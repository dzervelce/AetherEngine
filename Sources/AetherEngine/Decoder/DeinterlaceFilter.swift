import Foundation
import Libavfilter
import Libavutil

/// Persistent bwdif/yadif deinterlacing graph for the software-decode
/// path.
///
/// Interlaced H.264 routes to native AVPlayer, which deinterlaces
/// itself (device-verified on a 1080i channel). Interlaced MPEG-2 /
/// VC-1 / MPEG-4 (DVD rips, SD broadcast channels) decode through
/// libavcodec and would render with combing artifacts otherwise; this
/// graph weaves them into clean progressive frames.
///
/// Unlike the FrameExtractor's one-shot tone-map graph, this one is
/// PERSISTENT: bwdif/yadif are temporal filters that reference the
/// previous and next frames, so the graph must see a continuous frame
/// stream. The decoder engages it on the first interlaced frame and
/// from then on routes EVERY frame through it; `deint=interlaced`
/// makes the filter pass progressive frames through untouched, so
/// mixed content stays correct. Purely progressive sessions never
/// build a graph and pay zero overhead.
///
/// `mode=send_frame` emits one output frame per input frame (no field
/// rate doubling), so the playback frame rate and the renderer's
/// pacing are unaffected. The filter buffers one frame of lookahead;
/// the decoder tears the graph down on flush (seek) so stale temporal
/// references never bleed across a discontinuity, and lazily rebuilds.
///
/// Not thread-safe; the owning decoder serializes access with its lock.
final class DeinterlaceFilter {

    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var srcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var pixFmt: Int32 = -1
    private var loggedUnavailable = false

    /// True once a graph has been configured for this session; the
    /// decoder uses this to keep routing frames through the filter
    /// after the first interlaced one engaged it.
    var isActive: Bool { graph != nil }

    /// Build (or rebuild after a parameter change) the graph for the
    /// given frame's geometry. Returns false when no deinterlacer is
    /// compiled into the linked FFmpeg build or graph setup fails; the
    /// caller then renders the frame directly (combing, but playing).
    func ensureGraph(frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational) -> Bool {
        if graph != nil,
           width == frame.pointee.width,
           height == frame.pointee.height,
           pixFmt == frame.pointee.format {
            return true
        }
        teardown()

        // bwdif is the primary (better edge reconstruction); yadif the
        // fallback so an older linked framework still deinterlaces.
        let filterName: String
        if avfilter_get_by_name("bwdif") != nil {
            filterName = "bwdif"
        } else if avfilter_get_by_name("yadif") != nil {
            filterName = "yadif"
        } else {
            if !loggedUnavailable {
                loggedUnavailable = true
                EngineLog.emit(
                    "[Deinterlace] no bwdif/yadif in the linked FFmpeg build; rendering interlaced frames as-is",
                    category: .swPlayback
                )
            }
            return false
        }

        guard let g = avfilter_graph_alloc(),
              let bufferFilter = avfilter_get_by_name("buffer"),
              let sinkFilter = avfilter_get_by_name("buffersink") else {
            return false
        }
        var built = false
        var gOpt: UnsafeMutablePointer<AVFilterGraph>? = g
        defer { if !built { avfilter_graph_free(&gOpt) } }

        let sar = frame.pointee.sample_aspect_ratio
        let sarNum = sar.num > 0 ? sar.num : 1
        let sarDen = sar.den > 0 ? sar.den : 1
        let args = "video_size=\(frame.pointee.width)x\(frame.pointee.height)" +
                   ":pix_fmt=\(frame.pointee.format)" +
                   ":time_base=\(timeBase.num)/\(timeBase.den)" +
                   ":pixel_aspect=\(sarNum)/\(sarDen)"

        var src: UnsafeMutablePointer<AVFilterContext>?
        var sink: UnsafeMutablePointer<AVFilterContext>?
        let srcRet = avfilter_graph_create_filter(&src, bufferFilter, "in", args, nil, g)
        let sinkRet = avfilter_graph_create_filter(&sink, sinkFilter, "out", nil, nil, g)
        guard srcRet >= 0, sinkRet >= 0 else {
            EngineLog.emit(
                "[Deinterlace] create_filter failed src=\(srcRet) sink=\(sinkRet) args=\(args)",
                category: .swPlayback
            )
            return false
        }

        // send_frame: one output per input (no field-rate doubling).
        // deint=interlaced: progressive frames pass through untouched.
        let chain = "\(filterName)=mode=send_frame:parity=auto:deint=interlaced"

        var inputs = avfilter_inout_alloc()
        var outputs = avfilter_inout_alloc()
        defer { avfilter_inout_free(&inputs); avfilter_inout_free(&outputs) }
        guard inputs != nil, outputs != nil else { return false }
        outputs!.pointee.name = strdup("in")
        outputs!.pointee.filter_ctx = src
        outputs!.pointee.pad_idx = 0
        outputs!.pointee.next = nil
        inputs!.pointee.name = strdup("out")
        inputs!.pointee.filter_ctx = sink
        inputs!.pointee.pad_idx = 0
        inputs!.pointee.next = nil

        let parseRet = avfilter_graph_parse_ptr(g, chain, &inputs, &outputs, nil)
        guard parseRet >= 0 else {
            EngineLog.emit("[Deinterlace] parse_ptr failed ret=\(parseRet) chain=\(chain)", category: .swPlayback)
            return false
        }
        let configRet = avfilter_graph_config(g, nil)
        guard configRet >= 0 else {
            EngineLog.emit("[Deinterlace] graph_config failed ret=\(configRet)", category: .swPlayback)
            return false
        }

        built = true
        graph = g
        srcCtx = src
        sinkCtx = sink
        width = frame.pointee.width
        height = frame.pointee.height
        pixFmt = frame.pointee.format
        EngineLog.emit(
            "[Deinterlace] engaged: \(filterName) \(width)x\(height) pixFmt=\(pixFmt) (\(chain))",
            category: .swPlayback
        )
        return true
    }

    /// Feed a decoded frame. Takes ownership of the frame's references
    /// (the frame struct is reset; the caller's next receive_frame
    /// refills it).
    func push(_ frame: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let src = srcCtx else { return -1 }
        return av_buffersrc_add_frame_flags(src, frame, 0)
    }

    /// Pull the next filtered frame into `out`. Returns >= 0 on
    /// success, AVERROR(EAGAIN) when the filter needs more input (its
    /// one-frame temporal lookahead), any other negative on error.
    func pull(into out: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let sink = sinkCtx else { return -1 }
        return av_buffersink_get_frame(sink, out)
    }

    /// Free the graph. Called on flush (seek discontinuity: the
    /// temporal references are stale) and close; `ensureGraph` lazily
    /// rebuilds on the next interlaced frame.
    func teardown() {
        if graph != nil {
            avfilter_graph_free(&graph)
        }
        graph = nil
        srcCtx = nil
        sinkCtx = nil
        width = 0
        height = 0
        pixFmt = -1
    }

    deinit {
        teardown()
    }
}
