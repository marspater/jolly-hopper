import Foundation

/// Safari's on-disk cookie store. It holds persistent cookies only: Safari keeps
/// session cookies in memory, so a sign-in made without "Remember me" is not here.
/// Reading it needs Full Disk Access.
enum SafariCookieReader {
    static let cookieFiles: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "Library/Cookies/Cookies.binarycookies"
        ].map { home.appendingPathComponent($0) }
    }()

    /// Unexpired cookies from the first store that has any. A readable store that is
    /// corrupt, empty or fully expired falls through to the next one.
    static func cookies(now: Date = Date(), files: [URL] = cookieFiles) -> [HTTPCookie] {
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let live = parse(data).filter { ($0.expiresDate ?? .distantFuture) > now }
            if !live.isEmpty { return live }
        }
        return []
    }

    /// `Cookies.binarycookies`: "cook", a big-endian page count and page sizes, then
    /// pages of little-endian records. A record's strings sit at offsets inside it, and
    /// its dates count seconds from 2001-01-01. Malformed pages and records are skipped.
    static func parse(_ data: Data) -> [HTTPCookie] {
        let bytes = [UInt8](data)
        func uint32(_ at: Int, bigEndian: Bool) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return (0..<4).reduce(0) { value, index in
                value | Int(bytes[at + index]) << (8 * (bigEndian ? 3 - index : index))
            }
        }
        func double(_ at: Int) -> Double? {
            guard at >= 0, at + 8 <= bytes.count else { return nil }
            let raw = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
            return Double(bitPattern: raw)
        }
        func string(_ at: Int, end: Int) -> String? {
            guard at >= 0, at < end, end <= bytes.count,
                  let terminator = bytes[at..<end].firstIndex(of: 0) else { return nil }
            return String(decoding: bytes[at..<terminator], as: UTF8.self)
        }

        guard bytes.starts(with: Array("cook".utf8)), let pageCount = uint32(4, bigEndian: true) else { return [] }
        var cookies: [HTTPCookie] = []
        var pageStart = 8 + 4 * pageCount
        for page in 0..<pageCount {
            // A bad page size loses every later page boundary; a bad record table does not.
            guard let pageSize = uint32(8 + 4 * page, bigEndian: true),
                  pageSize >= 8, pageStart + pageSize <= bytes.count else { break }
            let pageEnd = pageStart + pageSize
            defer { pageStart = pageEnd }
            guard let count = uint32(pageStart + 4, bigEndian: false),
                  count <= (pageSize - 8) / 4 else { continue }
            for index in 0..<count {
                guard let offset = uint32(pageStart + 8 + 4 * index, bigEndian: false) else { break }
                let record = pageStart + offset
                guard let size = uint32(record, bigEndian: false), size >= 56, record + size <= pageEnd,
                      let flags = uint32(record + 8, bigEndian: false),
                      let domainAt = uint32(record + 16, bigEndian: false),
                      let nameAt = uint32(record + 20, bigEndian: false),
                      let pathAt = uint32(record + 24, bigEndian: false),
                      let valueAt = uint32(record + 28, bigEndian: false),
                      let expires = double(record + 40),
                      let domain = string(record + domainAt, end: record + size),
                      let name = string(record + nameAt, end: record + size),
                      let path = string(record + pathAt, end: record + size),
                      let value = string(record + valueAt, end: record + size) else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: domain,
                    .name: name,
                    .path: path,
                    .value: value,
                    .expires: Date(timeIntervalSinceReferenceDate: expires)
                ]
                if flags & 1 != 0 { properties[.secure] = "TRUE" }
                if flags & 4 != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let cookie = HTTPCookie(properties: properties) { cookies.append(cookie) }
            }
        }
        return cookies
    }
}
