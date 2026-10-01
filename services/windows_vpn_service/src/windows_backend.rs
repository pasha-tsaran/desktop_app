use super::kill_switch::KillSwitch;
use std::net::IpAddr;
use vpn_contracts::{AmneziaWgProfile, TunnelStatistics, VlessRealityProfile, WireGuardProfile};
use vpn_service_core::{BackendFailure, VpnBackend};

use super::{
    amneziawg_engine::AmneziaWgWindowsBackend, wireguard_engine::WireGuardWindowsBackend,
    xray_engine::XrayWindowsBackend,
};

#[derive(Clone, Copy, Debug)]
enum ActiveEngine {
    WireGuard,
    AmneziaWg,
    Xray,
}

#[derive(Debug)]
pub struct WindowsVpnBackend {
    wireguard: WireGuardWindowsBackend,
    amneziawg: AmneziaWgWindowsBackend,
    xray: XrayWindowsBackend,
    active: Option<ActiveEngine>,
    guard: KillSwitch,
    peer: Option<IpAddr>,
}

impl WindowsVpnBackend {
    pub fn system_default() -> std::io::Result<Self> {
        Ok(Self {
            wireguard: WireGuardWindowsBackend::system_default()?,
            amneziawg: AmneziaWgWindowsBackend::system_default()?,
            xray: XrayWindowsBackend::system_default()?,
            active: None,
            guard: KillSwitch::open().map_err(|_| std::io::Error::other("WFP unavailable"))?,
            peer: None,
        })
    }

    fn disconnect_all(&mut self) -> Result<(), BackendFailure> {
        if self.guard.active() {
            self.guard.configure(true, self.peer, None)?;
        }
        let wireguard = self.wireguard.disconnect();
        let amneziawg = self.amneziawg.disconnect();
        let xray = self.xray.disconnect();
        self.active = None;
        wireguard.and(amneziawg).and(xray)
    }

    fn prepare(&mut self, host: &str, enabled: bool) -> Result<(), BackendFailure> {
        super::connection_cancel::check()?;
        // The production profiles currently use literal endpoint addresses.
        // Fail closed for hostname profiles under strict protection: DNS must
        // never be temporarily allowed outside the tunnel to resolve them.
        self.peer = host.parse().ok();
        if enabled || self.guard.active() {
            if self.peer.is_none() {
                return Err(BackendFailure::InvalidProfile);
            }
            self.guard.configure(true, self.peer, None)?;
        }
        self.disconnect_all()?;
        super::connection_cancel::check()
    }

    fn finish(&mut self, active: ActiveEngine) -> Result<(), BackendFailure> {
        if let Err(error) = super::connection_cancel::check() {
            self.disconnect_all()?;
            return Err(error);
        }
        self.active = Some(active);
        if self.guard.active() {
            if let Err(error) = self.guard.configure(true, self.peer, self.tunnel_name()) {
                let _ = self.disconnect_all();
                return Err(error);
            }
        }
        Ok(())
    }
    fn tunnel_name(&self) -> Option<&'static str> {
        match self.active {
            Some(ActiveEngine::WireGuard) => Some("Kenai"),
            Some(ActiveEngine::AmneziaWg) => Some("KenaiAwg"),
            Some(ActiveEngine::Xray) => Some("KenaiXray"),
            None => None,
        }
    }
}

impl VpnBackend for WindowsVpnBackend {
    fn set_kill_switch(&mut self, enabled: bool) -> Result<(), BackendFailure> {
        self.guard.configure(
            enabled,
            self.peer,
            if enabled { self.tunnel_name() } else { None },
        )
    }
    fn kill_switch_active(&self) -> bool {
        self.guard.active()
    }
    fn connect(
        &mut self,
        id: &str,
        profile: &WireGuardProfile,
        kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        self.prepare(&profile.endpoint_host, kill_switch)?;
        self.wireguard.connect(id, profile, false)?;
        self.finish(ActiveEngine::WireGuard)
    }
    fn connect_amneziawg(
        &mut self,
        id: &str,
        profile: &AmneziaWgProfile,
        kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        self.prepare(&profile.wireguard.endpoint_host, kill_switch)?;
        self.amneziawg.connect_amneziawg(id, profile, false)?;
        self.finish(ActiveEngine::AmneziaWg)
    }
    fn connect_vless(
        &mut self,
        id: &str,
        profile: &VlessRealityProfile,
        kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        self.prepare(&profile.endpoint_host, kill_switch)?;
        self.xray.connect_vless(id, profile, false)?;
        self.finish(ActiveEngine::Xray)
    }
    fn disconnect(&mut self) -> Result<(), BackendFailure> {
        self.disconnect_all()
    }
    fn is_connected(&self) -> Result<bool, BackendFailure> {
        match self.active {
            Some(ActiveEngine::WireGuard) => self.wireguard.is_connected(),
            Some(ActiveEngine::AmneziaWg) => self.amneziawg.is_connected(),
            Some(ActiveEngine::Xray) => self.xray.is_connected(),
            None => Ok(false),
        }
    }
    fn statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
        match self.active {
            Some(ActiveEngine::WireGuard) => self.wireguard.statistics(),
            Some(ActiveEngine::AmneziaWg) => self.amneziawg.statistics(),
            Some(ActiveEngine::Xray) => self.xray.statistics(),
            None => Err(BackendFailure::EngineUnavailable),
        }
    }
}

impl Drop for WindowsVpnBackend {
    fn drop(&mut self) {
        // Service shutdown stops all engines without releasing persistent WFP protection.
        let _ = self.disconnect_all();
    }
}
