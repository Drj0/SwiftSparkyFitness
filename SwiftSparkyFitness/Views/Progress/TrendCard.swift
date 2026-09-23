//
//  TrendCard.swift
//  SwiftSparkyFitness
//
//  The shared chrome every Progress card sits in, plus the two states a
//  chart needs before it can draw anything.
//
//  The card recipe (surface + hairline overlay + clip) is the one
//  `DailySummaryCard` and `BodyCard` already use, repeated here rather than
//  generalised into a modifier because those two predate this and changing
//  them is Module 1-5 territory.
//

import SwiftUI

struct TrendCard<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Shown right-aligned against the title — a headline figure for the
    /// range, where one makes sense.
    var accessory: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                    if let subtitle {
                        Text(subtitle)
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if let accessory {
                    accessory
                }
            }
            content
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

/// What a card shows when the range holds nothing to chart.
///
/// Deliberately not an error: an empty range is a normal answer for a new
/// account or a quiet week, and dressing it as a failure would send people
/// looking for a problem that isn't there.
struct TrendEmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .appBody(13)
            .foregroundStyle(AppColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
    }
}

/// A single reading can't be a trend line, so it is reported as a value
/// instead of drawn as a one-point chart — which renders as an empty plot
/// area and reads as a bug.
struct TrendSinglePoint: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .appDisplay(24)
                .foregroundStyle(AppColor.ink)
            Text(caption)
                .appBody(12)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The figure shown top-right of a card: a number and its unit, sized so it
/// reads as the card's headline without competing with the screen title.
struct TrendStat: View {
    let value: String
    var label: String?
    var tint: Color = AppColor.ink

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .appBody(17, weight: .semibold)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let label {
                Text(label)
                    .appBody(11)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
