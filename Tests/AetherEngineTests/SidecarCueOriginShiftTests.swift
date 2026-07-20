import Foundation
import Testing
@testable import AetherEngine

/// Sidecar cues decode on the FILE's own zero-based clock; a non-zero-origin source (a disc
/// title's clip-0 STC base) reads `sourceTime` on a different axis, so a raw assignment would
/// offset every cue by a constant amount (audit finding #8). `AetherEngine.shiftCues` folds the
/// two axes together the same way `PresentationAxis.source(displayTime:origin:)` does for a
/// scalar seek target.
struct SidecarCueOriginShiftTests {
    private func cue(_ start: Double, _ end: Double) -> SubtitleCue {
        SubtitleCue(id: 0, startTime: start, endTime: end, body: .text("x"))
    }

    @Test("origin 0 is the identity (plain files, live, non-disc VOD)")
    func zeroOriginIsIdentity() {
        let cues = [cue(1, 2), cue(3, 4)]
        let shifted = AetherEngine.shiftCues(cues, bySourceOrigin: 0)
        #expect(shifted.map(\.startTime) == [1, 3])
        #expect(shifted.map(\.endTime) == [2, 4])
    }

    @Test("a non-zero origin shifts every cue's start and end onto the source-PTS axis")
    func nonZeroOriginShifts() {
        let cues = [cue(0, 1.5), cue(10, 12)]
        let shifted = AetherEngine.shiftCues(cues, bySourceOrigin: 599)
        #expect(shifted.map(\.startTime) == [599, 609])
        #expect(shifted.map(\.endTime) == [600.5, 611])
    }

    @Test("cue id and body survive the shift unchanged")
    func idAndBodyPreserved() {
        let original = SubtitleCue(id: 7, startTime: 1, endTime: 2, body: .text("hello"))
        let shifted = AetherEngine.shiftCues([original], bySourceOrigin: 100)
        #expect(shifted[0].id == 7)
        #expect(shifted[0].text == "hello")
    }
}
