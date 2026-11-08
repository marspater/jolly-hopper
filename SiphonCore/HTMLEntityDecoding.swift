import Foundation

// MARK: - HTML Entity Decoding Extension
public extension String {
    // Bolt Performance Optimization: Pre-compile static dictionary of named HTML entities to eliminate O(N) array search overhead with O(1) hash map lookups on every entity decoding call.
    nonisolated private static let namedHTMLEntities: [String: String] = [
        "&quot;": "\"",
        "&apos;": "'",
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&nbsp;": " ",
        "&copy;": "©",
        "&reg;": "®",
        "&trade;": "™",
        "&mdash;": "—",
        "&ndash;": "–",
        "&hellip;": "…",
        "&lsquo;": "‘",
        "&rsquo;": "’",
        "&ldquo;": "“",
        "&rdquo;": "”",
        "&bull;": "•"
    ]

    private static func decodeSingleHTMLEntity(_ entity: Substring) -> String? {
        guard entity.hasPrefix("&") && entity.hasSuffix(";") else { return nil }

        if entity.hasPrefix("&#") {
            let inner = entity.dropFirst(2).dropLast()
            guard !inner.isEmpty else { return nil }
            let isHex = inner.hasPrefix("x") || inner.hasPrefix("X")
            let digits = isHex ? inner.dropFirst() : inner
            guard !digits.isEmpty, digits.count <= 7 else { return nil }
            guard let codePoint = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(codePoint) else {
                return nil
            }
            return String(scalar)
        } else {
            return String.namedHTMLEntities[String(entity)]
        }
    }

    /// Decodes named, decimal (e.g. &#039; or &#39;), and hexadecimal (e.g. &#x27;) HTML entities into plain text.
    /// Bolt Performance Optimization: Single-pass native Swift scanner using Substring slicing and capacity pre-allocation
    /// to eliminate NSRegularExpression compilation, NSTextCheckingResult arrays, and NSMutableString heap allocations.
    func decodingHTMLEntities() -> String {
        guard self.contains("&") else { return self }

        var result = ""
        result.reserveCapacity(self.utf8.count)

        var searchIndex = self.startIndex
        while searchIndex < self.endIndex {
            guard let ampersandIndex = self[searchIndex...].firstIndex(of: "&") else {
                result.append(contentsOf: self[searchIndex...])
                break
            }

            result.append(contentsOf: self[searchIndex..<ampersandIndex])

            let maxSearchEnd = self.index(ampersandIndex, offsetBy: 35, limitedBy: self.endIndex) ?? self.endIndex
            let entityRange = ampersandIndex..<maxSearchEnd

            if let semicolonIndex = self[entityRange].firstIndex(of: ";") {
                let entitySlice = self[ampersandIndex...semicolonIndex]
                if let replacement = String.decodeSingleHTMLEntity(entitySlice) {
                    result.append(replacement)
                    searchIndex = self.index(after: semicolonIndex)
                    continue
                }
            }

            result.append("&")
            searchIndex = self.index(after: ampersandIndex)
        }

        return result
    }
}
