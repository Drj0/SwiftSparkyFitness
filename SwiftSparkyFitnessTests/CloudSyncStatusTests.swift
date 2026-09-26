//
//  CloudSyncStatusTests.swift
//  SwiftSparkyFitnessTests
//
//  Module 11's sync-status model.
//
//  These cover the part of iCloud sync that is this app's own logic: how an
//  account state and a mirroring event become something honest on screen.
//  They do **not** cover CloudKit actually syncing between two devices —
//  that needs two devices signed into one iCloud account and cannot be run
//  here. See PROGRESS.md for what remains unverified.
//

import XCTest
import CloudKit
@testable import SwiftSparkyFitness

@MainActor
final class CloudSyncStatusTests: XCTestCase {

    private struct StubProbe: CloudAccountProbing {
        let status: CKAccountStatus
        func accountStatus() async -> CKAccountStatus { status }
    }

    /// Never observes notifications, and never consults the real store.
    private func makeStatus(
        account: CKAccountStatus = .available,
        configured: Bool = true
    ) -> CloudSyncStatus {
        CloudSyncStatus(
            probe: StubProbe(status: account),
            syncingIsConfigured: { configured },
            observingNotifications: false
        )
    }

    override func setUp() {
        super.setUp()
        // The last-synced date is persisted, so a leftover value from another
        // test (or from running the app on this simulator) would otherwise
        // decide what state these start in.
        UserDefaults.standard.removeObject(forKey: CloudSyncStatus.lastSyncedKey)
    }

    // MARK: - Account states

    /// The headline case from the brief: no iCloud account degrades to
    /// local-only rather than blocking anything, and says so.
    func testNoAccountReportsNotSignedInAndOffersTheWayToFixIt() async {
        let status = makeStatus(account: .noAccount)

        await status.refreshAccountStatus()

        XCTAssertEqual(status.state, .unavailable(.notSignedIn))
        XCTAssertEqual(status.state.title, "Not signed in")
        XCTAssertTrue(status.state.offersSystemSettings, "this is the one state the user can fix in Settings.app")
        XCTAssertFalse(status.state.backsUpTheDiary, "with no account there is no second copy")
        XCTAssertTrue(
            status.state.detail().contains("stays on this iPhone only"),
            "the user has to be told their data is unprotected, not just that sync is off"
        )
    }

    /// `temporarilyUnavailable` means "ask again later", not "no account".
    /// Reporting it as not-signed-in would send someone to Settings.app to
    /// fix something that isn't broken.
    func testTemporarilyUnavailableIsNotReportedAsSignedOut() async {
        let status = makeStatus(account: .temporarilyUnavailable)

        await status.refreshAccountStatus()

        XCTAssertEqual(status.state, .unavailable(.temporarilyUnavailable))
        XCTAssertFalse(status.state.offersSystemSettings)
        XCTAssertFalse(status.state.isProblem, "a transient iCloud outage is not the user's fault to fix")
    }

    func testRestrictedAccountIsShownAsAProblemButNotAsSignedOut() async {
        let status = makeStatus(account: .restricted)

        await status.refreshAccountStatus()

        XCTAssertEqual(status.state, .unavailable(.restricted))
        XCTAssertTrue(status.state.isProblem)
        XCTAssertFalse(status.state.offersSystemSettings, "signing in isn't the fix for a managed account")
    }

    func testAFailedAccountCheckSaysSoRatherThanGuessing() async {
        let status = makeStatus(account: .couldNotDetermine)

        await status.refreshAccountStatus()

        XCTAssertEqual(status.state, .unavailable(.unknown))
        XCTAssertFalse(status.state.backsUpTheDiary, "not knowing is not the same as being backed up")
    }

    /// A store that opened without CloudKit will never sync however good the
    /// account is, so the account state must not override that.
    func testAStoreWithoutCloudKitReportsOffEvenWithAGoodAccount() async {
        let status = makeStatus(account: .available, configured: false)

        await status.refreshAccountStatus()

        XCTAssertEqual(status.state, .unavailable(.notConfigured))
        XCTAssertFalse(status.state.backsUpTheDiary)
    }

    /// An available account means syncing *can* happen, not that it has.
    func testAnAvailableAccountDoesNotByItselfClaimAnythingIsSynced() async {
        let status = makeStatus(account: .available)

        await status.refreshAccountStatus()

        XCTAssertEqual(status.state, .waiting)
        XCTAssertFalse(status.state.backsUpTheDiary, "nothing has reported a successful sync yet")
    }

    /// …and it must not stomp on a real success either.
    func testAnAvailableAccountDoesNotOverwriteAKnownSync() async {
        let status = makeStatus(account: .available)
        let finished = Date(timeIntervalSince1970: 1_750_000_000)
        status.apply(.exporting, endDate: finished, error: nil)

        await status.refreshAccountStatus()

        XCTAssertEqual(status.state, .synced(finished))
    }

