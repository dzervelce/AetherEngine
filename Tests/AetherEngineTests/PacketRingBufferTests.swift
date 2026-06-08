// Tests/AetherEngineTests/PacketRingBufferTests.swift
import XCTest
@testable import AetherEngine

final class PacketRingBufferTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbtest-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func testAppendAndKeyframeSeek() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true,  isVideo: true, bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: false, isVideo: true, bytes: Data([1]))
        try ring.append(pts: 2, isKeyframe: true,  isVideo: true, bytes: Data([2]))
        try ring.append(pts: 3, isKeyframe: false, isVideo: true, bytes: Data([3]))
        XCTAssertEqual(try ring.keyframePts(atOrBefore: 3.5), 2)
        XCTAssertEqual(try ring.packets(fromPts: 2).map(\.pts), [2, 3])
    }
    func testEvictsOutsideWindow() throws {
        let ring = try PacketRingBuffer(windowSeconds: 5, scratch: tmpDir())
        for i in 0...20 { try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: Data([UInt8(i)])) }
        // edge 20, window 5 -> oldest retained must keep a keyframe at/below 15
        XCTAssertLessThanOrEqual(try XCTUnwrap(ring.oldestPts), 15)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ring.oldestPts), 13)
    }
    func testReplayBytesRoundTrip() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([9, 8, 7]))
        XCTAssertEqual(try ring.packets(fromPts: 0).first?.bytes, Data([9, 8, 7]))
    }

    /// The SW DVR reseed interleaves video + audio packets. Audio packets
    /// share `isKeyframe == false` with video non-keyframes, so the host
    /// routes replay by the recorded `isVideo` flag. Verify that flag, and
    /// the byte payloads, round-trip per packet so the reseed feeds each
    /// packet to the correct decoder in order.
    func testReseedRoutingPreservesStreamKindInOrder() throws {
        let ring = try PacketRingBuffer(windowSeconds: 30, scratch: tmpDir())
        // Interleave like a real demux: video keyframe, audio, video delta,
        // audio, video delta...
        try ring.append(pts: 10.0, isKeyframe: true,  isVideo: true,  bytes: Data([1]))
        try ring.append(pts: 10.0, isKeyframe: false, isVideo: false, bytes: Data([2]))
        try ring.append(pts: 10.1, isKeyframe: false, isVideo: true,  bytes: Data([3]))
        try ring.append(pts: 10.1, isKeyframe: false, isVideo: false, bytes: Data([4]))
        try ring.append(pts: 10.2, isKeyframe: false, isVideo: true,  bytes: Data([5]))

        // Reseed must anchor on the video keyframe at/before the target.
        let kf = try XCTUnwrap(try ring.keyframePts(atOrBefore: 10.15))
        XCTAssertEqual(kf, 10.0)

        let replay = try ring.packets(fromPts: kf)
        XCTAssertEqual(replay.count, 5)
        // Stream-kind flags preserved in append order.
        XCTAssertEqual(replay.map(\.isVideo), [true, false, true, false, true])
        XCTAssertEqual(replay.map(\.isKeyframe), [true, false, false, false, false])
        // Exactly one keyframe anchor (the reseed re-primes from it).
        XCTAssertEqual(replay.filter(\.isKeyframe).count, 1)
        XCTAssertTrue(replay.first?.isKeyframe == true && replay.first?.isVideo == true)
        // Byte payloads intact (one tag byte per packet, in order).
        XCTAssertEqual(replay.map { $0.bytes.first }, [1, 2, 3, 4, 5])
    }

    /// A target predating the retained window clamps to `oldestPts`, which
    /// the ring guarantees is a keyframe, so a reseed there still begins at
    /// a decodable access point.
    func testTargetBeforeWindowClampsToKeyframeOldest() throws {
        let ring = try PacketRingBuffer(windowSeconds: 5, scratch: tmpDir())
        for i in 0...20 { try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: Data([UInt8(i)])) }
        let oldest = try XCTUnwrap(ring.oldestPts)
        // No keyframe exists at/before a target far below the window.
        XCTAssertNil(try ring.keyframePts(atOrBefore: -100))
        // ... so the host clamps to oldestPts, which is itself a keyframe.
        let firstAtOldest = try XCTUnwrap(try ring.packets(fromPts: oldest).first)
        XCTAssertTrue(firstAtOldest.isKeyframe)
    }
}
