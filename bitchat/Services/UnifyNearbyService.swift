//
// UnifyNearbyService.swift
// bitchat
//
// Ad-hoc detection of Unify Wallet users over Bluetooth, payments-only.
//
// Unify's "nearby payments" protocol (canonical contract:
// unify-wallet/libs/nearby-payments/.../NearbyPaymentContract.kt +
// NearbyPaymentFraming.kt) models the person GETTING PAID as a GATT
// peripheral: it advertises a service UUID and serves a BIP321 `bitcoin:`
// URI (carrying a BOLT12 offer / Lightning) from a payload characteristic.
// The PAYER is a GATT central that scans for the service, connects, reads
// the chunked payload, reassembles the URI and pays it.
//
// Sonar is always the PAYER here: we scan for Unify receivers, show them on
// the radar with a distinct badge, and on "Send sats" we connect, read the
// served offer and pay it directly over Lightning. We never advertise (no
// receiver role) and never chat with these peers.
//
// This service is deliberately ISOLATED from the mesh BLEService: it owns its
// OWN CBCentralManager so nothing here can perturb the wire-critical mesh
// radio. It is a plain @MainActor ObservableObject (no singleton) constructed
// by SonarAppStore.
//
// Platform note: CoreBluetooth central scanning is an iOS feature here. The
// type compiles on macOS but start()/scanning are guarded to a no-op so the
// macOS build links cleanly (it has no mesh BLE permission flow to piggyback
// on and is not a target for this ad-hoc feature).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

// MARK: - Wire contract (mirror of NearbyPaymentContract.kt — keep identical)

/// Canonical constants from Unify's `NearbyPaymentContract`. These MUST match
/// the Kotlin source byte-for-byte or an iPhone running Sonar and a phone
/// running Unify will not interoperate.
enum UnifyNearbyContract {
    /// Bumped by Unify when framing/characteristic layout changes incompatibly.
    static let protocolVersion = 2

    /// 128-bit service UUID advertised by a Unify receiver. Fixed forever.
    static let serviceUUIDString = "b1f7e2a0-9c3d-4e8a-bf21-3a1c0de54f10"
    /// Characteristic carrying the chunked BIP321 payload (NOTIFY + READ).
    static let payloadCharacteristicUUIDString = "b1f7e2a1-9c3d-4e8a-bf21-3a1c0de54f10"

    /// Conservative per-notification chunk size (Unify DEFAULT_MAX_CHUNK_SIZE).
    static let defaultMaxChunkSize = 180
    /// Upper bound on a single payment payload (Unify MAX_PAYLOAD_BYTES = 8 KB);
    /// bounds the reassembly buffer so a malicious peer can't exhaust memory.
    static let maxPayloadBytes = 8 * 1024

    /// Last-resort display name when the receiver advertises none.
    static let advertisedNamePrefix = "Unify user"
    /// SIG-reserved "no registered company" id; an Android Unify receiver puts
    /// its display name in manufacturer-specific data under this id.
    static let nameManufacturerID = 0xFFFF
    /// Max UTF-8 byte length of an advertised display name (Unify
    /// MAX_ADVERTISED_NAME_BYTES). Names are truncated on a codepoint boundary
    /// so a multi-byte character is never split.
    static let maxAdvertisedNameBytes = 20

    /// 16-bit "I am Sonar" marker advertised ALONGSIDE the Unify service by a
    /// Sonar app's receiver. Other Sonar apps skip these — a Sonar peer is
    /// shown via the mesh, never as a generic "Unify user"; the real Unify
    /// Wallet has no marker and still lists. A service UUID (not manufacturer
    /// data) is used because iOS CoreBluetooth can only advertise service UUIDs
    /// + local name, and a 16-bit UUID is tiny enough to fit beside the 128-bit
    /// Unify UUID in the primary advert (so Android sees it too).
    ///
    /// Caveats (both resolved only on two devices — see the PR review):
    /// - 16-bit UUIDs live in the Bluetooth-SIG-controlled space; `0x53A0` is
    ///   unassigned today but a private marker carries a low future-collision
    ///   risk. A false-skip would need a device advertising BOTH the Unify
    ///   service AND a SIG service `0x53A0`, which is effectively impossible.
    /// - iOS can relocate service UUIDs that don't fit the primary advert into
    ///   the iOS-only overflow area, which an Android general scan can't read.
    ///   A 128-bit + 16-bit pair should fit in the 31-byte primary, but the
    ///   iOS-advertised marker being visible to an Android scanner MUST be
    ///   verified on iPhone (advertising) + a Pixel (scanning).
    static let sonarMarkerUUIDString = "53A0"

