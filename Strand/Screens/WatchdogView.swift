import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// Live half-hour on Baseline. Each vital is equal; dotted line is the reconstructed usual for this stretch.
@MainActor
struct WatchdogPlaceholderView: View {
    @EnvironmentObject private var store: BaselineStore
    var embedded: Bool = false
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw)
    }

    var body: some View {
        if embedded {
            liveCard
        } else {
            ScreenScaffold(
                title: "Right now",
                subtitle: "Last 30 minutes.",
                topBackground: liquidScaffoldSky()
            ) {
                liveCard
            }
        }
    }

    private var liveCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Live baseline")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                liveBanner
                if snapshot.trustPct != nil || snapshot.trustCaption != nil {
                    trustLine
                }
                Text("The green band is this stretch’s reconstructed usual. Heart rate uses the awake pulse usual; resting HR uses still minutes and the sleep usual. Not a diagnosis.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                traitRows
            }
            .padding(.vertical, 4)
        }
        .onAppear { WatchdogNotifier.requestAuthorization() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.liveLabel). Live baseline")
    }

    private var liveBanner: some View {
        TimelineView(.periodic(from: .now, by: 0.9)) { timeline in
            let pulse = snapshot.isLive
                && Int(timeline.date.timeIntervalSince1970 / 0.9) % 2 == 0
            HStack(spacing: 8) {
                Circle()
                    .fill(snapshot.isLive ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    .frame(width: 8, height: 8)
                    .opacity(snapshot.isLive ? (pulse ? 1 : 0.28) : 0.5)
                    .accessibilityHidden(true)
                Text(snapshot.isLive ? "On" : snapshot.liveLabel)
                    .font(StrandFont.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(snapshot.isLive ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                if snapshot.isLive, snapshot.earlyFlag {
                    Text("·")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    Text("Early")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if snapshot.isLive, snapshot.activityDetail != "Context unknown" {
                    Text("·")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    Text(snapshot.activityDetail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text("·")
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text(snapshot.isLive ? (snapshot.updatedAgo ?? "Updating") : "Waiting on a reading")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(snapshot.isLive
                          ? StrandPalette.statusPositive.opacity(0.12)
                          : StrandPalette.surfaceInset)
            )
        }
    }

    private var trustLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let pct = snapshot.trustPct {
                Text("TRUST \(pct)%")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(trustColor(pct))
                    .tracking(0.4)
                    .accessibilityLabel("Trust \(pct) percent")
            }
            if let caption = snapshot.trustCaption {
                Text(caption)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trustColor(_ pct: Int) -> Color {
        if pct >= 70 { return StrandPalette.statusPositive }
        if pct >= 40 { return StrandPalette.textSecondary }
        return StrandPalette.statusWarning
    }

    private var traitRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.metrics.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().overlay(StrandPalette.hairline)
                }
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Text(row.now)
                            .font(StrandFont.rounded(18, weight: .bold))
                            .foregroundStyle(row.tone)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(row.windowCaption)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: 88, alignment: .leading)
                    WatchdogTraitStrip(values: row.series,
                                       reconstructed: row.reconstructed,
                                       usual: row.usualValue,
                                       tint: row.tone,
                                       minSpan: row.minSpan,
                                       decimals: row.decimals,
                                       rangeHalf: row.rangeHalf,
                                       rangeSeries: row.rangeSeries,
                                       pulsePeriod: snapshot.isLive ? row.pulsePeriod : 0)
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.expected)
                            .font(StrandFont.rounded(16, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        Text(row.status)
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(row.tone)
                            .lineLimit(1)
                    }
                    .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.name) \(row.now), expected \(row.expected), \(row.status)")
            }
        }
    }

    private var snapshot: WatchdogLiveSnapshot {
        WatchdogLiveSnapshot(store: store, temperatureUnit: temperatureUnit)
    }
}

private struct WatchdogTraitStrip: View {
    let values: [Double]
    let reconstructed: [Double]
    let usual: Double?
    let tint: Color
    let minSpan: Double
    let decimals: Int
    let rangeHalf: Double
    let rangeSeries: [Double]
    let pulsePeriod: Double

