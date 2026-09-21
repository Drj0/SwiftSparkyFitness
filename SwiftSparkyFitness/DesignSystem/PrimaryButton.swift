//
//  PrimaryButton.swift
//  SwiftSparkyFitness
//
//  The accent capsule. Note where the background sits: on the *label*, not
//  on the Button. It used to be on the Button, which meant the default
//  button style dimmed only what it owned — the title text faded on press
//  while the capsule behind it stayed fully lit, so the button looked like
//  it was losing its text rather than being pressed. With the fill inside
//  the label, the whole control responds as one.
//

import SwiftUI

struct PrimaryButton: View {
    let title: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                }
            }
            .appBody(16, weight: .semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.pressableLarge)
        .disabled(isLoading)
    }
}
