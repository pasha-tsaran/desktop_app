use std::{
    io::{self, Read, Write},
    net::{SocketAddr, TcpStream, UdpSocket},
    time::{Duration, Instant},
};

use vpn_service_core::BackendFailure;

const DNS_SERVERS: [&str; 2] = ["1.1.1.1:53", "1.0.0.1:53"];
const HTTP_ENDPOINTS: [&str; 2] = ["1.1.1.1:80", "1.0.0.1:80"];
const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(2);
const TRANSACTION_ID: [u8; 2] = *b"KV";
const HTTP_PROBE: &[u8] =
    b"GET /cdn-cgi/trace HTTP/1.1\r\nHost: one.one.one.one\r\nConnection: close\r\n\r\n";

/// Performs one bounded request/response exchange after the tunnel route and
/// DNS guard are installed. This is a connection gate, never an idle monitor.
pub fn verify_ipv4_round_trip() -> Result<(), BackendFailure> {
    let query = dns_query();
    for server in DNS_SERVERS {
        super::connection_cancel::check()?;
        if exchange(server, &query).is_ok() {
            return Ok(());
        }
    }
    // Some Windows/network combinations drop this service's raw UDP probe
    // even though Xray already carries TCP through the selected exit. Do not
    // misreport that transport-specific probe failure as an unavailable VPN
    // server: require a bounded HTTP request and response through the route.
    for endpoint in HTTP_ENDPOINTS {
        super::connection_cancel::check()?;
        if http_exchange(endpoint).is_ok() {
            return Ok(());
        }
    }
    Err(BackendFailure::ServerUnavailable)
}

fn http_exchange(endpoint: &str) -> io::Result<()> {
    let address: SocketAddr = endpoint
        .parse()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    let mut stream = TcpStream::connect_timeout(&address, ATTEMPT_TIMEOUT)?;
    stream.set_read_timeout(Some(ATTEMPT_TIMEOUT))?;
    stream.set_write_timeout(Some(ATTEMPT_TIMEOUT))?;
    stream.write_all(HTTP_PROBE)?;
    let mut response = [0_u8; 32];
    let mut size = 0;
    while size < response.len() {
        let bytes_read = stream.read(&mut response[size..])?;
        if bytes_read == 0 {
            break;
        }
        size += bytes_read;
        if response[..size].windows(2).any(|bytes| bytes == b"\r\n") {
            break;
        }
    }
    if valid_http_response(&response[..size]) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unexpected HTTP probe response",
        ))
    }
}

fn valid_http_response(response: &[u8]) -> bool {
    let Some(status) = response.strip_prefix(b"HTTP/1.") else {
        return false;
    };
    status.len() >= 5
        && matches!(status[0], b'0' | b'1')
        && status[1] == b' '
        && matches!(status[2], b'2' | b'3' | b'4')
        && status[3].is_ascii_digit()
        && status[4].is_ascii_digit()
}

fn exchange(server: &str, query: &[u8]) -> io::Result<()> {
    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.set_read_timeout(Some(ATTEMPT_TIMEOUT))?;
    socket.set_write_timeout(Some(ATTEMPT_TIMEOUT))?;
    socket.connect(server)?;
    socket.send(query)?;

    let deadline = Instant::now() + ATTEMPT_TIMEOUT;
    let mut response = [0_u8; 512];
    loop {
        let size = socket.recv(&mut response)?;
        if valid_dns_response(&response[..size]) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "no matching DNS response",
            ));
        }
        socket.set_read_timeout(Some(deadline.saturating_duration_since(Instant::now())))?;
    }
}

fn dns_query() -> Vec<u8> {
    let mut query = vec![
        TRANSACTION_ID[0],
        TRANSACTION_ID[1],
        0x01,
        0x00, // recursion desired
        0x00,
        0x01, // one question
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    ];
    for label in [b"example".as_slice(), b"com".as_slice()] {
        query.push(u8::try_from(label.len()).expect("fixed DNS label length"));
        query.extend_from_slice(label);
    }
    query.extend_from_slice(&[0, 0, 1, 0, 1]); // root, A, IN
    query
}

fn valid_dns_response(response: &[u8]) -> bool {
    response.len() >= 12
        && response[..2] == TRANSACTION_ID
        && response[2] & 0x80 != 0
        && response[3].trailing_zeros() >= 4
        && u16::from_be_bytes([response[4], response[5]]) == 1
        && u16::from_be_bytes([response[6], response[7]]) > 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_is_a_single_recursive_example_com_a_question() {
        assert_eq!(&dns_query()[..12], b"KV\x01\0\0\x01\0\0\0\0\0\0");
        assert!(dns_query().ends_with(b"\x07example\x03com\0\0\x01\0\x01"));
    }

    #[test]
    fn response_requires_matching_successful_answer() {
        let mut response = [0_u8; 12];
        response[..2].copy_from_slice(&TRANSACTION_ID);
        response[2] = 0x81;
        response[3] = 0x80;
        response[5] = 1;
        response[7] = 1;
        assert!(valid_dns_response(&response));
        response[3] = 0x83;
        assert!(!valid_dns_response(&response));
        response[3] = 0x80;
        response[7] = 0;
        assert!(!valid_dns_response(&response));
    }

    #[test]
    fn http_fallback_requires_a_complete_non_server_error_status() {
        assert!(valid_http_response(b"HTTP/1.1 200 OK\r\n"));
        assert!(valid_http_response(b"HTTP/1.0 301 Moved\r\n"));
        assert!(valid_http_response(b"HTTP/1.1 404 Missing\r\n"));
        assert!(!valid_http_response(b"HTTP/1.1 503 Unavailable\r\n"));
        assert!(!valid_http_response(b"HTTP/2 200\r\n"));
        assert!(!valid_http_response(b"HTTP/1.1 20"));
    }
}
