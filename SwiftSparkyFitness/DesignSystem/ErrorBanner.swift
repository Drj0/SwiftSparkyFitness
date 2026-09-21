//
//  ErrorBanner.swift
//  SwiftSparkyFitness
//
//  The inline failure banner from the Login — failure screen: sits above
//  the fields, not a system alert, so retrying doesn't get interrupted.
//
//  It carries its own entrance transition. The banner appears at the end of
//  a failed round trip, i.e. exactly when the user is already looking
//  elsewhere, and an instant pop-in plus the layout shove it gives the
//  fields below reads as a glitch rather than as an answer. The screens that
//  present it animate the `bannerMessage` change so this transition runs.
//

import SwiftUI

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(AppColor.destructive)
                // VoiceOver read this out as "Exclamation Mark In A Filled
                // Circle" before the message it decorates.
                .accessibilityHidden(true)
            Text(message)
                .appBody(13)
                .foregroundStyle(AppColor.errorText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppColor.errorBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppColor.errorBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