    #if canImport(CoreBluetooth)
    static let serviceUUID = CBUUID(string: serviceUUIDString)
    static let payloadCharacteristicUUID = CBUUID(string: payloadCharacteristicUUIDString)
    static let sonarMarkerUUID = CBUUID(string: sonarMarkerUUIDString)
    #endif

    /// Normalize a user-entered display name for advertising, mirroring Unify's
    /// `NearbyPaymentContract.sanitizeAdvertisedName`: replace control characters
    /// with spaces, collapse whitespace runs, trim, and truncate to
    /// `maxAdvertisedNameBytes` UTF-8 bytes on a codepoint boundary.
    ///
    /// - Returns: the cleaned name, or `nil` if blank after cleaning (signals
    ///   "advertise no custom name / fall back to the default").
    static func sanitizeAdvertisedName(_ name: String?) -> String? {
        guard let name else { return nil }
        // Replace control characters (Unicode category Cc: C0 0x00–0x1F and
        // C1 0x7F–0x9F, matching Kotlin's Char.isISOControl) with a space.
        let scalars = name.unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar.properties.generalCategory == .control ? " " : scalar
        }
        let replaced = String(String.UnicodeScalarView(scalars))
        // Collapse runs of whitespace to a single space, then trim.
        let collapsed = replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let cleaned = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        return truncateToUTF8Bytes(cleaned, maxBytes: maxAdvertisedNameBytes)
    }

    /// Truncate `value` to at most `maxBytes` UTF-8 bytes without splitting a
    /// multi-byte codepoint (back off any trailing continuation byte).
    static func truncateToUTF8Bytes(_ value: String, maxBytes: Int) -> String {
        let bytes = Array(value.utf8)
        if bytes.count <= maxBytes { return value }
        var end = maxBytes
        // 0b10xxxxxx is a UTF-8 continuation byte; back off until we land on a
        // lead byte (or the start) so we cut on a codepoint boundary.
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }
}

// MARK: - Framing (mirror of NearbyPaymentFraming.kt — pure, unit-tested)

/// Length-prefixed chunk framing for a single UTF-8 payload over a GATT
/// characteristic.
///
/// Wire format: a 4-byte big-endian unsigned length prefix followed by the
/// UTF-8 payload bytes. The stream is split into fixed-size chunks for
/// transmission; chunk boundaries carry no meaning, so `Reassembler` simply
/// concatenates incoming chunks and is done once it has `prefix + length`
/// bytes. A GATT long READ (offset reads) also yields the same framed blob,
/// so the same reassembler decodes both transports.
enum UnifyNearbyFraming {
    /// Big-endian Int length prefix size.
    static let headerSize = 4

    enum FramingError: Error, Equatable {
        case payloadTooLarge(Int)
        case malformedFrame(String)
    }

    /// Length-prefix `payload` as a single byte array (the receiver side; used
    /// only by tests on our payer build, to drive the reassembler round-trip).
    static func frame(_ payload: String) throws -> Data {
        let body = Data(payload.utf8)
        if body.count > UnifyNearbyContract.maxPayloadBytes {
            throw FramingError.payloadTooLarge(body.count)
        }
        var out = Data(capacity: headerSize + body.count)
        out.append(UInt8((body.count >> 24) & 0xFF))
        out.append(UInt8((body.count >> 16) & 0xFF))
        out.append(UInt8((body.count >> 8) & 0xFF))
        out.append(UInt8(body.count & 0xFF))
        out.append(body)
        return out
    }

