//! Pure service policy and state transitions. No operating-system calls.

#![allow(clippy::missing_errors_doc)]

use std::collections::{HashSet, VecDeque};

use vpn_contracts::{
    AmneziaWgProfile, ConnectRequest, ConnectionPhase, ControlCommand, RequestEnvelope, StateEvent,
    TunnelStatistics, VlessRealityProfile, WireGuardProfile, CONTRACT_VERSION,
};

#[derive(Debug, Eq, PartialEq)]
pub enum CommandError {
    Busy,
    DuplicateRequest,
    EmptyOperationId,
    EmptyProfileId,
    InvalidFailurePhase,
    UnauthorizedCaller,
    InvalidProfile,
    ProfileNotFound,
    ProfileStoreUnavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BackendFailure {
    EngineUnavailable,
    NoNetwork,
    ServerUnavailable,
    RoutingUnavailable,
    InvalidProfile,
    UnsupportedFeature,
    Internal,
    Cancelled,
}

pub trait VpnBackend {
    fn set_kill_switch(&mut self, _enabled: bool) -> Result<(), BackendFailure> {
        Err(BackendFailure::UnsupportedFeature)
    }
    fn kill_switch_active(&self) -> bool {
        false
    }
    fn connect(
        &mut self,
        profile_id: &str,
        profile: &WireGuardProfile,
        kill_switch: bool,
    ) -> Result<(), BackendFailure>;
    fn connect_amneziawg(
        &mut self,
        _profile_id: &str,
        _profile: &AmneziaWgProfile,
        _kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        Err(BackendFailure::UnsupportedFeature)
    }
    fn connect_vless(
        &mut self,
        _profile_id: &str,
        _profile: &VlessRealityProfile,
        _kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        Err(BackendFailure::UnsupportedFeature)
    }
    fn disconnect(&mut self) -> Result<(), BackendFailure>;
    fn is_connected(&self) -> Result<bool, BackendFailure>;
    fn statistics(&self) -> Result<TunnelStatistics, BackendFailure>;
}

#[derive(Debug, Default)]
pub struct UnavailableVpnBackend;

impl VpnBackend for UnavailableVpnBackend {
    fn connect(
        &mut self,
        _profile_id: &str,
        _profile: &WireGuardProfile,
        _kill_switch: bool,
    ) -> Result<(), BackendFailure> {
        Err(BackendFailure::EngineUnavailable)
    }

    fn disconnect(&mut self) -> Result<(), BackendFailure> {
        Ok(())
    }

    fn is_connected(&self) -> Result<bool, BackendFailure> {
        Ok(false)
    }

    fn statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
        Err(BackendFailure::EngineUnavailable)
    }
}

pub trait ProfileVault {
    fn store_wireguard(&mut self, profile: &WireGuardProfile) -> Result<String, CommandError>;
    fn load_wireguard(&self, profile_id: &str) -> Result<WireGuardProfile, CommandError>;
    fn store_amneziawg(&mut self, _profile: &AmneziaWgProfile) -> Result<String, CommandError> {
        Err(CommandError::ProfileStoreUnavailable)
    }
    fn load_amneziawg(&self, _profile_id: &str) -> Result<AmneziaWgProfile, CommandError> {
        Err(CommandError::ProfileStoreUnavailable)
    }
    fn store_vless(&mut self, _profile: &VlessRealityProfile) -> Result<String, CommandError> {
        Err(CommandError::ProfileStoreUnavailable)
    }
    fn load_vless(&self, _profile_id: &str) -> Result<VlessRealityProfile, CommandError> {
        Err(CommandError::ProfileStoreUnavailable)
    }
    fn delete(&mut self, profile_id: &str) -> Result<(), CommandError>;
}

#[derive(Debug, Default)]
pub struct UnavailableProfileVault;

impl ProfileVault for UnavailableProfileVault {
    fn store_wireguard(&mut self, _profile: &WireGuardProfile) -> Result<String, CommandError> {
        Err(CommandError::ProfileStoreUnavailable)
    }

