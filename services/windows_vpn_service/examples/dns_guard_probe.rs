// Operator-only probe, never installed as a service. Fixed interface and TTL.
#[cfg(windows)]
#[path = "../src/xray_dns_guard.rs"]
#[allow(unsafe_code)]
mod xray_dns_guard;

#[cfg(windows)]
#[allow(unsafe_code)]
fn main() -> Result<(), &'static str> {
    use std::{io::Write, thread, time::Duration};
    use windows_sys::{
        core::w,
        Win32::NetworkManagement::{
            IpHelper::{ConvertInterfaceAliasToLuid, GetIfEntry2, MIB_IF_ROW2},
            Ndis::{IfOperStatusUp, NET_LUID_LH},
        },
    };
    let mut luid = NET_LUID_LH::default();
    // SAFETY: fixed null-terminated name and initialized writable output.
    if unsafe { ConvertInterfaceAliasToLuid(w!("KenaiXray"), &raw mut luid) } != 0 {
        return Err("TUN_NOT_FOUND");
    }
    let mut row = MIB_IF_ROW2 {
        InterfaceLuid: luid,
        ..Default::default()
    };
    if unsafe { GetIfEntry2(&raw mut row) } != 0 || row.OperStatus != IfOperStatusUp {
        return Err("TUN_NOT_UP");
    }
    let guard = xray_dns_guard::DnsGuard::acquire(unsafe { luid.Value })
        .map_err(|_| "DNS_GUARD_INSTALL_FAILED")?;
    println!("DNS_GUARD_READY=True");
    std::io::stdout().flush().map_err(|_| "OUTPUT_FAILED")?;
    // Dynamic policy disappears even on process termination. This fixed TTL
    // is the independent recovery bound if the caller's script fails.
    thread::sleep(Duration::from_secs(45));
    drop(guard);
    println!("DNS_GUARD_SESSION_CLOSED=True");
    Ok(())
}

#[cfg(not(windows))]
fn main() {}
