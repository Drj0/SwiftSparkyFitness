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
        _viewModel = StateObject(wrappedValue: ExerciseSearchViewModel())
        self.onLogged = onLogged
    }

    // The editor slides in inside this sheet rather than stacking a second
    // sheet: two stacked sheets close one after the other, which flashed Log
    // Exercise back up for a beat after saving.
    private var showsOwnManualEntry: Bool {
        ["noResults", "networkError"].contains(viewModel.outcome.kindID)
    }

    var body: some View {
        NavigationStack {
            searchContent
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $pushedExercise) { exercise in
                    ExerciseEntryEditorView(exercise: exercise, entryDate: entryDate, dismissesOnSave: false) {
                        if let onLogged { onLogged() } else { dismiss() }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                }
        }
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
        // What's on screen is what's likely to be picked: fetch those photos
        // now, so the editor opens with them already there.
        .task(id: prefetchNames) { ExercisePhotoStore.prefetch(prefetchNames) }
        .sheet(isPresented: $isPresentingCustomExercise) {
            CustomExerciseView(initialName: viewModel.query.trimmingCharacters(in: .whitespaces)) { exercise in
                pushedExercise = exercise
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            SheetHeader(title: "Log Exercise", onCancel: { dismiss() }, showsDivider: false)
            searchField
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)
        .task { isSearchFocused = true }
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

    @ViewBuilder
    private var resultsArea: some View {
        if let materializeError {
            ErrorBanner(message: materializeError)
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
        // Recent, then Popular from the built-in catalog: most logs are one
        // tap away without typing anything.
        VStack(spacing: 0) {
            if !viewModel.recentExercises.isEmpty {
                heading("RECENT")
                ForEach(viewModel.recentExercises) { exercise in
                    resultRow(.owned(exercise))
                }
            }
            heading("POPULAR")
            ForEach(viewModel.popularExercises) { entry in
                resultRow(.catalog(entry))
            }
        }
        .padding(.horizontal, 20)
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
        VStack(spacing: 0) {
            heading("RESULTS")
            ForEach(results) { result in
                resultRow(result)
            }
        }
        .padding(.horizontal, 20)
    }

    private func resultRow(_ result: ExerciseSearchResult) -> some View {
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
                    Text(subtitle(for: result)).appBody(12).foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                if materializingId == result.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                        .frame(width: 26, height: 26)
                        .background(AppColor.accentSoft, in: Circle())
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(materializingId != nil)
        .overlay(Rectangle().fill(AppColor.inputBackground).frame(height: 1), alignment: .bottom)
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
