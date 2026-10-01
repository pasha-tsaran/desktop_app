use std::{
    ffi::OsString,
    fmt::Write as _,
    fs,
    io::{self, Write},
    path::PathBuf,
    process::Command,
    thread,
    time::{Duration, Instant},
};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use sha2::{Digest, Sha256};
use vpn_contracts::{AmneziaWgProfile, TunnelStatistics, WireGuardProfile};
use vpn_service_core::{BackendFailure, VpnBackend};
use windows_service::{
    service::{
        ServiceAccess, ServiceDependency, ServiceErrorControl, ServiceInfo, ServiceSidType,
        ServiceStartType, ServiceState, ServiceType,
    },
    service_manager::{ServiceManager, ServiceManagerAccess},
};
use zeroize::Zeroizing;

use super::profile_vault::apply_service_acl;

const TUNNEL_NAME: &str = "KenaiAwg";
const SERVICE_NAME: &str = "AmneziaWGTunnel$KenaiAwg";
const ENGINE_SHA256: &str = "ba446f6e1a4093e43a65d6ff45f4b8c7b6485dc419327eedaa1a218549740e3a";
const TOOLS_SHA256: &str = "272badace73caeb26dc42656f318b3eb7f10028c2f76faad1f52d6fe1e0ced12";
const WINTUN_SHA256: &str = "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce";
const TIMEOUT: Duration = Duration::from_secs(30);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug)]
pub struct AmneziaWgWindowsBackend {
    executable: PathBuf,
    runtime_root: PathBuf,
    config_path: PathBuf,
}

impl AmneziaWgWindowsBackend {
    pub fn system_default() -> io::Result<Self> {
        let executable = super::executable_path::current_executable()?;
        let program_data = std::env::var_os("ProgramData")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "ProgramData unavailable"))?;
        let runtime_root = PathBuf::from(program_data).join("KenaiVPN").join("runtime");
        fs::create_dir_all(&runtime_root)?;
        apply_service_acl(&runtime_root)?;
        let backend = Self {
            executable,
            config_path: runtime_root.join(format!("{TUNNEL_NAME}.conf")),
            runtime_root,
        };
        backend
            .cleanup_stale()
            .map_err(|_| io::Error::other("AmneziaWG cleanup failed"))?;
        Ok(backend)
    }

    fn payload_root(&self) -> Result<PathBuf, BackendFailure> {
        self.executable
            .parent()
            .map(|root| root.join("amneziawg").join("amd64"))
            .ok_or(BackendFailure::EngineUnavailable)
    }

    fn verify_payloads(&self) -> Result<(), BackendFailure> {
        let root = self.payload_root()?;
        verify_hash(&root.join("amneziawg.exe"), ENGINE_SHA256)?;
        verify_hash(&root.join("awg.exe"), TOOLS_SHA256)?;
        verify_hash(&root.join("wintun.dll"), WINTUN_SHA256)
    }

    fn write_config(&self, profile: &AmneziaWgProfile) -> Result<(), BackendFailure> {
        let temporary = self.runtime_root.join(format!("{TUNNEL_NAME}.conf.new"));
        remove_if_present(&temporary)?;
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|_| BackendFailure::Internal)?;
        let rendered = render_config(profile);
        if file
            .write_all(rendered.as_bytes())
            .and_then(|()| file.sync_all())
            .is_err()
        {
            let _ = fs::remove_file(temporary);
            return Err(BackendFailure::Internal);
        }
        drop(file);
        fs::rename(&temporary, &self.config_path).map_err(|_| BackendFailure::Internal)
    }

    fn start_service(&self) -> Result<(), BackendFailure> {
        let root = self.payload_root()?;
        let manager = ServiceManager::local_computer(
            None::<&str>,
            ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE,
        )
        .map_err(|_| BackendFailure::EngineUnavailable)?;
        let info = ServiceInfo {
            name: OsString::from(SERVICE_NAME),
            display_name: OsString::from("Kenai VPN AmneziaWG 2.0/3.1 tunnel"),
            service_type: ServiceType::OWN_PROCESS,
            start_type: ServiceStartType::OnDemand,
            error_control: ServiceErrorControl::Normal,
            executable_path: root.join("amneziawg.exe"),
            launch_arguments: vec![
                OsString::from("/tunnelservice"),
                self.config_path.as_os_str().to_os_string(),
            ],
            dependencies: vec![
                ServiceDependency::Service(OsString::from("Nsi")),
                ServiceDependency::Service(OsString::from("TcpIp")),
            ],
            account_name: None,
            account_password: None,
        };
        let service = manager
            .create_service(&info, ServiceAccess::ALL_ACCESS)
            .map_err(|_| BackendFailure::Internal)?;
        service
            .set_config_service_sid_info(ServiceSidType::Unrestricted)
            .map_err(|_| BackendFailure::Internal)?;
        service
            .start::<&str>(&[])
            .map_err(|_| BackendFailure::Internal)?;
        wait_for_state(&service, ServiceState::Running, TIMEOUT)
            .map_err(|_| BackendFailure::ServerUnavailable)?;
        remove_if_present(&self.config_path)
    }

    fn cleanup_stale(&self) -> Result<(), BackendFailure> {
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|_| BackendFailure::EngineUnavailable)?;
        if let Ok(service) = manager.open_service(SERVICE_NAME, ServiceAccess::ALL_ACCESS) {
            if service
                .query_status()
                .map_err(|_| BackendFailure::Internal)?
                .current_state
                != ServiceState::Stopped
            {
                service.stop().map_err(|_| BackendFailure::Internal)?;
                wait_for_state(&service, ServiceState::Stopped, TIMEOUT)
                    .map_err(|_| BackendFailure::Internal)?;
            }
            service.delete().map_err(|_| BackendFailure::Internal)?;
        }
        remove_if_present(&self.config_path)?;
        remove_if_present(&self.runtime_root.join(format!("{TUNNEL_NAME}.conf.new")))
    }

    fn read_statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
        self.verify_payloads()?;
        let output = super::command_wait::output(
            Command::new(self.payload_root()?.join("awg.exe")).args(["show", TUNNEL_NAME, "dump"]),
            Duration::from_secs(5),
        )?;
        let dump = Zeroizing::new(String::from_utf8(output).map_err(|_| BackendFailure::Internal)?);
        parse_statistics(&dump)
    }

    fn wait_for_handshake(&self) -> Result<(), BackendFailure> {
        let started = Instant::now();
        loop {
            super::connection_cancel::check()?;
            if self
                .read_statistics()
                .is_ok_and(|stats| has_handshake(&stats))
            {
                return Ok(());
            }
            if started.elapsed() >= HANDSHAKE_TIMEOUT {
                return Err(BackendFailure::ServerUnavailable);
            }
            thread::sleep(Duration::from_millis(250));
        }
    }
}

