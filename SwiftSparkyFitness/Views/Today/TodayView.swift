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
        viewModel.today.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Today", or the weekday name while a past day from the strip is open.
    private var title: String {
        viewModel.isViewingToday ? "Today" : viewModel.today.formatted(.dateTime.weekday(.wide))
    }

    /// Same floor Diary uses: no days before the account existed.
    private var minDate: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return min(Calendar.current.startOfDay(for: user.createdAt ?? Date()), today)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .appDisplay(32)
                            .foregroundStyle(AppColor.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(dateLabel)
                            .appBody(14)
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    WeekStrip(selected: viewModel.today, minDate: minDate) { day in
                        Task { await viewModel.select(day: day) }
                    }
                    .padding(.bottom, 2)

                    if viewModel.isLoading && viewModel.summary == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if let summary = viewModel.summary {
                        Group {
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
                        }
                        // A newly picked day is still loading: dim the old
                        // one and block taps, since water and the sheets
                        // already point at the new day.
                        .opacity(viewModel.isSwitchingDay ? 0.4 : 1)
                        .allowsHitTesting(!viewModel.isSwitchingDay)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: viewModel.isSwitchingDay)
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
        .alert("Couldn't remove that", isPresented: Binding(
            get: { viewModel.deleteError != nil },
            set: { if !$0 { viewModel.deleteError = nil } }
        )) {
            Button("OK") { viewModel.deleteError = nil }
        } message: {
            Text(viewModel.deleteError ?? "")
        }
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
            FoodSearchView(mealTypes: viewModel.loggableMealTypes, initialMealType: viewModel.pendingMealType,
                           entryDate: viewModel.entryDate) {
                viewModel.isPresentingFoodSearch = false
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.isPresentingLogExercise, onDismiss: { Task { await viewModel.load() } }) {
            // Module 12: search-and-materialize now stands between "Log
            // Exercise" and the entry editor, since a logged entry has to
            // reference an exercise already in the user's own library.
            ExerciseSearchView(entryDate: viewModel.entryDate)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.isPresentingLogWeight) {
            bodySheet(kind: .weight)
        }
        .sheet(isPresented: $viewModel.isPresentingLogMeasurements) {
            bodySheet(kind: .measurements)
        }
        // Wrapped in a stack because the goals screen is a page now: it wears
        // a navigation title and puts Save in the toolbar, which needs a bar
        // to put them in. It still opens as a sheet from here — from a card
        // that says "no goal yet", setting one is an interruption, not a trip
        // to Settings — and the view adds its own Cancel when presented.
        .sheet(isPresented: $viewModel.isPresentingSetGoals) {
            NavigationStack {
                SetGoalsView(showsCancel: true) {
                    Task { await viewModel.load() }
                }
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
            kind: kind, date: min(Calendar.current.startOfDay(for: viewModel.entryDate), maxDate),
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
        CalorieRingCard(summary: summary)
        MacroGoalsCard(totals: viewModel.macroTotals, goals: summary.goals)

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
        CalorieRingCard(summary: summary)

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
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                // An empty meal is just its header, quieter and without a
                // "0 kcal" — no placeholder box taking up a row.
                Text(entries.isEmpty ? mealType.name.capitalized : "\(mealType.name.capitalized) · \(Int(total)) kcal")
                    .appBody(13, weight: .semibold)
                    .tracking(0.8)
                    .foregroundStyle(entries.isEmpty ? AppColor.placeholder : AppColor.secondaryText)
                    .textCase(.uppercase)
                    // The total changes under the user the moment a food
                    // sheet dismisses; rolling the digits shows *which*
                    // number moved instead of silently swapping it.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: total)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(entries.isEmpty ? "Nothing logged" : "")
                Spacer()
                Button {
                    viewModel.pendingMealType = mealType
                    viewModel.isPresentingFoodSearch = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                        .frame(width: 28, height: 28)
                        .background(AppColor.accentSoft, in: Circle())
                        // 28pt glyph, 44pt target. The negative padding hands
                        // the growth back to the layout so the meal headers
                        // don't each gain height, and the "+" stays flush
                        // with the card edge.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -8)
                        .padding(.vertical, -8)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Add food to \(mealType.name.capitalized)")
            }
            if !entries.isEmpty {
                // One grouped card per meal, rows split by inset hairlines —
                // reads as a single meal rather than a stack of loose foods.
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(AppColor.hairline).frame(height: 1).padding(.leading, 16)
                        }
                        foodRow(entry)
                    }
                }
                .background(AppColor.surface)
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
        .padding(.top, 6)
    }

    /// "150g" but "1 serving" — a word unit glued to its number misreads.
    private func portion(_ entry: FoodEntrySummary) -> String {
        "\(Int(entry.quantity))\(entry.unit.count > 2 ? " " : "")\(entry.unit)"
    }

    private func foodRow(_ entry: FoodEntrySummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.foodName).appBody(16, weight: .semibold).foregroundStyle(AppColor.ink)
                Text(portion(entry)).appBody(13).foregroundStyle(AppColor.secondaryText)
            }
            Spacer(minLength: 8)
            Text("\(Int(entry.calories)) kcal").appBody(14, weight: .semibold).foregroundStyle(AppColor.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        // Three VoiceOver stops per food — name, portion, and a bare
        // number with no unit. One stop, one sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.foodName), \(portion(entry))")
        .accessibilityValue("\(Int(entry.calories)) calories")
        // Long-press to remove a mistaken entry. Not swipe: that needs a
        // List, and this screen is a scroll of cards.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: AppRadius.md))
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await viewModel.deleteFoodEntry(entry) }
            }
        }
        .accessibilityAction(named: "Delete") {
            Task { await viewModel.deleteFoodEntry(entry) }
        }
    }

    /// Water, weight and exercise. Water and weight were read-only stubs
    /// until Module 4: water showed a total derived by dividing by 240 (a
    /// figure that exists nowhere on the server), weight said "Log today's
    /// →" and did nothing. Weight and exercise sit side by side — two
    /// half-width cards reading the same way water's one full-width card
    /// does (a label row, then the day's number).
    @ViewBuilder
    private func statRow() -> some View {
        WaterCard(viewModel: viewModel.water)

        // `.top`, not the default `.center`: BodyCard grows taller than
        // ExerciseTodayCard the moment a measurement chip wraps onto a
        // second line, and centring would float the shorter card in the
        // middle of that extra height instead of keeping both cards'
        // headers flush with each other.
        HStack(alignment: .top, spacing: 12) {
            BodyCard(
                measurements: viewModel.bodyMeasurements,
                lastLoggedWeight: viewModel.lastLoggedWeight,
                preferences: viewModel.preferences,
                onLogWeight: { viewModel.isPresentingLogWeight = true },
                isToday: viewModel.isViewingToday
            )

            ExerciseTodayCard(
                durationMinutes: viewModel.exerciseDurationMinutes,
                caloriesBurned: viewModel.exerciseCaloriesBurned,
                hasLogged: viewModel.hasLoggedExercise,
                isToday: viewModel.isViewingToday
            ) {
                viewModel.isPresentingLogExercise = true
            }
        }
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
