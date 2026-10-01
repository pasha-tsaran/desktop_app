// Only callers construct fixed, allow-listed engine commands. Bound waits so
// an engine utility cannot leave the service worker stuck indefinitely.
use std::{
    io::Read,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use vpn_service_core::BackendFailure;

pub fn output(command: &mut Command, timeout: Duration) -> Result<Vec<u8>, BackendFailure> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| BackendFailure::EngineUnavailable)?;
    let stdout = child.stdout.take().ok_or(BackendFailure::Internal)?;
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout
            .take(16 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    });
    let deadline = Instant::now() + timeout;
    let result = loop {
        if let Err(error) = super::connection_cancel::check() {
            break Err(error);
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                break if status.success() {
                    Ok(())
                } else {
                    Err(BackendFailure::Internal)
                }
            }
            Err(_) => break Err(BackendFailure::Internal),
            Ok(None) => (),
        }
        if Instant::now() >= deadline {
            break Err(BackendFailure::Internal);
        }
        thread::sleep(Duration::from_millis(25));
    };
    if result.is_err() {
        let _ = child.kill();
    }
    let _ = child.wait();
    let bytes = reader
        .join()
        .map_err(|_| BackendFailure::Internal)?
        .map_err(|_| BackendFailure::Internal)?;
    result?;
    if bytes.len() > 16 * 1024 {
        return Err(BackendFailure::Internal);
    }
    Ok(bytes)
}
