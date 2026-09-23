//
//  SignUpView.swift
//  SwiftSparkyFitness
//
//  "Create your account" / sign-up validation screens from the design.
//
//  Gutter and vertical balance track LoginView exactly (20pt sides, a spacer
//  on each end). The two forms are ~80% the same content and AuthContainerView
//  slides one onto the other, so any difference in where the block sits shows
//  up as the fields jumping mid-transition.
//

import SwiftUI

struct SignUpView: View {
    @ObservedObject var viewModel: AuthViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)

            RoundedRectangle(cornerRadius: 16)
                .fill(AppColor.accent)
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "sparkle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .padding(.bottom, 20)
                .accessibilityHidden(true)

            Text("Create your account")
                .appDisplay(30)
                .foregroundStyle(AppColor.ink)

            Text("A few numbers a day, and Sparky handles the rest.")
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
                    errorMessage: viewModel.passwordError,
                    textContentType: .newPassword
                )
                AppTextField(
                    placeholder: "Confirm password",
                    text: $viewModel.confirmPassword,
                    isSecure: true,
                    errorMessage: viewModel.confirmPasswordError,
                    textContentType: .newPassword
                )
            }

            PrimaryButton(title: "Get started", isLoading: viewModel.isLoading) {
                Task { await viewModel.submit() }
            }
            .padding(.top, 20)
            .disabled(!viewModel.canSubmit)
            .opacity(viewModel.canSubmit ? 1 : 0.6)

            HStack(spacing: 4) {
                Text("Already have an account?")
                    .foregroundStyle(AppColor.secondaryText)
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                        viewModel.switchMode(to: .login)
                    }
                } label: {
                    // Was ~15.7pt tall; the target is 44 now, so the row's
                    // own top padding comes off to keep the spacing as drawn.
                    Text("Log in")
                        .foregroundStyle(AppColor.accent)
                        .appBody(13, weight: .semibold)
                        .frame(minWidth: 44, minHeight: 44)
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
}

#Preview("Sign up") {
    SignUpView(viewModel: AuthViewModel())
}

#Preview("Sign-up — validation") {
    let vm = AuthViewModel()
    vm.email = "you@email.com"
    vm.password = "••••"
    return SignUpView(viewModel: vm)
}