    fn load_wireguard(&self, _profile_id: &str) -> Result<WireGuardProfile, CommandError> {
        Err(CommandError::ProfileStoreUnavailable)
    }

    fn delete(&mut self, _profile_id: &str) -> Result<(), CommandError> {
        Err(CommandError::ProfileStoreUnavailable)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AuthorizationContext {
    pub is_local: bool,
    pub is_authenticated: bool,
    pub client_session_id: u32,
    pub allowed_session_id: u32,
}

impl AuthorizationContext {
    #[must_use]
    pub const fn is_allowed(self) -> bool {
        self.is_local
            && self.is_authenticated
            && self.client_session_id != 0
            && self.client_session_id == self.allowed_session_id
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandOutcome {
    pub request_id: String,
    pub state: StateEvent,
    pub code: &'static str,
    pub statistics: Option<TunnelStatistics>,
}

#[derive(Debug)]
pub struct ServiceCommandProcessor<V = UnavailableProfileVault, B = UnavailableVpnBackend> {
    machine: ConnectionStateMachine,
    recent_ids: VecDeque<String>,
    recent_id_set: HashSet<String>,
    vault: V,
    backend: B,
}

impl Default for ServiceCommandProcessor<UnavailableProfileVault, UnavailableVpnBackend> {
    fn default() -> Self {
        Self::new(UnavailableProfileVault)
    }
}

impl<V: ProfileVault> ServiceCommandProcessor<V, UnavailableVpnBackend> {
    #[must_use]
    pub fn new(vault: V) -> Self {
        Self::with_backend(vault, UnavailableVpnBackend)
    }
}

impl<V: ProfileVault, B: VpnBackend> ServiceCommandProcessor<V, B> {
    const MAX_RECENT_REQUESTS: usize = 256;

    #[must_use]
    pub fn with_backend(vault: V, backend: B) -> Self {
        Self {
            machine: ConnectionStateMachine::default(),
            recent_ids: VecDeque::new(),
            recent_id_set: HashSet::new(),
            vault,
            backend,
        }
    }

    pub fn process(
        &mut self,
        context: AuthorizationContext,
        request: RequestEnvelope,
    ) -> Result<CommandOutcome, CommandError> {
        if !context.is_allowed() {
            return Err(CommandError::UnauthorizedCaller);
        }
        if self.recent_id_set.contains(&request.request_id) {
            return Err(CommandError::DuplicateRequest);
        }
        self.remember(request.request_id.clone());

        let (code, returned_profile_id, statistics) = match request.command {
            ControlCommand::SetKillSwitch { enabled } => {
                let code = match self.backend.set_kill_switch(enabled) {
                    Ok(()) => "OK",
                    Err(failure) => backend_failure(failure).1,
                };
                (code, None, None)
            }
            ControlCommand::Status => (self.reconcile_status()?, None, None),
            ControlCommand::Diagnostics => ("DIAGNOSTICS_REDACTED", None, None),
            ControlCommand::Connect(connect) => (self.connect_request(&connect)?, None, None),
            ControlCommand::Disconnect { operation_id } => {
                (self.disconnect_request(&operation_id)?, None, None)
            }
            ControlCommand::ImportWireGuardProfile(import) => {
                let profile_id = self.import_wireguard(&import.operation_id, &import.profile)?;
                ("PROFILE_STORED", Some(profile_id), None)
            }
            ControlCommand::ImportAmneziaWgProfile(import) => {
                let profile_id = self.import_amneziawg(&import.operation_id, &import.profile)?;
                ("PROFILE_STORED", Some(profile_id), None)
            }
            ControlCommand::ImportVlessRealityProfile(import) => {
                let profile_id = self.import_vless(&import.operation_id, &import.profile)?;
                ("PROFILE_STORED", Some(profile_id), None)
            }
            ControlCommand::DeleteProfile {
                operation_id,
                profile_id,
            } => {
                if operation_id.trim().is_empty() {
                    return Err(CommandError::EmptyOperationId);
                }
                if profile_id.trim().is_empty() {
                    return Err(CommandError::EmptyProfileId);
                }
                self.vault.delete(&profile_id)?;
                ("PROFILE_DELETED", None, None)
            }
            ControlCommand::Statistics => match self.backend.statistics() {
                Ok(statistics) => ("OK", None, Some(statistics)),
                Err(failure) => {
                    let (_, code) = backend_failure(failure);
                    (code, None, None)
                }
            },
        };
        let mut state = self.machine.state().clone();
        state.kill_switch_active = self.backend.kill_switch_active();
        if returned_profile_id.is_some() {
            state.profile_id = returned_profile_id;
        }
        Ok(CommandOutcome {
            request_id: request.request_id,
            state,
            code,
            statistics,
        })
    }

    fn remember(&mut self, request_id: String) {
        if self.recent_ids.len() == Self::MAX_RECENT_REQUESTS {
            if let Some(expired) = self.recent_ids.pop_front() {
                self.recent_id_set.remove(&expired);
            }
        }
        self.recent_id_set.insert(request_id.clone());
        self.recent_ids.push_back(request_id);
    }

    fn connect_request(&mut self, connect: &ConnectRequest) -> Result<&'static str, CommandError> {
        if self.machine.state().phase.is_failure() {
            self.machine.reset_failure()?;
        }
        self.machine.begin_connect(connect)?;
        self.machine.mark_validated()?;
        let result = (|| match connect.protocol {
            vpn_contracts::Protocol::WireGuard => {
                let profile = self.vault.load_wireguard(&connect.profile_id)?;
                Ok(self
                    .backend
                    .connect(&connect.profile_id, &profile, connect.kill_switch))
            }
            vpn_contracts::Protocol::AmneziaWg => {
                let profile = self.vault.load_amneziawg(&connect.profile_id)?;
                Ok(self.backend.connect_amneziawg(
                    &connect.profile_id,
                    &profile,
                    connect.kill_switch,
                ))
            }
            vpn_contracts::Protocol::VlessReality => {
                let profile = self.vault.load_vless(&connect.profile_id)?;
                Ok(self
                    .backend
                    .connect_vless(&connect.profile_id, &profile, connect.kill_switch))
            }
        })();
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                self.machine
                    .fail(ConnectionPhase::Error, "PROFILE_LOAD_FAILED")?;
                return Err(error);
            }
        };
        match result {
            Ok(()) => {
                self.machine
                    .mark_connected(self.backend.kill_switch_active())?;
                Ok("CONNECTED")
            }
            Err(failure) => {
                let (phase, code) = backend_failure(failure);
                self.machine.fail(phase, code)?;
                Ok(code)
            }
        }
    }

    fn disconnect_request(&mut self, operation_id: &str) -> Result<&'static str, CommandError> {
        if operation_id.trim().is_empty() {
            return Err(CommandError::EmptyOperationId);
        }
        // Commands execute serially. A leftover transitional state is not an
        // operation still running: always allow explicit cleanup/retry.
        match self.backend.disconnect() {
            Ok(()) => self.machine.reconcile_disconnected(),
            Err(failure) => {
                let (phase, code) = backend_failure(failure);
                self.machine.fail(phase, code)?;
                return Ok(code);
            }
        }
        Ok("DISCONNECTED")
    }

