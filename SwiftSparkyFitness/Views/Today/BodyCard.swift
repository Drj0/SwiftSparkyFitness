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
            TodayStatTile(
                title: "⚖️ Weight",
                value: displayWeight.map(preferences.formatted),
                unit: preferences.weightUnitLabel,
                caption: caption,
                captionIsAction: displayWeight == nil
            )
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayWeight == nil ? (isToday ? "Log today's weight" : "Log weight") : "Weight")
        .accessibilityValue(accessibilityValue)
    }

    /// An older weight standing in for today's says so — the one job of this
    /// line is to stop it being mistaken for today's figure.
    private var caption: String {
        if displayWeight == nil { return isToday ? "Log today's →" : "Log →" }
        if let staleCaption { return "Logged \(staleCaption)" }
        return "Tap to update"
    }

    private var accessibilityValue: String {
        guard let displayWeight else { return "Not logged" }
        let base = "\(preferences.formatted(displayWeight)) \(preferences.weightUnitLabel)"
        guard let staleCaption else { return base }
        return "\(base), logged \(staleCaption)"
    }
}
