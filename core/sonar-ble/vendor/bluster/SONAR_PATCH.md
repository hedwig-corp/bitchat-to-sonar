# Vendored + patched bluster 0.2.0

Vendored from crates.io `bluster v0.2.0` (MIT licensed — see `LICENSE`) because
of one macOS bug we need fixed and can't get upstream in time.

## The patch

`src/peripheral/corebluetooth/peripheral_manager.rs`, `start_advertising`:
upstream builds the `CBAdvertisementDataServiceUUIDsKey` array out of **`NSString`**
objects. CoreBluetooth requires **`CBUUID`** objects there, so `startAdvertising`
fails with *"One or more parameters were invalid."* and the Mac never advertises.

The fix reuses bluster's own `IntoCBUUID` conversion (already used for GATT
services) to build the array from `CBUUID`s. One-line change; everything else is
upstream `bluster` verbatim.

Only the macOS (CoreBluetooth) advertising path is touched; the Linux (BlueZ)
backend is unchanged.