    fn import_wireguard(
        &mut self,
        operation_id: &str,
        profile: &WireGuardProfile,
    ) -> Result<String, CommandError> {
        validate_import(operation_id, profile.validate())?;
        validate_stored_id(self.vault.store_wireguard(profile)?)
    }

    fn import_amneziawg(
        &mut self,
        operation_id: &str,
        profile: &AmneziaWgProfile,
    ) -> Result<String, CommandError> {
        validate_import(operation_id, profile.validate())?;
        validate_stored_id(self.vault.store_amneziawg(profile)?)
    }

    fn import_vless(
        &mut self,
        operation_id: &str,
        profile: &VlessRealityProfile,
    ) -> Result<String, CommandError> {
        validate_import(operation_id, profile.validate())?;
        validate_stored_id(self.vault.store_vless(profile)?)
    }

    fn reconcile_status(&mut self) -> Result<&'static str, CommandError> {
        if !matches!(
            self.machine.state().phase,
            ConnectionPhase::Connected | ConnectionPhase::Reconnecting
        ) {
            return Ok("OK");
        }
        match self.backend.is_connected() {
            Ok(true) => Ok("OK"),
            Ok(false) => {
                self.machine.reconcile_disconnected();
                Ok("TUNNEL_STOPPED")
            }
            Err(failure) => {
                let (phase, code) = backend_failure(failure);
                self.machine.fail(phase, code)?;
                Ok(code)
            }
        }
    }
}

