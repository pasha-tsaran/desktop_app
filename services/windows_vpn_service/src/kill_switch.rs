// Persistent, service-owned WFP policy. No rules are removed by Drop: stopping
// the GUI/service or losing the tunnel must not restore ordinary Internet.
use std::{net::{IpAddr, Ipv4Addr}, ptr};
use vpn_service_core::BackendFailure;
use windows_sys::{core::{w, GUID}, Win32::{
    Foundation::{HANDLE, FWP_E_ALREADY_EXISTS, FWP_E_FILTER_NOT_FOUND},
    NetworkManagement::{IpHelper::ConvertInterfaceAliasToLuid, Ndis::NET_LUID_LH,
        WindowsFilteringPlatform::{FwpmEngineOpen0, FwpmFilterGetByKey0, FwpmFreeMemory0,
            FwpmTransactionBegin0, FwpmTransactionAbort0, FwpmTransactionCommit0,
            FwpmFilterDeleteByKey0, FWPM_SUBLAYER0, FWPM_SUBLAYER_FLAG_PERSISTENT,
            FwpmSubLayerAdd0, FWPM_LAYER_OUTBOUND_IPPACKET_V4, FWPM_LAYER_OUTBOUND_IPPACKET_V6,
            FWPM_CONDITION_FLAGS, FWP_MATCH_FLAGS_ALL_SET, FWP_UINT32, FWP_CONDITION_VALUE0_0,
            FWP_CONDITION_FLAG_IS_LOOPBACK, FWPM_CONDITION_IP_LOCAL_INTERFACE, FWP_MATCH_EQUAL,
            FWP_UINT64, FWP_V6_ADDR_AND_MASK, FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_V6_ADDR_MASK,
            FWP_V4_ADDR_AND_MASK, FWP_V4_ADDR_MASK, FWPM_FILTER_CONDITION0, FWPM_FILTER0,
            FWPM_FILTER_FLAG_PERSISTENT, FWP_VALUE0, FWP_VALUE0_0, FWPM_ACTION0, FWP_ACTION_PERMIT,
            FWP_ACTION_BLOCK, FwpmFilterAdd0, FwpmEngineClose0, FWPM_DISPLAY_DATA0,
            FWP_MATCH_TYPE, FWP_DATA_TYPE, FWP_CONDITION_VALUE0}},
    System::Rpc::RPC_C_AUTHN_WINNT,
}};

const SUBLAYER: GUID = GUID::from_u128(0xa4c03158_33ef_44ad_a169_553b3ca99e10);
const FILTER_BASE: u128 = 0xa4c03158_33ef_44ad_a169_553b3ca99f00;
const SLOTS: u128 = 16;
// The current one-server MVP API shares this host with both VPN endpoints.
const API: Ipv4Addr = Ipv4Addr::new(88, 218, 94, 3);

#[derive(Debug)]
pub struct KillSwitch { engine: HANDLE }

impl KillSwitch {
    pub fn open() -> Result<Self, BackendFailure> {
        let mut engine = ptr::null_mut();
        // SAFETY: fixed local BFE and initialized writable output.
        check(unsafe { FwpmEngineOpen0(ptr::null(), RPC_C_AUTHN_WINNT,
            ptr::null(), ptr::null(), &raw mut engine) })?;
        Ok(Self { engine })
    }

    pub fn active(&self) -> bool {
        self.exists(0) && self.exists(1)
    }

    fn exists(&self, slot: u128) -> bool {
        let key = GUID::from_u128(FILTER_BASE + slot);
        let mut filter = ptr::null_mut();
        // SAFETY: live BFE handle; output is allocated by BFE.
        let code = unsafe { FwpmFilterGetByKey0(self.engine, &raw const key, &raw mut filter) };
        if !filter.is_null() {
            unsafe { FwpmFreeMemory0(ptr::from_mut(&mut filter).cast()) };
        }
        code == 0
    }

