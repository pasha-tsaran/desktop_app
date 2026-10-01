// Local-only, bounded named-pipe transport for the privileged service.

use super::connection_cancel::Signal;
use std::sync::{mpsc, Arc};
use std::{ffi::c_void, io, mem::size_of, os::windows::io::AsRawHandle, ptr};

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::windows::named_pipe::{NamedPipeServer, PipeMode, ServerOptions},
    sync::{oneshot, watch},
};
use vpn_contracts::{
    declared_frame_size, decode_request, encode_response, ConnectionPhase, ResponseEnvelope,
    CONTRACT_VERSION,
};
use vpn_service_core::{
    AuthorizationContext, CommandError, ProfileVault, ServiceCommandProcessor, VpnBackend,
};

use super::profile_vault::DpapiProfileVault;
use super::windows_backend::WindowsVpnBackend;
use windows_sys::Win32::{
    Foundation::LocalFree,
    Security::{
        Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1},
        PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES,
    },
    System::{
        Pipes::GetNamedPipeClientProcessId,
        RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId},
    },
};

const PIPE_NAME: &str = r"\\.\pipe\KenaiVpnControl-v4";
const HEADER_SIZE: usize = 12;
const INVALID_REQUEST_ID: &str = "invalid-request";

struct Work {
    frame: Vec<u8>,
    authorization: AuthorizationContext,
    epoch: u64,
    reply: oneshot::Sender<ResponseEnvelope>,
}

async fn start_worker(
    epoch: Arc<Signal>,
) -> io::Result<(mpsc::SyncSender<Work>, std::thread::JoinHandle<()>)> {
    let (sender, receiver) = mpsc::sync_channel::<Work>(16);
    let (ready, initialized) = oneshot::channel();
    let worker = std::thread::Builder::new()
        .name("kenai-engine".into())
        .spawn(move || {
            // Create and retain all native handles on their owning worker thread.
            let initialized = (|| {
                Ok::<_, io::Error>(ServiceCommandProcessor::with_backend(
                    DpapiProfileVault::system_default()?,
                    WindowsVpnBackend::system_default()?,
                ))
            })();
            let mut processor = match initialized {
                Ok(processor) => {
                    let _ = ready.send(Ok(()));
                    processor
                }
                Err(error) => {
                    let _ = ready.send(Err(error));
                    return;
                }
            };
            while let Ok(work) = receiver.recv() {
                let operation = decode_request(&work.frame)
                    .ok()
                    .and_then(|request| match request.command {
                        vpn_contracts::ControlCommand::Connect(connect) => {
                            Some(connect.operation_id)
                        }
                        _ => None,
                    });
                let _attempt = operation.map(|id| {
                    super::connection_cancel::Attempt::enter(epoch.clone(), work.epoch, id)
                });
                let response = process_frame(&work.frame, work.authorization, &mut processor);
                let _ = work.reply.send(response);
            }
        })?;
    initialized
        .await
        .map_err(|_| io::Error::other("engine worker unavailable"))??;
    Ok((sender, worker))
}

pub async fn serve(shutdown: watch::Receiver<bool>) -> io::Result<()> {
    let epoch = Arc::new(Signal::default());
    let (worker, thread) = start_worker(epoch.clone()).await?;
    let result = serve_clients(shutdown, worker.clone(), epoch.clone()).await;
    epoch.cancel("shutdown");
    drop(worker);
    // Wait for cancelled work and native cleanup before reporting SCM Stopped.
    let joined = tokio::task::spawn_blocking(move || thread.join()).await;
    result?;
    joined
        .map_err(|_| io::Error::other("worker join failed"))?
        .map_err(|_| io::Error::other("engine worker failed"))
}

