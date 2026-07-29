import Foundation
import Testing
@testable import AetherEngine

struct SubtitlePacketStoreTests {
    private func pkt(_ pts: Double, dur: Double = 2, size: Int = 8) -> (Double, Double, Data) {
        (pts, dur, Data(repeating: 0xAB, count: size))
    }

    @Test("entries returns the inclusive pts window in ascending order")
    func windowQuery() {
        let store = SubtitlePacketStore()
        for p in [30.0, 10.0, 20.0] {
            let (pts, dur, data) = pkt(p)
            store.append(streamIndex: 3, ptsSeconds: pts, durationSeconds: dur, payload: data)
        }
        let got = store.entries(streamIndex: 3, from: 10, through: 20).map(\.ptsSeconds)
        #expect(got == [10, 20])
    }

    /// A restart re-reads the same source bytes, so the overlap it produces is byte-identical:
    /// that, not the bare timestamp match, is what identifies a duplicate. Distinct payloads on
    /// one PTS are distinct cues and are all retained (#235, Issue235SamePTSRetentionTests).
    @Test("a byte-identical re-harvest replaces its entry (producer restart overlap)")
    func dedupOnRestartOverlap() {
        let store = SubtitlePacketStore()
        let packet = Data([1, 2, 3, 4])
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: packet)
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: packet)
        let got = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(got.count == 1)
        #expect(got[0].payload == packet)
    }

    @Test("distinct same-pts packets both survive (#4: not a restart-overlap replay)")
    func distinctSamePtsBothSurvive() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: Data([1]))
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: Data([2, 2]))
        let got = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(got.count == 2)
        #expect(got.map(\.payload) == [Data([1]), Data([2, 2])])
        #expect(Set(got.map(\.sequence)).count == 2)
    }

    @Test("prune drops entries strictly before the cutoff")
    func pruneTrailing() {
        let store = SubtitlePacketStore()
        for p in [10.0, 320.0] {
            let (pts, dur, data) = pkt(p)
            store.append(streamIndex: 0, ptsSeconds: pts, durationSeconds: dur, payload: data)
        }
        store.prune(before: 20)
        #expect(store.entries(streamIndex: 0, from: 0, through: 1_000).map(\.ptsSeconds) == [320])
    }

    @Test("per-stream byte cap evicts oldest entries first")
    func capEvictsOldestFirst() {
        let store = SubtitlePacketStore()
        let big = SubtitlePacketStore.perStreamByteCap / 3
        for p in [10.0, 20.0, 30.0, 40.0] {
            store.append(streamIndex: 1, ptsSeconds: p, durationSeconds: 2,
                         payload: Data(repeating: 0, count: big))
        }
        let remaining = store.entries(streamIndex: 1, from: 0, through: 1_000).map(\.ptsSeconds)
        #expect(remaining.first != 10)
        #expect(remaining.contains(40))
    }

    @Test("frontier reports the largest stored pts per stream")
    func frontierPerStream() {
        let store = SubtitlePacketStore()
        let (pts, dur, data) = pkt(55)
        store.append(streamIndex: 2, ptsSeconds: pts, durationSeconds: dur, payload: data)
        #expect(store.frontier(streamIndex: 2) == 55)
        #expect(store.frontier(streamIndex: 9) == nil)
    }

    @Test("clear empties every stream")
    func clearAll() {
        let store = SubtitlePacketStore()
        let (pts, dur, data) = pkt(5)
        store.append(streamIndex: 0, ptsSeconds: pts, durationSeconds: dur, payload: data)
        store.clear()
        #expect(store.entries(streamIndex: 0, from: 0, through: 100).isEmpty)
    }

    // MARK: - Session-wide budget (#6)

    @Test("isBitmapStream reflects markBitmapStreams")
    func bitmapClassification() {
        let store = SubtitlePacketStore()
        store.markBitmapStreams([2, 4])
        #expect(store.isBitmapStream(2))
        #expect(store.isBitmapStream(4))
        #expect(!store.isBitmapStream(3))
    }

    // MARK: - Backscan anchors (#9)

    @Test("nearestEntryPts finds the closest preceding packet regardless of distance")
    func nearestEntryPtsUnbounded() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 4, ptsSeconds: 10, durationSeconds: 2, payload: Data([1]))
        store.append(streamIndex: 4, ptsSeconds: 500, durationSeconds: 2, payload: Data([2]))
        #expect(store.nearestEntryPts(streamIndex: 4, atOrBefore: 600) == 500)
        #expect(store.nearestEntryPts(streamIndex: 4, atOrBefore: 50) == 10)
        #expect(store.nearestEntryPts(streamIndex: 4, atOrBefore: 5) == nil)
    }

    private func pcsPayload(compositionState: UInt8) -> Data {
        var body = [UInt8](repeating: 0, count: 11)
        body[7] = compositionState   // offset 7 of the PCS body: 0x00 Normal, 0x40 Acquisition Point, 0x80 Epoch Start
        var d = Data([0x16, 0x00, 0x0B])   // type=PCS, length=11
        d.append(contentsOf: body)
        return d
    }

    @Test("nearestPGSAnchorPts finds the nearest self-contained composition within the fallback window")
    func nearestPGSAnchor() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 5, ptsSeconds: 10, durationSeconds: 1,
                     payload: pcsPayload(compositionState: 0x40))   // acquisition point
        store.append(streamIndex: 5, ptsSeconds: 40, durationSeconds: 1,
                     payload: pcsPayload(compositionState: 0x00))   // normal delta
        store.append(streamIndex: 5, ptsSeconds: 70, durationSeconds: 1,
                     payload: pcsPayload(compositionState: 0x00))   // normal delta
        // The deltas at 40/70 are not self-contained; the acquisition point at 10 is the nearest anchor.
        #expect(store.nearestPGSAnchorPts(streamIndex: 5, atOrBefore: 75, fallbackWindow: 90) == 10)
        // Outside the fallback window from a far-future playhead, no anchor is found.
        #expect(store.nearestPGSAnchorPts(streamIndex: 5, atOrBefore: 200, fallbackWindow: 90) == nil)
    }
}