fn validate_import(
    operation_id: &str,
    validation: Result<(), vpn_contracts::FrameError>,
) -> Result<(), CommandError> {
    if operation_id.trim().is_empty() {
        return Err(CommandError::EmptyOperationId);
    }
    validation.map_err(|_| CommandError::InvalidProfile)
}

fn validate_stored_id(profile_id: String) -> Result<String, CommandError> {
    if valid_profile_id(&profile_id) {
        Ok(profile_id)
    } else {
        Err(CommandError::ProfileStoreUnavailable)
    }
}

const fn backend_failure(failure: BackendFailure) -> (ConnectionPhase, &'static str) {
    match failure {
        BackendFailure::EngineUnavailable => (ConnectionPhase::Error, "ENGINE_NOT_INSTALLED"),
        BackendFailure::NoNetwork => (ConnectionPhase::NoNetwork, "NO_NETWORK"),
        BackendFailure::ServerUnavailable => {
            (ConnectionPhase::ServerUnavailable, "SERVER_UNAVAILABLE")
        }
        BackendFailure::RoutingUnavailable => (ConnectionPhase::Error, "TUNNEL_ROUTE_UNAVAILABLE"),
        BackendFailure::InvalidProfile => (ConnectionPhase::Error, "INVALID_PROFILE"),
        BackendFailure::UnsupportedFeature => (ConnectionPhase::Error, "UNSUPPORTED_FEATURE"),
        BackendFailure::Internal => (ConnectionPhase::Error, "ENGINE_FAILED"),
        BackendFailure::Cancelled => (ConnectionPhase::Error, "CONNECTION_CANCELLED"),
    }
}

fn valid_profile_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

#[derive(Debug, Default)]
pub struct ConnectionStateMachine {
    state: StateEvent,
}

impl ConnectionStateMachine {
    #[must_use]
    pub fn state(&self) -> &StateEvent {
        &self.state
    }

    pub fn begin_connect(&mut self, request: &ConnectRequest) -> Result<(), CommandError> {
        if request.operation_id.trim().is_empty() {
            return Err(CommandError::EmptyOperationId);
        }
        if request.profile_id.trim().is_empty() {
            return Err(CommandError::EmptyProfileId);
        }
        if self.state.phase != ConnectionPhase::Disconnected {
            return Err(CommandError::Busy);
        }
        self.state = StateEvent {
            contract_version: CONTRACT_VERSION,
            phase: ConnectionPhase::Validating,
            profile_id: Some(request.profile_id.clone()),
            kill_switch_active: false,
            error_code: None,
        };
        Ok(())
    }

    pub fn mark_validated(&mut self) -> Result<(), CommandError> {
        if self.state.phase != ConnectionPhase::Validating {
            return Err(CommandError::Busy);
        }
        self.state.phase = ConnectionPhase::Connecting;
        Ok(())
    }

