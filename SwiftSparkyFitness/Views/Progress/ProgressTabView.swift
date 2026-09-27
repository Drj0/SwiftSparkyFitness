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
        HStack(alignment: .center, spacing: 12) {
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

            rangeSelector
        }
    }

    // MARK: - Range

    /// One pill showing the current range; tapping it opens the choices,
    /// like Reddit's sort control. Four equal buttons spent a whole row on a
    /// setting that changes rarely.
    private var rangeSelector: some View {
        Menu {
            Picker("Time range", selection: presetSelection) {
                ForEach(ProgressRangePreset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.preset.label)
                    .appBody(13, weight: .semibold)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(AppColor.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppColor.inputBackground)
            .clipShape(Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Time range")
        .accessibilityValue(viewModel.preset.label)
    }

    private var presetSelection: Binding<ProgressRangePreset> {
        Binding(
            get: { viewModel.preset },
            set: { option in
                guard option != viewModel.preset else { return }
                Haptics.selection()
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { viewModel.preset = option }
            }
        )
    }

    private var customRangeFields: some View {
        CustomRangeCard(
            start: $viewModel.customStart,
            end: $viewModel.customEnd,
            minDate: viewModel.minDate,
            maxDate: viewModel.maxDate,
            dayCount: viewModel.range.dayCount,
            didClamp: viewModel.didClampCustomRange
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
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

// MARK: - Custom range

/// Two date tiles, From → To, each opening Today's graphical calendar. The
/// system compact pickers it replaces stacked label-left/value-right rows and
/// formatted the two dates differently depending on whether the value sat on
/// the range floor.
private struct CustomRangeCard: View {
    @Binding var start: Date
    @Binding var end: Date
    let minDate: Date
    let maxDate: Date
    let dayCount: Int
    let didClamp: Bool

    private enum RangeEnd: Identifiable { case start, end; var id: Self { self } }
    @State private var editing: RangeEnd?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                tile(.start, caption: "From", date: start)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.secondaryText)
                    .accessibilityHidden(true)
                tile(.end, caption: "To", date: end)
            }

            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(dayCount == 1 ? "1 day" : "\(dayCount) days")
                    .appBody(12, weight: .semibold)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(AppColor.secondaryText)

            if didClamp {
                // The endpoints behind this screen have no server-side range
                // cap — they loop day by day instead of rejecting a silly
                // span — so the clamp is the client's, and saying so beats
                // quietly showing less than was asked for.
                Text("Showing the most recent \(ProgressDateRange.maximumDays) days of that range.")
                    .appBody(11)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(AppSpacing.cardPad)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func tile(_ edge: RangeEnd, caption: String, date: Date) -> some View {
        let isEditing = editing == edge
        return Button {
            Haptics.selection()
            editing = edge
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(caption.uppercased())
                    .appBody(10, weight: .semibold)
                    .tracking(0.6)
                    .foregroundStyle(isEditing ? AppColor.accent : AppColor.secondaryText)
                Text(date.formatted(.dateTime.day().month(.abbreviated)))
                    .appDisplay(20)
                    .foregroundStyle(AppColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle(for: date))
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isEditing ? AppColor.accentSoft : AppColor.inputBackground)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(isEditing ? AppColor.accent : .clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(caption), \(date.formatted(date: .complete, time: .omitted))")
        .accessibilityHint("Opens a calendar")
        .popover(isPresented: Binding(
            get: { editing == edge },
            set: { if !$0 { editing = nil } }
        )) {
            calendar(for: edge)
        }
    }

    private func calendar(for edge: RangeEnd) -> some View {
        // Each end is bounded by the other so the range can't invert.
        let bounds = edge == .start
            ? minDate...max(minDate, min(end, maxDate))
            : min(max(start, minDate), maxDate)...maxDate
        return DatePicker(
            edge == .start ? "From" : "To",
            selection: Binding(
                get: { edge == .start ? start : end },
                set: { day in
                    if edge == .start { start = day } else { end = day }
                    editing = nil
                }
            ),
            in: bounds,
            displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .labelsHidden()
        .tint(AppColor.accent)
        .frame(width: 320)
        .padding(12)
        .presentationCompactAdaptation(.popover)
    }

    /// Weekday, or "Today" — the end tile usually sits on today and saying
    /// so reads faster than a weekday name.
    private func subtitle(for date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "Today"
            : date.formatted(.dateTime.weekday(.wide))
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
