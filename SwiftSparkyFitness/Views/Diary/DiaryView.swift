//
//  DiaryView.swift
//  SwiftSparkyFitness
//
//  Today's "read + edit" counterpart: same day, same DailySummaryCard, but
//  browsable by date and every entry is editable/deletable in place.
//
//  Built on a List (not the ScrollView+VStack every other screen uses) —
//  the one deliberate exception, and only because native swipe-to-delete
//  (`.swipeActions`) requires one. Row insets/separators/backgrounds are
//  stripped so it still reads as the same card-based design, not a system
//  list. Tapping a row reopens Module 2's own FoodDetailView/LogExerciseView
//  pre-loaded for editing rather than building new edit UI.
//

import SwiftUI

struct DiaryView: View {
    let user: SessionUser
    @StateObject private var viewModel: DiaryViewModel
    @State private var isPresentingDatePicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(user: SessionUser) {
        self.user = user
        _viewModel = StateObject(wrappedValue: DiaryViewModel(user: user))
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: viewModel.selectedDate)
    }

    var body: some View {
        List {
            Section {
                header.diaryRow()
            }

            // Keyed on the date so paging is an insert+remove (and so can
            // carry a directional transition) rather than an in-place content
            // swap, and dimmed while the new day is still in flight — the old
            // day used to sit there at full strength, indistinguishable from
            // the one you'd just asked for.
            dayContent
                .id(viewModel.selectedDate)
                .transition(pageTransition)
                .opacity(isShowingStaleDay ? 0.4 : 1)
                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: viewModel.selectedDate)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isShowingStaleDay)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        // Simultaneous, not `.gesture`: the List owns vertical scrolling and
        // the rows own `.swipeActions`, and neither may lose to day paging.
        .simultaneousGesture(dayPagingGesture)
        .safeAreaInset(edge: .top) { errorInset }
        .onChange(of: viewModel.errorMessage) { _, message in
            // The banner appears without moving focus, so VoiceOver would
            // otherwise never learn that the delete/refresh failed.
            guard let message, viewModel.summary != nil else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $viewModel.editingFoodEntry, onDismiss: { Task { await viewModel.load() } }) { entry in
            editFoodSheet(entry)
        }
        .sheet(item: $viewModel.editingExerciseEntry, onDismiss: { Task { await viewModel.load() } }) { entry in
            LogExerciseView(
                editingEntryId: entry.id, exerciseId: entry.exerciseId ?? "", name: entry.name ?? "",
                durationMinutes: entry.durationMinutes ?? 0, caloriesBurned: entry.caloriesBurned ?? 0,
                entryDate: viewModel.selectedDate
            ) {}
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingDatePicker) {
            DiaryDatePickerSheet(initialDate: viewModel.selectedDate, minDate: viewModel.minDate, maxDate: viewModel.maxDate) { picked in
                viewModel.jumpToDate(picked)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $viewModel.isPresentingBodySheet) { kind in
            LogBodyView(
                kind: kind, date: viewModel.selectedDate,
                existing: viewModel.bodyMeasurements,
                preferences: viewModel.preferences,
                minDate: viewModel.minDate, maxDate: viewModel.maxDate
            ) {
                Task { await viewModel.load() }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Everything below the header that belongs to one specific day.
    @ViewBuilder
    private var dayContent: some View {
        if viewModel.isLoading && viewModel.summary == nil {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .diaryRow()
            }
        } else if let summary = viewModel.summary {
            if viewModel.hasLoggedAnything {
                Section {
                    DailySummaryCard(
                        summary: summary, macroTotals: viewModel.macroTotals,
                        waterMl: viewModel.water.totalMl
                    )
                    .padding(.horizontal, AppSpacing.screenPad)
                    .diaryRow()
                }
                ForEach(viewModel.entriesByMeal, id: \.mealType.id) { group in
                    mealSection(group.mealType, group.entries)
                }
                exerciseSection(summary.exerciseSessions)
                waterSection()
                bodySection()
            } else {
                Section {
                    emptyState.diaryRow()
                }
            }
        } else if let errorMessage = viewModel.errorMessage {
            Section {
                loadErrorState(errorMessage).diaryRow()
            }
        }
    }

    private var isShowingStaleDay: Bool {
        viewModel.isLoading && viewModel.summary != nil
    }

    /// New day arrives from the direction you're travelling, old day leaves
    /// the opposite way. Reduce Motion gets the crossfade instead.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let forward = viewModel.lastPageDirection == .forward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    /// `errorMessage` is set on *every* failure, but the only place it was
    /// ever rendered was the `summary == nil` branch — so a failed delete or
    /// a failed day change with data already on screen produced a haptic and
    /// nothing else, leaving the row the user had just deleted sitting there
    /// looking deleted-but-not.
    private var errorInset: some View {
        // The container is always present (and zero-height when there's no
        // error) so the banner has something to animate in and out of.
        VStack(spacing: 0) {
            if let errorMessage = viewModel.errorMessage, viewModel.summary != nil {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, AppSpacing.screenPad)
                    .padding(.bottom, 10)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .background(AppColor.background)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
    }

    /// Left = next day, right = previous — with a soft bump at the bounds so
    /// a swipe that can't go anywhere still answers, instead of reading as a
    /// dropped gesture. Deliberately long and strongly horizontal so an
    /// ordinary scroll or a row's swipe-to-delete doesn't page the day too.
    private var dayPagingGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 90, abs(dx) > abs(dy) * 2.5 else { return }
                let wantsNextDay = dx < 0
                let canPage = wantsNextDay ? viewModel.canGoToNextDay : viewModel.canGoToPreviousDay
                guard canPage else { return Haptics.light() }
                Haptics.selection()
                if wantsNextDay { viewModel.goToNextDay() } else { viewModel.goToPreviousDay() }
            }
    }

    @ViewBuilder
    private func editFoodSheet(_ entry: FoodEntrySummary) -> some View {
        // A food entry the app itself logged always has these ids — nil
        // here would mean the server sent back something we've never seen
        // live; fail visibly (empty sheet body) rather than guess a food.
        if let food = entry.editableFood {
            let initialMealType = viewModel.mealTypes.first { $0.name == entry.mealType } ?? viewModel.mealTypes.first
            if let initialMealType {
                FoodDetailView(
                    food: food, mealTypes: viewModel.mealTypes, initialMealType: initialMealType,
                    existingEntryId: entry.id, initialQuantity: entry.quantity, entryDate: viewModel.selectedDate
                ) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diary")
                .appDisplay(26)
                .foregroundStyle(AppColor.ink)
            // The chevron glyphs were their own 6.7 x 11.7pt tap targets —
            // ~4% of the 44x44 minimum, and sitting a few points from the
            // date button, so a near-miss silently opened the date picker.
            // The glyphs keep their size; the *targets* are padded to 44 and
            // the row's spacing pulled to 0 so the row doesn't visibly spread.
            HStack(spacing: 0) {
                Button { Haptics.selection(); viewModel.goToPreviousDay() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(viewModel.canGoToPreviousDay ? AppColor.accent : AppColor.placeholder)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!viewModel.canGoToPreviousDay)
                .buttonStyle(.pressableCompact)
                // Defaults to "Back" — a chevron.left reads as navigation
                // history to VoiceOver, which is not what this does.
                .accessibilityLabel("Previous day")

                Button { isPresentingDatePicker = true } label: {
                    Text(dateLabel)
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(AppColor.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityHint("Opens a date picker")

                Button { Haptics.selection(); viewModel.goToNextDay() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(viewModel.canGoToNextDay ? AppColor.accent : AppColor.placeholder)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!viewModel.canGoToNextDay)
                .buttonStyle(.pressableCompact)
                // Defaults to "Forward", same problem as "Back" above.
                .accessibilityLabel("Next day")
            }
            // The 44pt targets are mostly empty space around a 7pt glyph, so
            // the left chevron is pulled back into the screen margin to stay
            // optically aligned under the "Diary" title.
            .padding(.leading, -14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("📭").font(.system(size: 36))
            Text("Nothing logged on \(dateLabel)")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
            Text("Switch to Today to log food, water, or exercise.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 60)
    }

    private func loadErrorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            ErrorBanner(message: message)
            PrimaryButton(title: "Retry") { Task { await viewModel.load() } }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, 40)
    }

    // MARK: - Meal sections

    private func mealSection(_ mealType: MealType, _ entries: [FoodEntrySummary]) -> some View {
        let total = entries.reduce(0) { $0 + $1.calories }
        return Section {
            if !viewModel.isCollapsed(mealType.id) {
                if entries.isEmpty {
                    Text("Nothing logged")
                        .appBody(13)
                        .foregroundStyle(AppColor.placeholder)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .diaryRow()
                } else {
                    ForEach(entries) { entry in
                        foodRow(entry)
                            .padding(.horizontal, AppSpacing.screenPad)
                            .diaryRow()
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    Task { await viewModel.deleteFoodEntry(entry) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        } header: {
            sectionHeader(id: mealType.id, title: "\(mealType.name.capitalized) · \(Int(total)) kcal")
        }
    }

    // A `.contentShape` + `.onTapGesture` row is invisible to assistive tech:
    // no button trait, no activation action, so Diary's entire tap-to-edit
    // affordance didn't exist under VoiceOver — and the row read out as three
    // loose strings ending in a bare unitless number. A real Button fixes
    // both, and gives the press feedback the tap gesture never had.
    private func foodRow(_ entry: FoodEntrySummary) -> some View {
        Button {
            guard entry.editableFood != nil else { return }
            viewModel.editingFoodEntry = entry
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.foodName), \(Int(entry.quantity))\(entry.unit)")
        .accessibilityValue("\(Int(entry.calories)) calories")
        .accessibilityHint("Opens for editing")
    }

    // MARK: - Exercise

    private func exerciseSection(_ sessions: [ExerciseSessionSummary]) -> some View {
        let total = sessions.reduce(0.0) { $0 + ($1.caloriesBurned ?? 0) }
        return Section {
            if !viewModel.isCollapsed("exercise") {
                if sessions.isEmpty {
                    Text("Nothing logged")
                        .appBody(13)
                        .foregroundStyle(AppColor.placeholder)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .diaryRow()
                } else {
                    ForEach(sessions) { session in
                        exerciseRow(session)
                            .padding(.horizontal, AppSpacing.screenPad)
                            .diaryRow()
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    Task { await viewModel.deleteExerciseEntry(session) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        } header: {
            sectionHeader(id: "exercise", title: "Exercise · \(Int(total)) kcal")
        }
    }

    private func exerciseRow(_ session: ExerciseSessionSummary) -> some View {
        Button {
            guard session.exerciseId != nil else { return }
            viewModel.editingExerciseEntry = session
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name ?? "Exercise").appBody(15, weight: .semibold).foregroundStyle(AppColor.ink)
                    Text("\(Int(session.durationMinutes ?? 0)) min").appBody(12).foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                Text("\(Int(session.caloriesBurned ?? 0))").appBody(14, weight: .semibold).foregroundStyle(AppColor.energy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppColor.surface)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColor.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.name ?? "Exercise"), \(Int(session.durationMinutes ?? 0)) minutes")
        .accessibilityValue("\(Int(session.caloriesBurned ?? 0)) calories burned")
        .accessibilityHint("Opens for editing")
    }

    // MARK: - Water
    // Module 4: a per-drink list, not the read-only total Module 3 shipped.
    // The ledger behind it (GET /api/v2/measurements/water-intake/{date}/log)
    // is what Module 3 couldn't find — it's on the /api/v2 prefix, and every
    // row carries an id, so a single mis-tapped glass can be swiped away
    // like any food or exercise entry.

    private func waterSection() -> some View {
        let entries = viewModel.water.entries
        return Section {
            if !viewModel.isCollapsed("water") {
                if entries.isEmpty {
                    Text("Nothing logged")
                        .appBody(13)
                        .foregroundStyle(AppColor.placeholder)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .diaryRow()
                } else {
                    ForEach(entries) { entry in
                        waterRow(entry)
                            .padding(.horizontal, AppSpacing.screenPad)
                            .diaryRow()
                            .swipeActions(edge: .trailing) {
                                if entry.isManual {
                                    Button(role: .destructive) {
                                        Haptics.warning()
                                        Task { await viewModel.water.delete(entry) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }

                // Food-derived water isn't in the ledger and isn't this
                // app's to delete, so it's shown as its own non-swipeable
                // line instead of being folded into a row that looks
                // deletable. Only appears for a user who opted in to
                // `add_food_water_to_intake`.
                if viewModel.water.foodMl > 0 {
                    Text("+ \(Int(viewModel.water.foodMl.rounded())) ml from food")
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .diaryRow()
                }
            }
        } header: {
            sectionHeader(id: "water", title: "Water · \(Int(viewModel.water.totalMl.rounded())) ml")
        }
    }

    private func waterRow(_ entry: WaterLogEntry) -> some View {
        HStack(spacing: 10) {
            Text("💧").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(entry.waterMl.rounded())) ml")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                if let containerName = entry.containerName {
                    Text(containerName)
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            Spacer()
            if let loggedAt = entry.loggedAt {
                Text(DiaryView.timeFormatter.string(from: loggedAt))
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(14)
        .background(AppColor.waterSoft)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Body (weight & measurements)
    // One row per day by construction — `check_in_measurements` is unique on
    // (user_id, entry_date) — so this is never a list of entries. Tapping
    // reopens the same sheets Today uses, prefilled for this date; swiping
    // deletes the whole row, which is the only delete the endpoint offers.

    private func bodySection() -> some View {
        let fields = viewModel.bodyMeasurements.populatedFields
        return Section {
            if !viewModel.isCollapsed("body") {
                if fields.isEmpty {
                    Text("Nothing logged")
                        .appBody(13)
                        .foregroundStyle(AppColor.placeholder)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .diaryRow()
                } else {
                    bodyRow(fields)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .diaryRow()
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Haptics.warning()
                                Task { await viewModel.deleteBodyMeasurements() }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            sectionHeader(id: "body", title: "Body")
        }
    }

    private func bodyRow(_ fields: [(field: BodyField, value: Double)]) -> some View {
        // Spacing traded for height: each line is now a 44pt target (it was a
        // ~20pt text row), so the gap between them comes out of the padding
        // instead of adding to it.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fields, id: \.field.id) { entry in
                // Per line, not per row: tapping the weight must open the
                // sheet that actually contains a weight field. A single
                // row-level tap sent you to the measurements sheet — which
                // has no weight on it — whenever the day had any measurement
                // logged alongside it.
                Button {
                    viewModel.isPresentingBodySheet = entry.field == .weight ? .weight : .measurements
                } label: {
                    HStack {
                        Text(entry.field.label)
                            .appBody(14)
                            .foregroundStyle(AppColor.secondaryText)
                        Spacer()
                        Text(valueLabel(entry.field, entry.value))
                            .appBody(15, weight: .semibold)
                            .foregroundStyle(AppColor.ink)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.field.label)
                .accessibilityValue(valueLabel(entry.field, entry.value))
                .accessibilityHint("Opens for editing")
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func valueLabel(_ field: BodyField, _ value: Double) -> String {
        let formatted = viewModel.preferences.formatted(value)
        return field.unitKind == .percent
            ? "\(formatted)%"
            : "\(formatted) \(field.unitLabel(viewModel.preferences))"
    }

    private func sectionHeader(id: String, title: String) -> some View {
        let isCollapsed = viewModel.isCollapsed(id)
        return Button {
            viewModel.toggleSection(id, animated: !reduceMotion)
        } label: {
            HStack {
                Text(title)
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .textCase(.uppercase)
                    // The kcal total changes under the same heading after a
                    // delete or an edit; digits should roll, not hard-cut.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: title)
                Spacer()
                // One chevron rotated, not two symbols swapped: swapping gave
                // the disclosure state no motion to follow at all.
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.placeholder)
                    .rotationEffect(.degrees(isCollapsed ? 180 : 0))
                    // Announces as "Go Up" on its own; the button's own
                    // value already says collapsed/expanded.
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Expands this section" : "Collapses this section")
        .padding(.horizontal, AppSpacing.screenPad)
        .textCase(nil)
    }
}

/// Strips List's default row chrome (insets/separator/background) so rows
/// read as plain content on `AppColor.background`, not a system list —
/// applied to every row since `List` has no "turn all this off" switch.
private extension View {
    func diaryRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct DiaryDatePickerSheet: View {
    @State private var date: Date
    let minDate: Date
    let maxDate: Date
    let onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialDate: Date, minDate: Date, maxDate: Date, onPick: @escaping (Date) -> Void) {
        _date = State(initialValue: initialDate)
        self.minDate = minDate
        self.maxDate = maxDate
        self.onPick = onPick
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(AppColor.hairline).frame(width: 44, height: 5).padding(.top, 10)
            DatePicker("", selection: $date, in: minDate...maxDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(AppColor.accent)
            PrimaryButton(title: "Go to date") {
                onPick(date)
                dismiss()
            }
        }
        .padding(20)
        .background(AppColor.surface)
    }
}

#Preview {
    DiaryView(user: SessionUser(email: "demo@sparkyfitness.com", name: "Demo"))
}
