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
    // Bolt Performance Optimization: Process binary cookie data using direct `withUnsafeBytes` buffer
    // pointer indexing and bitwise arithmetic to avoid O(N) heap array allocations ([UInt8](data))
    // and closure iterator overhead ((0..<4).reduce) during binary cookie parsing.
    static func parse(_ data: Data) -> [HTTPCookie] {
        return data.withUnsafeBytes { buffer -> [HTTPCookie] in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            let totalCount = buffer.count

            func uint32(_ at: Int, bigEndian: Bool) -> Int? {
                guard at >= 0, at + 4 <= totalCount else { return nil }
                if bigEndian {
                    return (Int(baseAddress[at]) << 24) |
                           (Int(baseAddress[at + 1]) << 16) |
                           (Int(baseAddress[at + 2]) << 8) |
                           Int(baseAddress[at + 3])
                } else {
                    return Int(baseAddress[at]) |
                           (Int(baseAddress[at + 1]) << 8) |
                           (Int(baseAddress[at + 2]) << 16) |
                           (Int(baseAddress[at + 3]) << 24)
                }
            }

            func double(_ at: Int) -> Double? {
                guard at >= 0, at + 8 <= totalCount else { return nil }
                let raw = UInt64(baseAddress[at]) |
                         (UInt64(baseAddress[at + 1]) << 8) |
                         (UInt64(baseAddress[at + 2]) << 16) |
                         (UInt64(baseAddress[at + 3]) << 24) |
                         (UInt64(baseAddress[at + 4]) << 32) |
                         (UInt64(baseAddress[at + 5]) << 40) |
                         (UInt64(baseAddress[at + 6]) << 48) |
                         (UInt64(baseAddress[at + 7]) << 56)
                return Double(bitPattern: raw)
            }

            func string(_ at: Int, end: Int) -> String? {
                guard at >= 0, at < end, end <= totalCount else { return nil }
                guard let nullOffset = (at..<end).first(where: { baseAddress[$0] == 0 }) else { return nil }
                let slice = UnsafeBufferPointer(start: baseAddress + at, count: nullOffset - at)
                return String(bytes: slice, encoding: .utf8)
            }

            guard totalCount >= 4,
                  baseAddress[0] == 0x63, // 'c'
                  baseAddress[1] == 0x6F, // 'o'
                  baseAddress[2] == 0x6F, // 'o'
                  baseAddress[3] == 0x6B, // 'k'
                  let pageCount = uint32(4, bigEndian: true) else { return [] }

            var cookies: [HTTPCookie] = []
            var pageStart = 8 + 4 * pageCount
            for page in 0..<pageCount {
                // A bad page size loses every later page boundary; a bad record table does not.
                guard let pageSize = uint32(8 + 4 * page, bigEndian: true),
                      pageSize >= 8, pageStart + pageSize <= totalCount else { break }
                let pageEnd = pageStart + pageSize
                defer { pageStart = pageEnd }
                guard let recordCount = uint32(pageStart + 4, bigEndian: false),
                      recordCount <= (pageSize - 8) / 4 else { continue }
                for index in 0..<recordCount {
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
}
