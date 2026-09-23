//
//  TodayView.swift
//  SwiftSparkyFitness
//
//  Three states from the design: populated, first-run/empty (goal set), and
//  goal-not-set. "Populated" vs "empty" share the same ring (zero progress
//  naturally looks empty) and differ only in the content below/around it.
//

import SwiftUI

struct TodayView: View {
    let user: SessionUser
    @StateObject private var viewModel = TodayViewModel()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: Date())
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Today")
                        .appDisplay(26)
                        .foregroundStyle(AppColor.ink)
                    Text(dateLabel)
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    if viewModel.isLoading && viewModel.summary == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if let summary = viewModel.summary {
                        if !viewModel.hasGoalSet {
                            GoalNotSetCard { viewModel.isPresentingSetGoals = true }
                        } else if viewModel.hasLoggedAnything {
                            populated(summary)
                        } else {
                            firstRun(summary)
                        }
                        // Water and weight are day-level widgets, not
                        // decoration under the food list: they render in
                        // every state, otherwise there'd be no way to log
                        // water on a day with nothing else on it — and, with
                        // no goal set, no way to log anything at all.
                        statRow()
                    } else if let errorMessage = viewModel.errorMessage {
                        loadErrorState(errorMessage)
                    }
                }
                .padding(AppSpacing.screenPad)
                // The FAB floats over the scroll content, so the last card
                // needs room to clear it — without this it sits on top of
                // the Weight card and fully covers Dinner's "+".
                .padding(.bottom, 76)
            }
            .refreshable { await viewModel.load() }

            // Logging must work regardless of whether a goal is set: gating
            // the FAB on hasGoalSet left a goal-less account with no way to
            // log anything anywhere in the app.
            LogFAB { viewModel.isPresentingLogChoice = true }
                .padding(.trailing, 20)
                .padding(.bottom, 18)
        }
        .background(AppColor.background)
        .task { await viewModel.load() }
        .sheet(isPresented: $viewModel.isPresentingLogChoice, onDismiss: {
            switch viewModel.pendingLogTarget {
            case .food: viewModel.isPresentingFoodSearch = true
            case .exercise: viewModel.isPresentingLogExercise = true
            case .weight: viewModel.isPresentingLogWeight = true
            case .measurements: viewModel.isPresentingLogMeasurements = true
            case nil: break
            }
            viewModel.pendingLogTarget = nil
        }) {
            LogChoiceSheet { target in
                viewModel.pendingLogTarget = target
                viewModel.isPresentingLogChoice = false
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $viewModel.isPresentingFoodSearch, onDismiss: {
            viewModel.pendingMealType = nil
            Task { await viewModel.load() }
        }) {
            FoodSearchView(mealTypes: viewModel.loggableMealTypes, initialMealType: viewModel.pendingMealType)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.isPresentingLogExercise, onDismiss: { Task { await viewModel.load() } }) {
            LogExerciseView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.isPresentingWaterAmount) {
            LogWaterAmountView(viewModel: viewModel.water)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.isPresentingLogWeight) {
            bodySheet(kind: .weight)
        }
        .sheet(isPresented: $viewModel.isPresentingLogMeasurements) {
            bodySheet(kind: .measurements)
        }
        .sheet(isPresented: $viewModel.isPresentingSetGoals) {
            SetGoalsView {
                Task { await viewModel.load() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Both body sheets are bounded like Diary's date navigation — you can
    /// back-date a weight to a day the account existed for, but not before
    /// it existed and not into the future.
    private func bodySheet(kind: LogBodyViewModel.Kind) -> some View {
        let maxDate = Calendar.current.startOfDay(for: Date())
        let minDate = min(Calendar.current.startOfDay(for: user.createdAt ?? Date()), maxDate)
        return LogBodyView(
            kind: kind, date: maxDate,
            existing: viewModel.bodyMeasurements,
            preferences: viewModel.preferences,
            minDate: minDate, maxDate: maxDate
        ) {
            Task { await viewModel.reloadBodyMeasurements() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func populated(_ summary: DailySummary) -> some View {
        DailySummaryCard(summary: summary, macroTotals: viewModel.macroTotals, waterMl: viewModel.water.totalMl)

        ForEach(viewModel.entriesByMeal, id: \.mealType.id) { group in
            mealSection(group.mealType, group.entries)
        }
    }

    private func loadErrorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            ErrorBanner(message: message)
            PrimaryButton(title: "Retry") {
                Task { await viewModel.load() }
            }
        }
        .padding(.top, 40)
    }

    @ViewBuilder
    private func firstRun(_ summary: DailySummary) -> some View {
        RingCard {
            RingChart(layers: [
                RingLayer(progress: 0, color: AppColor.accent),
                RingLayer(progress: 0, color: AppColor.energy),
                RingLayer(progress: 0, color: AppColor.water),
            ], diameter: 190) {
                VStack(spacing: 2) {
                    Text("\(Int(summary.calorieBalance.goal))")
                        .appDisplay(28)
                        .foregroundStyle(AppColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("kcal goal")
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .frame(maxWidth: 120)
                // Same reason as DailySummaryCard's centre: the ring is fixed
                // geometry, so its label has to stop growing before it spills
                // over the arcs.
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
            Text("Nothing logged yet today")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("\u{201C}Let's get your first bite on the board.\u{201D}")
                .appDisplay(16).italic()
                .foregroundStyle(AppColor.sparkyQuote)
            Text("Sparky")
                .appBody(12)
                .foregroundStyle(AppColor.sparkyQuote.opacity(0.75))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))

        PrimaryButton(title: "Log your first food") {
            viewModel.isPresentingFoodSearch = true
        }
    }

    private func mealSection(_ mealType: MealType, _ entries: [FoodEntrySummary]) -> some View {
        let total = entries.reduce(0) { $0 + $1.calories }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(mealType.name.capitalized) · \(Int(total)) kcal")
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .textCase(.uppercase)
                    // The total changes under the user the moment a food
                    // sheet dismisses; rolling the digits shows *which*
                    // number moved instead of silently swapping it.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: total)
                Spacer()
                Button {
                    viewModel.pendingMealType = mealType
                    viewModel.isPresentingFoodSearch = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                        .frame(width: 20, height: 20)
                        .background(AppColor.accentSoft, in: Circle())
                        // 20pt glyph, 44pt target. The negative padding hands
                        // the 24pt of growth back to the layout so the four
                        // meal headers don't each gain a row's worth of
                        // height, and the "+" stays flush with the card edge.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -12)
                        .padding(.vertical, -12)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Add food to \(mealType.name.capitalized)")
            }
            if entries.isEmpty {
                Text("Not logged yet")
                    .appBody(13)
                    .foregroundStyle(AppColor.placeholder)
                    .padding(.bottom, 6)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.foodName).appBody(15, weight: .semibold).foregroundStyle(AppColor.ink)
                            Text("\(Int(entry.quantity))\(entry.unit)").appBody(12).foregroundStyle(AppColor.secondaryText)
                        }
                        Spacer()
                        Text("\(Int(entry.calories))").appBody(14, weight: .semibold).foregroundStyle(AppColor.ink)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppColor.surface)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColor.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    // Three VoiceOver stops per food — name, portion, and a
                    // bare number with no unit ("142") that gave no clue it
                    // was calories. One stop, one sentence.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.foodName), \(Int(entry.quantity))\(entry.unit)")
                    .accessibilityValue("\(Int(entry.calories)) calories")
                }
            }
        }
    }

    /// Water and weight. Both were read-only stubs until Module 4: water
    /// showed a total derived by dividing by 240 (a figure that exists
    /// nowhere on the server), weight said "Log today's →" and did nothing.
    @ViewBuilder
    private func statRow() -> some View {
        WaterCard(viewModel: viewModel.water) {
            viewModel.isPresentingWaterAmount = true
        }

        BodyCard(
            measurements: viewModel.bodyMeasurements,
            preferences: viewModel.preferences,
            onLogWeight: { viewModel.isPresentingLogWeight = true },
            onLogMeasurements: { viewModel.isPresentingLogMeasurements = true }
        )
    }
}

private struct GoalNotSetCard: View {
    let onSetGoal: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            GoalNotSetRing()
                .padding(.top, 10)
            PrimaryButton(title: "Set daily calorie goal", action: onSetGoal)
        }
        .padding(20)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(AppColor.dashedBorder))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

