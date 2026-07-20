import Foundation

/// Outcome of the most recent sidecar subtitle decode (`AetherEngine.$sidecarLoadResult`). The
/// decode itself only logs on failure (`EngineLog`, host-invisible); this gives hosts a signal to
/// surface a "couldn't load subtitles" toast instead of a silently empty overlay. A completed
/// decode that produced zero cues counts as `success == false` - the file opened but had nothing
/// usable is indistinguishable from "broken" to the person watching.
public struct SidecarLoadResult: Sendable, Equatable {
    public let url: URL
    public let success: Bool
    public let cueCount: Int
    public let message: String?

    public init(url: URL, success: Bool, cueCount: Int, message: String? = nil) {
        self.url = url
        self.success = success
        self.cueCount = cueCount
        self.message = message
    }
}
