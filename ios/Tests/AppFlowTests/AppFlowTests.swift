import XCTest
@testable import LightCal

final class AppFlowTests: XCTestCase {
    private func makeClient() -> APIClient {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("records.json")
        return APIClient(localStore: LocalDataStore(fileURL: file))
    }

    func testRecordsPersistAndDecodeWithoutServer() async throws {
        let client = makeClient()
        var goals = MacroGoals()
        goals.dailyCalories = 2100
        try await client.saveMacroGoals(goals)
        _ = try await client.logFoods([FoodItem(name: "米饭", calories: 174, protein: 3.9, carbs: 38.9, fat: 0.5)], mealCategory: "lunch")
        _ = try await client.addHydration(amountMl: 250)
        try await client.addWeight(kg: 65)
        let summary = try await client.getDailySummary()
        XCTAssertEqual(summary.caloriesConsumed, 174)
        XCTAssertEqual(summary.caloriesGoal, 2100)
        XCTAssertEqual(summary.waterMl, 250)
        let foods = try await client.getFoods()
        XCTAssertEqual(foods.first?.foodName, "米饭")
        let group = try XCTUnwrap(foods.first?.uploadGroupId)
        do {
            _ = try await client.logFoods([], replacingGroupId: group)
            XCTFail("Invalid replacement must fail")
        } catch { }
        let unchanged = try await client.getFoods()
        XCTAssertEqual(unchanged.first?.foodName, "米饭")
        _ = try await client.logFoods([FoodItem(name: "鸡蛋", calories: 72)], replacingGroupId: group)
        let replaced = try await client.getFoods()
        XCTAssertEqual(replaced.count, 1)
        XCTAssertEqual(replaced.first?.foodName, "鸡蛋")
        let weights = try await client.getWeights()
        XCTAssertEqual(weights.first?.weightKg, 65)
        _ = try await client.getHydrationSummary()
        _ = try await client.getHydrationSettings()
        _ = try await client.getDrinkPresets()
        _ = try await client.getSleepSummary()
        _ = try await client.getStreak()
        _ = try await client.getUserPreferences()
        _ = try await client.getReminders()
        let export = try await client.exportAccountData()
        XCTAssertFalse(String(data: export, encoding: .utf8)!.contains("apiKey"))
        _ = try await client.deleteAccountData()
        let empty = try await client.getFoods()
        XCTAssertTrue(empty.isEmpty)
    }

    func testSavedFoodsAndFastingDecodeOffline() async throws {
        let client = makeClient()
        let saved = try await client.saveFoodTemplate(FoodItem(name: "鸡蛋", calories: 72))
        _ = try await client.getSavedFoods()
        _ = try await client.logSavedFood(id: saved.id)
        _ = try await client.getFastingPreferences()
        _ = try await client.getFastingHistory()
        _ = try await client.startFasting(method: "16:8", fastingHours: 16)
        _ = try await client.getFastingStatus()
        _ = try await client.cancelFasting()
        _ = try await client.getFastingStatus()
    }
}
