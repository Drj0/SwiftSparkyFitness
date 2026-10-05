//
//  TodayHomeCards.swift
//  SwiftSparkyFitness
//
//  The home screen's week strip, single calorie ring and macro-goal card.
//  Today-only on purpose: Diary keeps the shared triple-ring
//  DailySummaryCard, so restyling home can't move anything there.
//

import SwiftUI

// MARK: - Week strip

/// Swipeable weeks, from the account's first week (the same floor Diary
/// uses) to this one, with the day on screen highlighted. Swiping only
/// browses; tapping a day opens it. Future days aren't tappable.
struct WeekStrip: View {
    /// The day on screen.
    let selected: Date
    let minDate: Date
    let onSelect: (Date) -> Void

    @State private var visibleWeek: Date?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let spokenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    private static func weekStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    /// Oldest first, so the natural swipe direction (right = back in time)
    /// matches every calendar strip on iOS.
    private var weeks: [Date] {
        let calendar = Calendar.current
        let current = Self.weekStart(Date())
        var week = Self.weekStart(minDate)
        var result: [Date] = []
        while week <= current {
            result.append(week)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { break }
            week = next
        }
        return result.isEmpty ? [current] : result
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(weeks, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { offset in
                            if let day = Calendar.current.date(byAdding: .day, value: offset, to: week) {
                                cell(day)
                            }
                        }
                    }
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $visibleWeek)
        .onAppear { visibleWeek = Self.weekStart(selected) }
        // A day picked from the calendar may sit in another week.
        .onChange(of: Self.weekStart(selected)) { _, week in
            withAnimation(reduceMotion ? nil : .snappy) { visibleWeek = week }
        }
        // Seven fixed columns: past this size the day numbers stop fitting
        // their pill. Same trade-off as the ring's centre label.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: selected)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func cell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(day)
        let isEnabled = day <= calendar.startOfDay(for: Date()) && day >= calendar.startOfDay(for: minDate)
        let letter = calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]

        let numberColor: Color = isSelected ? .white
            : !isEnabled ? AppColor.placeholder.opacity(0.7)
            : isToday ? AppColor.accent
            : AppColor.ink
        let letterColor: Color = isSelected ? .white.opacity(0.85)
            : !isEnabled ? AppColor.placeholder.opacity(0.7)
            : AppColor.secondaryText

        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: 5) {
                Text(letter)
                    .appBody(11, weight: .semibold)
                    .foregroundStyle(letterColor)
                Text("\(calendar.component(.day, from: day))")
                    .appBody(17, weight: .bold)
                    .foregroundStyle(numberColor)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: 46, minHeight: 56)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppColor.accent)
                        .matchedGeometryEffect(id: "selectedDay", in: highlight)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!isEnabled)
        .accessibilityLabel(Self.spokenFormatter.string(from: day) + (isToday ? ", today" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Calorie ring

/// One calorie arc with "kcal left" in the middle — the home screen's hero.
struct CalorieRingCard: View {
    let summary: DailySummary

    /// Summed from the entries, not `calorieBalance.eaten` — see
    /// DailySummaryCard.eaten for the server bug this sidesteps.
    private var eaten: Double { summary.foodEntries.reduce(0) { $0 + $1.calories } }
    private var goal: Double { summary.calorieBalance.goal }
    private var burned: Double { summary.calorieBalance.burned }
    private var remaining: Double { goal - eaten + burned }

    private var accessibilitySummary: String {
        var parts = [
            "\(Int(eaten.rounded())) of \(Int(goal.rounded())) calories eaten",
            remaining < 0 ? "\(Int(abs(remaining).rounded())) over" : "\(Int(remaining.rounded())) remaining",
        ]
        if burned > 0 { parts.append("\(Int(burned.rounded())) burned") }
        return parts.joined(separator: ", ") + "."
    }

    var body: some View {
        let isOver = remaining < 0

        RingChart(
            layers: [RingLayer(progress: eaten / max(goal, 1), color: AppColor.accent)],
            diameter: 196, trackWidth: 18,
            accessibilityDescription: accessibilitySummary
        ) {
            VStack(spacing: 2) {
                Text(abs(Int(remaining.rounded())).formatted())
                    .appDisplay(46)
                    .foregroundStyle(isOver ? AppColor.destructive : AppColor.ink)
                    .contentTransition(.numericText())
                // Over-goal must not read the same as hitting it exactly.
                Text(isOver ? "kcal over" : "kcal left")
                    .appBody(14)
                    .foregroundStyle(isOver ? AppColor.destructive : AppColor.secondaryText)
                Text("\(Int(eaten.rounded()).formatted()) / \(Int(goal.rounded()).formatted()) kcal")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
                    .padding(.top, 6)
                // "Left" includes exercise, so without this the three
                // numbers wouldn't add up whenever something was burned.
                if burned > 0 {
                    Text("+\(Int(burned.rounded()).formatted()) burned")
                        .appBody(12, weight: .semibold)
                        .foregroundStyle(AppColor.energy)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: 136)
            // Fixed ring geometry: the label has to stop growing before it
            // spills over the arc. VoiceOver reads the full numbers anyway.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
        // The arc's stroke is centred on the ring's frame, so half of it
        // (9pt) sits outside — the padding is measured from the stroke edge.
        .padding(.vertical, 36 + 9)
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - Macro goals

/// Protein / carbs / fat against their goals, each with a progress bar.
/// A macro with no goal shows its bare total over an empty track, so the
/// three columns always line up.
struct MacroGoalsCard: View {
    let totals: (protein: Double, carbs: Double, fat: Double)
    let goals: DailySummary.Goals

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { columns }
            VStack(spacing: 16) { columns }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    @ViewBuilder
    private var columns: some View {
        column("Protein", totals.protein, goals.protein, text: AppColor.accent, bar: AppColor.accent)
        column("Carbs", totals.carbs, goals.carbs, text: AppColor.carbs, bar: AppColor.carbsGraphic)
        column("Fat", totals.fat, goals.fat, text: AppColor.energy, bar: AppColor.energyGraphic)
    }

    private func column(_ label: String, _ value: Double, _ goal: Double?, text: Color, bar: Color) -> some View {
        let goal = (goal ?? 0) > 0 ? goal : nil
        let progress = goal.map { min(value / $0, 1) } ?? 0

        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(Int(value))")
                    .appBody(17, weight: .bold)
                    .foregroundStyle(text)
                Text(goal.map { "/\(Int($0))g" } ?? "g")
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text(label)
                .appBody(12)
                .foregroundStyle(AppColor.secondaryText)
            Capsule()
                .fill(AppColor.ringTrack)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(bar)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(goal.map { "\(Int(value)) of \(Int($0)) grams" } ?? "\(Int(value)) grams")
    }
}
