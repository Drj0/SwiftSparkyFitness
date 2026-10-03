//
//  ExerciseDiaryView.swift
//  SwiftSparkyFitness
//
//  The Exercise tab's primary segment (Module 12) — a day view of logged
//  sessions. Shares `DiaryViewModel` with the "Food & Water" segment
//  (`DiaryView`) so both read one day's data and one date position, rather
//  than loading the same `GET /api/daily-summary` twice — and, since the
//  redesign, the same day control (`DiaryDayHeader`): calendar, swipe
//  paging and all.
//
//  What a day of exercise answers first is "how much": a summary of time,
//  burn and sessions heads the list. Each session then reads as its icon,
//  its name, what was done ("3 × 8 · 60 kg", in the user's own units) and
//  its burn. A row edits on tap; holding it (or swiping right) logs it
//  again, which is how most repeat workouts get logged.
//

import SwiftUI

struct ExerciseDiaryView: View {
    @ObservedObject var viewModel: DiaryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A one-line confirmation after "Log again" — it may land on a day
    /// other than the one on screen, so the list alone can't show it.
    @State private var toast: String?
    /// Which toast is up, so an earlier one's timer can't clear a later one
    /// that happens to say the same thing.
    @State private var toastID = 0

    private var sessions: [ExerciseSessionSummary] {
        viewModel.summary?.exerciseSessions.userLogged ?? []
    }

    private var weightUnit: String { viewModel.preferences.weightUnitLabel }
    private var distanceUnit: String { viewModel.preferences.distanceUnitLabel }

    var body: some View {
        List {
            Section {
                DiaryDayHeader(viewModel: viewModel).diaryRow().diaryDayPaging(viewModel)
            }

            content
                .id(viewModel.selectedDate)
                .transition(pageTransition)
                .opacity(isShowingStaleDay ? 0.4 : 1)
                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: viewModel.selectedDate)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isShowingStaleDay)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .safeAreaInset(edge: .top) { errorInset }
        .onChange(of: viewModel.errorMessage) { _, message in
            // The banner appears without moving focus; VoiceOver would
            // otherwise never hear that a delete or Log again failed.
            guard let message, viewModel.summary != nil else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .refreshable { await viewModel.load() }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $viewModel.editingExerciseEntry, onDismiss: { Task { await viewModel.load() } }) { entry in
            ExerciseEntryEditorView(editing: entry, exercise: entry.asExercise) {}
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.isPresentingExerciseSearch, onDismiss: { Task { await viewModel.load() } }) {
            // Logs to the day on screen. It used to log to today whatever
            // day was being looked at.
            ExerciseSearchView(entryDate: viewModel.selectedDate) {
                viewModel.isPresentingExerciseSearch = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var isShowingStaleDay: Bool {
        viewModel.isLoading && viewModel.summary != nil
    }

    /// New day arrives from the direction you're travelling, as in Food &
    /// Water. Reduce Motion gets the crossfade instead.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let forward = viewModel.lastPageDirection == .forward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.summary == nil {
            Section {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40).diaryRow().diaryDayPaging(viewModel)
            }
        } else if let summary = viewModel.summary {
            if sessions.isEmpty {
                Section { emptyState.diaryRow().diaryDayPaging(viewModel) }
            } else {
                Section {
                    summaryCard(healthEnergy: summary.exerciseSessions.healthActiveEnergy)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .padding(.top, 6)
                        .diaryRow()
                        .diaryDayPaging(viewModel)
                }
                Section {
                    ForEach(sessions) { session in
                        row(session)
                            .padding(.horizontal, AppSpacing.screenPad)
                            .padding(.vertical, 4)
                            .diaryRow()
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    Task { await viewModel.deleteExerciseEntry(session) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                // The TabView tints everything pink; delete keeps iOS red.
                                .tint(AppColor.destructive)
                            }
                            .swipeActions(edge: .leading) {
                                if session.exerciseId != nil {
                                    Button { logAgain(session) } label: {
                                        Label(logAgainTitle, systemImage: "arrow.clockwise")
                                    }
                                    .tint(AppColor.energy)
                                }
                            }
                    }
                } header: {
                    Text("SESSIONS")
                        .appBody(12, weight: .semibold)
                        .tracking(0.8)
                        .foregroundStyle(AppColor.secondaryText)
                        .padding(.horizontal, AppSpacing.screenPad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(.isHeader)
                        .diaryDayPaging(viewModel)
                }
            }
        } else if let errorMessage = viewModel.errorMessage {
            Section {
                loadErrorState(errorMessage).diaryRow().diaryDayPaging(viewModel)
            }
        }
    }

    // MARK: - Summary

