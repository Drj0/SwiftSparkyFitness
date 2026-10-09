//
//  ProgressTabView.swift
//  SwiftSparkyFitness
//
//  Module 6. The Progress tab: pick a range, see the trends.
//
//  Named `ProgressTabView` rather than `ProgressView` because SwiftUI
//  already owns that name and this file imports SwiftUI — shadowing it would
//  break every spinner in the app.
//
//  Follows Today's scaffold (ScrollView → VStack → screen padding, title in
//  the serif display face at Today's size, `.task` to load and
//  `.refreshable` to reload) and Diary's error rule: once data is on screen a
//  failure appears as a banner above it rather than replacing it, because a
//  failed reload must not take away the charts the user is already reading.
//
//  THE RANGE CONTROL
//  -----------------
//  The range is this screen's one real question — "over what period?" — so
//  it is a segmented row under the title, one tap from any range, the way
//  Health and Stocks do it. It used to be a pill that opened a menu: two
//  taps to change, and the options were invisible until you asked, so the
//  longer ranges went undiscovered.
//

import SwiftUI

struct ProgressTabView: View {
    @StateObject private var viewModel: ProgressViewModel
    /// Switches to Today, for the empty state's "log something" — logging
    /// food lives there, not here.
    private let onOpenToday: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which body sheet is up, if any: logging a weight or measurements
    /// straight from their chart.
    @State private var bodySheet: LogBodyViewModel.Kind?

