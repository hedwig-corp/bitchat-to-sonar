use std::sync::Mutex;

use objc::{msg_send, runtime::{BOOL, NO, Object, Sel, YES}, sel, sel_impl};
use objc_foundation::{INSArray, INSData, INSString, NSArray, NSData, NSObject, NSString};

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
    subscribers: usize,
    epoch: u64,
}

static SUBSCRIPTION_STATE: Mutex<SubscriptionState> = Mutex::new(SubscriptionState {
    subscribers: 0,
    epoch: 1,
});

fn next_subscription_epoch(state: &mut SubscriptionState) {
    state.epoch = state.epoch.wrapping_add(1).max(1);
}

pub fn reset_subscriptions() {
    if let Ok(mut state) = SUBSCRIPTION_STATE.lock() {
        state.subscribers = 0;
        next_subscription_epoch(&mut state);
    }
}

pub fn subscription_token() -> u64 {
    SUBSCRIPTION_STATE
        .lock()
        .map(|state| if state.subscribers == 1 { state.epoch } else { 0 })
        .unwrap_or(0)
}

fn subscription_started() {
    if let Ok(mut state) = SUBSCRIPTION_STATE.lock() {
        state.subscribers = state.subscribers.saturating_add(1);
        next_subscription_epoch(&mut state);
    }
}

fn subscription_ended() {
    if let Ok(mut state) = SUBSCRIPTION_STATE.lock() {
        state.subscribers = state.subscribers.saturating_sub(1);
        next_subscription_epoch(&mut state);
    }
}

pub extern "C" fn peripheral_manager_did_subscribe(
    _delegate: &mut Object,
    _cmd: Sel,
    _peripheral: *mut Object,
    _central: *mut Object,
    _characteristic: *mut Object,
) {
    subscription_started();
}

pub extern "C" fn peripheral_manager_did_unsubscribe(
    _delegate: &mut Object,
    _cmd: Sel,
    _peripheral: *mut Object,
    _central: *mut Object,
    _characteristic: *mut Object,
) {
    subscription_ended();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_identifies_one_subscription_and_invalidates_every_transition() {
        reset_subscriptions();
        assert_eq!(subscription_token(), 0);

        subscription_started();
        let first = subscription_token();
        assert_ne!(first, 0);

        subscription_started();
        assert_eq!(subscription_token(), 0);

        subscription_ended();
        let remaining = subscription_token();
        assert_ne!(remaining, 0);
        assert_ne!(remaining, first);

        subscription_ended();
        assert_eq!(subscription_token(), 0);
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
                let subscription_token = subscription_token();
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
