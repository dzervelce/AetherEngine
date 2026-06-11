import Testing
@testable import AetherEngine

/// Master-vs-media playlist routing matrix
/// (`HLSVideoEngine.resolveUseMasterPlaylist`). The master playlist is the
/// only place AVPlayer sees VIDEO-RANGE / FRAME-RATE, so `true` here is
/// what enables AVKit's automatic HDR display switch; `false` is the
/// tone-map path. DV-codec masters must stay gated on an already-HDR
/// panel (strict variant filter), plain-HDR masters may additionally ride
/// the Match-Content fallthrough (the -11848/-11868 media retry in
/// loadNative covers the rate-match-only false positive).
@Suite("PlaylistRouting")
struct PlaylistRoutingTests {

    private func route(
        sourceIsHDR: Bool = true,
        panelIsInHDRMode: Bool = false,
        displaySupportsHDR: Bool = true,
        matchContentEnabled: Bool = true,
        primaryCodecs: String = "hvc1.2.4.L150",
        supplementalCodecs: String? = nil,
        dv5OnNonDVPanel: Bool = false
    ) -> Bool {
        HLSVideoEngine.resolveUseMasterPlaylist(
            sourceIsHDR: sourceIsHDR,
            panelIsInHDRMode: panelIsInHDRMode,
            displaySupportsHDR: displaySupportsHDR,
            matchContentEnabled: matchContentEnabled,
            primaryCodecs: primaryCodecs,
            supplementalCodecs: supplementalCodecs,
            dv5OnNonDVPanel: dv5OnNonDVPanel
        )
    }

    @Test("SDR source never routes master, regardless of panel state")
    func sdrSourceStaysOnMedia() {
        #expect(!route(sourceIsHDR: false))
        #expect(!route(sourceIsHDR: false, panelIsInHDRMode: true))
    }

    @Test("HDR10 on SDR panel with Match Content on → master (AVKit drives the switch)")
    func hdr10MatchContentRoutesMaster() {
        #expect(route())
    }

    @Test("HDR10 on SDR panel with Match Content off → media (panel locked)")
    func hdr10MatchContentOffStaysOnMedia() {
        #expect(!route(matchContentEnabled: false))
    }

    @Test("HDR10 on a display with no HDR support → media")
    func hdr10NoHDRDisplayStaysOnMedia() {
        #expect(!route(displaySupportsHDR: false))
    }

    @Test("Panel already in HDR routes master even with Match Content off")
    func panelAlreadyHDRAlwaysMaster() {
        #expect(route(panelIsInHDRMode: true, matchContentEnabled: false))
        #expect(route(panelIsInHDRMode: true, displaySupportsHDR: false))
    }

    @Test("Direct-DV master (bare dvh1 CODECS) stays gated on an already-HDR panel")
    func directDVGatedOnPanel() {
        // P8.1 on a DV panel emits dvh1.08 as the primary codec.
        #expect(!route(primaryCodecs: "dvh1.08.06"))
        #expect(route(panelIsInHDRMode: true, primaryCodecs: "dvh1.08.06"))
        // P5 emits dvh1.05.
        #expect(!route(primaryCodecs: "dvh1.05.06"))
        #expect(route(panelIsInHDRMode: true, primaryCodecs: "dvh1.05.06"))
    }

    @Test("SUPPLEMENTAL-CODECS DV brand stays gated on an already-HDR panel")
    func supplementalDVGatedOnPanel() {
        // P8.4 on a DV panel: hvc1 primary + dvh1/db4h supplemental.
        #expect(!route(supplementalCodecs: "dvh1.08.06/db4h"))
        #expect(route(panelIsInHDRMode: true, supplementalCodecs: "dvh1.08.06/db4h"))
    }

    @Test("DV stripped to plain HDR base rides the Match-Content fallthrough")
    func strippedDVRoutesLikePlainHDR() {
        // P8.1 / P8.4 / P7 on non-DV panels downgrade to plain hvc1 with
        // no supplemental — they present as HDR10/HLG and may switch.
        #expect(route(primaryCodecs: "hvc1.2.4.L153"))
    }

    @Test("DV5 on a non-DV panel always routes media, even with panel in HDR")
    func dv5OnNonDVPanelForcedMedia() {
        #expect(!route(primaryCodecs: "dvh1.05.06", dv5OnNonDVPanel: true))
        #expect(!route(panelIsInHDRMode: true, primaryCodecs: "dvh1.05.06", dv5OnNonDVPanel: true))
    }
}
