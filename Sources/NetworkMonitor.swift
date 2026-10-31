import Foundation
import SystemConfiguration

enum WiFiGateway {
    static let interface = "en0"
    private static let servicePattern = "State:/Network/Service/[^/]+/IPv4"

    /// Reads the gateway of the Wi-Fi interface. Needs no Location Services:
    /// configd publishes the ARP-resolved router MAC in the service state.
    /// Call off the main thread: the ARP fallback may run short commands.
    static func observe() -> GatewayObservation {
        let observed = fromDynamicStore()
        guard case let .unresolved(router) = observed else { return observed }
        if let mac = arpLookup(router) { return .network(mac: mac, router: router) }
        // One ping to the router populates the ARP cache if it was empty.
        _ = run("/sbin/ping", ["-c", "1", "-t", "1", "-q", router])
        if let mac = arpLookup(router) { return .network(mac: mac, router: router) }
        return observed
    }

    private static func fromDynamicStore() -> GatewayObservation {
        guard let store = SCDynamicStoreCreate(nil, "home-ip.reader" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, servicePattern as CFString) as? [String] else {
            return .disconnected
        }
        let services = keys.compactMap { SCDynamicStoreCopyValue(store, $0 as CFString) as? [String: Any] }
        return GatewayParser.observe(services: services, interface: interface)
    }

    private static func arpLookup(_ router: String) -> String? {
        guard GatewayParser.ipv4Octets(router) != nil else { return nil }
        let result = run("/usr/sbin/arp", ["-n", router])
        return result.0 == 0 ? GatewayParser.parseARP(result.1, router: router, interface: interface) : nil
    }
}

/// Delivers configd notifications when the Wi-Fi link, address or gateway
/// changes, replacing periodic network polling. Callbacks arrive on main.
final class NetworkChangeMonitor {
    private var store: SCDynamicStore?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }
    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard store == nil else { return true }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let created = SCDynamicStoreCreate(nil, "home-ip.monitor" as CFString, callback, &context) else { return false }
        let interface = WiFiGateway.interface
        let keys = ["State:/Network/Interface/\(interface)/Link", "State:/Network/Interface/\(interface)/IPv4"] as CFArray
        let patterns = ["State:/Network/Service/[^/]+/IPv4"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(created, keys, patterns),
              SCDynamicStoreSetDispatchQueue(created, .main) else { return false }
        store = created
        return true
    }

    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
    }
}
