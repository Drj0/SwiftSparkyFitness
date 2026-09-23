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

import SwiftUI

struct MealCategoriesView: View {
    @StateObject private var viewModel = MealCategoriesViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isNewFieldFocused: Bool
    @State private var renamingCategory: MealType?
    @State private var renameText = ""

    /// Called on dismiss so the screens that render these categories pick up
    /// additions, renames and visibility changes.
    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void = {}) {
        self.onChanged = onChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Meals", cancelTitle: "Done") {
                onChanged()
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                    }

                    if viewModel.isLoading && viewModel.categories.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ForEach(viewModel.categories) { category in
                            row(category)
                        }
                        addRow
                        Text("Hidden meals stay on days you already used them — they just stop being offered when you log something new.")
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.categories)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
            }
        }
        .background(AppColor.background)
        .task { await viewModel.load() }
        .alert("Rename meal", isPresented: .constant(renamingCategory != nil)) {
            TextField("Name", text: $renameText)
                .autocapitalization(.words)
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
                // Only a user's own category is renameable — the server
                // answers 403 for its four, so tapping one would just produce
                // an error. A default's name is plain text.
                if category.isSystemDefault {
                    Text(category.displayName)
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(category.visible ? AppColor.ink : AppColor.secondaryText)
                    Text("Built in")
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)
                } else {
                    Button {
                        renamingCategory = category
                        renameText = category.name
                    } label: {
                        HStack(spacing: 5) {
                            Text(category.displayName)
                                .appBody(15, weight: .semibold)
                                .foregroundStyle(category.visible ? AppColor.ink : AppColor.secondaryText)
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(AppColor.placeholder)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Rename \(category.displayName)")
                }
            }

            Spacer(minLength: 0)

            if viewModel.busyCategoryId == category.id {
                ProgressView()
            }

            Toggle("", isOn: Binding(
                get: { category.visible },
                set: { visible in Task { await viewModel.setVisible(visible, for: category) } }
            ))
            .labelsHidden()
            .tint(AppColor.accent)
            .accessibilityLabel("Show \(category.displayName)")

            // Only a user-created category can be deleted; the server answers
            // 403 for its own, so offering the control would be a lie.
            if !category.isSystemDefault {
                Button {
                    Task { await viewModel.delete(category) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(AppColor.destructive)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Delete \(category.displayName)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            AppTextField(
                placeholder: "Add a meal — e.g. Pre-Workout",
                text: $viewModel.newName,
                style: .filled,
                submitLabel: .done,
                autocapitalization: .words,
                focus: $isNewFieldFocused
            )
            .onSubmit { Task { await viewModel.create() } }

            Button {
                Task { await viewModel.create() }
            } label: {
                Text("Add")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(viewModel.canCreate ? AppColor.accent : AppColor.placeholder)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(!viewModel.canCreate)
        }
    }
}

#Preview {
    MealCategoriesView()
}
