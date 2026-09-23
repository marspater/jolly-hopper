import SwiftUI
import AppKit

struct DebugLogView: View {
    @ObservedObject private var logger = LoggerService.shared
    @ObservedObject private var languageService = LanguageService.shared
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: SiphonTheme.spacing12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SiphonTheme.accentText)

                Text(languageService.s("debug_logs"))
                    .font(.siphonHeadline)

                SiphonTagBadge(
                    text: "\(logger.logs.count) \(languageService.s("entries"))",
                    tintColor: .secondary,
                    isMonospaced: true
                )

                Spacer()

                Button {
                    DebugLogWindowManager.shared.closeWindow()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.siphonIcon(size: 24))
                .help(languageService.s("close"))
                .accessibilityLabel(languageService.s("close"))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.top, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing12)

            // Log Console Container
            ZStack {
                SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl)
                    .overlay(SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl))

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
                    pasteboard.setString(logger.logs.joined(separator: "\n"), forType: .string)
                    withAnimation(SiphonAnimation.snappySpring) {
                        isCopied = true
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(SiphonAnimation.snappySpring) {
                            isCopied = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isCopied ? languageService.s("copied") : languageService.s("copy_log"))
                            .font(.siphonSecondaryMedium)
                    }
                    .foregroundColor(isCopied ? SiphonTheme.statusCompletedText : .primary)
                    .opacity(logger.logs.isEmpty ? 0.5 : 1.0)
                }
                .buttonStyle(.siphonSecondary)
                .disabled(logger.logs.isEmpty)
                .help(languageService.s("copy_log"))
                .accessibilityLabel(languageService.s("copy_log"))

                Button {
                    logger.clearLogs()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                        Text(languageService.s("clear"))
                            .font(.siphonSecondaryMedium)
                    }
                    .foregroundColor(.secondary)
                    .opacity(logger.logs.isEmpty ? 0.5 : 1.0)
                }
                .buttonStyle(.siphonSecondary)
                .disabled(logger.logs.isEmpty)
                .help(languageService.s("clear"))
                .accessibilityLabel(languageService.s("clear"))

                Spacer()

                Button {
                    Task {
                        if let url = try? await logger.exportLogs() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                        Text(languageService.s("reveal_in_finder"))
                            .font(.siphonSecondaryMedium)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.siphonSecondary)
                .help(languageService.s("reveal_in_finder"))
                .accessibilityLabel(languageService.s("reveal_in_finder"))
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing16)
        }
        .frame(minWidth: 550, idealWidth: 620, minHeight: 350, idealHeight: 420)
        .siphonAdaptiveRendering()
        .siphonWindowBackground()
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusSheet)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .ignoresSafeArea()
        )
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
