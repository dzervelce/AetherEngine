import Foundation
import CoreFoundation

/// Resolves the text encoding of a sidecar subtitle file (.srt/.ass/.vtt/.ssa) so
/// `SubtitleDecoder` can transcode it to UTF-8 before handing it to libavformat, which has no
/// charset-detection of its own and otherwise mojibakes anything outside ASCII. Legacy single-byte
/// subtitle files (Baltic/Cyrillic/Central-European code pages are common on OpenSubtitles-style
/// addons) carry no self-describing marker, so byte content alone cannot disambiguate them - e.g.
/// every byte sequence valid as windows-1252 is ALSO a valid (different) windows-1257 string, so
/// resolution NEVER tries decoding under a legacy candidate to see if it "succeeds"; it follows a
/// fixed precedence and, for the final tier, a language hint.
enum SidecarCharsetResolver {

    /// Resolution order: an explicit server-declared charset wins outright, then a byte-order
    /// mark, then a strict UTF-8 validity check, then a language-informed legacy guess.
    static func resolve(contentType: String?, bytes: Data, language: String?) -> String.Encoding {
        if let contentType, let name = charsetName(fromContentType: contentType),
           let declared = encoding(forCharsetName: name) {
            return declared
        }
        if let bom = detectBOM(bytes) {
            return bom.encoding
        }
        if isStrictUTF8(bytes) {
            return .utf8
        }
        return legacyFallback(forLanguage: language)
    }

    /// Decode `bytes` as `encoding`, stripping a byte-order mark that matches it. Foundation does
    /// not strip a UTF-8 BOM on decode (it survives as a leading U+FEFF), and an explicit-endian
    /// UTF-16/32 encoding does not auto-detect/strip a BOM the way the endian-less `.utf16`/`.utf32`
    /// do, so every path is stripped explicitly here rather than relying on encoding-specific
    /// behavior.
    static func decode(_ bytes: Data, as encoding: String.Encoding) -> String? {
        String(data: stripBOM(bytes, for: encoding), encoding: encoding)
    }

    /// CRLF -> LF, then any remaining lone CR (old Mac line endings) -> LF, so every downstream
    /// subtitle parser (SRT/ASS/VTT, all LF-oriented) sees one consistent line ending regardless of
    /// how the source file was authored/exported.
    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Content-Type charset

    /// Extracts the `charset=` parameter from an HTTP `Content-Type` header value
    /// ("text/plain; charset=windows-1251" -> "windows-1251"), tolerant of quotes and spacing.
    static func charsetName(fromContentType contentType: String) -> String? {
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("charset=") else { continue }
            let value = trimmed.dropFirst("charset=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Resolves an IANA/HTTP charset name ("windows-1251", "UTF-8", "iso-8859-2", ...) to a
    /// Foundation encoding via CoreFoundation's charset table. nil when unrecognized.
    static func encoding(forCharsetName name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: - BOM

    struct BOMMatch {
        let encoding: String.Encoding
        let length: Int
    }

    /// Detects a leading byte-order mark. UTF-32 markers are checked before UTF-16 (both share a
    /// `FF FE` / `00 00 FE FF` prefix relationship) so a 4-byte UTF-32 BOM is never misread as
    /// UTF-16 followed by two NUL data bytes.
    static func detectBOM(_ data: Data) -> BOMMatch? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0x00, b[3] == 0x00 {
            return BOMMatch(encoding: .utf32LittleEndian, length: 4)
        }
        if b.count >= 4, b[0] == 0x00, b[1] == 0x00, b[2] == 0xFE, b[3] == 0xFF {
            return BOMMatch(encoding: .utf32BigEndian, length: 4)
        }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return BOMMatch(encoding: .utf8, length: 3)
        }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE {
            return BOMMatch(encoding: .utf16LittleEndian, length: 2)
        }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            return BOMMatch(encoding: .utf16BigEndian, length: 2)
        }
        return nil
    }

    private static func stripBOM(_ data: Data, for encoding: String.Encoding) -> Data {
        guard let bom = detectBOM(data), bom.encoding == encoding else { return data }
        return data.dropFirst(bom.length)
    }

    // MARK: - Strict UTF-8 validation

    /// True only when every byte sequence is well-formed UTF-8 (Foundation's UTF-8 decode rejects
    /// overlong encodings and invalid continuation bytes, unlike a byte-count heuristic). NEVER used
    /// to accept/reject a legacy code page by decode "success" - see the type doc.
    static func isStrictUTF8(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }

    // MARK: - Legacy fallback

    /// windows-1257 (Baltic Rim, code page 1257) has no dedicated `String.Encoding` case; resolved
    /// via the `CFStringEncodings` constant directly rather than the IANA name table so it never
    /// depends on that table recognizing the string "windows-1257" on every platform.
    static let windowsCP1257: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.windowsBalticRim.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    /// Last-resort guess when no charset was declared, no BOM is present, and the bytes are not
    /// valid UTF-8: the language a host or track registration already knows about the subtitle
    /// picks the legacy single-byte code page most likely to have produced it. Falls through to
    /// windows-1252 (Western Europe) for every language not in a narrower group, matching what most
    /// non-UTF-8 subtitle authoring tools default to.
    static func legacyFallback(forLanguage language: String?) -> String.Encoding {
        let primary = language?.split(separator: "-").first.map { $0.lowercased() }
        switch primary {
        case "lv", "lt", "et":
            return windowsCP1257
        case "ru", "uk", "bg":
            return .windowsCP1251
        case "pl", "cs", "sk", "hu", "hr", "sl", "ro":
            return .windowsCP1250
        default:
            return .windowsCP1252
        }
    }
}
