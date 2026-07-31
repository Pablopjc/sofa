import Foundation

// Checks the policy that decides whether a message from the network may
// navigate this Mac's browser. Run:
//   swiftc -o /tmp/fh Tests/FollowHostHarness/main.swift Sources/Sofa/FollowHost.swift && /tmp/fh

private var failures = 0

private func check(_ actual: FollowDecision, _ expected: FollowDecision, _ name: String) {
    if actual != expected {
        failures += 1
        fputs("FAIL: \(name) — got \(actual), expected \(expected)\n", stderr)
    }
}

/// A guest, in a real party, watching in a browser, with no jump yet.
private func decide(
    enabled: Bool = true,
    inRoom: Bool = true,
    isTestMode: Bool = false,
    isHosting: Bool = false,
    playerIsBrowser: Bool = true,
    canonicalURL: String? = "https://www.youtube.com/watch?v=abc",
    serviceName: String? = "YouTube",
    lastFollowedURL: String? = nil,
    secondsSinceLastFollow: TimeInterval = 9999
) -> FollowDecision {
    FollowHost.decide(
        enabled: enabled, inRoom: inRoom, isTestMode: isTestMode, isHosting: isHosting,
        playerIsBrowser: playerIsBrowser, canonicalURL: canonicalURL,
        serviceName: serviceName, lastFollowedURL: lastFollowedURL,
        secondsSinceLastFollow: secondsSinceLastFollow
    )
}

let target = "https://www.youtube.com/watch?v=abc"

// The point of the feature.
check(decide(), .follow(url: target), "guest follows the host to a new video")

// Who may be moved.
check(decide(isHosting: true), .decline, "the host never follows anyone")
check(decide(enabled: false), .decline, "respects the setting being off")
check(decide(inRoom: false), .decline, "never outside a party")
check(decide(isTestMode: true), .decline, "never in Test Zone")
check(decide(playerIsBrowser: false), .decline, "QuickTime/VLC cannot follow a link")

// Where it may be moved TO. These are the security guards.
check(decide(canonicalURL: nil), .decline, "unusable URL is refused")
check(decide(serviceName: nil), .decline, "unrecognised site is refused")
check(
    decide(canonicalURL: "https://evil.example.com/pwn", serviceName: nil),
    .decline,
    "arbitrary page from a peer is refused"
)

// Loop protection.
check(
    decide(lastFollowedURL: target, secondsSinceLastFollow: 5),
    .alreadyFollowing,
    "a jump already under way stays quiet instead of re-firing"
)
check(
    decide(lastFollowedURL: target, secondsSinceLastFollow: 61),
    .follow(url: target),
    "the same URL may be retried once it is clearly not loading"
)
check(
    decide(lastFollowedURL: "https://www.youtube.com/watch?v=old", secondsSinceLastFollow: 5),
    .decline,
    "a different video inside the cooldown is refused"
)
check(
    decide(lastFollowedURL: "https://www.youtube.com/watch?v=old", secondsSinceLastFollow: 25),
    .follow(url: target),
    "a different video after the cooldown is followed"
)

if failures == 0 {
    print("FollowHost: all checks passed")
} else {
    fputs("\(failures) check(s) failed\n", stderr)
    exit(1)
}
