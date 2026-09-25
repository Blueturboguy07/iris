//
//  ModelPriceComparisonView.swift
//  leanring-buddy
//
//  The side-by-side under "How Iris answers": one row per route, each with
//  the model, the per-million-token prices as two thin bars, and the estimated
//  month as a third — all scaled against the largest value on screen so the
//  bars compare like with like. The assumption the estimate rests on and the
//  sources are printed underneath, because an estimate that hides what it
//  assumes is not one.
//
//  Every number comes from `ModelPriceComparisonStore` (publik's
//  `/api/iris/model-prices`). With it not loaded the view says the prices are
//  unavailable; it has no number of its own to fall back to.
//

import SwiftUI

struct ModelPriceComparisonView: View {
    @ObservedObject var store: ModelPriceComparisonStore
    /// The Iris model the picker is on ("claude-sonnet-4-6"), which decides
    /// the tier being compared.
    let irisModelName: String
    /// The route answering now. Nil means nothing is chosen yet, which the
    /// comparison shows as publik API — the default route.
    let selectedProvider: UsageProvider?

    @State private var isShowingSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What each option costs")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            switch store.loadState {
            case .notLoaded, .loading:
                Text("Loading prices…")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            case .unavailable:
                HStack(spacing: 8) {
                    Text("Prices are unavailable right now.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Button("Try again") { store.loadIfNeeded() }
                        .irisTextButton(fontSize: 10)
                }
            case .loaded(let comparison):
                if let level = comparison.level(forIrisModelName: irisModelName) {
                    comparisonRows(level: level)
                    footnotes(comparison: comparison, level: level)
                } else {
                    Text("Prices are unavailable right now.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
        .onAppear { store.loadIfNeeded() }
    }

    // MARK: - Rows

    private func comparisonRows(level: ModelPriceComparison.Level) -> some View {
        let largestPerMillion = level.options
            .flatMap { [$0.inputUsdPerMillion ?? 0, $0.outputUsdPerMillion ?? 0] }
            .max() ?? 0
        let largestMonthly = level.options.map(\.estimatedMonthlyUsd).max() ?? 0
        let highlightedProvider = (selectedProvider ?? .publikAPI).rawValue

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(level.options) { option in
                optionRow(
                    option: option,
                    isHighlighted: option.provider == highlightedProvider,
                    largestPerMillion: largestPerMillion,
                    largestMonthly: largestMonthly
                )
            }
        }
    }

    private func optionRow(
        option: ModelPriceComparison.Option,
        isHighlighted: Bool,
        largestPerMillion: Double,
        largestMonthly: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(option.label)
                    .font(.system(size: 11, weight: isHighlighted ? .semibold : .medium))
                    .foregroundColor(isHighlighted ? DS.Colors.ink : DS.Colors.textSecondary)
                Text(modelLine(option))
                    .font(.system(size: 9.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            if option.isBilledPerToken,
               let inputPerMillion = option.inputUsdPerMillion,
               let outputPerMillion = option.outputUsdPerMillion {
                priceBar(
                    caption: "In",
                    valueText: "\(dollars(inputPerMillion)) / 1M",
                    fraction: fraction(inputPerMillion, of: largestPerMillion),
                    isHighlighted: isHighlighted
                )
                priceBar(
                    caption: "Out",
                    valueText: "\(dollars(outputPerMillion)) / 1M",
                    fraction: fraction(outputPerMillion, of: largestPerMillion),
                    isHighlighted: isHighlighted
                )
                priceBar(
                    caption: "Month",
                    valueText: "≈ \(dollars(option.estimatedMonthlyUsd))",
                    fraction: fraction(option.estimatedMonthlyUsd, of: largestMonthly),
                    isHighlighted: isHighlighted
                )
            } else {
                priceBar(
                    caption: "Month",
                    valueText: "\(dollars(option.estimatedMonthlyUsd)) flat",
                    fraction: fraction(option.estimatedMonthlyUsd, of: largestMonthly),
                    isHighlighted: isHighlighted
                )
            }

            Text(option.note)
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isHighlighted ? DS.Colors.accentSubtle : DS.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .strokeBorder(isHighlighted ? DS.Colors.accent.opacity(0.35) : DS.Colors.line, lineWidth: 1)
        )
    }

    /// One labelled horizontal bar. Width is the value's share of the largest
    /// value of the same kind in this comparison.
    private func priceBar(caption: String, valueText: String, fraction: Double, isHighlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 34, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.Colors.line)
                    Capsule()
                        .fill(isHighlighted ? DS.Colors.accent : DS.Colors.textTertiary)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 5)

            Text(valueText)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .monospacedDigit()
                .frame(width: 74, alignment: .trailing)
        }
    }

    // MARK: - Footnotes

    private func footnotes(comparison: ModelPriceComparison, level: ModelPriceComparison.Level) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comparison.assumption.summary)
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(comparison.caveat)
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button(isShowingSources ? "Hide sources" : "Sources") {
                isShowingSources.toggle()
                NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
            }
            .irisTextButton(fontSize: 9)

            if isShowingSources {
                ForEach(level.options) { option in
                    Text("\(option.label): \(option.source)")
                        .font(.system(size: 8.5))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Formatting

    private func modelLine(_ option: ModelPriceComparison.Option) -> String {
        if let servedBy = option.servedBy, servedBy != option.model {
            return "\(option.model) · \(servedBy) answers"
        }
        return option.model
    }

    private func fraction(_ value: Double, of largest: Double) -> Double {
        guard largest > 0, value.isFinite else { return 0 }
        return min(1, max(0, value / largest))
    }

    private func dollars(_ value: Double) -> String {
        if value > 0 && value < 0.1 {
            return String(format: "$%.3f", value)
        }
        return String(format: "$%.2f", value)
    }
}
