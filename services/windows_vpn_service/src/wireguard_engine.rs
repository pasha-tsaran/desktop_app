use std::fmt::Write as _;
use std::{
    ffi::{c_void, OsString},
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use sha2::{Digest, Sha256};
use vpn_contracts::{TunnelStatistics, WireGuardProfile};
use vpn_service_core::{BackendFailure, VpnBackend};
use windows_service::{
    service::{
        ServiceAccess, ServiceDependency, ServiceErrorControl, ServiceInfo, ServiceSidType,
        ServiceStartType, ServiceState, ServiceType,
    },
    service_manager::{ServiceManager, ServiceManagerAccess},
};
use windows_sys::Win32::Foundation::FreeLibrary;
use windows_sys::Win32::System::LibraryLoader::{
    GetProcAddress, LoadLibraryExW, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS,
    LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR,
};
use zeroize::Zeroizing;

use super::profile_vault::apply_service_acl;

const TUNNEL_NAME: &str = "KenaiMvp";
const SERVICE_NAME: &str = "WireGuardTunnel$KenaiMvp";
const TUNNEL_SHA256: &str = "5533cf9cb741d5e9daa7f429aa1c56beba4a500934877c9d072f721f512583ca";
const DRIVER_SHA256: &str = "b1b85e072c45d81358be29d94c599dc76652f912be8c0f0a41e2d5d89a6461d3";
const START_TIMEOUT: Duration = Duration::from_secs(30);
const STOP_TIMEOUT: Duration = Duration::from_secs(30);
type OpenAdapter = unsafe extern "system" fn(*const u16) -> *mut c_void;
type CloseAdapter = unsafe extern "system" fn(*mut c_void);
type GetConfiguration = unsafe extern "system" fn(*mut c_void, *mut u8, *mut u32) -> i32;
type TunnelService = unsafe extern "C" fn(*const u16) -> i32;

#[derive(Debug)]
pub struct WireGuardWindowsBackend {
    executable: PathBuf,
    runtime_root: PathBuf,
    config_path: PathBuf,
}

impl WireGuardWindowsBackend {
    pub fn system_default() -> io::Result<Self> {
        let executable = std::env::current_exe()?;
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
            .map_err(|_| io::Error::other("WireGuard cleanup failed"))?;
        Ok(backend)
    }

    fn payload_root(&self) -> Result<PathBuf, BackendFailure> {
        self.executable
            .parent()
            .map(|parent| parent.join("wireguard").join("amd64"))
            .ok_or(BackendFailure::EngineUnavailable)
    }

    fn verify_payloads(&self) -> Result<(), BackendFailure> {
        let root = self.payload_root()?;
        verify_hash(&root.join("tunnel.dll"), TUNNEL_SHA256)?;
        verify_hash(&root.join("wireguard.dll"), DRIVER_SHA256)
    }

    fn write_config(&self, profile: &WireGuardProfile) -> Result<(), BackendFailure> {
        let temporary = self.runtime_root.join(format!("{TUNNEL_NAME}.conf.new"));
        let _ = fs::remove_file(&temporary);
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|_| BackendFailure::Internal)?;
        let rendered = render_config(profile);
        let result = file
            .write_all(rendered.as_bytes())
            .and_then(|()| file.sync_all());
        drop(file);
        if result.is_err() {
            let _ = fs::remove_file(temporary);
            return Err(BackendFailure::Internal);
        }
        fs::rename(&temporary, &self.config_path).map_err(|_| BackendFailure::Internal)
    }

    fn create_and_start_service(&self) -> Result<(), BackendFailure> {
        let manager = ServiceManager::local_computer(
            None::<&str>,
            ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE,
        )
        .map_err(|_| BackendFailure::EngineUnavailable)?;
        let info = ServiceInfo {
            name: OsString::from(SERVICE_NAME),
            display_name: OsString::from("Kenai VPN WireGuard tunnel"),
            service_type: ServiceType::OWN_PROCESS,
            start_type: ServiceStartType::OnDemand,
            error_control: ServiceErrorControl::Normal,
            executable_path: self.executable.clone(),
            launch_arguments: vec![
                OsString::from("/wireguard-service"),
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
        wait_for_state(&service, ServiceState::Running, START_TIMEOUT)
            .map_err(|_| BackendFailure::ServerUnavailable)?;
        fs::remove_file(&self.config_path).map_err(|_| BackendFailure::Internal)
    }

    fn cleanup_stale(&self) -> Result<(), BackendFailure> {
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|_| BackendFailure::EngineUnavailable)?;
        if let Ok(service) = manager.open_service(SERVICE_NAME, ServiceAccess::ALL_ACCESS) {
            let state = service
                .query_status()
                .map_err(|_| BackendFailure::Internal)?
                .current_state;
            if state != ServiceState::Stopped {
                service.stop().map_err(|_| BackendFailure::Internal)?;
                wait_for_state(&service, ServiceState::Stopped, STOP_TIMEOUT)
                    .map_err(|_| BackendFailure::Internal)?;
            }
            service.delete().map_err(|_| BackendFailure::Internal)?;
        }
        remove_if_present(&self.config_path)?;
        remove_if_present(&self.runtime_root.join(format!("{TUNNEL_NAME}.conf.new")))
    }
}

impl VpnBackend for WireGuardWindowsBackend {
    fn connect(
        &mut self,
        _profile_id: &str,
        profile: &WireGuardProfile,
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
        if let Err(error) = self.create_and_start_service() {
            let _ = self.cleanup_stale();
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
        let status = service
            .query_status()
            .map_err(|_| BackendFailure::Internal)?;
        Ok(status.current_state == ServiceState::Running)
    }

    fn statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
        self.read_statistics()
    }
}

impl WireGuardWindowsBackend {
    fn read_statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
        self.verify_payloads()?;
        let driver_path = self.payload_root()?.join("wireguard.dll");
        let wide_driver = to_wide(&driver_path.to_string_lossy());
        // SAFETY: the fixed absolute DLL path is NUL terminated and verified.
        let library = unsafe {
            LoadLibraryExW(
                wide_driver.as_ptr(),
                std::ptr::null_mut(),
                LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS,
            )
        };
        if library.is_null() {
            return Err(BackendFailure::EngineUnavailable);
        }
        let open_symbol =
            unsafe { GetProcAddress(library, c"WireGuardOpenAdapter".as_ptr().cast()) };
        let close_symbol =
            unsafe { GetProcAddress(library, c"WireGuardCloseAdapter".as_ptr().cast()) };
        let get_symbol =
            unsafe { GetProcAddress(library, c"WireGuardGetConfiguration".as_ptr().cast()) };
        let (Some(open_symbol), Some(close_symbol), Some(get_symbol)) =
            (open_symbol, close_symbol, get_symbol)
        else {
            unsafe { FreeLibrary(library) };
            return Err(BackendFailure::EngineUnavailable);
        };
        // SAFETY: names and ABI are pinned to the official WireGuardNT 1.1 API.
        let open: OpenAdapter = unsafe { std::mem::transmute(open_symbol) };
        let close: CloseAdapter = unsafe { std::mem::transmute(close_symbol) };
        let get: GetConfiguration = unsafe { std::mem::transmute(get_symbol) };
        let adapter_name = to_wide(TUNNEL_NAME);
        // SAFETY: the function signatures match the pinned `wireguard.h` API.
        let adapter = unsafe { open(adapter_name.as_ptr()) };
        if adapter.is_null() {
            unsafe { FreeLibrary(library) };
            return Err(BackendFailure::EngineUnavailable);
        }
        let mut buffer = vec![0_u8; 512];
        let read_result = loop {
            let mut size = u32::try_from(buffer.len()).map_err(|_| BackendFailure::Internal)?;
            // SAFETY: `buffer` is writable for `size`; adapter is live.
            if unsafe { get(adapter, buffer.as_mut_ptr(), std::ptr::addr_of_mut!(size)) } != 0 {
                buffer.truncate(size as usize);
                break parse_statistics(&buffer);
            }
            let required = size as usize;
            if required <= buffer.len() || required > 64 * 1024 {
                break Err(BackendFailure::Internal);
            }
            buffer.resize(required, 0);
        };
        // SAFETY: both handles were obtained above and are released once.
        unsafe {
            close(adapter);
            FreeLibrary(library);
        }
        read_result
    }
}