    private func summaryCard(healthEnergy: Double?) -> some View {
        let minutes = sessions.reduce(0.0) { $0 + ($1.durationMinutes ?? 0) }
        let burned = sessions.reduce(0.0) { $0 + ($1.caloriesBurned ?? 0) }
        return VStack(alignment: .leading, spacing: 12) {
            TrendStatRow(items: [
                .init(value: minutes > 0 ? ExerciseFormatting.duration(minutes) : "—", label: "Active time"),
                .init(value: "\(Int(burned.rounded()).formatted()) kcal", label: "Burned"),
                .init(value: "\(sessions.count)", label: sessions.count == 1 ? "Session" : "Sessions"),
            ])
            .contentTransition(.numericText())
            if let healthEnergy, healthEnergy > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .accessibilityHidden(true)
                    Text("\(Int(healthEnergy.rounded()).formatted()) kcal active energy from Apple Health")
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: - Rows

    private var logAgainTitle: String {
        viewModel.isViewingToday ? "Log again" : "Log again today"
    }

    private func logAgain(_ session: ExerciseSessionSummary) {
        // The clock's today, not the view model's: right even if the app
        // woke on a new day a moment before the rollover reached it.
        let target = Calendar.current.startOfDay(for: Date())
        let name = session.name ?? "Exercise"
        Task {
            if await viewModel.logAgain(session, on: target) {
                showToast(viewModel.isViewingToday ? "Logged \(name) again" : "Logged \(name) for today")
            }
        }
    }

    private func row(_ session: ExerciseSessionSummary) -> some View {
        let detail = ExerciseFormatting.detail(session, weightUnit: weightUnit, distanceUnit: distanceUnit)
        let name = session.name ?? "Exercise"
        let calories = Int((session.caloriesBurned ?? 0).rounded())
        return Button {
            guard session.exerciseId != nil else { return }
            viewModel.editingExerciseEntry = session
        } label: {
            HStack(spacing: 12) {
                Image(systemName: ExerciseCatalog.symbol(name: name, category: session.exerciseSnapshot?.category))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppColor.energy)
                    .frame(width: 40, height: 40)
                    .background(AppColor.energy.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        // Health's own heart, so an imported workout reads
                        // as "measured by your Watch", not typed in.
                        if session.isHealthWorkout {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.red)
                            Text("Apple Health ·").appBody(12).foregroundStyle(AppColor.secondaryText)
                        }
                        Text(detail.isEmpty ? session.effectiveModality.label : detail)
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                            .lineLimit(1)
                    }
                    if session.isHealthDuplicate {
                        // Same time as an imported workout: kept as typed, but
                        // the day counts Health's version once.
                        Label("Same as your Apple Health workout, counted once", systemImage: "heart.fill")
                            .labelStyle(.titleAndIcon)
                            .appBody(11)
                            .foregroundStyle(AppColor.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(calories.formatted())
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.energy)
                        .monospacedDigit()
                    Text("kcal")
                        .appBody(11)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppColor.surface)
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: AppRadius.md))
        .contextMenu {
            if session.exerciseId != nil {
                Button("Edit", systemImage: "pencil") { viewModel.editingExerciseEntry = session }
                Button(logAgainTitle, systemImage: "arrow.clockwise") { logAgain(session) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await viewModel.deleteExerciseEntry(session) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(session.isHealthWorkout ? "from Apple Health, " : "")\(session.isHealthDuplicate ? "same as an Apple Health workout, counted once, " : "")\(detail)")
        .accessibilityValue("\(calories) calories burned")
        .accessibilityHint(session.exerciseId != nil ? "Opens for editing" : "")
        .accessibilityActions {
            // Only where it can work, as in the context menu and swipe.
            if session.exerciseId != nil {
                Button(logAgainTitle) { logAgain(session) }
            }
        }
        .accessibilityAction(named: "Delete") {
            Task { await viewModel.deleteExerciseEntry(session) }
        }
    }

    // MARK: - States

    /// A failure with the day already on screen — a delete, Log again or a
    /// refresh — used to be a haptic and nothing else: `errorMessage` was
    /// only drawn when there was no day to show. Same banner as Food & Water.
    private var errorInset: some View {
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

    /// Says which day is empty, and offers the one thing to do about it.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.run")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppColor.energy)
                .frame(width: 64, height: 64)
                .background(AppColor.energy.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text("No workouts \(DiaryDayHeader.phrase(for: viewModel.selectedDate))")
                .appDisplay(20)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Log a run, a lift or a class. Anything you've logged before starts from last time.")
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Log a workout") {
                // A day swipe across the card ends on this button.
                guard !viewModel.isMidDaySwipe else { return }
                Haptics.light()
                viewModel.isPresentingExerciseSearch = true
            }
            .padding(.top, 6)
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
        .padding(.top, 12)
    }

    private func loadErrorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            ErrorBanner(message: message)
            PrimaryButton(title: "Retry") { Task { await viewModel.load() } }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, 40)
    }

    // MARK: - Bottom bar

    /// The "+" when there's a list to add to (the empty state carries its
    /// own button), and the "Log again" confirmation above it.
    private var bottomBar: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppColor.surface, in: Capsule())
                    .overlay(Capsule().stroke(AppColor.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !sessions.isEmpty {
                Button {
                    Haptics.light()
                    viewModel.isPresentingExerciseSearch = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(AppColor.accent, in: Circle())
                        .shadow(color: AppColor.accent.opacity(0.4), radius: 12, y: 6)
                }
                .buttonStyle(.pressableCompact)
                .accessibilityLabel("Log exercise")
                .padding(.trailing, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, 12)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: toast)
    }

    private func showToast(_ message: String) {
        toastID += 1
        let id = toastID
        toast = message
        AccessibilityNotification.Announcement(message).post()
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if toastID == id { toast = nil }
        }
    }
}

#Preview {
    ExerciseDiaryView(viewModel: DiaryViewModel(user: SessionUser(email: "demo@sparkyfitness.com", name: "Demo")))
}
