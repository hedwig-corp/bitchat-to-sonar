# Vendored + patched bluster 0.2.0

Vendored from crates.io `bluster v0.2.0` (MIT licensed, see `LICENSE`). Three
patches, described below.

## 1. CoreBluetooth advertises service UUIDs as `NSString` (macOS)

`src/peripheral/corebluetooth/peripheral_manager.rs`, `start_advertising`:
upstream builds the `CBAdvertisementDataServiceUUIDsKey` array out of **`NSString`**
objects. CoreBluetooth requires **`CBUUID`** objects there, so `startAdvertising`
fails with *"One or more parameters were invalid."* and the Mac never advertises.

The fix reuses bluster's own `IntoCBUUID` conversion (already used for GATT
services) to build the array from `CBUUID`s.

## 2. Notify + write-drain side channel (macOS only)

`Peripheral::notify` and `Peripheral::take_writes` (and their
`PeripheralManager` counterparts) are Sonar additions, marked `PATCH (Sonar)` at
each site. They exist **only** in the CoreBluetooth backend; the BlueZ backend
has no equivalent.

This is why `sonar-ble`'s `run_peripheral` is CoreBluetooth-only: it drives the
GATT server through this side channel rather than bluster's cross-platform
`gatt::event` channel. Bringing the peripheral/advertise role to Linux means
wiring `Event::NotifySubscribe` / `Event::Write` through the BlueZ backend's
event receiver, which is a different mechanism, not a port of this patch.

## 3. Never-type fallback in the BlueZ backend (Linux)

`src/peripheral/bluez/adapter.rs` (`powered`, `set_alias`) and
`src/peripheral/bluez/advertisement.rs` (`register`, `unregister`) call
`Proxy::method_call` and discard the reply, leaving the return type `R`
unconstrained. That relied on never-type fallback resolving `R` to `()`, which
`#[deny(dependency_on_unit_never_type_fallback)]` now rejects, and the crate failed
to build on stable rustc 1.96 with 8 errors, taking all of `core/build-desktop.sh`
down with it on Linux.

Each of the four calls is annotated `method_call::<(), _, _, _>(…)`, which is the
annotation rustc's own diagnostic suggests. No behavior change: `()` is what the
fallback resolved to anyway.

Patches 1 and 2 touch only the macOS (CoreBluetooth) path; patch 3 touches only
the Linux (BlueZ) path. Everything else is upstream `bluster` verbatim.
