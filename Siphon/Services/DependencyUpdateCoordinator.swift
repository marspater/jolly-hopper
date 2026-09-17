//
//  DependencyUpdateCoordinator.swift
//  Siphon
//

import Foundation
import Combine

struct YtdlpUpdateMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class DependencyUpdateCoordinator: ObservableObject {
    @Published var version: String?
    @Published var isUpdating: Bool = false
    @Published var updateProgress: Double = 0
    @Published var updateMessage: YtdlpUpdateMessage?

    private var cancellables = Set<AnyCancellable>()
    private let notificationService: NotificationService

    init(notificationService: NotificationService = .shared) {
        self.notificationService = notificationService
    }

    func bind(to ytdlpService: YtdlpService) {
        cancellables.removeAll()
        ytdlpService.$isUpdating
            .receive(on: RunLoop.main)
            .assign(to: &$isUpdating)
        ytdlpService.$updateProgress
            .receive(on: RunLoop.main)
            .assign(to: &$updateProgress)
    }

    func initialize(service: YtdlpService, skipBinarySetup: Bool = false) async {
        if !skipBinarySetup && (service.processRunner is DefaultYtdlpProcessRunner) {
            await service.setupBinaries()
            version = service.version
        } else if let ver = service.version {
            version = ver
        } else if !(service.processRunner is DefaultYtdlpProcessRunner) {
            await service.getVersion()
            version = service.version
        }
    }

    func updateYtdlp(service: YtdlpService) async {
        guard !isUpdating else { return }
        updateMessage = nil
        do {
            let installedVersion = try await service.updateYtdlp()
            version = installedVersion
            updateMessage = YtdlpUpdateMessage(
                title: "yt-dlp Updated",
                message: "Installed yt-dlp version \(installedVersion)."
            )
            notificationService.sendYtdlpUpdateSucceeded(version: installedVersion)
        } catch {
            let reason = error.localizedDescription
            updateMessage = YtdlpUpdateMessage(
                title: "yt-dlp Update Failed",
                message: reason
            )
            notificationService.sendYtdlpUpdateFailed(reason: reason)
        }
    }
}
