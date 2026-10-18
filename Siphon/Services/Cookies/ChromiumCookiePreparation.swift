//
//  ChromiumCookiePreparation.swift
//  Siphon
//

import Foundation

/// Adapts Chromium browser arguments and merges owned temporary cookie files.
/// Profile discovery, Keychain access, and cookie verification remain in the reader.
extension ChromiumCookieReader {
    static func prepare(_ args: [String], rootOverride: URL? = nil) throws -> (args: [String], cookieFile: SecureCookieFile?) {
        guard let index = args.firstIndex(of: "--cookies-from-browser"), index + 1 < args.count else {
            return (args, nil)
        }
        let browserArg = args[index + 1].lowercased()
        guard browserArg == "helium" || browserArg == "chromium-based" || browserArg == "arc" else {
            return (args, nil)
        }
        guard let target = args.last.flatMap(URL.init(string:)), ["http", "https"].contains(target.scheme) else {
            throw failure("Missing HTTP target for cookie extraction.")
        }
        let root: URL
        if let rootOverride {
            root = rootOverride
        } else if browserArg == "arc", let arcBrowser = knownChromiumBrowsers.first(where: { $0.name == "Arc" }) {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(arcBrowser.relativePath)
        } else {
            root = defaultHeliumRoot
        }
        var prepared = args
        guard let file = try export(for: target, root: root, searchOtherBrowsers: browserArg == "chromium-based") else {
            let host = target.host ?? "target"
            Task { @MainActor in
                LoggerService.shared.log("No \(browserArg) cookies for \(host); continuing without browser cookies.", level: .info)
            }
            prepared.removeSubrange(index...index + 1)
            return (prepared, nil)
        }
        prepared.removeSubrange(index...index + 1)
        if let cookieIndex = prepared.firstIndex(of: "--cookies"), cookieIndex + 1 < prepared.count {
            // Browser cookies and a challenge/session file must reach yt-dlp together.
            // Keep the supplied cookies last so they override stale browser values.
            let supplied = try String(contentsOfFile: prepared[cookieIndex + 1], encoding: .utf8)
            let handle = try FileHandle(forWritingTo: file.fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n" + supplied).utf8))
            prepared[cookieIndex + 1] = file.path
        } else {
            prepared.insert(contentsOf: ["--cookies", file.path], at: index)
        }
        return (prepared, file)
    }
}