    init(user: SessionUser, onOpenToday: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: ProgressViewModel(user: user))
        self.onOpenToday = onOpenToday
    }

    #if DEBUG
    /// Preview-only: renders against a pre-seeded view model instead of
    /// loading from the server.
    init(previewing viewModel: ProgressViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        onOpenToday = nil
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                RangeControl(selection: presetSelection)
                if viewModel.preset == .custom { customRangeFields }

                content
                    // A reload over existing charts dims them rather than
                    // blanking the screen, the same way Diary handles paging
                    // to a new day. Only the charts: the range control you
                    // just tapped stays at full strength.
                    .opacity(viewModel.isLoading && viewModel.hasLoadedOnce ? 0.5 : 1)
                    .allowsHitTesting(!(viewModel.isLoading && viewModel.hasLoadedOnce))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.isLoading)
            }
            .padding(AppSpacing.screenPad)
        }
        .background(AppColor.background)
        // `.task` re-runs every time the tab reappears (measured), and it
        // used to reload — dimmed — on each of those. Now it only makes the
        // first load; coming back re-reads quietly instead, in an
        // unstructured task so leaving again mid-read can't cancel it.
        .task {
            guard !viewModel.hasLoadedOnce else { return }
            await viewModel.load()
        }
        .onAppear {
            guard viewModel.hasLoadedOnce else { return }
            Task { await viewModel.refresh() }
        }
        // The system spinner already says a pull is in flight; dimming the
        // charts under it as well would be saying it twice.
        .refreshable { await viewModel.refresh() }
        .safeAreaInset(edge: .top) { errorBanner }
        .onChange(of: viewModel.errorMessage) { _, message in
            // The banner appears without moving VoiceOver focus, so it has to
            // announce itself or it is silent to a screen-reader user.
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .sheet(item: $bodySheet) { kind in
            // Opens on today with today's row, so saving a weight can't blank
            // this morning's waist; the sheet's own date picker reloads the
            // row for any other day.
            LogBodyView(
                kind: kind,
                date: viewModel.maxDate,
                existing: viewModel.todaysMeasurements,
                preferences: viewModel.preferences,
                minDate: viewModel.minDate,
                maxDate: viewModel.maxDate,
                suggestedWeight: viewModel.weightPoints.last?.value
            ) {
                Task { await viewModel.refresh() }
            }
            .fittedDetent()
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Progress")
                .appDisplay(32)
                .foregroundStyle(AppColor.ink)
                .accessibilityAddTraits(.isHeader)
            Text(viewModel.rangeDescription)
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.rangeDescription)
        }
    }

    // MARK: - Range

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

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoadedOnce {
            loadingPlaceholders
        } else if viewModel.didFailToLoad {
            failureState
        } else if viewModel.hasAnyData {
            cards
        } else {
            emptyState
        }
    }

    private enum Slot: Hashable, CaseIterable { case weight, nutrition, exercise, measurements }

    /// A fixed order, except that cards with something to chart come first:
    /// an account that never logs measurements shouldn't have to scroll past
    /// an empty card to reach the exercise it does log.
    private var slots: [Slot] {
        let filled = Slot.allCases.filter(hasData)
        return filled + Slot.allCases.filter { !hasData($0) }
    }

    private func hasData(_ slot: Slot) -> Bool {
        switch slot {
        case .weight: return !viewModel.weightPoints.isEmpty
        case .nutrition: return !viewModel.nutrition.isEmpty
        case .exercise: return (viewModel.exerciseTotals?.workoutCount ?? 0) > 0
        case .measurements: return !viewModel.populatedBodyFields.isEmpty
        }
    }

    private var cards: some View {
        VStack(spacing: 14) {
            ForEach(slots, id: \.self) { slot in
                switch slot {
                case .weight:
                    WeightTrendCard(viewModel: viewModel) { bodySheet = .weight }
                case .nutrition:
                    NutritionTrendCard(viewModel: viewModel)
                case .exercise:
                    ExerciseSummaryCard(viewModel: viewModel)
                case .measurements:
                    MeasurementsTrendCard(viewModel: viewModel) { bodySheet = .measurements }
                }
            }
        }
    }

    private var loadingPlaceholders: some View {
        VStack(spacing: 14) {
            TrendCardPlaceholder(chartHeight: 180)
            TrendCardPlaceholder(chartHeight: 150)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your progress")
    }

    /// Nothing loaded at all. Not the empty state — that would tell someone
    /// with a year of history that they've logged nothing.
    private var failureState: some View {
        VStack(spacing: 14) {
            ErrorBanner(message: "Couldn't load your progress. Check your connection, then try again.")
            PrimaryButton(title: "Retry") {
                Task { await viewModel.load() }
            }
        }
        .padding(.top, 12)
    }

    /// A blank slate and a break read differently. An account with nothing
    /// in the year before this range is told where trends come from and
    /// sent to Today; one that took a break is told when it last logged and
    /// offered the shortest range that reaches it — one tap to something,
    /// not a chain of empty ranges.
    private var emptyState: some View {
        let history = viewModel.earlierHistory
        let title: String
        let message: String
        var suggestion: ProgressRangePreset?
        switch history {
        case .none:
            title = "Your trends start here"
            message = "Log a meal, a workout or your weight on Today, and this is where it adds up over the days."
        case .lastLogged(let date):
            title = viewModel.preset.days.map { "Nothing logged in the last \($0) days" } ?? "Nothing logged in this range"
            // With the year once it isn't this one: the search reaches a year
            // back, and "Saturday 20 December" read in October sounds ahead.
            let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            let day = thisYear
                ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            message = "Your last entry was on \(day)."
            suggestion = viewModel.shortestPreset(reaching: date)
        case .unknown:
            title = viewModel.preset.days.map { "Nothing logged in the last \($0) days" } ?? "Nothing logged in this range"
            message = "Your charts appear as soon as there's something in this range."
        }

        return VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 64, height: 64)
                .background(AppColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .appDisplay(20)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let suggestion, let days = suggestion.days {
                Button {
                    presetSelection.wrappedValue = suggestion
                } label: {
                    Text(days == 365 ? "Show the last year" : "Show the last \(days) days")
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(AppColor.accentSoft, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .padding(.top, 6)
            } else if history == .none, let onOpenToday {
                PrimaryButton(title: "Go to Today", action: onOpenToday)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(AppColor.dashedBorder)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: history)
    }

    @ViewBuilder
    private var errorBanner: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage, viewModel.hasLoadedOnce, !viewModel.didFailToLoad {
                ErrorBanner(message: message)
                    .padding(.horizontal, AppSpacing.screenPad)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.errorMessage)
    }
}

// MARK: - Range control

/// Five rolling windows and Custom, one tap each. Accent thumb on the input
/// track, sliding between segments like the week strip's selected day.
private struct RangeControl: View {
    @Binding var selection: ProgressRangePreset
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProgressRangePreset.allCases) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(AppColor.inputBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Six fixed columns: past this the labels stop fitting their segment.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time range")
    }

    private func segment(_ option: ProgressRangePreset) -> some View {
        let isSelected = option == selection
        return Button {
            selection = option
        } label: {
            Group {
                if option == .custom {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Text(option.shortLabel)
                        .appBody(13, weight: .semibold)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppColor.accent)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            // The track's 3pt inset is still this segment's to tap, so the
            // target reaches the full 44pt of the control.
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .padding(.vertical, -3)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(option.spokenLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Loading

/// The shape of a card, while the first load is in flight — so the screen
/// arrives in place instead of a spinner giving way to a page of charts.
private struct TrendCardPlaceholder: View {
    var chartHeight: CGFloat
    @State private var isDimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            block(width: 96, height: 10)
            block(width: 150, height: 28)
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColor.ringTrack.opacity(0.6))
                .frame(height: chartHeight)
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .opacity(isDimmed ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDimmed = true }
        }
    }

    private func block(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2.5)
            .fill(AppColor.ringTrack)
            .frame(width: width, height: height)
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
