import Testing
@testable import AetherEngine

@Suite("SubtitleRectText")
struct SubtitleRectTextTests {

    @Test("Plain text passes through")
    func plainText() {
        #expect(SubtitleRectText.cleanASSBody("Hello there") == "Hello there")
    }

    @Test("ASS hard line breaks become newlines, hard spaces become spaces")
    func lineBreaks() {
        #expect(SubtitleRectText.cleanASSBody("line one\\Nline two") == "line one\nline two")
        #expect(SubtitleRectText.cleanASSBody("a\\hb") == "a b")
    }

    @Test("Italic overrides are preserved as <i> tags")
    func italicPreserved() {
        #expect(SubtitleRectText.cleanASSBody("{\\i1}whispering{\\i0} loud") == "<i>whispering</i> loud")
    }

    @Test("Bold by flag and by weight both open <b>; b0 closes")
    func boldVariants() {
        #expect(SubtitleRectText.cleanASSBody("{\\b1}strong{\\b0}") == "<b>strong</b>")
        #expect(SubtitleRectText.cleanASSBody("{\\b700}strong{\\b0}") == "<b>strong</b>")
    }

    @Test("Underline overrides are preserved as <u> tags")
    func underlinePreserved() {
        #expect(SubtitleRectText.cleanASSBody("{\\u1}marked{\\u0}") == "<u>marked</u>")
    }

    @Test("Non-style overrides are stripped")
    func overridesStripped() {
        #expect(SubtitleRectText.cleanASSBody("{\\pos(960,540)}Centered") == "Centered")
        #expect(SubtitleRectText.cleanASSBody("{\\an8}{\\fad(250,250)}Top") == "Top")
        #expect(SubtitleRectText.cleanASSBody("{\\c&H00FFFF&}tinted") == "tinted")
    }

    @Test("Combined block keeps the style token, drops the rest")
    func combinedBlock() {
        #expect(SubtitleRectText.cleanASSBody("{\\i1\\pos(1,2)}note") == "<i>note")
    }

    @Test("Style reset closes all open tags")
    func resetClosesAll() {
        #expect(SubtitleRectText.cleanASSBody("{\\i1}soft{\\r} hard") == "<i>soft</i></b></u> hard")
    }

    @Test("A cue that is only overrides is no cue")
    func onlyOverridesIsNil() {
        #expect(SubtitleRectText.cleanASSBody("{\\fad(250,250)}") == nil)
        #expect(SubtitleRectText.cleanASSBody("{\\i1}{\\i0}") == nil)
        #expect(SubtitleRectText.cleanASSBody("   ") == nil)
    }
}
