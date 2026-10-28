import Foundation

enum IPMode: String { case home, dhcp }

struct HomeSettings: Equatable {
    static let defaultSSID = ""
    static let defaultIP = ""
    let ssid: String
    let ip: String

    static func validSSID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        value.lengthOfBytes(using: .utf8) <= 32 &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func validIP(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  (part == "0" || !part.hasPrefix("0")), let number = Int(part), number <= 255 else { return nil }
            return number
        }
        guard octets.count == 4 else { return false }
        return (1...223).contains(octets[0]) && octets[0] != 127 &&
            (1...254).contains(octets[3])
    }
}

enum WiFiSSIDParser {
    // macOS network tools can report the associated Wi-Fi name without
    // CoreWLAN's Location Services authorization. Keep parsing pure so
    // localized labels and SSIDs containing a colon are covered by tests.
    static func parseNetworksetup(_ output: String) -> String? {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .newlines)
            let normalized = line.trimmingCharacters(in: .whitespaces)
            guard !normalized.isEmpty,
                  !normalized.localizedCaseInsensitiveContains("not associated") else { continue }
            guard let normalizedSeparator = normalized.firstIndex(where: { $0 == ":" || $0 == "：" }),
                  let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let label = normalized[..<normalizedSeparator]
            guard label.localizedCaseInsensitiveContains("network") || label.localizedCaseInsensitiveContains("ssid") || label.contains("网络") else { continue }
            var value = String(line[line.index(after: separator)...])
            // The command adds one separator space after the colon. Remove
            // that formatting byte only, preserving intentional SSID spaces.
            if value.first == " " { value.removeFirst() }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

struct NetworkPolicy {
    private var candidate: String?
    private var count = 0
    mutating func observe(ssid: String?, homeSSID: String, enabled: Bool) -> IPMode? {
        guard enabled, let ssid, !ssid.isEmpty else {
            candidate = nil; count = 0; return nil
        }
        if candidate == ssid { count += 1 } else { candidate = ssid; count = 1 }
        guard count >= 2 else { return nil }
        return ssid == homeSSID ? .home : .dhcp
    }
}

enum SpeakerPolicy {
    static func shouldMute(ssid: String?, homeSSID: String, enabled: Bool) -> Bool {
        enabled && ssid != homeSSID
    }
    static func isInternalSpeaker(transport: UInt32?, source: UInt32?) -> Bool {
        transport == 0x626C746E && source == 0x6973706B // 'bltn', 'ispk'
    }
}

struct SpeakerTransitionPolicy {
    private var homeObservations = 0
    private var homeRestored = false

    mutating func desiredMute(ssid: String?, homeSSID: String, enabled: Bool) -> Bool? {
        guard enabled else {
            homeObservations = 0; homeRestored = false
            return nil
        }
        guard ssid == homeSSID else {
            homeObservations = 0; homeRestored = false
            return true
        }
        homeObservations = min(homeObservations + 1, 2)
        return homeObservations >= 2 && !homeRestored ? false : nil
    }

    mutating func didRestoreHome() { homeRestored = true }
}
