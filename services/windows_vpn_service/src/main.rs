//! Minimal Windows SCM lifecycle for Kenai VPN.
//!
//! Stage 8 intentionally starts no VPN engine. Its local named pipe has an
//! explicit DACL, rejects remote clients, and verifies the caller session.

#[cfg(windows)]
mod windows_service_host {
    use std::{error::Error, ffi::OsString, time::Duration};

    use tokio::{runtime::Builder, sync::watch};
    use windows_service::{
        define_windows_service,
        service::{
            ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
            ServiceType,
        },
        service_control_handler::{self, ServiceControlHandlerResult},
        service_dispatcher,
    };

    #[allow(unsafe_code)]
    mod ipc {
        include!("ipc.rs");
    }

    #[allow(unsafe_code)]
    mod profile_vault {
        include!("profile_vault.rs");
    }

    #[allow(unsafe_code)]
    mod wireguard_engine {
        include!("wireguard_engine.rs");
    }
    #[allow(unsafe_code)]
    mod amneziawg_engine {
        include!("amneziawg_engine.rs");
    }
    #[allow(unsafe_code)]
    mod executable_path {
        include!("executable_path.rs");
    }
    mod windows_backend {
        include!("windows_backend.rs");
    }
    mod connection_cancel {
        include!("connection_cancel.rs");
    }
    mod command_wait {
        include!("command_wait.rs");
    }
    #[allow(unsafe_code)]
    mod kill_switch {
        include!("kill_switch.rs");
    }
    #[allow(unsafe_code)]
    mod xray_engine {
        include!("xray_engine.rs");
    }
    #[allow(unsafe_code)]
    mod xray_network_policy {
        include!("xray_network_policy.rs");
    }
    #[allow(unsafe_code)]
    mod xray_dns_guard {
        include!("xray_dns_guard.rs");
    }
    mod data_plane_probe {
        include!("data_plane_probe.rs");
    }

    const SERVICE_NAME: &str = "KenaiVpnService";

    #[cfg(test)]
    fn test_payload_root(product: &str) -> std::path::PathBuf {
        let compiled = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("third_party")
            .join(product)
            .join("windows")
            .join("amd64");
        if compiled.is_dir() {
            return compiled;
        }
        let working = std::env::current_dir().expect("test working directory");
        working
            .ancestors()
            .map(|root| {
                root.join("third_party")
                    .join(product)
                    .join("windows")
                    .join("amd64")
            })
            .find(|candidate| candidate.is_dir())
            .expect("workspace payload directory")
    }

    define_windows_service!(ffi_service_main, service_main);

    pub fn run() -> windows_service::Result<()> {
        service_dispatcher::start(SERVICE_NAME, ffi_service_main)
    }

    pub fn run_entry() -> Result<(), Box<dyn Error>> {
        let arguments: Vec<OsString> = std::env::args_os().collect();
        if arguments.len() == 2 && arguments[1] == "/clear-kill-switch" {
            let guard = kill_switch::KillSwitch::open().map_err(|_| "KILL_SWITCH_UNAVAILABLE")?;
            guard
                .configure(false, None, None)
                .map_err(|_| "KILL_SWITCH_CLEANUP_FAILED")?;
            return Ok(());
        }
        if arguments.len() == 3 && arguments[1] == "/wireguard-service" {
            return wireguard_engine::run_tunnel_service(std::path::Path::new(&arguments[2]))
                .map_err(Into::into);
        }
        run().map_err(Into::into)
    }

    fn service_main(_arguments: Vec<OsString>) {
        if run_service().is_err() {
            eprintln!("Kenai VPN service stopped: SERVICE_RUNTIME_FAILED");
        }
    }

    fn run_service() -> Result<(), Box<dyn Error + Send + Sync>> {
        let (shutdown_sender, shutdown_receiver) = watch::channel(false);
        let event_handler = move |control_event| match control_event {
            ServiceControl::Stop => {
                let _ = shutdown_sender.send(true);
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            _ => ServiceControlHandlerResult::NotImplemented,
        };
        let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;

        status_handle.set_service_status(status(ServiceState::Running))?;
        let runtime = Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()?;
        let serve_result = runtime.block_on(ipc::serve(shutdown_receiver));
        // Report a stopped service even if listener initialization fails.
        // Otherwise SCM can keep reporting RUNNING with no named pipe.
        status_handle.set_service_status(status(ServiceState::Stopped))?;
        serve_result?;
        Ok(())
    }

    fn status(current_state: ServiceState) -> ServiceStatus {
        ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state,
            controls_accepted: if current_state == ServiceState::Running {
                ServiceControlAccept::STOP
            } else {
                ServiceControlAccept::empty()
            },
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::ZERO,
            process_id: None,
        }
    }
}

#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    windows_service_host::run_entry()
}

#[cfg(not(windows))]
fn main() {
    eprintln!("KenaiVpnService can run only under the Windows Service Control Manager");
}
