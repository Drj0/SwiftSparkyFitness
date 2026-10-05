//
//  OnboardingTests.swift
//  SwiftSparkyFitnessTests
//
//  The calorie math agrees with the server's, and onboarding's answers
//  reach the server in the shapes it accepts.
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class OnboardingTests: XCTestCase {

    // MARK: - Math (the server's @workspace/shared numbers)

    func testMifflinStJeorMatchesTheServer() {
        // 10*70 + 6.25*170 - 5*30 + 5 = 1617.5
        XCTAssertEqual(CalorieTarget.bmr(weightKg: 70, heightCm: 170, age: 30, sex: .male), 1617.5, accuracy: 0.01)
        XCTAssertEqual(CalorieTarget.bmr(weightKg: 70, heightCm: 170, age: 30, sex: .female), 1451.5, accuracy: 0.01)
    }

    func testPaceUsesSixThousandKcalPerKgAndTheFloor() {
        // 0.5 kg/week = 3000 kcal/week = ~428.6/day.
        XCTAssertEqual(CalorieTarget.daily(maintenance: 2400, goal: .lose, kgPerWeek: 0.5), 1970)
        XCTAssertEqual(CalorieTarget.daily(maintenance: 2400, goal: .gain, kgPerWeek: 0.25), 2610)
        XCTAssertEqual(CalorieTarget.daily(maintenance: 2400, goal: .maintain, kgPerWeek: 1), 2400)
        XCTAssertEqual(CalorieTarget.daily(maintenance: 1500, goal: .lose, kgPerWeek: 1), CalorieTarget.floor)
    }

    func testUnitsConvertBeforeTheFormula() {
        XCTAssertEqual(CalorieTarget.kilograms(154.32, unit: "lbs"), 70, accuracy: 0.01)
        XCTAssertEqual(CalorieTarget.centimetres(67, unit: "inches"), 170.18, accuracy: 0.01)
        XCTAssertEqual(CalorieTarget.waterMl(weightKg: 70), 2500)
    }

    // MARK: - Server shapes

    func testSubmissionNeedsEveryAnswerAndMaintainingTargetsTheCurrentWeight() {
        var profile = UserProfile(sex: .female, birthDate: "1995-06-15", primaryGoal: .maintain)
        XCTAssertNil(OnboardingSubmission(profile: profile, currentWeight: 70, height: nil, activityLevel: "sedentary"))
        let submission = OnboardingSubmission(profile: profile, currentWeight: 70, height: 165, activityLevel: "sedentary")
        XCTAssertEqual(submission?.targetWeight, 70)
        profile.primaryGoal = nil
        XCTAssertNil(OnboardingSubmission(profile: profile, currentWeight: 70, height: 165, activityLevel: "sedentary"))
    }

    func testProfileDecodesTheLiveResponse() throws {
        let json = #"{"id":"x","full_name":"onb","date_of_birth":"1995-06-15","gender":"Female","target_weight":62}"#
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile, UserProfile(sex: .female, birthDate: "1995-06-15", targetWeight: 62))
        XCTAssertEqual(try JSONDecoder().decode(UserProfile.self, from: Data("{}".utf8)), UserProfile())
    }

    // MARK: - Sync

    func testPushSendsTheProfileAndCompletesOnboarding() async throws {
        let device = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try await device.updateUserPreference(.activityLevel, to: "lightly_active")
        _ = try await device.upsertBodyMeasurements(BodyMeasurementsInput(date: Date(), values: [.weight: 70, .height: 165]))
        try await device.saveProfile(UserProfile(sex: .female, birthDate: "1995-06-15", primaryGoal: .lose, targetWeight: 62))
        let server = FakeSyncServer()

        _ = try await ServerPush(store: device.store, server: server, account: "acct").run()

        let onServer = try await server.backing.profile()
        XCTAssertEqual(onServer.sex, .female)
        XCTAssertEqual(onServer.birthDate, "1995-06-15")
        XCTAssertEqual(server.onboardingSubmissions.first?.targetWeight, 62)
        XCTAssertEqual(server.onboardingSubmissions.first?.activityLevel, "lightly_active")
        XCTAssertEqual(server.onboardingSubmissions.first?.height, 165)
    }

    func testArchiveRoundTripsTheProfile() async throws {
        let device = LocalAPIClient(store: LocalStore(inMemory: true))
        let profile = UserProfile(sex: .male, birthDate: "1990-01-02", primaryGoal: .gain, targetWeight: 80)
        try await device.saveProfile(profile)
        let archive = try DiaryArchive.decode(DiaryArchive(from: device.store).encoded())
        let restored = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try archive.restore(into: restored.store)
        let restoredProfile = try await restored.profile()
        XCTAssertEqual(restoredProfile, profile)
    }

    // MARK: - Skipping and input

    private func model() -> OnboardingViewModel {
        OnboardingViewModel(account: nil, apiClient: LocalAPIClient(store: LocalStore(inMemory: true)), offersHealth: false)
    }

    func testSkippingEveryQuestionStillReachesAPlan() {
        let vm = model()
        for _ in 0..<4 { vm.skipStep() }
        XCTAssertEqual(vm.step, .plan)
        XCTAssertNil(vm.maintenance)
        XCTAssertEqual(vm.suggestedCalories, GoalsViewModel.suggestedCalories)
        XCTAssertTrue(vm.assumptions.contains { $0.step == .body })
    }

    func testSkippedSexUsesTheMidpointAndSkippedActivityMostlySitting() {
        let vm = model()
        vm.skipStep()                       // about
        vm.weightText = "70"; vm.heightText = "170"
        vm.answerStep()                     // body
        vm.skipStep()                       // activity
        vm.skipStep()                       // goal
        let male = CalorieTarget.bmr(weightKg: 70, heightCm: 170, age: 30, sex: .male)
        let female = CalorieTarget.bmr(weightKg: 70, heightCm: 170, age: 30, sex: .female)
        XCTAssertEqual(vm.maintenance ?? 0, (male + female) / 2 * 1.2, accuracy: 0.01)
    }

    func testRevisitingFromThePlanReturnsToIt() {
        let vm = model()
        for _ in 0..<4 { vm.skipStep() }
        vm.revisit(.activity)
        vm.activityLevel = "very_active"
        vm.answerStep()
        XCTAssertEqual(vm.step, .plan)
    }

    func testNumberFieldsKeepOnlyDigitsAndOneSeparator() {
        let vm = model()
        vm.weightText = "7a2.5.1\\b"
        XCTAssertEqual(vm.weightText, "72.51")
    }

    func testPaceIsAShareOfBodyWeightAndCapped() {
        XCTAssertEqual(CalorieTarget.Pace.medium.kgPerWeek(weightKg: 80, gaining: false), 0.6, accuracy: 0.001)
        XCTAssertEqual(CalorieTarget.Pace.fast.kgPerWeek(weightKg: 150, gaining: false), 1)
        XCTAssertEqual(CalorieTarget.Pace.fast.kgPerWeek(weightKg: 100, gaining: true), 0.5)
        XCTAssertEqual(CalorieTarget.floor(sex: .male), 1500)
        XCTAssertEqual(CalorieTarget.floor(sex: .female), 1200)
    }

    func testTheFloorSlowsAPaceRatherThanPretending() {
        let vm = model()
        vm.sex = .female; vm.answerStep()
        vm.weightText = "50"; vm.heightText = "150"; vm.answerStep()
        vm.activityLevel = "sedentary"; vm.answerStep()
        vm.goal = .lose
        // Maintenance ~1350: fast's 0.5 kg would need 1350 - 714, under 1200.
        XCTAssertLessThan(vm.kgPerWeek(.fast), vm.requestedKgPerWeek(.fast))
        XCTAssertGreaterThanOrEqual(vm.kgPerWeek(.fast), 0)
    }

    func testTargetStaysInsideAHealthyBMI() {
        let vm = model()
        vm.weightText = "70"; vm.heightText = "170"
        vm.goal = .lose
        vm.targetWeightText = "50"          // BMI 17.3
        XCTAssertNotNil(vm.targetError)
        vm.targetWeightText = "60"          // BMI 20.8
        XCTAssertNil(vm.targetError)
        vm.goal = .gain
        vm.targetWeightText = "95"          // BMI 32.9
        XCTAssertNotNil(vm.targetError)
    }

    func testAnsweredSexIsNotAskedForAgain() {
        let vm = model()
        vm.sex = .male
        vm.answerStep()
        vm.weightText = "70"; vm.heightText = "170"
        vm.answerStep()
        vm.skipStep(); vm.skipStep()
        let prompt = vm.assumptions.first { $0.step == .about }?.text ?? ""
        XCTAssertFalse(prompt.contains("sex"))
        XCTAssertTrue(prompt.contains("birthday"))
    }

    func testAnUntouchedBirthdayIsNotAnAnswer() {
        let vm = model()
        vm.sex = .female
        vm.answerStep()
        vm.weightText = "70"; vm.heightText = "170"
        vm.answerStep()
        vm.skipStep(); vm.skipStep()
        XCTAssertTrue(vm.assumptions.contains { $0.step == .about })
        vm.birthDate = Calendar.current.date(byAdding: .year, value: -40, to: Date())!
        XCTAssertFalse(vm.assumptions.contains { $0.step == .about })
    }

    func testSwitchingUnitsConvertsWhatWasTyped() {
        let vm = model()
        vm.weightText = "68"
        vm.weightUnit = "lbs"
        XCTAssertEqual(vm.weightText, "149.9")
        vm.heightText = "170"
        vm.heightUnit = "inches"
        XCTAssertEqual(vm.heightText, "66.9")
    }

    // MARK: - Metric on the server

    private func pull(_ device: LocalAPIClient, from server: FakeSyncServer, account: String) async throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        _ = try await ServerPull(store: device.store, server: server, account: account).run(from: yesterday, to: Date())
    }

    func testCheckInsGoUpInKgAndComeBackInPounds() async throws {
        let account = UUID().uuidString
        let device = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try await device.updateUserPreference(.weight, to: "lbs")
        _ = try await device.updateUserPreference(.measurement, to: "inches")
        _ = try await device.upsertBodyMeasurements(BodyMeasurementsInput(date: Date(), values: [.weight: 154.3, .waist: 32]))
        let server = FakeSyncServer()

        _ = try await ServerPush(store: device.store, server: server, account: account).run()
        let onServer = try await server.backing.bodyMeasurements(date: Date())
        XCTAssertEqual(onServer.weight ?? 0, 69.99, accuracy: 0.01)
        XCTAssertEqual(onServer.waist ?? 0, 81.28, accuracy: 0.01)

        let other = LocalAPIClient(store: LocalStore(inMemory: true))
        try await pull(other, from: server, account: account)
        let pulled = try await other.bodyMeasurements(date: Date())
        XCTAssertEqual(pulled.weight, 154.3)
        XCTAssertEqual(pulled.waist, 32)
    }

    func testSwitchingUnitsConvertsWhatIsStored() async throws {
        let device = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try await device.upsertBodyMeasurements(BodyMeasurementsInput(date: Date(), values: [.weight: 70, .height: 170, .bodyFatPercentage: 20]))
        try await device.saveProfile(UserProfile(targetWeight: 65))
        _ = try await device.updateUserPreference(.weight, to: "lbs")
        _ = try await device.updateUserPreference(.measurement, to: "inches")
        let stored = try await device.bodyMeasurements(date: Date())
        XCTAssertEqual(stored.weight, 154.32)
        XCTAssertEqual(stored.height, 66.93)
        XCTAssertEqual(stored.bodyFatPercentage, 20)
        let target = try await device.profile().targetWeight
        XCTAssertEqual(target, 143.3)
    }

    func testAnOldPoundDiaryIsResentInKgOnce() async throws {
        let account = UUID().uuidString
        let device = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try await device.updateUserPreference(.weight, to: "lbs")
        _ = try await device.upsertBodyMeasurements(BodyMeasurementsInput(date: Date(), values: [.weight: 154.3]))
        let server = FakeSyncServer()
        _ = try await ServerPush(store: device.store, server: server, account: account).run()
        // What a build before the fix left there: the lb number as if kg.
        _ = try await server.backing.upsertBodyMeasurements(BodyMeasurementsInput(date: Date(), values: [.weight: 154.3]))
        UserDefaults.standard.removeObject(forKey: "metricResend|\(account)")

        _ = try await ServerPush(store: device.store, server: server, account: account).run()
        try await pull(device, from: server, account: account)

        let onServer = try await server.backing.bodyMeasurements(date: Date())
        XCTAssertEqual(onServer.weight ?? 0, 69.99, accuracy: 0.01)
        let local = try await device.bodyMeasurements(date: Date())
        XCTAssertEqual(local.weight, 154.3)
    }
}