    pub fn configure(&self, enabled: bool, peer: Option<IpAddr>, tunnel: Option<&str>)
        -> Result<(), BackendFailure> {
        let mut luid = NET_LUID_LH::default();
        let interface = if let Some(alias) = tunnel {
            let name: Vec<u16> = alias.encode_utf16().chain(Some(0)).collect();
            check(unsafe { ConvertInterfaceAliasToLuid(name.as_ptr(), &raw mut luid) })?;
            Some(unsafe { luid.Value })
        } else { None };
        check(unsafe { FwpmTransactionBegin0(self.engine, 0) })?;
        let result = self.replace(enabled, peer, interface);
        if result.is_err() {
            unsafe { FwpmTransactionAbort0(self.engine) };
            return result;
        }
        let commit = unsafe { FwpmTransactionCommit0(self.engine) };
        if commit != 0 { unsafe { FwpmTransactionAbort0(self.engine) }; }
        check(commit)
    }

    fn replace(&self, enabled: bool, peer: Option<IpAddr>, interface: Option<u64>)
        -> Result<(), BackendFailure> {
        for slot in 0..SLOTS {
            let key = GUID::from_u128(FILTER_BASE + slot);
            let code = unsafe { FwpmFilterDeleteByKey0(self.engine, &raw const key) };
            if code != FWP_E_FILTER_NOT_FOUND.cast_unsigned() { check(code)?; }
        }
        if !enabled { return Ok(()); }
        let sublayer = FWPM_SUBLAYER0 {
            subLayerKey: SUBLAYER,
            displayData: display(),
            flags: FWPM_SUBLAYER_FLAG_PERSISTENT,
            weight: u16::MAX - 1,
            ..Default::default()
        };
        let code = unsafe { FwpmSubLayerAdd0(self.engine, &raw const sublayer, ptr::null_mut()) };
        if code != FWP_E_ALREADY_EXISTS.cast_unsigned() { check(code)?; }
        for (slot, layer) in [(0, FWPM_LAYER_OUTBOUND_IPPACKET_V4), (1, FWPM_LAYER_OUTBOUND_IPPACKET_V6)] {
            self.add(slot, layer, false, &mut [])?;
            let mut loopback = condition(FWPM_CONDITION_FLAGS, FWP_MATCH_FLAGS_ALL_SET,
                FWP_UINT32, FWP_CONDITION_VALUE0_0 { uint32: FWP_CONDITION_FLAG_IS_LOOPBACK });
            self.add(slot + 2, layer, true, std::slice::from_mut(&mut loopback))?;
            if let Some(mut value) = interface {
                let mut condition = condition(FWPM_CONDITION_IP_LOCAL_INTERFACE,
                    FWP_MATCH_EQUAL, FWP_UINT64,
                    FWP_CONDITION_VALUE0_0 { uint64: &raw mut value });
                self.add(slot + 4, layer, true, std::slice::from_mut(&mut condition))?;
            }
        }
        self.address(6, IpAddr::V4(API))?;
        if let Some(value) = peer { self.address(7, value)?; }
        // DHCPv4 acquisition may use broadcast when an uplink changes. No LAN
        // unicast or DNS exception is granted. ARP is below these IP layers.
        self.address(8, IpAddr::V4(Ipv4Addr::BROADCAST))?;
        // IPv6 link-local control multicast (ND/router discovery/DHCPv6), never
        // globally routable traffic. Needed for IPv6-only transport recovery.
        let mut multicast = FWP_V6_ADDR_AND_MASK { addr: [0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], prefixLength: 16 };
        let mut condition = condition(FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_MATCH_EQUAL,
            FWP_V6_ADDR_MASK, FWP_CONDITION_VALUE0_0 { v6AddrMask: &raw mut multicast });
        self.add(9, FWPM_LAYER_OUTBOUND_IPPACKET_V6, true, std::slice::from_mut(&mut condition))
    }

