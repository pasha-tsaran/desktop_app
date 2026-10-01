//! Bounded, versioned IPC contract shared by the GUI bridge and VPN service.

use std::{fmt, net::IpAddr};

pub const CONTRACT_VERSION: u32 = 5;
pub const MAX_FRAME_SIZE: usize = 32 * 1024;
const MAGIC: &[u8; 4] = b"KVPN";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Protocol {
    WireGuard,
    AmneziaWg,
    VlessReality,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ConnectionPhase {
    #[default]
    Disconnected,
    Validating,
    Connecting,
    Connected,
    Reconnecting,
    Disconnecting,
    BlockedBySubscription,
    NoNetwork,
    ServerUnavailable,
    Error,
}

impl ConnectionPhase {
    #[must_use]
    pub const fn is_failure(self) -> bool {
        matches!(
            self,
            Self::BlockedBySubscription | Self::NoNetwork | Self::ServerUnavailable | Self::Error
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConnectRequest {
    pub operation_id: String,
    pub profile_id: String,
    pub protocol: Protocol,
    pub kill_switch: bool,
}

#[derive(Clone, Eq, PartialEq)]
pub struct SecretKey(pub [u8; 32]);

impl fmt::Debug for SecretKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretKey([REDACTED])")
    }
}

impl Drop for SecretKey {
    fn drop(&mut self) {
        self.0.fill(0);
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WireGuardProfile {
    pub private_key: SecretKey,
    pub addresses: Vec<String>,
    pub dns_servers: Vec<IpAddr>,
    pub peer_public_key: SecretKey,
    pub preshared_key: Option<SecretKey>,
    pub endpoint_host: String,
    pub endpoint_port: u16,
    pub allowed_ips: Vec<String>,
    pub persistent_keepalive: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AmneziaWgProfile {
    pub wireguard: WireGuardProfile,
    pub junk_packet_count: u16,
    pub junk_packet_min_size: u16,
    pub junk_packet_max_size: u16,
    pub init_packet_junk_size: u16,
    pub response_packet_junk_size: u16,
    pub init_packet_magic_header: u16,
    pub response_packet_magic_header: u16,
    pub transport_packet_magic_header: String,
    pub init_packet_magic_header_value: String,
    pub response_packet_magic_header_value: String,
    pub transport_packet_magic_header_value: String,
    pub special_junk: Vec<String>,
    pub header_protection_key: Option<SecretKey>,
    pub content_padding_addition: Option<String>,
    pub rekey_after_time: Option<String>,
    pub rekey_timeout: Option<String>,
    pub reject_after_time: Option<String>,
    pub keepalive_timeout: Option<String>,
    pub max_handshake_attempts: Option<String>,
    pub random_trailers: Option<bool>,
    pub disable_cookies: Option<bool>,
    pub mtu: Option<u16>,
}

#[derive(Clone, Eq, PartialEq)]
pub struct VlessRealityProfile {
    pub client_id: String,
    pub endpoint_host: String,
    pub endpoint_port: u16,
    pub server_name: String,
    pub fingerprint: String,
    pub reality_password: String,
    pub short_id: String,
    pub spider_x: String,
}

impl fmt::Debug for VlessRealityProfile {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("VlessRealityProfile([REDACTED])")
    }
}

impl VlessRealityProfile {
    /// Revalidates every VLESS/REALITY field at the privileged boundary.
    ///
    /// # Errors
    ///
    /// Returns [`FrameError::InvalidProfile`] for values outside the exact
    /// RAW + REALITY + Vision subset accepted by the client.
    pub fn validate(&self) -> Result<(), FrameError> {
        validate_uuid(&self.client_id)?;
        validate_endpoint_host(&self.endpoint_host)?;
        if self.endpoint_port == 0 {
            return Err(FrameError::InvalidProfile);
        }
        validate_endpoint_host(&self.server_name)?;
        if self.fingerprint != "chrome"
            || self.reality_password.len() != 43
            || !self
                .reality_password
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
            || self.short_id.len() > 16
            || !self.short_id.len().is_multiple_of(2)
            || !self.short_id.bytes().all(|byte| byte.is_ascii_hexdigit())
            || self.spider_x != "/"
        {
            return Err(FrameError::InvalidProfile);
        }
        Ok(())
    }
}

impl AmneziaWgProfile {
    /// Revalidates every base and `AmneziaWG`-specific field.
    ///
    /// # Errors
    ///
    /// Returns [`FrameError::InvalidProfile`] for invalid or oversized data.
    pub fn validate(&self) -> Result<(), FrameError> {
        self.wireguard.validate()?;
        if self.junk_packet_count > 10
            || !(1..=1024).contains(&self.junk_packet_min_size)
            || !(1..=1024).contains(&self.junk_packet_max_size)
            || self.junk_packet_min_size > self.junk_packet_max_size
            || self.init_packet_junk_size > 64
            || self.response_packet_junk_size > 64
            || self.init_packet_magic_header > 64
            || self.response_packet_magic_header > 32
            || self.special_junk.len() > 5
            || self.mtu.is_some_and(|mtu| !(576..=9000).contains(&mtu))
        {
            return Err(FrameError::InvalidProfile);
        }
        for value in [
            &self.transport_packet_magic_header,
            &self.init_packet_magic_header_value,
            &self.response_packet_magic_header_value,
            &self.transport_packet_magic_header_value,
        ] {
            validate_numeric_range(value)?;
        }
        if self.special_junk.iter().any(|value| {
            value.is_empty() || value.len() > 4096 || value.chars().any(char::is_control)
        }) {
            return Err(FrameError::InvalidProfile);
        }
        for value in [
            &self.content_padding_addition,
            &self.rekey_after_time,
            &self.rekey_timeout,
            &self.reject_after_time,
            &self.keepalive_timeout,
            &self.max_handshake_attempts,
        ]
        .into_iter()
        .flatten()
        {
            validate_numeric_range_u16(value)?;
        }
        if self.header_protection_key.is_some()
            && (self.init_packet_junk_size < 12
                || self.response_packet_junk_size < 12
                || self.init_packet_magic_header < 12
                || self.response_packet_magic_header < 12)
        {
            return Err(FrameError::InvalidProfile);
        }
        if self.random_trailers == Some(true)
            && !(self.init_packet_junk_size == self.response_packet_junk_size
                && self.response_packet_junk_size == self.init_packet_magic_header
                && self.init_packet_magic_header == self.response_packet_magic_header)
        {
            return Err(FrameError::InvalidProfile);
        }
        Ok(())
    }
}

impl WireGuardProfile {
    /// Revalidates every field at the privileged boundary.
    ///
    /// # Errors
    ///
    /// Returns [`FrameError::InvalidProfile`] for an invalid or unbounded
    /// address, DNS server, endpoint, route, port, or keepalive value.
    pub fn validate(&self) -> Result<(), FrameError> {
        if self.private_key.0.iter().all(|byte| *byte == 0)
            || self.peer_public_key.0.iter().all(|byte| *byte == 0)
            || self
                .preshared_key
                .as_ref()
                .is_some_and(|key| key.0.iter().all(|byte| *byte == 0))
        {
            return Err(FrameError::InvalidProfile);
        }
        validate_networks(&self.addresses, 1, 8)?;
        if self.dns_servers.len() > 8 {
            return Err(FrameError::InvalidProfile);
        }
        validate_endpoint_host(&self.endpoint_host)?;
        if self.endpoint_port == 0 {
            return Err(FrameError::InvalidProfile);
        }
        validate_networks(&self.allowed_ips, 1, 32)?;
        if self.persistent_keepalive == Some(0) {
            return Err(FrameError::InvalidProfile);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportWireGuardProfileRequest {
    pub operation_id: String,
    pub profile: WireGuardProfile,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportAmneziaWgProfileRequest {
    pub operation_id: String,
    pub profile: AmneziaWgProfile,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportVlessRealityProfileRequest {
    pub operation_id: String,
    pub profile: VlessRealityProfile,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ControlCommand {
    SetKillSwitch {
        enabled: bool,
    },
    Status,
    Connect(ConnectRequest),
    Disconnect {
        operation_id: String,
    },
    Diagnostics,
    ImportWireGuardProfile(ImportWireGuardProfileRequest),
    ImportAmneziaWgProfile(Box<ImportAmneziaWgProfileRequest>),
    ImportVlessRealityProfile(ImportVlessRealityProfileRequest),
    DeleteProfile {
        operation_id: String,
        profile_id: String,
    },
    Statistics,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestEnvelope {
    pub contract_version: u32,
    pub request_id: String,
    pub command: ControlCommand,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResponseEnvelope {
    pub contract_version: u32,
    pub request_id: String,
    pub phase: ConnectionPhase,
    pub profile_id: Option<String>,
    pub kill_switch_active: bool,
    pub code: String,
    pub statistics: Option<TunnelStatistics>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TunnelStatistics {
    pub bytes_received: u64,
    pub bytes_sent: u64,
    pub last_handshake_unix_ms: Option<i64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FrameError {
    TooLarge,
    TooShort,
    InvalidMagic,
    UnsupportedVersion,
    UnknownOperation,
    InvalidLength,
    InvalidUtf8,
    InvalidIdentifier,
    InvalidProtocol,
    InvalidBoolean,
    TrailingData,
    InvalidProfile,
}

/// Returns the complete frame size declared by a 12-byte header.
///
/// # Errors
///
/// Returns [`FrameError`] if the header is incomplete, malformed, uses an
/// unsupported contract version, or declares an oversized frame.
pub fn declared_frame_size(header: &[u8]) -> Result<usize, FrameError> {
    if header.len() != 12 {
        return Err(FrameError::TooShort);
    }
    if &header[..4] != MAGIC {
        return Err(FrameError::InvalidMagic);
    }
    let version = u32::from(u16::from_le_bytes([header[4], header[5]]));
    if version != CONTRACT_VERSION {
        return Err(FrameError::UnsupportedVersion);
    }
    if header[7] != 0 {
        return Err(FrameError::UnknownOperation);
    }
    let body_len = usize::try_from(u32::from_le_bytes([
        header[8], header[9], header[10], header[11],
    ]))
    .map_err(|_| FrameError::InvalidLength)?;
    let total = body_len.checked_add(12).ok_or(FrameError::TooLarge)?;
    if total > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    Ok(total)
}

/// Encodes one validated client request into the bounded binary wire format.
///
/// # Errors
///
/// Returns [`FrameError`] when the contract version or an identifier is invalid,
/// or when the encoded frame would exceed [`MAX_FRAME_SIZE`].
pub fn encode_request(request: &RequestEnvelope) -> Result<Vec<u8>, FrameError> {
    validate_identifier(&request.request_id)?;
    if request.contract_version != CONTRACT_VERSION {
        return Err(FrameError::UnsupportedVersion);
    }

    let mut body = Vec::new();
    put_string(&mut body, &request.request_id)?;
    let opcode = match &request.command {
        ControlCommand::SetKillSwitch { enabled } => {
            body.push(u8::from(*enabled));
            10
        }
        ControlCommand::Status => 1,
        ControlCommand::Connect(connect) => {
            validate_identifier(&connect.operation_id)?;
            validate_identifier(&connect.profile_id)?;
            put_string(&mut body, &connect.operation_id)?;
            put_string(&mut body, &connect.profile_id)?;
            body.push(protocol_byte(connect.protocol));
            body.push(u8::from(connect.kill_switch));
            2
        }
        ControlCommand::Disconnect { operation_id } => {
            validate_identifier(operation_id)?;
            put_string(&mut body, operation_id)?;
            3
        }
        ControlCommand::Diagnostics => 4,
        ControlCommand::ImportWireGuardProfile(import) => {
            validate_identifier(&import.operation_id)?;
            import.profile.validate()?;
            put_string(&mut body, &import.operation_id)?;
            put_profile(&mut body, &import.profile)?;
            5
        }
        ControlCommand::DeleteProfile {
            operation_id,
            profile_id,
        } => {
            validate_identifier(operation_id)?;
            validate_identifier(profile_id)?;
            put_string(&mut body, operation_id)?;
            put_string(&mut body, profile_id)?;
            6
        }
        ControlCommand::Statistics => 7,
        ControlCommand::ImportAmneziaWgProfile(import) => {
            validate_identifier(&import.operation_id)?;
            import.profile.validate()?;
            put_string(&mut body, &import.operation_id)?;
            put_amneziawg_profile(&mut body, &import.profile)?;
            8
        }
        ControlCommand::ImportVlessRealityProfile(import) => {
            validate_identifier(&import.operation_id)?;
            import.profile.validate()?;
            put_string(&mut body, &import.operation_id)?;
            put_vless_profile(&mut body, &import.profile)?;
            9
        }
    };
    if body.len() + 12 > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }

    let mut frame = Vec::with_capacity(body.len() + 12);
    frame.extend_from_slice(MAGIC);
    let wire_version =
        u16::try_from(CONTRACT_VERSION).map_err(|_| FrameError::UnsupportedVersion)?;
    frame.extend_from_slice(&wire_version.to_le_bytes());
    frame.push(opcode);
    frame.push(0);
    let body_len = u32::try_from(body.len()).map_err(|_| FrameError::TooLarge)?;
    frame.extend_from_slice(&body_len.to_le_bytes());
    frame.extend_from_slice(&body);
    Ok(frame)
}

/// Decodes and validates one complete request frame.
///
/// # Errors
///
/// Returns [`FrameError`] for malformed, oversized, unsupported, or trailing
/// input. The decoder never accepts arbitrary paths or commands as identifiers.
pub fn decode_request(frame: &[u8]) -> Result<RequestEnvelope, FrameError> {
    if frame.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    if frame.len() < 12 {
        return Err(FrameError::TooShort);
    }
    if &frame[..4] != MAGIC {
        return Err(FrameError::InvalidMagic);
    }
    let version = u32::from(u16::from_le_bytes([frame[4], frame[5]]));
    if version != CONTRACT_VERSION {
        return Err(FrameError::UnsupportedVersion);
    }
    let opcode = frame[6];
    if frame[7] != 0 {
        return Err(FrameError::UnknownOperation);
    }
    let body_len = u32::from_le_bytes([frame[8], frame[9], frame[10], frame[11]]) as usize;
    if body_len != frame.len() - 12 {
        return Err(FrameError::InvalidLength);
    }

    let mut cursor = Cursor::new(&frame[12..]);
    let request_id = cursor.string()?;
    validate_identifier(&request_id)?;
    let command = decode_command(opcode, &mut cursor)?;
    if !cursor.finished() {
        return Err(FrameError::TrailingData);
    }
    Ok(RequestEnvelope {
        contract_version: version,
        request_id,
        command,
    })
}

fn decode_command(opcode: u8, cursor: &mut Cursor<'_>) -> Result<ControlCommand, FrameError> {
    let command = match opcode {
        10 => ControlCommand::SetKillSwitch {
            enabled: match cursor.byte()? {
                0 => false,
                1 => true,
                _ => return Err(FrameError::InvalidBoolean),
            },
        },
        1 => ControlCommand::Status,
        2 => {
            let operation_id = cursor.string()?;
            let profile_id = cursor.string()?;
            validate_identifier(&operation_id)?;
            validate_identifier(&profile_id)?;
            let protocol = match cursor.byte()? {
                1 => Protocol::WireGuard,
                2 => Protocol::AmneziaWg,
                3 => Protocol::VlessReality,
                _ => return Err(FrameError::InvalidProtocol),
            };
            let kill_switch = match cursor.byte()? {
                0 => false,
                1 => true,
                _ => return Err(FrameError::InvalidBoolean),
            };
            ControlCommand::Connect(ConnectRequest {
                operation_id,
                profile_id,
                protocol,
                kill_switch,
            })
        }
        3 => {
            let operation_id = cursor.string()?;
            validate_identifier(&operation_id)?;
            ControlCommand::Disconnect { operation_id }
        }
        4 => ControlCommand::Diagnostics,
        5 => {
            let operation_id = cursor.string()?;
            validate_identifier(&operation_id)?;
            let profile = cursor.profile()?;
            profile.validate()?;
            ControlCommand::ImportWireGuardProfile(ImportWireGuardProfileRequest {
                operation_id,
                profile,
            })
        }
        6 => {
            let operation_id = cursor.string()?;
            let profile_id = cursor.string()?;
            validate_identifier(&operation_id)?;
            validate_identifier(&profile_id)?;
            ControlCommand::DeleteProfile {
                operation_id,
                profile_id,
            }
        }
        7 => ControlCommand::Statistics,
        8 => {
            let operation_id = cursor.string()?;
            validate_identifier(&operation_id)?;
            let profile = cursor.amneziawg_profile()?;
            profile.validate()?;
            ControlCommand::ImportAmneziaWgProfile(Box::new(ImportAmneziaWgProfileRequest {
                operation_id,
                profile,
            }))
        }
        9 => {
            let operation_id = cursor.string()?;
            validate_identifier(&operation_id)?;
            let profile = cursor.vless_profile()?;
            profile.validate()?;
            ControlCommand::ImportVlessRealityProfile(ImportVlessRealityProfileRequest {
                operation_id,
                profile,
            })
        }
        _ => return Err(FrameError::UnknownOperation),
    };
    Ok(command)
}

/// Serializes one validated profile for encryption by the privileged vault.
///
/// # Errors
///
/// Returns [`FrameError`] if the profile is invalid or exceeds the bound.
pub fn encode_wireguard_profile(profile: &WireGuardProfile) -> Result<Vec<u8>, FrameError> {
    profile.validate()?;
    let mut bytes = b"KWP1".to_vec();
    put_profile(&mut bytes, profile)?;
    if bytes.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    Ok(bytes)
}

/// Decodes a profile only after its DPAPI envelope has been opened.
///
/// # Errors
///
/// Returns [`FrameError`] for malformed, trailing, invalid, or oversized data.
pub fn decode_wireguard_profile(bytes: &[u8]) -> Result<WireGuardProfile, FrameError> {
    if bytes.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    if !bytes.starts_with(b"KWP1") {
        return Err(FrameError::InvalidMagic);
    }
    let mut cursor = Cursor::new(&bytes[4..]);
    let profile = cursor.profile()?;
    if !cursor.finished() {
        return Err(FrameError::TrailingData);
    }
    profile.validate()?;
    Ok(profile)
}

/// Serializes a validated `AmneziaWG` profile for the encrypted service vault.
///
/// # Errors
///
/// Returns [`FrameError`] when validation or the size bound fails.
pub fn encode_amneziawg_profile(profile: &AmneziaWgProfile) -> Result<Vec<u8>, FrameError> {
    profile.validate()?;
    let mut bytes = b"KAP1".to_vec();
    put_amneziawg_profile(&mut bytes, profile)?;
    if bytes.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    Ok(bytes)
}

/// Decodes and validates an `AmneziaWG` profile after DPAPI decryption.
///
/// # Errors
///
/// Returns [`FrameError`] for malformed, trailing, invalid, or oversized data.
pub fn decode_amneziawg_profile(bytes: &[u8]) -> Result<AmneziaWgProfile, FrameError> {
    if bytes.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    if !bytes.starts_with(b"KAP1") {
        return Err(FrameError::InvalidMagic);
    }
    let mut cursor = Cursor::new(&bytes[4..]);
    let profile = cursor.amneziawg_profile()?;
    if !cursor.finished() {
        return Err(FrameError::TrailingData);
    }
    profile.validate()?;
    Ok(profile)
}

/// Serializes a validated VLESS/REALITY profile for the encrypted vault.
///
/// # Errors
///
/// Returns [`FrameError`] when validation or the size bound fails.
pub fn encode_vless_profile(profile: &VlessRealityProfile) -> Result<Vec<u8>, FrameError> {
    profile.validate()?;
    let mut bytes = b"KXP1".to_vec();
    put_vless_profile(&mut bytes, profile)?;
    if bytes.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    Ok(bytes)
}

/// Decodes and validates a VLESS/REALITY profile after DPAPI decryption.
///
/// # Errors
///
/// Returns [`FrameError`] for malformed, trailing, invalid, or oversized data.
pub fn decode_vless_profile(bytes: &[u8]) -> Result<VlessRealityProfile, FrameError> {
    if bytes.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    if !bytes.starts_with(b"KXP1") {
        return Err(FrameError::InvalidMagic);
    }
    let mut cursor = Cursor::new(&bytes[4..]);
    let profile = cursor.vless_profile()?;
    if !cursor.finished() {
        return Err(FrameError::TrailingData);
    }
    profile.validate()?;
    Ok(profile)
}

/// Encodes one service response without diagnostic text or platform errors.
///
/// # Errors
///
/// Returns [`FrameError`] when a field is not an allow-listed identifier, the
/// version is unsupported, or the response exceeds [`MAX_FRAME_SIZE`].
pub fn encode_response(response: &ResponseEnvelope) -> Result<Vec<u8>, FrameError> {
    if response.contract_version != CONTRACT_VERSION {
        return Err(FrameError::UnsupportedVersion);
    }
    validate_identifier(&response.request_id)?;
    validate_identifier(&response.code)?;

    let mut body = Vec::new();
    put_string(&mut body, &response.request_id)?;
    body.push(phase_byte(response.phase));
    match &response.profile_id {
        Some(profile_id) => {
            body.push(1);
            put_string(&mut body, profile_id)?;
        }
        None => body.push(0),
    }
    body.push(u8::from(response.kill_switch_active));
    put_string(&mut body, &response.code)?;
    match response.statistics {
        Some(statistics) => {
            body.push(1);
            body.extend_from_slice(&statistics.bytes_received.to_le_bytes());
            body.extend_from_slice(&statistics.bytes_sent.to_le_bytes());
            match statistics.last_handshake_unix_ms {
                Some(value) => {
                    body.push(1);
                    body.extend_from_slice(&value.to_le_bytes());
                }
                None => body.push(0),
            }
        }
        None => body.push(0),
    }
    encode_frame(0x81, &body)
}

/// Decodes one complete, bounded service response.
///
/// # Errors
///
/// Returns [`FrameError`] for malformed, oversized, unsupported, or trailing
/// input.
pub fn decode_response(frame: &[u8]) -> Result<ResponseEnvelope, FrameError> {
    let (opcode, version, body) = decode_frame(frame)?;
    if opcode != 0x81 {
        return Err(FrameError::UnknownOperation);
    }
    let mut cursor = Cursor::new(body);
    let request_id = cursor.string()?;
    validate_identifier(&request_id)?;
    let phase = decode_phase(cursor.byte()?)?;
    let profile_id = match cursor.byte()? {
        0 => None,
        1 => {
            let value = cursor.string()?;
            validate_identifier(&value)?;
            Some(value)
        }
        _ => return Err(FrameError::InvalidBoolean),
    };
    let kill_switch_active = match cursor.byte()? {
        0 => false,
        1 => true,
        _ => return Err(FrameError::InvalidBoolean),
    };
    let code = cursor.string()?;
    validate_identifier(&code)?;
    let statistics = match cursor.byte()? {
        0 => None,
        1 => {
            let bytes_received = cursor.u64()?;
            let bytes_sent = cursor.u64()?;
            let last_handshake_unix_ms = match cursor.byte()? {
                0 => None,
                1 => Some(cursor.i64()?),
                _ => return Err(FrameError::InvalidBoolean),
            };
            Some(TunnelStatistics {
                bytes_received,
                bytes_sent,
                last_handshake_unix_ms,
            })
        }
        _ => return Err(FrameError::InvalidBoolean),
    };
    if !cursor.finished() {
        return Err(FrameError::TrailingData);
    }
    Ok(ResponseEnvelope {
        contract_version: version,
        request_id,
        phase,
        profile_id,
        kill_switch_active,
        code,
        statistics,
    })
}

fn encode_frame(opcode: u8, body: &[u8]) -> Result<Vec<u8>, FrameError> {
    if body.len() + 12 > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    let wire_version =
        u16::try_from(CONTRACT_VERSION).map_err(|_| FrameError::UnsupportedVersion)?;
    let body_len = u32::try_from(body.len()).map_err(|_| FrameError::TooLarge)?;
    let mut frame = Vec::with_capacity(body.len() + 12);
    frame.extend_from_slice(MAGIC);
    frame.extend_from_slice(&wire_version.to_le_bytes());
    frame.push(opcode);
    frame.push(0);
    frame.extend_from_slice(&body_len.to_le_bytes());
    frame.extend_from_slice(body);
    Ok(frame)
}

fn decode_frame(frame: &[u8]) -> Result<(u8, u32, &[u8]), FrameError> {
    if frame.len() > MAX_FRAME_SIZE {
        return Err(FrameError::TooLarge);
    }
    if frame.len() < 12 {
        return Err(FrameError::TooShort);
    }
    if &frame[..4] != MAGIC {
        return Err(FrameError::InvalidMagic);
    }
    let version = u32::from(u16::from_le_bytes([frame[4], frame[5]]));
    if version != CONTRACT_VERSION {
        return Err(FrameError::UnsupportedVersion);
    }
    if frame[7] != 0 {
        return Err(FrameError::UnknownOperation);
    }
    let body_len = usize::try_from(u32::from_le_bytes([
        frame[8], frame[9], frame[10], frame[11],
    ]))
    .map_err(|_| FrameError::InvalidLength)?;
    if body_len != frame.len() - 12 {
        return Err(FrameError::InvalidLength);
    }
    Ok((frame[6], version, &frame[12..]))
}

const fn phase_byte(phase: ConnectionPhase) -> u8 {
    match phase {
        ConnectionPhase::Disconnected => 0,
        ConnectionPhase::Validating => 1,
        ConnectionPhase::Connecting => 2,
        ConnectionPhase::Connected => 3,
        ConnectionPhase::Reconnecting => 4,
        ConnectionPhase::Disconnecting => 5,
        ConnectionPhase::BlockedBySubscription => 6,
        ConnectionPhase::NoNetwork => 7,
        ConnectionPhase::ServerUnavailable => 8,
        ConnectionPhase::Error => 9,
    }
}

const fn decode_phase(value: u8) -> Result<ConnectionPhase, FrameError> {
    match value {
        0 => Ok(ConnectionPhase::Disconnected),
        1 => Ok(ConnectionPhase::Validating),
        2 => Ok(ConnectionPhase::Connecting),
        3 => Ok(ConnectionPhase::Connected),
        4 => Ok(ConnectionPhase::Reconnecting),
        5 => Ok(ConnectionPhase::Disconnecting),
        6 => Ok(ConnectionPhase::BlockedBySubscription),
        7 => Ok(ConnectionPhase::NoNetwork),
        8 => Ok(ConnectionPhase::ServerUnavailable),
        9 => Ok(ConnectionPhase::Error),
        _ => Err(FrameError::UnknownOperation),
    }
}

fn protocol_byte(protocol: Protocol) -> u8 {
    match protocol {
        Protocol::WireGuard => 1,
        Protocol::AmneziaWg => 2,
        Protocol::VlessReality => 3,
    }
}

fn validate_identifier(value: &str) -> Result<(), FrameError> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(FrameError::InvalidIdentifier);
    }
    Ok(())
}

fn put_string(target: &mut Vec<u8>, value: &str) -> Result<(), FrameError> {
    validate_identifier(value)?;
    let length = u8::try_from(value.len()).map_err(|_| FrameError::InvalidIdentifier)?;
    target.push(length);
    target.extend_from_slice(value.as_bytes());
    Ok(())
}

fn put_profile(target: &mut Vec<u8>, profile: &WireGuardProfile) -> Result<(), FrameError> {
    target.extend_from_slice(&profile.private_key.0);
    put_string_list(target, &profile.addresses)?;
    let dns: Vec<String> = profile
        .dns_servers
        .iter()
        .map(ToString::to_string)
        .collect();
    put_string_list(target, &dns)?;
    target.extend_from_slice(&profile.peer_public_key.0);
    match &profile.preshared_key {
        Some(key) => {
            target.push(1);
            target.extend_from_slice(&key.0);
        }
        None => target.push(0),
    }
    put_bounded_string(target, &profile.endpoint_host, 253)?;
    target.extend_from_slice(&profile.endpoint_port.to_le_bytes());
    put_string_list(target, &profile.allowed_ips)?;
    match profile.persistent_keepalive {
        Some(seconds) => {
            target.push(1);
            target.extend_from_slice(&seconds.to_le_bytes());
        }
        None => target.push(0),
    }
    Ok(())
}

fn put_amneziawg_profile(
    target: &mut Vec<u8>,
    profile: &AmneziaWgProfile,
) -> Result<(), FrameError> {
    put_profile(target, &profile.wireguard)?;
    for value in [
        profile.junk_packet_count,
        profile.junk_packet_min_size,
        profile.junk_packet_max_size,
        profile.init_packet_junk_size,
        profile.response_packet_junk_size,
        profile.init_packet_magic_header,
        profile.response_packet_magic_header,
    ] {
        target.extend_from_slice(&value.to_le_bytes());
    }
    for value in [
        &profile.transport_packet_magic_header,
        &profile.init_packet_magic_header_value,
        &profile.response_packet_magic_header_value,
        &profile.transport_packet_magic_header_value,
    ] {
        put_bounded_string(target, value, 253)?;
    }
    target.push(u8::try_from(profile.special_junk.len()).map_err(|_| FrameError::InvalidProfile)?);
    for value in &profile.special_junk {
        put_long_string(target, value)?;
    }
    match &profile.header_protection_key {
        Some(key) => {
            target.push(1);
            target.extend_from_slice(&key.0);
        }
        None => target.push(0),
    }
    for value in [
        &profile.content_padding_addition,
        &profile.rekey_after_time,
        &profile.rekey_timeout,
        &profile.reject_after_time,
        &profile.keepalive_timeout,
        &profile.max_handshake_attempts,
    ] {
        match value {
            Some(value) => {
                target.push(1);
                put_bounded_string(target, value, 31)?;
            }
            None => target.push(0),
        }
    }
    for value in [profile.random_trailers, profile.disable_cookies] {
        target.push(match value {
            None => 0,
            Some(false) => 1,
            Some(true) => 2,
        });
    }
    match profile.mtu {
        Some(mtu) => {
            target.push(1);
            target.extend_from_slice(&mtu.to_le_bytes());
        }
        None => target.push(0),
    }
    Ok(())
}

fn put_vless_profile(
    target: &mut Vec<u8>,
    profile: &VlessRealityProfile,
) -> Result<(), FrameError> {
    put_bounded_string(target, &profile.client_id, 36)?;
    put_bounded_string(target, &profile.endpoint_host, 253)?;
    target.extend_from_slice(&profile.endpoint_port.to_le_bytes());
    put_bounded_string(target, &profile.server_name, 253)?;
    put_bounded_string(target, &profile.fingerprint, 32)?;
    put_bounded_string(target, &profile.reality_password, 128)?;
    put_optional_bounded_string(target, &profile.short_id, 16)?;
    put_long_string(target, &profile.spider_x)?;
    Ok(())
}

fn put_optional_bounded_string(
    target: &mut Vec<u8>,
    value: &str,
    maximum: usize,
) -> Result<(), FrameError> {
    if value.len() > maximum || value.as_bytes().contains(&0) {
        return Err(FrameError::InvalidProfile);
    }
    target.push(u8::try_from(value.len()).map_err(|_| FrameError::InvalidProfile)?);
    target.extend_from_slice(value.as_bytes());
    Ok(())
}

fn validate_uuid(value: &str) -> Result<(), FrameError> {
    if value.len() != 36
        || value.bytes().enumerate().any(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte != b'-'
            } else {
                !byte.is_ascii_hexdigit()
            }
        })
    {
        return Err(FrameError::InvalidProfile);
    }
    Ok(())
}

fn put_long_string(target: &mut Vec<u8>, value: &str) -> Result<(), FrameError> {
    if value.is_empty() || value.len() > 4096 || value.chars().any(char::is_control) {
        return Err(FrameError::InvalidProfile);
    }
    target.extend_from_slice(
        &u16::try_from(value.len())
            .map_err(|_| FrameError::InvalidProfile)?
            .to_le_bytes(),
    );
    target.extend_from_slice(value.as_bytes());
    Ok(())
}

fn validate_numeric_range(value: &str) -> Result<(), FrameError> {
    let mut parts = value.split('-');
    let first = parts.next().ok_or(FrameError::InvalidProfile)?;
    if first.is_empty() || !first.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(FrameError::InvalidProfile);
    }
    let start: u32 = first.parse().map_err(|_| FrameError::InvalidProfile)?;
    if let Some(end) = parts.next() {
        if end.is_empty() || !end.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(FrameError::InvalidProfile);
        }
        let end: u32 = end.parse().map_err(|_| FrameError::InvalidProfile)?;
        if start > end || parts.next().is_some() {
            return Err(FrameError::InvalidProfile);
        }
    }
    Ok(())
}

fn validate_numeric_range_u16(value: &str) -> Result<(), FrameError> {
    validate_numeric_range(value)?;
    for part in value.split('-') {
        let parsed: u32 = part.parse().map_err(|_| FrameError::InvalidProfile)?;
        if parsed > u32::from(u16::MAX) {
            return Err(FrameError::InvalidProfile);
        }
    }
    Ok(())
}

fn decode_optional_bool(value: u8) -> Result<Option<bool>, FrameError> {
    match value {
        0 => Ok(None),
        1 => Ok(Some(false)),
        2 => Ok(Some(true)),
        _ => Err(FrameError::InvalidBoolean),
    }
}

fn put_string_list(target: &mut Vec<u8>, values: &[String]) -> Result<(), FrameError> {
    let count = u8::try_from(values.len()).map_err(|_| FrameError::InvalidProfile)?;
    target.push(count);
    for value in values {
        put_bounded_string(target, value, 253)?;
    }
    Ok(())
}

fn put_bounded_string(target: &mut Vec<u8>, value: &str, maximum: usize) -> Result<(), FrameError> {
    if value.is_empty() || value.len() > maximum || value.as_bytes().contains(&0) {
        return Err(FrameError::InvalidProfile);
    }
    let length = u8::try_from(value.len()).map_err(|_| FrameError::InvalidProfile)?;
    target.push(length);
    target.extend_from_slice(value.as_bytes());
    Ok(())
}

fn validate_networks(values: &[String], minimum: usize, maximum: usize) -> Result<(), FrameError> {
    if values.len() < minimum || values.len() > maximum {
        return Err(FrameError::InvalidProfile);
    }
    for value in values {
        let Some((address, prefix)) = value.split_once('/') else {
            return Err(FrameError::InvalidProfile);
        };
        let address: IpAddr = address.parse().map_err(|_| FrameError::InvalidProfile)?;
        let prefix: u8 = prefix.parse().map_err(|_| FrameError::InvalidProfile)?;
        let maximum_prefix = if address.is_ipv4() { 32 } else { 128 };
        if prefix > maximum_prefix {
            return Err(FrameError::InvalidProfile);
        }
    }
    Ok(())
}

fn validate_endpoint_host(value: &str) -> Result<(), FrameError> {
    if value.parse::<IpAddr>().is_ok() {
        return Ok(());
    }
    if value.is_empty()
        || value.len() > 253
        || value.starts_with('.')
        || value.ends_with('.')
        || value.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return Err(FrameError::InvalidProfile);
    }
    Ok(())
}

struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn byte(&mut self) -> Result<u8, FrameError> {
        let value = *self
            .bytes
            .get(self.offset)
            .ok_or(FrameError::InvalidLength)?;
        self.offset += 1;
        Ok(value)
    }

    fn string(&mut self) -> Result<String, FrameError> {
        let length = usize::from(self.byte()?);
        let end = self
            .offset
            .checked_add(length)
            .ok_or(FrameError::InvalidLength)?;
        let bytes = self
            .bytes
            .get(self.offset..end)
            .ok_or(FrameError::InvalidLength)?;
        self.offset = end;
        String::from_utf8(bytes.to_vec()).map_err(|_| FrameError::InvalidUtf8)
    }

    fn bytes<const N: usize>(&mut self) -> Result<[u8; N], FrameError> {
        let end = self
            .offset
            .checked_add(N)
            .ok_or(FrameError::InvalidLength)?;
        let source = self
            .bytes
            .get(self.offset..end)
            .ok_or(FrameError::InvalidLength)?;
        self.offset = end;
        source.try_into().map_err(|_| FrameError::InvalidLength)
    }

    fn u16(&mut self) -> Result<u16, FrameError> {
        Ok(u16::from_le_bytes(self.bytes()?))
    }

    fn long_string(&mut self) -> Result<String, FrameError> {
        let length = usize::from(self.u16()?);
        if length == 0 || length > 4096 {
            return Err(FrameError::InvalidProfile);
        }
        let end = self
            .offset
            .checked_add(length)
            .ok_or(FrameError::InvalidLength)?;
        let bytes = self
            .bytes
            .get(self.offset..end)
            .ok_or(FrameError::InvalidLength)?;
        self.offset = end;
        let value = String::from_utf8(bytes.to_vec()).map_err(|_| FrameError::InvalidUtf8)?;
        if value.chars().any(char::is_control) {
            return Err(FrameError::InvalidProfile);
        }
        Ok(value)
    }

    fn u64(&mut self) -> Result<u64, FrameError> {
        Ok(u64::from_le_bytes(self.bytes()?))
    }

    fn i64(&mut self) -> Result<i64, FrameError> {
        Ok(i64::from_le_bytes(self.bytes()?))
    }

    fn bounded_string(&mut self) -> Result<String, FrameError> {
        let value = self.string()?;
        if value.is_empty() || value.as_bytes().contains(&0) {
            return Err(FrameError::InvalidProfile);
        }
        Ok(value)
    }

    fn optional_bounded_string(&mut self) -> Result<String, FrameError> {
        let length = usize::from(self.byte()?);
        let end = self
            .offset
            .checked_add(length)
            .ok_or(FrameError::InvalidLength)?;
        let bytes = self
            .bytes
            .get(self.offset..end)
            .ok_or(FrameError::InvalidLength)?;
        self.offset = end;
        String::from_utf8(bytes.to_vec()).map_err(|_| FrameError::InvalidUtf8)
    }

    fn string_list(&mut self, maximum: usize) -> Result<Vec<String>, FrameError> {
        let count = usize::from(self.byte()?);
        if count > maximum {
            return Err(FrameError::InvalidProfile);
        }
        (0..count).map(|_| self.bounded_string()).collect()
    }

    fn profile(&mut self) -> Result<WireGuardProfile, FrameError> {
        let private_key = SecretKey(self.bytes()?);
        let addresses = self.string_list(8)?;
        let dns_servers = self
            .string_list(8)?
            .into_iter()
            .map(|value| value.parse().map_err(|_| FrameError::InvalidProfile))
            .collect::<Result<Vec<IpAddr>, FrameError>>()?;
        let peer_public_key = SecretKey(self.bytes()?);
        let preshared_key = match self.byte()? {
            0 => None,
            1 => Some(SecretKey(self.bytes()?)),
            _ => return Err(FrameError::InvalidBoolean),
        };
        let endpoint_host = self.bounded_string()?;
        let endpoint_port = self.u16()?;
        let allowed_ips = self.string_list(32)?;
        let persistent_keepalive = match self.byte()? {
            0 => None,
            1 => Some(self.u16()?),
            _ => return Err(FrameError::InvalidBoolean),
        };
        Ok(WireGuardProfile {
            private_key,
            addresses,
            dns_servers,
            peer_public_key,
            preshared_key,
            endpoint_host,
            endpoint_port,
            allowed_ips,
            persistent_keepalive,
        })
    }

    fn amneziawg_profile(&mut self) -> Result<AmneziaWgProfile, FrameError> {
        let wireguard = self.profile()?;
        let junk_packet_count = self.u16()?;
        let junk_packet_min_size = self.u16()?;
        let junk_packet_max_size = self.u16()?;
        let init_packet_junk_size = self.u16()?;
        let response_packet_junk_size = self.u16()?;
        let init_packet_magic_header = self.u16()?;
        let response_packet_magic_header = self.u16()?;
        let transport_packet_magic_header = self.bounded_string()?;
        let init_packet_magic_header_value = self.bounded_string()?;
        let response_packet_magic_header_value = self.bounded_string()?;
        let transport_packet_magic_header_value = self.bounded_string()?;
        let count = usize::from(self.byte()?);
        if count > 5 {
            return Err(FrameError::InvalidProfile);
        }
        let special_junk = (0..count)
            .map(|_| self.long_string())
            .collect::<Result<Vec<_>, _>>()?;
        let mut header_protection_key = None;
        let mut ranges: [Option<String>; 6] = Default::default();
        let mut random_trailers = None;
        let mut disable_cookies = None;
        let mut mtu = None;
        if !self.finished() {
            header_protection_key = match self.byte()? {
                0 => None,
                1 => Some(SecretKey(self.bytes()?)),
                _ => return Err(FrameError::InvalidBoolean),
            };
            for value in &mut ranges {
                *value = match self.byte()? {
                    0 => None,
                    1 => Some(self.bounded_string()?),
                    _ => return Err(FrameError::InvalidBoolean),
                };
            }
            random_trailers = decode_optional_bool(self.byte()?)?;
            disable_cookies = decode_optional_bool(self.byte()?)?;
            if !self.finished() {
                mtu = match self.byte()? {
                    0 => None,
                    1 => Some(self.u16()?),
                    _ => return Err(FrameError::InvalidBoolean),
                };
            }
        }
        Ok(AmneziaWgProfile {
            wireguard,
            junk_packet_count,
            junk_packet_min_size,
            junk_packet_max_size,
            init_packet_junk_size,
            response_packet_junk_size,
            init_packet_magic_header,
            response_packet_magic_header,
            transport_packet_magic_header,
            init_packet_magic_header_value,
            response_packet_magic_header_value,
            transport_packet_magic_header_value,
            special_junk,
            header_protection_key,
            content_padding_addition: ranges[0].take(),
            rekey_after_time: ranges[1].take(),
            rekey_timeout: ranges[2].take(),
            reject_after_time: ranges[3].take(),
            keepalive_timeout: ranges[4].take(),
            max_handshake_attempts: ranges[5].take(),
            random_trailers,
            disable_cookies,
            mtu,
        })
    }

    fn vless_profile(&mut self) -> Result<VlessRealityProfile, FrameError> {
        Ok(VlessRealityProfile {
            client_id: self.bounded_string()?,
            endpoint_host: self.bounded_string()?,
            endpoint_port: self.u16()?,
            server_name: self.bounded_string()?,
            fingerprint: self.bounded_string()?,
            reality_password: self.bounded_string()?,
            short_id: self.optional_bounded_string()?,
            spider_x: self.long_string()?,
        })
    }

    const fn finished(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StateEvent {
    pub contract_version: u32,
    pub phase: ConnectionPhase,
    pub profile_id: Option<String>,
    pub kill_switch_active: bool,
    pub error_code: Option<String>,
}

impl Default for StateEvent {
    fn default() -> Self {
        Self {
            contract_version: CONTRACT_VERSION,
            phase: ConnectionPhase::Disconnected,
            profile_id: None,
            kill_switch_active: false,
            error_code: None,
        }
    }
}

#[cfg(test)]
mod frame_tests {
    use super::*;

    fn connect() -> RequestEnvelope {
        RequestEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: "request-1".into(),
            command: ControlCommand::Connect(ConnectRequest {
                operation_id: "connect-1".into(),
                profile_id: "profile-1".into(),
                protocol: Protocol::WireGuard,
                kill_switch: true,
            }),
        }
    }

    fn wireguard_profile() -> WireGuardProfile {
        WireGuardProfile {
            private_key: SecretKey([7; 32]),
            addresses: vec!["10.8.0.2/32".into(), "fd00::2/128".into()],
            dns_servers: vec!["1.1.1.1".parse().expect("IP")],
            peer_public_key: SecretKey([9; 32]),
            preshared_key: Some(SecretKey([11; 32])),
            endpoint_host: "vpn.example.test".into(),
            endpoint_port: 51820,
            allowed_ips: vec!["0.0.0.0/0".into(), "::/0".into()],
            persistent_keepalive: Some(25),
        }
    }

    fn amneziawg_profile() -> AmneziaWgProfile {
        AmneziaWgProfile {
            wireguard: wireguard_profile(),
            junk_packet_count: 4,
            junk_packet_min_size: 64,
            junk_packet_max_size: 128,
            init_packet_junk_size: 12,
            response_packet_junk_size: 12,
            init_packet_magic_header: 12,
            response_packet_magic_header: 12,
            transport_packet_magic_header: "100".into(),
            init_packet_magic_header_value: "200-210".into(),
            response_packet_magic_header_value: "300".into(),
            transport_packet_magic_header_value: "400".into(),
            special_junk: vec!["<b 0x01>".into()],
            header_protection_key: Some(SecretKey([13; 32])),
            content_padding_addition: Some("10-100".into()),
            rekey_after_time: Some("100-120".into()),
            rekey_timeout: Some("3-7".into()),
            reject_after_time: Some("150-180".into()),
            keepalive_timeout: Some("5-15".into()),
            max_handshake_attempts: Some("15-20".into()),
            random_trailers: Some(false),
            disable_cookies: Some(true),
            mtu: Some(1376),
        }
    }

    fn vless_profile() -> VlessRealityProfile {
        let client_id = [8_usize, 4, 4, 4, 12]
            .iter()
            .map(|length| "a".repeat(*length))
            .collect::<Vec<_>>()
            .join("-");
        VlessRealityProfile {
            client_id,
            endpoint_host: "vpn.example.test".into(),
            endpoint_port: 443,
            server_name: "cover.example.test".into(),
            fingerprint: "chrome".into(),
            reality_password: "A".repeat(43),
            short_id: "aabbccdd".into(),
            spider_x: "/".into(),
        }
    }

    #[test]
    fn round_trips_every_allow_listed_operation() {
        for request in [
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "guard-on".into(),
                command: ControlCommand::SetKillSwitch { enabled: true },
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "guard-off".into(),
                command: ControlCommand::SetKillSwitch { enabled: false },
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "status-1".into(),
                command: ControlCommand::Status,
            },
            connect(),
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "disconnect-1".into(),
                command: ControlCommand::Disconnect {
                    operation_id: "operation-2".into(),
                },
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "diagnostics-1".into(),
                command: ControlCommand::Diagnostics,
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "statistics-1".into(),
                command: ControlCommand::Statistics,
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "import-1".into(),
                command: ControlCommand::ImportWireGuardProfile(ImportWireGuardProfileRequest {
                    operation_id: "provision-1".into(),
                    profile: wireguard_profile(),
                }),
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "delete-1".into(),
                command: ControlCommand::DeleteProfile {
                    operation_id: "cleanup-1".into(),
                    profile_id: "wg-0123456789abcdef".into(),
                },
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "import-awg-1".into(),
                command: ControlCommand::ImportAmneziaWgProfile(Box::new(
                    ImportAmneziaWgProfileRequest {
                        operation_id: "provision-awg-1".into(),
                        profile: amneziawg_profile(),
                    },
                )),
            },
            RequestEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "import-vless-1".into(),
                command: ControlCommand::ImportVlessRealityProfile(
                    ImportVlessRealityProfileRequest {
                        operation_id: "provision-vless-1".into(),
                        profile: vless_profile(),
                    },
                ),
            },
        ] {
            let encoded = encode_request(&request).expect("valid request");
            assert_eq!(decode_request(&encoded), Ok(request));
        }
    }

    #[test]
    fn encrypted_awg_payload_codec_rejects_trailing_and_invalid_ranges() {
        let profile = amneziawg_profile();
        let encoded = encode_amneziawg_profile(&profile).expect("valid AWG profile");
        assert_eq!(decode_amneziawg_profile(&encoded), Ok(profile.clone()));
        let mut trailing = encoded;
        trailing.push(0);
        assert_eq!(
            decode_amneziawg_profile(&trailing),
            Err(FrameError::TrailingData)
        );
        let mut invalid = profile;
        invalid.junk_packet_min_size = 1024;
        invalid.junk_packet_max_size = 64;
        assert_eq!(invalid.validate(), Err(FrameError::InvalidProfile));
    }

    #[test]
    fn awg31_small_positive_junk_range_is_valid() {
        let mut profile = amneziawg_profile();
        profile.junk_packet_min_size = 10;
        profile.junk_packet_max_size = 50;
        assert_eq!(profile.validate(), Ok(()));
    }

    #[test]
    fn awg_profile_without_explicit_mtu_remains_valid() {
        let mut profile = amneziawg_profile();
        profile.mtu = None;
        let encoded = encode_amneziawg_profile(&profile).expect("valid legacy profile");
        assert_eq!(decode_amneziawg_profile(&encoded), Ok(profile));
    }

    #[test]
    fn kill_switch_rejects_non_boolean_payload() {
        let request = RequestEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: "guard-invalid".into(),
            command: ControlCommand::SetKillSwitch { enabled: true },
        };
        let mut frame = encode_request(&request).expect("encoded");
        *frame.last_mut().expect("boolean") = 2;
        assert_eq!(decode_request(&frame), Err(FrameError::InvalidBoolean));
    }

    #[test]
    fn encrypted_vless_payload_codec_round_trips_and_rejects_trailing_data() {
        let profile = vless_profile();
        let encoded = encode_vless_profile(&profile).expect("valid VLESS profile");
        assert_eq!(decode_vless_profile(&encoded), Ok(profile));
        let mut trailing = encoded;
        trailing.push(0);
        assert_eq!(
            decode_vless_profile(&trailing),
            Err(FrameError::TrailingData)
        );
    }

    #[test]
    fn vless_validation_and_debug_output_protect_reality_credentials() {
        let profile = vless_profile();
        let rendered = format!("{profile:?}");
        assert!(rendered.contains("[REDACTED]"));
        assert!(!rendered.contains(&profile.client_id));
        assert!(!rendered.contains(&profile.reality_password));

        let mut invalid = profile;
        invalid.short_id = "abc".into();
        assert_eq!(invalid.validate(), Err(FrameError::InvalidProfile));
    }

    #[test]
    fn rejects_malformed_oversized_and_unknown_frames() {
        assert_eq!(decode_request(&[0; 11]), Err(FrameError::TooShort));
        assert_eq!(
            decode_request(&vec![0; MAX_FRAME_SIZE + 1]),
            Err(FrameError::TooLarge)
        );
        let mut frame = encode_request(&connect()).expect("valid request");
        frame[0] = b'X';
        assert_eq!(decode_request(&frame), Err(FrameError::InvalidMagic));
        let mut frame = encode_request(&connect()).expect("valid request");
        frame[6] = 99;
        assert_eq!(decode_request(&frame), Err(FrameError::UnknownOperation));

        let mut header = encode_request(&connect()).expect("valid request")[..12].to_vec();
        header[8..12].copy_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(declared_frame_size(&header), Err(FrameError::TooLarge));
    }

    #[test]
    fn identifiers_cannot_smuggle_paths_or_commands() {
        for value in [
            "../profile",
            "C:\\profile",
            "profile;whoami",
            "profile name",
        ] {
            let mut request = connect();
            if let ControlCommand::Connect(connect) = &mut request.command {
                connect.profile_id = value.into();
            }
            assert_eq!(encode_request(&request), Err(FrameError::InvalidIdentifier));
        }
    }

    #[test]
    fn response_round_trip_contains_only_typed_safe_fields() {
        let response = ResponseEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: "request-1".into(),
            phase: ConnectionPhase::Error,
            profile_id: Some("profile-1".into()),
            kill_switch_active: false,
            code: "ENGINE_NOT_INSTALLED".into(),
            statistics: Some(TunnelStatistics {
                bytes_received: 1024,
                bytes_sent: 2048,
                last_handshake_unix_ms: Some(1_700_000_000_000),
            }),
        };
        let encoded = encode_response(&response).expect("valid response");
        assert_eq!(decode_response(&encoded), Ok(response));
    }

    #[test]
    fn response_rejects_diagnostic_text_and_paths() {
        for code in ["access denied", "C:\\secret", "token=value"] {
            let response = ResponseEnvelope {
                contract_version: CONTRACT_VERSION,
                request_id: "request-1".into(),
                phase: ConnectionPhase::Error,
                profile_id: None,
                kill_switch_active: false,
                code: code.into(),
                statistics: None,
            };
            assert_eq!(
                encode_response(&response),
                Err(FrameError::InvalidIdentifier)
            );
        }
    }

    #[test]
    fn profile_validation_rejects_routes_endpoints_and_empty_keepalive() {
        let mut profile = wireguard_profile();
        profile.allowed_ips = vec!["0.0.0.0/33".into()];
        assert_eq!(profile.validate(), Err(FrameError::InvalidProfile));

        let mut profile = wireguard_profile();
        profile.endpoint_host = "bad host;command".into();
        assert_eq!(profile.validate(), Err(FrameError::InvalidProfile));

        let mut profile = wireguard_profile();
        profile.persistent_keepalive = Some(0);
        assert_eq!(profile.validate(), Err(FrameError::InvalidProfile));

        let mut profile = wireguard_profile();
        profile.private_key = SecretKey([0; 32]);
        assert_eq!(profile.validate(), Err(FrameError::InvalidProfile));
    }

    #[test]
    fn secret_debug_output_is_always_redacted() {
        let profile = wireguard_profile();
        let rendered = format!("{profile:?}");
        assert!(rendered.contains("[REDACTED]"));
        assert!(!rendered.contains("7, 7, 7"));
        assert!(!rendered.contains("11, 11, 11"));
    }
}
