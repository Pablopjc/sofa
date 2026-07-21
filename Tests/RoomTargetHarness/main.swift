import Foundation

private let secret = "abcdefghijklmnopqrstuvwxyzABCDEFGHJKLMNPQRS"
private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(name)\n", stderr)
    }
}

check(
    RoomTarget.parse("sofa://join/v1/AB3X7K/\(secret)")
        == .online(roomID: "AB3X7K", secret: secret),
    "online invite"
)
check(
    RoomTarget.parse("Join me: sofa://join/v1/ab3x7k/\(secret). See you!")
        == .online(roomID: "AB3X7K", secret: secret),
    "invite inside message text"
)
check(
    RoomTarget.parse("sofa://join/192.168.2.146:7420/H2JFVT")
        == .lan(address: "192.168.2.146:7420", token: "H2JFVT"),
    "legacy LAN invite"
)
check(
    RoomTarget.parse("macbook.local:7420/H2JFVT")
        == .lan(address: "macbook.local:7420", token: "H2JFVT"),
    "bare LAN invite"
)
check(
    RoomTarget.parse("macbook.local/H2JFVT")
        == .lan(address: "macbook.local", token: "H2JFVT"),
    "LAN invite without port"
)
check(
    RoomTarget.parse("[::1]:7420/H2JFVT")
        == .lan(address: "[::1]:7420", token: "H2JFVT"),
    "IPv6 LAN invite"
)
check(
    RoomTarget.parse("[::1]/H2JFVT")
        == .lan(address: "[::1]", token: "H2JFVT"),
    "IPv6 LAN invite without port"
)
check(RoomTarget.parse("user@macbook.local:7420/H2JFVT") == nil, "LAN username")
check(
    RoomTarget.parse("user:password@macbook.local:7420/H2JFVT") == nil,
    "LAN username and password"
)
check(RoomTarget.parse("sofa://join/v2/AB3X7K/\(secret)") == nil, "future version")
check(RoomTarget.parse("sofa://join/v1/AB3X7K/too-short") == nil, "short secret")
check(RoomTarget.parse("sofa://join/v1/AB3X7K/\(secret)/extra") == nil, "extra path (4 parts)")
check(RoomTarget.parse("sofa://join/v1/IIIIII/\(secret)") == nil, "ambiguous room code")
check(RoomTarget.parse("not an invite") == nil, "random text")

// The https invite page link parses back to the same online room.
check(
    RoomTarget.parse("https://sofa-sync-relay.pablopjc.workers.dev/j/AB3X7K#\(secret)")
        == .online(roomID: "AB3X7K", secret: secret),
    "https invite link"
)
check(
    RoomTarget.parse("https://sofa-sync-relay.pablopjc.workers.dev/j/ab3x7k#\(secret)")
        == .online(roomID: "AB3X7K", secret: secret),
    "https invite link lowercased room id"
)
// A bare visible room code is recognized but flagged as not-joinable.
check(RoomTarget.parse("AB3X7K") == .bareCode("AB3X7K"), "bare room code")
check(RoomTarget.parse("ab3x7k") == .bareCode("AB3X7K"), "bare room code lowercased")

if failures > 0 { exit(1) }
print("RoomTarget parser: 18 checks passed")
