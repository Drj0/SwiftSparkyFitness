//
//  ModeChoiceView.swift
//  SwiftSparkyFitness
//
//  The first thing a fresh install shows: server, or this device only.
//
//  It comes before auth deliberately. Signing in only means something once
//  there's a server to sign in to, so asking for an email first would make the
//  local-only path look like a fallback for people who failed at setup rather
//  than a supported way to use the app.
//

import SwiftUI

struct ModeChoiceView: View {
    /// Called once a mode is stored, so the caller can restore the session —
    /// which in local mode is synthetic and instant.
    var onChosen: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("SparkyFitness")
                    .appDisplay(30)
                    .foregroundStyle(AppColor.ink)
                    .padding(.top, 48)

                Text("How would you like to use it?")
                    .appBody(15)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(.top, 8)

                choice(
                    title: "Use on this device",
                    detail: "No account and no server. Everything you log stays on this iPhone.",
                    caveat: "Nothing is backed up — deleting the app deletes your diary.",
                    isPrimary: true
                ) { choose(.local) }
                .padding(.top, 32)

                choice(
                    title: "Connect to a server",
                    detail: "Sign in to a SparkyFitness server you run yourself, and reach the same data from any device.",
                    caveat: nil,
                    isPrimary: false
                ) { choose(.server) }
                .padding(.top, 14)

                Text("You can change this later in Settings.")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 28)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, 32)
        }
        .background(AppColor.background)
    }

    private func choose(_ mode: AppMode) {
        AppMode.current = mode
        Haptics.success()
        Task { await onChosen() }
    }

    private func choice(
        title: String,
        detail: String,
        caveat: String?,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .appBody(17, weight: .semibold)
                    .foregroundStyle(isPrimary ? AppColor.accent : AppColor.ink)
                Text(detail)
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let caveat {
                    Text(caveat)
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(isPrimary ? AppColor.accent : AppColor.hairline, lineWidth: isPrimary ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // One element per option: VoiceOver reads the choice and its
        // consequence together rather than as three loose texts.
        .accessibilityElement(children: .combine)
    }
}
