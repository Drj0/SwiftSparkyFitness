//
//  DiaryDayHeader.swift
//  SwiftSparkyFitness
//
//  The day control both halves of the Exercise tab share: chevrons either
//  side of the date, the date itself opening a calendar, and a horizontal
//  swipe paging days. Exercise used to have its own: no calendar, no swipe,
//  and the date in a fixed US format ("Thu, Oct 1") beside Food & Water's
//  — and Today's — "Thu, 1 Oct". One tab, one way to change day.
//

import SwiftUI

struct DiaryDayHeader: View {
    @ObservedObject var viewModel: DiaryViewModel
    @State private var isPresentingDatePicker = false

    /// "Today", "Yesterday", else "Thu, 24 Sep" in the user's locale.
    static func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// For sentences: "today", "yesterday", "on Thu, 24 Sep".
    static func phrase(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        return "on \(label(for: date))"
    }

    var body: some View {
        // The chevron glyphs were their own 6.7 x 11.7pt tap targets —
        // ~4% of the 44x44 minimum, and sitting a few points from the
        // date button, so a near-miss silently opened the date picker.
        // The glyphs keep their size; the *targets* are padded to 44 and
        // the row's spacing pulled to 0 so the row doesn't visibly spread.
        HStack(spacing: 0) {
            chevron("chevron.left", label: "Previous day", isEnabled: viewModel.canGoToPreviousDay) {
                viewModel.goToPreviousDay()
            }

            Button {
                guard !viewModel.isMidDaySwipe else { return }
                isPresentingDatePicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(Self.label(for: viewModel.selectedDate))
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(viewModel.selectedDate.formatted(date: .complete, time: .omitted))
            .accessibilityHint("Opens a calendar to pick a day")

            chevron("chevron.right", label: "Next day", isEnabled: viewModel.canGoToNextDay) {
                viewModel.goToNextDay()
            }
            Spacer(minLength: 0)
        }
        // The 44pt targets are mostly empty space around a 7pt glyph, so
        // the left chevron is pulled back into the screen margin to stay
        // optically aligned with the content below.
        .padding(.leading, -14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, 8)
        .sheet(isPresented: $isPresentingDatePicker) {
            DiaryDatePickerSheet(initialDate: viewModel.selectedDate, minDate: viewModel.minDate, maxDate: viewModel.maxDate) { picked in
                viewModel.jumpToDate(picked)
            }
            .presentationDetents([.medium])
        }
    }

    private func chevron(_ symbol: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? AppColor.accent : AppColor.placeholder)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .buttonStyle(.pressableCompact)
        // Defaults to "Back"/"Forward" — a chevron reads as navigation
        // history to VoiceOver, which is not what this does.
        .accessibilityLabel(label)
    }
}

extension View {
    /// A horizontal swipe pages the day. Simultaneous, not `.gesture`: the
    /// List owns vertical scrolling, and that may not lose to day paging.
    ///
    /// Applied to everything on a day page *except* rows with swipe
    /// actions, never to the whole List. On the List it fired alongside a
    /// row's own swipe: a full swipe to "Log again" also paged to
    /// yesterday, a partial one paged instead of revealing the button, and
    /// a delete on a past day jumped to the next. A swipe on a row now acts
    /// on that row; anywhere else — the header, the summary, section
    /// headers, an empty day — it changes the day.
    func diaryDayPaging(_ viewModel: DiaryViewModel) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    if abs(value.translation.width) > abs(value.translation.height) {
                        viewModel.lastDaySwipeAt = Date()
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 90, abs(dx) > abs(dy) * 2.5 else { return }
                    let wantsNextDay = dx < 0
                    let canPage = wantsNextDay ? viewModel.canGoToNextDay : viewModel.canGoToPreviousDay
                    guard canPage else { return Haptics.light() }
                    Haptics.selection()
                    if wantsNextDay { viewModel.goToNextDay() } else { viewModel.goToPreviousDay() }
                }
        )
    }
}

struct DiaryDatePickerSheet: View {
    @State private var date: Date
    let minDate: Date
    let maxDate: Date
    let onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialDate: Date, minDate: Date, maxDate: Date, onPick: @escaping (Date) -> Void) {
        _date = State(initialValue: initialDate)
        self.minDate = minDate
        self.maxDate = maxDate
        self.onPick = onPick
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(AppColor.hairline).frame(width: 44, height: 5).padding(.top, 10)
            DatePicker("", selection: $date, in: minDate...maxDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(AppColor.accent)
            PrimaryButton(title: "Go to date") {
                onPick(date)
                dismiss()
            }
        }
        .padding(20)
        .background(AppColor.surface)
    }
}
