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
//  list. Tapping a food row reopens Module 2's own FoodDetailView pre-loaded
//  for editing rather than building new edit UI. (Exercise entries moved to
//  ExerciseDiaryView, the Exercise tab's other segment, in Module 12.)
//

import SwiftUI

/// Module 12: the "Food & Water" half of the Exercise tab's segmented
/// control. Formerly a standalone tab named "Diary" — the day-paging, meal
/// sections and water/body sections are unchanged, only the exercise
/// section moved out (to `ExerciseDiaryView`, the tab's other segment) and
/// the header lost its own big title, since the segmented control above it
/// already says which half of the day this is.
struct DiaryView: View {
    @ObservedObject private var viewModel: DiaryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLoggingFood = false
    /// The meal a section's own "Log" row opened the search for.
    @State private var loggingMealType: MealType?

    /// Standalone use (previews, tests) builds its own view model; the
    /// Exercise tab passes one down so both segments share a single day's
    /// data and date position instead of loading it twice.
    init(user: SessionUser) {
        _viewModel = ObservedObject(wrappedValue: DiaryViewModel(user: user))
    }

    init(viewModel: DiaryViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }


    var body: some View {
        List {
            Section {
                header.diaryRow().diaryDayPaging(viewModel)
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
        // A run of closed sections was mostly air: 64pt per header plus a
        // 22pt gap. The header's own 44pt target is the spacing now.
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .safeAreaInset(edge: .top) { errorInset }
        .onChange(of: viewModel.errorMessage) { _, message in
            // The banner appears without moving focus, so VoiceOver would
            // otherwise never learn that the delete/refresh failed.
            guard let message, viewModel.summary != nil else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        // The Exercise tab loads this shared view model on appear; loading
        // again here ran a second full day load on every segment switch.
        // Standalone (previews), nothing else loads it.
        .task { if viewModel.summary == nil { await viewModel.load() } }
        .refreshable { await viewModel.load() }
        .sheet(item: $viewModel.editingFoodEntry, onDismiss: { Task { await viewModel.load() } }) { entry in
            editFoodSheet(entry)
        }
        // Logs to the day on screen, as the Exercise side's "Log a workout"
        // does; today keeps the time of day, as Today's logging does.
        .sheet(isPresented: $isLoggingFood, onDismiss: { Task { await viewModel.load() } }) {
            FoodSearchView(
                mealTypes: viewModel.mealTypes.visibleOnly, initialMealType: loggingMealType,
                entryDate: Calendar.current.isDateInToday(viewModel.selectedDate) ? Date() : viewModel.selectedDate
            ) {
                isLoggingFood = false
            }
            .fittedDetent()
            .presentationDragIndicator(.visible)
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
            .fittedDetent()
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
                    .diaryDayPaging(viewModel)
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
                    .diaryDayPaging(viewModel)
                }
                ForEach(viewModel.entriesByMeal, id: \.mealType.id) { group in
                    mealSection(group.mealType, group.entries)
                }
                waterSection()
                bodySection()
            } else {
                Section {
                    emptyState.diaryRow().diaryDayPaging(viewModel)
                }
            }
        } else if let errorMessage = viewModel.errorMessage {
            Section {
                loadErrorState(errorMessage).diaryRow().diaryDayPaging(viewModel)
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
    @ViewBuilder
    private func editFoodSheet(_ entry: FoodEntrySummary) -> some View {
        // A food entry the app itself logged always has these ids — nil
        // here would mean the server sent back something we've never seen
        // live; fail visibly (empty sheet body) rather than guess a food.
        if let food = entry.editableFood {
            let initialMealType = viewModel.mealTypes.first { $0.name == entry.mealType } ?? viewModel.mealTypes.first
            if let initialMealType {
                FoodDetailView(
                    food: food, mealTypes: viewModel.loggableMealTypes, initialMealType: initialMealType,
                    existingEntryId: entry.id, initialQuantity: entry.quantity, entryDate: viewModel.selectedDate
                ) {}
                .fittedDetent()
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var header: some View {
        // No big title here — the segmented control above this
        // (ExerciseTabView) already says "Food & Water".
        DiaryDayHeader(viewModel: viewModel)
    }

    /// The same card as the Exercise side's, so the two halves of this tab
    /// read as one screen — and, like it, it offers the thing to do here
    /// rather than sending the user to another tab.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 64, height: 64)
                .background(AppColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text("Nothing logged \(DiaryDayHeader.phrase(for: viewModel.selectedDate))")
                .appDisplay(20)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Log a meal, a snack or a drink for this day.")
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Log food") {
                // A day swipe across the card ends on this button.
                guard !viewModel.isMidDaySwipe else { return }
                Haptics.light()
                loggingMealType = nil
                isLoggingFood = true
            }
            .padding(.top, 6)
            Button {
                guard !viewModel.isMidDaySwipe else { return }
                addDrink()
            } label: {
                Label("Add a drink", systemImage: "drop.fill")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.water)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(AppColor.dashedBorder)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .padding(.horizontal, AppSpacing.screenPad)
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
            if !viewModel.isCollapsed(mealType.id, isEmpty: entries.isEmpty) {
                if entries.isEmpty {
                    emptyRow("Log \(mealType.name.lowercased())", symbol: "plus", tint: AppColor.accent) {
                        loggingMealType = mealType
                        isLoggingFood = true
                    }
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
                                // The TabView tints everything pink; delete keeps iOS red.
                                .tint(AppColor.destructive)
                            }
                    }
                }
            }
        } header: {
            sectionHeader(
                id: mealType.id, isEmpty: entries.isEmpty,
                title: entries.isEmpty ? mealType.name.capitalized : "\(mealType.name.capitalized) · \(Int(total.rounded())) kcal"
            )
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
                    Text(FoodVariant.amountText(entry.quantity, unit: entry.unit)).appBody(12).foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                Text("\(Int(entry.calories.rounded()))").appBody(14, weight: .semibold).foregroundStyle(AppColor.ink)
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
        .accessibilityLabel("\(entry.foodName), \(FoodVariant.amountText(entry.quantity, unit: entry.unit))")
        .accessibilityValue("\(Int(entry.calories.rounded())) calories")
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
        let isEmpty = viewModel.water.totalMl <= 0
        return Section {
            if !viewModel.isCollapsed("water", isEmpty: isEmpty) {
                if !entries.isEmpty {
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
                                    // The TabView tints everything pink; delete keeps iOS red.
                                    .tint(AppColor.destructive)
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

                // Always offered, not only when empty: one tap per glass is
                // what the water card on Today does, and this day may not be
                // today.
                emptyRow("Add a drink · \(viewModel.water.drinkLabel)", symbol: "plus", tint: AppColor.water, action: addDrink)
            }
        } header: {
            sectionHeader(
                id: "water", isEmpty: isEmpty,
                title: isEmpty ? "Water" : "Water · \(Int(viewModel.water.totalMl.rounded())) ml"
            )
        }
    }

    private func waterRow(_ entry: WaterLogEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "drop.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.water)
                .frame(width: 28, height: 28)
                .background(AppColor.waterSoft, in: Circle())
                .accessibilityHidden(true)
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
        // The food row's card, so a day reads as one list rather than two
        // styles stacked: a full tinted block per glass was the heaviest
        // thing on the screen for the least information.
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func addDrink() {
        Haptics.light()
        Task {
            await viewModel.water.adjust(drinks: 1)
            await viewModel.water.loadEntries()
        }
    }

    /// What an empty section shows once opened: the thing to do here, rather
    /// than a line saying there's nothing.
    private func emptyRow(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            guard !viewModel.isMidDaySwipe else { return }
            action()
        } label: {
            Label(title, systemImage: symbol)
                .appBody(14, weight: .semibold)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(AppColor.dashedBorder)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, AppSpacing.screenPad)
        .diaryRow()
        .diaryDayPaging(viewModel)
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
            if !viewModel.isCollapsed("body", isEmpty: fields.isEmpty) {
                if fields.isEmpty {
                    emptyRow("Log weight", symbol: "plus", tint: AppColor.accent) {
                        viewModel.isPresentingBodySheet = .weight
                    }
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
                            // The TabView tints everything pink; delete keeps iOS red.
                            .tint(AppColor.destructive)
                        }
                }
            }
        } header: {
            sectionHeader(id: "body", isEmpty: fields.isEmpty, title: "Body")
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

    private func sectionHeader(id: String, isEmpty: Bool, title: String) -> some View {
        let isCollapsed = viewModel.isCollapsed(id, isEmpty: isEmpty)
        return Button {
            viewModel.toggleSection(id, isEmpty: isEmpty, animated: !reduceMotion)
        } label: {
            HStack {
                Text(title)
                    .appBody(12, weight: .semibold)
                    // Empty sections recede, so the eye lands on what was logged.
                    .foregroundStyle(isEmpty ? AppColor.placeholder : AppColor.secondaryText)
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
        .listRowInsets(EdgeInsets())
        .diaryDayPaging(viewModel)
    }
}

/// Strips List's default row chrome (insets/separator/background) so rows
/// read as plain content on `AppColor.background`, not a system list —
/// applied to every row since `List` has no "turn all this off" switch.
/// Not `private`: `ExerciseDiaryView` (Module 12's other segment) is a
/// separate `List`-based day view that needs the exact same treatment.
extension View {
    func diaryRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview {
    DiaryView(user: SessionUser(email: "demo@sparkyfitness.com", name: "Demo"))
}