impl VpnBackend for AmneziaWgWindowsBackend {
    fn connect(
        &mut self,
        _id: &str,
        _profile: &WireGuardProfile,
        _kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        Err(BackendFailure::UnsupportedFeature)
    }
    fn connect_amneziawg(
        &mut self,
        _id: &str,
        profile: &AmneziaWgProfile,
        kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        if kill_switch {
            return Err(BackendFailure::UnsupportedFeature);
        }
        profile
            .validate()
            .map_err(|_| BackendFailure::InvalidProfile)?;
        self.cleanup_stale()?;
        self.verify_payloads()?;
        self.write_config(profile)?;
        if let Err(error) = self
            .start_service()
            .and_then(|()| self.wait_for_handshake())
        {
            // A running adapter or outbound bytes do not prove a working tunnel.
            // Remove its routes and WFP filters before returning a failed connect.
            self.cleanup_stale()?;
            return Err(error);
        }
        Ok(())
    }
    fn disconnect(&mut self) -> Result<(), BackendFailure> {
        self.cleanup_stale()
    }
    fn is_connected(&self) -> Result<bool, BackendFailure> {
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|_| BackendFailure::EngineUnavailable)?;
        let Ok(service) = manager.open_service(SERVICE_NAME, ServiceAccess::QUERY_STATUS) else {
            return Ok(false);
        };
        Ok(service
            .query_status()
            .map_err(|_| BackendFailure::Internal)?
            .current_state
            == ServiceState::Running)
    }
    fn statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
        self.read_statistics()
    }
}

