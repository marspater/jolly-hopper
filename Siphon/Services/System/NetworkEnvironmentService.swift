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
    private var storedOverrideIsVPNActive: Bool?
    private var storedOverrideSupportsIPv6: Bool?
    private var storedOverrideIsNordVPN: Bool?

    // Secondary Insights state
    private var secondaryNordConfirmed: Bool = false
    private var inFlightInsightsTask: Task<Void, Never>?

    public var overrideIsVPNActive: Bool? {
        get { lock.withLock { storedOverrideIsVPNActive } }
        set { lock.withLock { storedOverrideIsVPNActive = newValue } }
    }

    public var overrideSupportsIPv6: Bool? {
        get { lock.withLock { storedOverrideSupportsIPv6 } }
        set { lock.withLock { storedOverrideSupportsIPv6 = newValue } }
    }

    public var overrideIsNordVPN: Bool? {
        get { lock.withLock { storedOverrideIsNordVPN } }
        set { lock.withLock { storedOverrideIsNordVPN = newValue } }
    }

    public var isVPNActive: Bool {
        lock.withLock {
            if let override = storedOverrideIsVPNActive { return override }
            guard let path = currentPath else { return false }
            return Self.isVPNPath(path)
        }
    }

    public var supportsIPv6: Bool {
        lock.withLock {
            if let override = storedOverrideSupportsIPv6 { return override }
            guard let path = currentPath else { return true }
            return path.supportsIPv6
        }
    }

    public var isNordVPNDetected: Bool {
        lock.withLock {
            if let override = storedOverrideIsNordVPN { return override }
            guard let path = currentPath else { return false }
            guard Self.isVPNPath(path) else { return false }
            return Self.matchesNordGateway(path) || secondaryNordConfirmed
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
        inFlightInsightsTask?.cancel()
    }

    /// Optional, non-blocking secondary check against NordVPN Insights endpoint.
    /// Local detection via NWPathMonitor remains the primary authoritative signal.
    /// This request is purely best-effort, never blocks downloads or startup,
    /// and gracefully degrades if the undocumented endpoint changes or fails.
    nonisolated public static func performInsightsCheck(session: URLSession? = nil) async -> Bool {
        guard let url = URL(string: "https://api.nordvpn.com/v1/helpers/ips/insights") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let activeSession: URLSession
        if let session {
            activeSession = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2.5
            config.timeoutIntervalForResource = 3.0
            activeSession = URLSession(configuration: config)
        }

        do {
            let (data, response) = try await activeSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            if let protected = json["protected"] as? Bool, protected {
                return true
            }
            if let isp = (json["isp"] as? String)?.lowercased(), isp.contains("nord") {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func triggerOptionalSecondaryInsightsCheck(session: URLSession? = nil) {
        if NotificationService.isRunningTests && session == nil {
            return
        }

        lock.withLock {
            inFlightInsightsTask?.cancel()
            inFlightInsightsTask = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let isConfirmed = await Self.performInsightsCheck(session: session)
                if !Task.isCancelled && isConfirmed {
                    self.lock.withLock {
                        self.secondaryNordConfirmed = true
                    }
                    Task { @MainActor in
                        LoggerService.shared.log("[Network] NordVPN confirmed via secondary Insights check.", level: .info)
                    }
                }
            }
        }
    }

    public func resetSecondaryInsightsForTesting() {
        lock.withLock {
            secondaryNordConfirmed = false
            inFlightInsightsTask?.cancel()
            inFlightInsightsTask = nil
        }
    }

    @discardableResult
    public func applySecondaryInsightsForTesting(session: URLSession) async -> Bool {
        let confirmed = await Self.performInsightsCheck(session: session)
        lock.withLock {
            if confirmed {
                self.secondaryNordConfirmed = true
            }
        }
        return confirmed
    }

    private struct NetworkStateChange {
        let vpnChanged: Bool
        let isVPNActive: Bool
        let isNordVPN: Bool
        let ipv6Supported: Bool
        let shouldTriggerInsights: Bool
    }

    private func computePathUpdate(_ path: NWPath) -> NetworkStateChange {
        currentPath = path
        let active = Self.isVPNPath(path)
        let localNord = active && Self.matchesNordGateway(path)
        let changed = (lastReportedVPNState != active)
        lastReportedVPNState = active

        let shouldTrigger = updateInsightsLifecycle(active: active, changed: changed, localNord: localNord)
        return NetworkStateChange(
            vpnChanged: changed,
            isVPNActive: active,
            isNordVPN: localNord || secondaryNordConfirmed,
            ipv6Supported: path.supportsIPv6,
            shouldTriggerInsights: shouldTrigger
        )
    }

    private func updateInsightsLifecycle(active: Bool, changed: Bool, localNord: Bool) -> Bool {
        guard active else {
            secondaryNordConfirmed = false
            inFlightInsightsTask?.cancel()
            inFlightInsightsTask = nil
            return false
        }
        if changed { return true }
        return !localNord && !secondaryNordConfirmed
    }

    private func logStateChange(_ change: NetworkStateChange) {
        guard change.vpnChanged else { return }
        let vpnType = change.isNordVPN ? "NordVPN" : "VPN"
        Task { @MainActor in
            if change.isVPNActive {
                LoggerService.shared.log("[Network] Active \(vpnType) connection detected (IPv6 supported: \(change.ipv6Supported)). Enabling VPN-optimized transport.", level: .info)
            } else {
                LoggerService.shared.log("[Network] Standard network interface active (VPN disconnected). Restoring default transport.", level: .info)
            }
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        let change = lock.withLock { computePathUpdate(path) }

        if change.shouldTriggerInsights {
            triggerOptionalSecondaryInsightsCheck()
        }

        logStateChange(change)
    }
}
