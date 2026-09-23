//
//  WaterViewModel.swift
//  SwiftSparkyFitness
//
//  Owns one day's water: the running total plus the three ways it changes
//  (a quick-add tap, an undo tap, an exact amount). Kept separate from
//  TodayViewModel so Today's water card and Diary's water section read the
//  same logic instead of two screens each doing their own arithmetic on a
//  daily-summary field.
//
//  The server returns authoritative totals from the quick-add POST itself,
//  so a tap doesn't need a follow-up GET — the number on screen after a tap
//  is the server's, not a local guess. The total moves optimistically first
//  (see `adjust`) and the server's answer reconciles it; waiting for the
//  round trip before showing anything made a tap feel like a dropped one.
//

import Foundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class WaterViewModel: ObservableObject {
    @Published private(set) var totalMl: Double = 0
    @Published private(set) var goalMl: Double = WaterViewModel.fallbackGoalMl
    @Published private(set) var entries: [WaterLogEntry] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    /// Used when the account has no usable water goal. Lives on
    /// `DailySummary.Goals` so the card and this view model can't disagree —
    /// and so both get the "a cleared goal is 0, not null" rule.
    static let fallbackGoalMl: Double = DailySummary.Goals.fallbackWaterGoalMl

    private(set) var date: Date
    private let apiClient: APIClientProtocol

    init(date: Date = Date(), apiClient: APIClientProtocol = APIClient.shared) {
        self.date = date
        self.apiClient = apiClient
    }

    /// The user's primary container, once loaded. Quick-add sends its id,
    /// because the server does **not** consult the primary on its own — with
    /// a 750 ml primary configured, a bare `change_drinks: 1` still logs the
    /// generic 250 ml (verified live). Without this the management screen
    /// would let someone set a container that then changed nothing.
    @Published private(set) var primaryContainer: WaterContainer?

    var mlPerDrink: Double {
        primaryContainer?.mlPerServing ?? Water.defaultMlPerDrink
    }

    /// What one tap adds, for the card's subtitle.
    var drinkLabel: String {
        guard let primaryContainer else { return "\(Int(Water.defaultMlPerDrink)) ml each" }
        return "\(primaryContainer.name) · \(Int(mlPerDrink.rounded())) ml"
    }

    /// Best-effort: a failure here just leaves quick-add on the server's
    /// default, which is what it did before containers existed.
    func loadPrimaryContainer() async {
        primaryContainer = (try? await apiClient.waterContainers())?.first { $0.isPrimary }
    }

    /// Whole drinks logged, for the "3 glasses · 250 ml each" label. Derived
    /// from the total rather than the entry count so a custom 300 ml amount
    /// doesn't read as a full glass.
    var wholeDrinks: Int { Int((totalMl / mlPerDrink).rounded(.down)) }

    var progress: Double {
        goalMl > 0 ? min(totalMl / goalMl, 1) : 0
    }

    /// How far past the goal, as a second lap of 0...1. The bar filled and
    /// stopped at 100% before, so a day at 2 litres and a day at 4 looked
    /// identical. Kept separate from `progress` rather than letting that
    /// exceed 1, because the base fill is a width and a width can't overflow.
    ///
    /// Drinking past a water goal is a good outcome, unlike eating past a
    /// calorie goal, so the card draws this in a deeper water tone rather
    /// than borrowing the calorie ring's red warning.
    var overshoot: Double {
        guard goalMl > 0 else { return 0 }
        return min(max(0, totalMl / goalMl - 1), 1)
    }

    /// Only hand-logged water can be undone — the server's decrement only
    /// removes `source = 'manual'` ledger rows, so the control is disabled
    /// when there are none rather than tapping to no effect.
    ///
    /// Deliberately not gated on `isBusy` any more: the stepper applies its
    /// taps optimistically, so `manualMl` already reflects every tap in
    /// flight and disabling for the round trip only threw taps away.
    @Published private(set) var manualMl: Double = 0
    var canUndo: Bool { manualMl > 0 }

    /// Water derived from food, when the user has opted into
    /// `add_food_water_to_intake`. Shown separately because it isn't in the
    /// ledger and can't be deleted from here.
    @Published private(set) var foodMl: Double = 0

    /// Seeds the total from a daily summary the caller already fetched,
    /// avoiding a second round-trip for a number Today/Diary just loaded.
    func adopt(summary: DailySummary) {
        totalMl = summary.waterIntake
        goalMl = summary.goals.effectiveWaterGoalMl
        manualMl = summary.waterIntakeBreakdown?.manualMl ?? summary.waterIntake
        foodMl = summary.waterIntakeBreakdown?.foodMl ?? 0
    }

    func setDate(_ newDate: Date) {
        date = newDate
    }

    /// The card and the custom-amount sheet share this view model, so a
    /// failure from a quick-add would otherwise greet the user as a banner
    /// the moment they opened the sheet. Called when the sheet appears.
    func clearError() {
        errorMessage = nil
    }

    /// Loads the itemised ledger — only Diary needs it (Today shows a total
    /// and a stepper), so it's a separate call from `adopt`.
    func loadEntries() async {
        do {
            entries = try await apiClient.waterLog(date: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ totals: WaterTotals) {
        totalMl = totals.waterMl
        manualMl = totals.manualMl
        foodMl = totals.foodMl
    }

    /// Taps applied to the total but not yet acknowledged by the server, and
    /// whether a send loop is already draining them.
    private var unsentDrinks = 0
    private var isSendingDrinks = false

    /// Quick-add (`drinks > 0`) and undo (`drinks < 0`). The server clamps
    /// at zero and no-ops on an empty day — verified live — so there's no
    /// pre-check here beyond disabling the control.
    ///
    /// The tap lands on the displayed total immediately and the server's
    /// answer reconciles it. Before this, `isBusy` disabled both steppers for
    /// the whole round trip: a second tap within ~300 ms was simply dropped,
    /// and the total then jumped by one drink instead of two. Taps that
    /// arrive mid-flight are coalesced into the next call rather than queued
    /// as separate round trips, so a flurry of five is one extra request.
    func adjust(drinks: Int) async {
        errorMessage = nil
        applyOptimistic(drinks: drinks)
        unsentDrinks += drinks

        guard !isSendingDrinks else { return }
        isSendingDrinks = true
        defer { isSendingDrinks = false }

        while unsentDrinks != 0 {
            let batch = unsentDrinks
            unsentDrinks = 0
            do {
                // Only an *addition* names a container. The decrement deletes
                // the most recent manual rows whatever they were logged from,
                // so naming one there would imply a precision it doesn't have.
                apply(try await apiClient.adjustWater(
                    date: date,
                    drinks: batch,
                    containerId: batch > 0 ? primaryContainer?.id : nil
                ))
                // The server's total predates anything tapped while the call
                // was in flight, so those taps have to go back on top of it
                // or the number would visibly fall back mid-flurry.
                if unsentDrinks != 0 {
                    applyOptimistic(drinks: unsentDrinks)
                }
            } catch {
                // Nothing was accepted, so take back every tap still
                // unacknowledged: this batch and whatever queued behind it.
                applyOptimistic(drinks: -(batch + unsentDrinks))
                unsentDrinks = 0
                errorMessage = error.localizedDescription
                Haptics.error()
                return
            }
        }
    }

    /// Moves the displayed total by a number of drinks ahead of the server.
    /// Clamped at zero the same way the server clamps, so an over-eager "−"
    /// can't show a negative total for the length of a round trip.
    private func applyOptimistic(drinks: Int) {
        guard drinks != 0 else { return }
        let delta = Double(drinks) * mlPerDrink
        let total = max(0, totalMl + delta)
        let manual = max(0, manualMl + delta)
        // Reduce Motion isn't readable from the environment here, so this
        // asks UIKit for the same setting SwiftUI's accessibilityReduceMotion
        // reflects.
        let animation: Animation? = UIAccessibility.isReduceMotionEnabled
            ? nil : .spring(response: 0.4, dampingFraction: 0.8)
        withAnimation(animation) {
            totalMl = total
            manualMl = manual
        }
    }

    @discardableResult
    /// `isBusy` still gates this one — unlike the stepper, a double-tap on
    /// Add is a duplicate write rather than a second drink the user meant.
    ///
    /// It does now reconcile with the stepper, though. The two write paths
    /// are independent, so a "+" tapped while this was in flight used to be
    /// swallowed: this call's response carries the server's total from
    /// *before* that tap, and applying it plainly overwrote the optimistic
    /// one. Re-applying whatever is still unsent is the same correction the
    /// stepper's own send loop makes.
    func logExactAmount(_ milliliters: Double) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            apply(try await apiClient.logWaterAmount(date: date, milliliters: milliliters))
            if unsentDrinks != 0 {
                applyOptimistic(drinks: unsentDrinks)
            }
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func delete(_ entry: WaterLogEntry) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await apiClient.deleteWaterLogEntry(id: entry.id)
            // The delete response is just an ack, so re-read the two things
            // that changed rather than subtracting locally and drifting.
            entries = try await apiClient.waterLog(date: date)
            apply(try await apiClient.waterTotals(date: date))
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