fn render_config(profile: &AmneziaWgProfile) -> Zeroizing<String> {
    let base = &profile.wireguard;
    let endpoint = if base.endpoint_host.contains(':') {
        format!("[{}]", base.endpoint_host)
    } else {
        base.endpoint_host.clone()
    };
    let private_key = Zeroizing::new(STANDARD.encode(base.private_key.0));
    let mut config = Zeroizing::new(String::new());
    let _ = write!(
        config,
        "[Interface]\r\nPrivateKey = {}\r\nAddress = {}\r\n",
        private_key.as_str(),
        base.addresses.join(", ")
    );
    if !base.dns_servers.is_empty() {
        let _ = writeln!(
            config,
            "DNS = {}\r",
            base.dns_servers
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    if let Some(mtu) = profile.mtu {
        let _ = writeln!(config, "MTU = {mtu}\r");
    }
    let _ = write!(config, "Jc = {}\r\nJmin = {}\r\nJmax = {}\r\nS1 = {}\r\nS2 = {}\r\nS3 = {}\r\nS4 = {}\r\nH1 = {}\r\nH2 = {}\r\nH3 = {}\r\nH4 = {}\r\n", profile.junk_packet_count, profile.junk_packet_min_size, profile.junk_packet_max_size, profile.init_packet_junk_size, profile.response_packet_junk_size, profile.init_packet_magic_header, profile.response_packet_magic_header, profile.transport_packet_magic_header, profile.init_packet_magic_header_value, profile.response_packet_magic_header_value, profile.transport_packet_magic_header_value);
    for (index, value) in profile.special_junk.iter().enumerate() {
        let _ = writeln!(config, "I{} = {}\r", index + 1, value);
    }
    if let Some(key) = &profile.header_protection_key {
        let key = Zeroizing::new(STANDARD.encode(key.0));
        let _ = writeln!(config, "HeaderProtectionKey = {}\r", key.as_str());
    }
    for (name, value) in [
        ("ContentPaddingAddition", &profile.content_padding_addition),
        ("RekeyAfterTime", &profile.rekey_after_time),
        ("RekeyTimeout", &profile.rekey_timeout),
        ("RejectAfterTime", &profile.reject_after_time),
        ("KeepaliveTimeout", &profile.keepalive_timeout),
        ("MaxHandshakeAttempts", &profile.max_handshake_attempts),
    ] {
        if let Some(value) = value {
            let _ = writeln!(config, "{name} = {value}\r");
        }
    }
    for (name, value) in [
        ("RandomTrailers", profile.random_trailers),
        ("DisableCookies", profile.disable_cookies),
    ] {
        if let Some(value) = value {
            let _ = writeln!(config, "{name} = {}\r", if value { "on" } else { "off" });
        }
    }
    let _ = write!(
        config,
        "\r\n[Peer]\r\nPublicKey = {}\r\n",
        STANDARD.encode(base.peer_public_key.0)
    );
    if let Some(key) = &base.preshared_key {
        let key = Zeroizing::new(STANDARD.encode(key.0));
        let _ = writeln!(config, "PresharedKey = {}\r", key.as_str());
    }
    let _ = write!(
        config,
        "Endpoint = {endpoint}:{}\r\nAllowedIPs = {}\r\n",
        base.endpoint_port,
        base.allowed_ips.join(", ")
    );
    if let Some(value) = base.persistent_keepalive {
        let _ = writeln!(config, "PersistentKeepalive = {value}\r");
    }
    config
}

fn parse_statistics(value: &str) -> Result<TunnelStatistics, BackendFailure> {
    let peer = value.lines().nth(1).ok_or(BackendFailure::Internal)?;
    let fields: Vec<&str> = peer.split('\t').collect();
    if fields.len() < 8 {
        return Err(BackendFailure::Internal);
    }
    let handshake = fields[4]
        .parse::<i64>()
        .map_err(|_| BackendFailure::Internal)?;
    Ok(TunnelStatistics {
        last_handshake_unix_ms: (handshake > 0).then_some(handshake.saturating_mul(1000)),
        bytes_received: fields[5].parse().map_err(|_| BackendFailure::Internal)?,
        bytes_sent: fields[6].parse().map_err(|_| BackendFailure::Internal)?,
    })
}

fn has_handshake(statistics: &TunnelStatistics) -> bool {
    statistics
        .last_handshake_unix_ms
        .is_some_and(|time| time > 0)
}

fn verify_hash(path: &PathBuf, expected: &str) -> Result<(), BackendFailure> {
    let bytes = fs::read(path).map_err(|_| BackendFailure::EngineUnavailable)?;
    let actual = format!("{:x}", Sha256::digest(bytes));
    if actual == expected {
        Ok(())
    } else {
        Err(BackendFailure::EngineUnavailable)
    }
}
fn remove_if_present(path: &PathBuf) -> Result<(), BackendFailure> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(BackendFailure::Internal),
    }
}
fn wait_for_state(
    service: &windows_service::service::Service,
    expected: ServiceState,
    timeout: Duration,
) -> windows_service::Result<()> {
    let started = Instant::now();
    loop {
        if expected == ServiceState::Running && super::connection_cancel::check().is_err() {
            return Err(windows_service::Error::Winapi(io::Error::new(
                io::ErrorKind::Interrupted,
                "connection cancelled",
            )));
        }
        if service.query_status()?.current_state == expected {
            return Ok(());
        }
        if started.elapsed() >= timeout {
            return Err(windows_service::Error::Winapi(io::Error::new(
                io::ErrorKind::TimedOut,
                "service transition timed out",
            )));
        }
        thread::sleep(Duration::from_millis(100));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_only_awg_dump_counters() {
        let value = "private\tpublic\t51820\toff\npeer\t(none)\t1.2.3.4:1\t0.0.0.0/0\t1700000000\t120\t240\t25\n";
        let stats = parse_statistics(value).expect("valid dump");
        assert_eq!(stats.bytes_received, 120);
        assert_eq!(stats.bytes_sent, 240);
        assert_eq!(stats.last_handshake_unix_ms, Some(1_700_000_000_000));
        assert!(has_handshake(&stats));
    }
    #[test]
    fn outbound_packets_without_handshake_are_not_connected() {
        let value =
            "private\tpublic\t51820\toff\npeer\t(none)\t1.2.3.4:1\t0.0.0.0/0\t0\t0\t240\t25\n";
        let stats = parse_statistics(value).expect("valid dump");
        assert_eq!(stats.bytes_sent, 240);
        assert!(!has_handshake(&stats));
    }
    #[test]
    fn missing_or_malformed_peer_does_not_confirm_handshake() {
        assert!(parse_statistics("private\tpublic\t51820\toff\n").is_err());
        assert!(
            parse_statistics("header\npeer\t(none)\tendpoint\tallowed\tbad\t0\t0\t25").is_err()
        );
    }
    #[test]
    fn committed_payload_hashes_match() {
        let root = super::super::test_payload_root("amneziawg");
        verify_hash(&root.join("amneziawg.exe"), ENGINE_SHA256).expect("engine");
        verify_hash(&root.join("awg.exe"), TOOLS_SHA256).expect("tools");
        verify_hash(&root.join("wintun.dll"), WINTUN_SHA256).expect("wintun");
    }

    #[test]
    fn renders_the_profile_mtu_for_awg31() {
        let mut profile = vpn_contracts::AmneziaWgProfile {
            wireguard: WireGuardProfile {
                private_key: vpn_contracts::SecretKey([1; 32]),
                addresses: vec!["10.67.67.8/32".into()],
                dns_servers: vec!["1.1.1.1".parse().expect("IP")],
                peer_public_key: vpn_contracts::SecretKey([2; 32]),
                preshared_key: None,
                endpoint_host: "147.45.231.194".into(),
                endpoint_port: 443,
                allowed_ips: vec!["0.0.0.0/0".into()],
                persistent_keepalive: Some(25),
            },
            junk_packet_count: 6,
            junk_packet_min_size: 10,
            junk_packet_max_size: 50,
            init_packet_junk_size: 12,
            response_packet_junk_size: 12,
            init_packet_magic_header: 12,
            response_packet_magic_header: 12,
            transport_packet_magic_header: "1".into(),
            init_packet_magic_header_value: "2".into(),
            response_packet_magic_header_value: "3".into(),
            transport_packet_magic_header_value: "4".into(),
            special_junk: Vec::new(),
            header_protection_key: Some(vpn_contracts::SecretKey([3; 32])),
            content_padding_addition: Some("10-100".into()),
            rekey_after_time: Some("100-120".into()),
            rekey_timeout: Some("3-7".into()),
            reject_after_time: Some("150-180".into()),
            keepalive_timeout: Some("5-15".into()),
            max_handshake_attempts: Some("15-20".into()),
            random_trailers: Some(true),
            disable_cookies: Some(true),
            mtu: Some(1376),
        };
        profile.validate().expect("valid AWG 3.1 profile");
        let rendered = render_config(&profile);
        assert!(rendered.contains("MTU = 1376\r\n"));
        profile.mtu = None;
        assert!(!render_config(&profile).contains("MTU ="));
    }
}
