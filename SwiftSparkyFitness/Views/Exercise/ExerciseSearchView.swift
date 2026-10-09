//
//  ExerciseSearchView.swift
//  SwiftSparkyFitness
//
//  Log Exercise search sheet — the exercise-tab counterpart of
//  FoodSearchView, same three-state results area (idle/results/noResults/
//  networkError) and same idle-state recents.
//
//  Tapping an external (Free Exercise DB / Wger) result materializes it into
//  the user's own library first — required, since `exercise_entries.exercise_id`
//  FKs to that table, not the provider's — then opens the entry editor on the
//  materialized exercise. Tapping an already-owned result (a custom exercise,
//  or one materialized before) skips straight to the editor.
//

import SwiftUI

struct ExerciseSearchView: View {
    @StateObject private var viewModel: ExerciseSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pushedExercise: Exercise?
    @State private var isPresentingCustomExercise = false
    @State private var materializingId: String?
    @State private var materializeError: String?
    @FocusState private var isSearchFocused: Bool
    /// Called once an exercise is logged. The presenter should close this
    /// sheet by its own binding: that removes Log Exercise and the editor in
    /// one animation (see FoodSearchView for the flicker this avoids). nil
    /// falls back to this sheet dismissing itself.
    private let onLogged: (() -> Void)?
    /// The day a picked exercise is logged to — Today can be viewing a past day.
    private let entryDate: Date

    init(entryDate: Date = Date(), onLogged: (() -> Void)? = nil) {
        self.entryDate = entryDate
        _viewModel = StateObject(wrappedValue: ExerciseSearchViewModel(entryDate: entryDate))
        self.onLogged = onLogged
    }

    // The editor slides in inside this sheet rather than stacking a second
    // sheet: two stacked sheets close one after the other, which flashed Log
    // Exercise back up for a beat after saving. Slid over by hand, not
    // pushed on a NavigationStack: inside one, the sheet ignored the
    // editor's height and stayed full height around a half-empty form.
    private var showsOwnManualEntry: Bool {
        ["noResults", "networkError"].contains(viewModel.outcome.kindID)
    }