    /// Stateful reassembler for the payer side. Feed each received chunk to
    /// `offer(_:)`; it returns the decoded payload once the full stream has
    /// arrived, or `nil` while more chunks are still expected. Not thread-safe
    /// — drive it from a single BLE callback queue.
    final class Reassembler {
        private var buffer = Data()
        private var declaredLength = -1

        /// True once a complete payload has been decoded.
        private(set) var isComplete = false

        /// Append `chunk` and attempt to decode.
        /// - Returns: the decoded payload when complete, else `nil`.
        /// - Throws: `FramingError.malformedFrame` if the declared length is
        ///   invalid or the stream overruns it.
        func offer(_ chunk: Data) throws -> String? {
            if isComplete { return nil }
            if chunk.isEmpty { return nil }

            buffer.append(chunk)

            // Hard cap, enforced even before the header arrives, so an endless
            // stream of chunks cannot exhaust memory.
            if buffer.count > UnifyNearbyFraming.headerSize + UnifyNearbyContract.maxPayloadBytes {
                throw FramingError.malformedFrame("Stream exceeds maximum payload size")
            }

            // Need the full header before we know how many body bytes to expect.
            if declaredLength < 0 {
                if buffer.count < UnifyNearbyFraming.headerSize { return nil }
                declaredLength = UnifyNearbyFraming.readBigEndianInt(buffer, at: 0)
                if declaredLength < 0 || declaredLength > UnifyNearbyContract.maxPayloadBytes {
                    throw FramingError.malformedFrame("Declared payload length \(declaredLength) is out of range")
                }
            }

            let totalExpected = UnifyNearbyFraming.headerSize + declaredLength
            if buffer.count < totalExpected { return nil }
            if buffer.count > totalExpected {
                throw FramingError.malformedFrame("Received \(buffer.count) bytes, expected \(totalExpected)")
            }

            isComplete = true
            let body = buffer.subdata(in: UnifyNearbyFraming.headerSize..<totalExpected)
            guard let str = String(data: body, encoding: .utf8) else {
                throw FramingError.malformedFrame("Payload is not valid UTF-8")
            }
            return str
        }

        /// Reset to accept a fresh transfer.
        func reset() {
            buffer = Data()
            declaredLength = -1
            isComplete = false
        }
    }

    /// Read a big-endian Int from `data` at `offset`. Reads from the data's
    /// own index space so a non-zero-based `Data` slice is handled correctly.
    static func readBigEndianInt(_ data: Data, at offset: Int) -> Int {
        let base = data.startIndex + offset
        return (Int(data[base]) << 24)
            | (Int(data[base + 1]) << 16)
            | (Int(data[base + 2]) << 8)
            | Int(data[base + 3])
    }
}

// MARK: - BIP321 parsing (extract the Lightning destination to pay)

/// Extracts a payable Lightning destination from a Unify-served payment string.
///
/// Unify serves a BIP321 `bitcoin:` URI (BIP321 is the successor to BIP21; the
/// `lightning=` query param carries a BOLT11 invoice or a BOLT12 offer). We pay
/// the Lightning leg directly (Sonar is Lightning-first, no on-chain path), so
/// we pull out:
///   1. a `lightning=` (or `lno=`/`b12=`) query param if present,
///   2. else a bare `lno…`/`lnbc…`/`lntb…`/`lnbcrt…` string,
///   3. else, for a bare `bitcoin:<onchain>` with no Lightning leg, `nil`
///      (we have no on-chain send path).
///
/// Pure logic; unit-tested.
enum UnifyBIP321 {
    /// Result of parsing a served payment URI.
    struct Parsed: Equatable {
        /// The payable Lightning destination (BOLT11 invoice or BOLT12 offer),
        /// lowercased with any `lightning:` scheme prefix stripped.
        let lightning: String
        /// Amount in sats if the URI carried one (BIP321 `amount=` is BTC; we
        /// convert). `nil` ⇒ amountless, prompt the user.
        let amountSats: Int64?
    }

