import Foundation

/// Should this Mac jump to the video the host moved on to?
///
/// Split out as a pure function with no dependencies precisely because it
/// decides whether to navigate someone's browser on the strength of a message
/// from the network. Every guard here has a test in
/// `Tests/FollowHostHarness`, which is where the reasoning is checked rather
/// than assumed.
enum FollowDecision: Equatable {
    /// Open this URL locally.
    case follow(url: String)
    /// A jump to this same URL is already under way — stay quiet rather than
    /// warning the user that sync is broken while it converges.
    case alreadyFollowing
    /// Do nothing (and let the caller warn that sync is off).
    case decline
}

enum FollowHost {
    /// Minimum gap between two jumps. A title that fails to load must not turn
    /// into a reload loop, and streaming sites take several seconds to settle.
    static let cooldown: TimeInterval = 20
    /// After this long, the same URL may be attempted again — the first try
    /// may simply have failed.
    static let retrySameURLAfter: TimeInterval = 60

    static func decide(
        enabled: Bool,
        inRoom: Bool,
        isTestMode: Bool,
        isHosting: Bool,
        playerIsBrowser: Bool,
        /// Already canonicalised and scheme-checked by the caller; nil if the
        /// URL was unusable.
        canonicalURL: String?,
        /// Name of the recognised streaming service, or nil if the host is not
        /// one Sofa knows. Passed as a plain string so this file stays
        /// dependency-free and testable on its own.
        serviceName: String?,
        lastFollowedURL: String?,
        secondsSinceLastFollow: TimeInterval
    ) -> FollowDecision {
        guard enabled, inRoom, !isTestMode else { return .decline }
        // Only the guest follows. If both sides did, two players drifting apart
        // would chase each other around forever.
        guard !isHosting else { return .decline }
        // A local file in QuickTime or VLC cannot follow a link.
        guard playerIsBrowser else { return .decline }
        // Unknown host = don't touch it. The room secret already limits who can
        // send this, but "a friend's Mac got compromised" must not become
        // "arbitrary pages open on mine".
        guard let canonicalURL, serviceName != nil else { return .decline }

        if canonicalURL == lastFollowedURL {
            return secondsSinceLastFollow > retrySameURLAfter ? .follow(url: canonicalURL)
                                                              : .alreadyFollowing
        }
        guard secondsSinceLastFollow > cooldown else { return .decline }
        return .follow(url: canonicalURL)
    }
}
