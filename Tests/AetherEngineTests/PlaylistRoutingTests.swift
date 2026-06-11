import Testing
@testable import AetherEngine

/// Master-vs-media playlist routing matrix
/// (`HLSVideoEngine.resolveUseMasterPlaylist`). The master playlist is the
/// only place AVPlayer sees VIDEO-RANGE / FRAME-RATE, so `true` here is
/// what enables HDR output; `false` is the tone-map path.
///
/// The routing is PANEL-EMPIRICAL only: an HDR master may be served ONLY
/// to a panel that is already in HDR. The SDR→HDR switch happens UPSTREAM
/// (AetherEngine.load's plain-HDR pre-switch for suppressed-criteria
/// hosts, or the engine pre-flight otherwise) BEFORE this decision. A
/// match-content fallthrough ("serve master, let AVKit switch") was tried
/// and refuted on-device — AVKit's variant filter races its own panel
/// switch and rejects with -11868 mid-transition (debug104, 2026-06-11).
@Suite("PlaylistRouting")
struct PlaylistRoutingTests {

    private func route(
        sourceIsHDR: Bool = true,
        panelIsInHDRMode: Bool = false,
        dv5OnNonDVPanel: Bool = false
    ) -> Bool {
        HLSVideoEngine.resolveUseMasterPlaylist(
            sourceIsHDR: sourceIsHDR,
            panelIsInHDRMode: panelIsInHDRMode,
            dv5OnNonDVPanel: dv5OnNonDVPanel
        )
    }

    @Test("SDR source never routes master, regardless of panel state")
    func sdrSourceStaysOnMedia() {
        #expect(!route(sourceIsHDR: false))
        #expect(!route(sourceIsHDR: false, panelIsInHDRMode: true))
    }

    @Test("HDR source on a panel NOT in HDR → media (pre-switch happens upstream, never here)")
    func hdrOnSDRPanelStaysOnMedia() {
        #expect(!route(panelIsInHDRMode: false))
    }

    @Test("HDR source on a panel already in HDR → master")
    func hdrOnHDRPanelRoutesMaster() {
        #expect(route(panelIsInHDRMode: true))
    }

    @Test("DV5 on a non-DV panel always routes media, even with panel in HDR")
    func dv5OnNonDVPanelForcedMedia() {
        #expect(!route(dv5OnNonDVPanel: true))
        #expect(!route(panelIsInHDRMode: true, dv5OnNonDVPanel: true))
    }
}