    /// Parse a Unify-served string. Returns `nil` when no Lightning
    /// destination can be extracted (e.g. an on-chain-only `bitcoin:` URI).
    static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // 1) Bare Lightning string (no scheme), e.g. "lno1…" / "lnbc1…".
        if let bare = bareLightning(trimmed), !isURIScheme(trimmed) {
            return Parsed(lightning: bare, amountSats: nil)
        }

        // 2) "lightning:lno1…" bare scheme.
        if hasScheme(trimmed, "lightning") {
            let dest = String(trimmed.dropFirst("lightning:".count))
            if let bare = bareLightning(dest) {
                return Parsed(lightning: bare, amountSats: nil)
            }
        }

        // 3) BIP321 / BIP21 "bitcoin:<addr>?...&lightning=...&amount=..."
        if hasScheme(trimmed, "bitcoin") {
            let body = String(trimmed.dropFirst("bitcoin:".count))
            let (_, query) = splitQuery(body)
            let params = parseQuery(query)
            // BIP321 param is `lightning`; tolerate `lno`/`b12` aliases.
            let ln = params["lightning"] ?? params["lno"] ?? params["b12"]
            if let ln, let bare = bareLightning(ln) {
                let amount = params["amount"].flatMap(btcStringToSats)
                return Parsed(lightning: bare, amountSats: amount)
            }
            // No Lightning leg → on-chain only, which we can't pay.
            return nil
        }