    pub fn mark_connected(&mut self, kill_switch_active: bool) -> Result<(), CommandError> {
        if !matches!(
            self.state.phase,
            ConnectionPhase::Connecting | ConnectionPhase::Reconnecting
        ) {
            return Err(CommandError::Busy);
        }
        self.state.phase = ConnectionPhase::Connected;
        self.state.kill_switch_active = kill_switch_active;
        self.state.error_code = None;
        Ok(())
    }

    pub fn begin_reconnect(&mut self) -> Result<(), CommandError> {
        if self.state.phase != ConnectionPhase::Connected {
            return Err(CommandError::Busy);
        }
        self.state.phase = ConnectionPhase::Reconnecting;
        Ok(())
    }

    pub fn begin_disconnect(&mut self, operation_id: &str) -> Result<(), CommandError> {
        if operation_id.trim().is_empty() {
            return Err(CommandError::EmptyOperationId);
        }
        if !matches!(
            self.state.phase,
            ConnectionPhase::Connected | ConnectionPhase::Reconnecting
        ) {
            return Err(CommandError::Busy);
        }
        self.state.phase = ConnectionPhase::Disconnecting;
        Ok(())
    }

    pub fn mark_disconnected(&mut self) -> Result<(), CommandError> {
        if self.state.phase != ConnectionPhase::Disconnecting {
            return Err(CommandError::Busy);
        }
        self.state = StateEvent::default();
        Ok(())
    }

    /// Reconciles cached state after the operating-system tunnel stopped out of band.
    pub fn reconcile_disconnected(&mut self) {
        self.state = StateEvent::default();
    }

    pub fn fail(
        &mut self,
        phase: ConnectionPhase,
        error_code: impl Into<String>,
    ) -> Result<(), CommandError> {
        if !phase.is_failure() {
            return Err(CommandError::InvalidFailurePhase);
        }
        self.state.phase = phase;
        self.state.kill_switch_active = false;
        self.state.error_code = Some(error_code.into());
        Ok(())
    }