    var body: some View {
        ZStack {
            searchContent
                .accessibilityHidden(pushedExercise != nil)
                // A navigation push's parallax: the list drifts left under
                // the incoming detail rather than sitting still.
                .visualEffect { [isPushed = pushedExercise != nil] content, proxy in
                    content.offset(x: isPushed ? -proxy.size.width * 0.3 : 0)
                }
            if let exercise = pushedExercise {
                ExerciseEntryEditorView(
                    exercise: exercise, entryDate: entryDate,
                    lastSession: viewModel.lastSession(for: exercise.name), dismissesOnSave: false
                ) {
                    if let onLogged { onLogged() } else { dismiss() }
                }
                .onClose { pushedExercise = nil }
                .id(exercise.id)
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .sheetResize, value: pushedExercise?.id)
        .sheetHeightIgnored(pushedExercise == nil)
        // The list stays mounted under the detail, so its search field
        // would keep the keyboard up over it.
        .onChange(of: pushedExercise?.id) { _, id in if id != nil { isSearchFocused = false } }
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                resultsArea
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.isSearching)

            // The empty and error states carry this same action as their
            // main button; a second copy under them read as noise.
            if !showsOwnManualEntry {
                Button {
                    isPresentingCustomExercise = true
                } label: {
                    Text("+ Create custom exercise")
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .top)
            }
        }
        .background(AppColor.surface)
        .scrollDismissesKeyboard(.interactively)
        .task { await viewModel.loadRecents() }
        .task { await viewModel.loadWeight() }
        .task { await viewModel.loadHistory() }
        // What's on screen is what's likely to be picked: fetch those photos
        // now, so the editor opens with them already there.
        .task(id: prefetchNames) { ExercisePhotoStore.prefetch(prefetchNames) }
        .sheet(isPresented: $isPresentingCustomExercise) {
            CustomExerciseView(initialName: viewModel.query.trimmingCharacters(in: .whitespaces)) { exercise in
                // A custom exercise has no rate of its own; this gives it the
                // typical one for its kind, so calories start estimated.
                pushedExercise = viewModel.withBestRate(exercise)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // Browse-first: the search field no longer takes focus on open. With
    // it focused, the keyboard covered all but the first five suggestions —
    // and most logs are a recent or a popular exercise, not a typed name.
    private var header: some View {
        VStack(spacing: 10) {
            SheetHeader(title: "Log Exercise", onCancel: { dismiss() }, showsDivider: false)
            searchField
            if viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty {
                categoryChips
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)
        .task(id: viewModel.query) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await viewModel.search()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppColor.placeholder)
                .accessibilityHidden(true)
            TextField("Search exercises", text: $viewModel.query)
                .appBody(15)
                .foregroundStyle(AppColor.ink)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .accessibilityLabel("Search exercises")
                .onSubmit { Task { await viewModel.search() } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppColor.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, AppSpacing.screenPad)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ExerciseCategoryFilter.allCases) { option in
                    TrendChip(title: option.label, isSelected: viewModel.category == option) {
                        guard viewModel.category != option else { return }
                        Haptics.selection()
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { viewModel.category = option }
                    }
                }
            }
        }
        .contentMargins(.horizontal, AppSpacing.screenPad, for: .scrollContent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Exercise type")
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let materializeError {
            ErrorBanner(message: materializeError)
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, 10)
        }
        if let quickLogError = viewModel.quickLogError {
            ErrorBanner(message: quickLogError)
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, 10)
        }
        if viewModel.isSearching && !viewModel.hasResults {
            searchingState
        } else {
            switch viewModel.outcome {
            case .idle:
                idlePrompt
            case .results(let results):
                resultsListContent(results)
                    .opacity(viewModel.isSearching ? 0.45 : 1)
            case .noResults(let query):
                NoResultsView(
                    query: query, subject: "exercise database", manualEntryLabel: "Create custom exercise"
                ) { isPresentingCustomExercise = true }
                    .padding(.top, 48)
            case .networkError:
                SearchNetworkErrorView(
                    subject: "exercise database", manualEntryLabel: "Create custom exercise",
                    onRetry: { Task { await viewModel.search() } },
                    onManualEntry: { isPresentingCustomExercise = true }
                )
                .padding(.top, 48)
            }
        }
    }

    @ViewBuilder
    private var idlePrompt: some View {
        // Recent, then the catalog for the chosen kind: most logs are one
        // tap away without typing anything, and a repeat is one tap total.
        LazyVStack(spacing: 0) {
            let recents = viewModel.visibleRecents
            if !recents.isEmpty {
                heading("RECENT")
                ForEach(recents) { exercise in
                    resultRow(.owned(exercise), quickLog: exercise)
                }
            }
            heading(viewModel.category == .all ? "POPULAR" : viewModel.category.label.uppercased())
            ForEach(viewModel.browseExercises) { entry in
                resultRow(.catalog(entry))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var searchingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(AppColor.accent)
            Text("Searching…").appBody(13).foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .accessibilityElement(children: .combine)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .appBody(11, weight: .semibold)
            .foregroundStyle(AppColor.placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func resultsListContent(_ results: [ExerciseSearchResult]) -> some View {
        LazyVStack(spacing: 0) {
            heading("RESULTS")
            ForEach(results) { result in
                resultRow(result)
            }
        }
        .padding(.horizontal, 20)
    }

    /// One exercise. A recent one carries what was done last time and a
    /// "+" that logs it again as-is; everything else opens the editor,
    /// which starts from the last session when there is one.
    private func resultRow(_ result: ExerciseSearchResult, quickLog exercise: Exercise? = nil) -> some View {
        let last = viewModel.lastSessionSummary(for: result.name, modality: result.modality)
        let canQuickLog = exercise != nil && last != nil
        return HStack(spacing: 12) {
            Button {
                select(result)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: result.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AppColor.accent)
                        .frame(width: 36, height: 36)
                        .background(AppColor.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name).appBody(15, weight: .semibold).foregroundStyle(AppColor.ink)
                        Text(last ?? subtitle(for: result))
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if materializingId == result.id {
                        ProgressView().controlSize(.small)
                    } else if !canQuickLog {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColor.placeholder)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(materializingId != nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(result.name)
            .accessibilityValue(last.map { "Last time: \($0)" } ?? subtitle(for: result))
            .accessibilityHint(last == nil ? "Opens to log it" : "Opens to log it, filled in from last time")

            if let exercise, canQuickLog {
                quickLogButton(exercise, summary: last ?? "")
            }
        }
        .overlay(Rectangle().fill(AppColor.inputBackground).frame(height: 1), alignment: .bottom)
    }

    /// Logs the recent exercise again exactly as last time, without leaving
    /// the sheet — a check confirms it, and the sheet stays for the next.
    private func quickLogButton(_ exercise: Exercise, summary: String) -> some View {
        let isDone = viewModel.justLogged.contains(exercise.id)
        let isBusy = viewModel.quickLoggingId == exercise.id
        return Button {
            Task { await viewModel.quickLog(exercise) }
        } label: {
            ZStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isDone ? "checkmark" : "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isDone ? AppColor.energy : AppColor.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 30, height: 30)
            .background(isDone ? AppColor.energy.opacity(0.14) : AppColor.accentSoft, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCompact)
        .disabled(isBusy || viewModel.quickLoggingId != nil)
        .accessibilityLabel(isDone ? "Logged \(exercise.name)" : "Log \(exercise.name) again")
        .accessibilityHint(isDone ? "Tap to log it once more" : "Same as last time: \(summary)")
    }

    /// The first screenful — results can run long, and each photo is a
    /// download.
    private var prefetchNames: [String] {
        let names: [String]
        switch viewModel.outcome {
        case .results(let results): names = results.map(\.name)
        default: names = viewModel.recentExercises.map(\.name) + viewModel.popularExercises.map(\.name)
        }
        return Array(names.prefix(10))
    }

    private func subtitle(for result: ExerciseSearchResult) -> String {
        var parts: [String] = []
        if let category = result.category { parts.append(category.capitalized) }
        if let source = result.sourceLabel { parts.append(source) }
        return parts.isEmpty ? "Exercise" : parts.joined(separator: " · ")
    }

    private func select(_ result: ExerciseSearchResult) {
        materializeError = nil
        materializingId = result.id
        Task {
            defer { materializingId = nil }
            // Alongside materializing, which already shows the row's
            // spinner: the editor then opens with its photos in place
            // rather than popping them in a moment later.
            async let photos: Void = ExercisePhotoStore.waitForPhotos(of: result.name, upTo: .seconds(1.5))
            do {
                let exercise = try await viewModel.exercise(for: result)
                await photos
                pushedExercise = exercise
            } catch {
                materializeError = error.localizedDescription
                Haptics.error()
            }
        }
    }
}

#Preview {
    ExerciseSearchView()
}
