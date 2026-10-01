// Cancellation is scoped to the single engine worker, never to cleanup.
use std::{
    cell::RefCell,
    collections::VecDeque,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
};
use vpn_service_core::BackendFailure;

#[derive(Default)]
pub struct Signal {
    epoch: AtomicU64,
    revoked: Mutex<VecDeque<String>>,
}
impl Signal {
    pub fn generation(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }
    pub fn cancel(&self, operation: &str) {
        let mut revoked = self
            .revoked
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if revoked.len() == 128 {
            revoked.pop_front();
        }
        revoked.push_back(operation.to_owned());
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }
    fn cancelled(&self, expected: u64, operation: &str) -> bool {
        self.generation() != expected
            || self
                .revoked
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter()
                .any(|id| id == operation)
    }
}

thread_local! {
    static ATTEMPT: RefCell<Option<(Arc<Signal>, u64, String)>> = const { RefCell::new(None) };
}

pub struct Attempt;
impl Attempt {
    pub fn enter(epoch: Arc<Signal>, expected: u64, operation: String) -> Self {
        ATTEMPT.with(|slot| *slot.borrow_mut() = Some((epoch, expected, operation)));
        Self
    }
}
impl Drop for Attempt {
    fn drop(&mut self) {
        ATTEMPT.with(|slot| *slot.borrow_mut() = None);
    }
}

pub fn check() -> Result<(), BackendFailure> {
    ATTEMPT.with(|slot| {
        if slot
            .borrow()
            .as_ref()
            .is_some_and(|(epoch, expected, operation)| epoch.cancelled(*expected, operation))
        {
            Err(BackendFailure::Cancelled)
        } else {
            Ok(())
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_affects_only_the_old_attempt_not_cleanup_or_retry() {
        let epoch = Arc::new(Signal::default());
        let attempt = Attempt::enter(epoch.clone(), 0, "first".into());
        assert_eq!(check(), Ok(()));
        epoch.cancel("first");
        assert_eq!(check(), Err(BackendFailure::Cancelled));
        drop(attempt);
        assert_eq!(check(), Ok(()));
        let late = Attempt::enter(epoch.clone(), 1, "first".into());
        assert_eq!(check(), Err(BackendFailure::Cancelled));
        drop(late);
        let _next = Attempt::enter(epoch, 1, "second".into());
        assert_eq!(check(), Ok(()));
    }
}