    private func half(at index: Int) -> Double {
        if index >= 0, index < rangeSeries.count, rangeSeries[index].isFinite, rangeSeries[index] > 0 {
            return rangeSeries[index]
        }
        return rangeHalf
    }

    private var observed: [(id: Double, y: Double)] {
        values.enumerated().compactMap { i, v in
            guard v.isFinite else { return nil }
            return (Double(i), v)
        }
    }

    private var expected: [(id: Double, y: Double)] {
        let pts = reconstructed.enumerated().compactMap { i, v -> (Double, Double)? in
            guard v.isFinite else { return nil }
            return (Double(i), v)
        }
        if !pts.isEmpty { return pts }
        guard let usual else { return [] }
        return (0..<WatchdogConfig.seqLen).map { (Double($0), usual) }
    }

    /// In-range corridor at the live end: reconstructed usual ± UniTS predicted scale at that minute.
    private var liveRange: (lo: Double, hi: Double)? {
        guard let hat = expected.last else {
            guard rangeHalf > 0, let usual else { return nil }
            return (usual - rangeHalf, usual + rangeHalf)
        }
        let width = half(at: Int(hat.id.rounded()))
        guard width > 0 else { return nil }
        return (hat.y - width, hat.y + width)
    }

    private var yDomain: ClosedRange<Double> {
        var ys = observed.map(\.y) + expected.map(\.y)
        if let usual { ys.append(usual) }
        for point in expected {
            let width = half(at: Int(point.id.rounded()))
            ys.append(point.y - width)
            ys.append(point.y + width)
        }
        if let liveRange {
            ys.append(liveRange.lo)
            ys.append(liveRange.hi)
        }
        guard let lo = ys.min(), let hi = ys.max() else { return 0...1 }
        let span = max(hi - lo, minSpan)
        let mid = (hi + lo) / 2
        let pad = span * 0.12
        return (mid - span / 2 - pad)...(mid + span / 2 + pad)
    }

    private func formatY(_ value: Double) -> String {
        decimals == 0 ? String(format: "%.0f", value) : String(format: "%.\(decimals)f", value)
    }

    private func yPixel(value: Double, height: CGFloat) -> CGFloat {
        let d = yDomain
        let span = d.upperBound - d.lowerBound
        guard span > 0 else { return height / 2 }
        let t = (value - d.lowerBound) / span
        return (1 - t) * height
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            if let liveRange {
                GeometryReader { geo in
                    Text(formatY(liveRange.hi))
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(StrandPalette.statusPositive)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: geo.size.width, alignment: .trailing)
                        .position(x: geo.size.width / 2, y: yPixel(value: liveRange.hi, height: geo.size.height))
                    Text(formatY(liveRange.lo))
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(StrandPalette.statusPositive)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: geo.size.width, alignment: .trailing)
                        .position(x: geo.size.width / 2, y: yPixel(value: liveRange.lo, height: geo.size.height))
                }
                .frame(width: 24)
                .accessibilityHidden(true)
            }
            plot
        }
    }

    @ViewBuilder
    private var plot: some View {
        if observed.count >= 1 || expected.count >= 1 {
            if pulsePeriod > 0, pulsePeriod <= 2 {
                TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                    let t = timeline.date.timeIntervalSince1970.truncatingRemainder(dividingBy: pulsePeriod)
                    chart(flash: t < 0.18)
                }
            } else {
                chart(flash: false)
            }
        } else {
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height * 0.65))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * 0.65))
                }
                .stroke(StrandPalette.statusPositive.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
    }

    private func chart(flash: Bool) -> some View {
        Chart {
            ForEach(expected, id: \.id) { point in
                AreaMark(
                    x: .value("t", point.id),
                    yStart: .value("v", point.y - half(at: Int(point.id.rounded()))),
                    yEnd: .value("v", point.y + half(at: Int(point.id.rounded())))
                )
                .foregroundStyle(StrandPalette.statusPositive.opacity(0.16))
                .interpolationMethod(.linear)
            }
            ForEach(expected, id: \.id) { point in
                LineMark(x: .value("t", point.id), y: .value("v", point.y), series: .value("s", "usual"))
                    .interpolationMethod(.linear)
                    .foregroundStyle(StrandPalette.statusPositive)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, dash: [5, 4]))
            }
            ForEach(observed, id: \.id) { point in
                LineMark(x: .value("t", point.id), y: .value("v", point.y), series: .value("s", "now"))
                    .interpolationMethod(.linear)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
            }
            if let last = observed.last {
                PointMark(x: .value("t", last.id), y: .value("v", last.y))
                    .foregroundStyle(tint)
                    .symbolSize(flash ? 34 : 22)
            }
        }
        .chartXScale(domain: 0...29)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.padding(.vertical, 2) }
    }
}

