import XCTest
@testable import LocalCore

final class LocalDataStoreTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDownWithError() throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
    }
    private func location() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return directory.appendingPathComponent("records.json")
    }
    private func call(_ store: LocalDataStore, _ path: String, _ method: String = "GET", _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "local://device/v6" + path)!)
        request.httpMethod = method
        if method != "GET" { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await store.perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TestFailure.http(status) }
        return (try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]) ?? [:]
    }
    private func number(_ object: [String: Any], _ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? -1 }
    private let day = "2026-10-19"
    private var rice: [String: Any] { ["id": "rice", "name": "米饭", "calories": 200.0, "protein": 4.0, "carbs": 44.0, "fat": 1.0, "fiber": 2.0, "sodium": 10.0, "consumed_ratio": 1.0] }

    // A missing durable write or cross-store shared state breaks this test.
    func testPersistenceReloadAndIsolation() async throws {
        let file = location()
        let store = LocalDataStore(fileURL: file)
        _ = try await call(store, "/diary-note", "POST", ["date": day, "note": "今天在家做饭"])
        let reloaded = try await call(LocalDataStore(fileURL: file), "/diary-note?date=\(day)")
        XCTAssertEqual(reloaded["note"] as? String, "今天在家做饭")
        let isolated = try await call(LocalDataStore(fileURL: location()), "/diary-note?date=\(day)")
        XCTAssertEqual(isolated["note"] as? String, "")
    }
    // Omitting the persisted retry ledger would double count on process restart.
    func testFoodIdempotencySurvivesReloadAndTotalsUseActualNutrition() async throws {
        let file = location()
        let body: [String: Any] = ["date": day, "foods": [rice, ["name": "鸡蛋", "calories": 80.0, "protein": 7.0, "carbs": 1.0, "fat": 5.0]], "request_id": "same", "meal_category": "lunch"]
        _ = try await call(LocalDataStore(fileURL: file), "/food-log", "POST", body)
        let store = LocalDataStore(fileURL: file)
        _ = try await call(store, "/food-log", "POST", body)
        let summary = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_consumed"), 280)
        XCTAssertEqual(number(summary, "protein"), 11)
        XCTAssertEqual(number(summary, "meals_count"), 1)
        let foods = try await call(store, "/foods?date=\(day)")
        XCTAssertEqual((foods["foods"] as? [[String: Any]])?.count, 2)
    }
    // Replacing a meal must validate the whole edit and commit the removal and insert together.
    func testFoodLogReplacementRejectsInvalidEditThenReplacesGroupExactlyOnce() async throws {
        let file = location()
        let store = LocalDataStore(fileURL: file)
        let original = try await call(store, "/food-log", "POST", ["date": day, "foods": [rice]])
        let group = try XCTUnwrap((original["foods"] as? [[String: Any]])?.first?["upload_group_id"] as? String)
        let originalList = try await call(store, "/foods?date=\(day)")
        let originalID = try XCTUnwrap((originalList["foods"] as? [[String: Any]])?.first?["id"] as? Int)
        do {
            _ = try await call(store, "/food-log", "POST", ["date": day, "foods": [rice, ["name": "错误食物", "calories": -1]], "replace_group_id": group])
            XCTFail("Invalid replacement must fail")
        } catch TestFailure.http(let status) { XCTAssertEqual(status, 400) }
        let retained = try await call(store, "/foods?date=\(day)")
        XCTAssertEqual((retained["foods"] as? [[String: Any]])?.map { $0["id"] as? Int }, [originalID])
        let replacement: [String: Any] = ["date": day, "foods": [["name": "鸡蛋", "calories": 80]], "replace_group_id": group, "request_id": "replace-meal"]
        _ = try await call(store, "/food-log", "POST", replacement)
        let reloaded = LocalDataStore(fileURL: file)
        let retry = try await call(reloaded, "/food-log", "POST", replacement)
        XCTAssertEqual(retry["already_logged"] as? Bool, true)
        let listed = try await call(reloaded, "/foods?date=\(day)")
        let foods = try XCTUnwrap(listed["foods"] as? [[String: Any]])
        XCTAssertEqual(foods.count, 1)
        XCTAssertEqual(foods.first?["food_name"] as? String, "鸡蛋")
        let summary = try await call(reloaded, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_consumed"), 80)
    }
    func testFoodLogReplacementByIDsLeavesOtherMealsUntouched() async throws {
        let store = LocalDataStore(fileURL: location())
        _ = try await call(store, "/food-log", "POST", ["date": day, "foods": [rice, ["name": "鸡蛋", "calories": 80]]])
        let first = try await call(store, "/foods?date=\(day)")
        let ids = try XCTUnwrap(first["foods"] as? [[String: Any]]).compactMap { $0["id"] as? Int }
        _ = try await call(store, "/food-log", "POST", ["date": day, "foods": [["name": "苹果", "calories": 50]]])
        _ = try await call(store, "/food-log", "POST", ["date": day, "foods": [["name": "面包", "calories": 120]], "replace_ids": ids])
        let listed = try await call(store, "/foods?date=\(day)")
        let foods = try XCTUnwrap(listed["foods"] as? [[String: Any]])
        XCTAssertEqual(Set(foods.compactMap { $0["food_name"] as? String }), Set(["苹果", "面包"]))
        let summary = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_consumed"), 170)
    }
    func testFoodLogReplacementWriteFailureRetainsOldMeal() async throws {
        let file = location()
        let directory = file.deletingLastPathComponent()
        let store = LocalDataStore(fileURL: file)
        let saved = try await call(store, "/food-log", "POST", ["date": day, "foods": [rice]])
        let group = try XCTUnwrap((saved["foods"] as? [[String: Any]])?.first?["upload_group_id"] as? String)
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        do {
            _ = try await call(store, "/food-log", "POST", ["date": day, "foods": [["name": "鸡蛋", "calories": 80]], "replace_group_id": group, "request_id": "replacement-write"])
            XCTFail("Replacement must fail when durable storage fails")
        } catch {}
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: file)
        let summary = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_consumed"), 200)
        let listed = try await call(LocalDataStore(fileURL: file), "/foods?date=\(day)")
        XCTAssertEqual((listed["foods"] as? [[String: Any]])?.first?["food_name"] as? String, "米饭")
    }
    // A photo is stored once; neither each food nor the retry ledger may duplicate its bytes.
    func testPhotoStorageIsBoundedAndRetryReconstructsPhotoURLs() async throws {
        let file = location()
        let image = Data(repeating: 0x42, count: 250 * 1024).base64EncodedString()
        let body: [String: Any] = ["date": day, "foods": [rice, ["name": "鸡蛋", "calories": 80], ["name": "苹果", "calories": 50]], "image_base64": image, "request_id": "large-photo"]
        let saved = try await call(LocalDataStore(fileURL: file), "/food-log", "POST", body)
        XCTAssertEqual((saved["foods"] as? [[String: Any]])?.count, 3)
        XCTAssertLessThan(try Data(contentsOf: file).count, 600 * 1024)
        let reloaded = LocalDataStore(fileURL: file)
        let retry = try await call(reloaded, "/food-log", "POST", body)
        XCTAssertEqual(retry["already_logged"] as? Bool, true)
        let expectedURL = "data:image/jpeg;base64," + image
        XCTAssertEqual((retry["foods"] as? [[String: Any]])?.map { $0["image_url"] as? String }, Array(repeating: expectedURL, count: 3))
        let listed = try await call(reloaded, "/foods?date=\(day)")
        XCTAssertEqual((listed["foods"] as? [[String: Any]])?.map { $0["image_url"] as? String }, Array(repeating: expectedURL, count: 3))
        XCTAssertLessThan(try Data(contentsOf: file).count, 600 * 1024)
    }
    func testReplacementKeepsOriginalPhotoWithoutKeepingDuplicateImageBytes() async throws {
        let file = location()
        let store = LocalDataStore(fileURL: file)
        let image = Data(repeating: 0x42, count: 250 * 1024).base64EncodedString()
        let original = try await call(store, "/food-log", "POST", ["date": day, "foods": [rice], "image_base64": image, "request_id": "original-photo"])
        let group = try XCTUnwrap((original["foods"] as? [[String: Any]])?.first?["upload_group_id"] as? String)
        let replaced = try await call(store, "/food-log", "POST", ["date": day, "foods": [["name": "鸡蛋", "calories": 80]], "replace_group_id": group, "request_id": "replace-photo"])
        XCTAssertEqual((replaced["foods"] as? [[String: Any]])?.first?["image_url"] as? String, "data:image/jpeg;base64," + image)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((document["meal_images"] as? [String: String])?.count, 1)
        XCTAssertLessThan(try Data(contentsOf: file).count, 600 * 1024)
    }
    func testMissingReferencedPhotoBlocksMutationWithoutOverwritingFile() async throws {
        let file = location()
        _ = try await call(LocalDataStore(fileURL: file), "/food-log", "POST", ["date": day, "foods": [rice], "image_base64": Data([1, 2, 3]).base64EncodedString()])
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        document.removeValue(forKey: "meal_images")
        let corrupt = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try corrupt.write(to: file)
        do { _ = try await call(LocalDataStore(fileURL: file), "/diary-note", "POST", ["date": day, "note": "不能覆盖丢失照片的文件"]); XCTFail("A missing referenced image is storage corruption") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testExistingSchemaOneInlinePhotosAndRetryPayloadRemainReadable() async throws {
        let file = location()
        let image = Data(repeating: 0x42, count: 1024).base64EncodedString()
        let imageURL = "data:image/jpeg;base64," + image
        let body: [String: Any] = ["date": day, "foods": [rice], "image_base64": image, "request_id": "legacy-photo"]
        let response = try await call(LocalDataStore(fileURL: file), "/food-log", "POST", body)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy.removeValue(forKey: "meal_images")
        legacy["foods"] = (legacy["foods"] as? [[String: Any]] ?? []).map { row -> [String: Any] in
            var row = row; row.removeValue(forKey: "image_ref"); row["image_url"] = imageURL; return row
        }
        var fingerprintBody = body; fingerprintBody.removeValue(forKey: "request_id")
        let fingerprint = String(decoding: try JSONSerialization.data(withJSONObject: fingerprintBody, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
        legacy["idempotency"] = ["POST:/food-log:legacy-photo": ["fingerprint": fingerprint, "response": response]]
        try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]).write(to: file)
        let reloaded = LocalDataStore(fileURL: file)
        let retry = try await call(reloaded, "/food-log", "POST", body)
        XCTAssertEqual(retry["already_logged"] as? Bool, true)
        XCTAssertEqual((retry["foods"] as? [[String: Any]])?.first?["image_url"] as? String, imageURL)
        let listed = try await call(reloaded, "/foods?date=\(day)")
        XCTAssertEqual((listed["foods"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((listed["foods"] as? [[String: Any]])?.first?["image_url"] as? String, imageURL)
        _ = try await call(reloaded, "/diary-note", "POST", ["date": day, "note": "保留已有记录"])
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((persisted["foods"] as? [[String: Any]])?.count, 1)
    }
    // Scaling the already-scaled row instead of its baseline breaks repeated edits.
    func testPortionMoveAndDeletePreserveBaseline() async throws {
        let store = LocalDataStore(fileURL: location())
        _ = try await call(store, "/food-log", "POST", ["date": day, "foods": [rice]])
        let listed = try await call(store, "/foods?date=\(day)")
        let row = try XCTUnwrap((listed["foods"] as? [[String: Any]])?.first)
        let id = try XCTUnwrap(row["id"] as? Int)
        _ = try await call(store, "/food-log/\(id)/portion", "POST", ["consumed_ratio": 0.5])
        let adjusted = try await call(store, "/food-log/\(id)/portion", "POST", ["consumed_ratio": 1.5])
        XCTAssertEqual(number(adjusted["food"] as? [String: Any] ?? [:], "calories"), 300)
        _ = try await call(store, "/food-log/\(id)/move", "POST", ["date": "2026-10-18", "meal_category": "dinner"])
        let empty = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(empty, "calories_consumed"), 0)
        let moved = try await call(store, "/foods?date=2026-10-18")
        XCTAssertEqual((moved["foods"] as? [[String: Any]])?.first?["meal_category"] as? String, "dinner")
        let removed = try await call(store, "/food-log", "DELETE", ["ids": [id]])
        XCTAssertEqual(number(removed, "deleted"), 1)
    }
    // Drinking coefficients and nutrition must be scaled from the preset serving.
    func testHydrationPresetTotalsDeleteAndRetry() async throws {
        let store = LocalDataStore(fileURL: location())
        _ = try await call(store, "/drink-presets", "POST", ["id": "custom", "drink_type": "custom", "name": "我的饮品", "default_amount_ml": 200, "hydration_factor": 0.8, "caffeine_mg": 50, "sugar_g": 10, "calories": 60])
        _ = try await call(store, "/hydration/settings", "PUT", ["hydration_goal_ml": 2400])
        let body: [String: Any] = ["date": day, "drink_type": "custom", "amount_ml": 400, "request_id": "drink1"]
        let log = try await call(store, "/hydration", "POST", body)
        _ = try await call(store, "/hydration", "POST", body)
        let summary = try await call(store, "/hydration/summary?date=\(day)")
        XCTAssertEqual(number(summary, "hydration_effective_ml"), 320)
        XCTAssertEqual(number(summary, "caffeine_mg"), 100)
        XCTAssertEqual(number(summary, "hydration_goal_ml"), 2400)
        let daily = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(daily, "calories_consumed"), 120)
        let deleted = try await call(store, "/hydration", "DELETE", ["ids": [try XCTUnwrap(log["id"] as? String)]])
        XCTAssertEqual(number(deleted, "deleted"), 1)
    }
    // Unknown request keys must not leak credentials into saved data or export.
    func testExportResetAndImageData() async throws {
        let file = location()
        let store = LocalDataStore(fileURL: file)
        let image = Data([0xff, 0xd8, 0xff]).base64EncodedString()
        _ = try await call(store, "/food-log", "POST", ["date": day, "foods": [rice], "image_base64": image, "api_key": "secret-key"])
        let foods = try await call(store, "/foods?date=\(day)")
        XCTAssertEqual((foods["foods"] as? [[String: Any]])?.first?["image_url"] as? String, "data:image/jpeg;base64," + image)
        let exported = try await call(store, "/account/export")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: exported), as: UTF8.self).contains("secret-key"))
        let deleted = try await call(store, "/account", "DELETE", ["confirmation": "DELETE"])
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
        let empty = try await call(LocalDataStore(fileURL: file), "/foods?date=\(day)")
        XCTAssertEqual((empty["foods"] as? [[String: Any]])?.count, 0)
    }
    // Invalid data must remain untouched and block mutations, including reset.
    func testCorruptionIsReportedWithoutOverwritingExistingFile() async throws {
        let file = location()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{broken".utf8)
        try original.write(to: file)
        let store = LocalDataStore(fileURL: file)
        do { _ = try await call(store, "/diary-note", "POST", ["note": "overwrite"]); XCTFail("Corrupt storage must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    // A failed save may not leave an in-memory-only successful mutation.
    func testFailedWriteRollsBackMemory() async throws {
        let file = location()
        let directory = file.deletingLastPathComponent()
        let store = LocalDataStore(fileURL: file)
        _ = try await call(store, "/diary-note", "POST", ["date": day, "note": "before"])
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        do { _ = try await call(store, "/diary-note", "POST", ["date": day, "note": "after"]); XCTFail("Write must fail") } catch {}
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: file)
        let note = try await call(store, "/diary-note?date=\(day)")
        XCTAssertEqual(note["note"] as? String, "before")
    }
    // Dedup must survive relaunch; unsupported types must not be marked imported.
    func testHealthImportDeduplicatesAndUpdatesDailySummary() async throws {
        let file = location()
        let records: [[String: Any]] = [
            ["external_id": "s1", "record_type": "steps", "value": 3000, "unit": "count", "date": day],
            ["external_id": "w1", "record_type": "dietary_water", "value": 0.5, "unit": "l", "date": day],
            ["external_id": "e1", "record_type": "active_energy", "value": 200, "unit": "kcal", "date": day],
            ["external_id": "b1", "record_type": "weight", "value": 70, "unit": "kg", "date": day],
            ["external_id": "n1", "record_type": "sleep_duration", "value": 480, "unit": "min", "date": day],
            ["external_id": "u1", "record_type": "unsupported", "value": 5, "date": day]
        ]
        let imported = try await call(LocalDataStore(fileURL: file), "/health/import", "POST", ["records": records])
        XCTAssertEqual((imported["imported"] as? [[String: Any]])?.count, 5)
        let store = LocalDataStore(fileURL: file)
        let retry = try await call(store, "/health/import", "POST", ["records": records])
        XCTAssertEqual((retry["imported"] as? [[String: Any]])?.count, 0)
        let summary = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "steps"), 3000)
        XCTAssertEqual(number(summary, "water_ml"), 500)
        XCTAssertEqual(number(summary, "calories_burned"), 200)
        XCTAssertEqual(number(summary, "weight_kg"), 70)
        let sleep = try await call(store, "/sleep/summary?date=\(day)")
        XCTAssertEqual(number(sleep, "duration_hours"), 8)
    }
    // These are the exact unit strings emitted by HealthKitSyncService.
    func testHealthImportAcceptsNativeHealthKitChineseUnits() async throws {
        let file = location()
        let records: [[String: Any]] = [
            ["external_id": "native-steps", "record_type": "steps", "value": 4300, "unit": "步", "date": day, "metadata": ["aggregation": "day"]],
            ["external_id": "native-weight", "record_type": "weight", "value": 68.5, "unit": "公斤", "date": day],
            ["external_id": "native-water", "record_type": "dietary_water", "value": 600, "unit": "毫升", "date": day],
            ["external_id": "native-energy", "record_type": "active_energy", "value": 240, "unit": "千卡", "date": day, "metadata": ["aggregation": "day"]],
            ["external_id": "native-sleep", "record_type": "sleep_duration", "value": 7.5, "unit": "hour", "date": day]
        ]
        let response = try await call(LocalDataStore(fileURL: file), "/health/import", "POST", ["source": "healthkit", "records": records])
        XCTAssertEqual(number(response, "imported_count"), 5)
        XCTAssertEqual(number(response, "skipped_count"), 0)
        XCTAssertEqual(Set((response["imported"] as? [[String: Any]] ?? []).compactMap { $0["external_id"] as? String }), Set(["native-steps", "native-weight", "native-water", "native-energy", "native-sleep"]))
        let reloaded = LocalDataStore(fileURL: file)
        let summary = try await call(reloaded, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "steps"), 4300)
        XCTAssertEqual(number(summary, "weight_kg"), 68.5)
        XCTAssertEqual(number(summary, "water_ml"), 600)
        XCTAssertEqual(number(summary, "calories_burned"), 240)
        let sleep = try await call(reloaded, "/sleep/summary?date=\(day)")
        XCTAssertEqual(number(sleep, "duration_hours"), 7.5)
        let retry = try await call(reloaded, "/health/import", "POST", ["source": "healthkit", "records": records])
        XCTAssertEqual(number(retry, "imported_count"), 0)
        XCTAssertEqual(number(retry, "skipped_count"), 5)
    }
    func testGoalMacrosPreferencesRemindersAndSleepPersist() async throws {
        let file = location()
        let store = LocalDataStore(fileURL: file)
        _ = try await call(store, "/goal-plan", "POST", ["current_weight_kg": 70, "goal_weight_kg": 65, "height_cm": 175, "age": 30, "gender": "male", "activity": "moderate", "deficit_pct": 20])
        let plan = try await call(store, "/goal-plan")
        XCTAssertEqual(number(plan, "bmr"), 1649)
        _ = try await call(store, "/macro-goals", "POST", ["daily_calories": 1800, "protein_g": 100])
        _ = try await call(store, "/user-preferences", "PUT", ["diet_type": "vegetarian", "allergies": ["花生"]])
        _ = try await call(store, "/reminders", "POST", ["reminders": [["id": "r1", "meal_type": "lunch", "time": "12:00", "enabled": true]]])
        _ = try await call(store, "/sleep", "POST", ["date": day, "duration_hours": 7.5, "quality": 4, "request_id": "sleep"])
        let reloaded = LocalDataStore(fileURL: file)
        let prefs = try await call(reloaded, "/user-preferences")
        XCTAssertEqual(prefs["diet_type"] as? String, "vegetarian")
        let macros = try await call(reloaded, "/macro-goals")
        XCTAssertEqual(number(macros, "protein_g"), 100)
        let reminders = try await call(reloaded, "/reminders")
        XCTAssertEqual((reminders["reminders"] as? [[String: Any]])?.count, 1)
        let summary = try await call(reloaded, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_goal"), 1800)
    }
    func testSavedMealAndFoodCRUDAndLogging() async throws {
        let store = LocalDataStore(fileURL: location())
        let created = try await call(store, "/saved-meals", "POST", ["title": "午饭", "foods": [rice], "meal_category": "lunch"])
        let meal = try XCTUnwrap(created["meal"] as? [String: Any])
        let id = try XCTUnwrap(meal["id"] as? String)
        _ = try await call(store, "/saved-meals/\(id)", "PUT", ["title": "米饭午餐", "foods": [rice]])
        _ = try await call(store, "/saved-meals/\(id)/favorite", "POST")
        let logged = try await call(store, "/saved-meals/\(id)/log", "POST", ["date": day, "portion_multiplier": 2])
        XCTAssertEqual(number(logged, "saved"), 1)
        let saved = try await call(store, "/saved-foods", "POST", ["food": rice])
        let foodID = try XCTUnwrap((saved["food"] as? [String: Any])?["id"] as? String)
        _ = try await call(store, "/saved-foods/\(foodID)/log", "POST", ["date": day, "portion_multiplier": 0.5])
        let summary = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_consumed"), 500)
        let deleted = try await call(store, "/saved-meals/\(id)", "DELETE")
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
    }
    // The multiplier scales item count, while grams_per_unit remains a unit property.
    func testSavedMealAndFoodMultiplierScalesEggCountWithoutScalingEachEgg() async throws {
        let store = LocalDataStore(fileURL: location())
        let eggs: [String: Any] = ["name": "水煮蛋", "calories": 156.0, "protein": 12.6, "carbs": 1.2, "fat": 10.6, "grams_per_unit": 50.0, "quantity_count": 2.0, "quantity_unit": "个", "quantity_description": "2个（100g）", "serving_size": "2个（100g）"]
        for root in ["saved-meals", "saved-foods"] {
            let body: [String: Any] = root == "saved-meals" ? ["title": "鸡蛋早餐", "foods": [eggs]] : ["food": eggs]
            let created = try await call(store, "/" + root, "POST", body)
            let key = root == "saved-meals" ? "meal" : "food"
            let id = try XCTUnwrap((created[key] as? [String: Any])?["id"] as? String)
            _ = try await call(store, "/\(root)/\(id)/log", "POST", ["date": day, "portion_multiplier": 2])
        }
        let listed = try await call(store, "/foods?date=\(day)")
        let foods = try XCTUnwrap(listed["foods"] as? [[String: Any]])
        XCTAssertEqual(foods.count, 2)
        for food in foods {
            XCTAssertEqual(number(food, "quantity_count"), 4)
            XCTAssertEqual(number(food, "grams_per_unit"), 50)
            XCTAssertEqual(number(food, "quantity_count") * number(food, "grams_per_unit"), 200)
            XCTAssertEqual(number(food, "calories"), 312)
            XCTAssertEqual(number(food, "protein"), 25.2, accuracy: 0.001)
            XCTAssertEqual(food["quantity_description"] as? String, "4个（200g）")
            XCTAssertEqual(food["serving_size"] as? String, "4个（200g）")
        }
    }
    // HealthKit samples arrive newest-first, independently of their stored insertion order.
    func testImportedWeightsSortChronologicallyAndLatestSameDayDrivesSummaryAndEstimate() async throws {
        let file = location()
        let records: [[String: Any]] = [
            ["external_id": "latest", "record_type": "weight", "value": 68, "unit": "公斤", "date": day, "logged_at": "2026-10-19T06:00:00Z"],
            ["external_id": "earlier-same-day", "record_type": "weight", "value": 70, "unit": "公斤", "date": day, "logged_at": "2026-10-19T01:00:00Z"],
            ["external_id": "yesterday", "record_type": "weight", "value": 75, "unit": "公斤", "date": "2026-10-18", "logged_at": "2026-10-18T10:00:00Z"]
        ]
        _ = try await call(LocalDataStore(fileURL: file), "/health/import", "POST", ["records": records])
        let reloaded = LocalDataStore(fileURL: file)
        let history = try await call(reloaded, "/weight?date=\(day)&days=7")
        let weights = try XCTUnwrap(history["weights"] as? [[String: Any]])
        XCTAssertEqual(weights.map { number($0, "weight_kg") }, [75, 70, 68])
        let summary = try await call(reloaded, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "weight_kg"), 68)
        let estimate = try await call(reloaded, "/exercise/estimate", "POST", ["exercise_id": "walking", "name": "步行", "duration_minutes": 30, "intensity": "moderate"])
        XCTAssertEqual(number(estimate, "calories_burned"), 125)
    }
    func testFastingLifecycleManualAndHistory() async throws {
        let store = LocalDataStore(fileURL: location())
        _ = try await call(store, "/fasting/preferences", "PUT", ["enabled": true, "method": "16:8", "fasting_hours": 16])
        let start = try await call(store, "/fasting/start", "POST", ["method": "16:8", "fasting_hours": 16])
        XCTAssertEqual(start["is_fasting"] as? Bool, true)
        let cancelled = try await call(store, "/fasting/cancel", "POST")
        XCTAssertEqual(cancelled["is_fasting"] as? Bool, false)
        _ = try await call(store, "/fasting/manual", "POST", ["method": "16:8", "fasting_hours": 16, "start_at": "2020-01-01T16:00:00Z", "ended_at": "2020-01-02T08:00:00Z"])
        let history = try await call(store, "/fasting/history?days=3650")
        XCTAssertEqual(number(history["summary"] as? [String: Any] ?? [:], "completed_sessions"), 1)
    }
    func testSearchExerciseEstimatesAndExplicitUnsupportedMutation() async throws {
        let store = LocalDataStore(fileURL: location())
        let found = try await call(store, "/foodDatabase/search?q=%E7%B1%B3%E9%A5%AD")
        XCTAssertFalse((found["foods"] as? [[String: Any]] ?? []).isEmpty)
        let estimate = try await call(store, "/exercise/estimate", "POST", ["exercise_id": "walking", "name": "步行", "duration_minutes": 30, "intensity": "moderate"])
        XCTAssertGreaterThan(number(estimate, "calories_burned"), 50)
        do { _ = try await call(store, "/community/posts/daily-checkin", "POST"); XCTFail("Unsupported mutation cannot succeed") } catch TestFailure.http(let status) { XCTAssertEqual(status, 501) }
    }
    // A single voice save must either commit all food and drinks or commit neither.
    func testVoiceApplyIsAtomicAndIdempotentAndUsesEditedDrinkNutrition() async throws {
        let store = LocalDataStore(fileURL: location())
        let body: [String: Any] = ["date": day, "foods": [rice], "hydration": [["drink_type": "milk", "amount_ml": 240, "calories": 90, "protein_g": 7, "carbs_g": 9, "fat_g": 3, "sugar_g": 8]], "meal_category": "breakfast", "request_id": "voice"]
        _ = try await call(store, "/voice-log/apply", "POST", body)
        _ = try await call(store, "/voice-log/apply", "POST", body)
        let summary = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_consumed"), 290)
        XCTAssertEqual(number(summary, "protein"), 11)
        do { _ = try await call(store, "/voice-log/apply", "POST", ["date": day, "foods": [rice], "hydration": [["drink_type": "milk", "amount_ml": -1]]]); XCTFail("Invalid drink must reject whole voice save") } catch {}
        let unchanged = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(unchanged, "calories_consumed"), 290)
    }
    // HealthKit sends a growing daily aggregate under the same ID during a day.
    func testHealthDailyAggregateReplacesEarlierValueRatherThanAddingIt() async throws {
        let file = location()
        let first: [String: Any] = ["external_id": "healthkit:steps:2026-10-19", "record_type": "steps", "value": 3000, "unit": "count", "date": day, "metadata": ["aggregation": "day"]]
        _ = try await call(LocalDataStore(fileURL: file), "/health/import", "POST", ["records": [first]])
        var updated = first; updated["value"] = 4500
        let store = LocalDataStore(fileURL: file)
        let response = try await call(store, "/health/import", "POST", ["records": [updated]])
        XCTAssertEqual((response["imported"] as? [[String: Any]])?.count, 1)
        let summary = try await call(store, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "steps"), 4500)
    }
    // A reused mutation ID with a different payload must not discard a user's edit.
    func testIdempotencyKeyCannotSilentlySwallowDifferentMutation() async throws {
        let store = LocalDataStore(fileURL: location())
        _ = try await call(store, "/water", "POST", ["date": day, "amount_ml": 250, "request_id": "retry"])
        do { _ = try await call(store, "/water", "POST", ["date": day, "amount_ml": 500, "request_id": "retry"]); XCTFail("Conflicting retry must fail") } catch TestFailure.http(let status) { XCTAssertEqual(status, 409) }
        let summary = try await call(store, "/water?date=\(day)")
        XCTAssertEqual(number(summary, "total_ml"), 250)
    }
    func testExerciseStepsSleepAndFastingEndAreDurable() async throws {
        let file = location()
        let store = LocalDataStore(fileURL: file)
        _ = try await call(store, "/exercise", "POST", ["date": day, "name": "步行", "duration_minutes": 30, "calories_burned": 120, "request_id": "e"])
        _ = try await call(store, "/steps", "POST", ["date": day, "steps": 1000, "request_id": "s"])
        _ = try await call(store, "/sleep", "POST", ["date": day, "duration_hours": 8, "quality": 4, "request_id": "n"])
        _ = try await call(store, "/fasting/start", "POST", ["fasting_hours": 16])
        _ = try await call(store, "/fasting/end", "POST", ["notes": "结束记录"])
        let reloaded = LocalDataStore(fileURL: file)
        let summary = try await call(reloaded, "/daily-summary?date=\(day)")
        XCTAssertEqual(number(summary, "calories_burned"), 120)
        XCTAssertEqual(number(summary, "calories_goal"), 2120)
        XCTAssertEqual(number(summary, "steps"), 1000)
        let sleep = try await call(reloaded, "/sleep/summary?date=\(day)")
        XCTAssertEqual(number(sleep, "duration_hours"), 8)
        let history = try await call(reloaded, "/fasting/history")
        XCTAssertEqual((history["sessions"] as? [[String: Any]])?.last?["status"] as? String, "ended")
    }
    enum TestFailure: Error { case http(Int) }
}