    fn address(&self, slot: u128, address: IpAddr) -> Result<(), BackendFailure> {
        match address {
            IpAddr::V4(address) => {
                let mut value = FWP_V4_ADDR_AND_MASK { addr: u32::from(address), mask: u32::MAX };
                let mut cond = condition(FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_MATCH_EQUAL,
                    FWP_V4_ADDR_MASK, FWP_CONDITION_VALUE0_0 { v4AddrMask: &raw mut value });
                self.add(slot, FWPM_LAYER_OUTBOUND_IPPACKET_V4, true, std::slice::from_mut(&mut cond))
            }
            IpAddr::V6(address) => {
                let mut value = FWP_V6_ADDR_AND_MASK { addr: address.octets(), prefixLength: 128 };
                let mut cond = condition(FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_MATCH_EQUAL,
                    FWP_V6_ADDR_MASK, FWP_CONDITION_VALUE0_0 { v6AddrMask: &raw mut value });
                self.add(slot, FWPM_LAYER_OUTBOUND_IPPACKET_V6, true, std::slice::from_mut(&mut cond))
            }
        }
    }

    fn add(&self, slot: u128, layer: GUID, permit: bool,
        conditions: &mut [FWPM_FILTER_CONDITION0]) -> Result<(), BackendFailure> {
        let mut weight = if permit { 100_u64 } else { 1_u64 };
        let filter = FWPM_FILTER0 {
            filterKey: GUID::from_u128(FILTER_BASE + slot),
            displayData: display(), layerKey: layer, subLayerKey: SUBLAYER,
            flags: FWPM_FILTER_FLAG_PERSISTENT,
            weight: FWP_VALUE0 { r#type: FWP_UINT64, Anonymous: FWP_VALUE0_0 { uint64: &raw mut weight } },
            action: FWPM_ACTION0 { r#type: if permit { FWP_ACTION_PERMIT } else { FWP_ACTION_BLOCK }, ..Default::default() },
            numFilterConditions: u32::try_from(conditions.len()).map_err(|_| BackendFailure::Internal)?,
            filterCondition: conditions.as_mut_ptr(), ..Default::default()
        };
        check(unsafe { FwpmFilterAdd0(self.engine, &raw const filter, ptr::null_mut(), ptr::null_mut()) })
    }
}
impl Drop for KillSwitch {
    fn drop(&mut self) { unsafe { FwpmEngineClose0(self.engine) }; }
}
fn display() -> FWPM_DISPLAY_DATA0 {
    FWPM_DISPLAY_DATA0 { name: w!("Kenai VPN persistent kill switch").cast_mut(), description: ptr::null_mut() }
}
fn condition(field_key: GUID, match_type: FWP_MATCH_TYPE, r#type: FWP_DATA_TYPE,
    value: FWP_CONDITION_VALUE0_0) -> FWPM_FILTER_CONDITION0 {
    FWPM_FILTER_CONDITION0 { fieldKey: field_key, matchType: match_type,
        conditionValue: FWP_CONDITION_VALUE0 { r#type, Anonymous: value } }
}
fn check(code: u32) -> Result<(), BackendFailure> {
    if code == 0 { Ok(()) } else { Err(BackendFailure::RoutingUnavailable) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires administrator; validates an uncommitted WFP transaction, never changes traffic"]
    fn native_policy_validates_without_changing_traffic() {
        let guard = KillSwitch::open().expect("open BFE");
        let before = guard.active();
        check(unsafe { FwpmTransactionBegin0(guard.engine, 0) }).expect("transaction");
        let result = guard.replace(true, Some(IpAddr::V4(API)), Some(0x1234));
        let active = guard.active();
        // Always abort BEFORE assertions; uncommitted policy never classifies packets.
        let abort = unsafe { FwpmTransactionAbort0(guard.engine) };
        assert_eq!(abort, 0);
        assert!(result.is_ok(), "native filter validation failed: {result:?}");
        assert!(active, "both persistent deny rules should exist in transaction");
        assert_eq!(guard.active(), before, "committed policy must be unchanged");
    }
}
