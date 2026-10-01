//
//  ExerciseEntryEditorView.swift
//  SwiftSparkyFitness
//
//  Replaces the old flat LogExerciseView. The exercise is chosen before this
//  screen opens (via ExerciseSearchView, already materialized if it came from
//  an external provider) — this view only builds the log entry, branching its
//  fields on `viewModel.modality`.
//
//  ORDER FOLLOWS WHAT EACH KIND OF SESSION IS ABOUT
//  ------------------------------------------------
//  Strength is its sets, so sets come first and duration (optional, and
//  estimated from the sets when left blank) comes after. Timed sessions are
//  their minutes, so duration leads, with one-tap presets. Heart rate and
//  notes sit at the end: optional, and rarely filled in.
//
//  STARTS FROM LAST TIME
//  ---------------------
//  An exercise logged before opens on that session's sets, minutes and
//  distance, with a card saying so. Most sessions repeat the last one give
//  or take a rep, so the usual edit is a tap or two and then Save — and
//  nothing grabs focus, so no keyboard lands over the form to begin with.
//

import SwiftUI

struct ExerciseEntryEditorView: View {
    @StateObject private var viewModel: ExerciseEntryEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var onSaved: () -> Void = {}

    @State private var isConfirmingDelete = false
    @State private var showsMoreDetails = false

    /// False when the caller closes the whole sheet itself on save (Log
    /// Exercise): stepping back here first slid the search list in under a
    /// sheet already on its way down.
    private var dismissesOnSave = true

