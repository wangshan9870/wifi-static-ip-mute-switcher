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
