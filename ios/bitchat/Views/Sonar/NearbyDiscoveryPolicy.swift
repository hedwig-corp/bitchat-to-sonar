//
// NearbyDiscoveryPolicy.swift
// bitchat
//


/// The mesh radio has its own chats-only policy. This predicate controls the
/// additional nearby-payments scan, which must not run invisibly in background.
func shouldScanForNearbyPayments(
    isNearbyVisible: Bool,
    isForeground: Bool,
    isDiscoveryRestricted: Bool
) -> Bool {
    isNearbyVisible && isForeground && !isDiscoveryRestricted
}