async fn serve_clients(
    mut shutdown: watch::Receiver<bool>,
    worker: mpsc::SyncSender<Work>,
    epoch: Arc<Signal>,
) -> io::Result<()> {
    let security = PipeSecurity::new()?;
    let mut clients = tokio::task::JoinSet::new();
    let mut server = security.create_server(PIPE_NAME, true)?;

    loop {
        if *shutdown.borrow() {
            epoch.cancel("shutdown");
            return Ok(());
        }
        let connection_result = tokio::select! {
            result = server.connect() => result,
            result = shutdown.changed() => {
                let _ = result;
                epoch.cancel("shutdown");
                return Ok(());
            },
            _ = clients.join_next(), if !clients.is_empty() => continue,
        };
        if let Err(error) = connection_result {
            if !matches!(error.raw_os_error(), Some(109 | 232 | 233)) {
                return Err(error);
            }
            let replacement = create_next_listener(&security, PIPE_NAME).await?;
            drop(ConnectedPipe(std::mem::replace(&mut server, replacement)));
            continue;
        }
        let replacement = create_next_listener(&security, PIPE_NAME).await?;
        let mut connected = ConnectedPipe(std::mem::replace(&mut server, replacement));

        // A client can disconnect before its process/session can be queried.
        // That must not take the only listener down for all later clients.
        let Ok(authorization) = caller_authorization(&connected.0) else {
            continue;
        };
        if !authorization.is_allowed() {
            continue;
        }
        if clients.len() >= 8 {
            continue;
        }
        let worker = worker.clone();
        let epoch = epoch.clone();
        clients.spawn(async move {
            let _ = handle_worker(&mut connected.0, authorization, worker, epoch).await;
        });
    }
}

async fn handle_worker(
    server: &mut NamedPipeServer,
    authorization: AuthorizationContext,
    worker: mpsc::SyncSender<Work>,
    epoch: Arc<Signal>,
) -> io::Result<()> {
    // Untrusted partial frames cannot monopolize a listener indefinitely.
    if !authorization.is_allowed() {
        return Ok(());
    }
    let frame = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let mut header = [0_u8; HEADER_SIZE];
        server.read_exact(&mut header).await?;
        let size = declared_frame_size(&header).map_err(|_| io::Error::other("invalid frame"))?;
        let mut frame = vec![0; size];
        frame[..HEADER_SIZE].copy_from_slice(&header);
        server.read_exact(&mut frame[HEADER_SIZE..]).await?;
        Ok::<_, io::Error>(frame)
    })
    .await
    .map_err(|_| io::Error::other("request timed out"))??;
    let Ok(request) = decode_request(&frame) else {
        return write_safe_error(server, INVALID_REQUEST_ID, "INVALID_REQUEST").await;
    };
    // Only an authenticated, fully decoded typed Disconnect may cancel.
    // Capture the epoch at ingress, so queued old Connects are cancelled too.
    if let vpn_contracts::ControlCommand::Disconnect { operation_id } = &request.command {
        epoch.cancel(operation_id);
    }
    let expected = epoch.generation();
    let (reply, response) = oneshot::channel();
    if worker
        .try_send(Work {
            frame,
            authorization,
            epoch: expected,
            reply,
        })
        .is_err()
    {
        return write_safe_error(server, &request.request_id, "BUSY").await;
    }
    match response.await {
        Ok(response) => write_response(server, response).await,
        Err(_) => write_safe_error(server, &request.request_id, "SERVICE_UNAVAILABLE").await,
    }
}

// Tokio/Mio can retain a closing pipe until its cancelled overlapped I/O is
// dispatched. Let the I/O reactor complete that work before replacing it.
// Keep fresh Tokio objects: reusing a disconnected object retains read errors.
async fn create_next_listener(security: &PipeSecurity, name: &str) -> io::Result<NamedPipeServer> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        match security.create_server(name, false) {
            Ok(server) => return Ok(server),
            Err(error)
                if error.raw_os_error() == Some(231) && std::time::Instant::now() < deadline =>
            {
                tokio::time::sleep(std::time::Duration::from_millis(1)).await;
            }
            Err(error) => return Err(error),
        }
    }
}

struct ConnectedPipe(NamedPipeServer);

impl Drop for ConnectedPipe {
    fn drop(&mut self) {
        let _ = self.0.disconnect();
    }
}

