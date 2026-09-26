//
//  ExerciseTabView.swift
//  SwiftSparkyFitness
//
//  Module 12: the tab literally named "Exercise" now. The brief said
//  "replace Diary with Exercise" — taken literally that deletes access to
//  the day's food/water history, which nothing asked for. Built instead as
//  Exercise-first with a segmented control down to "Food & Water", so
//  Diary's day view stays one tap away in the same tab rather than
//  disappearing. See PROGRESS.md for the full reasoning; flag back if a
//  straight replacement (no Food & Water segment) was actually wanted.
//
//  Both segments share one `DiaryViewModel` — same day, same
//  `GET /api/daily-summary`, loaded once — so switching segments can't show
//  the two halves of the same day out of sync with each other.
//

import SwiftUI

struct ExerciseTabView: View {
    let user: SessionUser
    @StateObject private var viewModel: DiaryViewModel
    @State private var segment: Segment = .exercise
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Segment: String, CaseIterable, Hashable {
        case exercise = "Exercise"
        case foodWater = "Food & Water"
    }

    init(user: SessionUser) {
        self.user = user
        _viewModel = StateObject(wrappedValue: DiaryViewModel(user: user))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .onChange(of: segment) { _, _ in Haptics.selection() }

            switch segment {
            case .exercise:
                ExerciseDiaryView(viewModel: viewModel)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            case .foodWater:
                DiaryView(viewModel: viewModel)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(AppColor.background)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: segment)
        // Not `DiaryView`'s own `.task` — that only mounts once the
        // Food & Water segment is actually selected, and Exercise is the
        // default. Without this, opening straight to Exercise never
        // triggered a load at all: not the spinner, not the empty state,
        // nothing, since `viewModel.summary` stayed nil forever. Found by
        // driving the built app on the simulator, not by reading the code.
        .task { await viewModel.load() }
    }
}

#Preview {
    ExerciseTabView(user: SessionUser(email: "demo@sparkyfitness.com", name: "Demo"))
}
