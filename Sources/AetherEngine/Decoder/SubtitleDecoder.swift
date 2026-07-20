import Foundation
import Libavformat
import Libavcodec
import Libavutil

enum SubtitleDecoderError: Error {
    case openFailed(code: Int32)
    case noSubtitleStream
    case noDecoder
    case codecOpenFailed(code: Int32)
    /// The body exceeded `SubtitleDecoder.maxSidecarBodyBytes` while fetching (HTTP) or reading
    /// (local) the sidecar file.
    case oversizeBody(limit: Int)
    /// The resolved charset could not decode the bytes, or the normalized text could not
    /// re-encode as UTF-8 (both effectively impossible for `SidecarCharsetResolver`'s own
    /// candidates, kept as a defensive terminal case).
    case charsetDecodeFailed
}

/// Result of a sidecar decode: cue list plus, when preserveASSMarkup is set on an ASS/SSA file,
/// the script header ([Script Info] + [V4+ Styles] + [Events] Format line) from the stream's extradata.
struct SidecarDecodeResult {
    let cues: [SubtitleCue]
    let assHeader: String?
}

/// One-shot decoder for sidecar subtitle files (.srt/.ass/.vtt/.ssa).
/// Opens the URL as its own AVFormatContext; sidecars are separate files the main demuxer never sees.
enum SubtitleDecoder {

