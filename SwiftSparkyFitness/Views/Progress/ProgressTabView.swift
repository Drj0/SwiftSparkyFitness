//
//  ProgressTabView.swift
//  SwiftSparkyFitness
//
//  Module 6. The Progress tab: pick a range, see the trends.
//
//  Named `ProgressTabView` rather than `ProgressView` because SwiftUI
//  already owns that name and this file imports SwiftUI — shadowing it would
//  break every spinner in the app, including the one below.
//
//  Follows Today's scaffold (ScrollView → VStack → screen padding, title in
//  the serif display face, `.task` to load and `.refreshable` to reload) and
//  Diary's error rule: once data is on screen a failure appears as a banner
//  above it rather than replacing it, because a failed reload must not take
//  away the charts the user is already reading.
//

import SwiftUI

struct ProgressTabView: View {
    @StateObject private var viewModel: ProgressViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(user: SessionUser) {
        _viewModel = StateObject(wrappedValue: ProgressViewModel(user: user))
    }

    #if DEBUG
    /// Preview-only: renders against a pre-seeded view model instead of
    /// loading from the server.
    init(previewing viewModel: ProgressViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                rangeSelector
                if viewModel.preset == .custom { customRangeFields }

                if viewModel.isLoading && !viewModel.hasLoadedOnce {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if viewModel.hasAnyData {
                    cards
                } else if viewModel.hasLoadedOnce {
                    emptyState
                }
            }
            .padding(AppSpacing.screenPad)
            // A reload over existing charts dims them rather than blanking
            // the screen, the same way Diary handles paging to a new day.
            .opacity(viewModel.isLoading && viewModel.hasLoadedOnce ? 0.5 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.isLoading)
        }
        .background(AppColor.background)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .safeAreaInset(edge: .top) { errorBanner }
        .onChange(of: viewModel.errorMessage) { _, message in
            // The banner appears without moving VoiceOver focus, so it has to
            // announce itself or it is silent to a screen-reader user.
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Progress")
                .appDisplay(26)
                .foregroundStyle(AppColor.ink)
            Text(viewModel.rangeDescription)
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Range

    private var rangeSelector: some View {
        HStack(spacing: 6) {
            ForEach(ProgressRangePreset.allCases) { option in
                let isSelected = viewModel.preset == option
                Button {
                    if viewModel.preset != option {
                        Haptics.selection()
                        viewModel.preset = option
                    }
                } label: {
                    Text(option.label)
                        .appBody(13, weight: .semibold)
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
        .accessibilityLabel("Time range")
    }

    private var customRangeFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker(
                "From",
                selection: $viewModel.customStart,
                in: viewModel.minDate...viewModel.maxDate,
                displayedComponents: .date
            )
            DatePicker(
                "To",
                selection: $viewModel.customEnd,
                in: viewModel.minDate...viewModel.maxDate,
                displayedComponents: .date
            )
            if viewModel.didClampCustomRange {
                // The endpoints behind this screen have no server-side range
                // cap — they loop day by day instead of rejecting a silly
                // span — so the clamp is the client's, and saying so beats
                // quietly showing less than was asked for.
                Text("Showing the most recent \(ProgressDateRange.maximumDays) days of that range.")
                    .appBody(11)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .appBody(13)
        .foregroundStyle(AppColor.ink)
        .tint(AppColor.accent)
        .padding(AppSpacing.cardPad)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: - Content

    private var cards: some View {
        VStack(spacing: 14) {
            WeightTrendCard(viewModel: viewModel)
            NutritionTrendCard(viewModel: viewModel)
            ExerciseSummaryCard(viewModel: viewModel)
            MeasurementsTrendCard(viewModel: viewModel)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("📈")
                .font(.system(size: 40))
                .accessibilityHidden(true)
            Text("Nothing to chart yet")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
            Text("Log food, exercise or a weight and your trends will build up here.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 60)
    }

    @ViewBuilder
    private var errorBanner: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage, viewModel.hasLoadedOnce {
                ErrorBanner(message: message)
                    .padding(.horizontal, AppSpacing.screenPad)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
    }
}

#if DEBUG
#Preview("Progress — a month of data") {
    ProgressTabView(previewing: .previewSample())
}

#Preview("Progress — nothing logged") {
    ProgressTabView(previewing: .preview())
}
#endif
