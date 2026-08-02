import Foundation
import BitLogger
import Combine
import Network
import Tor

/// Coordinates when the app is allowed to start Tor and connect to Nostr relays.
/// Policy: permit start when either location permissions are authorized OR
/// there exists at least one mutual favorite. Otherwise, do not start.
@MainActor
final class NetworkActivationService: ObservableObject {
    static let shared = NetworkActivationService()

    @Published private(set) var activationAllowed: Bool = false
    /// Current OS network reachability. Optimistic until NWPathMonitor delivers
    /// its first update; relay connection state still gates user-visible Online.
    @Published private(set) var internetPathSatisfied: Bool = true
    /// True when the current route bills the user for bytes: cellular, a
    /// personal hotspot, or a link the user put under Low Data Mode
    /// (`isConstrained`). Only bulk transfers consult this — chat, relays and
    /// media stay on whatever path exists.
    ///
    /// Pessimistic until the first `NWPathMonitor` update, which is the safe
    /// direction: a cold launch that starts a multi-megabyte account upload
    /// before the first path callback is exactly the 66 GB report.
    @Published private(set) var pathIsExpensive: Bool = true
    // Sonar decision (2026-06-13): Tor is opt-in and OFF by default for now —
    // public channels / Nostr go direct. The v2 key ignores any previously
    // stored "true" from older builds where Tor defaulted on.
    @Published private(set) var userTorEnabled: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var pathMonitorStarted = false
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "chat.bitchat.network-path")
    private let torPreferenceKey = "networkActivationService.userTorEnabled.v2"
    private var torAutoStartDesired: Bool = false

    private init() {}

    /// Start `NWPathMonitor` exactly once, independently of the rest of
    /// `start()`.
    ///
    /// Split out because `start()` is only ever called from the UI scene, while
    /// the thing that most needs a truthful answer about the route — the
    /// background auto-backup executor — runs in `BGProcessing`/`BGAppRefresh`
    /// launches that may never build that scene.
    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            // `isConstrained` is Low Data Mode: the user asked the OS to hold
            // back background transfers, and a full-account upload is the
            // definition of one.
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pathIsExpensive != expensive {
                    self.pathIsExpensive = expensive
                    SecureLogger.info("NetworkActivationService: pathIsExpensive -> \(expensive)", category: .session)
                }
                guard self.internetPathSatisfied != satisfied else { return }
                self.internetPathSatisfied = satisfied
                SecureLogger.info("NetworkActivationService: internetPathSatisfied -> \(satisfied)", category: .session)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    /// Metered state resolved NOW, from the monitor's current path.
    ///
    /// The `@Published pathIsExpensive` above is pessimistic until the first
    /// `NWPathMonitor` callback lands, which is correct for a UI binding and
    /// wrong for a one-shot decision: a background launch that asks before that
    /// first callback would read `true` and skip the backup, and a launch that
    /// never ran `start()` would read `true` forever. A gate that silently
    /// means "no backups, ever" is worse than the data it saves.
    ///
    /// An unsatisfied path answers `false`: there is no route, so the upload
    /// fails on its own terms rather than being suppressed as "too expensive".
    func currentPathIsExpensive() -> Bool {
        startPathMonitorIfNeeded()
        let path = pathMonitor.currentPath
        guard path.status == .satisfied else { return false }
        return path.isExpensive || path.isConstrained
    }

    func start() {
        guard !started else { return }
        started = true

        if let stored = UserDefaults.standard.object(forKey: torPreferenceKey) as? Bool {
            userTorEnabled = stored
        } else {
            userTorEnabled = false
        }

        startPathMonitorIfNeeded()

        // Initial compute
        let allowed = basePolicyAllowed()
        activationAllowed = allowed
        torAutoStartDesired = allowed && userTorEnabled
        TorManager.shared.setAutoStartAllowed(torAutoStartDesired)
        applyTorState(torDesired: torAutoStartDesired)
        if allowed {
            NostrRelayManager.shared.connect()
        } else {
            NostrRelayManager.shared.disconnect()
        }

        // React to location permission changes
        LocationChannelManager.shared.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
            .store(in: &cancellables)

        // React to mutual favorites changes
        FavoritesPersistenceService.shared.$mutualFavorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
            .store(in: &cancellables)
    }

    func setUserTorEnabled(_ enabled: Bool) {
        guard enabled != userTorEnabled else { return }
        userTorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: torPreferenceKey)
        NotificationCenter.default.post(
            name: .TorUserPreferenceChanged,
            object: nil,
            userInfo: ["enabled": enabled]
        )
        reevaluate()
    }

    private func reevaluate() {
        let allowed = basePolicyAllowed()
        let torDesired = allowed && userTorEnabled
        let statusChanged = allowed != activationAllowed
        let torChanged = torDesired != torAutoStartDesired
        if statusChanged {
            SecureLogger.info("NetworkActivationService: activationAllowed -> \(allowed)", category: .session)
            activationAllowed = allowed
        }
        if statusChanged || torChanged {
            torAutoStartDesired = torDesired
            TorManager.shared.setAutoStartAllowed(torDesired)
            applyTorState(torDesired: torDesired)
        }

        if allowed {
            if torChanged {
                // Reset relay sockets when switching transport path (Tor ↔︎ direct)
                NostrRelayManager.shared.disconnect()
            }
            NostrRelayManager.shared.connect()
        } else if statusChanged {
            NostrRelayManager.shared.disconnect()
        }
    }

    private func basePolicyAllowed() -> Bool {
        let permOK = LocationChannelManager.shared.permissionState == .authorized
        let hasMutual = !FavoritesPersistenceService.shared.mutualFavorites.isEmpty
        return permOK || hasMutual
    }

    private func applyTorState(torDesired: Bool) {
        TorURLSession.shared.setProxyMode(useTor: torDesired)
        if torDesired {
            TorManager.shared.startIfNeeded()
        } else {
            TorManager.shared.shutdownCompletely()
        }
    }
}
