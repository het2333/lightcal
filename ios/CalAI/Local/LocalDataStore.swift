import Foundation
import CryptoKit

/// All tracking data stays in the app sandbox. This transport adapter never opens a socket.
/// An actor serializes mutations, and the JSON document is replaced atomically before success.
public actor LocalDataStore {
    public static let shared = LocalDataStore()
    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("LightCal", isDirectory: true).appendingPathComponent("local-records-v1.json")
    }

    private typealias Object = [String: Any]
    private let fileURL: URL
    private var state: Object?
    private static let collections = ["foods", "hydration", "drink_presets", "weights", "exercises", "steps", "sleep", "energy", "progress_photos", "saved_meals", "saved_foods", "reminders", "fasting_sessions", "health_imports"]
    private static let nutritionKeys = ["calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium", "added_sugar", "sat_fat", "trans_fat", "cholesterol", "vitamin_a", "vitamin_c", "calcium", "iron", "potassium", "magnesium", "zinc", "folate", "vitamin_d", "vitamin_b12", "vitamin_e", "vitamin_k", "omega_3", "monounsaturated_fat", "polyunsaturated_fat"]
    private struct RouteError: Error { let status: Int; let message: String }
    public enum StorageError: LocalizedError {
        case unreadable, unsupportedVersion, saveFailed
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "本机记录无法读取，原文件已保留。请先备份数据，再联系支持。"
            case .unsupportedVersion: return "本机记录格式来自其他版本，请更新应用后重试。原文件已保留。"
            case .saveFailed: return "本机记录未能保存，请检查设备剩余空间后重试。这次修改没有生效。"
            }
        }
    }

    public init(fileURL: URL = LocalDataStore.defaultFileURL) { self.fileURL = fileURL }

    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try loadIfNeeded()
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RouteError(status: 400, message: "记录地址无效")
        }
        var path = components.path
        if path == "/v6" { path = "/" }
        else if path.hasPrefix("/v6/") { path = String(path.dropFirst(3)) }
        let query = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in result[item.name] = item.value ?? "" }
        let method = (request.httpMethod ?? "GET").uppercased()
        let previous = state!
        do {
            var body: Object = [:]
            if let data = request.httpBody, !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data), let object = parsed as? Object else {
                    throw RouteError(status: 400, message: "记录内容格式无效")
                }
                body = object
            }
            let requestID = string(body, "request_id")
            guard requestID.count <= 128 else { throw invalid("记录请求编号过长") }
            let retryKey = method + ":" + path + ":" + requestID
            let fingerprint = requestID.isEmpty ? "" : try requestFingerprint(body)
            if method != "GET", !requestID.isEmpty,
               let cached = object("idempotency")[retryKey] as? Object {
                guard string(cached, "fingerprint") == fingerprint else { throw RouteError(status: 409, message: "这次请求编号已用于不同内容，请重新保存") }
                var result = restoredCachedResponse(cached["response"] ?? Object()) as? Object ?? [:]
                if path == "/food-log" { result["already_logged"] = true }
                return try response(result, url: url)
            }
            let result = try route(method, path, query, body)
            let data = try json(result)
            if method != "GET" {
                if !requestID.isEmpty, let object = result as? Object {
                    var ledger = self.object("idempotency")
                    let compact = compactCachedResponse(object)
                    ledger[retryKey] = ["response": compact, "fingerprint": fingerprint]
                    state!["idempotency"] = ledger
                }
                do { try persist() }
                catch { state = previous; throw StorageError.saveFailed }
            }
            return (data, httpResponse(url: url, status: 200))
        } catch let error as RouteError {
            state = previous
            return try response(["detail": error.message, "local_only": true], url: url, status: error.status)
        } catch {
            state = previous
            throw error
        }
    }

    private func loadIfNeeded() throws {
        guard state == nil else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) { state = Self.emptyState(); return }
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONSerialization.jsonObject(with: data) as? Object,
              let version = document["schema_version"] as? Int else { throw StorageError.unreadable }
        guard version == 1 else { throw StorageError.unsupportedVersion }
        guard Self.collections.allSatisfy({ document[$0] is [Object] }),
              ["macro_goals", "preferences", "diary_notes", "fasting_preferences", "idempotency"].allSatisfy({ document[$0] is Object }),
              let nextID = document["next_food_id"] as? Int, nextID > 0,
              document["goal_plan"] is Object || document["goal_plan"] is NSNull,
              document["diary_completed"] is [String] else { throw StorageError.unreadable }
        if let images = document["meal_images"], !(images is [String: String]) { throw StorageError.unreadable }
        let images = document["meal_images"] as? [String: String] ?? [:]
        for row in document["foods"] as? [Object] ?? [] {
            if let reference = row["image_ref"] {
                guard let key = reference as? String, !key.isEmpty,
                      images[key]?.isEmpty == false || (row["image_url"] as? String)?.isEmpty == false else { throw StorageError.unreadable }
            }
        }
        state = document
        migrateInlinePhotosAndRetryLedger()
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try json(state!)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    private static func emptyState() -> Object {
        var result: Object = [
            "schema_version": 1, "next_food_id": 1, "goal_plan": NSNull(), "diary_notes": Object(), "diary_completed": [String](), "idempotency": Object(), "meal_images": Object(),
            "macro_goals": ["daily_calories": 2000.0, "protein_g": 50.0, "carbs_g": 250.0, "fat_g": 65.0, "fiber_g": 25.0, "sugar_g": 50.0, "sodium_mg": 2300.0, "water_ml": 2000.0, "meal_shares": ["breakfast": 0.25, "lunch": 0.35, "dinner": 0.3, "snack": 0.1]],
            "preferences": ["diet_type": "balanced", "allergies": [String](), "avoid_ingredients": [String](), "favorite_cuisines": ["中式", "家常"], "budget_level": "medium", "prep_time_minutes": 20, "include_imported_recipes_in_meal_plans": true, "taste_tags": ["清淡", "高蛋白"], "meal_names": ["breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"]],
            "fasting_preferences": ["enabled": false, "method": "16:8", "fasting_hours": 16.0, "eating_hours": 8.0, "eating_window_start": "12:00", "reminders_enabled": true, "timezone": "local"]
        ]
        for name in collections { result[name] = [Object]() }
        return result
    }

    private func route(_ method: String, _ path: String, _ query: [String: String], _ body: Object) throws -> Any {
        let read = method == "GET"
        let parts = path.split(separator: "/").map(String.init)
        switch (method, path) {
        case ("GET", "/daily-summary"): return try dailySummary(day(query["date"]))
        case ("GET", "/streak"): return streak()
        case ("GET", "/goal-plan"): return state!["goal_plan"] ?? NSNull()
        case ("POST", "/goal-plan"): return try saveGoalPlan(body)
        case ("GET", "/macro-goals"): return object("macro_goals")
        case ("POST", "/macro-goals"), ("PUT", "/macro-goals"): return try saveMacroGoals(body)
        case ("GET", "/user-preferences"): return object("preferences")
        case ("PUT", "/user-preferences"):
            var prefs = object("preferences")
            for key in ["diet_type", "budget_level"] where body[key] is String { prefs[key] = body[key] }
            for key in ["allergies", "avoid_ingredients", "favorite_cuisines", "taste_tags"] where body[key] is [String] { prefs[key] = body[key] }
            if let names = body["meal_names"] as? [String: String] { prefs["meal_names"] = names }
            if let value = body["include_imported_recipes_in_meal_plans"] as? Bool { prefs["include_imported_recipes_in_meal_plans"] = value }
            if body["prep_time_minutes"] != nil { prefs["prep_time_minutes"] = Int(try bounded(body, "prep_time_minutes", 1...720)) }
            state!["preferences"] = prefs
            return prefs
        case ("GET", "/foods"):
            let date = try day(query["date"])
            return ["date": date, "foods": recentRows("foods", date: date, days: queryDays(query)).map(publicFood)]
        case ("POST", "/food-log"): return try logFoods(body)
        case ("POST", "/voice-log/apply"): return try applyVoiceLog(body)
        case ("DELETE", "/food-log"), ("POST", "/food-log/delete"):
            let ids = Set(body["ids"] as? [Int] ?? [])
            let group = string(body, "upload_group_id")
            guard !ids.isEmpty || !group.isEmpty else { throw invalid("请选择要删除的食物记录") }
            let deleted = rows("foods").filter { ids.contains(int($0, "id")) || (!group.isEmpty && string($0, "upload_group_id") == group) }
            let date = try day(deleted.first?["date"] as? String)
            state!["foods"] = rows("foods").filter { !ids.contains(int($0, "id")) && (group.isEmpty || string($0, "upload_group_id") != group) }
            removeUnusedMealImages(from: deleted)
            return ["status": "ok", "date": date, "deleted": deleted.count, "daily_summary": dailySummary(date)]
        case ("GET", "/frequent-foods"): return frequentFoods(query)
        case ("GET", "/foodDatabase/search"):
            let search = (query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let own = rows("foods").reversed().map { row -> Object in var food = publicFood(row); food["id"] = "local_\(int(row, "id"))"; food["name"] = string(row, "food_name"); return food }
            var seen = Set<String>()
            let found = (own + Self.foodSeeds).filter { food in
                let name = string(food, "name")
                return (search.isEmpty || name.localizedCaseInsensitiveContains(search) || string(food, "aliases").localizedCaseInsensitiveContains(search)) && seen.insert(name).inserted
            }
            return ["foods": Array(found.prefix(50))]
        case ("GET", "/hydration"): return ["logs": recentRows("hydration", date: try day(query["date"]), days: queryDays(query))]
        case ("POST", "/hydration"): return try addHydration(body)
        case ("GET", "/water"): return ["total_ml": number(hydrationSummary(try day(query["date"])), "hydration_effective_ml")]
        case ("POST", "/water"):
            var water = body; water["drink_type"] = "water"
            _ = try addHydration(water)
            return ["status": "ok", "total_ml": number(hydrationSummary(try day(body["date"] as? String)), "hydration_effective_ml")]
        case ("DELETE", "/hydration"):
            let ids = Set(body["ids"] as? [String] ?? [])
            let explicitDate = string(body, "date")
            guard !ids.isEmpty || !explicitDate.isEmpty else { throw invalid("请选择要删除的饮品记录") }
            let date = try day(explicitDate.isEmpty ? rows("hydration").first(where: { ids.contains(string($0, "id")) })?["date"] as? String : explicitDate)
            let old = rows("hydration")
            state!["hydration"] = old.filter { !ids.contains(string($0, "id")) && (explicitDate.isEmpty || string($0, "date") != explicitDate) }
            return ["status": "ok", "deleted": old.count - rows("hydration").count, "summary": hydrationSummary(date)]
        case ("GET", "/hydration/summary"): return try hydrationSummary(day(query["date"]))
        case ("GET", "/hydration/settings"): return hydrationSettings()
        case ("PUT", "/hydration/settings"):
            let goal = try bounded(body, "hydration_goal_ml", 100...20000)
            var macros = object("macro_goals"); macros["water_ml"] = goal; state!["macro_goals"] = macros
            return hydrationSettings()
        case ("GET", "/drink-presets"): return ["presets": drinkPresets()]
        case ("POST", "/drink-presets"): return try saveDrinkPreset(body)
        case ("GET", "/weight"): return ["weights": chronologicalWeights(recentRows("weights", date: try day(query["date"]), days: queryDays(query, fallback: 90)))]
        case ("POST", "/weight"):
            let row: Object = ["id": uuid(), "weight_kg": try bounded(body, "weight_kg", 1...600), "date": try day(body["date"] as? String), "logged_at": timestamp()]
            append("weights", row); return row
        case ("GET", "/exercise"): return ["exercises": rowsOnDay("exercises", try day(query["date"]))]
        case ("POST", "/exercise"): return try addExercise(body)
        case ("GET", "/exercise/catalog"): return ["exercises": Self.exerciseSeeds]
        case ("POST", "/exercise/estimate"): return try estimateExercise(body)
        case ("POST", "/steps"):
            let row: Object = ["id": uuid(), "date": try day(body["date"] as? String), "steps": Int(try bounded(body, "steps", 0...200000)), "source": "manual"]
            append("steps", row); return row
        case ("GET", "/steps"): return ["date": try day(query["date"]), "steps": sum(rowsOnDay("steps", try day(query["date"])), "steps")]
        case ("GET", "/sleep"): return ["logs": rowsOnDay("sleep", try day(query["date"]))]
        case ("GET", "/sleep/summary"): return try sleepSummary(day(query["date"]))
        case ("POST", "/sleep"):
            let row = try addSleep(body)
            return ["status": "ok", "summary": sleepSummary(string(row, "date"))]
        case ("POST", "/health/import"): return try importHealth(body)
        case ("GET", "/diary-note"): return try diaryNote(day(query["date"]))
        case ("POST", "/diary-note"):
            let date = try day(body["date"] as? String)
            let row: Object = ["date": date, "note": string(body, "note"), "updated_at": timestamp()]
            var notes = object("diary_notes"); notes[date] = row; state!["diary_notes"] = notes
            return row
        case ("POST", "/diary/complete"):
            let date = try day(body["date"] as? String)
            var completed = state!["diary_completed"] as? [String] ?? []
            if !completed.contains(date) { completed.append(date) }; state!["diary_completed"] = completed
            return ["status": "ok", "date": date, "message": "今天的日记已完成", "summary": dailySummary(date)]
        case ("GET", "/reminders"): return ["reminders": rows("reminders")]
        case ("POST", "/reminders"):
            guard let reminders = body["reminders"] as? [Object] else { throw invalid("提醒格式无效") }
            state!["reminders"] = try reminders.map(normalizeReminder)
            return ["reminders": rows("reminders")]
        case ("GET", "/fasting/preferences"): return object("fasting_preferences")
        case ("PUT", "/fasting/preferences"): return try saveFastingPreferences(body)
        case ("GET", "/fasting/status"): return fastingStatus()
        case ("GET", "/fasting/history"): return fastingHistory(days: queryDays(query, fallback: 30))
        case ("POST", "/fasting/start"): return try startFasting(body)
        case ("POST", "/fasting/end"), ("POST", "/fasting/cancel"): return try finishFasting(body, cancelled: path.hasSuffix("cancel"))
        case ("POST", "/fasting/manual"): return try manualFasting(body)
        case ("GET", "/saved-meals"), ("GET", "/saved-foods"): return savedList(path, query)
        case ("POST", "/saved-meals"), ("POST", "/saved-foods"): return try saveTemplate(path, body)
        case ("GET", "/progress-photos"):
            let limit = limitValue(query)
            return ["photos": Array(rows("progress_photos").reversed().prefix(limit)).map { row -> Object in var value = row; if query["include_images"] != "1" { value.removeValue(forKey: "image_base64") }; return value }]
        case ("POST", "/progress-photos"):
            let encoded = try validatedImage(string(body, "image_base64"))
            guard !encoded.isEmpty else { throw invalid("请选择照片") }
            var row: Object = ["id": uuid(), "date": try day(body["date"] as? String), "image_base64": encoded, "notes": string(body, "notes"), "created_at": timestamp()]
            if body["weight_kg"] != nil { row["weight_kg"] = try bounded(body, "weight_kg", 1...600) }
            append("progress_photos", row)
            return ["status": "ok", "id": string(row, "id"), "date": string(row, "date")]
        case ("GET", "/account/export"):
            var exported = state!
            exported.removeValue(forKey: "idempotency")
            exported["exported_at"] = timestamp(); exported["storage"] = "device"
            return exported
        case ("DELETE", "/account"):
            guard string(body, "confirmation") == "DELETE" else { throw invalid("请输入 DELETE 确认清空本机记录") }
            var counts: [String: Int] = [:]
            for collection in Self.collections { counts[collection] = rows(collection).count }
            counts["meal_images"] = object("meal_images").count
            state = Self.emptyState()
            return ["deleted": true, "deleted_counts": counts]
        default: break
        }
        if parts.count == 3, parts[0] == "food-log", let id = Int(parts[1]), method == "POST" {
            if parts[2] == "portion" { return try adjustPortion(id, body) }
            if parts[2] == "move" { return try moveFood(id, body) }
        }
        if let root = parts.first, root == "saved-meals" || root == "saved-foods", parts.count >= 2 {
            return try templateAction(root, parts, method, body)
        }
        if read {
            let emptyLists: [String: String] = ["/challenges": "challenges", "/friends": "friends", "/friends/leaderboard": "leaderboard", "/community/feed": "posts", "/meal-plan/history": "plans", "/meal-plan/collections": "collections", "/recipes/suggestions": "recipes", "/delivery/drafts": "drafts", "/decision/events": "events"]
            if let key = emptyLists[path] { return [key: [Object]()] }
        }
        throw RouteError(status: 501, message: "此功能尚未提供本机实现。你的其他记录仍保存在设备上。")
    }

    private func logFoods(_ body: Object) throws -> Object {
        guard let foods = body["foods"] as? [Object], !foods.isEmpty else { throw invalid("请添加食物后再保存") }
        let prepared = try foods.map(normalizedFood).filter { number($0, "consumed_ratio", fallback: 1) > 0 }
        guard !prepared.isEmpty else { throw invalid("没有实际吃下的食物，无需保存这餐") }
        if let value = body["replace_group_id"], !(value is String) { throw invalid("要替换的餐食编号无效") }
        if let value = body["replace_ids"], !(value is [Int]) { throw invalid("要替换的食物编号无效") }
        let replaceGroup = string(body, "replace_group_id").trimmingCharacters(in: .whitespacesAndNewlines)
        let replaceIDs = Set(body["replace_ids"] as? [Int] ?? [])
        guard replaceIDs.allSatisfy({ $0 > 0 }) else { throw invalid("要替换的食物编号无效") }
        let oldFoods = rows("foods").filter { replaceIDs.contains(int($0, "id")) || (!replaceGroup.isEmpty && string($0, "upload_group_id") == replaceGroup) }
        if !replaceGroup.isEmpty, !oldFoods.contains(where: { string($0, "upload_group_id") == replaceGroup }) { throw missing("要替换的餐食已不存在，请刷新后再保存") }
        guard replaceIDs.isSubset(of: Set(oldFoods.map { int($0, "id") })) else { throw missing("要替换的食物已不存在，请刷新后再保存") }
        let date = try day(body["date"] as? String)
        let group = uuid()
        let encoded = try validatedImage(string(body, "image_base64"))
        let providedImage = safeImageURL(string(body, "image_url"))
        let previousImage = oldFoods.first.map { string(publicFood($0), "image_url") } ?? ""
        let imageURL = encoded.isEmpty ? (providedImage.isEmpty ? previousImage : providedImage) : "data:image/jpeg;base64," + encoded
        let imageReference = imageURL.isEmpty ? "" : storeMealImage(imageURL, preferredKey: group)
        var saved: [Object] = []
        for food in prepared {
            let ratio = number(food, "consumed_ratio", fallback: 1)
            var row = food
            let id = int(state!, "next_food_id", fallback: 1)
            state!["next_food_id"] = id + 1
            row["id"] = id; row["food_id"] = string(food, "id"); row["food_name"] = string(food, "name")
            row["date"] = date; row["meal_category"] = string(body, "meal_category", fallback: "snack")
            row["upload_group_id"] = group; row["upload_group_title"] = string(body, "group_title")
            if !imageReference.isEmpty { row["image_ref"] = imageReference }
            row["logged_at"] = timestamp()
            var baseline: Object = [:]
            for key in Self.nutritionKeys { baseline[key] = number(food, key) / ratio }
            row["_baseline"] = baseline
            row["original_calories"] = number(baseline, "calories")
            row["leftover_calories"] = max(0, number(baseline, "calories") - number(food, "calories"))
            row["adjusted_by_leftovers"] = 0
            append("foods", row)
            saved.append(["name": string(food, "name"), "calories": number(food, "calories"), "upload_group_id": group, "upload_group_title": string(body, "group_title"), "image_url": imageURL])
        }
        let oldIDs = Set(oldFoods.map { int($0, "id") })
        state!["foods"] = rows("foods").filter { !oldIDs.contains(int($0, "id")) }
        removeUnusedMealImages(from: oldFoods)
        return ["status": "ok", "date": date, "saved": saved.count, "replaced": oldFoods.count, "foods": saved, "already_logged": false, "daily_summary": dailySummary(date)]
    }

    private func normalizedFood(_ raw: Object) throws -> Object {
        let name = string(raw, "name", fallback: string(raw, "food_name")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw invalid("食物名称不能为空") }
        var food: Object = ["id": string(raw, "id", fallback: uuid()), "name": name]
        for key in Self.nutritionKeys { food[key] = try bounded(raw, key, 0...1000000, fallback: 0) }
        for key in ["serving_size", "processing_level", "quantity_unit", "quantity_description", "barcode", "nutrition_source"] {
            food[key] = string(raw, key)
        }
        if string(food, "serving_size").isEmpty { food["serving_size"] = "100g" }
        if string(food, "processing_level").isEmpty { food["processing_level"] = "whole" }
        food["grams_per_unit"] = try bounded(raw, "grams_per_unit", 0...100000, fallback: 100)
        food["consumed_ratio"] = try bounded(raw, "consumed_ratio", 0...20, fallback: 1)
        if raw["quantity_count"] != nil { food["quantity_count"] = try bounded(raw, "quantity_count", 0...100000) }
        return food
    }

    private func adjustPortion(_ id: Int, _ body: Object) throws -> Object {
        var foods = rows("foods")
        guard let index = foods.firstIndex(where: { int($0, "id") == id }) else { throw missing("这条食物记录已不存在") }
        let ratio = try bounded(body, "consumed_ratio", 0...20)
        let date = try day(body["date"] as? String, fallback: string(foods[index], "date"))
        if ratio == 0 {
            let removed = foods[index]
            foods.remove(at: index); state!["foods"] = foods
            removeUnusedMealImages(from: [removed])
            return ["status": "ok", "date": date, "adjusted": 0, "removed": 1, "daily_summary": dailySummary(date)]
        }
        let base = foods[index]["_baseline"] as? Object ?? foods[index]
        for key in Self.nutritionKeys { foods[index][key] = number(base, key) * ratio }
        foods[index]["consumed_ratio"] = ratio
        foods[index]["leftover_calories"] = max(0, number(base, "calories") * (1 - ratio))
        state!["foods"] = foods
        return ["status": "ok", "date": date, "adjusted": 1, "food": publicFood(foods[index]), "daily_summary": dailySummary(date)]
    }

    private func moveFood(_ id: Int, _ body: Object) throws -> Object {
        var foods = rows("foods")
        guard let index = foods.firstIndex(where: { int($0, "id") == id }) else { throw missing("这条食物记录已不存在") }
        let category = string(body, "meal_category").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty else { throw invalid("请选择餐次") }
        let date = try day(body["date"] as? String, fallback: string(foods[index], "date"))
        foods[index]["meal_category"] = category; foods[index]["date"] = date
        state!["foods"] = foods
        return ["status": "ok", "date": date, "moved": 1, "food": publicFood(foods[index]), "daily_summary": dailySummary(date)]
    }

    private func dailySummary(_ date: String) -> Object {
        let foods = rowsOnDay("foods", date)
        let drinks = rowsOnDay("hydration", date)
        let hydration = hydrationSummary(date)
        let macros = object("macro_goals")
        var summary: Object = ["date": date]
        for key in Self.nutritionKeys { summary[key] = sum(foods, key) }
        let caloriesBurned = sum(rowsOnDay("exercises", date), "calories_burned") + sum(rowsOnDay("energy", date), "value")
        summary["calories_consumed"] = sum(foods, "calories") + sum(drinks, "calories")
        summary["calories_burned"] = caloriesBurned
        let plan = state!["goal_plan"] as? Object ?? [:]
        summary["calories_goal"] = number(macros, "daily_calories", fallback: number(plan, "daily_calorie_target", fallback: 2000)) + caloriesBurned
        for (key, macro) in [("protein", "protein_g"), ("carbs", "carbs_g"), ("fat", "fat_g")] {
            summary[key] = sum(foods, key) + sum(drinks, macro)
            summary[key + "_goal"] = number(macros, macro)
        }
        summary["sugar"] = sum(foods, "sugar") + sum(drinks, "sugar_g")
        summary["water_ml"] = number(hydration, "hydration_effective_ml")
        summary["water_goal_ml"] = number(macros, "water_ml", fallback: 2000)
        for key in ["hydration_ml", "hydration_effective_ml", "hydration_goal_ml", "caffeine_mg", "alcohol_g", "drink_count"] { summary[key] = hydration[key] }
        summary["drink_sugar_g"] = number(hydration, "sugar_g"); summary["drink_calories"] = number(hydration, "calories")
        summary["steps"] = Int(sum(rowsOnDay("steps", date), "steps"))
        summary["meals_count"] = Set(foods.map { string($0, "upload_group_id") }).count
        summary["streak_days"] = streak()["streak_days"]
        if let weight = chronologicalWeights(rows("weights").filter { string($0, "date") <= date }).last {
            summary["weight_kg"] = number(weight, "weight_kg")
        }
        return summary
    }

    private func streak() -> Object {
        let dates = Set(rows("foods").map { string($0, "date") })
        var current = 0
        let today = todayString()
        var cursor = dates.contains(today) ? today : offsetDay(today, -1)
        while dates.contains(cursor) { current += 1; cursor = offsetDay(cursor, -1) }
        var longest = 0, run = 0, previous = ""
        for date in dates.sorted() {
            run = previous.isEmpty || offsetDay(previous, 1) != date ? 1 : run + 1
            longest = max(longest, run); previous = date
        }
        return ["streak_days": current, "longest_streak": longest, "total_days_logged": dates.count]
    }

    private func frequentFoods(_ query: [String: String]) -> Object {
        let category = query["meal_category"] ?? ""
        let foods = rows("foods").filter { category.isEmpty || string($0, "meal_category") == category }
        let grouped = Dictionary(grouping: foods) { string($0, "food_name") }
        let result = grouped.values.compactMap { entries -> Object? in
            guard let last = entries.last else { return nil }
            var row = publicFood(last)
            row["id"] = "frequent_" + string(last, "food_name")
            row["log_count"] = entries.count; row["last_logged"] = string(last, "logged_at")
            return row
        }.sorted { int($0, "log_count") > int($1, "log_count") }
        return ["foods": Array(result.prefix(limitValue(query, fallback: 12)))]
    }

    private func hydrationSettings() -> Object { ["hydration_goal_ml": number(object("macro_goals"), "water_ml", fallback: 2000), "water_ml": number(object("macro_goals"), "water_ml", fallback: 2000)] }
    private func drinkPresets() -> [Object] {
        let custom = state!["drink_presets"] as? [Object] ?? []
        let customIDs = Set(custom.map { string($0, "id") })
        return Self.drinkSeeds.filter { !customIDs.contains(string($0, "id")) } + custom
    }
    private func saveDrinkPreset(_ body: Object) throws -> Object {
        let name = string(body, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw invalid("请填写饮品名称") }
        let id = string(body, "id", fallback: uuid())
        var row: Object = ["id": id, "drink_type": string(body, "drink_type", fallback: id), "name": name, "custom": true, "default_amount_ml": try bounded(body, "default_amount_ml", 1...20000, fallback: 250), "hydration_factor": try bounded(body, "hydration_factor", 0...1, fallback: 1)]
        for key in ["caffeine_mg", "alcohol_g", "sugar_g", "calories"] { row[key] = try bounded(body, key, 0...100000, fallback: 0) }
        var presets = state!["drink_presets"] as? [Object] ?? []
        presets.removeAll { string($0, "id") == id }; presets.append(row); state!["drink_presets"] = presets
        return row
    }
    private func addHydration(_ body: Object, overrideNutrition: Bool = false) throws -> Object {
        let type = string(body, "drink_type", fallback: "water")
        guard let preset = drinkPresets().first(where: { string($0, "drink_type") == type }) else { throw invalid("请先保存这个饮品的成分设置") }
        let amount = try bounded(body, "amount_ml", 1...20000)
        let scale = amount / number(preset, "default_amount_ml", fallback: 250)
        var row: Object = ["id": uuid(), "drink_type": type, "amount_ml": amount, "hydration_factor": number(preset, "hydration_factor"), "effective_ml": amount * number(preset, "hydration_factor"), "date": try day(body["date"] as? String), "source": string(body, "source", fallback: "manual"), "note": string(body, "note"), "logged_at": string(body, "logged_at", fallback: timestamp()), "external_id": string(body, "external_id")]
        for key in ["caffeine_mg", "alcohol_g", "sugar_g", "calories", "protein_g", "carbs_g", "fat_g"] {
            row[key] = overrideNutrition && body[key] != nil ? try bounded(body, key, 0...100000) : number(preset, key) * scale
        }
        append("hydration", row); return row
    }
    private func applyVoiceLog(_ body: Object) throws -> Object {
        let foods = body["foods"] as? [Object] ?? []
        let drinks = body["hydration"] as? [Object] ?? []
        guard !foods.isEmpty || !drinks.isEmpty else { throw invalid("请添加食物或饮品后再保存") }
        let date = try day(body["date"] as? String)
        if !foods.isEmpty { _ = try logFoods(["date": date, "foods": foods, "meal_category": string(body, "meal_category", fallback: "snack"), "group_title": "语音记录"]) }
        for raw in drinks {
            var drink = raw; drink["date"] = date; drink["source"] = "voice"
            _ = try addHydration(drink, overrideNutrition: true)
        }
        return ["status": "ok", "date": date]
    }
    private func hydrationSummary(_ date: String) -> Object {
        let drinks = rowsOnDay("hydration", date)
        var summary: Object = ["date": date, "hydration_ml": sum(drinks, "amount_ml"), "hydration_effective_ml": sum(drinks, "effective_ml"), "hydration_goal_ml": number(object("macro_goals"), "water_ml", fallback: 2000), "drink_count": drinks.count]
        for key in ["caffeine_mg", "alcohol_g", "sugar_g", "calories"] { summary[key] = sum(drinks, key) }
        return summary
    }

    private func saveGoalPlan(_ body: Object) throws -> Object {
        let weight = try bounded(body, "current_weight_kg", 25...350)
        let goal = try bounded(body, "goal_weight_kg", 25...350)
        let height = try bounded(body, "height_cm", 100...250)
        let age = try bounded(body, "age", 13...120)
        let gender = string(body, "gender")
        guard ["male", "female"].contains(gender) else { throw invalid("请选择有效的性别参数") }
        let activity = string(body, "activity", fallback: "moderate")
        let multipliers = ["sedentary": 1.2, "light": 1.375, "moderate": 1.55, "active": 1.725, "very_active": 1.9]
        let bmr = 10 * weight + 6.25 * height - 5 * age + (gender == "male" ? 5 : -161)
        let tdee = bmr * (multipliers[activity] ?? 1.55)
        let deficit = try bounded(body, "deficit_pct", -20...30, fallback: 20)
        let calorieDeficit = (tdee * deficit / 100).rounded()
        let target = min(6000, max(1000, tdee * (1 - deficit / 100))).rounded()
        let delta = weight - goal
        var plan: Object = ["bmr": bmr.rounded(), "tdee": tdee.rounded(), "daily_calorie_target": target, "current_weight_kg": weight, "goal_weight_kg": goal, "weight_delta_kg": abs(delta), "deficit_kcal_per_day": calorieDeficit, "activity_level": activity, "weekly_loss_kg": (calorieDeficit * 7 / 7700 * 100).rounded() / 100, "direction": delta > 0 ? "lose" : (delta < 0 ? "gain" : "maintain")]
        if delta == 0 { plan["estimated_days"] = 0; plan["goal_date"] = todayString() }
        else if delta * calorieDeficit > 0 {
            let days = Int(ceil(abs(delta * 7700 / calorieDeficit)))
            plan["estimated_days"] = days; plan["goal_date"] = offsetDay(todayString(), days)
        }
        state!["goal_plan"] = plan
        var macros = object("macro_goals"); macros["daily_calories"] = target; state!["macro_goals"] = macros
        return plan
    }
    private func saveMacroGoals(_ body: Object) throws -> Object {
        var macros = object("macro_goals")
        for key in ["daily_calories", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_mg", "water_ml"] where body[key] != nil {
            macros[key] = try bounded(body, key, 0...100000)
        }
        if let shares = body["meal_shares"] as? [String: Double] {
            guard shares.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw invalid("餐次比例无效") }
            macros["meal_shares"] = shares
        }
        state!["macro_goals"] = macros
        return macros
    }

    private func addExercise(_ body: Object) throws -> Object {
        let name = string(body, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw invalid("请填写运动名称") }
        let duration = Int(try bounded(body, "duration_minutes", 1...1440))
        let estimate = try estimateExercise(body)
        let calories = body["calories_burned"] == nil ? number(estimate, "calories_burned") : try bounded(body, "calories_burned", 0...20000)
        let row: Object = ["id": uuid(), "name": name, "duration_minutes": duration, "calories_burned": calories, "date": try day(body["date"] as? String), "intensity": string(body, "intensity", fallback: "moderate"), "notes": string(body, "notes")]
        append("exercises", row); return row
    }
    private func estimateExercise(_ body: Object) throws -> Object {
        let duration = try bounded(body, "duration_minutes", 1...1440)
        let identity = string(body, "exercise_id", fallback: string(body, "name"))
        let exercise = Self.exerciseSeeds.first { string($0, "id") == identity || string($0, "name") == identity }
        let intensity = string(body, "intensity", fallback: "moderate")
        let modifier = intensity == "light" || intensity == "low" ? 0.8 : (intensity == "high" || intensity == "vigorous" ? 1.25 : 1)
        let met = number(exercise ?? [:], "met", fallback: 4) * modifier
        let weight = chronologicalWeights(rows("weights")).last.map { number($0, "weight_kg", fallback: 70) } ?? number(state!["goal_plan"] as? Object ?? [:], "current_weight_kg", fallback: 70)
        return ["calories_burned": (met * 3.5 * weight / 200 * duration).rounded(), "duration_minutes": Int(duration), "intensity": intensity, "estimated": true]
    }
    private func addSleep(_ body: Object) throws -> Object {
        let row: Object = ["id": uuid(), "date": try day(body["date"] as? String), "duration_hours": try bounded(body, "duration_hours", 0...24), "quality": Int(try bounded(body, "quality", 1...5, fallback: 3)), "start_at": string(body, "start_at"), "end_at": string(body, "end_at"), "source": string(body, "source", fallback: "manual"), "note": string(body, "note"), "external_id": string(body, "external_id"), "created_at": timestamp()]
        append("sleep", row); return row
    }
    private func sleepSummary(_ date: String) -> Object {
        let logs = rowsOnDay("sleep", date)
        let hours = min(24, sum(logs, "duration_hours"))
        let quality = logs.isEmpty ? 0 : Int((sum(logs, "quality") / Double(logs.count)).rounded())
        return ["date": date, "duration_hours": hours, "goal_hours": 7.5, "quality": quality, "logs_count": logs.count, "status": hours >= 7 ? "green" : "red", "message": logs.isEmpty ? "还没有记录睡眠" : String(format: "已记录 %.1f 小时睡眠", hours)]
    }
    private func diaryNote(_ date: String) -> Object { object("diary_notes")[date] as? Object ?? ["date": date, "note": ""] }
    private func normalizeReminder(_ body: Object) throws -> Object {
        let time = string(body, "time")
        let pieces = time.split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]), (0...23).contains(hour), (0...59).contains(minute) else { throw invalid("提醒时间无效") }
        var row: Object = ["id": string(body, "id", fallback: uuid()), "time": time, "enabled": body["enabled"] as? Bool ?? true, "interval_minutes": Int(try bounded(body, "interval_minutes", 1...1440, fallback: 60))]
        for key in ["meal_type", "category", "title", "target_id", "days_of_week"] { row[key] = string(body, key) }
        return row
    }

    private func importHealth(_ body: Object) throws -> Object {
        guard let records = body["records"] as? [Object] else { throw invalid("健康记录格式无效") }
        var imported: [Object] = [], skipped: [Object] = []
        for record in records {
            let source = string(record, "source", fallback: string(body, "source", fallback: "healthkit"))
            let externalID = string(record, "external_id")
            let type = string(record, "record_type").lowercased()
            guard !externalID.isEmpty else { skipped.append(["external_id": externalID, "reason": "missing_external_id"]); continue }
            let beforeRecord = state!
            do {
                let date = try day(record["date"] as? String)
                let value = try bounded(record, "value", 0...1000000)
                let rawUnit = string(record, "unit").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // HealthKitSyncService uses localized labels in its export payloads.
                let unit = ["步": "count", "公斤": "kg", "毫升": "ml", "千卡": "kcal"][rawUnit] ?? rawUnit
                let aggregate = (record["metadata"] as? Object)?["aggregation"] as? String == "day"
                if let existing = rows("health_imports").first(where: { string($0, "source") == source && string($0, "external_id") == externalID }) {
                    let canUpdate = aggregate && existing["daily_aggregate"] as? Bool == true && string(existing, "record_type") == type
                    let changed = number(existing, "original_value", fallback: -1) != value || string(existing, "original_unit") != unit || string(existing, "date") != date
                    guard canUpdate && changed else { skipped.append(["external_id": externalID, "reason": "duplicate"]); continue }
                    let collection = string(existing, "collection"), recordID = string(existing, "record_id")
                    state![collection] = rows(collection).filter { string($0, "id") != recordID }
                    state!["health_imports"] = rows("health_imports").filter { !(string($0, "source") == source && string($0, "external_id") == externalID) }
                }
                let target: String
                let created: Object
                switch type {
                case "steps", "step_count":
                    guard ["count", "steps", ""].contains(unit) else { throw invalid("步数单位无效") }
                    target = "steps"
                    created = ["id": uuid(), "date": date, "steps": Int(value), "source": source, "external_id": externalID]
                    append(target, created)
                case "water", "hydration", "dietary_water":
                    guard ["ml", "l", "liter", "litre", ""].contains(unit) else { throw invalid("饮水单位无效") }
                    target = "hydration"
                    let ml = ["l", "liter", "litre"].contains(unit) ? value * 1000 : value
                    created = try addHydration(["date": date, "drink_type": "water", "amount_ml": ml, "source": source, "external_id": externalID, "logged_at": string(record, "logged_at", fallback: timestamp()), "note": "来自苹果健康"])
                case "weight", "body_mass":
                    guard ["kg", "lb", "lbs", "pound", "pounds", ""].contains(unit) else { throw invalid("体重单位无效") }
                    target = "weights"
                    let kg = ["lb", "lbs", "pound", "pounds"].contains(unit) ? value * 0.45359237 : value
                    guard kg > 0, kg <= 600 else { throw invalid("体重数值无效") }
                    created = ["id": uuid(), "date": date, "weight_kg": kg, "source": source, "external_id": externalID, "logged_at": string(record, "logged_at", fallback: timestamp())]
                    append(target, created)
                case "sleep", "sleep_duration", "sleep_analysis", "asleep":
                    guard ["h", "hr", "hour", "hours", "min", "minute", "minutes", "sec", "second", "seconds", ""].contains(unit) else { throw invalid("睡眠单位无效") }
                    target = "sleep"
                    let hours: Double
                    if ["min", "minute", "minutes"].contains(unit) { hours = value / 60 }
                    else if ["sec", "second", "seconds"].contains(unit) { hours = value / 3600 }
                    else { hours = value }
                    created = try addSleep(["date": date, "duration_hours": hours, "source": source, "external_id": externalID, "start_at": string(record, "start_at"), "end_at": string(record, "logged_at"), "quality": number(record, "quality", fallback: 3), "note": "来自苹果健康"])
                case "active_energy", "active_energy_burned":
                    guard ["kcal", "kj", "cal", ""].contains(unit) else { throw invalid("能量单位无效") }
                    target = "energy"
                    let kcal = unit == "kj" ? value / 4.184 : (unit == "cal" ? value / 1000 : value)
                    created = ["id": uuid(), "date": date, "value": kcal, "source": source, "external_id": externalID]
                    append(target, created)
                default:
                    skipped.append(["external_id": externalID, "reason": "unsupported_record_type"]); continue
                }
                append("health_imports", ["source": source, "external_id": externalID, "record_type": type, "date": date, "collection": target, "record_id": string(created, "id"), "daily_aggregate": aggregate, "original_value": value, "original_unit": unit])
                imported.append(["external_id": externalID, "record_type": type])
            } catch {
                state = beforeRecord
                skipped.append(["external_id": externalID, "reason": "invalid_record"])
            }
        }
        return ["status": "ok", "imported": imported, "skipped": skipped, "imported_count": imported.count, "skipped_count": skipped.count]
    }

    private func savedList(_ path: String, _ query: [String: String]) -> Object {
        let meals = path == "/saved-meals"
        let collection = meals ? "saved_meals" : "saved_foods"
        let search = query["query"] ?? ""
        let category = query["meal_category"] ?? ""
        let favorite = query["favorite"] == "true" || query["favorite"] == "1"
        var values = rows(collection).filter { row in
            let label = string(row, meals ? "title" : "name")
            return (search.isEmpty || label.localizedCaseInsensitiveContains(search)) && (category.isEmpty || string(row, "meal_category") == category) && (!favorite || row["favorite"] as? Bool == true)
        }
        switch query["sort"] ?? "created" {
        case "name", "title": values.sort { string($0, meals ? "title" : "name") < string($1, meals ? "title" : "name") }
        case "frequent", "most_used", "logged_count": values.sort { int($0, "logged_count") > int($1, "logged_count") }
        case "recent", "last_logged": values.sort { string($0, "logged_at") > string($1, "logged_at") }
        default: values.reverse()
        }
        let offset = max(0, Int(query["offset"] ?? "") ?? 0)
        return [meals ? "meals" : "foods": Array(values.dropFirst(offset).prefix(limitValue(query, fallback: meals ? 20 : 50)))]
    }

    private func saveTemplate(_ path: String, _ body: Object, existing: Object? = nil) throws -> Object {
        let meals = path == "/saved-meals"
        let collection = meals ? "saved_meals" : "saved_foods"
        var row = existing ?? ["id": uuid(), "created_at": timestamp(), "logged_count": 0, "favorite": false]
        row["source"] = string(body, "source", fallback: "ios")
        if meals {
            let title = string(body, "title").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let raw = body["foods"] as? [Object], !raw.isEmpty else { throw invalid("请填写餐品名称和食物") }
            row["title"] = title; row["foods"] = try raw.map(normalizedFood)
            row["meal_category"] = string(body, "meal_category"); row["image_url"] = safeImageURL(string(body, "image_url"))
            if let note = body["note"] as? String { row["note"] = note }
            if let instructions = body["instructions"] as? [String] { row["instructions"] = instructions }
            if let favorite = body["favorite"] as? Bool { row["favorite"] = favorite }
        } else {
            guard let raw = body["food"] as? Object else { throw invalid("请添加食物") }
            let food = try normalizedFood(raw)
            row["food"] = food; row["name"] = string(food, "name")
        }
        var saved = rows(collection)
        if let index = saved.firstIndex(where: { string($0, "id") == string(row, "id") }) { saved[index] = row } else { saved.append(row) }
        state![collection] = saved
        return ["status": "ok", meals ? "meal" : "food": row]
    }

    private func templateAction(_ root: String, _ parts: [String], _ method: String, _ body: Object) throws -> Object {
        let meals = root == "saved-meals"
        let collection = meals ? "saved_meals" : "saved_foods"
        let key = meals ? "meal_id" : "food_id"
        let id = parts[1].removingPercentEncoding ?? parts[1]
        var saved = rows(collection)
        guard let index = saved.firstIndex(where: { string($0, "id") == id }) else { throw missing("这条收藏已不存在") }
        if parts.count == 2 {
            if method == "DELETE" { saved.remove(at: index); state![collection] = saved; return ["status": "ok", "deleted": true, key: id] }
            if method == "PUT" { return try saveTemplate("/" + root, body, existing: saved[index]) }
        }
        if method == "POST", parts.count == 3 {
            if parts[2] == "favorite", meals {
                saved[index]["favorite"] = !(saved[index]["favorite"] as? Bool ?? false)
                state![collection] = saved
                return ["status": "ok", "meal": saved[index]]
            }
            if parts[2] == "log" {
                let factor = try bounded(body, "portion_multiplier", 0.01...20, fallback: 1)
                let rawFoods = meals ? (saved[index]["foods"] as? [Object] ?? []) : [saved[index]["food"] as? Object ?? [:]]
                let foods = rawFoods.map { raw -> Object in
                    var food = raw
                    for key in Self.nutritionKeys { food[key] = number(raw, key) * factor }
                    let gramsPerUnit = number(raw, "grams_per_unit", fallback: 100)
                    let count = number(raw, "quantity_count", fallback: 1) * factor
                    let rawUnit = string(raw, "quantity_unit")
                    let unit = rawUnit.isEmpty ? "份" : rawUnit
                    let quantity = portionNumber(count) + unit
                    let label = ["克", "g"].contains(unit) || gramsPerUnit <= 0 ? quantity : quantity + "（" + portionNumber(count * gramsPerUnit) + "g）"
                    food["grams_per_unit"] = gramsPerUnit
                    food["quantity_count"] = count
                    food["quantity_unit"] = unit
                    food["quantity_description"] = label
                    food["serving_size"] = label
                    return food
                }
                var payload: Object = ["date": try day(body["date"] as? String), "foods": foods, "meal_category": string(body, "meal_category", fallback: string(saved[index], "meal_category", fallback: "snack")), "group_title": string(saved[index], meals ? "title" : "name"), "image_url": string(saved[index], "image_url")]
                if string(payload, "meal_category").isEmpty { payload["meal_category"] = "snack" }
                var result = try logFoods(payload)
                saved[index]["logged_count"] = int(saved[index], "logged_count") + 1
                saved[index]["logged_at"] = timestamp(); state![collection] = saved
                result[key] = id; return result
            }
        }
        throw RouteError(status: 501, message: "此收藏操作尚未提供本机实现")
    }

    private func saveFastingPreferences(_ body: Object) throws -> Object {
        var prefs = object("fasting_preferences")
        for key in ["enabled", "reminders_enabled"] where body[key] is Bool { prefs[key] = body[key] }
        for key in ["method", "eating_window_start", "timezone"] where body[key] is String { prefs[key] = body[key] }
        if body["fasting_hours"] != nil { prefs["fasting_hours"] = try bounded(body, "fasting_hours", 1...72) }
        if body["eating_hours"] != nil { prefs["eating_hours"] = try bounded(body, "eating_hours", 0...24) }
        state!["fasting_preferences"] = prefs; return prefs
    }
    private func startFasting(_ body: Object) throws -> Object {
        guard !rows("fasting_sessions").contains(where: { string($0, "status") == "active" }) else { throw RouteError(status: 409, message: "已有进行中的计时，请先结束或取消") }
        let hours = try bounded(body, "fasting_hours", 1...72, fallback: number(object("fasting_preferences"), "fasting_hours", fallback: 16))
        let now = Date()
        let session: Object = ["id": uuid(), "method": string(body, "method", fallback: "16:8"), "fasting_hours": hours, "start_at": iso(now), "target_end_at": iso(now.addingTimeInterval(hours * 3600)), "status": "active", "notes": ""]
        append("fasting_sessions", session)
        var prefs = object("fasting_preferences"); prefs["enabled"] = true; state!["fasting_preferences"] = prefs
        return fastingStatus()
    }
    private func finishFasting(_ body: Object, cancelled: Bool) throws -> Object {
        var sessions = rows("fasting_sessions")
        guard let index = sessions.firstIndex(where: { string($0, "status") == "active" }) else { throw RouteError(status: 409, message: "当前没有进行中的计时") }
        sessions[index]["ended_at"] = timestamp(); sessions[index]["status"] = cancelled ? "cancelled" : "ended"; sessions[index]["notes"] = string(body, "notes")
        state!["fasting_sessions"] = sessions; return fastingStatus()
    }
    private func manualFasting(_ body: Object) throws -> Object {
        guard let start = parseISO(string(body, "start_at")), let end = parseISO(string(body, "ended_at")), end > start, end <= Date().addingTimeInterval(60), end.timeIntervalSince(start) <= 7 * 86400 else { throw invalid("请检查开始和结束时间") }
        let hours = try bounded(body, "fasting_hours", 1...72, fallback: 16)
        append("fasting_sessions", ["id": uuid(), "method": string(body, "method", fallback: "16:8"), "fasting_hours": hours, "start_at": iso(start), "target_end_at": iso(start.addingTimeInterval(hours * 3600)), "ended_at": iso(end), "status": "ended", "notes": string(body, "notes")])
        return fastingHistory(days: 3650)
    }
    private func fastingSession(_ raw: Object) -> Object {
        var session = raw
        let start = parseISO(string(raw, "start_at")) ?? Date()
        let end = parseISO(string(raw, "ended_at")) ?? Date()
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        let target = Int(number(raw, "fasting_hours", fallback: 16) * 3600)
        session["elapsed_seconds"] = elapsed; session["target_seconds"] = target
        session["remaining_seconds"] = max(0, target - elapsed)
        session["progress_pct"] = min(100, Double(elapsed) / Double(max(1, target)) * 100)
        session["completed"] = string(raw, "status") != "cancelled" && elapsed >= target
        return session
    }
    private func fastingStatus() -> Object {
        let sessions = rows("fasting_sessions")
        let active = sessions.first { string($0, "status") == "active" }
        var result: Object = ["preferences": object("fasting_preferences"), "enabled": object("fasting_preferences")["enabled"] as? Bool ?? false, "is_fasting": active != nil, "stage_plan": [Object](), "recent_sessions": Array(sessions.reversed().prefix(10)).map(fastingSession)]
        if let active { result["active_session"] = fastingSession(active) }
        return result
    }
    private func fastingHistory(days: Int) -> Object {
        let since = offsetDay(todayString(), -days + 1)
        let sessions = rows("fasting_sessions").filter { raw in
            let date = parseISO(string(raw, "ended_at", fallback: string(raw, "start_at"))).map(dayString) ?? ""
            return date >= since
        }.reversed().map(fastingSession)
        let finished = sessions.filter { string($0, "status") == "ended" }
        let completed = finished.filter { $0["completed"] as? Bool == true }
        let dates = Set(completed.compactMap { parseISO(string($0, "ended_at")).map(dayString) })
        var current = 0, longest = 0, run = 0, previous = ""
        var cursor = dates.contains(todayString()) ? todayString() : offsetDay(todayString(), -1)
        while dates.contains(cursor) { current += 1; cursor = offsetDay(cursor, -1) }
        for date in dates.sorted() { run = previous.isEmpty || offsetDay(previous, 1) != date ? 1 : run + 1; longest = max(longest, run); previous = date }
        let week = dates.filter { $0 >= offsetDay(todayString(), -6) }.sorted()
        let summary: Object = ["total_sessions": finished.count, "completed_sessions": completed.count, "completion_rate": finished.isEmpty ? 0 : Int(Double(completed.count) / Double(finished.count) * 100), "average_hours": finished.isEmpty ? 0 : sum(finished, "elapsed_seconds") / Double(finished.count) / 3600, "current_streak": current, "longest_streak": longest, "week_completed_days": week.count, "week_completed_dates": week]
        return ["sessions": sessions, "summary": summary]
    }

    private func object(_ key: String) -> Object { state?[key] as? Object ?? [:] }
    private func rows(_ key: String) -> [Object] { state?[key] as? [Object] ?? [] }
    private func append(_ key: String, _ row: Object) { var values = rows(key); values.append(row); state![key] = values }
    private func rowsOnDay(_ key: String, _ date: String) -> [Object] { rows(key).filter { string($0, "date") == date } }
    private func recentRows(_ key: String, date: String, days: Int) -> [Object] {
        let since = offsetDay(date, -days + 1)
        return rows(key).filter { let value = string($0, "date"); return value >= since && value <= date }
    }
    private func chronologicalWeights(_ values: [Object]) -> [Object] {
        let dated = values.enumerated().map { index, row in
            (index: index, row: row, day: string(row, "date"), time: parseISO(string(row, "logged_at"))?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970)
        }
        return dated.sorted { left, right in
            if left.day != right.day { return left.day < right.day }
            if left.time != right.time { return left.time < right.time }
            return left.index < right.index
        }.map { $0.row }
    }
    private func portionNumber(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
    private func publicFood(_ row: Object) -> Object {
        var result = row
        if let key = result.removeValue(forKey: "image_ref") as? String { result["image_url"] = object("meal_images")[key] as? String ?? "" }
        result.removeValue(forKey: "_baseline")
        return result
    }
    private func storeMealImage(_ imageURL: String, preferredKey: String = "") -> String {
        var images = object("meal_images")
        let key: String
        if !preferredKey.isEmpty, images[preferredKey] == nil || images[preferredKey] as? String == imageURL { key = preferredKey }
        else if let existing = images.first(where: { $0.value as? String == imageURL }) { return existing.key }
        else { key = "image_" + sha256(Data(imageURL.utf8)) }
        images[key] = imageURL; state!["meal_images"] = images
        return key
    }
    private func compactCachedResponse(_ value: Any) -> Any {
        if let dictionary = value as? Object {
            var result: Object = [:]
            for (key, child) in dictionary {
                if key == "image_url", let url = child as? String, !url.isEmpty {
                    let reference = storeMealImage(url, preferredKey: string(dictionary, "upload_group_id"))
                    result[key] = ["__local_image_ref": reference]
                } else { result[key] = compactCachedResponse(child) }
            }
            return result
        }
        if let array = value as? [Any] { return array.map(compactCachedResponse) }
        return value
    }
    private func restoredCachedResponse(_ value: Any) -> Any {
        if let dictionary = value as? Object {
            if dictionary.count == 1, let reference = dictionary["__local_image_ref"] as? String { return object("meal_images")[reference] as? String ?? "" }
            return dictionary.mapValues(restoredCachedResponse)
        }
        if let array = value as? [Any] { return array.map(restoredCachedResponse) }
        return value
    }
    /// Read schema-1 documents in either form; the next successful mutation saves
    /// inline photos and old canonical retry payloads in the compact representation.
    private func migrateInlinePhotosAndRetryLedger() {
        if state!["meal_images"] == nil { state!["meal_images"] = Object() }
        state!["foods"] = rows("foods").map { original -> Object in
            var row = original
            if let url = row.removeValue(forKey: "image_url") as? String, !url.isEmpty {
                row["image_ref"] = storeMealImage(url, preferredKey: string(row, "upload_group_id"))
            }
            return row
        }
        var ledger = object("idempotency")
        for key in Array(ledger.keys) {
            guard var entry = ledger[key] as? Object else { continue }
            let fingerprint = string(entry, "fingerprint")
            if fingerprint.hasPrefix("{") { entry["fingerprint"] = sha256(Data(fingerprint.utf8)) }
            if let response = entry["response"] { entry["response"] = compactCachedResponse(response) }
            ledger[key] = entry
        }
        state!["idempotency"] = ledger
    }
    private func removeUnusedMealImages(from removed: [Object]) {
        let live = Set(rows("foods").compactMap { $0["image_ref"] as? String })
        let unused = Set(removed.compactMap { $0["image_ref"] as? String }).subtracting(live)
        guard !unused.isEmpty else { return }
        var images = object("meal_images")
        for key in unused { images.removeValue(forKey: key) }
        state!["meal_images"] = images
    }
    private func string(_ object: Object, _ key: String, fallback: String = "") -> String { object[key] as? String ?? fallback }
    private func number(_ object: Object, _ key: String, fallback: Double = 0) -> Double { (object[key] as? NSNumber)?.doubleValue ?? fallback }
    private func int(_ object: Object, _ key: String, fallback: Int = 0) -> Int { (object[key] as? NSNumber)?.intValue ?? fallback }
    private func sum(_ objects: [Object], _ key: String) -> Double { objects.reduce(0) { $0 + number($1, key) } }
    private func bounded(_ object: Object, _ key: String, _ range: ClosedRange<Double>, fallback: Double? = nil) throws -> Double {
        guard let value = (object[key] as? NSNumber)?.doubleValue ?? fallback, value.isFinite, range.contains(value) else { throw invalid("\(key) 的数值无效") }
        return value
    }
    private func limitValue(_ query: [String: String], fallback: Int = 50) -> Int { min(1000, max(1, Int(query["limit"] ?? "") ?? fallback)) }
    private func queryDays(_ query: [String: String], fallback: Int = 1) -> Int { min(36500, max(1, Int(query["days"] ?? "") ?? fallback)) }
    private func invalid(_ message: String) -> RouteError { RouteError(status: 400, message: message) }
    private func missing(_ message: String) -> RouteError { RouteError(status: 404, message: message) }
    private func uuid() -> String { UUID().uuidString.lowercased() }
    private func day(_ raw: String?, fallback: String? = nil) throws -> String {
        let value = (raw?.isEmpty == false ? raw : fallback) ?? todayString()
        let formatter = dateFormatter()
        guard value.count == 10, let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else { throw invalid("日期格式应为 YYYY-MM-DD") }
        return value
    }
    private func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter
    }
    private func dayString(_ date: Date) -> String { dateFormatter().string(from: date) }
    private func todayString() -> String { dayString(Date()) }
    private func offsetDay(_ day: String, _ count: Int) -> String {
        let formatter = dateFormatter()
        guard let date = formatter.date(from: day), let result = Calendar(identifier: .gregorian).date(byAdding: .day, value: count, to: date) else { return day }
        return formatter.string(from: result)
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func timestamp() -> String { iso(Date()) }
    private func parseISO(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    private func validatedImage(_ value: String) throws -> String {
        guard !value.isEmpty else { return "" }
        let raw = value.hasPrefix("data:") ? String(value.split(separator: ",", maxSplits: 1).last ?? "") : value
        guard let decoded = Data(base64Encoded: raw), !decoded.isEmpty else { throw invalid("照片内容无效，请重新选择") }
        return decoded.base64EncodedString()
    }
    private func safeImageURL(_ value: String) -> String {
        guard value.hasPrefix("data:image/") || value.hasPrefix("file://") else { return "" }
        return value
    }
    /// Persist only the SHA-256 digest; request photos and credentials are never
    /// duplicated in the retry ledger.
    private func requestFingerprint(_ body: Object) throws -> String {
        func clean(_ value: Any) -> Any {
            if let object = value as? Object {
                return object.reduce(into: Object()) { result, pair in
                    let normalized = pair.key.lowercased().filter { $0.isLetter || $0.isNumber }
                    if ["requestid", "key", "apikey", "authorization", "token", "accesstoken", "refreshtoken", "password", "secret"].contains(normalized) { return }
                    result[pair.key] = clean(pair.value)
                }
            }
            if let array = value as? [Any] { return array.map(clean) }
            return value
        }
        return sha256(try json(clean(body)))
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    private func httpResponse(url: URL, status: Int) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json; charset=utf-8", "X-LightCal-Storage": "device"])! }
    private func response(_ value: Any, url: URL, status: Int = 200) throws -> (Data, URLResponse) { (try json(value), httpResponse(url: url, status: status)) }

    /// Small built-in reference portions for manual offline search; user logs expand this list.
    private static var foodSeeds: [Object] {
        [
            ["id": "seed_rice", "name": "米饭", "aliases": "rice", "calories": 116.0, "protein": 2.6, "carbs": 25.9, "fat": 0.3, "fiber": 0.3, "serving_size": "100g", "grams_per_unit": 100.0, "nutrition_source": "本机参考食物（估算）"],
            ["id": "seed_egg", "name": "水煮鸡蛋", "aliases": "egg", "calories": 78.0, "protein": 6.3, "carbs": 0.6, "fat": 5.3, "serving_size": "1个（50g）", "grams_per_unit": 50.0, "nutrition_source": "本机参考食物（估算）"],
            ["id": "seed_chicken", "name": "鸡胸肉（熟）", "aliases": "chicken breast", "calories": 165.0, "protein": 31.0, "carbs": 0.0, "fat": 3.6, "serving_size": "100g", "grams_per_unit": 100.0, "nutrition_source": "本机参考食物（估算）"],
            ["id": "seed_apple", "name": "苹果", "aliases": "apple", "calories": 52.0, "protein": 0.3, "carbs": 13.8, "fat": 0.2, "fiber": 2.4, "sugar": 10.4, "serving_size": "100g", "grams_per_unit": 100.0, "nutrition_source": "本机参考食物（估算）"],
            ["id": "seed_banana", "name": "香蕉", "aliases": "banana", "calories": 89.0, "protein": 1.1, "carbs": 22.8, "fat": 0.3, "fiber": 2.6, "sugar": 12.2, "serving_size": "100g", "grams_per_unit": 100.0, "nutrition_source": "本机参考食物（估算）"],
            ["id": "seed_broccoli", "name": "西兰花（熟）", "aliases": "broccoli", "calories": 35.0, "protein": 2.4, "carbs": 7.2, "fat": 0.4, "fiber": 3.3, "serving_size": "100g", "grams_per_unit": 100.0, "nutrition_source": "本机参考食物（估算）"],
            ["id": "seed_tofu", "name": "豆腐", "aliases": "tofu", "calories": 81.0, "protein": 8.1, "carbs": 4.2, "fat": 3.7, "serving_size": "100g", "grams_per_unit": 100.0, "nutrition_source": "本机参考食物（估算）"],
            ["id": "seed_oats", "name": "燕麦片（干）", "aliases": "oats", "calories": 379.0, "protein": 13.2, "carbs": 67.7, "fat": 6.5, "fiber": 10.1, "serving_size": "100g", "grams_per_unit": 100.0, "nutrition_source": "本机参考食物（估算）"]
        ]
    }
    private static var exerciseSeeds: [Object] {
        [
            ["id": "walking", "name": "步行", "category": "有氧", "met": 3.5, "default_intensity": "moderate", "suggested_minutes": 30, "description": "按 MET 和体重估算，实际消耗因人而异", "aliases": ["走路", "散步"]],
            ["id": "running", "name": "跑步", "category": "有氧", "met": 8.0, "default_intensity": "moderate", "suggested_minutes": 30, "aliases": ["慢跑"]],
            ["id": "cycling", "name": "骑行", "category": "有氧", "met": 6.8, "default_intensity": "moderate", "suggested_minutes": 30, "aliases": ["自行车"]],
            ["id": "swimming", "name": "游泳", "category": "有氧", "met": 6.0, "default_intensity": "moderate", "suggested_minutes": 30],
            ["id": "strength", "name": "力量训练", "category": "力量", "met": 3.5, "default_intensity": "moderate", "suggested_minutes": 45],
            ["id": "yoga", "name": "瑜伽", "category": "伸展", "met": 2.5, "default_intensity": "light", "suggested_minutes": 30]
        ]
    }
    private static var drinkSeeds: [Object] {
        let values: [(String, String, Double, Double, Double, Double, Double, Double, Double, Double, Double)] = [
            ("water", "水", 250, 1, 0, 0, 0, 0, 0, 0, 0),
            ("sparkling_water", "气泡水", 250, 1, 0, 0, 0, 0, 0, 0, 0),
            ("coffee", "咖啡", 240, 0.85, 95, 0, 0, 0, 0, 0, 0),
            ("latte", "拿铁", 350, 0.75, 75, 8, 160, 0, 8, 18, 6),
            ("tea", "茶", 240, 0.9, 35, 0, 0, 0, 0, 0, 0),
            ("milk", "牛奶", 240, 0.9, 0, 12, 120, 0, 8, 12, 4.5),
            ("milk_tea", "奶茶", 350, 0.7, 45, 32, 230, 0, 4, 38, 7),
            ("juice", "果汁", 240, 0.8, 0, 22, 110, 0, 1, 26, 0.2),
            ("energy_drink", "能量饮料", 250, 0.65, 80, 27, 120, 0, 0, 29, 0),
            ("alcohol", "酒精饮品", 150, 0, 0, 2, 125, 14, 0, 3, 0)
        ]
        return values.map { id, name, amount, factor, caffeine, sugar, calories, alcohol, protein, carbs, fat in
            ["id": id, "drink_type": id, "name": name, "default_amount_ml": amount, "hydration_factor": factor, "caffeine_mg": caffeine, "sugar_g": sugar, "calories": calories, "alcohol_g": alcohol, "protein_g": protein, "carbs_g": carbs, "fat_g": fat, "custom": false]
        }
    }
}
