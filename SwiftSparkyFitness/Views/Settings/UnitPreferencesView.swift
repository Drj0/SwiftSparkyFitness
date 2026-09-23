//
//  UnitPreferencesView.swift
//  SwiftSparkyFitness
//
//  Picks the units the app labels numbers with. See UnitPreferencesViewModel
//  for why nothing is converted — and why the screen says so.
//

import SwiftUI

struct UnitPreferencesView: View {
    @StateObject private var viewModel = UnitPreferencesViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void = {}) {
        self.onChanged = onChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Units", cancelTitle: "Done") {
                onChanged()
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                    }

                    ForEach(UserPreferences.Setting.allCases) { setting in
                        picker(setting)
                    }

                    // Worth stating plainly: a relabel that leaves the number
                    // alone looks like a bug the first time you hit it.
                    Text("Changing a unit relabels your numbers — it doesn't convert them. A weight stored as 73.5 stays 73.5. This matches the web app, which writes whatever you type.")
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
            }
        }
        .background(AppColor.background)
        .task { await viewModel.load() }
    }

    private func picker(_ setting: UserPreferences.Setting) -> some View {
        let current = viewModel.preferences.value(for: setting)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(setting.title.uppercased())
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                if viewModel.busySetting == setting {
                    ProgressView().scaleEffect(0.7)
                }
            }

            HStack(spacing: 8) {
                ForEach(setting.options, id: \.value) { option in
                    let isSelected = option.value == current
                    Button {
                        Task { await viewModel.select(option.value, for: setting) }
                    } label: {
                        Text(option.label)
                            .appBody(14, weight: .semibold)
                            .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(isSelected ? AppColor.accent : AppColor.inputBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }

            // A compound unit set from the web client can't be represented by
            // these options, so say what's stored rather than silently showing
            // nothing selected.
            if !setting.options.contains(where: { $0.value == current }) {
                Text("Currently “\(current)”, set elsewhere — this app can't show that as a single number.")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    UnitPreferencesView()
}
