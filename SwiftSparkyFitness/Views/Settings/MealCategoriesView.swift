//
//  MealCategoriesView.swift
//  SwiftSparkyFitness
//
//  Manage the meal categories food is logged into.
//
//  The server's four defaults and the user's own categories are deliberately
//  shown in one list rather than split into two sections: they're the same
//  thing to the person logging a meal, and the differences (a default can't
//  be renamed or deleted) are better expressed by which controls a row
//  offers than by a heading that would need explaining.
//
//  Pushed from Settings, and a real `List`, which is where the editing
//  controls come from now: swipe left to delete, swipe right to rename, or
//  use Edit for a tap-only path to the same thing. That replaces a trash
//  button and a pencil glyph parked on every row — two permanent targets for
//  a rare, irreversible action, sitting next to the toggle you actually came
//  to flip. `deleteDisabled` marks the server's four, so neither the swipe
//  nor Edit offers a delete the server would answer 403 to.
//

import SwiftUI

struct MealCategoriesView: View {
    @StateObject private var viewModel = MealCategoriesViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isNewFieldFocused: Bool
    @State private var renamingCategory: MealType?
    @State private var renameText = ""

    /// Called on the way out so the screens that render these categories pick
    /// up additions, renames and visibility changes.
    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void = {}) {
        self.onChanged = onChanged
    }

    private var hasOwnCategories: Bool {
        viewModel.categories.contains { !$0.isSystemDefault }
    }

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if viewModel.isLoading && viewModel.categories.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    ForEach(viewModel.categories) { category in
                        row(category)
                            .deleteDisabled(category.isSystemDefault)
                    }
                    .onDelete(perform: delete)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    footnote("Hidden meals stay on days you already used them — they just stop being offered when you log something new.")
                    // Advice about nothing until there's something to swipe.
                    if hasOwnCategories {
                        footnote("Swipe a meal you added to rename or delete it.")
                    }
                }
                .padding(.top, 2)
            }
            .listRowBackground(AppColor.surface)
            .listRowSeparatorTint(AppColor.hairline)

            Section {
                addRow
            } header: {
                Text("ADD A MEAL")
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .accessibilityAddTraits(.isHeader)
            }
            .listRowBackground(AppColor.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .navigationTitle("Meals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The tap-only route to a delete. Hidden until there's something
            // it could act on — the server's four can't be deleted, so Edit
            // over only those would open a mode with nothing to do in it.
            if hasOwnCategories {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.categories)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
        .task { await viewModel.load() }
        .onDisappear(perform: onChanged)
        .alert("Rename meal", isPresented: .constant(renamingCategory != nil)) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { renamingCategory = nil }
            Button("Rename") {
                if let renamingCategory {
                    Task { await viewModel.rename(renamingCategory, to: renameText) }
                }
                renamingCategory = nil
            }
        }
    }

    private func row(_ category: MealType) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(category.visible ? AppColor.ink : AppColor.secondaryText)
                Text(category.isSystemDefault ? "Built in" : "Added by you")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
            }

            Spacer(minLength: 8)

            if viewModel.busyCategoryId == category.id {
                ProgressView().controlSize(.small)
            }

            Toggle("", isOn: Binding(
                get: { category.visible },
                set: { visible in
                    // On the flip, not on the server's reply — see
                    // MealCategoriesViewModel.setVisible.
                    Haptics.selection()
                    Task { await viewModel.setVisible(visible, for: category) }
                }
            ))
            .labelsHidden()
            .tint(AppColor.accent)
            .accessibilityLabel("Show \(category.displayName)")
        }
        .frame(minHeight: 44)
        // Leading, so the trailing edge stays the system's own delete — the
        // gesture people already have muscle memory for, and the one Edit
        // mode mirrors. Only a user's own category is renameable: the server
        // answers 403 for its four.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !category.isSystemDefault {
                Button {
                    renamingCategory = category
                    renameText = category.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(AppColor.accent)
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            TextField("e.g. Pre-Workout", text: $viewModel.newName)
                .appBody(15)
                .foregroundStyle(AppColor.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isNewFieldFocused)
                .onSubmit { Task { await viewModel.create() } }
                .accessibilityLabel("Name of the meal to add")

            Button {
                Task { await viewModel.create() }
            } label: {
                Text("Add")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(viewModel.canCreate ? AppColor.accent : AppColor.placeholder)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(!viewModel.canCreate)
        }
    }

    /// `deleteDisabled` already keeps the server's four out of an offset set,
    /// so this doesn't re-check; it only exists because `onDelete` hands back
    /// indices rather than rows.
    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { viewModel.categories[$0] }
        Task {
            for category in doomed {
                await viewModel.delete(category)
            }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .appBody(12)
            .foregroundStyle(AppColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    NavigationStack { MealCategoriesView() }
}
