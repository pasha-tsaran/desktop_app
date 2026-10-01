// Session-scoped DNS egress policy. This is not a general kill switch.
use std::ptr;
use vpn_service_core::BackendFailure;
use windows_sys::{
    core::{w, GUID},
    Win32::{
        Foundation::HANDLE,
        NetworkManagement::WindowsFilteringPlatform::{
            FwpmEngineClose0, FwpmEngineOpen0, FwpmFilterAdd0, FwpmFilterGetById0, FwpmFreeMemory0,
            FwpmSubLayerAdd0, FwpmTransactionAbort0, FwpmTransactionBegin0, FwpmTransactionCommit0,
            FWPM_ACTION0, FWPM_CONDITION_FLAGS, FWPM_CONDITION_IP_LOCAL_INTERFACE,
            FWPM_CONDITION_IP_REMOTE_PORT, FWPM_DISPLAY_DATA0, FWPM_FILTER0,
            FWPM_FILTER_CONDITION0, FWPM_LAYER_OUTBOUND_TRANSPORT_V4,
            FWPM_LAYER_OUTBOUND_TRANSPORT_V6, FWPM_SESSION0, FWPM_SESSION_FLAG_DYNAMIC,
            FWPM_SUBLAYER0, FWP_ACTION_BLOCK, FWP_CONDITION_FLAG_IS_LOOPBACK, FWP_CONDITION_VALUE0,
            FWP_CONDITION_VALUE0_0, FWP_MATCH_EQUAL, FWP_MATCH_FLAGS_NONE_SET, FWP_MATCH_NOT_EQUAL,
            FWP_UINT16, FWP_UINT32, FWP_UINT64,
        },
        System::Rpc::RPC_C_AUTHN_WINNT,
    },
};

const SUBLAYER: GUID = GUID::from_u128(0x913f5f52_317d_451b_980c_c392631e806a);
const PORTS: [u16; 2] = [53, 853];
const LAYERS: [GUID; 2] = [
    FWPM_LAYER_OUTBOUND_TRANSPORT_V4,
    FWPM_LAYER_OUTBOUND_TRANSPORT_V6,
];

#[derive(Debug)]
pub struct DnsGuard {
    engine: HANDLE,
    filters: Vec<u64>,
}

fn check(code: u32) -> Result<(), BackendFailure> {
    if code == 0 {
        Ok(())
    } else {
        Err(BackendFailure::RoutingUnavailable)
    }
}

fn conditions(luid: &mut u64, port: u16) -> [FWPM_FILTER_CONDITION0; 3] {
    [
        FWPM_FILTER_CONDITION0 {
            fieldKey: FWPM_CONDITION_IP_LOCAL_INTERFACE,
            matchType: FWP_MATCH_NOT_EQUAL,
            conditionValue: FWP_CONDITION_VALUE0 {
                r#type: FWP_UINT64,
                Anonymous: FWP_CONDITION_VALUE0_0 { uint64: luid },
            },
        },
        FWPM_FILTER_CONDITION0 {
            fieldKey: FWPM_CONDITION_IP_REMOTE_PORT,
            matchType: FWP_MATCH_EQUAL,
            conditionValue: FWP_CONDITION_VALUE0 {
                r#type: FWP_UINT16,
                Anonymous: FWP_CONDITION_VALUE0_0 { uint16: port },
            },
        },
        FWPM_FILTER_CONDITION0 {
            fieldKey: FWPM_CONDITION_FLAGS,
            matchType: FWP_MATCH_FLAGS_NONE_SET,
            conditionValue: FWP_CONDITION_VALUE0 {
                r#type: FWP_UINT32,
                Anonymous: FWP_CONDITION_VALUE0_0 {
                    uint32: FWP_CONDITION_FLAG_IS_LOOPBACK,
                },
            },
        },
    ]
}

impl DnsGuard {
    fn open() -> Result<Self, BackendFailure> {
        let session = FWPM_SESSION0 {
            flags: FWPM_SESSION_FLAG_DYNAMIC,
            ..Default::default()
        };
        let mut engine = ptr::null_mut();
        // SAFETY: initialized session, local authenticated BFE and writable output.
        check(unsafe {
            FwpmEngineOpen0(
                ptr::null(),
                RPC_C_AUTHN_WINNT,
                ptr::null(),
                &raw const session,
                &raw mut engine,
            )
        })?;
        Ok(Self {
            engine,
            filters: Vec::new(),
        })
    }

