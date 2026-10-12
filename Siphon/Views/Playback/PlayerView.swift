import AVKit
import SwiftUI

struct PlayerView: View {
    @ObservedObject var service: PlaybackService
    let acceptsStreamURL: Bool
    let localFile: URL?
    let configuredSource: PlaybackSource?
    let openSource: (PlaybackSource) -> Void
    @State private var streamURL = ""
    @State private var inputError: String?
    @State private var authorization = ""

    var body: some View {
        VStack(spacing: SiphonTheme.spacing12) {
            if acceptsStreamURL {
                HStack {
                    TextField(LanguageService.s("playback_stream_url"), text: $streamURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitStream() }
                    Button(LanguageService.s("playback_play_stream")) { submitStream() }
                        .disabled(streamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, SiphonTheme.spacing20)
                .padding(.top, SiphonTheme.spacing12)
            }
            if case .hls(let manifestURL, let drm) = configuredSource {
                VStack(alignment: .leading, spacing: SiphonTheme.spacing8) {
                    VStack(alignment: .leading, spacing: SiphonTheme.spacing8) {
                        LabeledContent(LanguageService.s("playback_stream_server"), value: manifestURL.host ?? "")
                        if let drm {
                            LabeledContent(LanguageService.s("playback_certificate_server"), value: drm.certificateURL.host ?? "")
                            LabeledContent(LanguageService.s("playback_license_server"), value: (drm.licenseServerURL.host ?? "") + (drm.licenseServerURL.port.map { ":\($0)" } ?? ""))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(serverDescription(manifestURL: manifestURL, drm: drm))
                    if drm != nil {
                        SecureField(LanguageService.s("playback_authorization"), text: $authorization)
                            .textFieldStyle(.roundedBorder)
                        Text(LanguageService.s("playback_authorization_help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(LanguageService.s("playback_play_stream")) {
                        var configuredDRM = drm
                        configuredDRM?.authorization = authorization.isEmpty ? nil : authorization
                        openSource(.hls(manifestURL: manifestURL, drm: configuredDRM))
                    }
                }
                .padding(.horizontal, SiphonTheme.spacing20)
                .padding(.top, SiphonTheme.spacing12)
            }
            NativePlayerView(player: service.player)
                .frame(minWidth: 480, minHeight: 270)
                .accessibilityLabel(LanguageService.s("playback_player"))
            if service.state == .loading || service.state == .buffering {
                ProgressView(LanguageService.s("playback_loading"))
            }
            if let message = inputError ?? service.errorMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SiphonTheme.spacing20)
                    .textSelection(.enabled)
                if let localFile {
                    Button(LanguageService.s("playback_open_external")) {
                        NSWorkspace.shared.open(localFile)
                    }
                }
            }
        }
        .padding(.bottom, SiphonTheme.spacing12)
        .siphonWindowBackground()
        .onDisappear { authorization = "" }
    }

    private func serverDescription(manifestURL: URL, drm: DRMConfiguration?) -> String {
        var descriptions = [LanguageService.s("playback_stream_server") + ": " + (manifestURL.host ?? "")]
        if let drm {
            descriptions.append(LanguageService.s("playback_certificate_server") + ": " + (drm.certificateURL.host ?? ""))
            descriptions.append(LanguageService.s("playback_license_server") + ": " + (drm.licenseServerURL.host ?? "") + (drm.licenseServerURL.port.map { ":\($0)" } ?? ""))
        }
        return descriptions.joined(separator: ". ")
    }

    private func submitStream() {
        guard let url = URL(string: streamURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            inputError = LanguageService.s("playback_invalid_configuration")
            return
        }
        inputError = nil
        openSource(.hls(manifestURL: url, drm: nil))
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .default
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