#[cfg(test)]
async fn handle_one(
    server: &mut NamedPipeServer,
    authorization: AuthorizationContext,
    processor: &mut ServiceCommandProcessor<impl ProfileVault, impl VpnBackend>,
) -> io::Result<()> {
    let mut header = [0_u8; HEADER_SIZE];
    if server.read_exact(&mut header).await.is_err() {
        return Ok(());
    }
    let Ok(total_size) = declared_frame_size(&header) else {
        return write_safe_error(server, INVALID_REQUEST_ID, "INVALID_REQUEST").await;
    };
    let mut frame = Vec::with_capacity(total_size);
    frame.extend_from_slice(&header);
    frame.resize(total_size, 0);
    if server.read_exact(&mut frame[HEADER_SIZE..]).await.is_err() {
        return Ok(());
    }

    let response = process_frame(&frame, authorization, processor);
    write_response(server, response).await
}

fn process_frame<V: ProfileVault, B: VpnBackend>(
    frame: &[u8],
    authorization: AuthorizationContext,
    processor: &mut ServiceCommandProcessor<V, B>,
) -> ResponseEnvelope {
    let Ok(request) = decode_request(frame) else {
        return safe_error(INVALID_REQUEST_ID, "INVALID_REQUEST");
    };
    let request_id = request.request_id.clone();
    if !authorization.is_allowed() {
        return safe_command_error(request_id, &CommandError::UnauthorizedCaller);
    }
    // A rapid second click can reach the pipe before the original Connect.
    // Discard that revoked attempt without changing the disconnected state.
    if matches!(request.command, vpn_contracts::ControlCommand::Connect(_))
        && super::connection_cancel::check().is_err()
    {
        return safe_error(&request_id, "CONNECTION_CANCELLED");
    }
    match processor.process(authorization, request) {
        Ok(outcome) => ResponseEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: outcome.request_id,
            phase: outcome.state.phase,
            profile_id: outcome.state.profile_id,
            kill_switch_active: outcome.state.kill_switch_active,
            code: outcome.code.into(),
            statistics: outcome.statistics,
        },
        Err(error) => safe_command_error(request_id, &error),
    }
}

fn safe_command_error(request_id: String, error: &CommandError) -> ResponseEnvelope {
    let code = match error {
        CommandError::Busy => "BUSY",
        CommandError::DuplicateRequest => "DUPLICATE_REQUEST",
        CommandError::EmptyOperationId
        | CommandError::EmptyProfileId
        | CommandError::InvalidFailurePhase
        | CommandError::InvalidProfile => "INVALID_REQUEST",
        CommandError::ProfileNotFound => "PROFILE_NOT_FOUND",
        CommandError::ProfileStoreUnavailable => "PROFILE_STORE_UNAVAILABLE",
        CommandError::UnauthorizedCaller => "UNAUTHORIZED",
    };
    ResponseEnvelope {
        contract_version: CONTRACT_VERSION,
        request_id,
        phase: ConnectionPhase::Error,
        profile_id: None,
        kill_switch_active: false,
        code: code.into(),
        statistics: None,
    }
}

async fn write_safe_error(
    server: &mut NamedPipeServer,
    request_id: &str,
    code: &str,
) -> io::Result<()> {
    write_response(server, safe_error(request_id, code)).await
}

fn safe_error(request_id: &str, code: &str) -> ResponseEnvelope {
    ResponseEnvelope {
        contract_version: CONTRACT_VERSION,
        request_id: request_id.into(),
        phase: ConnectionPhase::Error,
        profile_id: None,
        kill_switch_active: false,
        code: code.into(),
        statistics: None,
    }
}

async fn write_response(
    server: &mut NamedPipeServer,
    response: ResponseEnvelope,
) -> io::Result<()> {
    let bytes = encode_response(&response)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "safe response encoding failed"))?;
    server.write_all(&bytes).await?;
    server.flush().await?;
    // DisconnectNamedPipe discards unread buffered bytes. A normal client reads
    // the entire response and closes its handle; wait for that close before
    // recycling the instance. A lingering/malformed client gets at most 2s.
    let mut unexpected_byte = [0_u8; 1];
    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        server.read(&mut unexpected_byte),
    )
    .await;
    Ok(())
}

