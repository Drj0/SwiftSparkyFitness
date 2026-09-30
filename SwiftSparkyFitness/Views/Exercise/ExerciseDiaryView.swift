//
//  ExerciseDiaryView.swift
//  SwiftSparkyFitness
//
//  The Exercise tab's primary segment (Module 12) — a day view of logged
//  sessions, replacing the read-only exercise section Diary used to carry.
//  Shares `DiaryViewModel` with the "Food & Water" segment (`DiaryView`) so
//  both read one day's data and one date position, rather than loading the
//  same `GET /api/daily-summary` twice.
//
//  Each row's subtitle branches on `effectiveModality` — sets/reps for
//  strength, distance for cardio — rather than always showing "N minutes",
//  which is the flat shape the old Diary row assumed and the real schema
//  doesn't have.
//

import SwiftUI

struct ExerciseDiaryView: View {
    @ObservedObject var viewModel: DiaryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sessions: [ExerciseSessionSummary] {
        viewModel.summary?.exerciseSessions.userLogged ?? []
    }

    var body: some View {
        List {
            Section {
                dateHeader.diaryRow()
            }

            content
                .id(viewModel.selectedDate)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .safeAreaInset(edge: .bottom) { fab }
        .sheet(item: $viewModel.editingExerciseEntry, onDismiss: { Task { await viewModel.load() } }) { entry in
            ExerciseEntryEditorView(editing: entry, exercise: entry.asExercise) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.isPresentingExerciseSearch, onDismiss: { Task { await viewModel.load() } }) {
            ExerciseSearchView {
                viewModel.isPresentingExerciseSearch = false
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.summary == nil {
            Section {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40).diaryRow()
            }
        } else if viewModel.summary != nil {
            Section {
                if sessions.isEmpty {
                    emptyState.diaryRow()
                } else {
                    ForEach(sessions) { session in
                        row(session)
                            .padding(.horizontal, AppSpacing.screenPad)
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
                    }
                }
            } header: {
                if !sessions.isEmpty {
                    let total = sessions.reduce(0.0) { $0 + ($1.caloriesBurned ?? 0) }
                    Text("\(Int(total)) kcal")
                        .appBody(12, weight: .semibold)
                        .foregroundStyle(AppColor.secondaryText)
                        .textCase(.uppercase)
                        .padding(.horizontal, AppSpacing.screenPad)
                }
            }
        } else if let errorMessage = viewModel.errorMessage {
            Section {
                loadErrorState(errorMessage).diaryRow()
            }
        }
    }

    private var dateHeader: some View {
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
            .accessibilityLabel("Previous day")

            Text(Self.dateFormatter.string(from: viewModel.selectedDate))
                .appBody(13, weight: .semibold)
                .foregroundStyle(AppColor.secondaryText)
                .frame(maxWidth: .infinity)

            Button { Haptics.selection(); viewModel.goToNextDay() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(viewModel.canGoToNextDay ? AppColor.accent : AppColor.placeholder)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!viewModel.canGoToNextDay)
            .buttonStyle(.pressableCompact)
            .accessibilityLabel("Next day")
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, 8)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    private var fab: some View {
        HStack {
            Spacer()
            Button {
                Haptics.light()
                viewModel.isPresentingExerciseSearch = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(AppColor.accent, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Log exercise")
            .padding(.trailing, 20)
            .padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🏋️").font(.system(size: 36))
            Text("Nothing logged")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
            Text("Tap + to log a workout.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
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

    private func row(_ session: ExerciseSessionSummary) -> some View {
        Button {
            guard session.exerciseId != nil else { return }
            viewModel.editingExerciseEntry = session
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name ?? "Exercise").appBody(15, weight: .semibold).foregroundStyle(AppColor.ink)
                    HStack(spacing: 4) {
                        // Health's own heart, so an imported workout reads
                        // as "measured by your Watch", not typed in.
                        if session.isHealthWorkout {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.red)
                            Text("Apple Health ·").appBody(12).foregroundStyle(AppColor.secondaryText)
                        }
                        Text(subtitle(session)).appBody(12).foregroundStyle(AppColor.secondaryText)
                    }
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
        .accessibilityLabel("\(session.name ?? "Exercise"), \(session.isHealthWorkout ? "from Apple Health, " : "")\(subtitle(session))")
        .accessibilityValue("\(Int(session.caloriesBurned ?? 0)) calories burned")
        .accessibilityHint("Opens for editing")
    }

    /// Branches on modality rather than always showing "N minutes" — the
    /// one line a modality-driven schema should also render as, not just log.
    private func subtitle(_ session: ExerciseSessionSummary) -> String {
        switch session.effectiveModality {
        case .weightReps, .repsOnly:
            // Identical sets say the numbers that matter — "3 × 8 · 60 kg" —
            // rather than a count and a duration that is usually estimated.
            let sets = session.setsList
            if let first = sets.first, let reps = first.reps,
               sets.allSatisfy({ $0.reps == first.reps && $0.weight == first.weight }) {
                let weightPart = first.weight.map { " · \($0.formatted(.number.precision(.fractionLength(0...1)))) kg" } ?? ""
                return "\(sets.count) × \(reps)\(weightPart)"
            }
            let setCount = sets.count
            let durationPart = session.durationMinutes.map { "\(Int($0)) min" }
            return [setCount > 0 ? "\(setCount) set\(setCount == 1 ? "" : "s")" : nil, durationPart]
                .compactMap { $0 }.joined(separator: " · ")
        case .durationDistance:
            let distancePart = session.distance.map { String(format: "%.1f %@", $0, viewModel.preferences.distanceUnitLabel) }
            let durationPart = session.durationMinutes.map { "\(Int($0)) min" }
            return [distancePart, durationPart].compactMap { $0 }.joined(separator: " · ")
        case .duration:
            return session.durationMinutes.map { "\(Int($0)) min" } ?? ""
        }
    }
}

#Preview {
    ExerciseDiaryView(viewModel: DiaryViewModel(user: SessionUser(email: "demo@sparkyfitness.com", name: "Demo")))
}