        return nil
    }

    // MARK: helpers

    /// Lightning destination prefixes we accept (lowercased, network-agnostic).
    /// `lno` = BOLT12 offer; `lnbc`/`lntb`/`lnbcrt`/`lnsb` = BOLT11 invoices.
    private static let lightningPrefixes = ["lno1", "lnbc", "lntb", "lnbcrt", "lnsb", "lntbs"]

    /// Returns the destination lowercased if it looks like a bare Lightning
    /// invoice/offer (after URL-decoding), else `nil`.
    private static func bareLightning(_ s: String) -> String? {
        let decoded = (s.removingPercentEncoding ?? s)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = decoded.lowercased()
        return lightningPrefixes.contains(where: { lower.hasPrefix($0) }) ? lower : nil
    }

    /// True if `s` starts with a URI scheme like "bitcoin:" / "lightning:".
    private static func isURIScheme(_ s: String) -> Bool {
        hasScheme(s, "bitcoin") || hasScheme(s, "lightning")
    }

    private static func hasScheme(_ s: String, _ scheme: String) -> Bool {
        s.lowercased().hasPrefix(scheme + ":")
    }

    private static func splitQuery(_ body: String) -> (path: String, query: String) {
        guard let q = body.firstIndex(of: "?") else { return (body, "") }
        return (String(body[..<q]), String(body[body.index(after: q)...]))
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first else { continue }
            let key = rawKey.lowercased()
            let value = kv.count > 1 ? String(kv[1]) : ""
            // First occurrence wins (BIP321 forbids duplicate keys).
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    /// Convert a BIP21 `amount=` (decimal BTC) to sats. Returns `nil` on a
    /// malformed or non-positive value.
    static func btcStringToSats(_ btc: String) -> Int64? {
        let decoded = btc.removingPercentEncoding ?? btc
        guard let value = Decimal(string: decoded), value > 0 else { return nil }
        let sats = value * Decimal(100_000_000)
        var rounded = Decimal()
        var mutable = sats
        NSDecimalRound(&rounded, &mutable, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

// MARK: - Discovered peer

/// A Unify receiver discovered by our scanning payer. Presence-only: we record
/// it on `didDiscover` and never connect until the user taps "Send sats".
struct UnifyPeer: Identifiable, Equatable {
    /// Stable per-session id = `peripheral.identifier.uuidString`.
    let id: String
    /// Advertised display name (BLE local name or Android manufacturer 0xFFFF
    /// data), or the default "Unify user".
    let name: String
    /// Signal strength in dBm, if reported.
    let rssi: Int
    /// Last time this peer's advertisement was seen (for stale pruning).
    var lastSeen: Date
}

// MARK: - Errors

enum UnifyNearbyError: Error, LocalizedError {
    case bluetoothUnavailable
    case peerNotFound
    case connectFailed(String)
    case serviceNotFound
    case characteristicNotFound
    case readFailed(String)
    case timedOut
    case malformedPayload(String)
    case noPayment

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is not available."
        case .peerNotFound: return "That Unify user is no longer nearby."
        case .connectFailed(let m): return "Couldn't connect: \(m)"
        case .serviceNotFound: return "That device isn't sharing a payment."
        case .characteristicNotFound: return "That device isn't sharing a payment."
        case .readFailed(let m): return "Couldn't read the payment: \(m)"
        case .timedOut: return "The Unify user didn't respond in time."
        case .malformedPayload(let m): return "The payment request was malformed: \(m)"
        case .noPayment: return "No Lightning payment was offered."
        }
    }
}

// MARK: - Service

#if canImport(CoreBluetooth)

/// Scans for nearby Unify receivers (payments-only) on its OWN CBCentralManager,
/// publishes discovered `UnifyPeer`s, and on demand connects to one peer to read
/// the served BIP321 payment URI.
@MainActor
final class UnifyNearbyService: NSObject, ObservableObject {
    /// Discovered Unify receivers, freshest first; pruned of stale entries.
    @Published private(set) var peers: [UnifyPeer] = []

    /// How long a peer survives without a fresh advertisement before pruning.
    private let staleAfter: TimeInterval = 20
    /// Per-operation timeout for the connect + read flow.
    private let fetchTimeout: TimeInterval = 15

    private var central: CBCentralManager?
    private let queue = DispatchQueue(label: "chat.bitchat.unify.central")
    private var wantScanning = false

    /// Peripherals retained while we hold a handle to them (CoreBluetooth does
    /// not retain them for us). Keyed by identifier string.
    private var peripherals: [String: CBPeripheral] = [:]

    /// In-flight fetch state (one at a time — Unify's flow is a single read).
    private final class FetchContext {
        let peerId: String
        let continuation: CheckedContinuation<String, Error>
        let reassembler = UnifyNearbyFraming.Reassembler()
        var payloadCharacteristic: CBCharacteristic?
        var finished = false
        init(peerId: String, continuation: CheckedContinuation<String, Error>) {
            self.peerId = peerId
            self.continuation = continuation
        }
    }
    private var fetch: FetchContext?
    private var pruneTimer: Timer?

    /// nonisolated so it can be used as a default-argument value in the
    /// @MainActor SonarAppStore designated init (no main-actor work here).
    nonisolated override init() {
        super.init()
    }

    // MARK: Lifecycle

    /// Begin scanning for Unify receivers. Reuses the app's existing Bluetooth
    /// permission (already granted for the mesh); creating the central triggers
    /// no extra prompt beyond what the mesh already requested. Idempotent.
    func start() {
        wantScanning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue, options: [
                CBCentralManagerOptionShowPowerAlertKey: false
            ])
        } else {
            startScanIfReady()
        }
        if pruneTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pruneStale() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pruneTimer = timer
        }
    }

    /// Stop scanning and clear discovered peers. Used on teardown and panic wipe.
    func stop() {
        wantScanning = false
        central?.stopScan()
        pruneTimer?.invalidate()
        pruneTimer = nil
        peers = []
        peripherals = [:]
        failFetch(.peerNotFound)
    }

    private func startScanIfReady() {
        guard wantScanning, let central, central.state == .poweredOn else { return }
        // Scan WITHOUT a service-UUID filter and match the service in code
        // (`didDiscover`). A filtered scan suppresses the scan-response local
        // name on iOS, so Unify receivers showed up nameless ("Unify user");
        // the unfiltered scan delivers the advertised display name. Gated to
        // while the radar is visible, so the broader scan is short-lived.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    // MARK: Discovery bookkeeping (main actor)

    private func recordDiscovery(id: String, name: String, rssi: Int, peripheral: CBPeripheral) {
        peripherals[id] = peripheral
        let now = Date()
        if let idx = peers.firstIndex(where: { $0.id == id }) {
            // Keep the best (non-default) name we've seen for this peer.
            let existing = peers[idx]
            let keepName = existing.name == UnifyNearbyContract.advertisedNamePrefix ? name : existing.name
            peers[idx] = UnifyPeer(id: id, name: keepName, rssi: rssi, lastSeen: now)
        } else {
            peers.append(UnifyPeer(id: id, name: name, rssi: rssi, lastSeen: now))
        }
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        let live = peers.filter { $0.lastSeen >= cutoff }
        if live.count != peers.count {
            // Drop retained peripherals we no longer track (unless mid-fetch).
            let liveIds = Set(live.map(\.id))
            for id in peripherals.keys where !liveIds.contains(id) && id != fetch?.peerId {
                peripherals.removeValue(forKey: id)
            }
            peers = live
        }
    }

    // MARK: Fetch the served BIP321 URI

    /// Connect to a discovered Unify receiver, read its served BIP321 payment
    /// URI (reassembling chunked reads), disconnect, and return the URI string.
    /// Robust timeout; one fetch at a time.
    func fetchPaymentURI(_ peerId: String) async throws -> String {
        guard let central, central.state == .poweredOn else {
            throw UnifyNearbyError.bluetoothUnavailable
        }
        guard let peripheral = peripherals[peerId] else {
            throw UnifyNearbyError.peerNotFound
        }
        if fetch != nil { throw UnifyNearbyError.connectFailed("busy") }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.fetchTimeout ?? 15) * 1_000_000_000))
            await MainActor.run { self?.failFetch(.timedOut) }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let ctx = FetchContext(peerId: peerId, continuation: continuation)
            self.fetch = ctx
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    /// Resolve the in-flight fetch successfully, tearing down the connection.
    private func finishFetch(success uri: String) {
        guard let ctx = fetch, !ctx.finished else { return }
        ctx.finished = true
        fetch = nil
        if let p = peripherals[ctx.peerId] { central?.cancelPeripheralConnection(p) }
        ctx.continuation.resume(returning: uri)
    }

    /// Fail the in-flight fetch (if any), tearing down the connection.
    private func failFetch(_ error: UnifyNearbyError) {
        guard let ctx = fetch, !ctx.finished else { return }
        ctx.finished = true
        fetch = nil
        if let p = peripherals[ctx.peerId] { central?.cancelPeripheralConnection(p) }
        ctx.continuation.resume(throwing: error)
    }
}

