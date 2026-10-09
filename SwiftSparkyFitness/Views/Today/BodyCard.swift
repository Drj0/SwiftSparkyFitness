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
//  logged the same way as before (the FAB's "Log Measurements" choice
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
    /// The day on screen — what "3 days ago" and the two-week rule are
    /// measured from, so a past day reads relative to itself.
    var referenceDate = Date()

    /// An older weight keeps standing in for two weeks; after that the card
    /// still shows it, but asks for a fresh one.
    static let staleAfterDays = 14

    private var displayWeight: Double? {
        measurements.weight ?? lastLoggedWeight?.value
    }

    private var isShowingStaleWeight: Bool {
        measurements.weight == nil && lastLoggedWeight != nil
    }

    private var staleCaption: String? {
        guard isShowingStaleWeight, let date = lastLoggedWeight?.date else { return nil }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
    }

    /// Shared: the caption is read twice per render, and Today re-renders
    /// this card on every change of its own.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var needsUpdate: Bool {
        guard isShowingStaleWeight, let date = lastLoggedWeight?.date else { return false }
        return Self.needsUpdate(loggedOn: date, viewing: referenceDate)
    }

    /// Up to and including day 14 the old weight stands; from day 15 it asks.
    static func needsUpdate(loggedOn date: Date, viewing day: Date) -> Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: day)).day ?? 0
        return days > staleAfterDays
    }

    var body: some View {
        Button(action: onLogWeight) {
            TodayStatTile(
                title: "Weight", symbol: "scalemass.fill", tint: AppColor.accent,
                value: displayWeight.map(preferences.formatted) ?? "Not set",
                valueIsEmpty: displayWeight == nil,
                unit: displayWeight == nil ? "" : preferences.weightUnitLabel,
                caption: caption,
                captionIsAction: displayWeight == nil || needsUpdate
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
        if displayWeight == nil { return "Log weight →" }
        if needsUpdate { return "Time to update →" }
        if let staleCaption { return "Logged \(staleCaption)" }
        return "Tap to update"
    }

    private var accessibilityValue: String {
        guard let displayWeight else { return "Not logged" }
        let base = "\(preferences.formatted(displayWeight)) \(preferences.weightUnitLabel)"
        guard let staleCaption else { return base }
        return "\(base), logged \(staleCaption)" + (needsUpdate ? ", time to update" : "")
    }
}