fn caller_authorization(server: &NamedPipeServer) -> io::Result<AuthorizationContext> {
    let handle = server.as_raw_handle();
    let mut process_id = 0_u32;
    let mut client_session_id = 0_u32;
    // SAFETY: Tokio owns a live connected pipe handle for the duration of both
    // calls, and both out-pointers refer to initialized local `u32` storage.
    let identified = unsafe {
        GetNamedPipeClientProcessId(handle, ptr::addr_of_mut!(process_id)) != 0
            && ProcessIdToSessionId(process_id, ptr::addr_of_mut!(client_session_id)) != 0
    };
    if !identified {
        return Err(io::Error::last_os_error());
    }
    let allowed_session_id = unsafe { WTSGetActiveConsoleSessionId() };
    Ok(AuthorizationContext {
        is_local: true,
        is_authenticated: true,
        client_session_id,
        allowed_session_id,
    })
}

struct PipeSecurity {
    descriptor: PSECURITY_DESCRIPTOR,
    attributes: SECURITY_ATTRIBUTES,
}

impl PipeSecurity {
    fn new() -> io::Result<Self> {
        // Protected DACL: deny anonymous/network tokens, allow SYSTEM and
        // Administrators full access, and authenticated users read/write.
        // The caller-session check narrows authenticated users after connect.
        let sddl = to_wide("D:P(D;;GA;;;AN)(D;;GA;;;NU)(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)");
        let mut descriptor = ptr::null_mut();
        // SAFETY: `sddl` is NUL-terminated and lives through the call;
        // `descriptor` is a valid out-pointer released with `LocalFree`.
        let converted = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                ptr::addr_of_mut!(descriptor),
                ptr::null_mut(),
            )
        };
        if converted == 0 {
            return Err(io::Error::last_os_error());
        }
        let length = u32::try_from(size_of::<SECURITY_ATTRIBUTES>())
            .map_err(|_| io::Error::other("invalid security attributes size"))?;
        Ok(Self {
            descriptor,
            attributes: SECURITY_ATTRIBUTES {
                nLength: length,
                lpSecurityDescriptor: descriptor.cast::<c_void>(),
                bInheritHandle: 0,
            },
        })
    }

    fn create_server(&self, name: &str, first: bool) -> io::Result<NamedPipeServer> {
        let mut options = ServerOptions::new();
        options
            .first_pipe_instance(first)
            .pipe_mode(PipeMode::Byte)
            .reject_remote_clients(true)
            .max_instances(16)
            .in_buffer_size(u32::try_from(vpn_contracts::MAX_FRAME_SIZE).unwrap_or(16_384))
            .out_buffer_size(u32::try_from(vpn_contracts::MAX_FRAME_SIZE).unwrap_or(16_384));
        // SAFETY: `self.attributes` and its descriptor remain alive for the
        // synchronous pipe creation call. Tokio does not retain this pointer.
        unsafe {
            options.create_with_security_attributes_raw(
                name,
                ptr::from_ref(&self.attributes).cast_mut().cast::<c_void>(),
            )
        }
    }
}

impl Drop for PipeSecurity {
    fn drop(&mut self) {
        if !self.descriptor.is_null() {
            // SAFETY: the descriptor was allocated by the SDDL conversion API
            // and is freed exactly once here.
            unsafe {
                LocalFree(self.descriptor.cast::<c_void>());
            }
        }
    }
}