@MainActor
private struct WatchdogLiveSnapshot {
    struct MetricRow: Identifiable {
        let id: String
        let name: String
        let now: String
        let expected: String
        let status: String
        let tone: Color
        let series: [Double]
        let reconstructed: [Double]
        let usualValue: Double?
        let windowCaption: String
        let minSpan: Double
        let decimals: Int
        let rangeHalf: Double
        let rangeSeries: [Double]
        let pulsePeriod: Double
    }

    let headline: String
    let isLive: Bool
    let liveLabel: String
    let updatedAgo: String?
    let trustPct: Int?
    let trustCaption: String?
    let activityDetail: String
    let earlyFlag: Bool
    let sigmaAdaptive: Bool
    let metrics: [MetricRow]

    init(store: BaselineStore, temperatureUnit: TemperatureUnit = .celsius) {
        let fahrenheit = temperatureUnit == .fahrenheit
        if let result = store.watchdogResult {
            headline = Self.headline(result)
            isLive = result.monitoringCurrent && result.unavailable == nil
            liveLabel = isLive ? "Live baseline" : Self.waitingLabel(result)
            updatedAgo = Self.ago(result.lastTickUnix)
            trustPct = result.unavailable == nil ? result.trustPct : nil
            trustCaption = Self.trustCaption(result)
            activityDetail = result.activityDetail
            earlyFlag = result.earlyFlag && result.trustPct >= 35
            sigmaAdaptive = result.sigmaAdaptive
            let hr = result.signals.first(where: { $0.name == "HR" })
            let rhr = result.signals.first(where: { $0.name == "RHR" })
            let hrv = result.signals.first(where: { $0.name == "HRV" })
            let temp = result.signals.first(where: { $0.name == "Temp" })
            let resp = result.signals.first(where: { $0.name == "Resp" })
            let spo2 = result.signals.first(where: { $0.name == "SpO2" })
            let whoop5 = WhoopModel.persisted == .whoop5mg
            metrics = [
                Self.row(id: "hr", name: "Heart rate", signal: hr, series: result.horizonHR,
                         reconstructed: result.reconstructedHR, rangeSeries: result.rangeHR,
                         caption: "Pulse · awake usual", minSpan: 8, whoop5: whoop5),
                Self.row(id: "rhr", name: "Resting HR", signal: rhr, series: result.horizonRHR,
                         reconstructed: result.reconstructedRHR, rangeSeries: result.rangeRHR,
                         caption: "Still minutes · sleep usual", minSpan: 8, whoop5: whoop5),
                Self.row(id: "hrv", name: "HRV", signal: hrv, series: result.horizonHRV,
                         reconstructed: result.reconstructedHRV, rangeSeries: result.rangeHRV,
                         caption: "Last 5 min RMSSD", minSpan: 18, whoop5: whoop5),
                Self.row(id: "temp", name: "Wrist temp", signal: temp, series: result.horizonTemp,
                         reconstructed: result.reconstructedTemp, rangeSeries: result.rangeTemp,
                         caption: "Last 30 min", minSpan: 0.4, whoop5: whoop5,
                         fahrenheit: fahrenheit),
                Self.row(id: "resp", name: "Breathing", signal: resp, series: result.horizonResp,
                         reconstructed: result.reconstructedResp, rangeSeries: result.rangeResp,
                         caption: "Held across gaps", minSpan: 4, whoop5: whoop5),
                Self.row(id: "spo2", name: "SpO₂", signal: spo2, series: result.horizonSpO2,
                         reconstructed: result.reconstructedSpO2, rangeSeries: result.rangeSpO2,
                         caption: "Percent samples", minSpan: 2, whoop5: whoop5)
            ]
            return
        }

        isLive = false
        liveLabel = "Waiting"
        updatedAgo = nil
        trustPct = nil
        trustCaption = "Usual is still being learned."
        headline = "Waiting on this half-hour"
        activityDetail = "Context unknown"
        earlyFlag = false
        sigmaAdaptive = false
        let whoop5 = WhoopModel.persisted == .whoop5mg
        metrics = [
            Self.emptyRow(id: "hr", name: "Heart rate", caption: "Pulse · awake usual", minSpan: 8, whoop5: whoop5),
            Self.emptyRow(id: "rhr", name: "Resting HR", caption: "Still minutes · sleep usual", minSpan: 8, whoop5: whoop5),
            Self.emptyRow(id: "hrv", name: "HRV", caption: "Last 5 min RMSSD", minSpan: 18, whoop5: whoop5),
            Self.emptyRow(id: "temp", name: "Wrist temp", caption: "Last 30 min", minSpan: 0.4, whoop5: whoop5,
                          fahrenheit: fahrenheit),
            Self.emptyRow(id: "resp", name: "Breathing", caption: "Held across gaps", minSpan: 4, whoop5: whoop5),
            Self.emptyRow(id: "spo2", name: "SpO₂", caption: "Percent samples", minSpan: 2, whoop5: whoop5)
        ]
    }