    init(
        exercise: Exercise,
        entryDate: Date = Date(),
        lastSession: ExerciseLastSession? = nil,
        dismissesOnSave: Bool = true,
        onSaved: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: ExerciseEntryEditorViewModel(
            exercise: exercise, entryDate: entryDate, lastSession: lastSession
        ))
        self.dismissesOnSave = dismissesOnSave
        self.onSaved = onSaved
    }

    init(editing entry: ExerciseSessionSummary, exercise: Exercise, onSaved: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: ExerciseEntryEditorViewModel(editing: entry, exercise: exercise))
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let bannerMessage = viewModel.bannerMessage {
                            ErrorBanner(message: bannerMessage)
                        }

                        ExercisePhotos(exerciseName: viewModel.exercise.name, height: 104)

                        kindRow

                        if viewModel.startsFromLastSession, let last = viewModel.lastSession {
                            lastTimeCard(last)
                        }

                        if viewModel.modality.usesSets {
                            setsEditor
                            durationSection
                        } else {
                            durationSection
                            if viewModel.modality == .durationDistance { distanceSection }
                        }

                        caloriesSection
                        moreDetails

                        if viewModel.isEditing { deleteButton }
                    }
                    .padding(18)
                    .id(Self.topAnchor)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewModel.setRows.count)
                }
                // Number pads have no return key; the search sheets dismiss the
                // same way.
                .scrollDismissesKeyboard(.interactively)
                // A failed save or delete reports at the top, and Delete sits at
                // the bottom — so the banner is brought into view, and spoken.
                .onChange(of: viewModel.bannerMessage) { _, message in
                    guard let message else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                        proxy.scrollTo(Self.topAnchor, anchor: .top)
                    }
                    AccessibilityNotification.Announcement(message).post()
                }
            }
        }
        .background(AppColor.surface)
        .task { await viewModel.loadUnits() }
        .confirmationDialog("Delete this \(viewModel.exercise.name) session?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.delete() { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It comes off this day's exercise and calories.")
        }
    }

    private var header: some View {
        SheetHeader(
            title: viewModel.isEditing ? "Edit \(viewModel.exercise.name)" : viewModel.exercise.name,
            onCancel: { dismiss() },
            action: SheetAction("Save", isBusy: viewModel.isSaving) {
                Task {
                    if await viewModel.save() {
                        onSaved()
                        if dismissesOnSave { dismiss() }
                    }
                }
            }
        )
    }

    private var kindRow: some View {
        HStack(spacing: 8) {
            if let category = viewModel.exercise.category {
                Text(category.capitalized)
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppColor.inputBackground, in: Capsule())
            }
            Text(viewModel.modality.label)
                .appBody(12)
                .foregroundStyle(AppColor.secondaryText)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// What the form was filled from — so the numbers already in it read as
    /// "your last session", not as defaults someone else picked.
    private func lastTimeCard(_ last: ExerciseLastSession) -> some View {
        let detail = ExerciseFormatting.detail(
            last, fallbackModality: viewModel.modality,
            weightUnit: viewModel.weightUnit, distanceUnit: viewModel.distanceUnit
        )
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 32, height: 32)
                .background(AppColor.surface, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last time · \(ExerciseFormatting.relativeDay(last.date))")
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                }
                Text("Filled in from it — change anything that's different.")
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppColor.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Sets editor (weightReps / repsOnly)

    private var setsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("SETS", isInvalid: viewModel.setsError != nil)
                Spacer()
                let count = viewModel.setRows.filter { !$0.isBlank }.count
                if count > 0 {
                    Text("\(count) set\(count == 1 ? "" : "s")")
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                        .contentTransition(.numericText())
                }
            }

            if !stacksSetFields { columnHeadings }

            ForEach(Array(viewModel.setRows.enumerated()), id: \.element.id) { index, row in
                setRow(index: index, row: row)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let setsError = viewModel.setsError {
                Text(setsError).appBody(12).foregroundStyle(AppColor.destructive)
            }

            Button {
                Haptics.light()
                viewModel.addSet()
            } label: {
                Label("Add set", systemImage: "plus")
                    .appBody(14, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColor.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableLarge)
            .accessibilityHint(viewModel.setRows.last.map { $0.isBlank ? "" : "Starts from the set above" } ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnHeadings: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: 26, alignment: .leading)
            Text("REPS").frame(maxWidth: .infinity)
            if viewModel.modality == .weightReps {
                Text("WEIGHT (\(viewModel.weightUnit.uppercased()))").frame(maxWidth: .infinity)
            }
            Color.clear.frame(width: Self.removeWidth + 4)
        }
        .appBody(10, weight: .semibold)
        .foregroundStyle(AppColor.placeholder)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    private static let topAnchor = "editorTop"

    /// From here up the two steppers no longer fit side by side — the
    /// fields' text scales and their columns don't — so each set stacks
    /// its fields under a heading instead of clipping "102.5" to "10".
    private var stacksSetFields: Bool { dynamicTypeSize >= .xxxLarge }

    @ViewBuilder
    private func setRow(index: Int, row: ExerciseSetRow) -> some View {
        if stacksSetFields {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Set \(index + 1)")
                        .appBody(14, weight: .semibold)
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if viewModel.setRows.count > 1 { removeSetButton(index: index, row: row) }
                }
                repsField(index: index, row: row)
                if viewModel.modality == .weightReps { weightField(index: index, row: row) }
            }
        } else {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .appBody(14, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .monospacedDigit()
                    .frame(width: 26, alignment: .leading)
                    .accessibilityHidden(true)

                repsField(index: index, row: row)
                if viewModel.modality == .weightReps { weightField(index: index, row: row) }

                // The last set can't be removed (see removeSet), so its button
                // would only buzz; keep the column so the fields stay aligned.
                if viewModel.setRows.count > 1 {
                    removeSetButton(index: index, row: row)
                } else {
                    Color.clear.frame(width: Self.removeWidth + 4, height: 44).accessibilityHidden(true)
                }
            }
        }
    }

    private func repsField(index: Int, row: ExerciseSetRow) -> some View {
        StepperField(
            label: "Reps, set \(index + 1)",
            text: binding(for: row, \.repsText),
            placeholder: "0",
            stepLabel: "1"
        ) { viewModel.step(row, .reps, by: $0) }
    }

    private func weightField(index: Int, row: ExerciseSetRow) -> some View {
        StepperField(
            label: "Weight in \(viewModel.weightUnit), set \(index + 1)",
            text: binding(for: row, \.weightText),
            placeholder: "0",
            keyboardType: .decimalPad,
            stepLabel: "\(ExerciseFormatting.number(viewModel.weightStep)) \(viewModel.weightUnit)"
        ) { viewModel.step(row, .weight, by: $0) }
    }

    /// Set apart from the weight's "+" — the most-tapped control in the row
    /// sat 8pt from it, and a slightly wide tap removed the whole set.
    private static let removeWidth: CGFloat = 36

    private func removeSetButton(index: Int, row: ExerciseSetRow) -> some View {
        Button {
            Haptics.warning()
            viewModel.removeSet(row)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppColor.placeholder)
                .frame(width: Self.removeWidth, height: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCompact)
        .padding(.leading, 4)
        .accessibilityLabel("Remove set \(index + 1)")
    }

    /// A single row's field, addressed by index rather than id — `ForEach`
    /// above already keys on id for diffing, but writing back through a
    /// `Binding` needs the current index to find the row again after edits.
    private func binding(for row: ExerciseSetRow, _ keyPath: WritableKeyPath<ExerciseSetRow, String>) -> Binding<String> {
        Binding(
            get: { viewModel.setRows.first(where: { $0.id == row.id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = viewModel.setRows.firstIndex(where: { $0.id == row.id }) else { return }
                viewModel.setRows[index][keyPath: keyPath] = newValue
                viewModel.applyEstimateIfNeeded()
            }
        )
    }

    // MARK: - Duration, distance, calories

    private var durationSection: some View {
        let usesSets = viewModel.modality.usesSets
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel(usesSets ? "DURATION (OPTIONAL)" : "DURATION", isInvalid: viewModel.durationError != nil)
            StepperField(
                label: "Duration in minutes",
                text: $viewModel.durationMinutesText.onChange { viewModel.applyEstimateIfNeeded() },
                placeholder: usesSets ? estimatedFromSets : "0",
                // "≈ 2 min a set" already says minutes; a unit after it read
                // "≈ 2 min a set min".
                unit: usesSets && viewModel.durationMinutesText.isEmpty && viewModel.effectiveMinutes == nil ? nil : "min",
                stepLabel: "5 minutes"
            ) { viewModel.stepDuration(by: $0) }
            if !usesSets {
                PresetChips(
                    values: [15, 20, 30, 45, 60],
                    unitLabel: "min",
                    spokenUnit: "minutes",
                    selected: Int(viewModel.durationMinutesText)
                ) { viewModel.setDuration($0) }
            }
            if let error = viewModel.durationError {
                Text(error).appBody(12).foregroundStyle(AppColor.destructive)
            }
        }
    }

    /// "≈ 6 min" — what a blank duration will be logged as.
    private var estimatedFromSets: String {
        guard let minutes = viewModel.effectiveMinutes, viewModel.durationMinutesText.isEmpty else { return "≈ 2 min a set" }
        return "≈ \(Int(minutes))"
    }

    private var distanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DISTANCE", isInvalid: viewModel.distanceError != nil)
            StepperField(
                label: "Distance in \(viewModel.distanceUnit)",
                text: $viewModel.distanceText,
                placeholder: "0",
                unit: viewModel.distanceUnit,
                keyboardType: .decimalPad,
                stepLabel: "0.5 \(viewModel.distanceUnit)"
            ) { viewModel.stepDistance(by: $0) }
            if let error = viewModel.distanceError {
                Text(error).appBody(12).foregroundStyle(AppColor.destructive)
            }
        }
    }

    private var caloriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CALORIES BURNED", isInvalid: viewModel.caloriesError != nil)
            AppTextField(
                placeholder: "0", text: $viewModel.caloriesText, style: .filled,
                isInvalid: viewModel.caloriesError != nil, keyboardType: .numberPad,
                suffix: "kcal"
            )
            if let error = viewModel.caloriesError {
                Text(error).appBody(12).foregroundStyle(AppColor.destructive)
            } else if viewModel.caloriesAreEstimated {
                Text("Estimated from the exercise's intensity and your weight. Type your own to replace it.")
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - More details

    /// Heart rate and notes: optional and rarely filled in, so folded away
    /// — open already when editing an entry that has them.
    @ViewBuilder
    private var moreDetails: some View {
        let hasDetails = !viewModel.notes.isEmpty || !viewModel.avgHeartRateText.isEmpty
        if showsMoreDetails || hasDetails {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.modality == .durationDistance {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("AVG HEART RATE", isInvalid: false)
                        AppTextField(
                            placeholder: "Optional", text: $viewModel.avgHeartRateText, style: .filled,
                            keyboardType: .numberPad, suffix: "bpm"
                        )
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("NOTES", isInvalid: false)
                    AppTextField(placeholder: "How did it feel?", text: $viewModel.notes, style: .filled)
                }
            }
            .transition(.opacity)
        } else {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { showsMoreDetails = true }
            } label: {
                Label(viewModel.modality == .durationDistance ? "Add heart rate or a note" : "Add a note", systemImage: "plus.circle")
                    .appBody(14, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Group {
                if viewModel.isDeleting {
                    ProgressView()
                } else {
                    Label("Delete this session", systemImage: "trash")
                }
            }
            .appBody(15, weight: .semibold)
            .foregroundStyle(AppColor.destructive)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(viewModel.isDeleting || viewModel.isSaving)
        .padding(.top, 6)
    }

    private func sectionLabel(_ text: String, isInvalid: Bool) -> some View {
        Text(text)
            .appBody(12, weight: .semibold)
            .foregroundStyle(isInvalid ? AppColor.destructive : AppColor.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension Binding where Value == String {
    /// Runs `action` after every write — the calorie estimate follows the
    /// duration whether it was typed or stepped.
    func onChange(_ action: @escaping () -> Void) -> Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}

#if DEBUG
#Preview {
    ExerciseEntryEditorView(exercise: Exercise.previewSquat)
}
#endif
