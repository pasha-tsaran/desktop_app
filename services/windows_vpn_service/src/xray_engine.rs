use std::{
    ffi::c_void,
    fmt::Write as _,
    fs,
    io::{self, Write},
    mem::size_of,
    os::windows::{io::AsRawHandle, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    ptr, thread,
    time::{Duration, Instant},
};

use sha2::{Digest, Sha256};
use vpn_contracts::{TunnelStatistics, VlessRealityProfile, WireGuardProfile};
use vpn_service_core::{BackendFailure, VpnBackend};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE, STILL_ACTIVE},
    NetworkManagement::{
        IpHelper::{ConvertInterfaceAliasToLuid, GetBestInterfaceEx, GetIfEntry2, MIB_IF_ROW2},
        Ndis::{IfOperStatusUp, NET_LUID_LH},
    },
    Networking::WinSock::{
        AF_INET, AF_INET6, IN6_ADDR, IN6_ADDR_0, IN_ADDR, IN_ADDR_0, IN_ADDR_0_0, SOCKADDR,
        SOCKADDR_IN, SOCKADDR_IN6, SOCKADDR_IN6_0, SOCKADDR_INET,
    },
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Threading::GetExitCodeProcess,
    },
};
use zeroize::Zeroizing;

use super::profile_vault::apply_service_acl;
use super::xray_dns_guard::DnsGuard;
use super::xray_network_policy::{reality_fingerprint, IpMode, Ipv6Guard};

const XRAY_SHA256: &str = "6b5cd540e3f4ce59f309863f0f1339b0bda13aeb9451405abfca29ba873cca20";
// The installed 1.1.8 / UI-only 2.1.10 payload is also explicitly pinned.
// System-feature updates can preserve that exact working engine binary.
const XRAY_BASELINE_SHA256: &str =
    "0d0fc0ea2b05641acb78c01fc36ad694e7b029861b2d5eb93da0e3e9fda9a98f";
const WINTUN_SHA256: &str = "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const START_GRACE: Duration = Duration::from_millis(750);
const ROUTE_READY_TIMEOUT: Duration = Duration::from_secs(18);
const TUN_NAME: &str = "KenaiXray";

#[derive(Debug)]
struct KillOnCloseJob(HANDLE);

impl KillOnCloseJob {
    fn create() -> Result<Self, BackendFailure> {
        // SAFETY: no security attributes or global name are supplied.
        let handle = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
        if handle.is_null() {
            return Err(BackendFailure::Internal);
        }
        let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let length = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
            .map_err(|_| BackendFailure::Internal)?;
        // SAFETY: `information` is initialized and valid for `length` bytes.
        let configured = unsafe {
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                ptr::from_ref(&information).cast::<c_void>(),
                length,
            )
        };
        if configured == 0 {
            // SAFETY: `handle` is owned and closed exactly once on this path.
            unsafe { CloseHandle(handle) };
            return Err(BackendFailure::Internal);
        }
        Ok(Self(handle))
    }

    fn assign(&self, child: &Child) -> Result<(), BackendFailure> {
        let process = child.as_raw_handle().cast::<c_void>();
        // SAFETY: both handles are live for the duration of this call.
        if unsafe { AssignProcessToJobObject(self.0, process) } == 0 {
            return Err(BackendFailure::Internal);
        }
        Ok(())
    }

    fn terminate(&self) -> Result<(), BackendFailure> {
        // SAFETY: the job handle remains owned by `self`.
        if unsafe { TerminateJobObject(self.0, 1) } == 0 {
            Err(BackendFailure::Internal)
        } else {
            Ok(())
        }
    }
}

impl Drop for KillOnCloseJob {
    fn drop(&mut self) {
        // Closing the last job handle is the crash-recovery boundary: every
        // assigned Xray process is terminated by the kernel.
        unsafe { CloseHandle(self.0) };
    }
}

#[derive(Debug)]
struct XrayProcess {
    child: Child,
    job: KillOnCloseJob,
}

impl XrayProcess {
    fn is_running(&self) -> Result<bool, BackendFailure> {
        let mut code = 0_u32;
        let handle = self.child.as_raw_handle().cast::<c_void>();
        // SAFETY: the child owns a live process handle and `code` is writable.
        if unsafe { GetExitCodeProcess(handle, ptr::addr_of_mut!(code)) } == 0 {
            return Err(BackendFailure::Internal);
        }
        Ok(code == STILL_ACTIVE as u32)
    }

