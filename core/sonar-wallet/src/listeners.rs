use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::traits::WalletEventListener;
use crate::types::WalletEvent;

/// Shared listener registry for backends: id allocation, removal, and
/// snapshot-before-dispatch so a listener can remove itself (or others) from
/// inside a callback without deadlocking.
#[derive(Default)]
pub struct ListenerRegistry {
    next_id: AtomicU64,
    listeners: Mutex<HashMap<u64, Arc<dyn WalletEventListener>>>,
}

impl ListenerRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&self, listener: Arc<dyn WalletEventListener>) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.listeners
            .lock()
            .expect("listener lock poisoned")
            .insert(id, listener);
        id
    }

    pub fn remove(&self, id: u64) {
        self.listeners
            .lock()
            .expect("listener lock poisoned")
            .remove(&id);
    }

    pub fn dispatch(&self, event: &WalletEvent) {
        let snapshot: Vec<Arc<dyn WalletEventListener>> = self
            .listeners
            .lock()
            .expect("listener lock poisoned")
            .values()
            .cloned()
            .collect();
        for listener in snapshot {
            listener.on_event(event.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    struct Counting(AtomicUsize);
    impl WalletEventListener for Counting {
        fn on_event(&self, _event: WalletEvent) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[test]
    fn add_dispatch_remove() {
        let reg = ListenerRegistry::new();
        let l = Arc::new(Counting(AtomicUsize::new(0)));
        let id = reg.add(l.clone());
        reg.dispatch(&WalletEvent::Connected);
        assert_eq!(l.0.load(Ordering::Relaxed), 1);
        reg.remove(id);
        reg.dispatch(&WalletEvent::Disconnected);
        assert_eq!(l.0.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn listener_may_remove_itself_during_dispatch() {
        struct SelfRemoving {
            reg: Arc<ListenerRegistry>,
            id: Mutex<Option<u64>>,
        }
        impl WalletEventListener for SelfRemoving {
            fn on_event(&self, _event: WalletEvent) {
                if let Some(id) = *self.id.lock().unwrap() {
                    self.reg.remove(id);
                }
            }
        }
        let reg = Arc::new(ListenerRegistry::new());
        let listener = Arc::new(SelfRemoving {
            reg: reg.clone(),
            id: Mutex::new(None),
        });
        let id = reg.add(listener.clone());
        *listener.id.lock().unwrap() = Some(id);
        // Must not deadlock, and the second dispatch reaches nobody.
        reg.dispatch(&WalletEvent::Connected);
        reg.dispatch(&WalletEvent::Connected);
    }
}
