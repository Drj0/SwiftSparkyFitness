//
//  ForgotPasswordSheet.swift
//  SwiftSparkyFitness
//
//  Requests a password-reset email. The "Forgot password?" link used to open
//  an alert saying the feature didn't exist; the endpoint does exist
//  (`POST /api/auth/request-password-reset` — note better-auth renamed it
//  from `forget-password`, which 404s).
//
//  WHAT THIS SCREEN CAN AND CAN'T PROMISE
//  --------------------------------------
//  The server returns an identical 200 whether or not the address has an
//  account (verified live against both). That's deliberate — otherwise this
//  form would tell anyone who asks which addresses are registered here. So
//  the confirmation is phrased conditionally; it is not able to say "we sent
//  you an email", because it genuinely doesn't know.
//
//  There's a second, self-hosting-specific catch worth naming to the user
//  rather than letting them sit and wait: SparkyFitness only sends mail once
//  the operator fills in the SMTP settings. With those blank the server logs
//  the reset link to its console and still answers 200, so no email is ever
//  delivered and nothing in the API response reveals that. Hence the note in
//  the confirmation state — it's the difference between "this app is broken"
//  and "ask whoever runs your server to set up email".
//
//  The link itself opens the web frontend, which is where the new password
//  gets set; there's no in-app deep-link route for the token.
//

import SwiftUI

struct ForgotPasswordSheet: View {
    @ObservedObject var viewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Reset password",
                cancelTitle: viewModel.resetState == .requested ? "Done" : "Cancel",
                onCancel: { dismiss() },
                action: viewModel.resetState == .requested ? nil : SheetAction(
                    "Send",
                    isEnabled: viewModel.canRequestReset
                ) {
                    Task { await viewModel.requestPasswordReset() }
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.resetState == .requested {
                        requestedState
                    } else {
                        editingState
                    }
                }
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .background(AppColor.background)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.resetState)
        .onAppear {
            viewModel.preparePasswordReset()
            emailFocused = true
        }
    }

    private var editingState: some View {
        Group {
            Text("We'll email you a link to set a new password.")
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)

            if let resetError = viewModel.resetError {
                ErrorBanner(message: resetError)
            }

            AppTextField(
                placeholder: "you@email.com",
                text: $viewModel.resetEmail,
                style: .filled,
                keyboardType: .emailAddress,
                textContentType: .username,
                submitLabel: .send,
                focus: $emailFocused.projectedValue
            )
            .onSubmit {
                guard viewModel.canRequestReset else { return }
                Task { await viewModel.requestPasswordReset() }
            }
        }
    }

    private var requestedState: some View {
        Group {
            Label {
                Text("If \(viewModel.resetEmail) has an account, a reset link is on its way.")
                    .appBody(15)
                    .foregroundStyle(AppColor.ink)
            } icon: {
                Image(systemName: "envelope")
                    .foregroundStyle(AppColor.accent)
            }
            .labelStyle(.titleAndIcon)

            Text("Open the link on the device where you use SparkyFitness — it sets your new password in the web app.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)

            Divider().overlay(AppColor.hairline)

            Text("Nothing arrives?")
                .appBody(13, weight: .semibold)
                .foregroundStyle(AppColor.ink)

            Text("A self-hosted server can only send email once its operator has configured SMTP. If that hasn't been set up, the reset link never leaves the server — ask whoever runs yours.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Forgot password") {
    ForgotPasswordSheet(viewModel: AuthViewModel())
}