    pub fn acquire(luid: u64) -> Result<Self, BackendFailure> {
        if luid == 0 {
            return Err(BackendFailure::RoutingUnavailable);
        }
        let mut guard = Self::open()?;
        // Install atomically: no partial policy may classify packets.
        check(unsafe { FwpmTransactionBegin0(guard.engine, 0) })?;
        if let Err(error) = guard.add_filters(luid) {
            unsafe { FwpmTransactionAbort0(guard.engine) };
            return Err(error);
        }
        check(unsafe { FwpmTransactionCommit0(guard.engine) })?;
        if !guard.is_installed() {
            return Err(BackendFailure::RoutingUnavailable);
        }
        Ok(guard)
    }

    fn add_filters(&mut self, mut luid: u64) -> Result<(), BackendFailure> {
        let display = FWPM_DISPLAY_DATA0 {
            name: w!("Kenai VLESS session DNS guard").cast_mut(),
            description: ptr::null_mut(),
        };
        let sublayer = FWPM_SUBLAYER0 {
            subLayerKey: SUBLAYER,
            displayData: display,
            weight: u16::MAX,
            ..Default::default()
        };
        check(unsafe { FwpmSubLayerAdd0(self.engine, &raw const sublayer, ptr::null_mut()) })?;
        for layer in LAYERS {
            for port in PORTS {
                let mut predicates = conditions(&mut luid, port);
                let filter = FWPM_FILTER0 {
                    displayData: display,
                    layerKey: layer,
                    subLayerKey: SUBLAYER,
                    action: FWPM_ACTION0 {
                        r#type: FWP_ACTION_BLOCK,
                        ..Default::default()
                    },
                    numFilterConditions: 3,
                    filterCondition: predicates.as_mut_ptr(),
                    ..Default::default()
                };
                let mut id = 0;
                // SAFETY: every nested condition pointer is live for this call.
                check(unsafe {
                    FwpmFilterAdd0(self.engine, &raw const filter, ptr::null_mut(), &raw mut id)
                })?;
                self.filters.push(id);
            }
        }
        Ok(())
    }

    pub fn is_installed(&self) -> bool {
        self.filters.len() == LAYERS.len() * PORTS.len()
            && self.filters.iter().all(|id| {
                let mut filter = ptr::null_mut();
                let result = unsafe { FwpmFilterGetById0(self.engine, *id, &raw mut filter) };
                let valid = result == 0
                    && !filter.is_null()
                    && unsafe { (*filter).action.r#type == FWP_ACTION_BLOCK };
                if !filter.is_null() {
                    unsafe { FwpmFreeMemory0(ptr::from_mut(&mut filter).cast()) };
                }
                valid
            })
    }
}

impl Drop for DnsGuard {
    fn drop(&mut self) {
        // Closing the dynamic session also removes filters after a service crash.
        unsafe { FwpmEngineClose0(self.engine) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn guid_parts(guid: GUID) -> (u32, u16, u16, [u8; 8]) {
        (guid.data1, guid.data2, guid.data3, guid.data4)
    }

    #[test]
    fn policy_only_matches_dns_outside_tunnel_and_not_loopback() {
        let mut luid = 123;
        for port in PORTS {
            let c = conditions(&mut luid, port);
            assert_eq!(
                guid_parts(c[0].fieldKey),
                guid_parts(FWPM_CONDITION_IP_LOCAL_INTERFACE)
            );
            assert_eq!(c[0].matchType, FWP_MATCH_NOT_EQUAL);
            assert_eq!(unsafe { *c[0].conditionValue.Anonymous.uint64 }, 123);
            assert_eq!(
                guid_parts(c[1].fieldKey),
                guid_parts(FWPM_CONDITION_IP_REMOTE_PORT)
            );
            assert_eq!(unsafe { c[1].conditionValue.Anonymous.uint16 }, port);
            assert_eq!(c[2].matchType, FWP_MATCH_FLAGS_NONE_SET);
            assert_eq!(
                unsafe { c[2].conditionValue.Anonymous.uint32 },
                FWP_CONDITION_FLAG_IS_LOOPBACK
            );
        }
    }

    #[test]
    fn unknown_tunnel_is_rejected_before_opening_bfe() {
        assert!(DnsGuard::acquire(0).is_err());
    }

    #[test]
    #[ignore = "administrator required; aborted transaction never changes live traffic"]
    fn native_dns_policy_validates_without_changing_traffic() {
        let mut guard = DnsGuard::open().expect("open dynamic BFE session");
        check(unsafe { FwpmTransactionBegin0(guard.engine, 0) }).expect("begin transaction");
        let result = guard.add_filters(0x1234);
        let visible = guard.is_installed();
        let abort = unsafe { FwpmTransactionAbort0(guard.engine) };
        assert_eq!(abort, 0);
        assert!(result.is_ok(), "DNS filter validation failed");
        assert!(visible);
        assert!(!guard.is_installed(), "aborted filters must not remain");
    }
}