    static func row(id: String, name: String, signal: WatchdogSignalEvidence?,
                    series: [Double], reconstructed: [Double], rangeSeries: [Double],
                    caption: String, minSpan: Double, whoop5: Bool, fahrenheit: Bool = false) -> MetricRow {
        let energy = signal?.energy ?? 0
        var now = signal?.observed
        var usual = signal?.reconstructed ?? signal?.usual
        var series = series
        var reconstructed = reconstructed
        var rangeSeries = rangeSeries
        var minSpan = minSpan
        var range = (signal?.rangeHalf ?? 0) > 0 ? (signal?.rangeHalf ?? rangeHalf(for: id)) : rangeHalf(for: id)
        var unit = signal?.unit ?? ""
        if id == "temp", fahrenheit {
            now = now.map(UnitFormatter.celsiusToFahrenheit)
            usual = usual.map(UnitFormatter.celsiusToFahrenheit)
            series = series.map(UnitFormatter.celsiusToFahrenheit)
            reconstructed = reconstructed.map(UnitFormatter.celsiusToFahrenheit)
            minSpan *= 9.0 / 5.0
            range *= 9.0 / 5.0
            rangeSeries = rangeSeries.map { $0 * 9.0 / 5.0 }
            unit = "°F"
        }
        let aligned = lastAligned(series: series, reconstructed: reconstructed, usual: usual)
        let lastObs = aligned?.obs
        let lastHat = aligned?.hat
        let lastWidth: Double = {
            if let i = aligned?.index, i >= 0, i < rangeSeries.count, rangeSeries[i] > 0 {
                return rangeSeries[i]
            }
            return range
        }()
        let outsideBand: Bool = {
            guard let lastObs, let lastHat, lastWidth > 0 else { return energy >= WatchdogConfig.tau }
            return abs(lastObs - lastHat) > lastWidth
        }()
        let status: String
        let tone: Color
        if signal?.observed == nil {
            status = "—"
            tone = StrandPalette.textTertiary
        } else if outsideBand || energy >= WatchdogConfig.tau {
            let mag: Double
            if lastWidth > 0, let lastObs, let lastHat {
                mag = min(1, abs(lastObs - lastHat) / max(lastWidth, 0.001) / WatchdogConfig.tauSevere)
            } else {
                mag = min(1, energy / WatchdogConfig.tauSevere)
            }
            status = "Out of sync"
            tone = baselineOffColor(mag)
        } else {
            status = "In sync"
            tone = StrandPalette.statusPositive
        }
        return MetricRow(id: id, name: name,
                         now: format(now, decimals: decimals(for: id), unit: unit),
                         expected: format(usual, decimals: decimals(for: id), unit: unit),
                         status: status, tone: tone, series: series, reconstructed: reconstructed,
                         usualValue: usual, windowCaption: caption, minSpan: minSpan,
                         decimals: decimals(for: id),
                         rangeHalf: lastWidth,
                         rangeSeries: rangeSeries,
                         pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
    }

    static func lastAligned(series: [Double], reconstructed: [Double], usual: Double?) -> (obs: Double, hat: Double, index: Int)? {
        let n = max(series.count, reconstructed.count)
        guard n > 0 else {
            if let usual, let obs = series.last(where: { $0.isFinite }) { return (obs, usual, series.count - 1) }
            return nil
        }
        var i = n - 1
        while i >= 0 {
            let obs = i < series.count && series[i].isFinite ? series[i] : nil
            let hat = i < reconstructed.count && reconstructed[i].isFinite ? reconstructed[i] : nil
            if let obs, let hat { return (obs, hat, i) }
            if let obs, let usual { return (obs, usual, i) }
            i -= 1
        }
        return nil
    }

    static func emptyRow(id: String, name: String, caption: String, minSpan: Double, whoop5: Bool,
                         fahrenheit: Bool = false) -> MetricRow {
        let span = (id == "temp" && fahrenheit) ? minSpan * 9.0 / 5.0 : minSpan
        let half = rangeHalf(for: id) * ((id == "temp" && fahrenheit) ? 9.0 / 5.0 : 1)
        return MetricRow(id: id, name: name, now: "—", expected: "—", status: "—",
                  tone: StrandPalette.textTertiary, series: [], reconstructed: [],
                  usualValue: nil, windowCaption: caption, minSpan: span,
                  decimals: decimals(for: id), rangeHalf: half, rangeSeries: [],
                  pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
    }

    static func rangeHalf(for id: String) -> Double {
        let scale: Double
        switch id {
        case "hr", "rhr": scale = WatchdogConfig.hrScale
        case "hrv": scale = WatchdogConfig.hrvScale
        case "temp": scale = WatchdogConfig.tempScale
        case "resp": scale = WatchdogConfig.respScale
        case "spo2": scale = WatchdogConfig.spo2Scale
        default: scale = 1
        }
        return scale * WatchdogConfig.tau
    }

    /// Live HR/RR cadence from the strap. WHOOP 4 ~1 Hz (2A37); 5/MG ~30 s. Other vitals are held or sparse.
    static func whoopReadSeconds(id: String, whoop5: Bool) -> Double {
        switch id {
        case "hr", "rhr", "hrv":
            return whoop5 ? 30 : 1
        default:
            return 0
        }
    }

    static func decimals(for id: String) -> Int { id == "temp" ? 1 : 0 }

    static func trustCaption(_ result: WatchdogResult) -> String? {
        if result.unavailable != nil { return nil }
        if result.trustPct < 35 { return "Call is weak until more usuals land." }
        if !result.contributing.isEmpty { return "Trust is for this off call, not a diagnosis." }
        return "This stretch matches the reconstructed usual."
    }

    static func headline(_ result: WatchdogResult) -> String {
        if result.earlyFlag && result.severity != .severe && result.severity != .active {
            return "Leaving the expected path"
        }
        if let reason = result.unavailable {
            switch reason {
            case .wristOff: return "Strap off"
            case .stale: return "Reading went stale"
            case .coverage, .gap, .empty: return "Waiting on a reading"
            }
        }
        switch result.episodeState {
        case .recovering: return "Settling back"
        case .resolved: return "Looks like you again"
        case .dataUnavailable: return "Waiting on a reading"
        case .candidate:
            return result.severity == .candidate ? "A pattern is forming" : "One odd reading"
        case .active:
            return result.severity == .severe ? "Far from your usual" : "Unlike your usual"
        case .withinLimits:
            return result.severity == .note ? "One reading a bit off" : "Looks like you"
        }
    }

    static func waitingLabel(_ result: WatchdogResult) -> String {
        result.unavailable == .wristOff ? "Off wrist" : "Waiting"
    }

    static func format(_ value: Double?, decimals: Int, unit: String) -> String {
        guard let value else { return "—" }
        let number = decimals == 0 ? String(format: "%.0f", value) : String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    static func ago(_ unix: Int) -> String {
        let seconds = Int(Date().timeIntervalSince1970) - unix
        if seconds < 45 { return "Just now" }
        if seconds < 120 { return "1 min ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}
