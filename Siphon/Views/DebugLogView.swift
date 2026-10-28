import SwiftUI
import AppKit

struct DebugLogView: View {
    @ObservedObject private var logger = LoggerService.shared
    @ObservedObject private var languageService = LanguageService.shared
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @StateObject private var copyFeedback = TransientFeedbackState()
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: SiphonTheme.spacing12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SiphonTheme.accentText)
                    .accessibilityHidden(true)

                Text(languageService.s("debug_logs"))
                    .font(.siphonWindowTitle)

                SiphonTagBadge(
                    text: "\(logger.logs.count) \(languageService.s("entries"))",
                    tintColor: .secondary,
                    isMonospaced: true
                )

                Spacer()
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.top, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing12)

            // Log Console Container
            ZStack {
                SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
                    .overlay(SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard))

                ReadOnlyLogView(
                    text: logger.logs.isEmpty ? languageService.s("no_log_output") : logger.logs.joined(separator: "\n"),
                    fontSize: 11
                )
                .padding(SiphonTheme.spacing8)
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing14)

            // Bottom Action Bar
            HStack(spacing: SiphonTheme.spacing10) {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(LoggerService.sanitizeLogContentForExport(logger.logs.joined(separator: "\n")), forType: .string)
                    copyFeedback.show(languageService.s("copied"), isSuccess: true, duration: 1.5)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copyFeedback.isShowing ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .accessibilityHidden(true)
                        Text(copyFeedback.isShowing ? languageService.s("copied") : languageService.s("copy_log"))
                            .font(.siphonSecondaryMedium)
                    }
                    .foregroundColor(copyFeedback.isShowing ? SiphonTheme.statusCompletedText : .primary)
                }
                .buttonStyle(.siphonSecondary)
                .disabled(logger.logs.isEmpty)
                .help(languageService.s("copy_log"))
                .accessibilityLabel(copyFeedback.isShowing ? languageService.s("copied") : languageService.s("copy_log"))

                Button {
                    logger.clearLogs()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(languageService.s("clear"))
                            .font(.siphonSecondaryMedium)
                    }
                }
                .buttonStyle(.siphonSecondary)
                .disabled(logger.logs.isEmpty)
                .help(languageService.s("clear"))

                Spacer()

                Button {
                    guard !isExporting else { return }
                    isExporting = true
                    Task {
                        defer { isExporting = false }
                        do {
                            let url = try await logger.exportLogs()
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } catch {
                            logger.log("Failed to export logs: \(error.localizedDescription)", level: .error)
                            NSAlert(error: error).runModal()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isExporting {
                            SiphonSpinner(size: 11, color: .primary, lineWidth: 1.6)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text(languageService.s("reveal_in_finder"))
                            .font(.siphonSecondaryMedium)
                    }
                }
                .buttonStyle(.siphonSecondary)
                .disabled(logger.logs.isEmpty || isExporting)
                .help(languageService.s("reveal_in_finder"))
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing16)
        }
        .frame(minWidth: 550, idealWidth: 620, minHeight: 350, idealHeight: 420)
        .siphonAdaptiveRendering()
        .siphonWindowBackground()
        .preferredColorScheme(activeColorScheme)
    }

    private var activeColorScheme: ColorScheme? {
        if theme == "light" {
            return .light
        } else if theme == "dark" {
            return .dark
        } else {
            return nil
        }
    }
}
