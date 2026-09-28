#!/usr/bin/env swift
//
// Signs a Siphon release manifest with the offline Ed25519 release key.
// The app pins the matching public key in UpdateManifestVerifier and, for every
// release after UpdateChecker.lastUnsignedRelease, refuses to update without it.
//
//   swift scripts/sign-release-manifest.swift keygen <private-key-file>
//       Writes a new private key (base64, mode 600) and prints its public key,
//       which goes into UpdateManifestVerifier.defaultPublicKeyBase64.
//
//   swift scripts/sign-release-manifest.swift sign <private-key-file> <version> <asset>...
//       Writes release-manifest.json and release-manifest.json.sig to the current
//       directory. Upload both next to the assets on the GitHub release.

import CryptoKit
import Foundation

struct Manifest: Encodable {
    let version: String
    let assets: [String: String]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func sha256Hex(of file: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: file) else { fail("Cannot read \(file.path)") }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("\(path) is not a base64 Ed25519 private key")
    }
    return key
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "keygen":
    guard arguments.count == 2, let path = arguments.last else { fail("usage: keygen <private-key-file>") }
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists; refusing to overwrite a key") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(
        atPath: path,
        contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600]
    ) else { fail("Cannot write \(path)") }
    print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")

case "sign":
    let values = Array(arguments.dropFirst())
    guard values.count >= 3 else { fail("usage: sign <private-key-file> <version> <asset>...") }
    let key = loadKey(values[0])
    let version = values[1].hasPrefix("v") ? String(values[1].dropFirst()) : values[1]
    var assets: [String: String] = [:]
    for path in values.dropFirst(2) {
        let file = URL(fileURLWithPath: path)
        assets[file.lastPathComponent] = sha256Hex(of: file)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    // The signature covers these exact bytes; the app verifies before parsing.
    let data = try encoder.encode(Manifest(version: version, assets: assets))
    let signature = try key.signature(for: data)
    try data.write(to: URL(fileURLWithPath: "release-manifest.json"))
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: "release-manifest.json.sig"))
    print("Signed \(assets.count) asset(s) for \(version): release-manifest.json, release-manifest.json.sig")

default:
    fail("usage: sign-release-manifest.swift keygen <private-key-file> | sign <private-key-file> <version> <asset>...")
}
