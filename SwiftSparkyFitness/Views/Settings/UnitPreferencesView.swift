//
//  UnitPreferencesView.swift
//  SwiftSparkyFitness
//
//  Picks the units the app labels numbers with. See UnitPreferencesViewModel
//  for why nothing is converted — and why the screen says so.
//
//  Pushed from Settings rather than presented: there is nothing here to
//  commit, so a sheet's "Done" would only have been a way out of a screen
//  that never needed one. Each choice writes immediately.
//
//  The four settings are menu pickers rather than rows of chips. A picker
//  shows the *current* value on the row itself, which is the thing you came
//  here to check, and it collapses four two-line groups into four lines.
//

import SwiftUI

struct UnitPreferencesView: View {
    @StateObject private var viewModel = UnitPreferencesViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void = {}) {
        self.onChanged = onChanged
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
                ForEach(UserPreferences.Setting.allCases) { setting in
                    row(setting)
                }
            } footer: {
                // Worth stating plainly: a relabel that leaves the number
                // alone looks like a bug the first time you hit it.
                Text("Changing a unit relabels your numbers — it doesn't convert them. A weight stored as 73.5 stays 73.5.")
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .listRowBackground(AppColor.surface)
            .listRowSeparatorTint(AppColor.hairline)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .navigationTitle("Units")
        .navigationBarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
        .task { await viewModel.load() }
        // On the way out rather than on a Done tap: the writes already
        // happened, and the screens that render these labels still need
        // telling.
        .onDisappear(perform: onChanged)
    }

    private func row(_ setting: UserPreferences.Setting) -> some View {
        let current = viewModel.preferences.value(for: setting)
        return HStack(spacing: 8) {
            Picker(selection: binding(for: setting)) {
                ForEach(options(for: setting), id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Text(setting.title)
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
            }
            .pickerStyle(.menu)
            .tint(AppColor.secondaryText)
            // A bare "kg" read on its own doesn't say what it sets.
            .accessibilityLabel(setting.title)
            .accessibilityValue(label(for: current, in: setting))

            if viewModel.busySetting == setting {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minHeight: 36)
    }

    private func binding(for setting: UserPreferences.Setting) -> Binding<String> {
        Binding(
            get: { viewModel.preferences.value(for: setting) },
            set: { value in
                // As the choice is made — see UnitPreferencesViewModel.select.
                guard value != viewModel.preferences.value(for: setting) else { return }
                Haptics.selection()
                Task { await viewModel.select(value, for: setting) }
            }
        )
    }

    /// A compound unit set from the web client (`st_lbs`, `ft_in`) isn't one
    /// this app offers, and a `Picker` whose selection matches no tag renders
    /// *blank* — so the stored value is added as an option, named for what it
    /// is. Picking it back is a no-op the view model drops; picking anything
    /// else is how you leave it, which is the only sane exit and was
    /// previously a sentence explaining you couldn't.
    private func options(for setting: UserPreferences.Setting) -> [(value: String, label: String)] {
        let offered = setting.options
        let current = viewModel.preferences.value(for: setting)
        guard !offered.contains(where: { $0.value == current }) else { return offered }
        return offered + [(value: current, label: "\(current) (set elsewhere)")]
    }

    private func label(for value: String, in setting: UserPreferences.Setting) -> String {
        options(for: setting).first { $0.value == value }?.label ?? value
    }
}

#Preview {
    NavigationStack { UnitPreferencesView() }
}
