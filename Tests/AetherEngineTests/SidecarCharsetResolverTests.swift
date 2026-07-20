import Foundation
import Testing
@testable import AetherEngine

/// Charset resolution order for sidecar subtitle files (SubtitleDecoder audit finding A):
/// declared Content-Type charset -> BOM -> strict UTF-8 validity -> language-informed legacy
/// fallback. Byte content alone can never disambiguate the legacy tier (windows-1252 and
/// windows-1257 both accept every byte sequence, just decoding to different characters), so those
/// cases are exercised via the language hint rather than "does it decode" heuristics.
struct SidecarCharsetResolverTests {

    @Test("an explicit Content-Type charset wins over everything else")
    func contentTypeWins() {
        let bytes = Data([0xC1, 0xE9]) // valid windows-1251, invalid UTF-8
        let encoding = SidecarCharsetResolver.resolve(
            contentType: "text/plain; charset=windows-1251", bytes: bytes, language: "en")
        #expect(encoding == .windowsCP1251)
    }

    @Test("charset name parses past extra Content-Type parameters and quoting")
    func charsetNameParsing() {
        #expect(SidecarCharsetResolver.charsetName(fromContentType: "text/plain; charset=UTF-8") == "UTF-8")
        #expect(SidecarCharsetResolver.charsetName(fromContentType: "text/plain;charset=\"windows-1250\"") == "windows-1250")
        #expect(SidecarCharsetResolver.charsetName(fromContentType: "text/plain") == nil)
    }

    @Test("a UTF-8 BOM is detected and wins over the legacy fallback")
    func utf8BOMDetected() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append("hello".data(using: .utf8)!)
        let encoding = SidecarCharsetResolver.resolve(contentType: nil, bytes: bytes, language: "ru")
        #expect(encoding == .utf8)
    }

    @Test("a UTF-16LE BOM is detected")
    func utf16LEBOMDetected() {
        let bytes = Data([0xFF, 0xFE, 0x48, 0x00])
        let match = SidecarCharsetResolver.detectBOM(bytes)
        #expect(match?.encoding == .utf16LittleEndian)
        #expect(match?.length == 2)
    }

    @Test("decode strips a UTF-8 BOM before returning text")
    func decodeStripsUTF8BOM() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append("hi".data(using: .utf8)!)
        let text = SidecarCharsetResolver.decode(bytes, as: .utf8)
        #expect(text == "hi")
    }

    @Test("valid UTF-8 with no declared charset and no BOM is accepted as UTF-8")
    func strictUTF8Accepted() {
        let bytes = "café".data(using: .utf8)!
        let encoding = SidecarCharsetResolver.resolve(contentType: nil, bytes: bytes, language: nil)
        #expect(encoding == .utf8)
    }

    @Test("byte sequences invalid as UTF-8 never resolve to UTF-8")
    func invalidUTF8Rejected() {
        // 0xE9 alone is a truncated 3-byte UTF-8 lead sequence - invalid on its own.
        let bytes = Data([0x48, 0xE9, 0x6C])
        #expect(!SidecarCharsetResolver.isStrictUTF8(bytes))
    }

    @Test("legacy fallback: Baltic languages map to windows-1257")
    func legacyBalticFallback() {
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "lv") == SidecarCharsetResolver.windowsCP1257)
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "lt") == SidecarCharsetResolver.windowsCP1257)
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "et") == SidecarCharsetResolver.windowsCP1257)
    }

    @Test("legacy fallback: Cyrillic-script languages map to windows-1251")
    func legacyCyrillicFallback() {
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "ru") == .windowsCP1251)
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "uk") == .windowsCP1251)
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "bg") == .windowsCP1251)
    }

    @Test("legacy fallback: Central European languages map to windows-1250")
    func legacyCentralEuropeanFallback() {
        for lang in ["pl", "cs", "sk", "hu", "hr", "sl", "ro"] {
            #expect(SidecarCharsetResolver.legacyFallback(forLanguage: lang) == .windowsCP1250,
                    "expected windows-1250 for \(lang)")
        }
    }

    @Test("legacy fallback: unlisted and nil languages default to windows-1252")
    func legacyDefaultFallback() {
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: nil) == .windowsCP1252)
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "de") == .windowsCP1252)
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "fr") == .windowsCP1252)
    }

    @Test("a region subtag does not defeat the primary-language match")
    func regionSubtagStripped() {
        #expect(SidecarCharsetResolver.legacyFallback(forLanguage: "ru-RU") == .windowsCP1251)
    }

    @Test("windows-1252 and windows-1257 never disambiguate by decode success alone")
    func neverGuessesByDecodeSuccess() {
        // Every byte 0x00-0xFF is a valid single-byte code point under BOTH windows-1252 and
        // windows-1257 (they just map to different characters); a decode-success heuristic could
        // never tell them apart, which is exactly why resolution goes through the language hint
        // instead. Assert the fixed-precedence contract directly: with no content-type/BOM/UTF-8
        // signal, language ALONE decides, and both legacy encodings accept the same bytes.
        let bytes = Data([0xC0, 0xE9, 0x9F])
        #expect(String(data: bytes, encoding: .windowsCP1252) != nil)
        #expect(String(data: bytes, encoding: SidecarCharsetResolver.windowsCP1257) != nil)
        #expect(SidecarCharsetResolver.resolve(contentType: nil, bytes: bytes, language: "lv")
                == SidecarCharsetResolver.windowsCP1257)
        #expect(SidecarCharsetResolver.resolve(contentType: nil, bytes: bytes, language: "de")
                == .windowsCP1252)
    }

    @Test("line endings normalize to LF: CRLF and lone CR both fold")
    func lineEndingNormalization() {
        let normalized = SidecarCharsetResolver.normalizeLineEndings("a\r\nb\rc\nd")
        #expect(normalized == "a\nb\nc\nd")
    }
}
