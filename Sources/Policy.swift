import Foundation

enum IPMode: String { case home, dhcp }

struct HomeSettings: Equatable {
    static let defaultRouter = ""
    static let defaultIP = ""
    // Home is identified by the Wi-Fi gateway's hardware address. macOS hides
    // the SSID without Location Services, but publishes the gateway MAC.
    let router: String
    let ip: String

    static func validRouter(_ value: String) -> Bool {
        GatewayParser.normalizeMAC(value) == value
    }

    static func validIP(_ value: String) -> Bool {
        guard let octets = GatewayParser.ipv4Octets(value) else { return false }
        return (1...223).contains(octets[0]) && octets[0] != 127 &&
            (1...254).contains(octets[3])
    }
}

// What the Wi-Fi interface reports about its gateway. Unknown states stay
// distinct from "another network": only a resolved MAC is a network identity.
enum GatewayObservation: Equatable {
    case disconnected
    case unresolved(router: String)
    case network(mac: String, router: String)

    var mac: String? {
        if case let .network(mac, _) = self { return mac }
        return nil
    }
    var router: String? {
        switch self {
        case .disconnected: return nil
        case let .unresolved(router), let .network(_, router): return router
        }
    }
}

enum GatewayParser {
    static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  (part == "0" || !part.hasPrefix("0")), let number = Int(part), number <= 255 else { return nil }
            return number
        }
        return octets.count == 4 ? octets : nil
    }

    /// Lowercase, zero-padded `aa:bb:cc:dd:ee:ff`; rejects broadcast, zero and
    /// multicast addresses, which never identify a router.
    static func normalizeMAC(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count), part.allSatisfy({ $0.isHexDigit && $0.isASCII }),
                  let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        guard bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Reads the configd service IPv4 state (`State:/Network/Service/*/IPv4`)
    /// for one interface. configd records the ARP-resolved gateway MAC there.
    static func observe(services: [[String: Any]], interface: String) -> GatewayObservation {
        for service in services {
            guard service["InterfaceName"] as? String == interface,
                  let router = service["Router"] as? String, ipv4Octets(router) != nil else { continue }
            if service["ARPResolvedIPAddress"] as? String == router,
               let raw = service["ARPResolvedHardwareAddress"] as? String,
               let mac = normalizeMAC(raw) {
                return .network(mac: mac, router: router)
            }
            return .unresolved(router: router)
        }
        return .disconnected
    }

    /// Parses `arp -n <ip>` output, e.g.
    /// `? (192.168.1.1) at e4:d3:73:74:d3:53 on en0 ifscope [ethernet]`.
    static func parseARP(_ output: String, router: String, interface: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(separator: " ").map(String.init)
            guard let at = fields.firstIndex(of: "at"), at + 3 < fields.count,
                  fields.contains("(\(router))"),
                  fields[at + 2] == "on", fields[at + 3] == interface else { continue }
            return normalizeMAC(fields[at + 1])
        }
        return nil
    }
}

struct NetworkPolicy {
    private var candidate: String?
    private var count = 0
    mutating func observe(network: String?, homeNetwork: String, enabled: Bool) -> IPMode? {
        guard enabled, let network, !network.isEmpty else {
            candidate = nil; count = 0; return nil
        }
        if candidate == network { count += 1 } else { candidate = network; count = 1 }
        guard count >= 2 else { return nil }
        return network == homeNetwork ? .home : .dhcp
    }
    /// True after one observation of a known network that still needs a second.
    var awaitingConfirmation: Bool { candidate != nil && count < 2 }
}

enum SpeakerPolicy {
    static func shouldMute(network: String?, homeNetwork: String, enabled: Bool) -> Bool {
        enabled && network != homeNetwork
    }
    static func isInternalSpeaker(transport: UInt32?, source: UInt32?) -> Bool {
        transport == 0x626C746E && source == 0x6973706B // 'bltn', 'ispk'
    }
}

struct SpeakerTransitionPolicy {
    private var enabled = false
    private var atHome = false
    private var homeObservations = 0
    private var homeRestored = false

    /// Records one network observation and returns the resulting desire.
    mutating func desiredMute(network: String?, homeNetwork: String, enabled: Bool) -> Bool? {
        self.enabled = enabled
        atHome = enabled && network == homeNetwork
        if atHome { homeObservations = min(homeObservations + 1, 2) }
        else { homeObservations = 0; homeRestored = false }
        return currentDesire
    }

    /// The desire for the last observation, without counting a new one. Audio
    /// change events use this to re-enforce mute away from home.
    var currentDesire: Bool? {
        guard enabled else { return nil }
        guard atHome else { return true }
        return homeObservations >= 2 && !homeRestored ? false : nil
    }
    var awaitingConfirmation: Bool { enabled && atHome && homeObservations < 2 }

    mutating func didRestoreHome() { homeRestored = true }
}

enum AppVersion {
    /// Numeric components of `v1.4.0` / `1.4`; nil for anything else.
    static func components(_ value: String) -> [Int]? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count ? numbers : nil
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Parsed GitHub "latest release". Only release pages of this repository are
/// accepted as download links, so a malformed response cannot open other URLs.
struct ReleaseInfo: Equatable {
    static let repository = "wangshan9870/wifi-static-ip-mute-switcher"
    static let releasesPage = "https://github.com/\(repository)/releases"
    let version: String
    let page: String

    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String, AppVersion.components(tag) != nil else { return nil }
        let page = json["html_url"] as? String ?? ""
        let safePage = page.hasPrefix(releasesPage + "/tag/") ? page : releasesPage + "/latest"
        return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: safePage)
    }
}