    // MARK: - Mirroring events

    func testAnEventStillRunningReadsAsSyncing() {
        let status = makeStatus()

        status.apply(.exporting, endDate: nil, error: nil)

        XCTAssertEqual(status.state, .syncing)
        XCTAssertNil(status.lastSynced)
    }

    /// Only an export proves this device's data reached iCloud. An import
    /// says the other direction worked, which is not what "backed up" means.
    func testOnlyAnExportUpdatesTheLastBackedUpTime() {
        let status = makeStatus()
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_500)

        status.apply(.importing, endDate: importedAt, error: nil)
        XCTAssertNil(status.lastSynced, "an import is not a backup")
        XCTAssertEqual(status.state, .synced(nil))

        status.apply(.exporting, endDate: exportedAt, error: nil)
        XCTAssertEqual(status.lastSynced, exportedAt)
        XCTAssertEqual(status.state, .synced(exportedAt))
    }

    func testSetupFinishingDoesNotCountAsABackupEither() {
        let status = makeStatus()

        status.apply(.setup, endDate: Date(), error: nil)

        XCTAssertNil(status.lastSynced)
    }

    func testAFailedEventSurfacesTheProblemAndKeepsTheLastGoodTime() {
        let status = makeStatus()
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
        status.apply(.exporting, endDate: exportedAt, error: nil)

        status.apply(.exporting, endDate: Date(), error: CKError(.networkUnavailable))

        XCTAssertEqual(status.state, .failed("No connection. Sync will resume when you're back online."))
        XCTAssertTrue(status.state.isProblem)
        XCTAssertEqual(status.lastSynced, exportedAt, "a later failure doesn't unmake an earlier success")
    }

    // MARK: - Error copy

    /// A full iCloud account is the most common real failure and the only one
    /// the user can do anything about, so it must not be hidden behind the
    /// generic message.
    func testAFullAccountIsNamedRatherThanReportedGenerically() {
        XCTAssertEqual(
            CloudSyncStatus.message(for: CKError(.quotaExceeded)),
            "Your iCloud storage is full, so new entries aren't being backed up."
        )
    }

    func testAnUnrecognisedErrorNeverPutsFrameworkTextOnScreen() {
        let raw = NSError(domain: "NSCocoaErrorDomain", code: 4099, userInfo: [
            NSLocalizedDescriptionKey: "connection to service named com.apple.cloudd was invalidated"
        ])

        let message = CloudSyncStatus.message(for: raw)

        XCTAssertEqual(message, "Sync failed. It'll try again on its own.")
        XCTAssertFalse(message.contains("cloudd"))
    }

    // MARK: - What the row says

    func testASyncedStateWithADateReadsAsARelativeTime() {
        let now = Date(timeIntervalSince1970: 1_700_003_600)
        let anHourEarlier = Date(timeIntervalSince1970: 1_700_000_000)

        let detail = CloudSyncStatus.State.synced(anHourEarlier).detail(relativeTo: now)

        XCTAssertTrue(detail.hasPrefix("Last backed up "), "got: \(detail)")
        XCTAssertTrue(detail.contains("hour"), "got: \(detail)")
    }

    /// Waiting is the state that most tempts a reassuring lie.
    func testWaitingNeverClaimsTheDiaryIsBackedUp() {
        XCTAssertFalse(CloudSyncStatus.State.waiting.backsUpTheDiary)
        XCTAssertFalse(CloudSyncStatus.State.waiting.detail().contains("Last backed up"))
    }

    /// Settings prints `detail()` and `dataLossWarning` one under the other,
    /// so the pair has to be readable as a single sentence. `.waiting` is the
    /// case that broke: it promises a backup is coming, and the blunt warning
    /// sat above it saying nothing was backed up.
    func testWaitingWarnsWithoutContradictingItsOwnDetail() {
        let state = CloudSyncStatus.State.waiting

        let warning = try? XCTUnwrap(state.dataLossWarning)
        XCTAssertNotNil(warning, "an unconfirmed copy still has to warn")
        XCTAssertFalse(
            state.dataLossWarning?.contains("Nothing is backed up") ?? true,
            "contradicts detail(), which says the diary will back up"
        )
    }

    func testStatesThatReachedICloudDoNotWarn() {
        XCTAssertNil(CloudSyncStatus.State.synced(Date()).dataLossWarning)
        XCTAssertNil(CloudSyncStatus.State.syncing.dataLossWarning)
    }

    func testStatesThatCannotSyncGetTheBluntWarning() {
        for state: CloudSyncStatus.State in [
            .unavailable(.notSignedIn),
            .unavailable(.notConfigured),
            .failed("whatever the framework said")
        ] {
            XCTAssertEqual(
                state.dataLossWarning,
                "Nothing is backed up. Deleting the app, or erasing this iPhone, deletes your diary with it.",
                "\(state) can't produce a second copy, so the warning shouldn't be softened"
            )
        }
    }
}