pub fn run_tunnel_service(config_path: &Path) -> io::Result<()> {
    let executable = std::env::current_exe()?;
    let executable_root = executable
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "executable root unavailable"))?;
    let runtime_root = PathBuf::from(
        std::env::var_os("ProgramData")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "ProgramData unavailable"))?,
    )
    .join("KenaiVPN")
    .join("runtime");
    let expected = runtime_root.join(format!("{TUNNEL_NAME}.conf"));
    if config_path != expected
        || config_path.extension().and_then(|value| value.to_str()) != Some("conf")
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "invalid tunnel profile path",
        ));
    }
    let payload_root = executable_root.join("wireguard").join("amd64");
    let tunnel_path = payload_root.join("tunnel.dll");
    verify_hash(&tunnel_path, TUNNEL_SHA256)
        .map_err(|_| io::Error::other("invalid tunnel payload"))?;
    verify_hash(&payload_root.join("wireguard.dll"), DRIVER_SHA256)
        .map_err(|_| io::Error::other("invalid driver payload"))?;
    let wide_library = to_wide(&tunnel_path.to_string_lossy());
    // SAFETY: the absolute NUL-terminated path is valid for the call. Search
    // flags restrict dependency resolution to trusted/default directories.
    let library = unsafe {
        LoadLibraryExW(
            wide_library.as_ptr(),
            std::ptr::null_mut(),
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS,
        )
    };
    if library.is_null() {
        return Err(io::Error::last_os_error());
    }
    let symbol = unsafe { GetProcAddress(library, c"WireGuardTunnelService".as_ptr().cast()) };
    let Some(symbol) = symbol else {
        unsafe { FreeLibrary(library) };
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "tunnel entrypoint unavailable",
        ));
    };
    // SAFETY: upstream exports this exact cdecl signature.
    let tunnel: TunnelService = unsafe { std::mem::transmute(symbol) };
    let wide_config = to_wide(&config_path.to_string_lossy());
    let result = unsafe { tunnel(wide_config.as_ptr()) };
    unsafe { FreeLibrary(library) };
    if result == 0 {
        Err(io::Error::other("tunnel service failed"))
    } else {
        Ok(())
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

fn verify_hash(path: &Path, expected: &str) -> Result<(), BackendFailure> {
    let bytes = fs::read(path).map_err(|_| BackendFailure::EngineUnavailable)?;
    let actual = format!("{:x}", Sha256::digest(bytes));
    if actual == expected {
        Ok(())
    } else {
        Err(BackendFailure::EngineUnavailable)
    }
}

fn remove_if_present(path: &Path) -> Result<(), BackendFailure> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(BackendFailure::Internal),
    }
}