    pub fn reset_failure(&mut self) -> Result<(), CommandError> {
        if !self.state.phase.is_failure() {
            return Err(CommandError::Busy);
        }
        self.state = StateEvent::default();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;
    use vpn_contracts::{ImportWireGuardProfileRequest, Protocol, SecretKey, WireGuardProfile};

    #[derive(Debug, Default)]
    struct MemoryVault {
        stored: bool,
    }

    impl ProfileVault for MemoryVault {
        fn store_wireguard(&mut self, _profile: &WireGuardProfile) -> Result<String, CommandError> {
            self.stored = true;
            Ok("wg-0011223344556677".into())
        }

        fn load_wireguard(&self, _profile_id: &str) -> Result<WireGuardProfile, CommandError> {
            if self.stored {
                Ok(profile())
            } else {
                Err(CommandError::ProfileNotFound)
            }
        }

        fn delete(&mut self, profile_id: &str) -> Result<(), CommandError> {
            if self.stored && profile_id == "wg-0011223344556677" {
                self.stored = false;
                Ok(())
            } else {
                Err(CommandError::ProfileNotFound)
            }
        }
    }

    #[derive(Debug, Default)]
    struct WorkingBackend {
        connected: bool,
        protected: bool,
        fail_disconnect: bool,
    }

    impl VpnBackend for WorkingBackend {
        fn set_kill_switch(&mut self, enabled: bool) -> Result<(), BackendFailure> {
            self.protected = enabled;
            Ok(())
        }
        fn kill_switch_active(&self) -> bool {
            self.protected
        }
        fn connect(
            &mut self,
            _profile_id: &str,
            _profile: &WireGuardProfile,
            kill_switch: bool,
        ) -> Result<(), BackendFailure> {
            if kill_switch {
                return Err(BackendFailure::UnsupportedFeature);
            }
            self.connected = true;
            Ok(())
        }

        fn disconnect(&mut self) -> Result<(), BackendFailure> {
            if self.fail_disconnect {
                return Err(BackendFailure::Internal);
            }
            self.connected = false;
            Ok(())
        }

        fn is_connected(&self) -> Result<bool, BackendFailure> {
            Ok(self.connected)
        }

        fn statistics(&self) -> Result<TunnelStatistics, BackendFailure> {
            if !self.connected {
                return Err(BackendFailure::EngineUnavailable);
            }
            Ok(TunnelStatistics {
                bytes_received: 200,
                bytes_sent: 100,
                last_handshake_unix_ms: Some(1_700_000_000_000),
            })
        }
    }

    fn request() -> ConnectRequest {
        ConnectRequest {
            operation_id: "connect-1".into(),
            profile_id: "profile-1".into(),
            protocol: Protocol::WireGuard,
            kill_switch: true,
        }
    }

    #[test]
    fn failed_disconnect_is_retryable_and_never_stays_busy() {
        let mut processor = ServiceCommandProcessor::with_backend(
            MemoryVault::default(),
            WorkingBackend {
                protected: true,
                fail_disconnect: true,
                ..Default::default()
            },
        );
        processor.machine.begin_connect(&request()).unwrap();
        processor.machine.mark_validated().unwrap();
        processor.machine.mark_connected(true).unwrap();
        assert_eq!(processor.disconnect_request("stop"), Ok("ENGINE_FAILED"));
        assert_eq!(processor.machine.state().phase, ConnectionPhase::Error);
        assert!(processor.backend.protected);
        processor.backend.fail_disconnect = false;
        assert_eq!(processor.disconnect_request("retry"), Ok("DISCONNECTED"));
        assert_eq!(
            processor.machine.state().phase,
            ConnectionPhase::Disconnected
        );
        assert!(processor.backend.protected);
    }

    #[test]
    fn missing_profile_and_stale_transitions_allow_explicit_cleanup() {
        let mut processor = ServiceCommandProcessor::with_backend(
            MemoryVault::default(),
            WorkingBackend::default(),
        );
        assert_eq!(
            processor.connect_request(&request()),
            Err(CommandError::ProfileNotFound)
        );
        assert_eq!(processor.machine.state().phase, ConnectionPhase::Error);
        assert_eq!(processor.disconnect_request("cleanup"), Ok("DISCONNECTED"));
        processor.machine.begin_connect(&request()).unwrap();
        processor.machine.mark_validated().unwrap();
        assert_eq!(processor.disconnect_request("cancel"), Ok("DISCONNECTED"));
        processor.machine.state.phase = ConnectionPhase::Disconnecting;
        assert_eq!(processor.disconnect_request("retry"), Ok("DISCONNECTED"));
    }

    fn authorized() -> AuthorizationContext {
        AuthorizationContext {
            is_local: true,
            is_authenticated: true,
            client_session_id: 4,
            allowed_session_id: 4,
        }
    }

    fn profile() -> WireGuardProfile {
        WireGuardProfile {
            private_key: SecretKey([1; 32]),
            addresses: vec!["10.0.0.2/32".into()],
            dns_servers: vec![IpAddr::from([1, 1, 1, 1])],
            peer_public_key: SecretKey([2; 32]),
            preshared_key: None,
            endpoint_host: "vpn.example.test".into(),
            endpoint_port: 51820,
            allowed_ips: vec!["0.0.0.0/0".into()],
            persistent_keepalive: Some(25),
        }
    }

    #[test]
    fn follows_connect_reconnect_and_disconnect_lifecycle() {
        let mut machine = ConnectionStateMachine::default();

        assert_eq!(machine.begin_connect(&request()), Ok(()));
        assert_eq!(machine.state().phase, ConnectionPhase::Validating);
        assert_eq!(machine.mark_validated(), Ok(()));
        assert_eq!(machine.mark_connected(true), Ok(()));
        assert!(machine.state().kill_switch_active);
        assert_eq!(machine.begin_reconnect(), Ok(()));
        assert_eq!(machine.mark_connected(true), Ok(()));
        assert_eq!(machine.begin_disconnect("disconnect-1"), Ok(()));
        assert_eq!(machine.mark_disconnected(), Ok(()));
        assert_eq!(machine.state(), &StateEvent::default());
    }

    #[test]
    fn rejects_invalid_and_overlapping_commands() {
        let mut machine = ConnectionStateMachine::default();
        let mut invalid = request();
        invalid.operation_id.clear();
        assert_eq!(
            machine.begin_connect(&invalid),
            Err(CommandError::EmptyOperationId)
        );
        assert_eq!(machine.begin_connect(&request()), Ok(()));
        assert_eq!(machine.begin_connect(&request()), Err(CommandError::Busy));
        assert_eq!(
            machine.begin_disconnect("disconnect-1"),
            Err(CommandError::Busy)
        );
    }

    #[test]
    fn supports_all_failure_states_and_explicit_recovery() {
        for phase in [
            ConnectionPhase::BlockedBySubscription,
            ConnectionPhase::NoNetwork,
            ConnectionPhase::ServerUnavailable,
            ConnectionPhase::Error,
        ] {
            let mut machine = ConnectionStateMachine::default();
            assert_eq!(machine.fail(phase, "TEST_FAILURE"), Ok(()));
            assert_eq!(machine.state().phase, phase);
            assert_eq!(machine.reset_failure(), Ok(()));
            assert_eq!(machine.state().phase, ConnectionPhase::Disconnected);
        }
    }

    #[test]
    fn missing_tunnel_route_is_not_reported_as_connected() {
        assert_eq!(
            backend_failure(BackendFailure::RoutingUnavailable),
            (ConnectionPhase::Error, "TUNNEL_ROUTE_UNAVAILABLE")
        );
    }

    #[test]
    fn protection_survives_manual_disconnect_until_explicitly_disabled() {
        let mut processor = ServiceCommandProcessor::with_backend(
            MemoryVault::default(),
            WorkingBackend::default(),
        );
        for (index, (command, expected)) in [
            (ControlCommand::SetKillSwitch { enabled: true }, true),
            (
                ControlCommand::Disconnect {
                    operation_id: "manual".into(),
                },
                true,
            ),
            (ControlCommand::Status, true),
            (ControlCommand::SetKillSwitch { enabled: false }, false),
            (ControlCommand::Status, false),
        ]
        .into_iter()
        .enumerate()
        {
            let outcome = processor
                .process(
                    authorized(),
                    RequestEnvelope {
                        contract_version: CONTRACT_VERSION,
                        request_id: format!("guard-{index}"),
                        command,
                    },
                )
                .expect("handled");
            assert_eq!(outcome.state.kill_switch_active, expected);
            assert_eq!(outcome.state.phase, ConnectionPhase::Disconnected);
        }
    }

    #[test]
    fn command_processor_rejects_unauthorized_and_duplicate_requests() {
        let request = RequestEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: "status-1".into(),
            command: ControlCommand::Status,
        };
        let mut processor = ServiceCommandProcessor::default();
        let denied = AuthorizationContext {
            client_session_id: 5,
            ..authorized()
        };

        assert_eq!(
            processor.process(denied, request.clone()),
            Err(CommandError::UnauthorizedCaller)
        );
        assert_eq!(
            processor
                .process(authorized(), request.clone())
                .expect("authorized status")
                .code,
            "OK"
        );
        assert_eq!(
            processor.process(authorized(), request),
            Err(CommandError::DuplicateRequest)
        );
    }

