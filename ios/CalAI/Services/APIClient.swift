import Foundation
import CryptoKit
import UIKit

class APIClient {
    static let shared = APIClient()
    static let apiOverrideDefaultsKey = "APIBaseURLOverride"
    private static let defaultBaseURL = "http://127.0.0.1:8001/v6"
    private static let pendingFoodLogRequestsDefaultsKey = "PendingFoodLogRequestIDs"
    private static let pendingMutationRequestsDefaultsKey = "PendingMutationRequestIDs"
    private let pendingFoodLogLock = NSLock()
    private let pendingMutationLock = NSLock()

    private static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var base: String {
        Self.resolvedBaseURL()
    }

    static func bundledBaseURL() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? defaultBaseURL
    }

    static func resolvedBaseURL() -> String {
        let bundled = normalizeBaseURL(bundledBaseURL())
        #if DEBUG
        let debugOverride = UserDefaults.standard.string(forKey: apiOverrideDefaultsKey) ?? ""
        if !debugOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeBaseURL(debugOverride)
        }
        #endif
        let override = UserDefaults.standard.string(forKey: apiOverrideDefaultsKey) ?? ""
        if isStaleLocalOverride(override) {
            UserDefaults.standard.removeObject(forKey: apiOverrideDefaultsKey)
            return bundled
        }
        return normalizeBaseURL(override.isEmpty ? bundled : override)
    }

    static func normalizeBaseURL(_ value: String) -> String {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasSuffix("/") {
            clean.removeLast()
        }
        if clean.isEmpty {
            return bundledBaseURL()
        }
        while true {
            let lower = clean.lowercased()
            if lower.hasSuffix("/v6") || lower.hasSuffix("/v1") {
                clean = String(clean.dropLast(3))
                while clean.hasSuffix("/") {
                    clean.removeLast()
                }
            } else {
                break
            }
        }
        return clean + "/v6"
    }

    private static func isStaleLocalOverride(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let normalized = normalizeBaseURL(value).lowercased()
        guard let url = URL(string: normalized),
              let host = url.host?.lowercased()
        else {
            return false
        }
        if url.port == 8001 || url.port == 8003 {
            return true
        }
        if host == "localhost" || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
            return true
        }
        return false
    }

    static func setBaseURLOverride(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        if clean.isEmpty {
            UserDefaults.standard.removeObject(forKey: apiOverrideDefaultsKey)
        } else {
            UserDefaults.standard.set(normalizeBaseURL(clean), forKey: apiOverrideDefaultsKey)
        }
        #else
        if clean.isEmpty || isStaleLocalOverride(clean) {
            UserDefaults.standard.removeObject(forKey: apiOverrideDefaultsKey)
        } else {
            UserDefaults.standard.set(normalizeBaseURL(clean), forKey: apiOverrideDefaultsKey)
        }
        #endif
    }

    @discardableResult
    static func checkConnection(to value: String) async throws -> Int {
        let targetBase = normalizeBaseURL(value)
        guard let url = URL(string: targetBase + "/daily-summary") else {
            throw APIError.server("地址格式不对")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8

        let v6Status: Int
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.server("这个地址暂时没响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.server("这个地址暂时不能用：HTTP \(http.statusCode)")
            }
            v6Status = http.statusCode
        } catch let error as URLError {
            throw APIError.connection(base: targetBase, code: error.code)
        }

        let depthBase = String(targetBase.dropLast(3)) + "/v1"
        guard let depthURL = URL(string: depthBase + "/health") else {
            throw APIError.server("拍照地址格式不对")
        }
        var depthReq = URLRequest(url: depthURL)
        depthReq.httpMethod = "GET"
        depthReq.setValue("application/json", forHTTPHeaderField: "Accept")
        depthReq.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: depthReq)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.server("拍照地址暂时没响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.server("扫描食物还没准备好：HTTP \(http.statusCode)")
            }
            // Connection check should answer only one question: can the app reach
            // the backend. Cloud vision readiness is handled by the camera flow so
            // a temporary GPU/model warm-up does not make the whole app look offline.
            _ = data
        } catch let error as URLError {
            throw APIError.connection(base: depthBase, code: error.code)
        }
        return v6Status
    }

    private var assetBase: String {
        if base.hasSuffix("/v6") {
            return String(base.dropLast(3))
        }
        return base
    }

    private var v1Base: String {
        if base.hasSuffix("/v6") {
            return String(base.dropLast(3)) + "/v1"
        }
        if base.hasSuffix("/v1") {
            return base
        }
        return base + "/v1"
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        return try decodeResponse(T.self, from: data)
    }

    func getDepthPipelineHealth() async throws -> DepthPipelineHealth {
        var req = URLRequest(url: URL(string: v1Base + "/health")!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        return try decodeResponse(DepthPipelineHealth.self, from: data)
    }

    private func post(_ path: String, json: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        req.timeoutInterval = 45
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
    }

    private func post<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        req.timeoutInterval = 45
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        return try decodeResponse(T.self, from: data)
    }

    @discardableResult
    func uploadDepthBundle(_ bundle: MealCaptureBundle) async throws -> [String: Any] {
        let captureId = try await createDepthCapture(bundle: bundle)
        let uploaded = try await uploadDepthBundleFiles(bundle, captureId: captureId)
        return [
            "capture_id": captureId,
            "local_capture_id": bundle.captureId,
            "uploaded": uploaded
        ]
    }

    private func createDepthCapture(bundle: MealCaptureBundle, mealType: String = "photo") async throws -> String {
        try await createMealCapture(depthSource: bundle.depthSource, mealType: mealType)
    }

    private func createMealCapture(depthSource: String, mealType: String = "photo") async throws -> String {
        var req = URLRequest(url: URL(string: v1Base + "/meal-captures")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "platform": "ios",
            "device_model": "ios_device",
            "depth_source": depthSource,
            "meal_type": mealType
        ])
        req.timeoutInterval = 30
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        guard
            let created = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let captureId = created["capture_id"] as? String
        else {
            throw APIError.server("深度拍摄任务创建失败")
        }
        return captureId
    }

    private func uploadDepthBundleFiles(_ bundle: MealCaptureBundle, captureId: String) async throws -> [[String: Any]] {
        let uploads: [(String, String, String)] = [
            ("rgb", bundle.rgbPath, "image/jpeg"),
            ("depth", bundle.depthPath, "application/octet-stream"),
            ("confidence", bundle.confidencePath, "application/octet-stream"),
            ("metadata", bundle.metadataPath, "application/json")
        ]

        var uploaded: [[String: Any]] = []
        for (kind, path, contentType) in uploads {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let body = try await uploadCaptureFile(captureId: captureId, kind: kind, data: data, contentType: contentType)
            uploaded.append(body)
        }
        return uploaded
    }

    private func uploadCaptureFile(
        captureId: String,
        kind: String,
        data: Data,
        contentType: String
    ) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: v1Base + "/meal-captures/\(captureId)/files/\(kind)")!)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 45
        let (responseData, response) = try await perform(req)
        try validate(response: response, data: responseData)
        return (try JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }

    private func uploadAuxiliaryImages(_ capture: MealCapture, captureId: String) async throws -> Int {
        var uploaded = 0
        for (index, encoded) in capture.auxiliaryImagesBase64.prefix(4).enumerated() {
            let sourceData = try Self.imageData(fromBase64: encoded)
            let data = try Self.platformUploadJPEGData(from: sourceData)
            _ = try await uploadCaptureFile(
                captureId: captureId,
                kind: "auxiliary_\(index)",
                data: data,
                contentType: "image/jpeg"
            )
            uploaded += 1
        }
        return uploaded
    }

    private func analyzeDepthCapture(captureId: String, userHint: String, mealType: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: v1Base + "/meal-captures/\(captureId)/analyze")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_hint": userHint,
            "meal_type": mealType,
            "container_hint": ""
        ])
        req.timeoutInterval = 180
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.server("拍照分析没开始。重新拍一张，或先手动补记。")
        }
        return body
    }

    private func getDepthJob(jobId: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: v1Base + "/meal-analysis-jobs/\(jobId)")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 60
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.server("还没拿到分析进度，返回首页刷新一次。")
        }
        return body
    }

    func confirmDepthMeal(mealId: String) async throws {
        var req = URLRequest(url: URL(string: v1Base + "/meals/\(mealId)/confirm")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["confirmed": true])
        req.timeoutInterval = 45
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
    }

    @discardableResult
    func patchDepthMealItem(
        mealId: String,
        itemId: String,
        nameZh: String? = nil,
        estimatedGrams: Double? = nil,
        eatenRatio: Double? = nil,
        oilLevel: String? = nil
    ) async throws -> [String: Any] {
        var payload: [String: Any] = [:]
        if let nameZh, !nameZh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["name_zh"] = nameZh.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let estimatedGrams { payload["estimated_grams"] = estimatedGrams }
        if let eatenRatio { payload["eaten_ratio"] = eatenRatio }
        if let oilLevel, !oilLevel.isEmpty { payload["oil_level"] = oilLevel }

        var req = URLRequest(url: URL(string: v1Base + "/meals/\(mealId)/items/\(itemId)")!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 45
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func analyzeDepthBundleAsDescribeMeal(
        capture: MealCapture,
        onEvent: (([String: Any]) -> Void)? = nil
    ) async throws -> DescribeMealResponse {
        guard let bundle = capture.depthBundle else {
            throw APIError.server("这次没拿到可算份量的信息，请从“扫描食物”实时拍一张。")
        }
        onEvent?(["stage": "uploading_depth", "message": "正在上传照片，马上开始识别"])
        let captureId = try await createDepthCapture(bundle: bundle, mealType: "photo")
        _ = try await uploadDepthBundleFiles(bundle, captureId: captureId)
        let auxiliaryCount = try await uploadAuxiliaryImages(capture, captureId: captureId)

        onEvent?([
            "stage": "analyzing_depth",
            "message": auxiliaryCount > 0 ? "正在结合主图和辅助图识别，再根据深度估重" : "正在根据照片估重"
        ])
        let source = (capture.captureMetadata["source"] as? String) ?? "image_scan"
        let task = try await analyzeDepthCapture(
            captureId: captureId,
            userHint: source == "label_scan" ? "营养标签" : "真实餐食照片，请识别可见食物",
            mealType: "photo"
        )
        guard let jobId = task["job_id"] as? String else {
            throw APIError.server("拍照分析没开始。重新拍一张，或先手动补记。")
        }

        for _ in 0..<30 {
            let job = try await getDepthJob(jobId: jobId)
            let status = String(describing: job["status"] ?? "")
            let progress = (job["progress"] as? Double) ?? 0
            onEvent?([
                "stage": status,
                "progress": progress,
                "message": status == "completed" ? "这餐算好了" : "正在分析这餐"
            ])
            if status == "completed" {
                guard
                    let result = job["result"] as? [String: Any],
                    result["meal_id"] is String
                else {
                    throw APIError.server("这次没有生成餐食结果，请重新拍一张更完整的照片。")
                }
                let foods = Self.foodItems(
                    fromDepthMealResult: result,
                    imageWidth: Double(bundle.rgbWidth),
                    imageHeight: Double(bundle.rgbHeight)
                )
                guard !foods.isEmpty else {
                    throw APIError.server("这张照片没识别出可记录的食物，请让整份食物和碗盘边缘都入镜。")
                }
                return DescribeMealResponse(
                    foods: foods,
                    healthScore: nil,
                    description: Self.depthDescription(from: result),
                    decision: nil
                )
            }
            if status == "failed" {
                throw APIError.server(String(describing: job["message"] ?? "这次没算出来，请重新拍一次。"))
            }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        throw APIError.server("这次分析等太久了，重新拍一张或先手动补记。")
    }

    private static func foodItems(
        fromDepthMealResult result: [String: Any],
        imageWidth: Double? = nil,
        imageHeight: Double? = nil
    ) -> [FoodItem] {
        guard let items = result["items"] as? [[String: Any]] else { return [] }
        let mealId = String(describing: result["meal_id"] ?? "")
        return items.compactMap { item in
            let itemId = String(describing: item["item_id"] ?? "")
            let name = (item["name_zh"] as? String) ?? (item["name_en"] as? String) ?? "食物"
            let nutrition = item["nutrition"] as? [String: Any] ?? [:]
            let weight = item["weight"] as? [String: Any] ?? [:]
            let volume = item["volume"] as? [String: Any] ?? [:]
            let depthQuality = volume["depth_quality"] as? [String: Any] ?? [:]
            let segmentation = item["segmentation"] as? [String: Any] ?? [:]
            let detection = item["detection"] as? [String: Any] ?? [:]
            let semanticValidation = item["semantic_validation"] as? [String: Any] ?? [:]
            let grams = doubleValue(weight["estimated_grams"])
            var serving = grams > 0 ? "\(Int(round(grams)))g" : "估算份量"
            if let fallback = volume["fallback"] as? Bool, fallback {
                serving += " · 需确认"
            }
            return FoodItem(
                name: name,
                calories: doubleValue(nutrition["calories"]),
                protein: doubleValue(nutrition["protein_g"]),
                carbs: doubleValue(nutrition["carbs_g"]),
                fat: doubleValue(nutrition["fat_g"]),
                fiber: doubleValue(nutrition["fiber_g"]),
                sugar: 0,
                sodium: doubleValue(nutrition["sodium_mg"]),
                servingSize: serving,
                processingLevel: "whole",
                addedSugar: 0,
                satFat: doubleValue(nutrition["sat_fat_g"]),
                cholesterol: doubleValue(nutrition["cholesterol_mg"]),
                vitaminC: doubleValue(nutrition["vitamin_c_mg"]),
                calcium: doubleValue(nutrition["calcium_mg"]),
                iron: doubleValue(nutrition["iron_mg"]),
                potassium: doubleValue(nutrition["potassium_mg"]),
                magnesium: doubleValue(nutrition["magnesium_mg"]),
                zinc: doubleValue(nutrition["zinc_mg"]),
                folate: doubleValue(nutrition["folate_mcg"]),
                vitaminD: doubleValue(nutrition["vitamin_d_mcg"]),
                vitaminB12: doubleValue(nutrition["vitamin_b12_mcg"]),
                vitaminE: doubleValue(nutrition["vitamin_e_mg"]),
                vitaminK: doubleValue(nutrition["vitamin_k_mcg"]),
                omega3: doubleValue(nutrition["omega_3_g"]),
                monounsaturatedFat: doubleValue(nutrition["monounsaturated_fat_g"]),
                polyunsaturatedFat: doubleValue(nutrition["polyunsaturated_fat_g"]),
                gramsPerUnit: 1,
                quantityCount: grams > 0 ? grams : nil,
                quantityUnit: grams > 0 ? "克" : "",
                quantityDescription: grams > 0 ? "\(Int(round(grams)))克" : "",
                nutritionSource: stringValue(item["nutrition_source"]) ?? "",
                date: nil,
                depthMealId: mealId.isEmpty ? nil : mealId,
                depthItemId: itemId.isEmpty ? nil : itemId,
                depthVolumeMl: doubleValue(volume["estimated_volume_ml"]),
                depthVolumeMethod: stringValue(volume["volume_method"]),
                depthSource: stringValue(volume["depth_source"]),
                depthVolumeConfidence: doubleValue(depthQuality["volume_confidence"]),
                depthFallback: volume["fallback"] as? Bool,
                depthFallbackReason: stringValue(volume["fallback_reason"]),
                depthMaskUrl: stringValue(segmentation["mask_url"]),
                depthMaskPreviewBase64: stringValue(segmentation["mask_preview_base64"]),
                depthMaskAreaPixels: doubleValue(segmentation["area_pixels"]),
                depthMaskConfidence: doubleValue(segmentation["mask_confidence"]),
                depthDensity: doubleValue(weight["density_g_per_ml"]),
                depthDensitySource: stringValue(weight["density_source"]),
                depthBbox: doubleArrayValue(detection["bbox_xyxy"]),
                depthImageWidth: imageWidth,
                depthImageHeight: imageHeight,
                depthSemanticIsFood: semanticValidation["is_food"] as? Bool,
                depthSemanticConfidence: doubleValue(semanticValidation["semantic_confidence"]),
                depthSemanticNeedsSplit: semanticValidation["needs_split"] as? Bool,
                depthSemanticNotes: stringArrayValue(semanticValidation["notes"])
            )
        }
    }

    private static func depthDescription(from result: [String: Any]) -> String {
        let mode = String(describing: result["estimation_mode"] ?? "rgb_depth_pipeline")
        let mealId = String(describing: result["meal_id"] ?? "")
        let items = result["items"] as? [[String: Any]] ?? []
        let fallbackCount = items.filter { item in
            let volume = item["volume"] as? [String: Any] ?? [:]
            return (volume["fallback"] as? Bool) == true
        }.count
        let suffix = mealId.isEmpty ? "" : " · depth_meal_id=\(mealId)"
        if fallbackCount > 0 {
            return "\(mode)：\(items.count) 项，其中 \(fallbackCount) 项需要份量确认\(suffix)"
        }
        return "\(mode)：\(items.count) 项\(suffix)"
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) ?? 0 }
        return 0
    }

    private static func imageData(fromBase64 raw: String) throws -> Data {
        let value = raw.contains(",") ? String(raw.split(separator: ",", maxSplits: 1).last ?? "") : raw
        guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            throw APIError.server("这张照片数据无效，请重新选一张。")
        }
        return data
    }

    private static func imageSize(from data: Data) -> (width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        let width = max(1, Int(round(image.size.width * image.scale)))
        let height = max(1, Int(round(image.size.height * image.scale)))
        return (width, height)
    }

    private static func platformUploadJPEGData(from data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw APIError.server("这张照片无法读取，请重新选一张。")
        }
        let pixelWidth = max(1, image.size.width * image.scale)
        let pixelHeight = max(1, image.size.height * image.scale)
        let maxEdge: CGFloat = 1536
        let scale = min(1, maxEdge / max(pixelWidth, pixelHeight))
        let targetSize = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85), !jpeg.isEmpty else {
            throw APIError.server("这张照片压缩失败，请重新选一张。")
        }
        return jpeg
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        let text = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "<null>" || text.lowercased() == "null" {
            return nil
        }
        return text
    }

    private static func doubleArrayValue(_ raw: Any?) -> [Double]? {
        if let values = raw as? [Double] { return values }
        if let values = raw as? [NSNumber] { return values.map(\.doubleValue) }
        if let values = raw as? [Any] {
            let doubles = values.compactMap { value -> Double? in
                if let number = value as? NSNumber { return number.doubleValue }
                if let double = value as? Double { return double }
                if let int = value as? Int { return Double(int) }
                if let text = value as? String { return Double(text) }
                return nil
            }
            return doubles.isEmpty ? nil : doubles
        }
        return nil
    }

    private static func stringArrayValue(_ raw: Any?) -> [String]? {
        guard let values = raw as? [Any] else { return nil }
        let strings = values.compactMap { value -> String? in
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text == "<null>" ? nil : text
        }
        return strings.isEmpty ? nil : strings
    }

    private func put<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        req.timeoutInterval = 45
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        return try decodeResponse(T.self, from: data)
    }

    private func delete<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        req.timeoutInterval = 45
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        return try decodeResponse(T.self, from: data)
    }

    func getDailySummary(date: String = "") async throws -> DailySummary {
        let path = date.isEmpty ? "/daily-summary" : "/daily-summary?date=\(date.urlQueryEscaped)"
        return try await get(path)
    }
    func getDiaryNote(date: String = "") async throws -> DiaryNoteResponse {
        let path = date.isEmpty ? "/diary-note" : "/diary-note?date=\(date.urlQueryEscaped)"
        return try await get(path)
    }
    func saveDiaryNote(date: String = "", note: String) async throws -> DiaryNoteResponse {
        var payload: [String: Any] = ["note": note]
        if !date.isEmpty { payload["date"] = date }
        return try await post("/diary-note", json: payload)
    }
    func completeDiary(date: String = "") async throws -> DiaryCompleteResponse {
        var payload: [String: Any] = [:]
        if !date.isEmpty { payload["date"] = date }
        return try await post("/diary/complete", json: payload)
    }
    func getStreak() async throws -> StreakData { try await get("/streak") }
    func getGoalPlan() async throws -> GoalPlan? { try await get("/goal-plan") }
    func exportAccountData() async throws -> Data {
        var req = URLRequest(url: URL(string: base + "/account/export")!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        return data
    }
    func deleteAccountData() async throws -> AccountDeleteResponse {
        try await delete("/account", json: ["confirmation": "DELETE"])
    }
    func getMacroGoals() async throws -> MacroGoals { try await get("/macro-goals") }
    func getNutritionScore(date: String = "") async throws -> NutritionScore {
        let path = date.isEmpty ? "/nutrition-score/daily" : "/nutrition-score/daily?date=\(date.urlQueryEscaped)"
        return try await get(path)
    }
    func getDecisionContext(date: String = "") async throws -> DecisionContext {
        let path = date.isEmpty ? "/decision/context" : "/decision/context?date=\(date.urlQueryEscaped)"
        return try await get(path)
    }
    func getDecisionEvents(date: String = "", limit: Int = 30) async throws -> [DecisionScoreResponse] {
        var path = "/decision/events?limit=\(limit)"
        if !date.isEmpty {
            path += "&date=\(date.urlQueryEscaped)"
        }
        let response: DecisionEventsResponse = try await get(path)
        return response.events
    }
    func scoreMealDecision(foods: [FoodItem], date: String = "", persist: Bool = true) async throws -> DecisionScoreResponse {
        var payload: [String: Any] = [
            "foods": foods.map { foodPayload($0) },
            "source": "candidate",
            "event_type": "today_fit",
            "persist": persist,
        ]
        if !date.isEmpty { payload["date"] = date }
        return try await post("/decision/score-meal", json: payload)
    }
    func scoreAfterLogDecision(foods: [FoodItem], date: String = "", persist: Bool = true) async throws -> DecisionScoreResponse {
        var payload: [String: Any] = [
            "foods": foods.map { foodPayload($0) },
            "source": "meal",
            "event_type": "after_log",
            "persist": persist,
        ]
        if !date.isEmpty { payload["date"] = date }
        return try await post("/decision/after-log", json: payload)
    }
    func scoreProductDecision(nutrition: [String: Double], names: [String] = [], date: String = "", persist: Bool = true) async throws -> DecisionScoreResponse {
        var payload: [String: Any] = [
            "nutrition": nutrition,
            "names": names,
            "source": "product",
            "event_type": "product_score",
            "persist": persist,
        ]
        if !date.isEmpty { payload["date"] = date }
        return try await post("/decision/score-product", json: payload)
    }
    func getChallenges() async throws -> [Challenge] {
        let response: ChallengesResponse = try await get("/challenges")
        return response.challenges
    }
    func createChallenge(_ request: ChallengeCreateRequest) async throws -> Challenge {
        try await post("/challenges", json: request.json)
    }
    func getFriends(user: String = "me") async throws -> [Friend] {
        let response: FriendsResponse = try await get("/friends?user=\(user.urlQueryEscaped)")
        return response.friends
    }
    func getLeaderboard(user: String = "me") async throws -> [LeaderboardEntry] {
        let response: LeaderboardResponse = try await get("/friends/leaderboard?user=\(user.urlQueryEscaped)")
        return response.leaderboard
    }
    func getCommunityFeed(tab: String = "friends", user: String = "me", limit: Int = 20, cursor: String = "") async throws -> CommunityFeedResponse {
        var path = "/community/feed?tab=\(tab.urlQueryEscaped)&user=\(user.urlQueryEscaped)&limit=\(limit)"
        if !cursor.isEmpty {
            path += "&cursor=\(cursor.urlQueryEscaped)"
        }
        return try await get(path)
    }
    func getWeights(days: Int = 90) async throws -> [WeightLog] {
        let response: WeightLogsResponse = try await get("/weight?days=\(days)")
        return response.weights
    }
    func getProgressPhotos(limit: Int = 20, includeImages: Bool = false) async throws -> [ProgressPhoto] {
        let include = includeImages ? 1 : 0
        let response: ProgressPhotosResponse = try await get("/progress-photos?limit=\(limit)&include_images=\(include)")
        return response.photos
    }
    func getWater(date: String = "") async throws -> WaterResp {
        let path = date.isEmpty ? "/water" : "/water?date=\(date.urlQueryEscaped)"
        return try await get(path)
    }
    func getHydration(date: String = "", days: Int = 1) async throws -> [HydrationLog] {
        var path = "/hydration?days=\(days)"
        if !date.isEmpty {
            path += "&date=\(date.urlQueryEscaped)"
        }
        let response: HydrationLogsResponse = try await get(path)
        return response.logs
    }
    func getHydrationSummary(date: String = "") async throws -> HydrationSummary {
        let path = date.isEmpty ? "/hydration/summary" : "/hydration/summary?date=\(date.urlQueryEscaped)"
        return try await get(path)
    }
    func getHydrationSettings() async throws -> HydrationSettings {
        try await get("/hydration/settings")
    }
    func saveHydrationSettings(goalMl: Double) async throws -> HydrationSettings {
        try await put("/hydration/settings", json: [
            "hydration_goal_ml": goalMl,
        ])
    }
    func getDrinkPresets() async throws -> [DrinkPreset] {
        let response: DrinkPresetsResponse = try await get("/drink-presets")
        return response.presets
    }
    func getExercises(date: String = "") async throws -> [ExerciseEntry] {
        let path = date.isEmpty ? "/exercise" : "/exercise?date=\(date.urlQueryEscaped)"
        let response: ExerciseLogsResponse = try await get(path)
        return response.exercises
    }
    func getFoods(date: String = "", days: Int = 1) async throws -> [FoodLogRow] {
        var path = "/foods?days=\(days)"
        if !date.isEmpty {
            path += "&date=\(date.urlQueryEscaped)"
        }
        let response: FoodLogResponse = try await get(path)
        return response.foods
    }
    func getFrequentFoods(limit: Int = 12, mealCategory: String = "") async throws -> [FrequentFoodItem] {
        var path = "/frequent-foods?limit=\(limit)"
        let cleanMealCategory = mealCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanMealCategory.isEmpty {
            path += "&meal_category=\(cleanMealCategory.urlQueryEscaped)"
        }
        let response: FrequentFoodsResponse = try await get(path)
        return response.foods
    }
    func searchFoods(query: String) async throws -> [FoodItem] {
        let response: FoodSearchResponse = try await get("/foodDatabase/search?q=\(query.urlQueryEscaped)")
        return response.foods
    }

    func assetURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: assetBase + normalized)
    }

    private func foodPayload(_ food: FoodItem) -> [String: Any] {
        var payload: [String: Any] = [
            "id": food.id,
            "name": food.name,
            "calories": food.calories,
            "protein": food.protein,
            "carbs": food.carbs,
            "fat": food.fat,
            "fiber": food.fiber,
            "sugar": food.sugar,
            "sodium": food.sodium,
            "serving_size": food.servingSize,
            "grams_per_unit": food.gramsPerUnit,
            "processing_level": food.processingLevel,
            "added_sugar": food.addedSugar,
            "sat_fat": food.satFat,
            "trans_fat": food.transFat,
            "cholesterol": food.cholesterol,
            "vitamin_a": food.vitaminA,
            "vitamin_c": food.vitaminC,
            "calcium": food.calcium,
            "iron": food.iron,
            "potassium": food.potassium,
            "magnesium": food.magnesium,
            "zinc": food.zinc,
            "folate": food.folate,
            "vitamin_d": food.vitaminD,
            "vitamin_b12": food.vitaminB12,
            "vitamin_e": food.vitaminE,
            "vitamin_k": food.vitaminK,
            "omega_3": food.omega3,
            "monounsaturated_fat": food.monounsaturatedFat,
            "polyunsaturated_fat": food.polyunsaturatedFat,
            "consumed_ratio": food.consumedRatio,
            "barcode": food.barcode,
            "nutrition_source": food.nutritionSource,
        ]
        if let quantityCount = food.quantityCount {
            payload["quantity_count"] = quantityCount
        }
        if !food.quantityUnit.isEmpty { payload["quantity_unit"] = food.quantityUnit }
        if !food.quantityDescription.isEmpty { payload["quantity_description"] = food.quantityDescription }
        if let date = food.date, !date.isEmpty {
            payload["date"] = date
        }
        return payload
    }

    func describeMeal(imageBase64: String) async throws -> DescribeMealResponse {
        try await describePhotoOnlyMeal(
            capture: MealCapture(
                imageBase64: imageBase64,
                depthMetadata: nil,
                captureMetadata: [
                    "source": "library",
                    "has_depth": false,
                    "capture_pipeline": "photo_only_fallback"
                ]
            )
        )
    }
    func describeTextMeal(_ text: String) async throws -> DescribeMealResponse {
        try await post("/describeMeal", json: [
            "source": "manually",
            "text": text,
        ])
    }

    func addWater(ml: Double) async throws {
        var payload: [String: Any] = ["amount_ml": ml, "date": Self.todayDateString()]
        let pending = pendingMutationRequest(operation: "water", payload: payload)
        payload["request_id"] = pending.requestId
        try await post("/water", json: payload)
        clearPendingMutationRequest(pending)
    }
    func addHydration(
        amountMl: Double,
        drinkType: String = "water",
        note: String = "",
        date: String = ""
    ) async throws -> HydrationLog {
        var payload: [String: Any] = [
            "drink_type": drinkType,
            "amount_ml": amountMl,
            "source": "ios_swiftui",
            "date": date.isEmpty ? Self.todayDateString() : date,
        ]
        if !note.isEmpty { payload["note"] = note }
        let pending = pendingMutationRequest(operation: "hydration", payload: payload)
        payload["request_id"] = pending.requestId
        let response: HydrationLog = try await post("/hydration", json: payload)
        clearPendingMutationRequest(pending)
        return response
    }
    func deleteHydration(ids: [String] = [], date: String = "") async throws -> HydrationDeleteResponse {
        try await delete("/hydration", json: [
            "ids": ids,
            "date": date,
        ])
    }
    func addDrinkPreset(
        name: String,
        defaultAmountMl: Double,
        hydrationFactor: Double,
        caffeineMg: Double = 0,
        sugarG: Double = 0,
        calories: Double = 0,
        alcoholG: Double = 0
    ) async throws -> DrinkPreset {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return try await post("/drink-presets", json: [
            "id": normalized.isEmpty ? UUID().uuidString : normalized,
            "drink_type": normalized.isEmpty ? UUID().uuidString : normalized,
            "name": name,
            "default_amount_ml": defaultAmountMl,
            "hydration_factor": hydrationFactor,
            "caffeine_mg": caffeineMg,
            "sugar_g": sugarG,
            "calories": calories,
            "alcohol_g": alcoholG,
            "custom": true,
        ])
    }
    func addWeight(kg: Double) async throws {
        var payload: [String: Any] = ["weight_kg": kg, "date": Self.todayDateString()]
        let pending = pendingMutationRequest(operation: "weight", payload: payload)
        payload["request_id"] = pending.requestId
        try await post("/weight", json: payload)
        clearPendingMutationRequest(pending)
    }
    func addProgressPhoto(imageBase64: String, weightKg: Double? = nil, notes: String = "") async throws -> ProgressPhotoSaveResponse {
        var payload: [String: Any] = [
            "image_base64": imageBase64,
            "notes": notes,
        ]
        if let weightKg, weightKg > 0 {
            payload["weight_kg"] = weightKg
        }
        return try await post("/progress-photos", json: payload)
    }
    func addExercise(name: String, dur: Int, cal: Double) async throws {
        var payload: [String: Any] = [
            "name": name,
            "duration_minutes": dur,
            "calories_burned": cal,
            "intensity": "moderate",
            "date": Self.todayDateString(),
        ]
        let pending = pendingMutationRequest(operation: "exercise", payload: payload)
        payload["request_id"] = pending.requestId
        try await post("/exercise", json: payload)
        clearPendingMutationRequest(pending)
    }
    func addExercise(
        name: String,
        durationMinutes: Int,
        intensity: String,
        caloriesBurned: Double,
        exerciseId: String? = nil,
        notes: String = "",
        date: String = ""
    ) async throws {
        var payload: [String: Any] = [
            "name": name,
            "duration_minutes": durationMinutes,
            "intensity": intensity,
            "calories_burned": caloriesBurned,
            "notes": notes,
            "date": date.isEmpty ? Self.todayDateString() : date,
        ]
        if let exerciseId, !exerciseId.isEmpty {
            payload["exercise_id"] = exerciseId
        }
        let pending = pendingMutationRequest(operation: "exercise", payload: payload)
        payload["request_id"] = pending.requestId
        try await post("/exercise", json: payload)
        clearPendingMutationRequest(pending)
    }
    func addSteps(_ s: Int) async throws {
        var payload: [String: Any] = ["steps": s, "date": Self.todayDateString()]
        let pending = pendingMutationRequest(operation: "steps", payload: payload)
        payload["request_id"] = pending.requestId
        try await post("/steps", json: payload)
        clearPendingMutationRequest(pending)
    }
    func getExerciseCatalog() async throws -> [ExerciseCatalogItem] {
        let response: ExerciseCatalogResponse = try await get("/exercise/catalog")
        return response.exercises
    }
    func estimateExercise(
        exerciseId: String? = nil,
        name: String,
        durationMinutes: Int,
        intensity: String
    ) async throws -> ExerciseEstimate {
        var payload: [String: Any] = [
            "name": name,
            "duration_minutes": durationMinutes,
            "intensity": intensity,
        ]
        if let exerciseId, !exerciseId.isEmpty {
            payload["exercise_id"] = exerciseId
        }
        return try await post("/exercise/estimate", json: payload)
    }
    func logFoods(
        _ foods: [FoodItem],
        mealCategory: String = "",
        groupTitle: String = "",
        imageBase64: String = "",
        date: String = ""
    ) async throws -> FoodLogSaveResponse {
        let foodsPayload = foods.map { foodPayload($0) }
        var payload: [String: Any] = [
            "foods": foodsPayload,
            "meal_category": mealCategory,
            "group_title": groupTitle,
        ]
        if !imageBase64.isEmpty {
            payload["image_base64"] = imageBase64
        }
        payload["date"] = date.isEmpty ? Self.todayDateString() : date
        let fingerprint = foodLogPayloadFingerprint(payload)
        let requestId = pendingFoodLogRequestId(for: fingerprint)
        payload["request_id"] = requestId
        let response: FoodLogSaveResponse = try await post("/food-log", json: payload)
        clearPendingFoodLogRequestId(for: fingerprint, requestId: requestId)
        return response
    }

    private func foodLogPayloadFingerprint(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return UUID().uuidString.lowercased()
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pendingFoodLogRequestId(for fingerprint: String) -> String {
        pendingFoodLogLock.lock()
        defer { pendingFoodLogLock.unlock() }
        var pending = UserDefaults.standard.dictionary(forKey: Self.pendingFoodLogRequestsDefaultsKey) as? [String: String] ?? [:]
        if let existing = pending[fingerprint], !existing.isEmpty {
            return existing
        }
        if pending.count >= 50 {
            pending.removeAll()
        }
        let requestId = UUID().uuidString.lowercased()
        pending[fingerprint] = requestId
        UserDefaults.standard.set(pending, forKey: Self.pendingFoodLogRequestsDefaultsKey)
        return requestId
    }

    private func clearPendingFoodLogRequestId(for fingerprint: String, requestId: String) {
        pendingFoodLogLock.lock()
        defer { pendingFoodLogLock.unlock() }
        var pending = UserDefaults.standard.dictionary(forKey: Self.pendingFoodLogRequestsDefaultsKey) as? [String: String] ?? [:]
        guard pending[fingerprint] == requestId else { return }
        pending.removeValue(forKey: fingerprint)
        UserDefaults.standard.set(pending, forKey: Self.pendingFoodLogRequestsDefaultsKey)
    }

    private struct PendingMutationRequest {
        let key: String
        let requestId: String
    }

    private func pendingMutationRequest(
        operation: String,
        payload: [String: Any]
    ) -> PendingMutationRequest {
        let fingerprint = foodLogPayloadFingerprint(payload)
        let key = "\(operation):\(fingerprint)"
        pendingMutationLock.lock()
        defer { pendingMutationLock.unlock() }
        var pending = UserDefaults.standard.dictionary(forKey: Self.pendingMutationRequestsDefaultsKey) as? [String: String] ?? [:]
        if let existing = pending[key], !existing.isEmpty {
            return PendingMutationRequest(key: key, requestId: existing)
        }
        if pending.count >= 100 {
            pending.removeAll()
        }
        let requestId = UUID().uuidString.lowercased()
        pending[key] = requestId
        UserDefaults.standard.set(pending, forKey: Self.pendingMutationRequestsDefaultsKey)
        return PendingMutationRequest(key: key, requestId: requestId)
    }

    private func clearPendingMutationRequest(_ request: PendingMutationRequest) {
        pendingMutationLock.lock()
        defer { pendingMutationLock.unlock() }
        var pending = UserDefaults.standard.dictionary(forKey: Self.pendingMutationRequestsDefaultsKey) as? [String: String] ?? [:]
        guard pending[request.key] == request.requestId else { return }
        pending.removeValue(forKey: request.key)
        UserDefaults.standard.set(pending, forKey: Self.pendingMutationRequestsDefaultsKey)
    }
    func getSavedMeals(limit: Int = 20, query: String = "", sort: String = "created", offset: Int = 0, mealCategory: String = "", favorite: Bool = false) async throws -> [SavedMealItem] {
        var path = "/saved-meals?limit=\(limit)&sort=\(sort)&offset=\(max(0, offset))"
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanQuery.isEmpty {
            path += "&query=\(cleanQuery.urlQueryEscaped)"
        }
        let cleanMealCategory = mealCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanMealCategory.isEmpty {
            path += "&meal_category=\(cleanMealCategory.urlQueryEscaped)"
        }
        if favorite {
            path += "&favorite=true"
        }
        let response: SavedMealsResponse = try await get(path)
        return response.meals
    }
    func saveMealTemplate(title: String, foods: [FoodItem], mealCategory: String = "", imageUrl: String = "", note: String? = nil, instructions: [String]? = nil, favorite: Bool? = nil) async throws -> SavedMealItem {
        var payload: [String: Any] = [
            "title": title,
            "foods": foods.map { foodPayload($0) },
            "meal_category": mealCategory,
            "image_url": imageUrl,
            "source": "ios"
        ]
        if let note { payload["note"] = note }
        if let instructions { payload["instructions"] = instructions }
        if let favorite { payload["favorite"] = favorite }
        let response: SavedMealMutationResponse = try await post("/saved-meals", json: payload)
        guard let meal = response.meal else {
            throw APIError.server("保存餐品失败。")
        }
        return meal
    }
    func updateSavedMeal(id: String, title: String, foods: [FoodItem], mealCategory: String = "", imageUrl: String = "", note: String? = nil, instructions: [String]? = nil, favorite: Bool? = nil) async throws -> SavedMealItem {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var payload: [String: Any] = [
            "title": title,
            "foods": foods.map { foodPayload($0) },
            "meal_category": mealCategory,
            "image_url": imageUrl,
            "source": "ios"
        ]
        if let note { payload["note"] = note }
        if let instructions { payload["instructions"] = instructions }
        if let favorite { payload["favorite"] = favorite }
        let response: SavedMealMutationResponse = try await put("/saved-meals/\(encodedId)", json: payload)
        guard let meal = response.meal else {
            throw APIError.server("这份餐品还没更新，内容还在，检查网络后再点保存。")
        }
        return meal
    }
    func logSavedMeal(id: String, mealCategory: String = "", date: String = "", portionMultiplier: Double = 1) async throws -> SavedMealLogResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var payload: [String: Any] = [
            "meal_category": mealCategory,
            "portion_multiplier": portionMultiplier,
        ]
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/saved-meals/\(encodedId)/log", json: payload)
    }
    func deleteSavedMeal(id: String) async throws -> SavedMealDeleteResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await delete("/saved-meals/\(encodedId)", json: [:])
    }
    func toggleSavedMealFavorite(id: String) async throws -> SavedMealMutationResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await post("/saved-meals/\(encodedId)/favorite", json: [:])
    }
    func getSavedFoods(limit: Int = 50, query: String = "", sort: String = "created", offset: Int = 0) async throws -> [SavedFoodItem] {
        var path = "/saved-foods?limit=\(limit)&sort=\(sort)&offset=\(max(0, offset))"
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanQuery.isEmpty {
            path += "&query=\(cleanQuery.urlQueryEscaped)"
        }
        let response: SavedFoodsResponse = try await get(path)
        return response.foods
    }
    func saveFoodTemplate(_ food: FoodItem) async throws -> SavedFoodItem {
        let response: SavedFoodMutationResponse = try await post("/saved-foods", json: [
            "food": foodPayload(food),
            "source": "ios"
        ])
        guard let savedFood = response.food else {
            throw APIError.server("保存食物失败。")
        }
        return savedFood
    }
    func updateSavedFood(id: String, food: FoodItem) async throws -> SavedFoodItem {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let response: SavedFoodMutationResponse = try await put("/saved-foods/\(encodedId)", json: [
            "food": foodPayload(food),
            "source": "ios"
        ])
        guard let savedFood = response.food else {
            throw APIError.server("这个食物还没更新，内容还在，检查网络后再点保存。")
        }
        return savedFood
    }
    func logSavedFood(id: String, mealCategory: String = "", date: String = "", portionMultiplier: Double = 1) async throws -> SavedFoodLogResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var payload: [String: Any] = [
            "meal_category": mealCategory,
            "portion_multiplier": portionMultiplier,
        ]
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/saved-foods/\(encodedId)/log", json: payload)
    }
    func deleteSavedFood(id: String) async throws -> SavedFoodDeleteResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await delete("/saved-foods/\(encodedId)", json: [:])
    }
    func deleteFoodLogs(ids: [Int] = [], uploadGroupId: String = "") async throws -> FoodLogDeleteResponse {
        try await delete("/food-log", json: [
            "ids": ids,
            "upload_group_id": uploadGroupId,
        ])
    }
    func adjustFoodLogPortion(id: Int, consumedRatio: Double, date: String = "") async throws -> FoodLogPortionResponse {
        var payload: [String: Any] = [
            "consumed_ratio": consumedRatio,
        ]
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/food-log/\(id)/portion", json: payload)
    }

    func moveFoodLog(id: Int, mealCategory: String, date: String = "") async throws -> FoodLogMoveResponse {
        var payload: [String: Any] = [
            "meal_category": mealCategory,
        ]
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/food-log/\(id)/move", json: payload)
    }

    func estimateFoodLogLeftovers(
        uploadGroupId: String,
        imageBase64: String,
        date: String = "",
        description: String = ""
    ) async throws -> LeftoverEstimateResponse {
        var payload: [String: Any] = [
            "upload_group_id": uploadGroupId,
            "image_base64": imageBase64,
            "description": description,
        ]
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/food-log/leftovers/estimate", json: payload)
    }
    func applyFoodLogLeftovers(
        uploadGroupId: String,
        imageBase64: String? = nil,
        date: String = "",
        items: [LeftoverEstimateItem]
    ) async throws -> LeftoverApplyResponse {
        var payload: [String: Any] = [
            "upload_group_id": uploadGroupId,
            "items": items.map { item -> [String: Any] in
                [
                    "id": item.id,
                    "name": item.name,
                    "remaining_percent": item.remainingPercent,
                    "confidence": item.confidence,
                    "reason": item.reason,
                ]
            },
        ]
        if let imageBase64, !imageBase64.isEmpty {
            payload["image_base64"] = imageBase64
        }
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/food-log/leftovers/apply", json: payload)
    }
    func reportFood(foodId: String, foodName: String = "", reason: String = "wrong_nutrition", detail: String = "") async throws {
        try await post("/reportFood", json: [
            "food_id": foodId,
            "food_name": foodName,
            "reason": reason,
            "detail": detail,
        ])
    }
    func fixFood(
        foodId: String,
        originalName: String = "",
        note: String = "",
        correctedName: String? = nil,
        correctedCalories: Double? = nil,
        correctedProtein: Double? = nil,
        correctedCarbs: Double? = nil,
        correctedFat: Double? = nil,
        correctedFiber: Double? = nil,
        correctedSugar: Double? = nil,
        correctedSodium: Double? = nil,
        correctedServingSize: String? = nil
    ) async throws {
        var payload: [String: Any] = [
            "food_id": foodId,
            "original_name": originalName,
            "note": note,
        ]
        if let correctedName, !correctedName.isEmpty { payload["corrected_name"] = correctedName }
        if let correctedCalories { payload["corrected_calories"] = correctedCalories }
        if let correctedProtein { payload["corrected_protein"] = correctedProtein }
        if let correctedCarbs { payload["corrected_carbs"] = correctedCarbs }
        if let correctedFat { payload["corrected_fat"] = correctedFat }
        if let correctedFiber { payload["corrected_fiber"] = correctedFiber }
        if let correctedSugar { payload["corrected_sugar"] = correctedSugar }
        if let correctedSodium { payload["corrected_sodium"] = correctedSodium }
        if let correctedServingSize, !correctedServingSize.isEmpty { payload["corrected_serving_size"] = correctedServingSize }
        try await post("/fixFood", json: payload)
    }
    func voteFood(foodId: String, foodName: String = "", vote: String) async throws {
        try await post("/voteFood", json: [
            "food_id": foodId,
            "food_name": foodName,
            "vote": vote,
        ])
    }
    func parseVoiceLog(text: String, date: String = "") async throws -> VoiceLogParseResponse {
        var payload: [String: Any] = ["text": text]
        if !date.isEmpty { payload["date"] = date }
        return try await post("/voice-log/parse", json: payload)
    }
    func applyVoiceLog(
        text: String,
        date: String = "",
        mealCategory: String,
        foods: [VoiceParsedFood],
        hydration: [VoiceParsedDrink]
    ) async throws -> VoiceLogApplyResponse {
        let foodPayload = foods.map { food -> [String: Any] in
            [
                "name": food.name,
                "calories": food.calories,
                "protein": food.protein,
                "carbs": food.carbs,
                "fat": food.fat,
                "fiber": food.fiber,
                "sugar": food.sugar,
                "sodium": food.sodium,
                "serving_size": food.servingSize,
            ]
        }
        let hydrationPayload = hydration.map { drink -> [String: Any] in
            [
                "drink_type": drink.drinkType,
                "amount_ml": drink.amountMl,
                "calories": drink.calories,
                "protein_g": drink.protein,
                "carbs_g": drink.carbs,
                "fat_g": drink.fat,
                "sugar_g": drink.sugar,
                "note": drink.note,
            ]
        }
        var payload: [String: Any] = [
            "text": text,
            "meal_category": mealCategory,
            "foods": foodPayload,
            "hydration": hydrationPayload,
            "date": date.isEmpty ? Self.todayDateString() : date,
        ]
        let pending = pendingMutationRequest(operation: "voice_log", payload: payload)
        payload["request_id"] = pending.requestId
        let response: VoiceLogApplyResponse = try await post("/voice-log/apply", json: payload)
        clearPendingMutationRequest(pending)
        return response
    }
    func getSleepSummary(date: String = "") async throws -> SleepSummary {
        let path = date.isEmpty ? "/sleep/summary" : "/sleep/summary?date=\(date.urlQueryEscaped)"
        return try await get(path)
    }
    func getSleep(date: String = "") async throws -> [SleepLog] {
        let path = date.isEmpty ? "/sleep" : "/sleep?date=\(date.urlQueryEscaped)"
        let response: SleepLogsResponse = try await get(path)
        return response.logs
    }
    func addSleep(durationHours: Double, quality: Int, note: String = "", date: String = "") async throws -> SleepLogSaveResponse {
        var payload: [String: Any] = [
            "duration_hours": durationHours,
            "quality": quality,
            "note": note,
            "source": "ios_swiftui",
            "date": date.isEmpty ? Self.todayDateString() : date,
        ]
        let pending = pendingMutationRequest(operation: "sleep", payload: payload)
        payload["request_id"] = pending.requestId
        let response: SleepLogSaveResponse = try await post("/sleep", json: payload)
        clearPendingMutationRequest(pending)
        return response
    }
    func importHealthRecords(_ records: [HealthImportRecordPayload], source: String = "healthkit") async throws -> HealthImportResponse {
        try await post("/health/import", json: [
            "source": source,
            "records": records.map { $0.json },
        ])
    }
    func getUserPreferences() async throws -> UserPreferences {
        try await get("/user-preferences")
    }
    func saveUserPreferences(_ preferences: UserPreferences) async throws -> UserPreferences {
        try await put("/user-preferences", json: [
            "diet_type": preferences.dietType,
            "allergies": preferences.allergies,
            "avoid_ingredients": preferences.avoidIngredients,
            "favorite_cuisines": preferences.favoriteCuisines,
            "budget_level": preferences.budgetLevel,
            "prep_time_minutes": preferences.prepTimeMinutes,
            "include_imported_recipes_in_meal_plans": preferences.includeImportedRecipesInMealPlans,
            "taste_tags": preferences.tasteTags,
            "meal_names": preferences.mealNames,
        ])
    }
    func getMealPlanHistory() async throws -> [MealPlanPayload] {
        let response: MealPlanHistoryResponse = try await get("/meal-plan/history")
        return response.plans
    }

    func getMealPlanRecipeCollections(limit: Int = 6) async throws -> [MealPlanRecipeCollection] {
        let safeLimit = max(1, min(12, limit))
        let response: MealPlanRecipeCollectionsResponse = try await get("/meal-plan/collections?limit=\(safeLimit)")
        return response.collections
    }

    func updateMealPlanGroceryChecked(planId: String, checkedItems: [String]) async throws -> MealPlanPayload {
        let encodedPlanId = planId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? planId
        return try await post("/meal-plan/\(encodedPlanId)/grocery-check", json: [
            "checked_items": checkedItems
        ])
    }

    func deleteMealPlan(planId: String) async throws -> MealPlanDeleteResponse {
        let encodedPlanId = planId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? planId
        return try await delete("/meal-plan/\(encodedPlanId)", json: [:])
    }

    func generateMealPlan(
        dailyCalories: Int,
        days: Int,
        goalType: String,
        mealsPerDay: Int,
        prepTimeMinutes: Int,
        preferences: String,
        avoidIngredients: [String]
    ) async throws -> MealPlanPayload {
        let macros: (protein: Int, carbs: Int, fat: Int)
        switch goalType {
        case "muscle_gain":
            macros = (28, 45, 27)
        case "maintain":
            macros = (25, 45, 30)
        default:
            macros = (32, 40, 28)
        }
        return try await post("/meal-plan/generate", json: [
            "daily_calories": dailyCalories,
            "days": days,
            "goal_type": goalType,
            "meals_per_day": mealsPerDay,
            "prep_time_minutes": prepTimeMinutes,
            "preferences": preferences,
            "avoid_ingredients": avoidIngredients,
            "protein_pct": macros.protein,
            "carbs_pct": macros.carbs,
            "fat_pct": macros.fat,
        ])
    }
    func swapMeal(
        planId: String,
        day: String,
        meal: MealPlanMeal,
        dailyTargets: MealPlanTargets?,
        preferences: String,
        avoidIngredients: [String]
    ) async throws -> MealSwapResponse {
        let currentMeal: [String: Any] = [
            "meal_type": meal.mealType ?? "",
            "label": meal.label ?? "",
            "name": meal.name,
            "calories": meal.calories,
            "protein": meal.protein,
            "carbs": meal.carbs,
            "fat": meal.fat,
            "fiber": meal.fiber ?? 0,
            "sugar": meal.sugar ?? 0,
            "sodium": meal.sodium ?? 0,
            "prep_time_minutes": meal.prepTimeMinutes ?? 20,
            "ingredients": meal.ingredients,
            "reason": meal.reason ?? "",
            "source": meal.source ?? "",
        ]
        let targets: [String: Any] = [
            "calories": dailyTargets?.calories ?? 0,
            "protein": dailyTargets?.protein ?? 0,
            "carbs": dailyTargets?.carbs ?? 0,
            "fat": dailyTargets?.fat ?? 0,
        ]
        let encodedPlanId = planId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? planId
        return try await post("/meal-plan/\(encodedPlanId)/swap-meal", json: [
            "current_meal": currentMeal,
            "day": day,
            "daily_targets": targets,
            "preferences": preferences,
            "avoid_ingredients": avoidIngredients,
        ])
    }
    func getTodayRecommendations(
        mealType: String = "dinner",
        prepTimeMinutes: Int = 20,
        limit: Int = 3,
        useAI: Bool = true
    ) async throws -> TodayRecommendationsResponse {
        try await post("/recommendations/today", json: [
            "meal_type": mealType,
            "prep_time_minutes": prepTimeMinutes,
            "limit": limit,
            "use_ai": useAI,
        ])
    }
    func logRecommendation(
        id: String,
        portionMultiplier: Double = 1,
        mealCategory: String = ""
    ) async throws -> RecommendationLogResponse {
        try await post("/recommendations/\(id)/log", json: [
            "portion_multiplier": portionMultiplier,
            "meal_category": mealCategory,
        ])
    }
    func chatCoach(message: String, mealType: String = "") async throws -> CoachChatResponse {
        var payload: [String: Any] = ["message": message]
        if !mealType.isEmpty {
            payload["meal_type"] = mealType
        }
        return try await post("/coach/chat", json: payload)
    }
    func applyCoachAction(_ action: CoachAction) async throws -> CoachApplyResponse {
        var actionPayload: [String: Any] = [
            "type": action.type,
            "label": action.label,
        ]
        if let id = action.id { actionPayload["id"] = id }
        if let description = action.description { actionPayload["description"] = description }
        if let payload = action.payload {
            actionPayload["payload"] = payload.mapValues { $0.anyValue }
        }
        return try await post("/coach/actions/apply", json: ["action": actionPayload])
    }
    func createDeliveryDraft(
        recommendationId: String,
        portionMultiplier: Double = 1,
        provider: String = "auto"
    ) async throws -> DeliveryDraftResponse {
        try await post("/recommendations/\(recommendationId)/delivery-draft", json: [
            "portion_multiplier": portionMultiplier,
            "provider": provider,
        ])
    }
    func getDeliveryRecommendations(
        tastes: [String],
        mealTypes: [String],
        platform: String,
        budget: String,
        deliveryTime: String,
        restrictions: [String],
        variant: Int = 0,
        limit: Int = 3
    ) async throws -> DeliveryRecommendationsResponse {
        try await post("/delivery/recommendations", json: [
            "tastes": tastes,
            "meal_types": mealTypes,
            "platform": platform,
            "budget": budget,
            "delivery_time": deliveryTime,
            "restrictions": restrictions,
            "variant": variant,
            "limit": limit,
        ])
    }
    func getDeliveryDrafts(date: String = "", limit: Int = 20) async throws -> [DeliveryOrderDraft] {
        let query = date.isEmpty ? "limit=\(limit)" : "date=\(date)&limit=\(limit)"
        let response: DeliveryDraftsResponse = try await get("/delivery/drafts?\(query)")
        return response.drafts
    }
    func buildRecipesFromIngredients(
        ingredients: String,
        imageBase64: String? = nil,
        servings: Int = 1,
        limit: Int = 3,
        useAI: Bool = true,
        date: String = ""
    ) async throws -> IngredientRecipesResponse {
        var payload: [String: Any] = [
            "ingredients": ingredients,
            "servings": servings,
            "limit": limit,
            "use_ai": useAI,
        ]
        if let imageBase64, !imageBase64.isEmpty {
            payload["image_base64"] = imageBase64
        }
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/recipes/from-ingredients", json: payload)
    }
    func importRecipeFromURL(_ urlString: String) async throws -> RecipeURLImportResponse {
        try await post("/recipe/import", json: ["url": urlString])
    }
    func getIngredientRecipeSuggestions(limit: Int = 10, query: String = "", sort: String = "created", offset: Int = 0, favorite: Bool = false, imported: Bool = false, mealType: String = "", tag: String = "") async throws -> [IngredientRecipeHistoryItem] {
        var path = "/recipes/suggestions?limit=\(limit)&sort=\(sort)&offset=\(max(0, offset))"
        if favorite {
            path += "&favorite=true"
        }
        if imported {
            path += "&imported=true"
        }
        let cleanMealType = mealType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanMealType.isEmpty {
            path += "&meal_type=\(cleanMealType.urlQueryEscaped)"
        }
        let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTag.isEmpty {
            path += "&tag=\(cleanTag.urlQueryEscaped)"
        }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanQuery.isEmpty {
            path += "&query=\(cleanQuery.urlQueryEscaped)"
        }
        let response: IngredientRecipeHistoryResponse = try await get(path)
        return response.recipes
    }
    func createIngredientRecipeSuggestion(recipePayload: [String: Any], date: String = "", source: String = "manual") async throws -> IngredientRecipeUpdateResponse {
        var payload: [String: Any] = [
            "recipe": recipePayload,
            "source": source,
        ]
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/recipes/suggestions", json: payload)
    }
    func logIngredientRecipe(
        id: String,
        portionMultiplier: Double = 1,
        servingSizeLabel: String? = nil,
        mealCategory: String = "dinner",
        date: String = ""
    ) async throws -> IngredientRecipeLogResponse {
        var payload: [String: Any] = [
            "portion_multiplier": portionMultiplier,
            "meal_category": mealCategory,
        ]
        if let servingSizeLabel, !servingSizeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["serving_size_label"] = servingSizeLabel
        }
        if !date.isEmpty {
            payload["date"] = date
        }
        return try await post("/recipes/\(id)/log", json: payload)
    }
    func deleteIngredientRecipeSuggestion(id: String) async throws -> IngredientRecipeDeleteResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await delete("/recipes/suggestions/\(encodedId)", json: [:])
    }
    func updateIngredientRecipeSuggestion(id: String, recipePayload: [String: Any]) async throws -> IngredientRecipeUpdateResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await put("/recipes/suggestions/\(encodedId)", json: ["recipe": recipePayload])
    }
    func toggleIngredientRecipeFavorite(id: String) async throws -> IngredientRecipeUpdateResponse {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await post("/recipes/suggestions/\(encodedId)/favorite", json: [:])
    }
    func getReminders() async throws -> [ReminderItem] {
        let response: RemindersResponse = try await get("/reminders")
        return response.reminders
    }
    func saveReminders(_ reminders: [ReminderItem]) async throws -> [ReminderItem] {
        let response: RemindersResponse = try await post("/reminders", json: [
            "reminders": reminders.map { $0.savePayload },
        ])
        return response.reminders
    }
    func joinChallenge(id: String) async throws -> Challenge {
        try await post("/challenges/\(id)/join", json: [:])
    }
    func refreshChallenge(id: String) async throws -> Challenge {
        try await post("/challenges/\(id)/refresh", json: [:])
    }
    func sendFriendRequest(fromUser: String = "me", toUser: String) async throws {
        try await post("/friends/request", json: [
            "from_user": fromUser,
            "to_user": toUser,
        ])
    }
    func shareDailyCheckin(user: String = "me", visibility: String = "friends", caption: String = "今日状态打卡") async throws -> CommunityActionResponse {
        try await post("/community/posts/daily-checkin", json: [
            "user": user,
            "visibility": visibility,
            "caption": caption,
        ])
    }
    func shareMealToCommunity(
        uploadGroupId: String,
        user: String = "me",
        visibility: String = "friends",
        caption: String = "",
        tags: [String] = []
    ) async throws -> CommunityActionResponse {
        try await post("/community/posts/from-meal-log", json: [
            "upload_group_id": uploadGroupId,
            "user": user,
            "visibility": visibility,
            "caption": caption,
            "tags": tags,
        ])
    }
    func reactCommunityPost(id: String, user: String = "me", reaction: String = "like") async throws -> CommunityActionResponse {
        try await post("/community/posts/\(id)/reactions", json: [
            "user": user,
            "reaction": reaction,
        ])
    }
    func commentCommunityPost(id: String, user: String = "me", body: String) async throws -> CommunityActionResponse {
        try await post("/community/posts/\(id)/comments", json: [
            "user": user,
            "body": body,
        ])
    }
    func bookmarkCommunityPost(id: String, user: String = "me") async throws -> CommunityActionResponse {
        try await post("/community/posts/\(id)/bookmark", json: ["user": user])
    }
    func reportCommunityPost(id: String, user: String = "me", reason: String = "不感兴趣") async throws -> CommunityActionResponse {
        try await post("/community/posts/\(id)/report", json: [
            "user": user,
            "reason": reason,
        ])
    }
    func logSameCommunityMeal(id: String, user: String = "me", mealCategory: String = "") async throws -> CommunityActionResponse {
        try await post("/community/posts/\(id)/log-same-meal", json: [
            "user": user,
            "meal_category": mealCategory,
        ])
    }
    func getFastingPreferences() async throws -> FastingPreferences {
        try await get("/fasting/preferences")
    }
    func getFastingStatus() async throws -> FastingStatus { try await get("/fasting/status") }
    func getFastingHistory(days: Int = 30) async throws -> FastingHistory { try await get("/fasting/history?days=\(days)") }
    func saveFastingPreferences(_ prefs: FastingPreferences) async throws -> FastingPreferences {
        try await put("/fasting/preferences", json: [
            "enabled": prefs.enabled,
            "method": prefs.method,
            "fasting_hours": prefs.fastingHours,
            "eating_hours": prefs.eatingHours,
            "eating_window_start": prefs.eatingWindowStart,
            "reminders_enabled": prefs.remindersEnabled,
            "timezone": prefs.timezone,
        ])
    }
    func startFasting(method: String, fastingHours: Double) async throws -> FastingStatus {
        try await post("/fasting/start", json: [
            "method": method,
            "fasting_hours": fastingHours,
        ])
    }
    func endFasting(notes: String = "") async throws -> FastingStatus {
        try await post("/fasting/end", json: ["notes": notes])
    }
    func cancelFasting() async throws -> FastingStatus {
        try await post("/fasting/cancel", json: [:])
    }
    func addManualFasting(startAt: Date, endedAt: Date, method: String, fastingHours: Double, notes: String = "") async throws -> FastingHistory {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try await post("/fasting/manual", json: [
            "method": method,
            "fasting_hours": fastingHours,
            "start_at": formatter.string(from: startAt),
            "ended_at": formatter.string(from: endedAt),
            "notes": notes,
        ])
    }
    func saveGoalPlan(_ p: GoalPlanRequest) async throws {
        try await post("/goal-plan", json: [
            "current_weight_kg": p.currentWeightKg, "goal_weight_kg": p.goalWeightKg,
            "height_cm": p.heightCm, "age": p.age, "gender": p.gender,
            "activity": p.activity, "deficit_pct": p.deficitPct
        ])
    }
    func saveMacroGoals(_ goals: MacroGoals) async throws {
        try await post("/macro-goals", json: [
            "daily_calories": goals.dailyCalories,
            "protein_g": goals.proteinG,
            "carbs_g": goals.carbsG,
            "fat_g": goals.fatG,
            "fiber_g": goals.fiberG,
            "sugar_g": goals.sugarG,
            "sodium_mg": goals.sodiumMg,
            "water_ml": goals.waterMl,
            "meal_shares": goals.mealShares,
        ])
    }
    // Fix describeMeal - it's a POST that returns data
    func describeMealGet(imageBase64: String) async throws -> DescribeMealResponse {
        try await describeMeal(imageBase64: imageBase64)
    }

    func describeMealGet(capture: MealCapture) async throws -> DescribeMealResponse {
        if capture.depthBundle != nil {
            try await requireGPUVisionPipeline()
            return try await analyzeDepthBundleAsDescribeMeal(capture: capture)
        }
        return try await analyzeVisionImageAsDescribeMeal(capture: capture)
    }

    func describeMealStream(
        capture: MealCapture,
        onEvent: @escaping ([String: Any]) -> Void
    ) async throws -> DescribeMealResponse {
        if capture.depthBundle != nil {
            try await requireGPUVisionPipeline()
            return try await analyzeDepthBundleAsDescribeMeal(capture: capture, onEvent: onEvent)
        }
        return try await analyzeVisionImageAsDescribeMeal(capture: capture, onEvent: onEvent)
    }

    private func describePhotoOnlyMeal(
        capture: MealCapture,
        onEvent: (([String: Any]) -> Void)? = nil
    ) async throws -> DescribeMealResponse {
        try await analyzeVisionImageAsDescribeMeal(capture: capture, onEvent: onEvent)
    }

    private func analyzeVisionImageAsDescribeMeal(
        capture: MealCapture,
        onEvent: (([String: Any]) -> Void)? = nil
    ) async throws -> DescribeMealResponse {
        guard !capture.imageBase64.isEmpty else {
            throw APIError.server("这次没有拿到照片，请重新拍一张或手动补记。")
        }

        onEvent?(["stage": "vision_started", "message": "正在识别可见食物和估算营养"])
        var metadata = capture.captureMetadata
        metadata["has_depth"] = false
        metadata["capture_pipeline"] = "qwen_vl_direct_nutrition"
        var payload: [String: Any] = [
            "source": "library",
            "image_base64": capture.imageBase64,
            "capture_metadata": metadata,
        ]
        if let depthMetadata = capture.depthMetadata {
            payload["depth_metadata"] = depthMetadata
        }

        var req = URLRequest(url: URL(string: base + "/describeMeal")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 180
        let (data, response) = try await perform(req)
        try validate(response: response, data: data)
        let result = try decodeResponse(DescribeMealResponse.self, from: data)
        onEvent?([
            "stage": "final",
            "items": result.foods.map { ["name": $0.name] },
            "message": "识别出 \(result.foods.count) 项食物",
        ])
        return result
    }

    private func requireGPUVisionPipeline() async throws {
        guard let health = try? await getDepthPipelineHealth(),
              health.depthPipeline?.cloudPipeline?.reachable == true
        else {
            throw APIError.server("GPU 食物识别服务暂时不可用，请稍后重试。照片不会切换到其他模型。")
        }
    }

    private func analyzePlatformImageAsDescribeMeal(
        capture: MealCapture,
        onEvent: (([String: Any]) -> Void)? = nil
    ) async throws -> DescribeMealResponse {
        guard !capture.imageBase64.isEmpty else {
            throw APIError.server("这次没有拿到照片，请重新拍一张或手动补记。")
        }
        onEvent?(["stage": "uploading_rgb", "message": "正在上传照片，马上开始识别"])
        let sourceImageData = try Self.imageData(fromBase64: capture.imageBase64)
        let imageData = try Self.platformUploadJPEGData(from: sourceImageData)
        let imageSize = Self.imageSize(from: imageData)
        var metadata = capture.captureMetadata
        metadata["has_depth"] = false
        metadata["capture_pipeline"] = "cloud_rgb_groundingdino_sam2_visual_volume"
        metadata["depth_source"] = "platform_rgb_only"
        if let width = imageSize?.width { metadata["image_width"] = width }
        if let height = imageSize?.height { metadata["image_height"] = height }
        let source = (metadata["source"] as? String) ?? "library"
        let captureId = try await createMealCapture(depthSource: "platform_rgb_only", mealType: "photo")
        _ = try await uploadCaptureFile(captureId: captureId, kind: "rgb", data: imageData, contentType: "image/jpeg")
        let auxiliaryCount = try await uploadAuxiliaryImages(capture, captureId: captureId)
        metadata["auxiliary_image_count"] = auxiliaryCount
        metadata["auxiliary_image_role"] = "identity_nutrition_label_scale_other_angle_only"
        let metadataPayload: [String: Any] = [
            "capture": metadata,
            "rgb": [
                "width": imageSize?.width ?? 0,
                "height": imageSize?.height ?? 0,
                "source": source == "label_scan" ? "library" : source
            ],
            "depth": [
                "available": false,
                "source": "platform_rgb_only"
            ],
            "depth_source": "platform_rgb_only",
            "has_depth": false
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadataPayload, options: [.prettyPrinted, .sortedKeys])
        _ = try await uploadCaptureFile(captureId: captureId, kind: "metadata", data: metadataData, contentType: "application/json")

        onEvent?([
            "stage": "analyzing_rgb",
            "message": auxiliaryCount > 0 ? "正在结合主图和辅助图识别食物" : "正在用云端模型识别食物和估算份量"
        ])
        let task = try await analyzeDepthCapture(
            captureId: captureId,
            userHint: "平台/图库普通食物照片，请识别可见食物，并用视觉线索估算体积和份量",
            mealType: "photo"
        )
        guard let jobId = task["job_id"] as? String else {
            throw APIError.server("照片分析没开始。重新选一张，或先手动补记。")
        }

        for _ in 0..<30 {
            let job = try await getDepthJob(jobId: jobId)
            let status = String(describing: job["status"] ?? "")
            let progress = (job["progress"] as? Double) ?? 0
            onEvent?([
                "stage": status,
                "progress": progress,
                "message": status == "completed" ? "这餐算好了" : "正在分析这餐"
            ])
            if status == "completed" {
                guard
                    let result = job["result"] as? [String: Any],
                    result["meal_id"] is String
                else {
                    throw APIError.server("这次没有生成餐食结果，请重新选一张更完整的照片。")
                }
                let foods = Self.foodItems(
                    fromDepthMealResult: result,
                    imageWidth: imageSize.map { Double($0.width) },
                    imageHeight: imageSize.map { Double($0.height) }
                )
                onEvent?([
                    "stage": "vision_items",
                    "items": foods.map { ["name": $0.name] }
                ])
                guard !foods.isEmpty else {
                    throw APIError.server("这张照片没识别出可记录的食物，请让整份食物和碗盘边缘都入镜。")
                }
                return DescribeMealResponse(
                    foods: foods,
                    healthScore: nil,
                    description: Self.depthDescription(from: result),
                    decision: nil
                )
            }
            if status == "failed" {
                throw APIError.server(String(describing: job["message"] ?? "这次没算出来，请换一张照片。"))
            }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        throw APIError.server("这次分析等太久了，重新选一张或先手动补记。")
    }

    func lookupBarcode(_ barcode: String) async throws -> DescribeMealResponse {
        try await post("/describeMeal", json: [
            "source": "barcode_scan",
            "barcode": barcode,
        ])
    }

    private func parseSSEEvent(_ block: String) -> [String: Any]? {
        let text = block
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let originalError {
            guard let repaired = Self.repairedJSONData(data) else {
                throw APIError.server("返回数据没有完整传回来，请再试一次。\n\(originalError.localizedDescription)")
            }
            do {
                return try JSONDecoder().decode(type, from: repaired)
            } catch {
                throw APIError.server("返回数据暂时无法读取，请再试一次。")
            }
        }
    }

    private static func repairedJSONData(_ data: Data) -> Data? {
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        text = String(text[start...])
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var lastCompleteIndex: String.Index?
        for index in text.indices {
            let char = text[index]
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }
            if char == "{" || char == "[" {
                stack.append(char)
            } else if char == "}" || char == "]" {
                guard let open = stack.last,
                      (open == "{" && char == "}") || (open == "[" && char == "]")
                else { continue }
                stack.removeLast()
                if stack.isEmpty { lastCompleteIndex = index; break }
            }
        }
        if let lastCompleteIndex {
            text = String(text[...lastCompleteIndex])
        } else {
            guard !inString else { return nil }
            for open in stack.reversed() {
                text.append(open == "{" ? "}" : "]")
            }
        }
        return text.data(using: .utf8)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let retryableStatusCodes: Set<Int> = [429, 503, 529]
        let method = (request.httpMethod ?? "GET").uppercased()
        let path = request.url?.path.lowercased() ?? ""
        let retrySafe = ["GET", "HEAD", "PUT", "DELETE"].contains(method)
            || path.contains("describemeal")
            || path.contains("/analyze")
            || path.contains("/depth-meal")
        let delays: [UInt64] = [1, 2, 4]
        var lastConnectionError: URLError?

        for attempt in 0...delays.count {
            do {
                let result = try await URLSession.shared.data(for: request)
                if retrySafe,
                   attempt < delays.count,
                   let http = result.1 as? HTTPURLResponse,
                   retryableStatusCodes.contains(http.statusCode) {
                    try await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
                    continue
                }
                return result
            } catch let error as URLError {
                lastConnectionError = error
                if retrySafe, attempt < delays.count {
                    try await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
                    continue
                }
                print("[Cal AI API] request failed url=\(request.url?.absoluteString ?? "nil") code=\(error.code.rawValue) base=\(base)")
                throw APIError.connection(base: base, code: error.code)
            } catch {
                print("[Cal AI API] request failed url=\(request.url?.absoluteString ?? "nil") error=\(error.localizedDescription) base=\(base)")
                throw error
            }
        }
        throw APIError.connection(base: base, code: lastConnectionError?.code ?? .cannotConnectToHost)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw APIError.server(message)
        }
    }
}