fn parse_statistics(buffer: &[u8]) -> Result<TunnelStatistics, BackendFailure> {
    const INTERFACE_SIZE: usize = 80;
    const PEER_SIZE: usize = 136;
    const PEER_TX_OFFSET: usize = 104;
    const PEER_RX_OFFSET: usize = 112;
    const PEER_HANDSHAKE_OFFSET: usize = 120;
    if buffer.len() < INTERFACE_SIZE || read_u32(buffer, 72)? != 1 {
        return Err(BackendFailure::InvalidProfile);
    }
    let peer = buffer
        .get(INTERFACE_SIZE..INTERFACE_SIZE + PEER_SIZE)
        .ok_or(BackendFailure::Internal)?;
    let handshake_filetime = read_u64(peer, PEER_HANDSHAKE_OFFSET)?;
    let last_handshake_unix_ms = if handshake_filetime == 0 {
        None
    } else {
        const WINDOWS_TO_UNIX_MILLIS: u64 = 11_644_473_600_000;
        let millis = handshake_filetime / 10_000;
        Some(
            i64::try_from(millis.saturating_sub(WINDOWS_TO_UNIX_MILLIS))
                .map_err(|_| BackendFailure::Internal)?,
        )
    };
    Ok(TunnelStatistics {
        bytes_received: read_u64(peer, PEER_RX_OFFSET)?,
        bytes_sent: read_u64(peer, PEER_TX_OFFSET)?,
        last_handshake_unix_ms,
    })
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, BackendFailure> {
    let end = offset.checked_add(4).ok_or(BackendFailure::Internal)?;
    let value = bytes
        .get(offset..end)
        .ok_or(BackendFailure::Internal)?
        .try_into()
        .map_err(|_| BackendFailure::Internal)?;
    Ok(u32::from_le_bytes(value))
}

fn read_u64(bytes: &[u8], offset: usize) -> Result<u64, BackendFailure> {
    let end = offset.checked_add(8).ok_or(BackendFailure::Internal)?;
    let value = bytes
        .get(offset..end)
        .ok_or(BackendFailure::Internal)?
        .try_into()
        .map_err(|_| BackendFailure::Internal)?;
    Ok(u64::from_le_bytes(value))
}

fn render_config(profile: &WireGuardProfile) -> Zeroizing<String> {
    let endpoint = if profile.endpoint_host.contains(':') {
        format!("[{}]", profile.endpoint_host)
    } else {
        profile.endpoint_host.clone()
    };
    let private_key = Zeroizing::new(STANDARD.encode(profile.private_key.0));
    let mut config = Zeroizing::new(String::new());
    let _ = write!(
        config,
        "[Interface]\r\nPrivateKey = {}\r\nAddress = {}\r\n",
        private_key.as_str(),
        profile.addresses.join(", ")
    );
    if !profile.dns_servers.is_empty() {
        let _ = write!(
            config,
            "DNS = {}\r\n",
            profile
                .dns_servers
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    let _ = write!(
        config,
        "\r\n[Peer]\r\nPublicKey = {}\r\n",
        STANDARD.encode(profile.peer_public_key.0)
    );
    if let Some(key) = &profile.preshared_key {
        let preshared_key = Zeroizing::new(STANDARD.encode(key.0));
        let _ = writeln!(config, "PresharedKey = {}\r", preshared_key.as_str());
    }
    let _ = write!(
        config,
        "Endpoint = {endpoint}:{}\r\nAllowedIPs = {}\r\n",
        profile.endpoint_port,
        profile.allowed_ips.join(", ")
    );
    if let Some(keepalive) = profile.persistent_keepalive {
        let _ = write!(config, "PersistentKeepalive = {keepalive}\r\n");
    }
    config
}

fn to_wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;
    use vpn_contracts::SecretKey;

    fn profile() -> WireGuardProfile {
        WireGuardProfile {
            private_key: SecretKey([7; 32]),
            addresses: vec!["10.0.0.2/32".into()],
            dns_servers: vec![IpAddr::from([1, 1, 1, 1])],
            peer_public_key: SecretKey([9; 32]),
            preshared_key: None,
            endpoint_host: "vpn.example.test".into(),
            endpoint_port: 51820,
            allowed_ips: vec!["0.0.0.0/0".into()],
            persistent_keepalive: Some(25),
        }
    }

    #[test]
    fn rendered_profile_contains_only_supported_wireguard_directives() {
        let rendered = render_config(&profile());
        assert!(rendered.contains("[Interface]"));
        assert!(rendered.contains("[Peer]"));
        assert!(rendered.contains("Endpoint = vpn.example.test:51820"));
        assert!(!rendered.contains("PostUp"));
        assert!(!rendered.contains("PreDown"));
    }

    #[test]
    fn committed_payload_hashes_match_the_pinned_manifest_when_present() {
        let root = super::super::test_payload_root("wireguard");
        verify_hash(&root.join("tunnel.dll"), TUNNEL_SHA256).expect("tunnel hash");
        verify_hash(&root.join("wireguard.dll"), DRIVER_SHA256).expect("driver hash");
    }

    #[test]
    fn parses_driver_counters_and_handshake_without_key_material() {
        let mut buffer = vec![0_u8; 80 + 136];
        buffer[72..76].copy_from_slice(&1_u32.to_le_bytes());
        buffer[184..192].copy_from_slice(&2048_u64.to_le_bytes());
        buffer[192..200].copy_from_slice(&4096_u64.to_le_bytes());
        let unix_millis = 1_700_000_000_000_u64;
        let filetime = (unix_millis + 11_644_473_600_000) * 10_000;
        buffer[200..208].copy_from_slice(&filetime.to_le_bytes());

        let statistics = parse_statistics(&buffer).expect("valid configuration");

        assert_eq!(statistics.bytes_sent, 2048);
        assert_eq!(statistics.bytes_received, 4096);
        assert_eq!(statistics.last_handshake_unix_ms, Some(1_700_000_000_000));
    }
}
