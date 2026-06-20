//
// UnifyReceiverService.swift
// bitchat
//
// The RECEIVER half of Unify nearby-payments: this lets a Unify Wallet user
// pay a Sonar user, with no changes on Unify's side.
//
// Unify's contract (unify-wallet/libs/nearby-payments/.../NearbyPaymentContract.kt
// + NearbyPaymentFraming.kt) models the person GETTING PAID as a GATT
// PERIPHERAL: it advertises the service UUID and serves a BIP321 `bitcoin:`
// URI (carrying a BOLT12 offer) from the payload characteristic. The Unify
// payer is a GATT central that scans, connects and READS the framed payload.
//
// This service mirrors that receiver role. It is the exact inverse of the
// payer's `UnifyNearbyService`: it builds the same service + characteristic,
// serves `frame("bitcoin:?lno=<offer>")` (4-byte big-endian length + UTF-8,
// the inverse of `UnifyNearbyFraming.Reassembler`) and advertises the user's
// nickname as the v2 display name in the BLE local name.
//
// Policy (docs/UNIFY-INTEROP.md, brainstorm 2026-06-12): Sonar is "always
// payable" while the wallet is configured (.ready) AND the app is FOREGROUND.
// We stop advertising in the background (iOS strips the local name and
// restricts service-UUID advertising in the background anyway) and on panic
// wipe. The served offer is AMOUNTLESS — the Unify payer enters the sats.
//
// Like `UnifyNearbyService` this is deliberately ISOLATED from the mesh
// `BLEService`: it owns its OWN `CBPeripheralManager` (separate from the mesh
// and from the payer's central) so nothing here can perturb the wire-critical
// mesh radio. It is a plain @MainActor ObservableObject (no singleton),
// constructed and driven by `SonarAppStore`.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

#if canImport(CoreBluetooth)

/// Advertises Sonar as a Unify-protocol payment receiver and serves a framed,
/// amountless BIP321 offer from its own `CBPeripheralManager`.
@MainActor
final class UnifyReceiverService: NSObject, ObservableObject {

    /// True while we are actively advertising the receiver service.
    @Published private(set) var isAdvertising = false

    /// Supplies a reusable BOLT12 offer to serve. Injected by the host so the
    /// receiver stays decoupled from the wallet implementation. Returns
    /// `nil` when no offer is available yet (wallet not ready) — we then don't
    /// advertise.
    var offerProvider: (() async -> String?)?

    /// Supplies the advertised display name (the user's nickname). Sanitized
    /// + 20-byte-capped per the contract before it hits the air; a blank/`nil`
    /// value falls back to "Sonar user".
    var nameProvider: (() -> String?)?

    /// Default display name when the user has no usable nickname.
    static let defaultName = "Sonar user"

    private var manager: CBPeripheralManager?
    private let queue = DispatchQueue(label: "chat.bitchat.unify.peripheral")

    /// The single read characteristic carrying the framed payload.
    private var payloadCharacteristic: CBMutableCharacteristic?
    /// True once the GATT service has been added to the manager (add once).
    private var serviceAdded = false

    /// The host has asked us to advertise (wallet ready + app foreground). The
    /// actual radio advertising is gated additionally on CoreBluetooth being
    /// powered on and an offer being available.
    private var wantAdvertising = false

    /// The framed payload we serve from the characteristic: the exact bytes a
    /// Unify payer reassembles. Rebuilt whenever the offer or name changes;
    /// `nil` until the first offer is fetched.
    private var framedPayload: Data?
    /// The offer string behind `framedPayload`, to detect changes cheaply.
    private var cachedOffer: String?
    /// The display name currently being advertised.
    private var cachedName: String?

    /// NOTIFY push state: the framed payload split into MTU-sized chunks for the
    /// current subscriber, and the index of the next chunk to send. Unify's
    /// payer subscribes and consumes these notifications (its Reassembler
    /// concatenates them back into the framed blob).
    private var outgoingChunks: [Data] = []
    private var sendCursor = 0

    /// nonisolated so it can be a default-argument value in the @MainActor
    /// SonarAppStore designated init (no main-actor work here).
    nonisolated override init() {
        super.init()
    }

    // MARK: - Lifecycle (driven by the store)

    /// Begin (or refresh) advertising as a payment receiver. Idempotent: safe
    /// to call on every foreground / wallet-ready transition. Fetches the offer
    /// (async, possibly slow) and only advertises once a framed payload exists.
    func start() {
        wantAdvertising = true
        if manager == nil {
            // Creating the peripheral manager reuses the app's existing
            // Bluetooth permission (already granted for the mesh); no extra
            // prompt beyond what the mesh requested.
            manager = CBPeripheralManager(delegate: self, queue: queue, options: [
                CBPeripheralManagerOptionShowPowerAlertKey: false
            ])
        } else {
            Task { await self.refreshAndAdvertiseIfReady() }
        }
    }

    /// Stop advertising and tear down. Used when the wallet becomes
    /// unavailable, on background, and on panic wipe. Keeps the manager around
    /// so a later `start()` is cheap, but drops the cached payload so a wiped
    /// offer is never re-served.
    func stop() {
        wantAdvertising = false
        manager?.stopAdvertising()
        isAdvertising = false
        framedPayload = nil
        cachedOffer = nil
        cachedName = nil
        outgoingChunks = []
        sendCursor = 0
    }

    // MARK: - Building + advertising

