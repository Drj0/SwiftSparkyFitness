//
//  AuthViewModel.swift
//  SwiftSparkyFitness
//
//  Owns both auth screens' form state (they're one flow toggled by `mode`,
//  matching the design's "Already have an account? Log in" links) and maps
//  server error codes to the exact field/banner states the design specifies:
//  duplicate email and weak password land under their field; a bad login
//  can't say which field is wrong, so it's a banner + a reddened (but
//  message-less) password field instead.
//

import Foundation
import Combine

enum AuthMode {
    case login, signUp
}

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var mode: AuthMode = .login
    @Published var email = ""
    @Published var password = ""
    @Published var confirmPassword = ""

    @Published private(set) var emailError: String?
    @Published private(set) var passwordError: String?
    @Published private(set) var passwordFieldInvalid = false
    @Published private(set) var bannerMessage: String?

    @Published private(set) var isLoading = false
    @Published private(set) var session: SessionUser?

    private let apiClient: APIClientProtocol
    private var sessionExpiredObserver: NSObjectProtocol?

    init(apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
        sessionExpiredObserver = NotificationCenter.default.addObserver(
            forName: .sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSessionExpired() }
        }
    }

    deinit {
        if let sessionExpiredObserver {
            NotificationCenter.default.removeObserver(sessionExpiredObserver)
        }
    }

    private func handleSessionExpired() {
        guard session != nil else { return }
        session = nil
        bannerMessage = "Your session expired — please sign in again."
    }

    var canSubmit: Bool {
        guard !email.isEmpty, !password.isEmpty, !isLoading else { return false }
        guard mode == .signUp else { return true }
        return !confirmPassword.isEmpty && confirmPasswordError == nil
    }

    /// Sign-up only: nil once confirmPassword is empty or matches password.
    var confirmPasswordError: String? {
        guard mode == .signUp, !confirmPassword.isEmpty, confirmPassword != password else { return nil }
        return "Passwords don't match."
    }

    func switchMode(to newMode: AuthMode) {
        mode = newMode
        clearErrors()
    }

    /// Where the launch-time session check has got to.
    ///
    /// Without this the app rendered with `session == nil` and only *then*
    /// looked, so frame one of every cold launch was the full Login screen
    /// even for a perfectly valid session — and if the server was
    /// unreachable it stayed there, with no error, while the user's cookie
    /// was still good.
    enum RestoreState: Equatable {
        case restoring
        case done
        case unreachable
    }

    @Published private(set) var restoreState: RestoreState = .restoring

    func signOut() async {
        await apiClient.signOut()
        email = ""
        password = ""
        confirmPassword = ""
        clearErrors()
        session = nil
        restoreState = .done
    }

    func restoreSession() async {
        restoreState = .restoring
        do {
            session = try await apiClient.currentSession()
            restoreState = .done
        } catch {
            // Transport failure, not a logout: keep the user out of the login
            // form and let ContentView offer a retry instead.
            restoreState = .unreachable
        }
    }

    func submit() async {
        clearErrors()

        if mode == .signUp {
            if confirmPasswordError != nil {
                Haptics.error()
                return
            }
            if let reason = passwordWeaknessReason(password) {
                passwordError = reason
                Haptics.error()
                return
            }
        }

        isLoading = true
        defer { isLoading = false }
        do {
            session = mode == .login
                ? try await apiClient.signIn(email: email, password: password)
                : try await apiClient.signUp(email: email, password: password)
        } catch let error as APIError {
            apply(error)
            Haptics.error()
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
        }
    }

    // MARK: - Password reset

    /// Deliberately has no "that address isn't registered" case: the server
    /// answers identically either way so the form can't be used to find out
    /// who has an account, and this can only ever report that the request
    /// was accepted.
    enum ResetState: Equatable {
        case editing
        case sending
        case requested
    }

    @Published var resetEmail = ""
    @Published private(set) var resetState: ResetState = .editing
    @Published private(set) var resetError: String?

    var canRequestReset: Bool {
        resetState != .sending && resetEmail.contains("@")
    }

    /// Call when opening the sheet, so it starts on whatever was already
    /// typed into the login form rather than making them type it twice.
    func preparePasswordReset() {
        resetEmail = email
        resetState = .editing
        resetError = nil
    }

    func requestPasswordReset() async {
        resetError = nil
        resetState = .sending
        do {
            try await apiClient.requestPasswordReset(
                email: resetEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            resetState = .requested
            Haptics.success()
        } catch {
            resetState = .editing
            resetError = error.localizedDescription
            Haptics.error()
        }
    }

    private func apply(_ error: APIError) {
        guard case .server(let message, let code) = error else {
            bannerMessage = error.localizedDescription
            return
        }
        switch code {
        case "USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL":
            emailError = "This email is already registered — try logging in instead."
        case "PASSWORD_TOO_SHORT":
            passwordError = "Use at least 8 characters, with a number."
        case "INVALID_EMAIL_OR_PASSWORD":
            bannerMessage = "That email and password don't match. Check your password or reset it below."
            passwordFieldInvalid = true
        case "VALIDATION_ERROR":
            emailError = message
        default:
            bannerMessage = message
        }
    }

    private func passwordWeaknessReason(_ password: String) -> String? {
        let hasDigit = password.contains { $0.isNumber }
        return (password.count >= 8 && hasDigit) ? nil : "Use at least 8 characters, with a number."
    }

    private func clearErrors() {
        emailError = nil
        passwordError = nil
        passwordFieldInvalid = false
        bannerMessage = nil
    }
}
