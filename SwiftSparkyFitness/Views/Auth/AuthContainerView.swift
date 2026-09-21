//
//  AuthContainerView.swift
//  SwiftSparkyFitness
//
//  Login and Sign Up are one flow, not two screens: ~80% of what's on them
//  is the same fields in the same place. A bare switch hard-cut between
//  them, which threw that continuity away and read as a reload rather than
//  a move sideways. They now slide as a pair — sign-up arrives from the
//  trailing edge and leaves back the way it came — with the ZStack there so
//  both views exist for the length of the transition. The mode change
//  itself is animated at the two buttons that make it, in LoginView and
//  SignUpView.
//

import SwiftUI

struct AuthContainerView: View {
    @ObservedObject var viewModel: AuthViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch viewModel.mode {
            case .login:
                LoginView(viewModel: viewModel)
                    .transition(transition(from: .leading))
            case .signUp:
                SignUpView(viewModel: viewModel)
                    .transition(transition(from: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
    }

    /// Each form enters and leaves on its own side, so the pair reads as one
    /// strip sliding rather than two cards shuffling. Reduce Motion keeps
    /// the cross-fade and drops the travel.
    private func transition(from edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge).combined(with: .opacity)
        )
    }
}
