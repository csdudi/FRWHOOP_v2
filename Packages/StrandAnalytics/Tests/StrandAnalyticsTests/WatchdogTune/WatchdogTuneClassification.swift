import Foundation

enum WatchdogTuneTestKind: String, Sendable {
    case unit
    case livePath = "live-path"
}

/// Integrity tests stay; they are not the tune. Unit = injected J / writeDay / memory / band.update.
enum WatchdogTuneClassification {
    static let suites: [(name: String, kind: WatchdogTuneTestKind, why: String)] = [
        ("WatchdogV23Tests", .unit, "Direction.compute(rawR) and severity(recon:)"),
        ("WatchdogV25SelfLabelTests", .unit, "Memory.observe + Band.update call-counts; one live quiet evaluate"),
        ("WatchdogV27PhaseSidecarTests", .unit, "writeDay / blendPrompt vectors; some evaluate ticks"),
        ("WatchdogV30SeverityJointTests", .unit, "Most rows are severityJoint(energies:); a few evaluate"),
        ("WatchdogIsolationTests", .unit, "Layer 1 hash lock"),
        ("WatchdogV28LiveTapeTests", .livePath, "Packet clock / wrist-off tape"),
        ("WatchdogV29HonestyTests", .livePath, "Window builder empty minutes"),
        ("WatchdogV31LiveTailTests", .livePath, "evaluate leftover / safety"),
        ("WatchdogV32FollowOnTests", .livePath, "blend + evaluate tail / sidecar minutes"),
        ("WatchdogV34ActivityConnectTests", .livePath, "20-col builder + evaluate"),
        ("WatchdogV35ForecastEarlyTests", .livePath, "evaluate + path cube"),
        ("WatchdogV36EventTransitionTests", .livePath, "evaluate hold / C4"),
        ("WatchdogV37GreenBandPeriodTests", .livePath, "evaluate PhaseKey minutes"),
        ("WatchdogV38TuneEvidenceTests", .livePath, "catalog replay evaluate"),
        ("WatchdogV24DynamicTests", .unit, "Geometry tables; some reconstruct"),
        ("WatchdogV26PrimeFixTests", .livePath, "evaluate integrity"),
        ("WatchdogV33LogicGapTests", .livePath, "evaluate prompt / day log"),
        ("WatchdogV2GauntletTests", .livePath, "mixed; includes inject.severe and file pin"),
        ("WatchdogPrimeProbeTests", .livePath, "evaluate probes"),
        ("WatchdogPrimeGauntletTests", .livePath, "evaluate gauntlet"),
        ("WatchdogTests", .livePath, "evaluate + inject Test Centre"),
    ]

    static func markdown() -> String {
        var md = """
        ## Test classification (not a tune)

        | Suite | Kind | Why |
        |---|---|---|

        """
        for s in suites {
            md += "| \(s.name) | \(s.kind.rawValue) | \(s.why) |\n"
        }
        return md
    }
}
