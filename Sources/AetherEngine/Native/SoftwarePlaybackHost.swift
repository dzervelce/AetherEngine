import Foundation
import AVFoundation
import CoreMedia
import Combine
import Libavformat
import Libavcodec
import Libavutil

/// Software-decode playback host. Parallel to `NativeAVPlayerHost` but
/// drives decode + render through the engine's own FFmpeg/dav1d
/// pipeline instead of handing the source to AVPlayer. Used for codecs
/// AVPlayer cannot decode on the active platform — primarily AV1 on
/// Apple TV today, where Apple ships dav1d on iOS / macOS but not on
/// tvOS, and no Apple TV chip has HW AV1.
///
/// The pipeline:
///
/// ```
/// Demuxer ─┬─ video pkt ──► SoftwareVideoDecoder ──► SampleBufferRenderer ──► AVSampleBufferDisplayLayer
///          │                                                                     │
///          └─ audio pkt ──► AudioDecoder ──► CMSampleBuffer ──► AudioOutput ─────┘
///                                                                  (AVSampleBufferRenderSynchronizer
///                                                                   is the master clock; display layer
///                                                                   is attached to it for A/V sync)
/// ```
///
/// AV1 sources in the wild almost never carry Atmos or Dolby Vision
/// (DV is HEVC-profile-driven; Atmos mastering runs in HEVC), so this
/// host intentionally skips the EAC3+JOC fMP4 pipe + DV HDMI handshake
/// that the native path provides. If those gaps ever bite an AV1+DV or
/// AV1+Atmos source, route handling lives in `AetherEngine.load` and
/// can be revisited there without changing this host.
@MainActor
final class SoftwarePlaybackHost {

    // MARK: - Published state (mirrors NativeAVPlayerHost surface)

    /// Frames successfully enqueued into the AVSampleBufferDisplayLayer.
    /// Incremented each time `renderer.enqueue` is invoked. Read by the
    /// engine's LiveTelemetrySampler at 1 Hz to compute observed FPS on
    /// the software path. Atomic read via the existing class-internal
    /// serialisation; the counter is single-writer (the decode pump) and
    /// any reader sees a torn `Int` only on 32-bit platforms (tvOS is
    /// 64-bit, so reads are atomic by ABI).
    private(set) var framesEnqueued: Int = 0

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    @Published private(set) var didReachEnd: Bool = false

    /// Fires (off-main) once per session the first time HDR10+ dynamic
    /// metadata appears on a decoded frame. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    nonisolated(unsafe) var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    // MARK: - Output