    /// Decode every cue from the subtitle file at `url`, cancellable via Task.cancel().
    /// When preserveASSMarkup is true, ASS/SSA cues carry the raw libavcodec event line
    /// (ReadOrder,Layer,Style,...,Text) so ASSScriptBuilder can restyle them; no effect on SRT/VTT.
    /// `language` (BCP-47/ISO 639, same convention as `ExternalSubtitleTrack.language`) is the
    /// last-resort disambiguator when the file declares no charset of its own; see
    /// `SidecarCharsetResolver`.
    static func decodeFile(
        url: URL,
        httpHeaders: [String: String] = [:],
        preserveASSMarkup: Bool = false,
        language: String? = nil
    ) async throws -> SidecarDecodeResult {
        // Task.cancel() does NOT propagate into detached tasks (isCancelled inside always false).
        // Bridge cancellation explicitly via CancelFlag so the fetch/decode loop abort promptly.
        let token = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try decodeFileSync(
                    url: url, httpHeaders: httpHeaders,
                    preserveASSMarkup: preserveASSMarkup, cancel: token, language: language
                )
            }.value
        } onCancel: {
            token.cancel()
        }
    }

    /// Ceiling on a sidecar's fetched/read body. Subtitle files are text and tiny; a server (or a
    /// mis-pointed external-subtitle URL) serving something far larger is misbehaving and must not
    /// be buffered toward jetsam (mirrors AVIOReader's ChunkFetchDelegate cap for media fetches).
    static let maxSidecarBodyBytes: Int = 8 * 1024 * 1024

    /// Thread-safe cancellation token for the detached decode task. Holds the abort action for
    /// whichever phase is currently running - the capped network fetch, then the in-memory demux -
    /// so `cancel()` aborts either promptly; `registerAbort` fires immediately if already cancelled
    /// (mirrors the old register-before-open ordering: a cancel landing mid-fetch or mid-open must
    /// not wait for a network timeout, #32).
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var abortHandler: (() -> Void)?

        func cancel() {
            lock.lock()
            cancelled = true
            let handler = abortHandler
            lock.unlock()
            handler?()
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }

        func registerAbort(_ handler: @escaping () -> Void) {
            lock.lock()
            let wasCancelled = cancelled
            abortHandler = handler
            lock.unlock()
            if wasCancelled { handler() }
        }
    }

    /// Extensions carrying text subtitle formats. Only these route through `SidecarCharsetResolver`;
    /// see the corruption note at the `isTextSidecarFormat` call site.
    private static let textSidecarExtensions: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]

    private static func isTextSidecarFormat(url: URL) -> Bool {
        textSidecarExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Synchronous core

    private static func decodeFileSync(
        url: URL, httpHeaders: [String: String],
        preserveASSMarkup: Bool, cancel: CancelFlag, language: String?
    ) throws -> SidecarDecodeResult {
        let isHTTP = url.scheme == "http" || url.scheme == "https"

        // #<A>: fetch the whole (capped) body first and resolve its charset before handing
        // anything to libavformat, which has no charset detection of its own - the prior code fed
        // raw HTTP/legacy bytes straight to the demuxer and silently mojibaked anything outside
        // ASCII. Local files go through the identical resolve+transcode path so a legacy-encoded
        // bundled sidecar is not a second, unfixed instance of the same defect.
        let rawBody: Data
        var contentType: String?
        if isHTTP {
            let fetched = try fetchSidecarBody(url: url, headers: httpHeaders, cancel: cancel)
            rawBody = fetched.body
            contentType = fetched.contentType
        } else {
            let path = url.isFileURL ? url.path : url.absoluteString
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.intValue else {
                throw SubtitleDecoderError.openFailed(code: -1)
            }
            guard size <= maxSidecarBodyBytes else {
                throw SubtitleDecoderError.oversizeBody(limit: maxSidecarBodyBytes)
            }
            guard let data = FileManager.default.contents(atPath: path) else {
                throw SubtitleDecoderError.openFailed(code: -1)
            }
            rawBody = data
        }
        guard !cancel.isCancelled else { throw CancellationError() }

        // Charset resolution only applies to TEXT sidecar formats (SRT/ASS/SSA/VTT); a bitmap
        // sidecar (PGS `.sup`) or anything unrecognized is binary or unknown and must reach the
        // demuxer byte-for-byte - decoding it under a guessed text encoding and re-encoding to UTF-8
        // would corrupt it (control bytes reinterpreted as CR/LF, high bytes remapped by the guessed
        // code page, etc).
        let demuxBody: Data
        if isTextSidecarFormat(url: url) {
            let encoding = SidecarCharsetResolver.resolve(
                contentType: contentType, bytes: rawBody, language: language)
            guard let decodedText = SidecarCharsetResolver.decode(rawBody, as: encoding) else {
                throw SubtitleDecoderError.charsetDecodeFailed
            }
            let normalized = SidecarCharsetResolver.normalizeLineEndings(decodedText)
            guard let utf8Body = normalized.data(using: .utf8) else {
                throw SubtitleDecoderError.charsetDecodeFailed
            }
            demuxBody = utf8Body
        } else {
            demuxBody = rawBody
        }

        // Demux the in-memory body through the same custom-AVIO seam a live custom source uses,
        // rather than re-opening the original URL: the fetch above already paid the network/disk
        // cost, and libavformat needs a byte source it can probe, not a decoded String.
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: demuxBody))
        cancel.registerAbort { bridge.markClosed() }
        try bridge.open()
        guard let allocated = avformat_alloc_context() else {
            bridge.close()
            throw SubtitleDecoderError.openFailed(code: -1)
        }
        allocated.pointee.pb = bridge.context
        // Assign formatContext only after a successful open: avformat_open_input frees the
        // supplied context and NULLs its pointer on failure, so an early assignment would
        // leave a dangling pointer for the defer to double-close (mirrors Demuxer.swift).
        var ctxPtr: UnsafeMutablePointer<AVFormatContext>? = allocated
        let ret = avformat_open_input(&ctxPtr, nil, nil, nil)
        guard ret == 0 else {
            bridge.close()
            throw SubtitleDecoderError.openFailed(code: ret)
        }
        formatContext = ctxPtr

        defer {
            if formatContext != nil {
                avformat_close_input(&formatContext)
            }
            bridge.close()
        }

        guard let fmt = formatContext else {
            throw SubtitleDecoderError.openFailed(code: -1)
        }

        let probeRet = avformat_find_stream_info(fmt, nil)
        guard probeRet >= 0 else {
            throw SubtitleDecoderError.openFailed(code: probeRet)
        }

        // Probe defensively; sidecars usually have one stream at index 0 but containers can have extras.
        var subStreamIndex: Int = -1
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar
            else { continue }
            if codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                subStreamIndex = i
                break
            }
        }
        guard subStreamIndex >= 0,
              let stream = fmt.pointee.streams[subStreamIndex],
              let codecpar = stream.pointee.codecpar
        else {
            throw SubtitleDecoderError.noSubtitleStream
        }

        // ASS/SSA script header is in codec extradata (mirrors Demuxer.trackInfo for embedded tracks).
        // Only surfaced under preserveASSMarkup; the raw event-line path is the only consumer.
        let codecID = codecpar.pointee.codec_id
        let isASS = codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA
        let keepMarkup = preserveASSMarkup && isASS
        var assHeader: String? = nil
        if keepMarkup,
           let extradata = codecpar.pointee.extradata,
           codecpar.pointee.extradata_size > 0 {
            let bytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            // Strip NUL bytes: extradata is often NUL-terminated; libass parses C-string-style and a NUL hides everything after it.
            assHeader = String(data: bytes, encoding: .utf8)?
                .replacingOccurrences(of: "\0", with: "")
        }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw SubtitleDecoderError.noDecoder
        }
        guard let codecCtx = avcodec_alloc_context3(codec) else {
            throw SubtitleDecoderError.codecOpenFailed(code: -1)
        }
        var localCodecCtx: UnsafeMutablePointer<AVCodecContext>? = codecCtx
        defer { avcodec_free_context(&localCodecCtx) }

        let paramsRet = avcodec_parameters_to_context(codecCtx, codecpar)
        guard paramsRet >= 0 else {
            throw SubtitleDecoderError.codecOpenFailed(code: paramsRet)
        }
        let openRet = avcodec_open2(codecCtx, codec, nil)
        guard openRet >= 0 else {
            throw SubtitleDecoderError.codecOpenFailed(code: openRet)
        }

        let timeBase = stream.pointee.time_base
        let tbSec = Double(timeBase.num) / Double(timeBase.den)

        var cues: [SubtitleCue] = []
        var nextID = 0
        /// Indices of image cues still "open" (PGS-style: ended by the next composition event).
        var pendingImageCueIndices: [Int] = []
        var lastPktPTS: Double = 0  // PTS anchor for flush events that have no packet of their own

        // Under preserveASSMarkup: keep raw ASS event line (ASSScriptBuilder re-stamps timing); otherwise plain text.
        let lineForRect: (UnsafeMutablePointer<AVSubtitleRect>) -> String? = { rect in
            keepMarkup ? SubtitleRectText.rawASSLine(for: rect) : SubtitleRectText.plainText(for: rect)
        }

        while !cancel.isCancelled {
            var pktPtr: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
            guard let pkt = pktPtr else { break }
            let readRet = av_read_frame(fmt, pkt)
            if readRet < 0 {
                trackedPacketFree(&pktPtr)
                break
            }

            if Int(pkt.pointee.stream_index) != subStreamIndex {
                av_packet_unref(pkt)
                trackedPacketFree(&pktPtr)
                continue
            }

            var sub = AVSubtitle()
            var gotSub: Int32 = 0
            let ret = avcodec_decode_subtitle2(codecCtx, &sub, &gotSub, pkt)

            if ret >= 0 && gotSub != 0 {
                let pktPTS = pkt.pointee.pts == Int64.min
                    ? 0.0
                    : Double(pkt.pointee.pts) * tbSec
                lastPktPTS = pktPTS
                let startOffset = Double(sub.start_display_time) / 1000.0
                let endOffset: Double
                if sub.end_display_time > 0 {
                    endOffset = Double(sub.end_display_time) / 1000.0
                } else if pkt.pointee.duration > 0 {
                    endOffset = Double(pkt.pointee.duration) * tbSec
                } else {
                    endOffset = 5.0
                }
                let startTime = pktPTS + startOffset
                let endTime = pktPTS + endOffset

                // Bitmap subtitles (external .sup / PGS sidecars, FFmpegBuild >= 2.1.3 sup demuxer):
                // a composition usually carries end_display_time == 0 and is ended by the NEXT
                // composition event (a new set or a clear packet), so clamp any still-open image
                // cues to this packet's PTS before appending the new ones. The 5 s fallback above
                // only survives for a final composition with no successor.
                for idx in pendingImageCueIndices where cues[idx].startTime < pktPTS && cues[idx].endTime > pktPTS {
                    let open = cues[idx]
                    cues[idx] = SubtitleCue(id: open.id, startTime: open.startTime, endTime: pktPTS, body: open.body)
                }
                pendingImageCueIndices.removeAll()

                var lines: [String] = []
                var images: [SubtitleImage] = []
                if sub.num_rects > 0, let rects = sub.rects {
                    for i in 0..<Int(sub.num_rects) {
                        guard let rect = rects[i] else { continue }
                        if rect.pointee.type == SUBTITLE_BITMAP {
                            // The composition canvas is the codec's coded size (PGS: from the PCS).
                            if let image = EmbeddedSubtitleDecoder.imageForSubtitleRect(
                                rect,
                                videoWidth: Int(codecpar.pointee.width),
                                videoHeight: Int(codecpar.pointee.height)
                            ) {
                                images.append(image)
                            }
                        } else if let text = lineForRect(rect) {
                            lines.append(text)
                        }
                    }
                }
                avsubtitle_free(&sub)

                let merged = lines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !merged.isEmpty && endTime > startTime {
                    cues.append(SubtitleCue(
                        id: nextID,
                        startTime: startTime,
                        endTime: endTime,
                        body: .text(merged)
                    ))
                    nextID += 1
                }
                if endTime > startTime {
                    for image in images {
                        pendingImageCueIndices.append(cues.count)
                        cues.append(SubtitleCue(
                            id: nextID,
                            startTime: startTime,
                            endTime: endTime,
                            body: .image(image)
                        ))
                        nextID += 1
                    }
                }
            }

            av_packet_unref(pkt)
            trackedPacketFree(&pktPtr)
        }

        // Flush ASS/SSA buffered events (old code decoded one event and discarded it, silently losing the last cue).
        // Flushed events have no packet; use lastPktPTS as the timing anchor.
        while !cancel.isCancelled {
            var flushPkt = AVPacket()
            flushPkt.data = nil
            flushPkt.size = 0
            var flushSub = AVSubtitle()
            var gotFlush: Int32 = 0
            let flushRet = avcodec_decode_subtitle2(codecCtx, &flushSub, &gotFlush, &flushPkt)
            guard flushRet >= 0, gotFlush != 0 else { break }

            let startOffset = Double(flushSub.start_display_time) / 1000.0
            let endOffset = flushSub.end_display_time > 0
                ? Double(flushSub.end_display_time) / 1000.0
                : startOffset + 5.0
            var lines: [String] = []
            if flushSub.num_rects > 0, let rects = flushSub.rects {
                for i in 0..<Int(flushSub.num_rects) {
                    guard let rect = rects[i] else { continue }
                    if let text = lineForRect(rect) {
                        lines.append(text)
                    }
                }
            }
            avsubtitle_free(&flushSub)

            let merged = lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let startTime = lastPktPTS + startOffset
            let endTime = lastPktPTS + endOffset
            if !merged.isEmpty && endTime > startTime {
                cues.append(SubtitleCue(
                    id: nextID,
                    startTime: startTime,
                    endTime: endTime,
                    body: .text(merged)
                ))
                nextID += 1
            }
        }

        return SidecarDecodeResult(
            cues: cues.sorted { $0.startTime < $1.startTime },
            assHeader: assHeader
        )
    }

    // MARK: - Capped HTTP fetch

    /// One-shot capped GET for a sidecar subtitle file: the whole body up to `maxSidecarBodyBytes`,
    /// plus the response `Content-Type` for charset resolution. Blocks the calling (detached) thread
    /// via semaphore, matching this file's otherwise-synchronous decode core. Redirects replay the
    /// caller's headers through the same policy media fetches use (`RedirectHeaderPolicy`), so an
    /// addon's auth header is not silently dropped on a CDN hop.
    private static func fetchSidecarBody(
        url: URL, headers: [String: String], cancel: CancelFlag
    ) throws -> (body: Data, contentType: String?) {
        let delegate = SidecarFetchDelegate(maxBytes: maxSidecarBodyBytes)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.dataTask(with: request)
        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        cancel.registerAbort { task.cancel() }
        task.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        if let error = delegate.error {
            throw error
        }
        return (delegate.body, delegate.contentType)
    }
}

