use std::sync::Mutex;

use objc::{
    msg_send,
    runtime::{Object, Sel, BOOL, NO, YES},
    sel, sel_impl,
};
use objc_foundation::{INSArray, INSData, INSString, NSArray, NSData, NSObject, NSString};
use objc_id::{Id, Shared};

use super::{
    constants::POWERED_ON_IVAR,
    ffi::{CBATTError, CBManagerState},
    into_bool::IntoBool,
};

// PATCH (Sonar): upstream bluster's CoreBluetooth callbacks are stubs (see the
// TODO below) — write requests were acked but the bytes thrown away. Queue them
// so PeripheralManager::take_writes() can hand the central's packets (its
// announce / handshake) to the app.
pub static WRITE_QUEUE: Mutex<Vec<(u64, Vec<u8>)>> = Mutex::new(Vec::new());

// PATCH (Sonar): identify the current CoreBluetooth notification-subscription
// lifetime. Noise sessions bind to this token so a newly connected central can
// never make a historical session appear writable. Zero means there is not
// exactly one subscriber; this fails closed rather than notifying a private
// ciphertext to multiple centrals (the transport is intentionally single-peer).
struct SubscriptionState {
    subscriber_ids: Vec<String>,
    epoch: u64,
}

static SUBSCRIPTION_STATE: Mutex<SubscriptionState> = Mutex::new(SubscriptionState {
    subscriber_ids: Vec::new(),
    epoch: 1,
});
static SUBSCRIBED_CENTRALS: Mutex<Vec<(String, Id<NSObject, Shared>)>> = Mutex::new(Vec::new());

impl SubscriptionState {
    fn advance_epoch(&mut self) {
        self.epoch = self.epoch.wrapping_add(1).max(1);
    }

    fn start(&mut self, central_id: String) {
        if self.subscriber_ids.iter().any(|id| id == &central_id) {
            return;
        }
        self.subscriber_ids.push(central_id);
        self.advance_epoch();
    }

    fn end(&mut self, central_id: &str) {
        let before = self.subscriber_ids.len();
        self.subscriber_ids.retain(|id| id != central_id);
        if self.subscriber_ids.len() != before {
            self.advance_epoch();
        }
    }

    fn token(&self) -> u64 {
        if self.subscriber_ids.len() == 1 {
            self.epoch
        } else {
            0
        }
    }

    fn token_for(&self, central_id: &str) -> u64 {
        if self.subscriber_ids.len() == 1 && self.subscriber_ids[0] == central_id {
            self.epoch
        } else {
            0
        }
    }

    fn sole_central_id(&self, expected_token: u64) -> Option<&str> {
        if expected_token != 0 && self.token() == expected_token {
            self.subscriber_ids.first().map(String::as_str)
        } else {
            None
        }
    }
}

fn central_id(central: *mut Object) -> Option<String> {
    if central.is_null() {
        return None;
    }
    unsafe {
        let identifier: *mut Object = msg_send![central, identifier];
        if identifier.is_null() {
            return None;
        }
        let uuid_string: *mut Object = msg_send![identifier, UUIDString];
        if uuid_string.is_null() {
            return None;
        }
        Some((*(uuid_string as *mut NSString)).as_str().to_owned())
    }
}

pub fn reset_subscriptions() {
    if let Ok(mut state) = SUBSCRIPTION_STATE.lock() {
        state.subscriber_ids.clear();
        state.advance_epoch();
    }
    if let Ok(mut centrals) = SUBSCRIBED_CENTRALS.lock() {
        centrals.clear();
    }
}

pub fn subscription_token() -> u64 {
    SUBSCRIPTION_STATE
        .lock()
        .map(|state| state.token())
        .unwrap_or(0)
}

fn subscription_token_for_central(central_id: &str) -> u64 {
    SUBSCRIPTION_STATE
        .lock()
        .map(|state| state.token_for(central_id))
        .unwrap_or(0)
}

pub fn subscribed_central(expected_token: u64) -> Option<Id<NSObject, Shared>> {
    let central_id = SUBSCRIPTION_STATE
        .lock()
        .ok()
        .and_then(|state| state.sole_central_id(expected_token).map(str::to_owned))?;
    SUBSCRIBED_CENTRALS.lock().ok().and_then(|centrals| {
        centrals
            .iter()
            .find(|(id, _)| id == &central_id)
            .map(|(_, central)| central.clone())
    })
}

fn subscription_started(central: *mut Object) {
    let Some(central_id) = central_id(central) else {
        return;
    };
    if let Ok(mut state) = SUBSCRIPTION_STATE.lock() {
        state.start(central_id.clone());
    }
    if let Ok(mut centrals) = SUBSCRIBED_CENTRALS.lock() {
        centrals.retain(|(id, _)| id != &central_id);
        let retained = unsafe { Id::<NSObject, Shared>::from_ptr(central as *mut NSObject) };
        centrals.push((central_id, retained));
    }
}

fn subscription_ended(central: *mut Object) {
    let Some(central_id) = central_id(central) else {
        return;
    };
    if let Ok(mut state) = SUBSCRIPTION_STATE.lock() {
        state.end(&central_id);
    }
    if let Ok(mut centrals) = SUBSCRIBED_CENTRALS.lock() {
        centrals.retain(|(id, _)| id != &central_id);
    }
}

pub extern "C" fn peripheral_manager_did_subscribe(
    _delegate: &mut Object,
    _cmd: Sel,
    _peripheral: *mut Object,
    central: *mut Object,
    _characteristic: *mut Object,
) {
    subscription_started(central);
}

