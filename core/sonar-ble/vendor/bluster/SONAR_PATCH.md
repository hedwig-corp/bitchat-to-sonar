# Vendored + patched bluster 0.2.0

Vendored from crates.io `bluster v0.2.0` (MIT licensed, see `LICENSE`). The Sonar
changes are listed below. Every Sonar edit is marked `PATCH (Sonar)` at its
site; grep for that marker before assuming a hunk is upstream.

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

## 3. Insecure write advertises both write types (Linux)

`src/peripheral/bluez/gatt/flags.rs`: bluster models `Write` as either
`WithResponse` or `WithoutResponse`, so an insecure write characteristic
advertised only the `write` flag and a central writing without a response was
refused with NOTSUPPORTED.

Both phone platforms use both types on the bitchat characteristic (iOS
`[.notify, .write, .writeWithoutResponse, .read]`, Android `PROPERTY_WRITE |
PROPERTY_WRITE_NO_RESPONSE | PROPERTY_NOTIFY`), so the Linux GATT server has to
offer both or half the writes fail. This is the BlueZ mirror of patch 4's
CoreBluetooth change. BlueZ routes both write types to the same `WriteValue`
handler, so no extra event handling is needed.

## 4. Never-type fallback in the BlueZ backend (Linux)

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

## 5. Other CoreBluetooth changes

`src/peripheral/corebluetooth/characteristic_flags.rs` also advertises
write-WITHOUT-response, and `src/peripheral/corebluetooth/events.rs` fills in
callbacks that upstream left as stubs. Both are Sonar changes rather than
upstream code.

Patches 1, 2 and 5 touch only the macOS (CoreBluetooth) path; patches 3 and 4
touch only the Linux (BlueZ) path. Anything without a `PATCH (Sonar)` marker should be
upstream `bluster`, but verify with the marker rather than trusting this list to
be exhaustive when rebasing the vendor drop.