/// Delegate backing `SubtitleDecoder.fetchSidecarBody`: buffers the response body up to a hard cap
/// (a server ignoring an implicit whole-file GET, or ignoring Content-Length, must not drive
/// unbounded allocation - same defensive contract as AVIOReader's ChunkFetchDelegate) and captures
/// the declared Content-Type for charset resolution. All mutable state is only ever touched from
/// URLSession's delegate queue, so no additional locking is needed beyond `@unchecked Sendable`.
private final class SidecarFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maxBytes: Int
    var body = Data()
    var contentType: String?
    var error: Error?
    var onCompletion: (() -> Void)?

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let replayHeaders = (task.originalRequest?.allHTTPHeaderFields).map { headers in
            RedirectHeaderPolicy.headersToReplay(
                extraHeaders: headers,
                originalURL: task.originalRequest?.url,
                redirectURL: request.url)
        } ?? [:]
        var updated = request
        for (name, value) in replayHeaders {
            updated.setValue(value, forHTTPHeaderField: name)
        }
        completionHandler(updated)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        contentType = http.value(forHTTPHeaderField: "Content-Type")
        let len = Int(http.expectedContentLength)
        if len > 0 { body.reserveCapacity(min(len, maxBytes)) }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            error = SubtitleDecoderError.openFailed(code: Int32(http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= maxBytes else {
            if error == nil { error = SubtitleDecoderError.oversizeBody(limit: maxBytes) }
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Keep a deliberate cap/status error - the cancellation it triggers must not overwrite it.
        if self.error == nil { self.error = error }
        onCompletion?()
    }
}