    /// The display layer the engine attaches to the bound `AetherPlayerView`.
    /// Owned by `SampleBufferRenderer`; surfaced here so the engine can
    /// hand it to the view via the same `attach(_ layer: CALayer)` entry
    /// point it uses for `AVPlayerLayer`.
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }

    // MARK: - Internals

    private let renderer: SampleBufferRenderer
    /// Video decoder. Swapped per codec at `load()` time:
    /// `SoftwareVideoDecoder` for AV1 / VP9 (libavcodec / dav1d), and
    /// `HardwareVideoDecoder` for HEVC (VTDecompressionSession HW).
    /// The protocol is `VideoDecodingPipeline` so the demux loop
    /// stays codec-agnostic.
    private var videoDecoder: any VideoDecodingPipeline
    private var audioDecoder: AudioDecoder?
    private var audioOutput: AudioOutput?
    private var demuxer: Demuxer?

    /// Background queue the demux loop runs on. One queue per host so
    /// hosts created across rapid load() calls don't fight over the
    /// same execution context.
    private let demuxQueue = DispatchQueue(label: "engine.sw.demux", qos: .userInitiated)

    /// Lock guarding the playing / stop flags. Read on the demux thread
    /// every iteration, written on the main actor from play/pause/stop.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying: Bool = false
    nonisolated(unsafe) private var _stopRequested: Bool = false

    /// Condition the demux thread waits on while paused so it doesn't
    /// busy-loop reading packets that would just stack up.
    private let demuxCondition = NSCondition()

    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1

    /// Video stream time base (seconds per PTS unit) captured at load.
    /// Used both to convert raw packet PTS to seconds for the DVR ring
    /// and, on the replay path, to convert ring seconds back into the
    /// time_base units the decoders expect on a reconstructed AVPacket.
    private var videoTimeBaseSeconds: Double = 0
    /// Audio stream time base (seconds per PTS unit), same role as the
    /// video one for replayed audio packets. 0 when there is no audio.
    private var audioTimeBaseSeconds: Double = 0

    // MARK: - Live / DVR

    /// Disk-spooled packet ring backing the software-path DVR rewind
    /// buffer. Non-nil only for a live session loaded with a DVR window
    /// (`dvrWindowSeconds != nil`). Appended on the demux thread (the
    /// ring is internally locked), read on the seek path. Closed + niled
    /// in `stop()`.
    nonisolated(unsafe) private var dvrRing: PacketRingBuffer?

    /// True for a live session. Gates ring fill, edge publishing, and the
    /// live-DVR seek branch so the non-live SW path is untouched.
    private var isLive: Bool = false

    /// Session-start PTS in seconds (the first packet's PTS, video or
    /// audio, whichever arrives first). The SW session timeline (and the
    /// engine's `currentTime` on this path) is "seconds since first
    /// frame", so the session-relative edge is `newestPts - sessionStartPts`.
    /// `nan` until the first packet is seen.
    nonisolated(unsafe) private var sessionStartPts: Double = .nan

    /// Newest source PTS (seconds) demuxed so far, tracked on the demux
    /// thread. The live edge in session time is `newestSourcePts - sessionStartPts`.
    nonisolated(unsafe) private var newestSourcePts: Double = .nan

    /// Guards `sessionStartPts` / `newestSourcePts` against the demux
    /// thread writing while the main-actor time tick reads them.
    private let liveEdgeLock = NSLock()

    /// Invoked on the main-actor time-update cadence with the current
    /// session-relative live edge (seconds since first frame) while live.
    /// Wired by the engine to `publishLiveWindow(edgeSessionTime:)`.
    var onLiveEdge: (@MainActor (Double) -> Void)?

    /// Session-relative live edge in seconds, or nil before the first
    /// packet. Read on the main actor by the time tick.
    private var liveEdgeSessionTime: Double? {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return nil }
        return max(0, newestSourcePts - sessionStartPts)
    }

    /// Periodic mirror of `audioOutput.currentTimeSeconds` into the
    /// published `currentTime`. 250 ms is the same cadence the pre-
    /// collapse engine used; granular enough for transport-bar UX,
    /// cheap enough to ignore.
    private var timeTimer: AnyCancellable?

    /// Caching the chosen rate so resume() restores the right speed
    /// after a pause without the host needing to know its history.
    private var lastRate: Float = 1.0

    /// Source-position seconds the host opened at, captured so the
    /// demux loop can align the synchronizer's master clock to the
    /// first decoded sample's PTS. Cold-start at 0 is fine because
    /// the source's first packet PTS is also ~0; resume / audio-switch
    /// reload with a non-zero startPosition would otherwise leave the
    /// clock at .zero while samples arrive with PTS=startPosition,
    /// causing the synchronizer to wait `startPosition` seconds
    /// before rendering — visible as "frozen frame, no audio".
    private var initialClockTime: CMTime = .zero

    nonisolated var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock(); _isPlaying = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    nonisolated var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock(); _stopRequested = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    // MARK: - Init

    init() {
        self.renderer = SampleBufferRenderer()
        // Default to the software decoder; load() swaps it for the
        // VT-backed one when the source's video codec is HEVC.
        self.videoDecoder = SoftwareVideoDecoder()
    }

    // MARK: - Load

    func load(
        demuxer dem: Demuxer,
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil
    ) async throws {
        self.demuxer = dem
        self.duration = dem.duration
        self.isLive = isLive

        guard dem.videoStreamIndex >= 0,
              let vStream = dem.stream(at: dem.videoStreamIndex) else {
            throw HostError.noVideoStream
        }
        self.videoStreamIndex = dem.videoStreamIndex
        let vtb = vStream.pointee.time_base
        self.videoTimeBaseSeconds = vtb.den > 0 ? Double(vtb.num) / Double(vtb.den) : 0

        // Build the DVR rewind ring for a live session that opted into a
        // window. Live-only (no window) keeps unbounded forward playback
        // with no rewind buffer. Scratch dir mirrors SegmentCache's
        // <tmpdir>/aether-segments/<uuid> convention so stale-dir cleanup
        // and disk accounting stay uniform.
        if isLive, let window = dvrWindowSeconds {
            let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("aether-segments", isDirectory: true)
            let scratch = baseDir.appendingPathComponent("dvr-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                self.dvrRing = try PacketRingBuffer(windowSeconds: window, scratch: scratch)
                EngineLog.emit("[SWHost] DVR ring armed window=\(String(format: "%.0f", window))s scratch=\(scratch.lastPathComponent)", category: .swPlayback)
            } catch {
                EngineLog.emit("[SWHost] DVR ring create failed (\(error)); live-only fallback", category: .swPlayback)
                self.dvrRing = nil
            }
        }

        // Release-visible session-start log so the diagnostic overlay
        // shows the SW path was entered at all. Without this, a SW-path
        // session that black-screens looks identical in logs to a session
        // that never dispatched here (DrHurt #4 MPEG-4 "not much on log").
        let vCodecID = vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0
        let aIdx = audioSourceStreamIndex ?? dem.audioStreamIndex
        let aCodecID: UInt32 = aIdx >= 0
            ? (dem.stream(at: aIdx)?.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)
            : 0
        EngineLog.emit(
            "[SWHost] session start: videoCodecID=\(vCodecID) "
            + "audioCodecID=\(aCodecID == 0 ? "none" : String(aCodecID)) "
            + "duration=\(String(format: "%.1f", dem.duration))s",
            category: .swPlayback
        )

        // Pick the right decoder for the source codec. HEVC routes
        // to VTDecompressionSession (HW); AV1 / VP9 / anything else
        // stays on libavcodec via SoftwareVideoDecoder. The current
        // instance is replaced wholesale so the previous decoder's
        // state cannot bleed into the new session.
        if let codecpar = vStream.pointee.codecpar,
           codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
            videoDecoder.close()
            videoDecoder = HardwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected HardwareVideoDecoder (VT HEVC) for codec_id=\(codecpar.pointee.codec_id.rawValue)",
                category: .swPlayback
            )
        } else if !(videoDecoder is SoftwareVideoDecoder) {
            // Restoring the software default if a previous load left
            // a HW decoder in place and this load isn't HEVC.
            videoDecoder.close()
            videoDecoder = SoftwareVideoDecoder()
        }

        // Detect HDR transfer characteristic from the source codecpar
        // and flip the display layer into HDR mode before any frames
        // arrive. Without this `displayLayer.preferredDynamicRange`
        // stays at `.standard` and AVSampleBufferDisplayLayer renders
        // PQ / HLG content desaturated. Matches what AVPlayer's
        // internal pipeline does implicitly via AVAsset metadata.
        if let codecpar = vStream.pointee.codecpar {
            let trc = codecpar.pointee.color_trc
            let sourceIsHDR = trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
            if sourceIsHDR {
                renderer.setHDROutput(true)
                EngineLog.emit(
                    "[SWHost] HDR mode ON on display layer (transfer=\(trc.rawValue))",
                    category: .swPlayback
                )
            }
        }

        try videoDecoder.open(stream: vStream) { [weak self] pixelBuffer, pts, hdr10PlusData in
            // Decoder callback fires on the demux thread. SampleBufferRenderer
            // is internally locked + safe to call off-main; the engine's
            // public state stays untouched here, only the layer's frame queue.
            self?.renderer.enqueue(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData)
            // Release-visible first-frame-enqueued log. After [SWDecoder]
            // Opened and [SWHost] session start, this is the next milestone:
            // proves the demux loop reached a video packet, the decoder
            // produced a pixel buffer, and the renderer accepted the
            // enqueue. If this never fires after several seconds, the
            // failure is between decoder-open and first-frame.
            if self?.framesEnqueued == 0 {
                let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                EngineLog.emit(
                    "[SWHost] first video frame enqueued: "
                    + "pixfmt=0x\(String(pfType, radix: 16)) "
                    + "size=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) "
                    + "pts=\(String(format: "%.3f", pts.seconds))s",
                    category: .swPlayback
                )
            }
            self?.framesEnqueued &+= 1
        }
        videoDecoder.onFirstHDR10PlusDetected = { [weak self] in
            self?.onFirstHDR10PlusDetected?()
        }

        let resolvedAudioIdx: Int32 = audioSourceStreamIndex ?? dem.audioStreamIndex
        if resolvedAudioIdx >= 0, let aStream = dem.stream(at: resolvedAudioIdx) {
            let aDec = AudioDecoder()
            do {
                try aDec.open(stream: aStream)
                self.audioDecoder = aDec
                self.audioStreamIndex = resolvedAudioIdx
                let atb = aStream.pointee.time_base
                self.audioTimeBaseSeconds = atb.den > 0 ? Double(atb.num) / Double(atb.den) : 0

                // AudioOutput is created here but the display layer is
                // NOT yet attached to its synchronizer — that happens in
                // play() after the engine has hung the layer in the
                // bound view's CALayer hierarchy. Attaching a free-
                // floating layer to the synchronizer has been observed
                // to fail with `FigVideoQueueRemote err=-12080` after
                // the first enqueue on tvOS 26+.
                self.audioOutput = AudioOutput()
            } catch {
                EngineLog.emit("[SWHost] audio open failed (\(error)); video-only", category: .swPlayback)
                self.audioStreamIndex = -1
            }
        }

        if let start = startPosition, start > 0 {
            dem.seek(to: start)
            // Mirror the same skip-PTS + clock-alignment dance the
            // seek() path performs, so the demux loop drops pre-
            // keyframe frames and the synchronizer starts ticking at
            // the resume offset (not at .zero) once the first audio
            // sample arrives.
            let startTime = CMTime(seconds: start, preferredTimescale: 90000)
            videoDecoder.skipUntilPTS = startTime
            renderer.setSkipThreshold(startTime)
            initialClockTime = startTime
            currentTime = start
        } else {
            initialClockTime = .zero
        }

        startTimeUpdates()
        isReady = true
        // Demux loop only spins up once play() actually fires; no point
        // pulling packets while the synchronizer hasn't claimed the
        // layer yet.
    }

    // MARK: - Transport

    func play() {
        // First play() since load(): claim the display layer for the
        // synchronizer (now that the engine has hung it in the bound
        // view's CALayer hierarchy via presentCurrentLayer) and kick
        // off the demux loop. Idempotent across repeated play() calls;
        // the layer-attach + loop-spin-up only fire on the first one.
        if !demuxLoopStarted, let aOut = audioOutput {
            aOut.attachVideoLayer(renderer.displayLayer)
        }
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }

        // Don't eager-start the audio synchronizer. The pre-collapse
        // pattern was: start(at:) fires only on the first decoded audio
        // sample, so the master clock's time-zero aligns with the
        // sample's PTS. Eager-starting here with an empty renderer queue
        // means the clock ticks forward through the demux loop's spin-up
        // and the first sample lands "in the past" — dropped, with a
        // visible initial flicker or audio gap. The demux loop calls
        // `audioOutput.start(at: .zero)` itself on first enqueue;
        // `start()` is idempotent so the duplicate call from `seek()`'s
        // resume path is a no-op.
        rate = lastRate
        isPlaying = true
    }

    /// Latched once the first `play()` has wired the audio synchronizer
    /// to the display layer and spun up the demux loop. Subsequent
    /// `play()` calls only flip `isPlaying` without re-attaching.
    private var demuxLoopStarted: Bool = false

    func pause() {
        audioOutput?.pause()
        rate = 0
        isPlaying = false
    }

    func setRate(_ newRate: Float) {
        lastRate = newRate
        audioOutput?.setRate(newRate)
        rate = newRate
    }

    func seek(to seconds: Double) async {
        guard let dem = demuxer else { return }
        // Pause the demux loop so we don't race the seek against
        // in-flight packet reads.
        let wasPlaying = isPlaying
        isPlaying = false

        videoDecoder.flush()
        audioDecoder?.flush()
        renderer.flush()
        audioOutput?.flush()

        // Live + DVR rewind: a live source CANNOT be demuxer-seeked (it
        // is a forward-only stream). Instead we reseed the decoder from
        // the retained ring. The demux loop, once resumed, keeps reading
        // NEW packets forward from where the live source already sits
        // (its read position is untouched), so playback shows the
        // buffered past from the seek target and then catches back up to
        // live as the loop continues appending + decoding fresh packets.
        if isLive, let ring = dvrRing {
            await seekLiveDVR(to: seconds, ring: ring, wasPlaying: wasPlaying)
            return
        }

        dem.seek(to: seconds)

        // Drop frames before the seek target until a keyframe lines up.
        // SoftwareVideoDecoder honors `skipUntilPTS` internally per
        // pre-collapse contract.
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        currentTime = seconds

        if wasPlaying {
            // Jump the synchronizer's master clock to the seek target so
            // PTS-stamped samples decoded after the seek align with the
            // clock. Calling `start(at: .zero)` here would wedge the
            // queue: samples come back with PTS=seekTarget but the clock
            // is at 0, so the synchronizer waits seekTarget seconds
            // before rendering — visible as "frozen frame, no audio"
            // until the wait elapses, plus the renderer's queue fills
            // up and trips err=-12080 from FigVideoQueueRemote.
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
            isPlaying = true
        }
    }

    /// Live DVR rewind: reseed the decoder pipeline from the retained
    /// ring without touching the live demuxer's read position.
    ///
    /// `targetSession` is session-relative seconds (the engine clock).
    /// The ring + audio synchronizer + sample PTS all live on the source
    /// PTS axis, so we map via the captured `sessionStartPts`. After this
    /// returns and the loop resumes, the demux loop keeps reading NEW
    /// packets forward from the live source, so the buffered past plays
    /// out from the target and then catches back up to live.
    private func seekLiveDVR(to targetSession: Double, ring: PacketRingBuffer, wasPlaying: Bool) async {
        // Map session time to source PTS. sessionStartPts is set by the
        // demux loop on the first packet; if it has not been seen yet
        // (extremely early seek), treat session == source.
        let startPts: Double = {
            liveEdgeLock.lock(); defer { liveEdgeLock.unlock() }
            return sessionStartPts.isFinite ? sessionStartPts : 0
        }()
        let targetSource = startPts + targetSession

        // Anchor the reseed at the newest keyframe at or before the
        // target. If the target predates the retained window, clamp to
        // the oldest retained pts (which the ring guarantees is a
        // keyframe). If the ring is empty, there is nothing to replay;
        // fall back to just re-priming the skip threshold at the target.
        let kf: Double
        if let k = try? ring.keyframePts(atOrBefore: targetSource) {
            kf = k
        } else if let oldest = ring.oldestPts {
            kf = oldest
        } else {
            // Empty ring: no buffered past. Pin the clock at the target
            // and resume forward; nothing to replay.
            let t = CMTime(seconds: targetSource, preferredTimescale: 90000)
            videoDecoder.skipUntilPTS = t
            renderer.setSkipThreshold(t)
            currentTime = targetSession
            if wasPlaying {
                audioOutput?.seekClock(to: t, rate: lastRate)
                isPlaying = true
            }
            return
        }

        // Skip threshold (in source PTS) drops replayed frames before the
        // requested target so the playhead lands exactly at `targetSource`
        // even though replay begins at the earlier keyframe. Set BEFORE
        // replaying so the decoder honors it on the first decoded frame.
        let targetTime = CMTime(seconds: targetSource, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        // Anchor the master clock at the target so the post-skip samples
        // (which carry source PTS >= targetSource) align with the clock.
        if wasPlaying {
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
        }

        // Replay the retained tail from the keyframe through the same
        // decode entry points the demux loop uses, reconstructing an
        // AVPacket per stored packet. Pre-target frames are dropped by the
        // skip threshold; from `targetSource` on, frames render.
        let replay = (try? ring.packets(fromPts: kf)) ?? []
        let videoCount = replay.filter(\.isVideo).count
        EngineLog.emit("[SWHost] DVR rewind: targetSession=\(String(format: "%.2f", targetSession)) targetSource=\(String(format: "%.2f", targetSource)) kf=\(String(format: "%.2f", kf)) replay=\(replay.count) pkts (\(videoCount) video)", category: .swPlayback)
        for pkt in replay {
            feedReplay(pkt)
        }

        currentTime = targetSession
        if wasPlaying {
            // Resume the loop. It continues forward reads from the live
            // source (read position untouched), appending + decoding new
            // packets, so playback catches up from the buffered past.
            isPlaying = true
        }
    }

    /// Reconstruct an AVPacket from a ring packet and route it to the
    /// same decode entry the live demux loop uses (video -> the video
    /// decoder, audio -> the audio decoder + audio output). PTS is
    /// converted from ring seconds back into the owning stream's
    /// time_base units so the decoders recover the identical source PTS
    /// on the replayed sample. The ring records `isVideo` per entry so
    /// the route is unambiguous (a video non-keyframe and an audio packet
    /// both carry `isKeyframe == false`).
    private func feedReplay(_ pkt: PacketRingBuffer.Packet) {
        let tbSec = pkt.isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
        guard tbSec > 0, !pkt.bytes.isEmpty else { return }

        guard var avPkt: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc(),
              let p = avPkt else { return }
        defer { trackedPacketFree(&avPkt) }

        // Allocate a ref-counted buffer and copy the stored bytes in, so
        // the decoder owns a normal AVBufferRef-backed packet just like
        // one from av_read_frame.
        if av_new_packet(p, Int32(pkt.bytes.count)) < 0 { return }
        pkt.bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = p.pointee.data {
                memcpy(dst, base, pkt.bytes.count)
            }
        }
        p.pointee.pts = Int64((pkt.pts / tbSec).rounded())
        p.pointee.dts = p.pointee.pts
        p.pointee.flags = pkt.isKeyframe ? AV_PKT_FLAG_KEY : 0
        p.pointee.stream_index = pkt.isVideo ? videoStreamIndex : audioStreamIndex

        if pkt.isVideo {
            videoDecoder.decode(packet: p)
        } else if let aDec = audioDecoder, let aOut = audioOutput {
            for buf in aDec.decode(packet: p) {
                aOut.enqueue(sampleBuffer: buf)
            }
        }
    }

    func stop() {
        stopRequested = true
        isPlaying = false
        timeTimer?.cancel()
        timeTimer = nil

        dvrRing?.close()
        dvrRing = nil
        liveEdgeLock.lock()
        sessionStartPts = .nan
        newestSourcePts = .nan
        liveEdgeLock.unlock()

        if let aOut = audioOutput {
            aOut.stop()
            aOut.detachVideoLayer(renderer.displayLayer)
        }
        audioOutput = nil
        audioDecoder?.close()
        audioDecoder = nil
        videoDecoder.close()
        renderer.flush()
        demuxer?.close()
        demuxer = nil

        isReady = false
    }

    var volume: Float {
        get { audioOutput?.volume ?? 1.0 }
        set { audioOutput?.volume = newValue }
    }

    // MARK: - Demux loop

    /// Captures the dependencies the demux loop needs as locals so the
    /// loop runs fully off the main actor without re-entering it on
    /// every packet. All captured types are `@unchecked Sendable` with
    /// internal locks, so off-main use is safe.
    private func startDemuxLoop() {
        guard let dem = demuxer else { return }
        // `AVSampleBufferDisplayLayer` isn't Sendable in Apple's
        // headers, but we only read `isReadyForMoreMediaData` off-main
        // (which is documented as thread-safe by AVFoundation).
        // Wrapping in `UncheckedSendable` quiets the closure-capture
        // diagnostic without forcing the loop back to the main actor.
        let layer = UncheckedSendable(renderer.displayLayer)
        let vDec = videoDecoder
        let vIdx = videoStreamIndex
        let aDec = audioDecoder
        let aOut = audioOutput
        let aIdx = audioStreamIndex
        let rndr = renderer
        let condition = demuxCondition
        let initialClock = initialClockTime
        let initialRate = lastRate
        let ring = dvrRing
        let vTbSec = videoTimeBaseSeconds
        let aTbSec = audioTimeBaseSeconds
        let liveSession = isLive
        // Demux-thread edge tracker. Records the session-start PTS once and
        // the newest PTS continuously so the main-actor time tick can read
        // the live edge. Captured weakly so it can't pin `self` past stop.
        let noteEdge: @Sendable (Double) -> Void = { [weak self] ptsSec in
            guard let self, ptsSec.isFinite else { return }
            self.liveEdgeLock.lock()
            if self.sessionStartPts.isNaN { self.sessionStartPts = ptsSec }
            if self.newestSourcePts.isNaN || ptsSec > self.newestSourcePts {
                self.newestSourcePts = ptsSec
            }
            self.liveEdgeLock.unlock()
        }
        let getIsPlaying: @Sendable () -> Bool = { [weak self] in self?.isPlaying ?? false }
        let getStopRequested: @Sendable () -> Bool = { [weak self] in self?.stopRequested ?? true }
        let onError: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor [weak self] in self?.failureMessage = msg }
        }
        let onEnd: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.didReachEnd = true
                self?.isPlaying = false
            }
        }

        demuxQueue.async {
            Self.runDemuxLoop(
                demuxer: dem,
                videoDecoder: vDec,
                videoStreamIndex: vIdx,
                audioDecoder: aDec,
                audioOutput: aOut,
                audioStreamIndex: aIdx,
                renderer: rndr,
                displayLayer: layer.value,
                condition: condition,
                initialClockTime: initialClock,
                initialRate: initialRate,
                ring: ring,
                videoTimeBaseSeconds: vTbSec,
                audioTimeBaseSeconds: aTbSec,
                isLive: liveSession,
                noteEdge: noteEdge,
                isPlaying: getIsPlaying,
                stopRequested: getStopRequested,
                onError: onError,
                onEnd: onEnd
            )
        }
    }

    /// Hot-path demux loop modeled on the pre-collapse pattern. Reads
    /// packets from the demuxer, dispatches by stream index, applies
    /// inline back-pressure on the video display layer's
    /// `isReadyForMoreMediaData` so the decoder doesn't outpace the
    /// renderer. EOF flushes both decoders and the renderer's reorder
    /// buffer, then flips the engine state via the published
    /// `didReachEnd` mirror.
    nonisolated private static func runDemuxLoop(
        demuxer: Demuxer,
        videoDecoder: any VideoDecodingPipeline,
        videoStreamIndex: Int32,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        displayLayer: AVSampleBufferDisplayLayer,
        condition: NSCondition,
        initialClockTime: CMTime,
        initialRate: Float,
        ring: PacketRingBuffer?,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        isLive: Bool,
        noteEdge: @Sendable (Double) -> Void,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        onError: @Sendable (String) -> Void,
        onEnd: @Sendable () -> Void
    ) {
        // One-shot latch so the synchronizer clock is anchored exactly
        // once per session, on the first decoded audio packet. seekClock
        // is NOT idempotent (it always re-sets the synchronizer rate
        // and time), so calling it on every packet would snap the clock
        // back to `initialClockTime` 50× per second and freeze playback.
        var clockArmed = false

        // Live PTS-discontinuity reconciliation (SW path). A program
        // boundary leaps the source PTS (forward or backward) far beyond
        // normal frame spacing. Without compensation, the session edge
        // (`newestPts - sessionStartPts`) would jump by the raw delta and the
        // decoder clock would choke. We keep a running `discontinuityOffset`
        // (in source-PTS seconds): on a detected jump we add
        // `(jumpedPts - expectedContinuationPts)` to it, then subtract the
        // offset from every subsequent packet's PTS BEFORE the live-edge note,
        // the ring append, and the decoder stamping, so the whole pipeline
        // sees one continuous timeline. The decoders are also flushed so they
        // do not stall on the seam (same flush pattern the SW seek path uses).
        //
        // Threshold mirrors the native producer: 10 s, far above any frame
        // interval or the look-behind inference, well below the synthetic
        // +1000 s test jump. Live-only; non-live SW never enters this branch.
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSWDiscontinuity = false

        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[SWHost] demux read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                break
            }

            guard let packet else {
                videoDecoder.flush()
                audioDecoder?.flush()
                renderer.drainReorderBuffer()
                onEnd()
                break
            }

            let streamIdx = packet.pointee.stream_index

            // Live PTS-discontinuity detection + reconciliation. Runs before
            // anything reads the packet's timestamps so the live-edge note,
            // the ring append, and the decoder all see the reconciled
            // (continuous) PTS. Detection keys on the VIDEO stream's raw pts;
            // the resulting offset is applied to BOTH streams so audio stays
            // aligned. Non-live SW skips this entirely.
            if isLive, streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        // Program boundary. The timeline should continue from
                        // where it was: one frame past the previous packet.
                        // Accrue (jumpedPts - expectedContinuationPts) into the
                        // offset so post-jump PTS map back onto the prior
                        // trajectory.
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        // Flush the decoders / renderer so they do not choke
                        // on the seam (codec params may also have changed; a
                        // flush is sufficient for the synthetic test, a fuller
                        // reinit is the device-verify follow-up).
                        videoDecoder.flush()
                        audioDecoder?.flush()
                        renderer.drainReorderBuffer()
                        if !loggedSWDiscontinuity {
                            loggedSWDiscontinuity = true
                            EngineLog.emit(
                                "[SWHost] live PTS discontinuity: prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)",
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        // Track the running frame interval from normal advance
                        // so the expected-continuation estimate is accurate.
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }

            // Apply the accrued discontinuity offset to the packet's
            // timestamps in-place (live only, once a jump has been seen). The
            // offset is in source-PTS seconds; convert to this stream's TB
            // ticks. After this, every downstream consumer (edge note, ring,
            // decoder) operates on the continuous timeline.
            if isLive, discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    let offsetTicks = Int64((discontinuityOffsetSec / tbSec).rounded())
                    if packet.pointee.pts != Int64.min { packet.pointee.pts -= offsetTicks }
                    if packet.pointee.dts != Int64.min { packet.pointee.dts -= offsetTicks }
                }
            }

            // Live edge + DVR ring fill. Done BEFORE decode so the ring
            // holds every packet handed to the pipeline. Both video and
            // audio are appended (the reseed replays both so audio stays
            // in sync); only video keyframes are tagged as keyframes so
            // the ring's keyframe-aligned eviction + reseed anchor on a
            // decodable access point.
            if isLive {
                let isVideo = streamIdx == videoStreamIndex
                let isAudio = streamIdx == audioStreamIndex
                if isVideo || isAudio {
                    let tbSec = isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
                    let rawPts = packet.pointee.pts
                    if rawPts != Int64.min, tbSec > 0 {
                        let ptsSec = Double(rawPts) * tbSec
                        noteEdge(ptsSec)
                        if let ring {
                            let isKey = isVideo && (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                            if let data = packet.pointee.data, packet.pointee.size > 0 {
                                let bytes = Data(bytes: data, count: Int(packet.pointee.size))
                                // Append is a small file write; off-main and
                                // internally locked, so it never touches the
                                // decoders' state. Best-effort: a write failure
                                // just shrinks the rewind window, it must not
                                // stall live playback.
                                try? ring.append(pts: ptsSec, isKeyframe: isKey, isVideo: isVideo, bytes: bytes)
                            }
                        }
                    }
                }
            }

            if streamIdx == videoStreamIndex {
                // Back-pressure against the renderer's actual queue, not
                // the display layer's deprecated property — see
                // `SampleBufferRenderer.isReadyForMoreMediaData` doc.
                while !renderer.isReadyForMoreMediaData && !stopRequested() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if stopRequested() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    break
                }
                videoDecoder.decode(packet: packet)
            } else if streamIdx == audioStreamIndex, let aDec = audioDecoder, let aOut = audioOutput {
                let buffers = aDec.decode(packet: packet)
                for buf in buffers {
                    aOut.enqueue(sampleBuffer: buf)
                }
                // Anchor the synchronizer clock to `initialClockTime`
                // (.zero on cold-start, the resume offset on
                // resume / audio-switch reload) the first time we've
                // got real audio in the renderer. Latched so subsequent
                // packets don't keep snapping the clock back.
                if !clockArmed, !buffers.isEmpty {
                    aOut.seekClock(to: initialClockTime, rate: initialRate)
                    clockArmed = true
                }
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
    }

    // MARK: - Time updates

    private func startTimeUpdates() {
        timeTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let aOut = self.audioOutput else { return }
                let raw = aOut.currentTimeSeconds
                if raw.isFinite, raw >= 0 {
                    // The synchronizer clock runs on the source PTS axis
                    // (samples carry source PTS). For a live session the
                    // engine timeline is "seconds since first frame", so
                    // subtract the session-start PTS. VOD / cold-start
                    // (sessionStartPts unset) keeps the raw clock.
                    if self.isLive {
                        let start: Double = {
                            self.liveEdgeLock.lock(); defer { self.liveEdgeLock.unlock() }
                            return self.sessionStartPts.isFinite ? self.sessionStartPts : 0
                        }()
                        self.currentTime = max(0, raw - start)
                    } else {
                        self.currentTime = raw
                    }
                }
                // Publish the live edge for DVR surfaces. currentTime (just
                // set) is the playhead; the edge is the newest demuxed PTS
                // in session time. publishLiveWindow (in the engine) reads
                // currentTime for the playhead, so we only feed the edge.
                if self.isLive, let edge = self.liveEdgeSessionTime {
                    self.onLiveEdge?(edge)
                }
            }
    }

    // MARK: - Errors

    enum HostError: Error, LocalizedError {
        case noVideoStream

        var errorDescription: String? {
            switch self {
            case .noVideoStream: return "Source has no video stream"
            }
        }
    }
}

// MARK: - AVPacket free helper

/// Symmetric `av_packet_free` that handles the in/out double-pointer
/// dance FFmpeg expects. Pre-collapse code had this as a top-level
/// helper; restored here so the SW demux loop can call it cleanly.
func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&p)
}

// MARK: - Sendable wrapper

/// Box for non-Sendable reference types that we only touch on a single
/// background queue. Captures the value once at construction so the
/// closure that owns it can be marked `@Sendable` without Swift 6
/// strict concurrency rejecting the capture. Used for
/// `AVSampleBufferDisplayLayer`, whose `isReadyForMoreMediaData`
/// reads are documented as thread-safe.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
