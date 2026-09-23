//
//  DailySummaryCard.swift
//  SwiftSparkyFitness
//
//  The ring + macro-totals block from the Today screen, extracted so Diary
//  (Module 3) can show the exact same daily summary for whatever date it's
//  viewing instead of rebuilding it — same visual, same math, one place to
//  fix if either ever needs to change.
//

import SwiftUI

struct DailySummaryCard: View {
    let summary: DailySummary
    let macroTotals: (protein: Double, carbs: Double, fat: Double)
    /// Module 4: water can now change without the summary being re-fetched
    /// (a quick-add tap answers with authoritative totals of its own), so
    /// the water ring reads this live value when one is supplied rather than
    /// the summary's decoded — and by then stale — field. Defaults to nil so
    /// every existing call site is unaffected.
    var waterMl: Double? = nil

    var body: some View {
        VStack(spacing: 14) {
            ring
            macroRow
        }
    }

    /// Summed from the same entries the meal list renders, rather than read
    /// from `calorieBalance.eaten`.
    ///
    /// The server re-applies `quantity / serving_size` to the already-scaled
    /// `calories` the app writes, so its total is only correct when the
    /// logged quantity happens to equal one base serving. Verified live: 50 g
    /// of a 100 g / 200 kcal food (truth 100 kcal) returns `eaten: 50` while
    /// the entries sum to 100 — so the hero number contradicted the list
    /// directly beneath it for any part portion. Summing locally keeps the
    /// screen internally consistent and doesn't depend on fixing the server.
    private var eaten: Double {
        summary.foodEntries.reduce(0) { $0 + $1.calories }
    }

    private var remaining: Double {
        summary.calorieBalance.goal - eaten + summary.calorieBalance.burned
    }

    private var ring: some View {
        let goal = summary.calorieBalance.goal
        let energyGoal = max(goal * 0.15, 1)
        let waterGoal = summary.goals.effectiveWaterGoalMl
        let isOver = remaining < 0
        let water = waterMl ?? summary.waterIntake

        return RingCard {
            RingChart(layers: [
                RingLayer(progress: eaten / max(goal, 1), color: AppColor.accent),
                RingLayer(progress: summary.calorieBalance.burned / energyGoal, color: AppColor.energyGraphic),
                RingLayer(progress: water / waterGoal, color: AppColor.water),
            ], accessibilityDescription: ringDescription(eaten: eaten, goal: goal, water: water, waterGoal: waterGoal)) {
                VStack(spacing: 2) {
                    Text("\(abs(Int(remaining)))")
                        .appDisplay(34)
                        .foregroundStyle(isOver ? AppColor.destructive : AppColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    // Over-goal used to render identically to hitting it
                    // exactly (both clamped to "0 kcal left"), which is the
                    // one question a calorie tracker exists to answer.
                    Text(isOver ? "kcal over" : "kcal left")
                        .appBody(12)
                        .foregroundStyle(isOver ? AppColor.destructive : AppColor.secondaryText)
                    Text("\(Int(eaten)) eaten")
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                        .padding(.top, 3)
                }
                // Was a hard 116pt, which the text overflowed the moment
                // Dynamic Type grew it.
                .frame(maxWidth: 150)
                .padding(.horizontal, 6)
                // The ring is fixed geometry, so unlike the rest of the app
                // its centre label can't grow without spilling over the arcs.
                // Capped here rather than app-wide: everything outside the
                // ring still scales to the user's full setting, and the same
                // numbers are read out in full by VoiceOver and repeated in
                // the macro row below.
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
            RingLegend()
        }
    }

    /// The whole dashboard in one spoken sentence. Without it VoiceOver got
    /// arc length and colour — i.e. nothing — for active energy and water.
    private func ringDescription(eaten: Double, goal: Double, water: Double, waterGoal: Double) -> String {
        let burned = summary.calorieBalance.burned
        var parts = [
            "\(Int(eaten)) of \(Int(goal)) calories eaten",
            remaining < 0 ? "\(Int(abs(remaining))) over" : "\(Int(remaining)) remaining",
        ]
        if burned > 0 { parts.append("active energy \(Int(burned)) calories") }
        parts.append("water \(Int(water)) of \(Int(waterGoal)) millilitres")
        return parts.joined(separator: ", ") + "."
    }

    /// Three columns side by side until Dynamic Type makes them too narrow to
    /// hold their own labels ("Protein" wrapping to "Protei/n"), then one per
    /// row. `ViewThatFits` picks whichever still fits, so nothing is clamped
    /// for users at normal sizes.
    private var macroRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                macroColumn("\(Int(macroTotals.protein))g", "Protein", AppColor.accent)
                macroDivider
                macroColumn("\(Int(macroTotals.carbs))g", "Carbs", AppColor.carbs)
                macroDivider
                macroColumn("\(Int(macroTotals.fat))g", "Fat", AppColor.energy)
            }
            VStack(spacing: 10) {
                macroColumn("\(Int(macroTotals.protein))g", "Protein", AppColor.accent)
                macroColumn("\(Int(macroTotals.carbs))g", "Carbs", AppColor.carbs)
                macroColumn("\(Int(macroTotals.fat))g", "Fat", AppColor.energy)
            }
        }
        .padding(.vertical, 14)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// `Divider()` paints the system separator — a cool translucent grey that
    /// reads visibly colder than every other rule in this warm palette. Inset
    /// so it doesn't run into the card's rounded corners.
    private var macroDivider: some View {
        Rectangle().fill(AppColor.hairline).frame(width: 1).padding(.vertical, 4)
    }

    private func macroColumn(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).appBody(15, weight: .bold).foregroundStyle(color)
            Text(label).appBody(11).foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        // Value and label were two separate VoiceOver stops, read in the
        // wrong order — six swipes for three numbers.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct RingCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 10) {
            content
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

struct RingLegend: View {
    var body: some View {
        // One row while the three fit; stacked once Dynamic Type breaks the
        // labels mid-word ("Calori/es"). Hidden from VoiceOver because the
        // ring itself now carries all three values in its accessibilityValue,
        // so reading the legend too would just repeat the colour names.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                legendItem("Calories", AppColor.accent)
                legendItem("Active energy", AppColor.energyGraphic)
                legendItem("Water", AppColor.water)
            }
            VStack(alignment: .leading, spacing: 6) {
                legendItem("Calories", AppColor.accent)
                legendItem("Active energy", AppColor.energyGraphic)
                legendItem("Water", AppColor.water)
            }
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).appBody(12).foregroundStyle(AppColor.secondaryText).fixedSize()
        }
    }
}
