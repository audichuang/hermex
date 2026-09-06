import SwiftUI

struct ModelBreakdownRow: View {
    let model: InsightsModelBreakdown
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var metricMinimumWidth = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.model ?? String(localized: "Unknown Model"))
                .font(.subheadline)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible(), alignment: .leading)]
                    : [GridItem(.adaptive(minimum: metricMinimumWidth), alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                Text("\(formatTokens(model.totalTokens ?? tokenTotal)) tokens")
                Text("\(model.sessions ?? 0) sessions")

                if let cost = model.cost, cost > 0 {
                    Text(cost.formattedCost())
                }

                if let share = model.displayShare {
                    Text("\(share)% share")
                }

                if let cacheHitPercent = model.cacheHitPercent {
                    Text("\(insightsFormattedPercent(cacheHitPercent)) cache")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var tokenTotal: Int {
        (model.inputTokens ?? 0) + (model.outputTokens ?? 0)
    }
}

struct DailyTokenRow: View {
    let day: InsightsDailyToken
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var metricMinimumWidth = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.date ?? String(localized: "Unknown Date"))
                .font(.subheadline)
                .fontWeight(.medium)

            LazyVGrid(
                columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible(), alignment: .leading)]
                    : [GridItem(.adaptive(minimum: metricMinimumWidth), alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                Text("\(formatTokens(totalTokens)) tokens")
                Text("\(day.sessions ?? 0) sessions")

                if let cost = day.cost, cost > 0 {
                    Text(cost.formattedCost())
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var totalTokens: Int {
        (day.inputTokens ?? 0) + (day.outputTokens ?? 0)
    }
}

struct ActivitySummaryRow: View {
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private func formatTokens(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// Formats a server-reported 0–100 percentage (e.g. `cache_hit_percent`) with a
/// localized percent symbol and at most one fraction digit ("87.5%", "12%").
func insightsFormattedPercent(_ value: Double, locale: Locale = .current) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
}
