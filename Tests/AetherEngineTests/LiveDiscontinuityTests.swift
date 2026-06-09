// Tests/AetherEngineTests/LiveDiscontinuityTests.swift
//
// Verifies the live PTS-discontinuity plumbing on the native HLS path:
// a segment flagged discontinuous makes `buildMediaPlaylistText` prefix
// EXACTLY that segment's #EXTINF with #EXT-X-DISCONTINUITY, and no other
// segment is tagged. This deterministically exercises items 1-2 of the
// discontinuity feature (producer flag -> provider segment list ->
// playlist builder) without depending on libavformat's mpegts streaming
// demuxer, which normalizes a synthetic PTS jump before the producer can
// observe it (see the feature's device-verify note).
import XCTest
@testable import AetherEngine

/// Minimal live provider exposing a hand-built segment list with a
/// discontinuity at a known index. Only the members the media-playlist
/// builder reads are meaningful; the rest take protocol defaults.
private final class MockLiveProvider: HLSSegmentProvider, @unchecked Sendable {
    let count: Int
    let discontinuousIndex: Int

    init(count: Int, discontinuousIndex: Int) {
        self.count = count
        self.discontinuousIndex = discontinuousIndex
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 5.0 }
    func segmentIsDiscontinuous(at index: Int) -> Bool { index == discontinuousIndex }
    var playlistType: HLSPlaylistType { .live }
    // A live playlist with no sliding (firstVisible stays 0) so every
    // segment is listed and the tag position is unambiguous.
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool) {
        (visibleCount: count, refreshCounter: 1, endlistAdded: false)
    }
}

final class LiveDiscontinuityTests: XCTestCase {

    func testDiscontinuityTagPrecedesOnlyTheBoundarySegment() {
        let provider = MockLiveProvider(count: 5, discontinuousIndex: 2)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Exactly one discontinuity tag.
        let tagCount = lines.filter { $0 == "#EXT-X-DISCONTINUITY" }.count
        XCTAssertEqual(tagCount, 1, "expected exactly one #EXT-X-DISCONTINUITY tag")

        // The tag must immediately precede seg2's #EXTINF, and seg2's URI
        // must follow that #EXTINF.
        guard let tagIdx = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") else {
            return XCTFail("no #EXT-X-DISCONTINUITY tag emitted")
        }
        XCTAssertTrue(lines[tagIdx + 1].hasPrefix("#EXTINF:"),
                      "tag must be immediately followed by an #EXTINF")
        XCTAssertEqual(lines[tagIdx + 2], "seg2.mp4",
                       "the tagged segment must be seg2 (the discontinuous index)")

        // No other segment carries the tag: seg0/seg1/seg3/seg4 EXTINFs are
        // not preceded by a discontinuity line.
        for i in [0, 1, 3, 4] {
            guard let uriIdx = lines.firstIndex(of: "seg\(i).mp4") else {
                return XCTFail("seg\(i).mp4 missing from playlist")
            }
            // uri is preceded by its EXTINF, which is preceded by either MAP
            // (seg0) or the prior segment's URI -- never a discontinuity.
            XCTAssertNotEqual(lines[uriIdx - 2], "#EXT-X-DISCONTINUITY",
                              "seg\(i) must not be flagged discontinuous")
        }
    }

    func testNoTagWhenNoDiscontinuity() {
        // discontinuousIndex out of range -> no segment is ever flagged.
        let provider = MockLiveProvider(count: 4, discontinuousIndex: -1)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        // Exact-line match: live playlists ALWAYS carry the
        // #EXT-X-DISCONTINUITY-SEQUENCE header (RFC 8216 6.2.2 bookkeeping
        // for tagged segments that slid out of the window), which a
        // substring check would falsely match as the per-segment tag.
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertFalse(lines.contains("#EXT-X-DISCONTINUITY"),
                       "a playlist with no discontinuous segment must not emit the tag")
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"),
                      "live playlists must carry the discontinuity-sequence header")
    }

    func testFirstSegmentDiscontinuityIsEmittedAfterMap() {
        // A discontinuity on seg0 is legal (a boundary at the very first
        // visible segment) and must still emit the tag, after #EXT-X-MAP.
        let provider = MockLiveProvider(count: 3, discontinuousIndex: 0)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let tagIdx = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") else {
            return XCTFail("no tag emitted for a seg0 discontinuity")
        }
        XCTAssertTrue(lines[tagIdx + 1].hasPrefix("#EXTINF:"))
        XCTAssertEqual(lines[tagIdx + 2], "seg0.mp4")
    }
}