private struct LogChoiceSheet: View {
    let onSelect: (LogTarget) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Capsule().fill(AppColor.hairline).frame(width: 44, height: 5).padding(.top, 10)
            Text("Log").appDisplay(18).foregroundStyle(AppColor.ink).padding(.top, 4)

            choiceRow(icon: "fork.knife", title: "Log Food") { onSelect(.food) }
            choiceRow(icon: "figure.run", title: "Log Exercise") { onSelect(.exercise) }
            // Water isn't here: it's one tap on the card itself, and burying
            // a one-tap action two sheets deep would be slower than the stub
            // it replaced.
            choiceRow(icon: "scalemass", title: "Log Weight") { onSelect(.weight) }
            choiceRow(icon: "ruler", title: "Body Measurements") { onSelect(.measurements) }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .background(AppColor.surface)
    }

    private func choiceRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 36, height: 36)
                    .background(AppColor.accentSoft, in: Circle())
                    // The row's title already says what this does; left
                    // visible to VoiceOver the symbol read its own name out
                    // loud first — "Scale For Weighing Mass, Log Weight".
                    .accessibilityHidden(true)
                Text(title).appBody(16, weight: .semibold).foregroundStyle(AppColor.ink)
                Spacer()
            }
            .padding(.vertical, 10)
        }
    }
}

private struct LogFAB: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(AppColor.accent, in: Circle())
                .shadow(color: AppColor.accent.opacity(0.4), radius: 12, y: 6)
        }
        .buttonStyle(.pressableCompact)
        // Announced as "Add" — identical to the four meal buttons above it,
        // with nothing to say what it adds.
        .accessibilityLabel("Log")
    }
}

#Preview {
    TodayView(user: SessionUser(email: "demo@sparkyfitness.com", name: "Demo"))
}