    fn stop(mut self) -> Result<(), BackendFailure> {
        if self.job.terminate().is_err() {
            self.child.kill().map_err(|_| BackendFailure::Internal)?;
        }
        self.child.wait().map_err(|_| BackendFailure::Internal)?;
        Ok(())
    }
}

#[derive(Debug)]
pub struct XrayWindowsBackend {
    executable: PathBuf,
    runtime_root: PathBuf,
    config_path: PathBuf,
    process: Option<XrayProcess>,
    counter_baseline: Option<(u64, u64)>,
    ip_mode: IpMode,
    ipv6_guard: Option<Ipv6Guard>,
    dns_guard: Option<DnsGuard>,
}

impl XrayWindowsBackend {
    pub fn system_default() -> io::Result<Self> {
        let executable = super::executable_path::current_executable()?;
        let program_data = std::env::var_os("ProgramData")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "ProgramData unavailable"))?;
        let runtime_root = PathBuf::from(program_data).join("KenaiVPN").join("runtime");
        fs::create_dir_all(&runtime_root)?;
        apply_service_acl(&runtime_root)?;
        let config_path = runtime_root.join("KenaiXray.json");
        remove_if_present(&config_path).map_err(|_| io::Error::other("Xray cleanup failed"))?;
        Ok(Self {
            executable,
            runtime_root,
            config_path,
            process: None,
            counter_baseline: None,
            ip_mode: IpMode::DualStack,
            ipv6_guard: None,
            dns_guard: None,
        })
    }

    fn payload_root(&self) -> Result<PathBuf, BackendFailure> {
        self.executable
            .parent()
            .map(|root| root.join("xray").join("amd64"))
            .ok_or(BackendFailure::EngineUnavailable)
    }

    fn verify_payloads(&self) -> Result<(), BackendFailure> {
        let root = self.payload_root()?;
        verify_hash(&root.join("xray.exe"), XRAY_SHA256)
            .or_else(|_| verify_hash(&root.join("xray.exe"), XRAY_BASELINE_SHA256))?;
        verify_hash(&root.join("wintun.dll"), WINTUN_SHA256)
    }

    fn write_config(&self, profile: &VlessRealityProfile) -> Result<(), BackendFailure> {
        let temporary = self.runtime_root.join("KenaiXray.json.new");
        remove_if_present(&temporary)?;
        let rendered = render_config(profile, self.ip_mode);
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|_| BackendFailure::Internal)?;
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

    fn command(&self) -> Result<Command, BackendFailure> {
        let mut command = Command::new(self.payload_root()?.join("xray.exe"));
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW);
        Ok(command)
    }

    fn validate_config(&self) -> Result<(), BackendFailure> {
        super::command_wait::output(
            self.command()?
                .args(["run", "-test", "-config"])
                .arg(&self.config_path),
            Duration::from_secs(10),
        )
        .map(|_| ())
    }

    fn start(&mut self) -> Result<(), BackendFailure> {
        let job = KillOnCloseJob::create()?;
        let mut child = self
            .command()?
            .args(["run", "-config"])
            .arg(&self.config_path)
            .spawn()
            .map_err(|_| BackendFailure::EngineUnavailable)?;
        if let Err(error) = job.assign(&child) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
        thread::sleep(START_GRACE);
        if child
            .try_wait()
            .map_err(|_| BackendFailure::Internal)?
            .is_some()
        {
            return Err(BackendFailure::ServerUnavailable);
        }
        self.process = Some(XrayProcess { child, job });
        remove_if_present(&self.config_path)
    }

    fn cleanup(&mut self) -> Result<(), BackendFailure> {
        self.counter_baseline = None;
        let process_result = self.process.take().map_or(Ok(()), XrayProcess::stop);
        self.dns_guard = None;
        self.ipv6_guard = None;
        let config_result = remove_if_present(&self.config_path);
        let temporary_result = remove_if_present(&self.runtime_root.join("KenaiXray.json.new"));
        process_result.and(config_result).and(temporary_result)
    }

    fn await_routes(&mut self) -> Result<(), BackendFailure> {
        let deadline = Instant::now() + ROUTE_READY_TIMEOUT;
        loop {
            super::connection_cancel::check()?;
            if !self
                .process
                .as_ref()
                .is_some_and(|process| process.is_running().unwrap_or(false))
            {
                return Err(BackendFailure::RoutingUnavailable);
            }
            if let Ok(row) = tunnel_interface() {
                if routes_use_tunnel(
                    row.InterfaceIndex,
                    self.ip_mode,
                    self.ipv6_guard
                        .as_ref()
                        .is_some_and(Ipv6Guard::is_installed),
                ) {
                    // Do not report connected until DNS on non-tunnel interfaces
                    // is blocked. DNS settings on physical adapters are untouched.
                    self.dns_guard = Some(DnsGuard::acquire(unsafe { row.InterfaceLuid.Value })?);
                    self.counter_baseline = Some((row.InOctets, row.OutOctets));
                    return Ok(());
                }
            }
            if Instant::now() >= deadline {
                return Err(BackendFailure::RoutingUnavailable);
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}

fn tunnel_interface() -> Result<MIB_IF_ROW2, BackendFailure> {
    let alias: Vec<u16> = TUN_NAME.encode_utf16().chain(std::iter::once(0)).collect();
    let mut luid = NET_LUID_LH::default();
    // SAFETY: alias is NUL-terminated and luid is a writable output parameter.
    if unsafe { ConvertInterfaceAliasToLuid(alias.as_ptr(), &raw mut luid) } != 0 {
        return Err(BackendFailure::RoutingUnavailable);
    }
    let mut row = MIB_IF_ROW2 {
        InterfaceLuid: luid,
        ..Default::default()
    };
    // SAFETY: row has a valid interface LUID and remains writable for the call.
    if unsafe { GetIfEntry2(&raw mut row) } != 0 || row.OperStatus != IfOperStatusUp {
        return Err(BackendFailure::RoutingUnavailable);
    }
    Ok(row)
}

fn best_interface(address: &SOCKADDR_INET) -> Option<u32> {
    let mut index = 0_u32;
    // SAFETY: SOCKADDR_INET begins with a SOCKADDR-compatible address family;
    // both input and output pointers remain valid for the synchronous call.
    let result =
        unsafe { GetBestInterfaceEx(ptr::from_ref(address).cast::<SOCKADDR>(), &raw mut index) };
    (result == 0).then_some(index)
}

fn routes_use_tunnel(index: u32, mode: IpMode, guarded: bool) -> bool {
    let ipv4 = SOCKADDR_INET {
        Ipv4: SOCKADDR_IN {
            sin_family: AF_INET,
            sin_port: 0,
            sin_addr: IN_ADDR {
                S_un: IN_ADDR_0 {
                    S_un_b: IN_ADDR_0_0 {
                        s_b1: 1,
                        s_b2: 1,
                        s_b3: 1,
                        s_b4: 1,
                    },
                },
            },
            sin_zero: [0; 8],
        },
    };
    let ipv6 = SOCKADDR_INET {
        Ipv6: SOCKADDR_IN6 {
            sin6_family: AF_INET6,
            sin6_port: 0,
            sin6_flowinfo: 0,
            sin6_addr: IN6_ADDR {
                u: IN6_ADDR_0 {
                    Byte: std::net::Ipv6Addr::new(0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111)
                        .octets(),
                },
            },
            Anonymous: SOCKADDR_IN6_0::default(),
        },
    };
    mode.routes_ready(index, best_interface(&ipv4), best_interface(&ipv6), guarded)
}

impl VpnBackend for XrayWindowsBackend {
    fn connect(
        &mut self,
        _id: &str,
        _profile: &WireGuardProfile,
        _kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        Err(BackendFailure::UnsupportedFeature)
    }
    fn connect_vless(
        &mut self,
        _id: &str,
        profile: &VlessRealityProfile,
        kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        if kill_switch {
            return Err(BackendFailure::UnsupportedFeature);
        }
        profile
            .validate()
            .map_err(|_| BackendFailure::InvalidProfile)?;
        self.cleanup()?;
        self.verify_payloads()?;
        // The current Armenia exit has no working IPv6 route. Keep this an
        // explicit server capability decision: omit IPv6 from Xray and block
        // non-loopback IPv6 only for this VPN session so it cannot escape on a
        // physical adapter. Switch to DualStack only after exit IPv6 is live.
        self.ip_mode = IpMode::Ipv4Only;
        self.ipv6_guard = Some(Ipv6Guard::acquire()?);
        if let Err(error) = self
            .write_config(profile)
            .and_then(|()| self.validate_config())
            .and_then(|()| self.start())
            .and_then(|()| self.await_routes())
            .and_then(|()| super::data_plane_probe::verify_ipv4_round_trip())
        {
            let _ = self.cleanup();
            return Err(error);
        }
        Ok(())
    }
    fn disconnect(&mut self) -> Result<(), BackendFailure> {
        self.cleanup()
    }
    fn is_connected(&self) -> Result<bool, BackendFailure> {
        let running = self
            .process
            .as_ref()
            .map_or(Ok(false), XrayProcess::is_running)?;
        if !running {
            return Ok(false);
        }
        if !self.dns_guard.as_ref().is_some_and(DnsGuard::is_installed) {
            return Err(BackendFailure::RoutingUnavailable);
        }
        let row = tunnel_interface()?;
        if !routes_use_tunnel(
            row.InterfaceIndex,
            self.ip_mode,
            self.ipv6_guard
                .as_ref()
                .is_some_and(Ipv6Guard::is_installed),
        ) {
            return Err(BackendFailure::RoutingUnavailable);
        }
        Ok(true)
    }
    fn statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
        if !self.is_connected()? {
            return Err(BackendFailure::EngineUnavailable);
        }
        let row = tunnel_interface()?;
        let (initial_received, initial_sent) = self.counter_baseline.unwrap_or((0, 0));
        Ok(TunnelStatistics {
            bytes_received: row.InOctets.saturating_sub(initial_received),
            bytes_sent: row.OutOctets.saturating_sub(initial_sent),
            last_handshake_unix_ms: None,
        })
    }
}

impl Drop for XrayWindowsBackend {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}

fn render_config(profile: &VlessRealityProfile, mode: IpMode) -> Zeroizing<String> {
    let mut config = Zeroizing::new(String::new());
    let fingerprint = reality_fingerprint(
        &profile.endpoint_host,
        profile.endpoint_port,
        &profile.fingerprint,
    );
    let _ = write!(config,
        "{{\"log\":{{\"loglevel\":\"none\"}},\"inbounds\":[{{\"tag\":\"kenai-tun\",\"protocol\":\"tun\",\"settings\":{{\"name\":\"KenaiXray\",\"desc\":\"Kenai VPN Xray\",\"mtu\":1500,\"gateway\":[\"10.254.0.1/30\",\"fd00:6b65:6e61:69::1/126\"],\"dns\":[\"1.1.1.1\",\"2606:4700:4700::1111\"],\"autoSystemRoutingTable\":[\"0.0.0.0/0\",\"::/0\"],\"autoOutboundsInterface\":\"auto\"}}}}],\"outbounds\":[{{\"tag\":\"proxy\",\"protocol\":\"vless\",\"settings\":{{\"address\":\"{}\",\"port\":{},\"id\":\"{}\",\"encryption\":\"none\",\"flow\":\"xtls-rprx-vision\"}},\"streamSettings\":{{\"network\":\"raw\",\"security\":\"reality\",\"realitySettings\":{{\"serverName\":\"{}\",\"fingerprint\":\"{}\",\"password\":\"{}\",\"shortId\":\"{}\",\"spiderX\":\"/\"}}}}}}]}}",
        profile.endpoint_host, profile.endpoint_port, profile.client_id, profile.server_name,
        fingerprint, profile.reality_password, profile.short_id);
    // DNS transport must not require an IPv6-capable exit. IPv4 resolvers
    // still answer both A and AAAA queries. Keep the IPv6 tunnel route intact
    // in dual-stack mode so this fix cannot send IPv6 onto the physical NIC.
    config = Zeroizing::new(config.replace(
        "\"dns\":[\"1.1.1.1\",\"2606:4700:4700::1111\"]",
        "\"dns\":[\"1.1.1.1\",\"1.0.0.1\"]",
    ));
    if mode == IpMode::Ipv4Only {
        // Fixed literals only; the pinned Kenai Xray patch skips an entirely
        // unconfigured IP family instead of opening its Windows interface.
        for literal in [",\"fd00:6b65:6e61:69::1/126\"", ",\"::/0\""] {
            let next = Zeroizing::new(config.replace(literal, ""));
            config = next;
        }
    }
    config
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

#[cfg(test)]
mod tests {
    use super::*;
    fn profile() -> VlessRealityProfile {
        let groups = [8_usize, 4, 4, 4, 12];
        let client_id = groups
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
    fn rendered_config_is_a_full_tun_and_never_enables_logs() {
        let config = render_config(&profile(), IpMode::DualStack);
        assert!(config.contains("\"protocol\":\"tun\""));
        assert!(config.contains("\"autoSystemRoutingTable\":[\"0.0.0.0/0\",\"::/0\"]"));
        assert!(config.contains("\"security\":\"reality\""));
        assert!(config.contains("\"loglevel\":\"none\""));
    }
    #[test]
    fn existing_netherlands_profile_uses_compatible_handshake_without_reimport() {
        let mut nl = profile();
        nl.endpoint_host = "147.45.231.194".into();
        let config = render_config(&nl, IpMode::Ipv4Only);
        assert!(config.contains("\"fingerprint\":\"firefox\""));
        assert!(config.contains("\"address\":\"147.45.231.194\""));
        assert!(config.contains("\"loglevel\":\"none\""));
        assert_eq!(nl.fingerprint, "chrome", "stored profile stays unchanged");
        nl.endpoint_host = "88.218.94.3".into();
        let armenia = render_config(&nl, IpMode::Ipv4Only);
        assert!(armenia.contains("\"fingerprint\":\"chrome\""));
    }
    #[test]
    fn committed_payload_hashes_match() {
        let root = super::super::test_payload_root("xray");
        verify_hash(&root.join("xray.exe"), XRAY_SHA256).expect("xray");
        verify_hash(&root.join("wintun.dll"), WINTUN_SHA256).expect("wintun");
    }

    #[test]
    fn ipv4_config_omits_ipv6_setup_but_keeps_reality_and_dns() {
        let config = render_config(&profile(), IpMode::Ipv4Only);
        assert!(config.contains("\"gateway\":[\"10.254.0.1/30\"]"));
        assert!(config.contains("\"dns\":[\"1.1.1.1\",\"1.0.0.1\"]"));
        assert!(config.contains("\"autoSystemRoutingTable\":[\"0.0.0.0/0\"]"));
        assert!(!config.contains("fd00:"));
        assert!(!config.contains("2606:"));
        assert!(!config.contains("::/0"));
        assert!(config.contains("\"security\":\"reality\""));
        assert!(config.contains("\"autoOutboundsInterface\":\"auto\""));
    }

    #[test]
    fn dns_transport_is_ipv4_in_both_modes_without_dropping_ipv6_capture() {
        for mode in [IpMode::DualStack, IpMode::Ipv4Only] {
            let config = render_config(&profile(), mode);
            assert!(config.contains("\"dns\":[\"1.1.1.1\",\"1.0.0.1\"]"));
            assert!(!config.contains("2606:4700:4700::1111"));
            assert_eq!(config.contains("::/0"), mode == IpMode::DualStack);
            assert_eq!(config.contains("fd00:"), mode == IpMode::DualStack);
        }
    }

    #[test]
    #[ignore = "Xray TUN validation opens Wintun and requires an elevated Windows token"]
    fn pinned_xray_accepts_rendered_configuration() {
        let root = super::super::test_payload_root("xray");
        let config_path = std::env::temp_dir().join(format!(
            "kenai-xray-config-test-{}.json",
            std::process::id()
        ));
        fs::write(
            &config_path,
            render_config(&profile(), IpMode::DualStack).as_bytes(),
        )
        .expect("write config");
        let result = Command::new(root.join("xray.exe"))
            .args(["run", "-test", "-config"])
            .arg(&config_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .status();
        let _ = fs::remove_file(config_path);
        assert!(result.expect("run pinned Xray").success());
    }
}
