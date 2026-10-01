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

    /// Only set when a caller named a client explicitly, which in practice
    /// means the tests. Nil in the app.
    private let injectedClient: APIClientProtocol?

    /// Re-resolved on every use rather than captured in `init`, and that is
    /// load-bearing rather than tidiness. This view model is a `@StateObject`
    /// on `ContentView`, so it is built on the *first* render — which on a
    /// fresh install is before any mode has been chosen. Capturing the client
    /// there pinned it to `APIClient` for the lifetime of the process, so
    /// choosing "Use on this device" then fired `get-session` at the
    /// placeholder address, hung on a spinner for the full timeout and landed
    /// on the can't-reach-the-server screen — from which nothing led back to
    /// local mode. Verified on a fresh simulator install, and the same
    /// staleness broke switching mode in Settings in both directions.
    private var apiClient: APIClientProtocol { injectedClient ?? AppServices.client }

    private var sessionExpiredObserver: NSObjectProtocol?

    init(apiClient: APIClientProtocol? = nil) {
        self.injectedClient = apiClient
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
        // A 401 or a late "no session" belongs to server mode. Arriving in
        // local mode — a check the user walked away from, a handoff call —
        // it used to sign the on-device user out onto the server login.
        guard session != nil, AppMode.current == .server else { return }
        session = nil
        // Server mode's copy stays on this device through sign-in; saying so
        // stops "session expired" reading as "what I logged offline is gone".
        let pending = AppMode.isLocal ? 0 : ServerSync.shared.pendingCount
        bannerMessage = pending > 0
            ? "Your session expired — sign in again to sync \(pending) change\(pending == 1 ? "" : "s") saved on this iPhone."
            : "Your session expired — please sign in again."
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

    /// Which restore owns the outcome. Leaving the server path while it is
    /// still connecting starts another restore against the new mode, and the
    /// server's late answer — "no session" — must not land on top of it and
    /// sign the user out of the mode they just picked.
    private var restoreGeneration = 0

    func signOut() async {
        await apiClient.signOut()
        email = ""
        password = ""
        confirmPassword = ""
        clearErrors()
        session = nil
        restoreState = .done
    }

    /// The mode changed — to the other one, or back to the start screen —
    /// so whoever is signed in belongs to the mode being left. Keeping them
    /// is how the on-device user stayed "signed in" after Delete all local
    /// data and then opened server mode's tabs, writing to no account at
    /// all, when the server they picked didn't answer. A restore still in
    /// flight for the old mode is superseded, so its answer lands nowhere.
    /// `restoring` when a restore for the new mode follows at once, so the
    /// frame in between shows the connecting state rather than the login form.
    func resetForModeChange(restoring: Bool) {
        restoreGeneration += 1
        session = nil
        restoreState = restoring ? .restoring : .done
        password = ""
        confirmPassword = ""
        mode = .login
        clearErrors()
    }

    func restoreSession() async {
        restoreGeneration += 1
        let generation = restoreGeneration
        restoreState = .restoring
        do {
            let user = try await apiClient.currentSession()
            guard generation == restoreGeneration else { return }
            session = user
            restoreState = .done
        } catch {
            guard generation == restoreGeneration else { return }
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
        guard case .server(let message, let code, _) = error else {
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
