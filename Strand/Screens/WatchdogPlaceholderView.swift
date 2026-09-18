import SwiftUI
import StrandDesign

/// Placeholder until Watchdog is built. Lives under the longer usual on Baseline, not as its own tab.
struct WatchdogPlaceholderView: View {
    var embedded: Bool = false

    var body: some View {
        if embedded {
            embeddedCard
        } else {
            ScreenScaffold(
                title: "Watchdog",
                subtitle: "A later pass. Usuals live on Baseline.",
                topBackground: liquidScaffoldSky()
            ) {
                ComingSoon(
                    what: "Watchdog will watch nights that leave your usual without asking you to hunt for them.",
                    symbol: "eye.trianglebadge.exclamationmark"
                )
            }
        }
    }

    private var embeddedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watchdog")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Will watch nights that leave your usual. Placeholder for a later pass.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .fill(StrandPalette.surfaceInset.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watchdog. Placeholder for a later pass.")
    }
}
