//
//  WaterContainersView.swift
//  SwiftSparkyFitness
//
//  Manage the containers a water quick-add logs from.
//
//  The screen says what a tap is currently worth, because that's the thing
//  this changes: without a container the "+" logs the server's generic
//  250 ml, and it keeps doing so until one is marked primary.
//
//  Pushed from Settings, and a real `List`. Two things changed with it:
//  picking the container "+" uses is now selecting the row — with a checkmark
//  on the chosen one, the way every other "choose one of these" screen in iOS
//  works — instead of a "Use this" button that appeared on the rows you
//  hadn't chosen; and deleting is the system's swipe or Edit rather than a
//  trash button standing permanently beside it.
//

import SwiftUI

struct WaterContainersView: View {
    @StateObject private var viewModel = WaterContainersViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void = {}) {
        self.onChanged = onChanged
    }

    private var primary: WaterContainer? {
        viewModel.containers.first(where: \.isPrimary)
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
                if viewModel.isLoading && viewModel.containers.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if viewModel.containers.isEmpty {
                    Text("No containers yet.")
                        .appBody(14)
                        .foregroundStyle(AppColor.placeholder)
                        .frame(minHeight: 44)
                } else {
                    ForEach(viewModel.containers) { container in
                        row(container)
                    }
                    .onDelete(perform: delete)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    footnote(tapSummary)
                    if viewModel.containers.count > 1 {
                        footnote("Tap a container to make it the one “+” uses.")
                    }
                }
                .padding(.top, 2)
            }
            .listRowBackground(AppColor.surface)
            .listRowSeparatorTint(AppColor.hairline)

            Section {
                TextField("Water bottle", text: $viewModel.newName)
                    .appBody(15)
                    .foregroundStyle(AppColor.ink)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
                    .accessibilityLabel("Name of the container to add")

                HStack(spacing: 10) {
                    TextField("Volume", text: $viewModel.newVolume)
                        .appBody(15)
                        .foregroundStyle(AppColor.ink)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Volume in millilitres")
                    Text("ml")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    Spacer(minLength: 8)

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
            } header: {
                Text("ADD A CONTAINER")
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .accessibilityAddTraits(.isHeader)
            }
            .listRowBackground(AppColor.surface)
            .listRowSeparatorTint(AppColor.hairline)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        // Matches the row that opens it. "Water" on its own reads as the
        // logging feature, which this screen is not.
        .navigationTitle("Water Containers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !viewModel.containers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.containers)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
        .task { await viewModel.load() }
        .onDisappear(perform: onChanged)
    }

    private var tapSummary: String {
        guard let primary else {
            return "One tap of “+” logs 250 ml. Add a container to log what you actually drink from."
        }
        return "One tap of “+” logs \(Int(primary.mlPerServing.rounded())) ml, from “\(primary.name)”."
    }

    private func row(_ container: WaterContainer) -> some View {
        Button {
            guard !container.isPrimary else { return }
            // On the tap — see WaterContainersViewModel.setPrimary.
            Haptics.selection()
            Task { await viewModel.setPrimary(container) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                    Text(container.displayVolume)
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)
                }

                Spacer(minLength: 8)

                if viewModel.busyContainerId == container.id {
                    ProgressView().controlSize(.small)
                } else if container.isPrimary {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Selection, not a button: what a tap does is choose this one, and
        // VoiceOver should say which one is already chosen rather than
        // announcing four identical "buttons".
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(container.isPrimary ? [.isSelected] : [])
        .accessibilityHint(container.isPrimary ? "" : "Makes this the container quick add uses")
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { viewModel.containers[$0] }
        Task {
            for container in doomed {
                await viewModel.delete(container)
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
    NavigationStack { WaterContainersView() }
}
