import SwiftUI
import AppKit

struct DebugLogView: View {
    @ObservedObject private var logger = LoggerService.shared
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.geist(15, weight: .semibold))
                    .foregroundColor(SiphonTheme.accent)

                Text("Debug Logs")
                    .font(.geist(15, weight: .bold))

                HStack(spacing: 4) {
                    Circle()
                        .fill(SiphonTheme.statusCompleted)
                        .frame(width: 6, height: 6)
                    Text("\(logger.logs.count) entries")
                        .font(.geistMono(11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04))
                .clipShape(Capsule())

                Spacer()

                Button {
                    DebugLogWindowManager.shared.closeWindow()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Log Console Container
            ZStack {
                RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                    .fill(Color.primary.opacity(0.03))
                    .background(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                ReadOnlyLogView(
                    text: logger.logs.isEmpty ? "No logs recorded yet." : logger.logs.joined(separator: "\n"),
                    fontSize: 11
                )
                .padding(8)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            // Bottom Action Bar
            HStack(spacing: 10) {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logger.logs.joined(separator: "\n"), forType: .string)
                    isCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        isCopied = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isCopied ? "Copied" : "Copy All")
                            .font(.geist(12, weight: .medium))
                    }
                    .foregroundColor(isCopied ? SiphonTheme.statusCompleted : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                }
                .buttonStyle(.plain)

                Button {
                    logger.clearLogs()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Clear")
                            .font(.geist(12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([logger.exportLogs()])
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Show in Finder")
                            .font(.geist(12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 550, minHeight: 350)
        .background(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusCard)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        )
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusCard)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .ignoresSafeArea()
        )
        .preferredColorScheme(theme == "light" ? .light : (theme == "dark" ? .dark : nil))
    }
}