pub extern "C" fn peripheral_manager_did_unsubscribe(
    _delegate: &mut Object,
    _cmd: Sel,
    _peripheral: *mut Object,
    central: *mut Object,
    _characteristic: *mut Object,
) {
    subscription_ended(central);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_identifies_one_subscription_and_invalidates_every_transition() {
        let mut state = SubscriptionState {
            subscriber_ids: Vec::new(),
            epoch: 1,
        };
        assert_eq!(state.token(), 0);

        state.start("central-a".into());
        let first = state.token();
        assert_ne!(first, 0);
        assert_eq!(state.token_for("central-a"), first);
        assert_eq!(state.token_for("central-b"), 0);

        state.start("central-b".into());
        assert_eq!(state.token(), 0);
        assert_eq!(state.token_for("central-a"), 0);
        assert_eq!(state.token_for("central-b"), 0);

        state.end("central-a");
        let remaining = state.token();
        assert_ne!(remaining, 0);
        assert_ne!(remaining, first);
        assert_eq!(state.token_for("central-b"), remaining);

        state.end("central-b");
        assert_eq!(state.token(), 0);
    }

    #[test]
    fn duplicate_and_foreign_transitions_do_not_corrupt_the_epoch() {
        let mut state = SubscriptionState {
            subscriber_ids: Vec::new(),
            epoch: 9,
        };
        state.start("central-a".into());
        let first = state.token();

        state.start("central-a".into());
        state.end("not-subscribed");

        assert_eq!(state.token(), first);
        assert_eq!(state.sole_central_id(first), Some("central-a"));
    }
}

// TODO: Implement event stream for all below callback

pub extern "C" fn peripheral_manager_did_update_state(
    delegate: &mut Object,
    _cmd: Sel,
    peripheral: *mut Object,
) {
    println!("peripheral_manager_did_update_state");

    unsafe {
        let state: CBManagerState = msg_send![peripheral, state];
        match state {
            CBManagerState::CBManagerStateUnknown => {
                println!("CBManagerStateUnknown");
                reset_subscriptions();
            }
            CBManagerState::CBManagerStateResetting => {
                println!("CBManagerStateResetting");
                reset_subscriptions();
            }
            CBManagerState::CBManagerStateUnsupported => {
                println!("CBManagerStateUnsupported");
                reset_subscriptions();
            }
            CBManagerState::CBManagerStateUnauthorized => {
                println!("CBManagerStateUnauthorized");
                reset_subscriptions();
            }
            CBManagerState::CBManagerStatePoweredOff => {
                println!("CBManagerStatePoweredOff");
                reset_subscriptions();
                delegate.set_ivar::<BOOL>(POWERED_ON_IVAR, NO);
            }
            CBManagerState::CBManagerStatePoweredOn => {
                println!("CBManagerStatePoweredOn");
                delegate.set_ivar(POWERED_ON_IVAR, YES);
            }
        };
    }
}

pub extern "C" fn peripheral_manager_did_start_advertising_error(
    _delegate: &mut Object,
    _cmd: Sel,
    _peripheral: *mut Object,
    error: *mut Object,
) {
    println!("peripheral_manager_did_start_advertising_error");
    if error.into_bool() {
        let localized_description: *mut Object = unsafe { msg_send![error, localizedDescription] };
        let string = localized_description as *mut NSString;
        println!("{:?}", unsafe { (*string).as_str() });
    }
}

pub extern "C" fn peripheral_manager_did_add_service_error(
    _delegate: &mut Object,
    _cmd: Sel,
    _peripheral: *mut Object,
    _service: *mut Object,
    error: *mut Object,
) {
    println!("peripheral_manager_did_add_service_error");
    if error.into_bool() {
        let localized_description: *mut Object = unsafe { msg_send![error, localizedDescription] };
        let string = localized_description as *mut NSString;
        println!("{:?}", unsafe { (*string).as_str() });
    }
}

pub extern "C" fn peripheral_manager_did_receive_read_request(
    _delegate: &mut Object,
    _cmd: Sel,
    peripheral: *mut Object,
    request: *mut Object,
) {
    unsafe {
        let _: Result<(), ()> = msg_send![peripheral, respondToRequest:request
                                    withResult:CBATTError::CBATTErrorSuccess];
    }
}

pub extern "C" fn peripheral_manager_did_receive_write_requests(
    _delegate: &mut Object,
    _cmd: Sel,
    peripheral: *mut Object,
    requests: *mut Object,
) {
    unsafe {
        for request in (*(requests as *mut NSArray<NSObject>)).to_vec() {
            // PATCH (Sonar): capture the written bytes before acking.
            let value: *mut Object = msg_send![request, value];
            if !value.is_null() {
                let data = value as *mut NSData;
                let bytes = (*data).bytes().to_vec();
                let request_central: *mut Object = msg_send![request, central];
                let subscription_token = central_id(request_central)
                    .map(|id| subscription_token_for_central(&id))
                    .unwrap_or(0);
                if !bytes.is_empty() && subscription_token != 0 {
                    if let Ok(mut q) = WRITE_QUEUE.lock() {
                        if q.len() < 256 {
                            q.push((subscription_token, bytes));
                        }
                    }
                }
            }
            let _: Result<(), ()> = msg_send![peripheral, respondToRequest:request
                                        withResult:CBATTError::CBATTErrorSuccess];
        }
    }
}
