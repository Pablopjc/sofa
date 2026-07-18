import Foundation

/// A versioned online room or a legacy LAN room.
///
/// Online invites deliberately keep the short room code separate from the
/// capability secret. The six visible characters are convenient to recognise;
/// the 256-bit secret in the full link is what grants access.
enum RoomTarget: Equatable {
    case online(roomID: String, secret: String)
    case lan(address: String, token: String?)

    var token: String? {
        switch self {
        case .online(_, let secret): return secret
        case .lan(_, let token): return token
        }
    }

    var displayCode: String {
        switch self {
        case .online(let roomID, _): return roomID
        case .lan(_, let token): return token ?? ""
        }
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    /// Accepts a link copied out of a message, a bare online path, or the
    /// legacy `host:port/CODE` form. Malformed and future-version links are
    /// rejected rather than accidentally treated as a hostname.
    static func parse(_ input: String) -> RoomTarget? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(
            of: #"sofa://join/[^\s<>\"]+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            text = String(text[range])
        }
        text = text.trimmingCharacters(
            in: CharacterSet(charactersIn: "<>\"'(){},.;!?").union(.whitespacesAndNewlines)
        )

        if text.lowercased().hasPrefix("sofa://") {
            guard let components = URLComponents(string: text),
                  components.scheme?.lowercased() == "sofa",
                  components.host?.lowercased() == "join",
                  components.query == nil,
                  components.fragment == nil else { return nil }
            return parse(path: components.percentEncodedPath)
        }

        return parse(path: text)
    }

    private static func parse(path rawPath: String) -> RoomTarget? {
        let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedParts = path.split(separator: "/", omittingEmptySubsequences: false)
        let parts = encodedParts.compactMap { String($0).removingPercentEncoding }
        guard parts.count == encodedParts.count, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty }) else { return nil }

        let version = parts[0].lowercased()
        if version == "v1" || version == "online" {
            guard parts.count == 3,
                  isValidRoomID(parts[1]),
                  isValidOnlineSecret(parts[2]) else { return nil }
            return .online(roomID: parts[1].uppercased(), secret: parts[2])
        }

        // Explicit unknown versions must never fall through to LAN parsing.
        if version.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil {
            return nil
        }

        guard parts.count == 1 || parts.count == 2,
              isValidLANAddress(parts[0]) else { return nil }
        let token: String?
        if parts.count == 2 {
            guard isValidLANToken(parts[1]) else { return nil }
            token = parts[1]
        } else {
            token = nil
        }
        return .lan(address: parts[0], token: token)
    }

    private static func isValidRoomID(_ value: String) -> Bool {
        value.range(
            of: #"^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isValidOnlineSecret(_ value: String) -> Bool {
        // The official relay returns 32 random bytes as 43 base64url chars.
        value.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    }

    private static func isValidLANToken(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        return value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private static func isValidLANAddress(_ address: String) -> Bool {
        guard !address.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: "ws://\(address)"),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else { return false }
        if let port = components.port, !(1...65_535).contains(port) { return false }
        return true
    }
}
