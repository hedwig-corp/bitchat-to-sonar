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
pub static WRITE_QUEUE: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

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
            }
            CBManagerState::CBManagerStateResetting => {
                println!("CBManagerStateResetting");
            }
            CBManagerState::CBManagerStateUnsupported => {
                println!("CBManagerStateUnsupported");
            }
            CBManagerState::CBManagerStateUnauthorized => {
                println!("CBManagerStateUnauthorized");
            }
            CBManagerState::CBManagerStatePoweredOff => {
                println!("CBManagerStatePoweredOff");
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
                if !bytes.is_empty() {
                    if let Ok(mut q) = WRITE_QUEUE.lock() {
                        if q.len() < 256 {
                            q.push(bytes);
                        }
                    }
                }
            }
            let _: Result<(), ()> = msg_send![peripheral, respondToRequest:request
                                        withResult:CBATTError::CBATTErrorSuccess];
        }
    }
}
