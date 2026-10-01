use std::ptr;
use vpn_service_core::BackendFailure;
use windows_sys::{
    core::w,
    Win32::{
        Foundation::HANDLE,
        NetworkManagement::WindowsFilteringPlatform::{
            FwpmEngineClose0, FwpmEngineOpen0, FwpmFilterAdd0, FwpmFilterGetById0, FwpmFreeMemory0,
            FwpmSubLayerAdd0, FWPM_ACTION0, FWPM_CONDITION_FLAGS, FWPM_DISPLAY_DATA0, FWPM_FILTER0,
            FWPM_FILTER_CONDITION0, FWPM_LAYER_OUTBOUND_IPPACKET_V6, FWPM_SESSION0,
            FWPM_SESSION_FLAG_DYNAMIC, FWPM_SUBLAYER0, FWP_ACTION_BLOCK,
            FWP_CONDITION_FLAG_IS_LOOPBACK, FWP_CONDITION_VALUE0, FWP_CONDITION_VALUE0_0,
            FWP_MATCH_FLAGS_NONE_SET, FWP_UINT32,
        },
        System::Rpc::RPC_C_AUTHN_WINNT,
    },
};

/// Endpoint-scoped compatibility for already provisioned NL profiles. On the
/// tested direct path, Chrome handshakes stall under concurrent connections;
/// Firefox passes the same DNS/HTTPS workload with the same credentials.
/// Keep this decision outside profile storage so upgrades repair cached keys.
pub fn reality_fingerprint<'a>(endpoint: &str, port: u16, configured: &'a str) -> &'a str {
    if endpoint == "147.45.231.194" && port == 443 && configured == "chrome" {
        "firefox"
    } else {
        configured
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IpMode {
    DualStack,
    Ipv4Only,
}

impl IpMode {
    pub fn routes_ready(self, index: u32, v4: Option<u32>, v6: Option<u32>, guarded: bool) -> bool {
        v4 == Some(index)
            && match self {
                Self::DualStack => v6 == Some(index),
                Self::Ipv4Only => guarded,
            }
    }
}

/// Non-persistent IPv6 egress block for IPv4-only sessions. Acquire before
/// starting Xray, drop after stopping it. Never rewrites user network settings.
#[derive(Debug)]
pub struct Ipv6Guard {
    handle: HANDLE,
    filter_id: u64,
}

const GUARD_SUBLAYER: windows_sys::core::GUID =
    windows_sys::core::GUID::from_u128(0x45325912_96ef_4964_99d4_5ba5c911b703);

fn block_filter() -> FWPM_FILTER0 {
    FWPM_FILTER0 {
        displayData: FWPM_DISPLAY_DATA0 {
            name: w!("Kenai Xray IPv4-only IPv6 guard").cast_mut(),
            description: ptr::null_mut(),
        },
        layerKey: FWPM_LAYER_OUTBOUND_IPPACKET_V6,
        subLayerKey: GUARD_SUBLAYER,
        action: FWPM_ACTION0 {
            r#type: FWP_ACTION_BLOCK,
            ..Default::default()
        },
        ..Default::default()
    }
}
impl Ipv6Guard {
    pub fn acquire() -> Result<Self, BackendFailure> {
        let session = FWPM_SESSION0 {
            flags: FWPM_SESSION_FLAG_DYNAMIC,
            ..Default::default()
        };
        let mut handle = ptr::null_mut();
        // SAFETY: initialized session and valid output; local authenticated BFE.
        if unsafe {
            FwpmEngineOpen0(
                ptr::null(),
                RPC_C_AUTHN_WINNT,
                ptr::null(),
                &raw const session,
                &raw mut handle,
            )
        } != 0
        {
            return Err(BackendFailure::RoutingUnavailable);
        }
        let mut guard = Self {
            handle,
            filter_id: 0,
        };
        let sublayer = FWPM_SUBLAYER0 {
            subLayerKey: GUARD_SUBLAYER,
            displayData: block_filter().displayData,
            weight: u16::MAX,
            ..Default::default()
        };
        // SAFETY: initialized dynamic sublayer with process-lifetime strings.
        if unsafe { FwpmSubLayerAdd0(handle, &raw const sublayer, ptr::null_mut()) } != 0 {
            return Err(BackendFailure::RoutingUnavailable);
        }
        // Keep ::1 working. Block other IPv6 egress, including connections
        // established before this session and interfaces enabled later.
        let mut condition = FWPM_FILTER_CONDITION0 {
            fieldKey: FWPM_CONDITION_FLAGS,
            matchType: FWP_MATCH_FLAGS_NONE_SET,
            conditionValue: FWP_CONDITION_VALUE0 {
                r#type: FWP_UINT32,
                Anonymous: FWP_CONDITION_VALUE0_0 {
                    uint32: FWP_CONDITION_FLAG_IS_LOOPBACK,
                },
            },
        };
        let filter = FWPM_FILTER0 {
            numFilterConditions: 1,
            filterCondition: &raw mut condition,
            ..block_filter()
        };
        // SAFETY: nested pointers live throughout this synchronous call.
        if unsafe {
            FwpmFilterAdd0(
                guard.handle,
                &raw const filter,
                ptr::null_mut(),
                &raw mut guard.filter_id,
            )
        } != 0
        {
            return Err(BackendFailure::RoutingUnavailable);
        }
        Ok(guard)
    }

    pub fn is_installed(&self) -> bool {
        let mut filter = ptr::null_mut();
        // SAFETY: live engine handle and writable output; BFE allocates memory.
        if unsafe { FwpmFilterGetById0(self.handle, self.filter_id, &raw mut filter) } != 0 {
            return false;
        }
        if filter.is_null() {
            return false;
        }
        // SAFETY: successful GetById returned an initialized FWPM_FILTER0.
        let installed = unsafe { (*filter).action.r#type == FWP_ACTION_BLOCK };
        // SAFETY: release BFE-owned allocation with its matching allocator.
        unsafe {
            FwpmFreeMemory0(ptr::from_mut(&mut filter).cast());
        }
        installed
    }
}
impl Drop for Ipv6Guard {
    fn drop(&mut self) {
        // SAFETY: session owned and closed once. Windows also deletes its
        // dynamic filter on process termination; no persistent firewall edits.
        unsafe {
            FwpmEngineClose0(self.handle);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn handshake_compatibility_is_scoped_to_the_known_nl_endpoint() {
        assert_eq!(
            reality_fingerprint("147.45.231.194", 443, "chrome"),
            "firefox"
        );
        for endpoint in ["88.218.94.3", "147.45.231.195", "147.45.231.194.example"] {
            assert_eq!(reality_fingerprint(endpoint, 443, "chrome"), "chrome");
        }
        assert_eq!(
            reality_fingerprint("147.45.231.194", 8443, "chrome"),
            "chrome"
        );
        assert_eq!(
            reality_fingerprint("147.45.231.194", 443, "firefox"),
            "firefox"
        );
    }
    #[test]
    fn ipv4_only_requires_ipv6_guard_and_correct_ipv4_route() {
        assert!(!IpMode::Ipv4Only.routes_ready(4, Some(4), None, false));
        assert!(IpMode::Ipv4Only.routes_ready(4, Some(4), None, true));
        assert!(!IpMode::Ipv4Only.routes_ready(4, Some(5), None, true));
        assert!(!IpMode::Ipv4Only.routes_ready(4, None, None, true));
        assert!(IpMode::Ipv4Only.routes_ready(4, Some(4), Some(5), true));
    }
    #[test]
    fn dual_stack_still_requires_both_families_in_tunnel() {
        assert!(IpMode::DualStack.routes_ready(4, Some(4), Some(4), false));
        assert!(!IpMode::DualStack.routes_ready(4, Some(4), None, true));
        assert!(!IpMode::DualStack.routes_ready(4, Some(4), Some(5), true));
    }
    #[test]
    fn filter_blocks_ipv6_packets_and_is_not_persistent() {
        let filter = block_filter();
        assert_eq!(filter.action.r#type, FWP_ACTION_BLOCK);
        assert_eq!(filter.layerKey.data1, FWPM_LAYER_OUTBOUND_IPPACKET_V6.data1);
        assert_eq!(filter.layerKey.data4, FWPM_LAYER_OUTBOUND_IPPACKET_V6.data4);
        assert_eq!(filter.flags, 0);
    }

    #[test]
    #[ignore = "requires elevation; temporarily blocks non-loopback IPv6 egress"]
    fn native_guard_exists_only_while_dynamic_session_is_open() {
        let guard = Ipv6Guard::acquire().expect("install IPv6 guard");
        assert!(guard.is_installed());
        let id = guard.filter_id;
        drop(guard);
        let session = FWPM_SESSION0::default();
        let mut handle = ptr::null_mut();
        // SAFETY: readback uses a separate initialized local session.
        assert_eq!(
            unsafe {
                FwpmEngineOpen0(
                    ptr::null(),
                    RPC_C_AUTHN_WINNT,
                    ptr::null(),
                    &raw const session,
                    &raw mut handle,
                )
            },
            0
        );
        let mut filter = ptr::null_mut();
        let result = unsafe { FwpmFilterGetById0(handle, id, &raw mut filter) };
        if !filter.is_null() {
            unsafe {
                FwpmFreeMemory0(ptr::from_mut(&mut filter).cast());
            }
        }
        unsafe {
            FwpmEngineClose0(handle);
        }
        assert_ne!(result, 0, "filter must disappear on close");
    }
}
