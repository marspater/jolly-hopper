//
//  ProcessLifecycleState.swift
//  Siphon
//

import Foundation

public enum ProcessLifecycleState: Sendable, Equatable {
    case created
    case starting
    case running(pid: pid_t)
    case cancelling(pid: pid_t)
    case terminated(exitCode: Int32, reason: Process.TerminationReason)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isTerminated: Bool {
        if case .terminated = self { return true }
        return false
    }

    public var isCancelling: Bool {
        if case .cancelling = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var canCancel: Bool {
        switch self {
        case .created, .starting, .running:
            return true
        case .cancelling, .terminated, .failed:
            return false
        }
    }
}