    #[test]
    fn connect_never_reports_success_without_an_engine() {
        let request = RequestEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: "connect-request-1".into(),
            command: ControlCommand::Connect(request()),
        };
        let mut vault = MemoryVault::default();
        vault.store_wireguard(&profile()).expect("stored profile");
        let mut processor = ServiceCommandProcessor::new(vault);

        let outcome = processor
            .process(authorized(), request)
            .expect("valid request is handled safely");

        assert_eq!(outcome.code, "ENGINE_NOT_INSTALLED");
        assert_eq!(outcome.state.phase, ConnectionPhase::Error);
        assert!(!outcome.state.kill_switch_active);
    }

    #[test]
    fn provisions_an_opaque_handle_and_deletes_it_explicitly() {
        let mut processor = ServiceCommandProcessor::new(MemoryVault::default());
        let stored = processor
            .process(
                authorized(),
                RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: "import-request-1".into(),
                    command: ControlCommand::ImportWireGuardProfile(
                        ImportWireGuardProfileRequest {
                            operation_id: "provision-1".into(),
                            profile: profile(),
                        },
                    ),
                },
            )
            .expect("profile stored");
        assert_eq!(stored.code, "PROFILE_STORED");
        assert_eq!(
            stored.state.profile_id.as_deref(),
            Some("wg-0011223344556677")
        );

        let deleted = processor
            .process(
                authorized(),
                RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: "delete-request-1".into(),
                    command: ControlCommand::DeleteProfile {
                        operation_id: "cleanup-1".into(),
                        profile_id: "wg-0011223344556677".into(),
                    },
                },
            )
            .expect("profile deleted");
        assert_eq!(deleted.code, "PROFILE_DELETED");
        assert_eq!(deleted.state.profile_id, None);
    }

    #[test]
    fn working_backend_connects_reports_statistics_and_disconnects() {
        let mut vault = MemoryVault::default();
        vault.store_wireguard(&profile()).expect("stored profile");
        let mut processor = ServiceCommandProcessor::with_backend(vault, WorkingBackend::default());
        let connected = processor
            .process(
                authorized(),
                RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: "connect-working-1".into(),
                    command: ControlCommand::Connect(ConnectRequest {
                        operation_id: "connect-operation-1".into(),
                        profile_id: "wg-0011223344556677".into(),
                        protocol: Protocol::WireGuard,
                        kill_switch: false,
                    }),
                },
            )
            .expect("connect processed");
        assert_eq!(connected.code, "CONNECTED");
        assert_eq!(connected.state.phase, ConnectionPhase::Connected);

        let statistics = processor
            .process(
                authorized(),
                RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: "statistics-working-1".into(),
                    command: ControlCommand::Statistics,
                },
            )
            .expect("statistics processed");
        assert_eq!(
            statistics.statistics.expect("statistics").bytes_received,
            200
        );

        let disconnected = processor
            .process(
                authorized(),
                RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: "disconnect-working-1".into(),
                    command: ControlCommand::Disconnect {
                        operation_id: "disconnect-operation-1".into(),
                    },
                },
            )
            .expect("disconnect processed");
        assert_eq!(disconnected.state.phase, ConnectionPhase::Disconnected);
    }

    #[test]
    fn status_reconciles_an_out_of_band_tunnel_stop() {
        let mut vault = MemoryVault::default();
        vault.store_wireguard(&profile()).expect("stored profile");
        let mut processor = ServiceCommandProcessor::with_backend(vault, WorkingBackend::default());
        processor
            .process(
                authorized(),
                RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: "connect-before-crash-1".into(),
                    command: ControlCommand::Connect(ConnectRequest {
                        operation_id: "connect-before-crash-operation-1".into(),
                        profile_id: "wg-0011223344556677".into(),
                        protocol: Protocol::WireGuard,
                        kill_switch: false,
                    }),
                },
            )
            .expect("connect processed");
        processor.backend.connected = false;

        let status = processor
            .process(
                authorized(),
                RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: "status-after-crash-1".into(),
                    command: ControlCommand::Status,
                },
            )
            .expect("status processed");

        assert_eq!(status.code, "TUNNEL_STOPPED");
        assert_eq!(status.state.phase, ConnectionPhase::Disconnected);
    }
}
