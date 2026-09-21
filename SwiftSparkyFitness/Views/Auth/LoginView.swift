//
//  LoginView.swift
//  SwiftSparkyFitness
//
//  "Welcome back" / login-failure screens from the design.
//
//  COMPOSITION
//  -----------
//  The form used to be bottom-anchored by a single Spacer(), which put the
//  first pixel of content at y=488 of 874 — 56% of the screen was empty
//  cream with nothing in it, on the one screen a new user sees first.
//  There's now a spacer on both sides, so the block sits centred, and the
//  upper region carries a brand lockup instead of nothing: the ring geometry
//  the Today screen already uses, at badge size, next to the wordmark in the
//  serif face. No new image assets — it's the same RingChart.
//
//  The horizontal gutter also drops from 28 to 20, which is what every other
//  screen in the app uses (AppSpacing.screenPad).
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsForgotPasswordNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)

            brandLockup

            Text("Welcome back")
                .appDisplay(30)
                .foregroundStyle(AppColor.ink)

            Text("Log in to pick up where you left off.")
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .padding(.top, 6)
                .padding(.bottom, 20)

            if let bannerMessage = viewModel.bannerMessage {
                ErrorBanner(message: bannerMessage)
                    .padding(.bottom, 16)
            }

            VStack(spacing: 12) {
                AppTextField(
                    placeholder: "you@email.com",
                    text: $viewModel.email,
                    errorMessage: viewModel.emailError,
                    keyboardType: .emailAddress,
                    textContentType: .username
                )
                AppTextField(
                    placeholder: "Password",
                    text: $viewModel.password,
                    isSecure: true,
                    isInvalid: viewModel.passwordFieldInvalid,
                    textContentType: .password
                )
            }

            // Measured 113 x 15.7pt. The target grows to 44pt tall, so the
            // row's own top padding comes off to keep the spacing as drawn.
            Button {
                showsForgotPasswordNotice = true
            } label: {
                Text("Forgot password?")
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .alert("Password reset isn't available yet", isPresented: $showsForgotPasswordNotice) {
                Button("OK", role: .cancel) {}
            }

            PrimaryButton(title: "Log in", isLoading: viewModel.isLoading) {
                Task { await viewModel.submit() }
            }
            .padding(.top, 8)
            .disabled(!viewModel.canSubmit)
            .opacity(viewModel.canSubmit ? 1 : 0.6)

            HStack(spacing: 4) {
                Text("New to Sparky?")
                    .foregroundStyle(AppColor.secondaryText)
                Button {
                    // Animated here rather than in AuthContainerView because
                    // this is where the state actually changes — the
                    // container's transition has nothing to run off
                    // otherwise, and the two near-identical forms hard-cut.
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                        viewModel.switchMode(to: .signUp)
                    }
                } label: {
                    Text("Create an account")
                        .foregroundStyle(AppColor.accent)
                        .fontWeight(.semibold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
            .appBody(13)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
    }

    /// Decorative: one spoken "Sparky" rather than a ring chart announcing
    /// three arcs of meaningless progress.
    private var brandLockup: some View {
        HStack(spacing: 12) {
            RingChart(
                layers: [
                    RingLayer(progress: 0.78, color: AppColor.accent),
                    RingLayer(progress: 0.52, color: AppColor.energyGraphic),
                    RingLayer(progress: 0.64, color: AppColor.water),
                ],
                diameter: 52, trackWidth: 5, gap: 3
            )
            Text("Sparky")
                .appDisplay(26)
                .foregroundStyle(AppColor.ink)
        }
        .padding(.bottom, 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sparky")
    }
}

#Preview("Login") {
    LoginView(viewModel: AuthViewModel())
}

#Preview("Login — failure") {
    let vm = AuthViewModel()
    vm.email = "you@email.com"
    return LoginView(viewModel: vm)
}
