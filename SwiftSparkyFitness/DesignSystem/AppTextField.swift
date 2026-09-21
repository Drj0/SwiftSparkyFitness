//
//  AppTextField.swift
//  SwiftSparkyFitness
//
//  The app's one text input. `isInvalid` reddens the border alone (the
//  Login — failure screen does this to the password field with no message,
//  since it's unclear which field is actually wrong); `errorMessage` adds
//  the one-line reason underneath (the Sign-up — validation screen).
//
//  TWO STYLES, ONE COMPONENT
//  -------------------------
//  `.outlined` is the original pill from the Auth screens — white surface,
//  hairline border — which reads correctly against those screens' cream
//  background. `.filled` is the flat beige input the logging sheets use,
//  where the sheet itself is already white and a white-on-white pill needs
//  a border to exist at all.
//
//  Both looks were already in the app, but as *different components*:
//  CustomFoodView and LogExerciseView each carried their own private
//  `plainField` helper (identical to each other, duplicated) and alternated
//  it with AppTextField inside the same form — NAME bordered-white, SERVING
//  SIZE beige, CALORIES bordered-white, in adjacent rows. Both helpers are
//  gone; the sheets now pass `style: .filled` and there is a single input.
//
//  `focus` is here because none of the sheets could focus their first field
//  without it: `@FocusState` has to bind to the TextField itself, and the
//  TextField lives in here.
//

import SwiftUI

struct AppTextField: View {
    enum Style {
        /// Auth screens: white pill on cream, hairline border.
        case outlined
        /// Inside a sheet: flat beige fill, borderless unless invalid.
        case filled
    }

    let placeholder: String
    @Binding var text: String
    var style: Style = .outlined
    var isSecure = false
    var isInvalid = false
    var errorMessage: String? = nil
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil
    var submitLabel: SubmitLabel = .return
    /// Defaults to `.never` for the email/password fields this started as;
    /// name-ish fields (a food name, an activity) pass `.words`.
    var autocapitalization: TextInputAutocapitalization = .never
    /// Optional trailing unit ("g", "cm") rendered inside the field.
    var suffix: String? = nil
    /// Lets the owning sheet put the keyboard up on its primary field. Passed
    /// in rather than applied from outside because `.focused` only binds
    /// reliably on the text field itself, not on a wrapper.
    var focus: FocusState<Bool>.Binding? = nil

    private var showsError: Bool { isInvalid || errorMessage != nil }

    private var cornerRadius: CGFloat { style == .outlined ? 14 : 12 }
    private var horizontalPadding: CGFloat { style == .outlined ? 16 : 14 }
    private var verticalPadding: CGFloat { style == .outlined ? 14 : 12 }
    private var fill: Color { style == .outlined ? AppColor.surface : AppColor.inputBackground }

    private var borderColor: Color {
        if showsError { return AppColor.destructive }
        return style == .outlined ? AppColor.hairline : .clear
    }

    private var borderWidth: CGFloat {
        if showsError { return 2 }
        return style == .outlined ? 1 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                input
                if let suffix {
                    Text(suffix)
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: borderWidth)
            )

            if let errorMessage {
                Text(errorMessage)
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
                    .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        if let focus {
            styledField.focused(focus)
        } else {
            styledField
        }
    }

    private var styledField: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .appBody(15)
        .foregroundStyle(AppColor.ink)
        .keyboardType(keyboardType)
        .textContentType(textContentType)
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled()
        .submitLabel(submitLabel)
    }
}
