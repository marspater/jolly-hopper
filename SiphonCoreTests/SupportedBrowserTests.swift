import SiphonCore
import Testing

struct SupportedBrowserTests {
    @Test(arguments: [
        (" Safari ", "safari"),
        ("helium", "helium"),
        ("chromium-based", "chromium-based"),
        ("not-a-browser", nil),
        (nil, nil)
    ] as [(String?, String?)])
    func normalizedCookieSource(raw: String?, expected: String?) {
        #expect(SupportedBrowser.normalizedCookieSource(raw) == expected)
    }
}
