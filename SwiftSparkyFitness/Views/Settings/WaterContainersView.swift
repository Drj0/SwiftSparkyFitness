//
//  WaterContainersView.swift
//  SwiftSparkyFitness
//
//  Manage the containers a water quick-add logs from.
//
//  The screen leads with what a tap is currently worth, because that's the
//  thing this changes: without a container the "+" logs the server's generic
//  250 ml, and it keeps doing so until one is marked primary.
//

import SwiftUI

struct WaterContainersView: View {
    @StateObject private var viewModel = WaterContainersViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void = {}) {
        self.onChanged = onChanged
    }

    private var primary: WaterContainer? {
        viewModel.containers.first(where: \.isPrimary)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Water", cancelTitle: "Done") {
                onChanged()
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                    }

                    Text(tapSummary)
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    if viewModel.isLoading && viewModel.containers.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ForEach(viewModel.containers) { container in
                            row(container)
                        }
                        addRow
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.containers)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
            }
        }
        .background(AppColor.background)
        .task { await viewModel.load() }
    }

    private var tapSummary: String {
        guard let primary else {
            return "One tap of “+” logs 250 ml — the server's default. Add a container to log what you actually drink from."
        }
        return "One tap of “+” logs \(Int(primary.mlPerServing.rounded())) ml, from “\(primary.name)”."
    }

    private func row(_ container: WaterContainer) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                Text(container.isPrimary ? "\(container.displayVolume) · used by +" : container.displayVolume)
                    .appBody(12)
                    .foregroundStyle(container.isPrimary ? AppColor.accent : AppColor.secondaryText)
            }

            Spacer(minLength: 0)

            if viewModel.busyContainerId == container.id {
                ProgressView()
            } else if !container.isPrimary {
                Button {
                    Task { await viewModel.setPrimary(container) }
                } label: {
                    Text("Use this")
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }

            Button {
                Task { await viewModel.delete(container) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.destructive)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Delete \(container.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(container.isPrimary ? AppColor.accent : AppColor.hairline, lineWidth: 1)
        )
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppTextField(
                placeholder: "Name — e.g. Water bottle",
                text: $viewModel.newName,
                style: .filled,
                autocapitalization: .sentences
            )
            HStack(spacing: 10) {
                AppTextField(
                    placeholder: "Volume",
                    text: $viewModel.newVolume,
                    style: .filled,
                    keyboardType: .decimalPad,
                    suffix: "ml"
                )
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
}

#Preview {
    WaterContainersView()
}
