//
//  NetworkEnvironmentService.swift
//  Siphon
//

import Foundation
import Network

/// Monitors network connectivity, tunnel/VPN state, and IP transport capabilities.
/// Used to dynamically optimize yt-dlp arguments, socket timeouts, and proxy routing
/// (such as prioritizing IPv4 and preventing unroutable IPv6 timeouts on VPNs like NordVPN).
public final class NetworkEnvironmentService: @unchecked Sendable {
    public static let shared = NetworkEnvironmentService()

    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.marspater.siphon.network-monitor", qos: .utility)
    private let lock = NSLock()

    private var currentPath: NWPath?
    private var lastReportedVPNState: Bool?

    // Testing overrides
    private var _overrideIsVPNActive: Bool?
    private var _overrideSupportsIPv6: Bool?
    private var _overrideIsNordVPN: Bool?

    public var overrideIsVPNActive: Bool? {
        get { lock.withLock { _overrideIsVPNActive } }
        set { lock.withLock { _overrideIsVPNActive = newValue } }
    }

    public var overrideSupportsIPv6: Bool? {
        get { lock.withLock { _overrideSupportsIPv6 } }
        set { lock.withLock { _overrideSupportsIPv6 = newValue } }
    }

    public var overrideIsNordVPN: Bool? {
        get { lock.withLock { _overrideIsNordVPN } }
        set { lock.withLock { _overrideIsNordVPN = newValue } }
    }

    public var isVPNActive: Bool {
        lock.withLock {
            if let override = _overrideIsVPNActive { return override }
            guard let path = currentPath else { return false }
            return Self.isVPNPath(path)
        }
    }

    public var supportsIPv6: Bool {
        lock.withLock {
            if let override = _overrideSupportsIPv6 { return override }
            guard let path = currentPath else { return true }
            return path.supportsIPv6
        }
    }

    public var isNordVPNDetected: Bool {
        lock.withLock {
            if let override = _overrideIsNordVPN { return override }
            guard let path = currentPath else { return false }
            guard Self.isVPNPath(path) else { return false }
            return Self.matchesNordGateway(path)
        }
    }

    public var primaryInterfaceDescription: String {
        lock.withLock {
            guard let path = currentPath else { return "Unknown" }
            let interfaces = path.availableInterfaces.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")
            return interfaces.isEmpty ? "None" : interfaces
        }
    }

    private init() {
        if NotificationService.isRunningTests {
            self.monitor = nil
            return
        }

        let mon = NWPathMonitor()
        self.monitor = mon
        mon.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        mon.start(queue: queue)
    }

    private static func isVPNPath(_ path: NWPath) -> Bool {
        path.usesInterfaceType(.other) ||
            path.availableInterfaces.contains { $0.type == .other || $0.name.hasPrefix("utun") || $0.name.hasPrefix("ppp") || $0.name.hasPrefix("ipsec") }
    }

    private static func matchesNordGateway(_ path: NWPath) -> Bool {
        if path.availableInterfaces.contains(where: { $0.name.lowercased().contains("nord") }) {
            return true
        }
        for gateway in path.gateways {
            let desc = gateway.debugDescription
            if desc.contains("10.5.") || desc.contains("100.64.") {
                return true
            }
        }
        return false
    }

    deinit {
        monitor?.cancel()
    }

    private func handlePathUpdate(_ path: NWPath) {
        let (vpnChanged, isVPN, isNord, v6) = lock.withLock { () -> (Bool, Bool, Bool, Bool) in
            currentPath = path
            let active = Self.isVPNPath(path)
            let nord = active && Self.matchesNordGateway(path)
            let v6Supported = path.supportsIPv6
            let changed = (lastReportedVPNState != active)
            lastReportedVPNState = active
            return (changed, active, nord, v6Supported)
        }

        if vpnChanged {
            let vpnType = isNord ? "NordVPN" : "VPN"
            Task { @MainActor in
                if isVPN {
                    LoggerService.shared.log("[Network] Active \(vpnType) connection detected (IPv6 supported: \(v6)). Enabling VPN-optimized transport.", level: .info)
                } else {
                    LoggerService.shared.log("[Network] Standard network interface active (VPN disconnected). Restoring default transport.", level: .info)
                }
            }
        }
    }
}
