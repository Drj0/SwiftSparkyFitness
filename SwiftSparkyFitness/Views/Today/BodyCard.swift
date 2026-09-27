//
//  BodyCard.swift
//  SwiftSparkyFitness
//
//  Today's weight stub ("Log today's →", which went nowhere) made real.
//
//  Weight-only now, sized and shaped to match ExerciseTodayCard beside it —
//  measurement chips (waist/hips/neck/...) used to render here too, but
//  their variable count made this card grow taller than its sibling and,
//  at accessibility text sizes, overflow it. Measurements are still
//  logged the same way as before (the FAB's "Body Measurements" choice
//  opens the exact same sheet this card's own "+ Measurements" link used
//  to), just not surfaced in this compact a card.
//
//  If today has nothing logged, this shows the most recent weight from any
//  earlier day instead of a bare prompt — with a small "logged 3 days ago"
//  caption so it's never mistaken for today's — rather than making a fresh
//  user stare at "Log today's →" when they weighed in yesterday and the
//  number hasn't materially changed.
//

import SwiftUI

struct BodyCard: View {
    let measurements: BodyMeasurements
    /// The most recent day (before today) with a weight logged, if today
    /// itself has none. `nil` when today has a weight, or nothing has ever
    /// been logged.
    let lastLoggedWeight: (value: Double, date: Date)?
    let preferences: UserPreferences
    let onLogWeight: () -> Void
    /// False while Today is showing a past day from the week strip.
    var isToday = true

    private var displayWeight: Double? {
        measurements.weight ?? lastLoggedWeight?.value
    }

    private var isShowingStaleWeight: Bool {
        measurements.weight == nil && lastLoggedWeight != nil
    }

    private var staleCaption: String? {
        guard isShowingStaleWeight, let date = lastLoggedWeight?.date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Button(action: onLogWeight) {
            VStack(alignment: .leading, spacing: 10) {
                // Capped like the ring's centre label elsewhere in this app
                // (fixed geometry that shouldn't spill) — an uncapped
                // "⚖️ Weight" wraps mid-word ("Weig" / "ht") once this card
                // sits half-width beside ExerciseTodayCard at accessibility
                // text sizes.
                Text("⚖️ Weight")
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)

                if let displayWeight {
                    // Was a `Text + Text` concatenation, which can't take a
                    // view modifier — and the scaling font has to be one. An
                    // HStack on .firstTextBaseline keeps the identical look
                    // (unit sitting on the number's baseline) while letting
                    // both halves scale with Dynamic Type.
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(preferences.formatted(displayWeight))
                            .appBody(20, weight: .bold)
                            .foregroundStyle(AppColor.ink)
                        Text(" \(preferences.weightUnitLabel)")
                            .appBody(13)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    .contentTransition(.numericText())

                    // Small and out of the way on purpose — this is a
                    // fallback figure standing in for today's, and the one
                    // job of this line is to stop it being mistaken for one.
                    if let staleCaption {
                        Text("Logged \(staleCaption)")
                            .appBody(10)
                            .foregroundStyle(AppColor.placeholder)
                    }
                } else {
                    Text(isToday ? "Log today's →" : "Log →")
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayWeight == nil ? (isToday ? "Log today's weight" : "Log weight") : "Weight")
        .accessibilityValue(accessibilityValue)
        .padding(14)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var accessibilityValue: String {
        guard let displayWeight else { return "Not logged" }
        let base = "\(preferences.formatted(displayWeight)) \(preferences.weightUnitLabel)"
        guard let staleCaption else { return base }
        return "\(base), logged \(staleCaption)"
    }
}