// MARK: - CBCentralManagerDelegate

extension UnifyNearbyService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                self.startScanIfReady()
            } else {
                self.failFetch(.bluetoothUnavailable)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Unfiltered scan → only keep advertisers carrying the Unify service.
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard services.contains(UnifyNearbyContract.serviceUUID) else { return }
        // Skip Sonar apps advertising the Unify receiver — they're shown as Sonar
        // peers via the mesh, not as generic "Unify users".
        if services.contains(UnifyNearbyContract.sonarMarkerUUID) { return }
        let id = peripheral.identifier.uuidString
        let name = Self.advertisedName(advertisementData, peripheralName: peripheral.name)
        let rssi = RSSI.intValue
        Task { @MainActor in
            self.recordDiscovery(id: id, name: name, rssi: rssi, peripheral: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.fetch?.peerId == peripheral.identifier.uuidString else { return }
            peripheral.discoverServices([UnifyNearbyContract.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.fetch?.peerId == peripheral.identifier.uuidString else { return }
            self.failFetch(.connectFailed(error?.localizedDescription ?? "connection failed"))
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            // A disconnect before we assembled the payload is a failure.
            guard self.fetch?.peerId == peripheral.identifier.uuidString else { return }
            self.failFetch(.readFailed(error?.localizedDescription ?? "disconnected"))
        }
    }

    /// Resolve the advertised display name: Android Unify receivers carry it in
    /// manufacturer-specific data under company id 0xFFFF; iOS receivers carry
    /// it in the BLE local name. We read manufacturer data first, then local
    /// name, then fall back to the default prefix.
    nonisolated static func advertisedName(_ adv: [String: Any], peripheralName: String?) -> String {
        // Prefer the iOS receiver's advertised local name, then the Android
        // manufacturer 0xFFFF name, then the GAP peripheral name (populated by
        // CoreBluetooth from the scan response / after connect), then the
        // default. All go through the contract's sanitize/trim + 20-byte cap so
        // they look identical to the receiver's own advertised value.
        if let local = adv[CBAdvertisementDataLocalNameKey] as? String,
           let clean = UnifyNearbyContract.sanitizeAdvertisedName(local) {
            return clean
        }
        if let mfg = adv[CBAdvertisementDataManufacturerDataKey] as? Data,
           let name = nameFromManufacturerData(mfg) {
            return name
        }
        if let clean = UnifyNearbyContract.sanitizeAdvertisedName(peripheralName) {
            return clean
        }
        return UnifyNearbyContract.advertisedNamePrefix
    }

    /// Manufacturer data layout: 2-byte little-endian company id followed by
    /// the UTF-8 name bytes (Unify uses 0xFFFF + the sanitized name). Returns
    /// `nil` if the company id doesn't match or the name is empty after the
    /// same sanitize/trim + 20-byte cap the receiver applies.
    nonisolated static func nameFromManufacturerData(_ data: Data) -> String? {
        guard data.count > 2 else { return nil }
        let company = Int(data[data.startIndex]) | (Int(data[data.startIndex + 1]) << 8)
        guard company == UnifyNearbyContract.nameManufacturerID else { return nil }
        let nameBytes = data.subdata(in: (data.startIndex + 2)..<data.endIndex)
        return UnifyNearbyContract.sanitizeAdvertisedName(String(decoding: nameBytes, as: UTF8.self))
    }
}

// MARK: - CBPeripheralDelegate (the chunked read)

extension UnifyNearbyService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard self.fetch?.peerId == peripheral.identifier.uuidString else { return }
            if let error { self.failFetch(.readFailed(error.localizedDescription)); return }
            guard let service = peripheral.services?.first(where: {
                $0.uuid == UnifyNearbyContract.serviceUUID
            }) else {
                self.failFetch(.serviceNotFound); return
            }
            peripheral.discoverCharacteristics([UnifyNearbyContract.payloadCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard let ctx = self.fetch, ctx.peerId == peripheral.identifier.uuidString else { return }
            if let error { self.failFetch(.readFailed(error.localizedDescription)); return }
            guard let characteristic = service.characteristics?.first(where: {
                $0.uuid == UnifyNearbyContract.payloadCharacteristicUUID
            }) else {
                self.failFetch(.characteristicNotFound); return
            }
            ctx.payloadCharacteristic = characteristic
            // GATT long READ: CoreBluetooth coalesces offset reads into one
            // value delivery, yielding the whole framed blob. We also subscribe
            // to notifications so a chunk-streaming receiver works too.
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let value = characteristic.value
        Task { @MainActor in
            guard let ctx = self.fetch, ctx.peerId == peripheral.identifier.uuidString else { return }
            if let error { self.failFetch(.readFailed(error.localizedDescription)); return }
            guard let value, !value.isEmpty else {
                self.failFetch(.readFailed("empty payload")); return
            }
            do {
                if let payload = try ctx.reassembler.offer(value) {
                    self.finishFetch(success: payload)
                }
                // else: more chunks expected; wait for the next notify.
            } catch {
                let msg = (error as? UnifyNearbyFraming.FramingError).map { "\($0)" }
                    ?? error.localizedDescription
                self.failFetch(.malformedPayload(msg))
            }
        }
    }
}

#else

// macOS / platforms without CoreBluetooth: a no-op stub so the rest of the app
// compiles and links. Unify nearby payments are an iOS ad-hoc feature.
@MainActor
final class UnifyNearbyService: ObservableObject {
    @Published private(set) var peers: [UnifyPeer] = []
    nonisolated init() {}
    func start() {}
    func stop() {}
    func fetchPaymentURI(_ peerId: String) async throws -> String {
        throw UnifyNearbyError.bluetoothUnavailable
    }
}

#endif