fn to_wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::windows::named_pipe::ClientOptions;
    use vpn_contracts::{encode_request, ControlCommand, RequestEnvelope};

    #[test]
    fn a_connect_arriving_after_its_cancel_does_not_change_service_state() {
        let epoch = Arc::new(Signal::default());
        epoch.cancel("late-connect");
        let _attempt = super::super::connection_cancel::Attempt::enter(
            epoch.clone(),
            epoch.generation(),
            "late-connect".into(),
        );
        let authorization = AuthorizationContext {
            is_local: true,
            is_authenticated: true,
            client_session_id: 1,
            allowed_session_id: 1,
        };
        let mut processor = ServiceCommandProcessor::default();
        let request = RequestEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: "late-request".into(),
            command: ControlCommand::Connect(vpn_contracts::ConnectRequest {
                operation_id: "late-connect".into(),
                profile_id: "not-loaded".into(),
                protocol: vpn_contracts::Protocol::VlessReality,
                kill_switch: false,
            }),
        };
        let result = process_frame(
            &encode_request(&request).unwrap(),
            authorization,
            &mut processor,
        );
        assert_eq!(result.code, "CONNECTION_CANCELLED");
        let status = RequestEnvelope {
            command: ControlCommand::Status,
            request_id: "status".into(),
            ..request
        };
        let result = process_frame(
            &encode_request(&status).unwrap(),
            authorization,
            &mut processor,
        );
        assert_eq!(result.phase, ConnectionPhase::Disconnected);
        assert_eq!(result.code, "OK");
    }

    async fn exchange(name: &str, command: ControlCommand, id: &str) -> ResponseEnvelope {
        let mut client = ClientOptions::new().open(name).unwrap();
        let request = RequestEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: id.into(),
            command,
        };
        client
            .write_all(&encode_request(&request).unwrap())
            .await
            .unwrap();
        let mut header = [0; HEADER_SIZE];
        client.read_exact(&mut header).await.unwrap();
        let mut frame = vec![0; declared_frame_size(&header).unwrap()];
        frame[..HEADER_SIZE].copy_from_slice(&header);
        client.read_exact(&mut frame[HEADER_SIZE..]).await.unwrap();
        vpn_contracts::decode_response(&frame).unwrap()
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)] // Keep the two clients and isolated worker in one test.
    async fn disconnect_reaches_a_busy_worker_through_a_second_pipe() {
        let name = format!(r"\\.\pipe\KenaiVpnCancelTest-{}", std::process::id());
        let security = PipeSecurity::new().unwrap();
        let first = security.create_server(&name, true).unwrap();
        let second = security.create_server(&name, false).unwrap();
        let epoch = Arc::new(Signal::default());
        let (sender, receiver) = mpsc::sync_channel::<Work>(4);
        let (started, ready) = oneshot::channel();
        let worker_epoch = epoch.clone();
        // No native engine, route, firewall, account or real service is touched.
        let worker = std::thread::spawn(move || {
            let work = receiver.recv().unwrap();
            let request = decode_request(&work.frame).unwrap();
            let ControlCommand::Connect(connect) = request.command else {
                panic!("connect first")
            };
            let attempt = super::super::connection_cancel::Attempt::enter(
                worker_epoch,
                work.epoch,
                connect.operation_id,
            );
            started.send(()).unwrap();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            while super::super::connection_cancel::check().is_ok() {
                assert!(
                    std::time::Instant::now() < deadline,
                    "cancellation was blocked behind connect"
                );
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            drop(attempt);
            work.reply
                .send(safe_error(&request.request_id, "CONNECTION_CANCELLED"))
                .unwrap();
            let work = receiver.recv().unwrap();
            let request = decode_request(&work.frame).unwrap();
            assert!(matches!(request.command, ControlCommand::Disconnect { .. }));
            work.reply
                .send(ResponseEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: request.request_id,
                    phase: ConnectionPhase::Disconnected,
                    profile_id: None,
                    kill_switch_active: true,
                    code: "DISCONNECTED".into(),
                    statistics: None,
                })
                .unwrap();
        });
        let authorization = AuthorizationContext {
            is_local: true,
            is_authenticated: true,
            client_session_id: 1,
            allowed_session_id: 1,
        };
        let first_sender = sender.clone();
        let first_epoch = epoch.clone();
        let servers = async move {
            tokio::join!(
                async move {
                    first.connect().await.unwrap();
                    let mut pipe = ConnectedPipe(first);
                    handle_worker(&mut pipe.0, authorization, first_sender, first_epoch)
                        .await
                        .unwrap();
                },
                async move {
                    second.connect().await.unwrap();
                    let mut pipe = ConnectedPipe(second);
                    handle_worker(&mut pipe.0, authorization, sender, epoch)
                        .await
                        .unwrap();
                }
            );
        };
        let clients = async {
            let connect = exchange(
                &name,
                ControlCommand::Connect(vpn_contracts::ConnectRequest {
                    operation_id: "pending".into(),
                    profile_id: "test-profile".into(),
                    protocol: vpn_contracts::Protocol::AmneziaWg,
                    kill_switch: true,
                }),
                "connect-request",
            );
            let cancel = async {
                ready.await.unwrap();
                exchange(
                    &name,
                    ControlCommand::Disconnect {
                        operation_id: "pending".into(),
                    },
                    "cancel-request",
                )
                .await
            };
            let (connect, cancel) = tokio::join!(connect, cancel);
            assert_eq!(connect.code, "CONNECTION_CANCELLED");
            assert_eq!(cancel.phase, ConnectionPhase::Disconnected);
            assert!(cancel.kill_switch_active);
        };
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            tokio::join!(servers, clients);
        })
        .await
        .unwrap();
        worker.join().unwrap();
    }

    #[tokio::test]
    async fn recycling_waits_until_the_client_has_received_the_response() {
        let name = format!(r"\\.\pipe\KenaiVpnResponseTest-{}", std::process::id());
        let security = PipeSecurity::new().expect("test pipe security");
        let server = security.create_server(&name, true).expect("listener");
        let mut client = ClientOptions::new().open(&name).expect("client");
        server.connect().await.expect("connection");
        let response = safe_error("response-test", "OK");
        let expected = encode_response(&response).expect("encoded response");
        let expected_length = expected.len();
        let (sent, received) = tokio::join!(
            async {
                let mut connection = ConnectedPipe(server);
                write_response(&mut connection.0, response).await
            },
            async move {
                tokio::task::yield_now().await;
                let mut received = vec![0_u8; expected_length];
                client
                    .read_exact(&mut received)
                    .await
                    .expect("complete response");
                drop(client);
                received
            }
        );
        sent.expect("response sent");
        assert_eq!(received, expected);
    }

    #[tokio::test]
    async fn disconnected_client_does_not_hold_a_pipe_instance() {
        let name = format!(r"\\.\pipe\KenaiVpnEarlyCloseTest-{}", std::process::id());
        let security = PipeSecurity::new().expect("test pipe security");
        let first = security.create_server(&name, true).expect("listener");
        let client = ClientOptions::new().open(&name).expect("early client");
        drop(client);
        first.connect().await.expect("closed connection");
        let second = create_next_listener(&security, &name)
            .await
            .expect("second listener");
        drop(ConnectedPipe(first));
        let next_client = ClientOptions::new().open(&name).expect("next client");
        second.connect().await.expect("next connection");
        let third = create_next_listener(&security, &name)
            .await
            .expect("third listener");
        drop((ConnectedPipe(second), third));
        drop(next_client);
    }

    #[tokio::test]
    async fn repeated_requests_with_lingering_clients_reuse_bounded_instances() {
        let name = format!(r"\\.\pipe\KenaiVpnLingerTest-{}", std::process::id());
        let security = PipeSecurity::new().expect("test pipe security");
        let mut server = security.create_server(&name, true).expect("first listener");
        let mut clients = Vec::new();
        for _ in 0..100 {
            clients.push(ClientOptions::new().open(&name).expect("client"));
            server.connect().await.expect("connection");
            let replacement = create_next_listener(&security, &name)
                .await
                .expect("replacement");
            let connected = ConnectedPipe(std::mem::replace(&mut server, replacement));
            drop(connected);
        }
    }

    #[tokio::test]
    async fn one_hundred_complete_status_exchanges_keep_working() {
        let name = format!(r"\\.\pipe\KenaiVpnExchangeTest-{}", std::process::id());
        let security = PipeSecurity::new().expect("pipe security");
        let mut listener = security.create_server(&name, true).expect("listener");
        let mut processor = ServiceCommandProcessor::default();
        let authorization = AuthorizationContext {
            is_local: true,
            is_authenticated: true,
            client_session_id: 1,
            allowed_session_id: 1,
        };
        let server_loop = async {
            for _ in 0..100 {
                listener.connect().await.expect("accept");
                let next = create_next_listener(&security, &name)
                    .await
                    .expect("next listener");
                let mut connection = ConnectedPipe(std::mem::replace(&mut listener, next));
                handle_one(&mut connection.0, authorization, &mut processor)
                    .await
                    .expect("request");
            }
        };
        let client_loop = async {
            for i in 0..100 {
                let mut client = loop {
                    match ClientOptions::new().open(&name) {
                        Ok(client) => break client,
                        Err(error) if error.raw_os_error() == Some(231) => {
                            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
                        }
                        Err(error) => panic!("client open: {error}"),
                    }
                };
                let id = format!("test-{i}");
                let request = RequestEnvelope {
                    contract_version: CONTRACT_VERSION,
                    request_id: id.clone(),
                    command: ControlCommand::Status,
                };
                client
                    .write_all(&encode_request(&request).expect("request frame"))
                    .await
                    .expect("write");
                let mut header = [0_u8; HEADER_SIZE];
                client
                    .read_exact(&mut header)
                    .await
                    .expect("response header");
                let size = declared_frame_size(&header).expect("response size");
                let mut frame = vec![0_u8; size];
                frame[..HEADER_SIZE].copy_from_slice(&header);
                client
                    .read_exact(&mut frame[HEADER_SIZE..])
                    .await
                    .expect("response body");
                let response = vpn_contracts::decode_response(&frame).expect("response");
                assert_eq!(response.request_id, id);
                assert_eq!(response.code, "OK");
            }
        };
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            tokio::join!(server_loop, client_loop);
        })
        .await
        .expect("bounded status stress test");
    }

    #[tokio::test]
    async fn a_second_listener_stays_available_while_first_client_is_open() {
        let name = format!(r"\\.\pipe\KenaiVpnTest-{}", std::process::id());
        let security = PipeSecurity::new().expect("test pipe security");
        let first = security
            .create_server(&name, true)
            .expect("first pipe instance");
        let first_client = ClientOptions::new().open(&name).expect("first client");
        first.connect().await.expect("first connection");

        let second = security
            .create_server(&name, false)
            .expect("replacement listener while first client remains open");
        let second_client = ClientOptions::new().open(&name).expect("second client");
        second.connect().await.expect("second connection");

        drop(first_client);
        drop(second_client);
    }

    #[test]
    fn command_errors_are_reduced_to_allow_listed_codes() {
        for (error, expected) in [
            (CommandError::Busy, "BUSY"),
            (CommandError::DuplicateRequest, "DUPLICATE_REQUEST"),
            (CommandError::EmptyProfileId, "INVALID_REQUEST"),
            (CommandError::UnauthorizedCaller, "UNAUTHORIZED"),
        ] {
            assert_eq!(
                safe_command_error("request-1".into(), &error).code,
                expected
            );
        }
    }

    #[test]
    fn malformed_and_unauthorized_frames_never_expose_internal_details() {
        let mut processor = ServiceCommandProcessor::default();
        let authorized = AuthorizationContext {
            is_local: true,
            is_authenticated: true,
            client_session_id: 3,
            allowed_session_id: 3,
        };
        let malformed = process_frame(b"not a frame", authorized, &mut processor);
        assert_eq!(malformed.request_id, INVALID_REQUEST_ID);
        assert_eq!(malformed.code, "INVALID_REQUEST");

        let request = RequestEnvelope {
            contract_version: CONTRACT_VERSION,
            request_id: "status-1".into(),
            command: ControlCommand::Status,
        };
        let frame = encode_request(&request).expect("valid frame");
        let unauthorized = process_frame(
            &frame,
            AuthorizationContext {
                is_local: true,
                is_authenticated: true,
                client_session_id: 2,
                allowed_session_id: 3,
            },
            &mut processor,
        );
        assert_eq!(unauthorized.request_id, "status-1");
        assert_eq!(unauthorized.code, "UNAUTHORIZED");
        assert_eq!(unauthorized.profile_id, None);
    }
}