enum APIError: LocalizedError {
    case server(String)
    case connection(base: String, code: URLError.Code)

    var errorDescription: String? {
        switch self {
        case .server(let message):
            return Self.readableServerMessage(message)
        case .connection(_, _):
            return "现在没连上。请检查网络后再试。"
        }
    }

    private static func readableServerMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "这次没有处理成功，请稍后再试。"
        }

        let extracted = extractJSONMessage(from: trimmed) ?? trimmed
        let lower = extracted.lowercased()

        if lower.contains("could not connect") || lower.contains("connection") || lower.contains("connecterror") {
            return "现在没连上。请检查网络后再试。"
        }
        if lower.contains("depth") || lower.contains("lidar") || lower.contains("深度") || lower.contains("估重信息") {
            return "这次照片信息不完整。点拍新照片会更稳。"
        }
        if lower.contains("not found") || lower.contains("404") {
            return "这次没接上。再点一次，或稍后重试。"
        }
        if lower.contains("internal server error") || lower.contains("500") {
            return "刚才没处理成功，再点刚才的按钮。"
        }
        if lower.contains("bad gateway") || lower.contains("502") || lower.contains("service unavailable") || lower.contains("503") {
            return "现在有点忙，等几秒再点刚才的按钮。"
        }
        if lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("401") || lower.contains("403") {
            return "拍照权限还没准备好。先到设置里检测一次，或回到加号手动补记。"
        }
        if lower.contains("unprocessable") || lower.contains("validation") || lower.contains("422") || lower.contains("missing field") {
            return "这次信息不完整。重新拍一张，或先手动补记。"
        }
        if lower.contains("cloud")
            || lower.contains("gpu")
            || lower.contains("model")
            || lower.contains("glm")
            || lower.contains("qwen")
            || lower.contains("mimo")
            || lower.contains("sam2")
            || lower.contains("grounding")
            || extracted.contains("云端")
            || extracted.contains("模型")
            || extracted.contains("拍照估重")
            || extracted.contains("基础服务") {
            return "扫描食物还没准备好。检查网络后再点扫描食物，或先手动补记这餐。"
        }
        if lower.hasPrefix("{")
            || lower.hasPrefix("[")
            || lower.contains("http://")
            || lower.contains("https://")
            || lower.contains("traceback")
            || lower.contains("metadata")
            || lower.contains("capture_pipeline")
            || lower.contains("image_scan")
            || lower.contains("has_depth")
            || lower.contains("api")
            || lower.contains("pipeline")
            || lower.contains("endpoint")
            || lower.contains("http ")
            || lower.contains("input/output")
            || lower.contains("errno") {
            return "这次没处理好。重新拍一张通常可以，赶时间也可以先手动补记。"
        }

        return extracted
    }

    private static func extractJSONMessage(from raw: String) -> String? {
        guard let start = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        let jsonText = String(raw[start...])
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let dict = object as? [String: Any] {
            for key in ["detail", "message", "error"] {
                if let value = dict[key] as? String, !value.isEmpty {
                    return value
                }
                if let array = dict[key] as? [[String: Any]], let first = array.first {
                    for nestedKey in ["msg", "message", "detail", "error", "type"] {
                        if let value = first[nestedKey] as? String, !value.isEmpty {
                            return value
                        }
                    }
                }
                if let nested = dict[key] as? [String: Any] {
                    for nestedKey in ["message", "detail", "error"] {
                        if let value = nested[nestedKey] as? String, !value.isEmpty {
                            return value
                        }
                    }
                }
            }
        }

        if let array = object as? [[String: Any]],
           let first = array.first {
            for key in ["message", "detail", "error"] {
                if let value = first[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }

        return nil
    }
}

struct WaterResp: Codable { let total_ml: Double }

private extension String {
    var urlQueryEscaped: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