    /// Fetch/refresh the offer + name, (re)build the framed payload and the
    /// characteristic value, then advertise — but only when everything is
    /// ready (powered on, want-advertising, an offer exists).
    private func refreshAndAdvertiseIfReady() async {
        guard wantAdvertising, let manager, manager.state == .poweredOn else { return }

        // Resolve the display name (cheap, synchronous).
        let name = UnifyNearbyContract.sanitizeAdvertisedName(nameProvider?())
            ?? Self.defaultName

        // Resolve the offer (async, can be slow). If none yet, don't advertise.
        guard let offer = await offerProvider?(), !offer.isEmpty else {
            // No offer available — make sure we're not advertising a stale one.
            manager.stopAdvertising()
            isAdvertising = false
            return
        }

        // Re-derive the framed payload only when the offer changed.
        if offer != cachedOffer || framedPayload == nil {
            let payload = "bitcoin:?lno=\(offer)"
            guard let framed = try? UnifyNearbyFraming.frame(payload) else {
                SecureLogger.error("UnifyReceiver: failed to frame offer payload", category: .session)
                return
            }
            framedPayload = framed
            cachedOffer = offer
        }

        ensureServiceAdded()

        // (Re)start advertising if the name changed or we're not advertising.
        if name != cachedName || !isAdvertising {
            cachedName = name
            manager.stopAdvertising()
            // Advertise ONLY the Unify service UUID (no Sonar marker). The
            // 16-bit 0x53A0 marker was stripping 4 bytes from the 31-byte
            // primary advertisement, which pushed the 128-bit Unify UUID into
            // iOS's overflow area — invisible to Android Unify scanners.
            // Without the marker a peer Sonar app's payer may list us as a
            // generic "Unify user" alongside the mesh entry; that is cosmetic
            // and acceptable — interop with the real Unify Wallet is the
            // priority.
            manager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [
                    UnifyNearbyContract.serviceUUID,
                ],
                CBAdvertisementDataLocalNameKey: name
            ])
            isAdvertising = true
        }
    }

    /// Build + add the GATT service exactly once. The characteristic is
    /// NOTIFY + READ: Unify's payer SUBSCRIBES (setNotifyValue) and we push the
    /// framed offer in MTU-sized chunks on `didSubscribeTo` (the primary path);
    /// READ is a fallback served per-request in `didReceiveRead`.
    private func ensureServiceAdded() {
        guard let manager, !serviceAdded else { return }
        let characteristic = CBMutableCharacteristic(
            type: UnifyNearbyContract.payloadCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,                 // dynamic value → served via notify/read
            permissions: [.readable]
        )
        let service = CBMutableService(type: UnifyNearbyContract.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        payloadCharacteristic = characteristic
        manager.add(service)
        serviceAdded = true
    }

    /// Push the framed payload to a subscribed central in MTU-sized chunks via
    /// NOTIFY, exactly like Unify's receiver. Chunk size is fixed to the
    /// subscriber's MTU at the START of a transfer (re-chunking mid-stream would
    /// desync `sendCursor`). `updateValue` returning false means the transmit
    /// queue is full — we stop and resume from `peripheralManagerIsReady`.
    private func pumpChunks(to central: CBCentral) {
        guard let manager, let characteristic = payloadCharacteristic else { return }
        if sendCursor == 0, let framed = framedPayload {
            // Unify DEFAULT_MAX_CHUNK_SIZE (180), capped to the subscriber MTU.
            let chunkSize = max(20, min(central.maximumUpdateValueLength, 180))
            outgoingChunks = stride(from: 0, to: framed.count, by: chunkSize).map {
                framed.subdata(in: $0..<min($0 + chunkSize, framed.count))
            }
        }
        while sendCursor < outgoingChunks.count {
            let ok = manager.updateValue(
                outgoingChunks[sendCursor],
                for: characteristic,
                onSubscribedCentrals: [central]
            )
            if !ok { return } // queue full — resume in peripheralManagerIsReady
            sendCursor += 1
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension UnifyReceiverService: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            if peripheral.state == .poweredOn {
                await self.refreshAndAdvertiseIfReady()
            } else {
                // Powered off / unauthorized / resetting: we are not advertising.
                self.isAdvertising = false
            }
        }
    }

    /// Serve the framed payload, honoring CoreBluetooth's long-read offsets.
    /// CoreBluetooth chunks the response by the negotiated ATT MTU and calls us
    /// once per chunk with an increasing `request.offset`; we return the slice
    /// of the full framed blob at that offset. The payer reassembles the exact
    /// `4-byte BE length + UTF-8` blob `UnifyNearbyFraming.Reassembler` expects.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        Task { @MainActor in
            guard request.characteristic.uuid == UnifyNearbyContract.payloadCharacteristicUUID,
                  let framed = self.framedPayload else {
                peripheral.respond(to: request, withResult: .readNotPermitted)
                return
            }
            // An offset past the end is an invalid request per the ATT spec.
            guard request.offset <= framed.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = framed.subdata(in: request.offset..<framed.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    /// Unify's payer subscribes (NOTIFY); push the framed payload in chunks.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.sendCursor = 0
            self.pumpChunks(to: central)
        }
    }

    /// Transmit queue drained — resume pushing to the (single) subscriber.
    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            if let characteristic = self.payloadCharacteristic,
               let subscriber = characteristic.subscribedCentrals?.first {
                self.pumpChunks(to: subscriber)
            }
        }
    }
}

#else

// Platforms without CoreBluetooth: a no-op stub so the rest of the app
// compiles and links. Unify nearby payments are an iOS ad-hoc feature.
@MainActor
final class UnifyReceiverService: ObservableObject {
    @Published private(set) var isAdvertising = false
    static let defaultName = "Sonar user"
    var offerProvider: (() async -> String?)?
    var nameProvider: (() -> String?)?
    nonisolated init() {}
    func start() {}
    func stop() {}
}

#endif
