import Foundation
import Libavcodec

/// Shared AVSubtitleRect → display-string extraction for the embedded and
/// sidecar subtitle decoders (the two previously carried diverging copies).
///
/// Inline italic/bold/underline ASS overrides are preserved as HTML-style
/// `<i>`/`<b>`/`<u>` tags — the only styling hosts render — so SRT cues like
/// "<i>off-screen voice</i>" (which FFmpeg converts to `{\i1}…{\i0}`) keep
/// their emphasis. Every other `{…}` override block (positioning, color,
/// karaoke, animation, vector drawing) is dropped.
enum SubtitleRectText {
    static func text(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            var line = String(cString: assPtr)
            if line.hasPrefix("Dialogue: ") {
                line.removeFirst("Dialogue: ".count)
            }
            // ASS dialogue layout: 9 comma-separated fields; the body
            // is the 9th and may contain commas.
            let parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            let raw = parts.count == 9 ? String(parts[8]) : line
            return cleanASSBody(raw)
        }
        return nil
    }

    /// ASS body → display text: `\N`/`\n` become newlines, `\h` a space,
    /// style overrides become tags (see type comment). Returns nil when
    /// nothing visible remains (a cue that was only override blocks).
    static func cleanASSBody(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = convertOverrideBlocks(in: s)
        let visible = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let blockRegex = try! NSRegularExpression(pattern: "\\{[^}]*\\}")
    /// `\i0`/`\i1`, `\b<weight>` (1 or 400/700), `\u0`/`\u1`, and `\r` (style reset).
    private static let styleTokenRegex = try! NSRegularExpression(pattern: "\\\\(i[01]|b[0-9]+|u[01]|r)")

    private static func convertOverrideBlocks(in s: String) -> String {
        let ns = s as NSString
        let matches = blockRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += tags(forBlock: ns.substring(with: m.range))
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func tags(forBlock block: String) -> String {
        let ns = block as NSString
        let tokens = styleTokenRegex.matches(in: block, range: NSRange(location: 0, length: ns.length))
        var out = ""
        for t in tokens {
            switch ns.substring(with: t.range(at: 1)) {
            case "i1": out += "<i>"
            case "i0": out += "</i>"
            case "u1": out += "<u>"
            case "u0": out += "</u>"
            // Reset closes everything; hosts ignore unmatched closes.
            case "r": out += "</i></b></u>"
            case "b0": out += "</b>"
            case let b where b.hasPrefix("b"): out += "<b>"
            default: break
            }
        }
        return out
    }
}
