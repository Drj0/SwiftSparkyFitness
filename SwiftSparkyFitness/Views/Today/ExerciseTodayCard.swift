//
//  ExerciseTodayCard.swift
//  SwiftSparkyFitness
//
//  Today's exercise total, sitting beside BodyCard the same way the design
//  pairs a Weight card and an Exercise card under the Water card. Mirrors
//  BodyCard's shape deliberately (label row, then the day's headline number)
//  so the two read as one family rather than two different card idioms.
//

import SwiftUI

struct ExerciseTodayCard: View {
    let durationMinutes: Double
    let caloriesBurned: Double
    let hasLogged: Bool
    /// False while Today is showing a past day from the week strip.
    var isToday = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            TodayStatTile(
                title: "Exercise", symbol: "figure.run", tint: AppColor.energy,
                // A real zero, not a dash: "0 min" is a true fact about the
                // day, and the prompt under it says what to do about it.
                value: hasLogged ? "\(Int(durationMinutes.rounded()))" : "0",
                valueIsEmpty: !hasLogged,
                unit: "min",
                caption: hasLogged ? "−\(Int(caloriesBurned.rounded())) kcal burned" : "Log a workout →",
                captionIsAction: !hasLogged
            )
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasLogged ? "Exercise" : isToday ? "Log today's exercise" : "Log exercise")
        .accessibilityValue(
            hasLogged
                ? "\(Int(durationMinutes.rounded())) minutes, \(Int(caloriesBurned.rounded())) calories burned"
                : "Not logged"
        )
    }
}

/// Today's steps from Apple Health, full width under Weight and Exercise.
/// Display only: steps never reach the server (see HealthKitService). The
/// caption explains the calorie figure: the balance counts Health's active
/// energy plus any logged exercise Health doesn't already contain.
struct StepsTodayCard: View {
    let steps: Int?
    /// Health's active energy as stored for the day, and the logged exercise
    /// that adds to it.
    let healthKilocalories: Double?
    let extraLoggedKilocalories: Double

    private var caption: String {
        guard let healthKilocalories else {
            return steps == nil ? "No steps from Health yet" : "From Apple Health"
        }
        let health = Int(healthKilocalories.rounded())
        guard extraLoggedKilocalories > 0 else { return "\(health) kcal active energy from Health" }
        return "Health \(health) kcal + \(Int(extraLoggedKilocalories.rounded())) kcal you logged"
    }

    var body: some View {
        TodayStatTile(
            title: "Steps", symbol: "figure.walk", tint: AppColor.energy,
            value: steps.map { $0.formatted() } ?? "—",
            valueIsEmpty: steps == nil,
            unit: "steps",
            caption: caption
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steps")
        .accessibilityValue(
            [steps.map { "\($0) steps" }, caption].compactMap { $0 }.joined(separator: ", ")
        )
    }
}

#Preview {
    HStack(spacing: 12) {
        ExerciseTodayCard(durationMinutes: 30, caloriesBurned: 180, hasLogged: true) {}
        ExerciseTodayCard(durationMinutes: 0, caloriesBurned: 0, hasLogged: false) {}
    }
    .padding()
    .background(AppColor.background)
}

/// The shared shell of Today's half-width Weight and Exercise cards. Every
/// state has the same three rows — title, value, caption — so the two cards match each other and don't change height when
/// something gets logged. The card fills whatever height its row gives it,
/// which is what keeps the pair level at large text sizes.
struct TodayStatTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    /// Greys the value out ("0 min", "Not set") while keeping its size, so
    /// an empty card is the same height as a filled one.
    var valueIsEmpty = false
    var unit = ""
    let caption: String
    /// "Log →" reads as an action (accent); everything else is a quiet fact.
    var captionIsAction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            CardTitle(title, symbol: symbol, tint: tint)
                .padding(.bottom, 6)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .appBody(22, weight: .bold)
                    .foregroundStyle(valueIsEmpty ? AppColor.placeholder : AppColor.ink)
                if !unit.isEmpty {
                    Text(unit)
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())

            Text(caption)
                .appBody(12, weight: captionIsAction ? .semibold : .regular)
                .foregroundStyle(captionIsAction ? AppColor.accent : AppColor.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .contentShape(Rectangle())
    }
}

/// A Today card's label: an SF Symbol in the card's colour beside the title
/// in ink. The symbol follows the title's size and weight, so the two stay
/// one line at every text size; only the icon carries colour, so the title
/// never competes with the number under it.
struct CardTitle: View {
    let title: String
    let symbol: String
    let tint: Color

    init(_ title: String, symbol: String, tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        // Capped: half-width beside a sibling, the title wraps mid-word
        // ("Weig" / "ht") at accessibility sizes otherwise.
        Label {
            Text(title).foregroundStyle(AppColor.ink)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .labelStyle(CardTitleLabelStyle())
        .appBody(13, weight: .semibold)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// Tighter than the default label spacing, which reads as two items at 13pt.
private struct CardTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}
