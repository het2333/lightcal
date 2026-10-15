import Foundation

func isConnectionFailureMessage(_ value: String) -> Bool {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    return lower.contains("could not connect")
        || lower.contains("connection")
        || lower.contains("timed out")
        || lower.contains("offline")
        || lower.contains("network")
        || lower.contains("urlsession")
        || text.contains("连接不到")
        || text.contains("无法连接")
        || text.contains("没连上")
        || text.contains("检查网络")
}

struct MealCapture {
    let imageBase64: String
    let depthMetadata: [String: Any]?
    let captureMetadata: [String: Any]
    var auxiliaryImagesBase64: [String] = []
    var depthBundle: MealCaptureBundle? = nil

    var hasDepthCaptureBundle: Bool {
        depthBundle != nil
    }
}

struct MealAnalysisJob: Identifiable {
    enum Status {
        case running
        case ready
        case failed
    }

    let id: String
    let imageBase64: String
    let capture: MealCapture?
    var progress: Double
    var status: Status
    var message: String
    var result: DescribeMealResponse? = nil
    var startedAt: Date = Date()
}

// MARK: - Food & Meals
struct FoodItem: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var sugar: Double = 0
    var sodium: Double = 0
    var servingSize: String = "100g"
    var processingLevel: String = "whole"
    var addedSugar: Double = 0
    var satFat: Double = 0
    var transFat: Double = 0
    var cholesterol: Double = 0
    var vitaminA: Double = 0
    var vitaminC: Double = 0
    var calcium: Double = 0
    var iron: Double = 0
    var potassium: Double = 0
    var magnesium: Double = 0
    var zinc: Double = 0
    var folate: Double = 0
    var vitaminD: Double = 0
    var vitaminB12: Double = 0
    var vitaminE: Double = 0
    var vitaminK: Double = 0
    var omega3: Double = 0
    var monounsaturatedFat: Double = 0
    var polyunsaturatedFat: Double = 0
    var gramsPerUnit: Double = 100
    var quantityCount: Double? = nil
    var quantityUnit: String = ""
    var quantityDescription: String = ""
    var consumedRatio: Double = 1
    var barcode: String = ""
    var nutritionSource: String = ""
    var date: String? = nil
    var depthMealId: String? = nil
    var depthItemId: String? = nil
    var depthVolumeMl: Double? = nil
    var depthVolumeMethod: String? = nil
    var depthSource: String? = nil
    var depthVolumeConfidence: Double? = nil
    var depthFallback: Bool? = nil
    var depthFallbackReason: String? = nil
    var depthMaskUrl: String? = nil
    var depthMaskPreviewBase64: String? = nil
    var depthMaskAreaPixels: Double? = nil
    var depthMaskConfidence: Double? = nil
    var depthDensity: Double? = nil
    var depthDensitySource: String? = nil
    var depthBbox: [Double]? = nil
    var depthImageWidth: Double? = nil
    var depthImageHeight: Double? = nil
    var depthSemanticIsFood: Bool? = nil
    var depthSemanticConfidence: Double? = nil
    var depthSemanticNeedsSplit: Bool? = nil
    var depthSemanticNotes: [String]? = nil

    init(
        id: String = UUID().uuidString,
        name: String,
        calories: Double = 0,
        protein: Double = 0,
        carbs: Double = 0,
        fat: Double = 0,
        fiber: Double = 0,
        sugar: Double = 0,
        sodium: Double = 0,
        servingSize: String = "100g",
        processingLevel: String = "whole",
        addedSugar: Double = 0,
        satFat: Double = 0,
        transFat: Double = 0,
        cholesterol: Double = 0,
        vitaminA: Double = 0,
        vitaminC: Double = 0,
        calcium: Double = 0,
        iron: Double = 0,
        potassium: Double = 0,
        magnesium: Double = 0,
        zinc: Double = 0,
        folate: Double = 0,
        vitaminD: Double = 0,
        vitaminB12: Double = 0,
        vitaminE: Double = 0,
        vitaminK: Double = 0,
        omega3: Double = 0,
        monounsaturatedFat: Double = 0,
        polyunsaturatedFat: Double = 0,
        gramsPerUnit: Double = 100,
        quantityCount: Double? = nil,
        quantityUnit: String = "",
        quantityDescription: String = "",
        consumedRatio: Double = 1,
        barcode: String = "",
        nutritionSource: String = "",
        date: String? = nil,
        depthMealId: String? = nil,
        depthItemId: String? = nil,
        depthVolumeMl: Double? = nil,
        depthVolumeMethod: String? = nil,
        depthSource: String? = nil,
        depthVolumeConfidence: Double? = nil,
        depthFallback: Bool? = nil,
        depthFallbackReason: String? = nil,
        depthMaskUrl: String? = nil,
        depthMaskPreviewBase64: String? = nil,
        depthMaskAreaPixels: Double? = nil,
        depthMaskConfidence: Double? = nil,
        depthDensity: Double? = nil,
        depthDensitySource: String? = nil,
        depthBbox: [Double]? = nil,
        depthImageWidth: Double? = nil,
        depthImageHeight: Double? = nil,
        depthSemanticIsFood: Bool? = nil,
        depthSemanticConfidence: Double? = nil,
        depthSemanticNeedsSplit: Bool? = nil,
        depthSemanticNotes: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
        self.servingSize = servingSize
        self.processingLevel = processingLevel
        self.addedSugar = addedSugar
        self.satFat = satFat
        self.transFat = transFat
        self.cholesterol = cholesterol
        self.vitaminA = vitaminA
        self.vitaminC = vitaminC
        self.calcium = calcium
        self.iron = iron
        self.potassium = potassium
        self.magnesium = magnesium
        self.zinc = zinc
        self.folate = folate
        self.vitaminD = vitaminD
        self.vitaminB12 = vitaminB12
        self.vitaminE = vitaminE
        self.vitaminK = vitaminK
        self.omega3 = omega3
        self.monounsaturatedFat = monounsaturatedFat
        self.polyunsaturatedFat = polyunsaturatedFat
        self.gramsPerUnit = gramsPerUnit
        self.quantityCount = quantityCount
        self.quantityUnit = quantityUnit
        self.quantityDescription = quantityDescription
        self.consumedRatio = consumedRatio
        self.barcode = barcode
        self.nutritionSource = nutritionSource
        self.date = date
        self.depthMealId = depthMealId
        self.depthItemId = depthItemId
        self.depthVolumeMl = depthVolumeMl
        self.depthVolumeMethod = depthVolumeMethod
        self.depthSource = depthSource
        self.depthVolumeConfidence = depthVolumeConfidence
        self.depthFallback = depthFallback
        self.depthFallbackReason = depthFallbackReason
        self.depthMaskUrl = depthMaskUrl
        self.depthMaskPreviewBase64 = depthMaskPreviewBase64
        self.depthMaskAreaPixels = depthMaskAreaPixels
        self.depthMaskConfidence = depthMaskConfidence
        self.depthDensity = depthDensity
        self.depthDensitySource = depthDensitySource
        self.depthBbox = depthBbox
        self.depthImageWidth = depthImageWidth
        self.depthImageHeight = depthImageHeight
        self.depthSemanticIsFood = depthSemanticIsFood
        self.depthSemanticConfidence = depthSemanticConfidence
        self.depthSemanticNeedsSplit = depthSemanticNeedsSplit
        self.depthSemanticNotes = depthSemanticNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
        carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
        fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
        fiber = try container.decodeIfPresent(Double.self, forKey: .fiber) ?? 0
        sugar = try container.decodeIfPresent(Double.self, forKey: .sugar) ?? 0
        sodium = try container.decodeIfPresent(Double.self, forKey: .sodium) ?? 0
        servingSize = try container.decodeIfPresent(String.self, forKey: .servingSize) ?? "100g"
        processingLevel = try container.decodeIfPresent(String.self, forKey: .processingLevel) ?? "whole"
        addedSugar = try container.decodeIfPresent(Double.self, forKey: .addedSugar) ?? 0
        satFat = try container.decodeIfPresent(Double.self, forKey: .satFat) ?? 0
        transFat = try container.decodeIfPresent(Double.self, forKey: .transFat) ?? 0
        cholesterol = try container.decodeIfPresent(Double.self, forKey: .cholesterol) ?? 0
        vitaminA = try container.decodeIfPresent(Double.self, forKey: .vitaminA) ?? 0
        vitaminC = try container.decodeIfPresent(Double.self, forKey: .vitaminC) ?? 0
        calcium = try container.decodeIfPresent(Double.self, forKey: .calcium) ?? 0
        iron = try container.decodeIfPresent(Double.self, forKey: .iron) ?? 0
        potassium = try container.decodeIfPresent(Double.self, forKey: .potassium) ?? 0
        magnesium = try container.decodeIfPresent(Double.self, forKey: .magnesium) ?? 0
        zinc = try container.decodeIfPresent(Double.self, forKey: .zinc) ?? 0
        folate = try container.decodeIfPresent(Double.self, forKey: .folate) ?? 0
        vitaminD = try container.decodeIfPresent(Double.self, forKey: .vitaminD) ?? 0
        vitaminB12 = try container.decodeIfPresent(Double.self, forKey: .vitaminB12) ?? 0
        vitaminE = try container.decodeIfPresent(Double.self, forKey: .vitaminE) ?? 0
        vitaminK = try container.decodeIfPresent(Double.self, forKey: .vitaminK) ?? 0
        omega3 = try container.decodeIfPresent(Double.self, forKey: .omega3) ?? 0
        monounsaturatedFat = try container.decodeIfPresent(Double.self, forKey: .monounsaturatedFat) ?? 0
        polyunsaturatedFat = try container.decodeIfPresent(Double.self, forKey: .polyunsaturatedFat) ?? 0
        gramsPerUnit = try container.decodeIfPresent(Double.self, forKey: .gramsPerUnit) ?? 100
        quantityCount = try container.decodeIfPresent(Double.self, forKey: .quantityCount)
        quantityUnit = try container.decodeIfPresent(String.self, forKey: .quantityUnit) ?? ""
        quantityDescription = try container.decodeIfPresent(String.self, forKey: .quantityDescription) ?? ""
        consumedRatio = try container.decodeIfPresent(Double.self, forKey: .consumedRatio) ?? 1
        barcode = try container.decodeIfPresent(String.self, forKey: .barcode) ?? ""
        nutritionSource = try container.decodeIfPresent(String.self, forKey: .nutritionSource) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date)
        depthMealId = try container.decodeIfPresent(String.self, forKey: .depthMealId)
        depthItemId = try container.decodeIfPresent(String.self, forKey: .depthItemId)
        depthVolumeMl = try container.decodeIfPresent(Double.self, forKey: .depthVolumeMl)
        depthVolumeMethod = try container.decodeIfPresent(String.self, forKey: .depthVolumeMethod)
        depthSource = try container.decodeIfPresent(String.self, forKey: .depthSource)
        depthVolumeConfidence = try container.decodeIfPresent(Double.self, forKey: .depthVolumeConfidence)
        depthFallback = try container.decodeIfPresent(Bool.self, forKey: .depthFallback)
        depthFallbackReason = try container.decodeIfPresent(String.self, forKey: .depthFallbackReason)
        depthMaskUrl = try container.decodeIfPresent(String.self, forKey: .depthMaskUrl)
        depthMaskPreviewBase64 = try container.decodeIfPresent(String.self, forKey: .depthMaskPreviewBase64)
        depthMaskAreaPixels = try container.decodeIfPresent(Double.self, forKey: .depthMaskAreaPixels)
        depthMaskConfidence = try container.decodeIfPresent(Double.self, forKey: .depthMaskConfidence)
        depthDensity = try container.decodeIfPresent(Double.self, forKey: .depthDensity)
        depthDensitySource = try container.decodeIfPresent(String.self, forKey: .depthDensitySource)
        depthBbox = try container.decodeIfPresent([Double].self, forKey: .depthBbox)
        depthImageWidth = try container.decodeIfPresent(Double.self, forKey: .depthImageWidth)
        depthImageHeight = try container.decodeIfPresent(Double.self, forKey: .depthImageHeight)
        depthSemanticIsFood = try container.decodeIfPresent(Bool.self, forKey: .depthSemanticIsFood)
        depthSemanticConfidence = try container.decodeIfPresent(Double.self, forKey: .depthSemanticConfidence)
        depthSemanticNeedsSplit = try container.decodeIfPresent(Bool.self, forKey: .depthSemanticNeedsSplit)
        depthSemanticNotes = try container.decodeIfPresent([String].self, forKey: .depthSemanticNotes)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, calories, protein, carbs, fat, fiber, sugar, sodium
        case servingSize = "serving_size"
        case processingLevel = "processing_level"
        case addedSugar = "added_sugar"
        case satFat = "sat_fat"
        case transFat = "trans_fat"
        case cholesterol
        case vitaminA = "vitamin_a"
        case vitaminC = "vitamin_c"
        case calcium
        case iron
        case potassium
        case magnesium, zinc, folate
        case vitaminD = "vitamin_d"
        case vitaminB12 = "vitamin_b12"
        case vitaminE = "vitamin_e"
        case vitaminK = "vitamin_k"
        case omega3 = "omega_3"
        case monounsaturatedFat = "monounsaturated_fat"
        case polyunsaturatedFat = "polyunsaturated_fat"
        case gramsPerUnit = "grams_per_unit"
        case quantityCount = "quantity_count"
        case quantityUnit = "quantity_unit"
        case quantityDescription = "quantity_description"
        case consumedRatio = "consumed_ratio"
        case barcode
        case nutritionSource = "nutrition_source"
        case date
        case depthMealId = "depth_meal_id"
        case depthItemId = "depth_item_id"
        case depthVolumeMl = "depth_volume_ml"
        case depthVolumeMethod = "depth_volume_method"
        case depthSource = "depth_source"
        case depthVolumeConfidence = "depth_volume_confidence"
        case depthFallback = "depth_fallback"
        case depthFallbackReason = "depth_fallback_reason"
        case depthMaskUrl = "depth_mask_url"
        case depthMaskPreviewBase64 = "depth_mask_preview_base64"
        case depthMaskAreaPixels = "depth_mask_area_pixels"
        case depthMaskConfidence = "depth_mask_confidence"
        case depthDensity = "depth_density"
        case depthDensitySource = "depth_density_source"
        case depthBbox = "depth_bbox"
        case depthImageWidth = "depth_image_width"
        case depthImageHeight = "depth_image_height"
        case depthSemanticIsFood = "depth_semantic_is_food"
        case depthSemanticConfidence = "depth_semantic_confidence"
        case depthSemanticNeedsSplit = "depth_semantic_needs_split"
        case depthSemanticNotes = "depth_semantic_notes"
    }
}

struct DescribeMealResponse: Codable {
    let foods: [FoodItem]
    let healthScore: HealthScore?
    let description: String?
    let decision: DecisionScoreResponse?

    enum CodingKeys: String, CodingKey {
        case foods, decision
        case healthScore = "health_score"
        case description
    }
}

struct FoodSearchResponse: Codable {
    let foods: [FoodItem]
    let query: String?
}

struct FoodLogResponse: Codable {
    let foods: [FoodLogRow]
    let date: String?
}

struct FrequentFoodsResponse: Codable {
    let foods: [FrequentFoodItem]
}

struct FrequentFoodItem: Codable, Identifiable {
    let id: String?
    let foodName: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let addedSugar: Double?
    let satFat: Double?
    let transFat: Double?
    let cholesterol: Double?
    let vitaminA: Double?
    let vitaminC: Double?
    let calcium: Double?
    let iron: Double?
    let potassium: Double?
    let magnesium: Double?
    let zinc: Double?
    let folate: Double?
    let vitaminD: Double?
    let vitaminB12: Double?
    let vitaminE: Double?
    let vitaminK: Double?
    let omega3: Double?
    let monounsaturatedFat: Double?
    let polyunsaturatedFat: Double?
    let servingSize: String?
    let gramsPerUnit: Double?
    let barcode: String?
    let nutritionSource: String?
    let processingLevel: String?
    let mealCategory: String?
    let logCount: Int?
    let lastLogged: String?

    enum CodingKeys: String, CodingKey {
        case id
        case foodName = "food_name"
        case calories, protein, carbs, fat, fiber, sugar, sodium, cholesterol, calcium, iron, potassium, magnesium, zinc, folate, barcode
        case addedSugar = "added_sugar"
        case satFat = "sat_fat"
        case transFat = "trans_fat"
        case vitaminA = "vitamin_a"
        case vitaminC = "vitamin_c"
        case vitaminD = "vitamin_d"
        case vitaminB12 = "vitamin_b12"
        case vitaminE = "vitamin_e"
        case vitaminK = "vitamin_k"
        case omega3 = "omega_3"
        case monounsaturatedFat = "monounsaturated_fat"
        case polyunsaturatedFat = "polyunsaturated_fat"
        case servingSize = "serving_size"
        case gramsPerUnit = "grams_per_unit"
        case nutritionSource = "nutrition_source"
        case processingLevel = "processing_level"
        case mealCategory = "meal_category"
        case logCount = "log_count"
        case lastLogged = "last_logged"
    }
}

struct FoodLogRow: Codable, Identifiable {
    let id: Int?
    let foodName: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let addedSugar: Double?
    let satFat: Double?
    let transFat: Double?
    let cholesterol: Double?
    let vitaminA: Double?
    let vitaminC: Double?
    let calcium: Double?
    let iron: Double?
    let potassium: Double?
    let magnesium: Double?
    let zinc: Double?
    let folate: Double?
    let vitaminD: Double?
    let vitaminB12: Double?
    let vitaminE: Double?
    let vitaminK: Double?
    let omega3: Double?
    let monounsaturatedFat: Double?
    let polyunsaturatedFat: Double?
    let servingSize: String?
    let gramsPerUnit: Double?
    let barcode: String?
    let nutritionSource: String?
    let date: String?
    let mealCategory: String?
    let uploadGroupId: String?
    let uploadGroupTitle: String?
    let imageUrl: String?
    let loggedAt: String?
    let quantityCount: Double?
    let quantityUnit: String?
    let quantityDescription: String?
    let originalCalories: Double?
    let leftoverCalories: Double?
    let consumedRatio: Double?
    let adjustedByLeftovers: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case foodName = "food_name"
        case calories, protein, carbs, fat, fiber, sugar, sodium, cholesterol, calcium, iron, potassium, magnesium, zinc, folate, barcode
        case addedSugar = "added_sugar"
        case satFat = "sat_fat"
        case transFat = "trans_fat"
        case vitaminA = "vitamin_a"
        case vitaminC = "vitamin_c"
        case vitaminD = "vitamin_d"
        case vitaminB12 = "vitamin_b12"
        case vitaminE = "vitamin_e"
        case vitaminK = "vitamin_k"
        case omega3 = "omega_3"
        case monounsaturatedFat = "monounsaturated_fat"
        case polyunsaturatedFat = "polyunsaturated_fat"
        case servingSize = "serving_size"
        case gramsPerUnit = "grams_per_unit"
        case nutritionSource = "nutrition_source"
        case date
        case mealCategory = "meal_category"
        case uploadGroupId = "upload_group_id"
        case uploadGroupTitle = "upload_group_title"
        case imageUrl = "image_url"
        case loggedAt = "logged_at"
        case quantityCount = "quantity_count"
        case quantityUnit = "quantity_unit"
        case quantityDescription = "quantity_description"
        case originalCalories = "original_calories"
        case leftoverCalories = "leftover_calories"
        case consumedRatio = "consumed_ratio"
        case adjustedByLeftovers = "adjusted_by_leftovers"
    }

    var displayName: String {
        let text = foodName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "未命名食物" : text
    }

    var displayServingSize: String {
        let text = servingSize?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "估算份量" : text
    }

    var displayQuantity: String {
        if let text = quantityDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        guard let count = quantityCount, count > 0 else { return "" }
        let rounded = (count * 10).rounded() / 10
        let countText = rounded.rounded() == rounded ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        let unit = quantityUnit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return unit.isEmpty ? countText : "\(countText)\(unit)"
    }

    var originalCalorieValue: Double {
        let value = originalCalories ?? calories ?? 0
        return max(0, value)
    }

    var consumedPercent: Int {
        if let consumedRatio {
            return max(0, min(2000, Int(round(consumedRatio * 100))))
        }
        let original = originalCalorieValue
        guard original > 0 else { return 100 }
        return max(0, min(2000, Int(round((calories ?? 0) / original * 100))))
    }

    var consumedRatioValue: Double {
        if let consumedRatio {
            return max(0, consumedRatio)
        }
        let original = originalCalorieValue
        guard original > 0 else { return 1 }
        return max(0, (calories ?? 0) / original)
    }

    var consumedPortionLabel: String {
        let ratio = consumedRatioValue
        if ratio >= 10 {
            return String(format: "%.1f倍", ratio)
        }
        return "\(Int(round(ratio * 100)))%"
    }
}

struct MealHistoryGroup: Identifiable {
    let id: String
    let title: String
    let names: [String]
    let count: Int
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let sugar: Double
    let sodium: Double
    let imageUrl: URL?
    let loggedAt: String?
    let foods: [FoodLogRow]
    let adjustedByLeftovers: Bool

    var displayTime: String {
        guard let loggedAt, !loggedAt.isEmpty else { return "" }
        let parts = loggedAt.split(separator: " ")
        let timeText = parts.last.map(String.init) ?? loggedAt
        return String(timeText.prefix(5))
    }

    var isAnalysisFailure: Bool {
        title == "这餐没算出来"
            && calories <= 0
            && protein <= 0
            && carbs <= 0
            && fat <= 0
    }
}

extension MealHistoryGroup {
    static func makeGroups(from rows: [FoodLogRow]) -> [MealHistoryGroup] {
        let grouped = Dictionary(grouping: rows) { row in
            let group = row.uploadGroupId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !group.isEmpty { return group }
            return "single-\(row.id ?? Int.random(in: 1...Int.max))"
        }

        return grouped.values.compactMap { items in
            guard let first = items.first else { return nil }
            let sorted = items.sorted { ($0.loggedAt ?? "") > ($1.loggedAt ?? "") }
            let rawNames = sorted.map { ($0.foodName ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let names = rawNames.compactMap { cleanedFoodDisplayText($0) }
            let rawTitleFromServer = first.uploadGroupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let titleFromServer = cleanedFoodDisplayText(rawTitleFromServer) ?? ""
            let hasFailureLikeText = isFailureLikeText(rawTitleFromServer)
                || rawNames.contains(where: isFailureLikeText)
            let title: String
            if !titleFromServer.isEmpty {
                title = titleFromServer
            } else if hasFailureLikeText {
                title = "这餐没算出来"
            } else if names.count <= 2 {
                title = names.joined(separator: " + ")
            } else {
                title = "\(names.prefix(2).joined(separator: " + "))等 \(names.count) 项"
            }
            return MealHistoryGroup(
                id: first.uploadGroupId?.isEmpty == false ? (first.uploadGroupId ?? "") : "single-\(first.id ?? 0)",
                title: title.isEmpty ? "餐食记录" : title,
                names: names,
                count: items.count,
                calories: items.reduce(0) { $0 + ($1.calories ?? 0) },
                protein: items.reduce(0) { $0 + ($1.protein ?? 0) },
                carbs: items.reduce(0) { $0 + ($1.carbs ?? 0) },
                fat: items.reduce(0) { $0 + ($1.fat ?? 0) },
                fiber: items.reduce(0) { $0 + ($1.fiber ?? 0) },
                sugar: items.reduce(0) { $0 + ($1.sugar ?? 0) },
                sodium: items.reduce(0) { $0 + ($1.sodium ?? 0) },
                imageUrl: APIClient.shared.assetURL(first.imageUrl),
                loggedAt: sorted.first?.loggedAt,
                foods: sorted,
                adjustedByLeftovers: sorted.contains { ($0.adjustedByLeftovers ?? 0) != 0 || ($0.leftoverCalories ?? 0) > 0 }
            )
        }
        .sorted { ($0.loggedAt ?? "") > ($1.loggedAt ?? "") }
    }

    private static func cleanedFoodDisplayText(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isFailureLikeText(text) else { return nil }
        return text
    }

    private static func isFailureLikeText(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return true
        }
        return text.contains("分析失败")
            || text.contains("连接不到")
            || text.contains("暂时不能分析")
            || lower.contains("\"detail\"")
            || lower.contains("not found")
            || lower.contains("internal server")
            || lower.contains("could not connect")
            || lower.contains("http")
            || lower.contains("pipeline")
            || lower.contains("traceback")
            || lower.contains("exception")
    }
}

struct HealthScore: Codable {
    let total: Int
    let artificialScore: SubScore?
    let netCarbsScore: SubScore?
    let addedSugarScore: SubScore?

    enum CodingKeys: String, CodingKey {
        case total
        case artificialScore = "artificial_score"
        case netCarbsScore = "net_carbs_score"
        case addedSugarScore = "added_sugar_score"
    }
}

struct SubScore: Codable {
    let score: Int
    let level: String?
    let description: String?
}

// MARK: - Daily Summary
struct DailySummary: Codable {
    var date: String = ""
    var caloriesConsumed: Double = 0
    var caloriesGoal: Double = 2000
    var caloriesBurned: Double = 0
    var protein: Double = 0
    var proteinGoal: Double = 50
    var carbs: Double = 0
    var carbsGoal: Double = 250
    var fat: Double = 0
    var fatGoal: Double = 65
    var fiber: Double = 0
    var magnesium: Double = 0
    var zinc: Double = 0
    var folate: Double = 0
    var vitaminD: Double = 0
    var vitaminB12: Double = 0
    var vitaminE: Double = 0
    var vitaminK: Double = 0
    var omega3: Double = 0
    var monounsaturatedFat: Double = 0
    var polyunsaturatedFat: Double = 0
    var waterMl: Double = 0
    var waterGoalMl: Double = 2000
    var hydrationMl: Double = 0
    var hydrationEffectiveMl: Double = 0
    var hydrationGoalMl: Double = 2000
    var caffeineMg: Double = 0
    var alcoholG: Double = 0
    var drinkSugarG: Double = 0
    var drinkCalories: Double = 0
    var drinkCount: Int = 0
    var weightKg: Double?
    var streakDays: Int = 0
    var steps: Int = 0
    var mealsCount: Int = 0
    var weightProjection: String?

    enum CodingKeys: String, CodingKey {
        case date
        case caloriesConsumed = "calories_consumed"
        case caloriesGoal = "calories_goal"
        case caloriesBurned = "calories_burned"
        case protein
        case proteinGoal = "protein_goal"
        case carbs
        case carbsGoal = "carbs_goal"
        case fat
        case fatGoal = "fat_goal"
        case fiber
        case magnesium, zinc, folate
        case vitaminD = "vitamin_d"
        case vitaminB12 = "vitamin_b12"
        case vitaminE = "vitamin_e"
        case vitaminK = "vitamin_k"
        case omega3 = "omega_3"
        case monounsaturatedFat = "monounsaturated_fat"
        case polyunsaturatedFat = "polyunsaturated_fat"
        case waterMl = "water_ml"
        case waterGoalMl = "water_goal_ml"
        case hydrationMl = "hydration_ml"
        case hydrationEffectiveMl = "hydration_effective_ml"
        case hydrationGoalMl = "hydration_goal_ml"
        case caffeineMg = "caffeine_mg"
        case alcoholG = "alcohol_g"
        case drinkSugarG = "drink_sugar_g"
        case drinkCalories = "drink_calories"
        case drinkCount = "drink_count"
        case weightKg = "weight_kg"
        case streakDays = "streak_days"
        case steps
        case mealsCount = "meals_count"
        case weightProjection = "weight_projection"
    }
}

struct DiaryNoteResponse: Codable {
    let date: String
    let note: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case date, note
        case updatedAt = "updated_at"
    }
}

struct DiaryCompleteResponse: Codable {
    let status: String
    let date: String
    let message: String?
    let projection: String?
    let summary: DailySummary?
}

struct HydrationLog: Codable, Identifiable {
    let id: String
    let drinkType: String
    let amountMl: Double
    let hydrationFactor: Double
    let effectiveMl: Double
    let caffeineMg: Double
    let alcoholG: Double
    let sugarG: Double
    let calories: Double
    let source: String?
    let note: String?
    let date: String?
    let loggedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case drinkType = "drink_type"
        case amountMl = "amount_ml"
        case hydrationFactor = "hydration_factor"
        case effectiveMl = "effective_ml"
        case caffeineMg = "caffeine_mg"
        case alcoholG = "alcohol_g"
        case sugarG = "sugar_g"
        case calories, source, note, date
        case loggedAt = "logged_at"
    }
}

struct HydrationLogsResponse: Codable {
    let logs: [HydrationLog]
}

struct HydrationSummary: Codable {
    let date: String?
    let hydrationMl: Double
    let hydrationEffectiveMl: Double
    let hydrationGoalMl: Double
    let caffeineMg: Double
    let alcoholG: Double
    let sugarG: Double
    let calories: Double
    let drinkCount: Int

    enum CodingKeys: String, CodingKey {
        case date
        case hydrationMl = "hydration_ml"
        case hydrationEffectiveMl = "hydration_effective_ml"
        case hydrationGoalMl = "hydration_goal_ml"
        case caffeineMg = "caffeine_mg"
        case alcoholG = "alcohol_g"
        case sugarG = "sugar_g"
        case calories
        case drinkCount = "drink_count"
    }
}

struct DepthPipelineHealth: Codable {
    let status: String?
    let version: String?
    let features: [String]?
    let depthPipeline: DepthPipelineInfo?

    enum CodingKeys: String, CodingKey {
        case status, version, features
        case depthPipeline = "depth_pipeline"
    }
}

struct DepthPipelineInfo: Codable {
    let cloudPipeline: DepthCloudPipelineInfo?

    enum CodingKeys: String, CodingKey {
        case cloudPipeline = "cloud_pipeline"
    }
}

struct DepthCloudPipelineInfo: Codable {
    let enabled: Bool?
    let reachable: Bool?
    let baseURL: String?

    enum CodingKeys: String, CodingKey {
        case enabled, reachable
        case baseURL = "base_url"
    }
}

struct HydrationSettings: Codable {
    let hydrationGoalMl: Double
    let waterMl: Double?

    enum CodingKeys: String, CodingKey {
        case hydrationGoalMl = "hydration_goal_ml"
        case waterMl = "water_ml"
    }
}

struct HydrationDeleteResponse: Codable {
    let status: String?
    let deleted: Int?
    let summary: HydrationSummary?
}

struct DrinkPreset: Codable, Identifiable {
    let id: String
    let drinkType: String
    let name: String
    let defaultAmountMl: Double
    let hydrationFactor: Double
    let caffeineMg: Double
    let alcoholG: Double
    let sugarG: Double
    let calories: Double
    let color: String?
    let icon: String?
    let custom: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case drinkType = "drink_type"
        case name
        case defaultAmountMl = "default_amount_ml"
        case hydrationFactor = "hydration_factor"
        case caffeineMg = "caffeine_mg"
        case alcoholG = "alcohol_g"
        case sugarG = "sugar_g"
        case calories, color, icon, custom
    }
}

struct DrinkPresetsResponse: Codable {
    let presets: [DrinkPreset]
}

struct StreakData: Codable {
    let streakDays: Int
    let longestStreak: Int?
    let totalDaysLogged: Int?

    enum CodingKeys: String, CodingKey {
        case streakDays = "streak_days"
        case longestStreak = "longest_streak"
        case totalDaysLogged = "total_days_logged"
    }
}

struct GoalPlan: Codable {
    var bmr: Double?
    var tdee: Double?
    var dailyCalorieTarget: Double?
    var currentWeightKg: Double?
    var goalWeightKg: Double?
    var direction: String?
    var weightDeltaKg: Double?
    var deficitKcalPerDay: Double?
    var activityLevel: String?
    var estimatedDays: Int?
    var targetDate: String?
    var goalDate: String?
    var weeklyLossKg: Double?

    enum CodingKeys: String, CodingKey {
        case bmr, tdee
        case dailyCalorieTarget = "daily_calorie_target"
        case currentWeightKg = "current_weight_kg"
        case goalWeightKg = "goal_weight_kg"
        case direction
        case weightDeltaKg = "weight_delta_kg"
        case deficitKcalPerDay = "deficit_kcal_per_day"
        case activityLevel = "activity_level"
        case estimatedDays = "estimated_days"
        case targetDate = "target_date"
        case goalDate = "goal_date"
        case weeklyLossKg = "weekly_loss_kg"
    }
}

struct AccountDeleteResponse: Codable {
    let deleted: Bool
    let deletedCounts: [String: Int]

    enum CodingKeys: String, CodingKey {
        case deleted
        case deletedCounts = "deleted_counts"
    }
}

struct MacroGoals: Codable {
    var dailyCalories: Double = 2000
    var proteinG: Double = 50
    var carbsG: Double = 250
    var fatG: Double = 65
    var fiberG: Double = 25
    var sugarG: Double = 50
    var sodiumMg: Double = 2300
    var waterMl: Double = 2000
    var mealShares: [String: Double] = ["breakfast": 0.25, "lunch": 0.35, "dinner": 0.30, "snack": 0.10]

    enum CodingKeys: String, CodingKey {
        case dailyCalories = "daily_calories"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case sodiumMg = "sodium_mg"
        case waterMl = "water_ml"
        case mealShares = "meal_shares"
    }

    init(
        dailyCalories: Double = 2000,
        proteinG: Double = 50,
        carbsG: Double = 250,
        fatG: Double = 65,
        fiberG: Double = 25,
        sugarG: Double = 50,
        sodiumMg: Double = 2300,
        waterMl: Double = 2000,
        mealShares: [String: Double] = ["breakfast": 0.25, "lunch": 0.35, "dinner": 0.30, "snack": 0.10]
    ) {
        self.dailyCalories = dailyCalories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.waterMl = waterMl
        self.mealShares = mealShares
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dailyCalories = try container.decodeIfPresent(Double.self, forKey: .dailyCalories) ?? 2000
        proteinG = try container.decodeIfPresent(Double.self, forKey: .proteinG) ?? 50
        carbsG = try container.decodeIfPresent(Double.self, forKey: .carbsG) ?? 250
        fatG = try container.decodeIfPresent(Double.self, forKey: .fatG) ?? 65
        fiberG = try container.decodeIfPresent(Double.self, forKey: .fiberG) ?? 25
        sugarG = try container.decodeIfPresent(Double.self, forKey: .sugarG) ?? 50
        sodiumMg = try container.decodeIfPresent(Double.self, forKey: .sodiumMg) ?? 2300
        waterMl = try container.decodeIfPresent(Double.self, forKey: .waterMl) ?? 2000
        mealShares = try container.decodeIfPresent([String: Double].self, forKey: .mealShares) ?? ["breakfast": 0.25, "lunch": 0.35, "dinner": 0.30, "snack": 0.10]
    }
}

struct WeightLog: Codable, Identifiable {
    var id: String = UUID().uuidString
    let weightKg: Double
    let date: String

    enum CodingKeys: String, CodingKey {
        case id
        case weightKg = "weight_kg"
        case date
    }
}

struct WeightLogsResponse: Codable {
    let weights: [WeightLog]
}

struct ExerciseEntry: Codable, Identifiable {
    var id: String = UUID().uuidString
    let name: String
    var durationMinutes: Int = 30
    var caloriesBurned: Double = 0
    let date: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case durationMinutes = "duration_minutes"
        case caloriesBurned = "calories_burned"
        case date
    }
}

struct ExerciseLogsResponse: Codable {
    let exercises: [ExerciseEntry]
}

struct ExerciseCatalogResponse: Codable {
    let exercises: [ExerciseCatalogItem]
}

struct ExerciseCatalogItem: Codable, Identifiable {
    let id: String
    let name: String
    let category: String?
    let description: String?
    let defaultIntensity: String?
    let suggestedMinutes: Int?
    let aliases: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, category, description, aliases
        case defaultIntensity = "default_intensity"
        case suggestedMinutes = "suggested_minutes"
    }
}

struct ExerciseEstimate: Codable {
    let caloriesBurned: Double
    let durationMinutes: Int?
    let intensity: String?

    enum CodingKeys: String, CodingKey {
        case caloriesBurned = "calories_burned"
        case durationMinutes = "duration_minutes"
        case intensity
    }
}

struct FoodLogSaveResponse: Codable {
    let status: String?
    let date: String?
    let alreadyLogged: Bool?
    let saved: Int?
    let foods: [FoodLogSavedFood]?
    let dailySummary: DailySummary?
    let decision: DecisionScoreResponse?

    enum CodingKeys: String, CodingKey {
        case status, date, saved, foods, decision
        case alreadyLogged = "already_logged"
        case dailySummary = "daily_summary"
    }
}

struct FoodLogSavedFood: Codable {
    let name: String?
    let calories: Double?
    let uploadGroupId: String?
    let uploadGroupTitle: String?
    let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, calories
        case uploadGroupId = "upload_group_id"
        case uploadGroupTitle = "upload_group_title"
        case imageUrl = "image_url"
    }
}

struct FoodLogDeleteResponse: Codable {
    let status: String?
    let date: String?
    let deleted: Int?
    let dailySummary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, deleted
        case dailySummary = "daily_summary"
    }
}

struct SavedMealsResponse: Codable {
    let meals: [SavedMealItem]
}

struct SavedMealMutationResponse: Codable {
    let status: String?
    let meal: SavedMealItem?
}

struct SavedMealLogResponse: Codable {
    let status: String?
    let date: String?
    let mealId: String?
    let saved: Int?
    let foods: [FoodLogSavedFood]?
    let dailySummary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, saved, foods
        case mealId = "meal_id"
        case dailySummary = "daily_summary"
    }
}

struct SavedMealDeleteResponse: Codable {
    let status: String?
    let deleted: Bool
    let mealId: String?

    enum CodingKeys: String, CodingKey {
        case status, deleted
        case mealId = "meal_id"
    }
}

struct SavedMealItem: Codable, Identifiable {
    let id: String
    let title: String
    let source: String?
    let mealCategory: String?
    let imageUrl: String?
    let note: String?
    let instructions: [String]?
    let createdAt: String?
    let loggedAt: String?
    let loggedCount: Int?
    let favorite: Bool?
    let foods: [FoodItem]

    enum CodingKeys: String, CodingKey {
        case id, title, source, foods
        case note, instructions
        case favorite
        case mealCategory = "meal_category"
        case imageUrl = "image_url"
        case createdAt = "created_at"
        case loggedAt = "logged_at"
        case loggedCount = "logged_count"
    }

    var calories: Double { foods.reduce(0) { $0 + $1.calories } }
    var protein: Double { foods.reduce(0) { $0 + $1.protein } }
    var carbs: Double { foods.reduce(0) { $0 + $1.carbs } }
    var fat: Double { foods.reduce(0) { $0 + $1.fat } }
    var fiber: Double { foods.reduce(0) { $0 + $1.fiber } }
    var sugar: Double { foods.reduce(0) { $0 + $1.sugar } }
    var sodium: Double { foods.reduce(0) { $0 + $1.sodium } }
    var addedSugar: Double { foods.reduce(0) { $0 + $1.addedSugar } }
    var satFat: Double { foods.reduce(0) { $0 + $1.satFat } }
    var cholesterol: Double { foods.reduce(0) { $0 + $1.cholesterol } }
    var potassium: Double { foods.reduce(0) { $0 + $1.potassium } }
    var names: [String] { foods.map(\.name).filter { !$0.isEmpty } }
}

struct SavedFoodsResponse: Codable {
    let foods: [SavedFoodItem]
}

struct SavedFoodMutationResponse: Codable {
    let status: String?
    let food: SavedFoodItem?
}

struct SavedFoodLogResponse: Codable {
    let status: String?
    let date: String?
    let foodId: String?
    let saved: Int?
    let foods: [FoodLogSavedFood]?
    let dailySummary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, saved, foods
        case foodId = "food_id"
        case dailySummary = "daily_summary"
    }
}

struct SavedFoodDeleteResponse: Codable {
    let status: String?
    let deleted: Bool
    let foodId: String?

    enum CodingKeys: String, CodingKey {
        case status, deleted
        case foodId = "food_id"
    }
}

struct SavedFoodItem: Codable, Identifiable {
    let id: String
    let name: String
    let source: String?
    let createdAt: String?
    let loggedAt: String?
    let loggedCount: Int?
    let food: FoodItem

    enum CodingKeys: String, CodingKey {
        case id, name, source, food
        case createdAt = "created_at"
        case loggedAt = "logged_at"
        case loggedCount = "logged_count"
    }
}

struct FoodLogPortionResponse: Codable {
    let status: String?
    let date: String?
    let adjusted: Int?
    let food: FoodLogRow?
    let dailySummary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, adjusted, food
        case dailySummary = "daily_summary"
    }
}

struct FoodLogMoveResponse: Codable {
    let status: String?
    let date: String?
    let moved: Int?
    let food: FoodLogRow?
    let dailySummary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, moved, food
        case dailySummary = "daily_summary"
    }
}

struct ProgressPhoto: Codable, Identifiable {
    let id: String
    let date: String?
    let weightKg: Double?
    let notes: String?
    let imageBase64: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, date, notes
        case weightKg = "weight_kg"
        case imageBase64 = "image_base64"
        case createdAt = "created_at"
    }
}

struct ProgressPhotosResponse: Codable {
    let photos: [ProgressPhoto]
}

struct ProgressPhotoSaveResponse: Codable {
    let id: String?
    let date: String?
    let status: String?
}

struct LeftoverEstimateItem: Codable, Identifiable {
    let id: String
    let name: String
    var remainingPercent: Double
    let confidence: Double
    let reason: String
    let originalCalories: Double?
    let leftoverCalories: Double?
    let consumedCalories: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, confidence, reason
        case remainingPercent = "remaining_percent"
        case originalCalories = "original_calories"
        case leftoverCalories = "leftover_calories"
        case consumedCalories = "consumed_calories"
    }
}

struct LeftoverEstimateResponse: Codable, Identifiable {
    var id: String { uploadGroupId }
    let status: String
    let date: String?
    let uploadGroupId: String
    let originalCalories: Double
    let estimatedLeftoverCalories: Double
    let estimatedConsumedCalories: Double
    let items: [LeftoverEstimateItem]
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case status, date, items, notes
        case uploadGroupId = "upload_group_id"
        case originalCalories = "original_calories"
        case estimatedLeftoverCalories = "estimated_leftover_calories"
        case estimatedConsumedCalories = "estimated_consumed_calories"
    }
}

struct LeftoverApplyResponse: Codable {
    let status: String
    let date: String?
    let uploadGroupId: String
    let originalCalories: Double
    let leftoverCalories: Double
    let consumedCalories: Double
    let consumedRatio: Double
    let items: [LeftoverEstimateItem]
    let dailySummary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, items
        case uploadGroupId = "upload_group_id"
        case originalCalories = "original_calories"
        case leftoverCalories = "leftover_calories"
        case consumedCalories = "consumed_calories"
        case consumedRatio = "consumed_ratio"
        case dailySummary = "daily_summary"
    }
}

// MARK: - Daily Status Score
struct NutritionScoreItem: Codable, Identifiable {
    var id: String
    var label: String = ""
    var value: Double = 0
    var goal: Double = 0
    var unit: String = ""
    var ratio: Double = 0
    var status: String = "red"
    var score: Double = 0
    var weight: Double = 0
    var message: String = ""
    var suggestion: String = ""

    enum CodingKeys: String, CodingKey {
        case id, label, value, goal, unit, ratio, status, score, weight, message, suggestion
    }

    init(
        id: String = UUID().uuidString,
        label: String = "",
        value: Double = 0,
        goal: Double = 0,
        unit: String = "",
        ratio: Double = 0,
        status: String = "red",
        score: Double = 0,
        weight: Double = 0,
        message: String = "",
        suggestion: String = ""
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.goal = goal
        self.unit = unit
        self.ratio = ratio
        self.status = status
        self.score = score
        self.weight = weight
        self.message = message
        self.suggestion = suggestion
    }
}

struct NutritionScore: Codable {
    var date: String = ""
    var scoreType: String?
    var score: Double = 0
    var status: String = "red"
    var headline: String = ""
    var items: [NutritionScoreItem] = []
    var nutritionItems: [NutritionScoreItem] = []
    var dimensions: [NutritionScoreItem] = []
    var highlights: [String] = []
    var nextActions: [String] = []
    var adjustments: [String] = []
    var sleep: SleepSummary?

    enum CodingKeys: String, CodingKey {
        case date, score, status, headline, items, dimensions, highlights, adjustments, sleep
        case scoreType = "score_type"
        case nutritionItems = "nutrition_items"
        case nextActions = "next_actions"
    }

    var displayDimensions: [NutritionScoreItem] {
        if !dimensions.isEmpty { return dimensions }
        return items
    }
}

// MARK: - Eating Decision
struct DecisionRemaining: Codable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
}

struct DecisionEatingWindow: Codable {
    var start: String = ""
    var end: String = ""
    var label: String = ""
    var state: String = ""
    var canEat: Bool = true
    var advice: String = ""

    enum CodingKeys: String, CodingKey {
        case start, end, label, state, advice
        case canEat = "can_eat"
    }
}

struct DecisionDayScore: Codable {
    var score: Double = 0
    var label: String = ""
    var headline: String = ""
}

struct DecisionCoachCard: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var status: String = ""
    var recommendedMethod: String?

    enum CodingKeys: String, CodingKey {
        case id, title, body, status
        case recommendedMethod = "recommended_method"
    }
}

struct DecisionContext: Codable {
    var date: String = ""
    var remaining: DecisionRemaining = DecisionRemaining()
    var eatingWindow: DecisionEatingWindow = DecisionEatingWindow()
    var canEat: Bool = true
    var isFasting: Bool = false
    var suggestedNextMeal: String = ""
    var notRecommended: String = ""
    var proteinGap: Double = 0
    var dayScore: DecisionDayScore = DecisionDayScore()
    var coachCards: [DecisionCoachCard] = []

    enum CodingKeys: String, CodingKey {
        case date, remaining
        case eatingWindow = "eating_window"
        case canEat = "can_eat"
        case isFasting = "is_fasting"
        case suggestedNextMeal = "suggested_next_meal"
        case notRecommended = "not_recommended"
        case proteinGap = "protein_gap"
        case dayScore = "day_score"
        case coachCards = "coach_cards"
    }
}

struct DecisionCriterion: Codable, Identifiable {
    var id: String { label }
    var label: String = ""
    var score: Double = 0
    var status: String = ""
    var detail: String = ""
}

struct DecisionScoreResponse: Codable, Identifiable {
    var id: String = ""
    var date: String = ""
    var score: Double = 0
    var scoreType: String = ""
    var label: String = ""
    var headline: String = ""
    var nutrition: [String: Double] = [:]
    var criteria: [DecisionCriterion] = []
    var reasons: [String] = []
    var warnings: [String] = []
    var suggestions: [String] = []
    var nextAdjustment: String = ""
    var context: DecisionContext?
    var source: String = ""
    var eventType: String = ""

    enum CodingKeys: String, CodingKey {
        case id, date, score, label, headline, nutrition, criteria, reasons, warnings, suggestions, context, source
        case scoreType = "score_type"
        case nextAdjustment = "next_adjustment"
        case eventType = "event_type"
    }
}

struct DecisionEventsResponse: Codable {
    var events: [DecisionScoreResponse] = []
}

// MARK: - Challenges
struct ChallengesResponse: Codable {
    let challenges: [Challenge]
}

struct Challenge: Codable, Identifiable {
    let id: String
    let templateId: String?
    let title: String
    let description: String
    let challengeType: String
    let durationDays: Int
    let targetValue: Double
    let startDate: String?
    let endDate: String?
    let status: String
    let rewardPoints: Int
    let progress: ChallengeProgress?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, progress
        case templateId = "template_id"
        case challengeType = "challenge_type"
        case durationDays = "duration_days"
        case targetValue = "target_value"
        case startDate = "start_date"
        case endDate = "end_date"
        case rewardPoints = "reward_points"
    }
}

struct ChallengeCreateRequest {
    var title: String
    var description: String
    var challengeType: String
    var durationDays: Int
    var targetValue: Double
    var rewardPoints: Int

    var json: [String: Any] {
        [
            "title": title,
            "description": description,
            "challenge_type": challengeType,
            "duration_days": durationDays,
            "target_value": targetValue,
            "reward_points": rewardPoints,
        ]
    }
}

struct ChallengeProgress: Codable {
    let completedDays: Int
    let durationDays: Int
    let currentStreak: Int
    let percent: Double
    let completed: Bool
    let days: [ChallengeProgressDay]

    enum CodingKeys: String, CodingKey {
        case percent, completed, days
        case completedDays = "completed_days"
        case durationDays = "duration_days"
        case currentStreak = "current_streak"
    }
}

struct ChallengeProgressDay: Codable, Identifiable {
    var id: String { date }
    let date: String
    let checked: Bool
    let success: Bool
    let value: Double
}

// MARK: - Community / Friends
struct FriendsResponse: Codable {
    let friends: [Friend]
}

struct Friend: Codable, Identifiable {
    var id: String { friendshipId ?? friend }
    let friendshipId: String?
    let friend: String
    let since: String?

    enum CodingKeys: String, CodingKey {
        case friendshipId = "friendship_id"
        case friend, since
    }
}

struct LeaderboardResponse: Codable {
    let leaderboard: [LeaderboardEntry]
}

struct LeaderboardEntry: Codable, Identifiable {
    var id: String { user }
    let user: String
    let streakDays: Int?
    let weightsCount: Int?

    enum CodingKeys: String, CodingKey {
        case user
        case streakDays = "streak_days"
        case weightsCount = "weights_count"
    }
}

struct CommunityFeedResponse: Codable {
    let tab: String?
    let posts: [CommunityPost]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case tab, posts
        case nextCursor = "next_cursor"
    }
}

struct CommunityActionResponse: Codable {
    let status: String?
    let post: CommunityPost?
    let hidden: Bool?
    let date: String?
    let saved: Int?
}

struct CommunityPost: Codable, Identifiable {
    let id: String
    let author: String?
    let authorName: String
    let avatarInitial: String?
    let visibility: String
    let postType: String?
    let title: String
    let body: String?
    let imageUrl: String?
    let mealLogGroupId: String?
    let date: String?
    let checkinDate: String?
    let challengeId: String?
    let statusScore: Double?
    let payload: CommunityPostPayload?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let healthLabel: String?
    let aiNote: String?
    let tags: [String]
    let foods: [CommunityFoodSnapshot]
    let createdAt: String
    let reactions: [String: Int]
    let activeReactions: [String]
    let commentsCount: Int
    let recentComments: [CommunityComment]
    let bookmarksCount: Int
    let bookmarked: Bool

    enum CodingKeys: String, CodingKey {
        case id, author, visibility, title, body, date, payload, calories, protein, carbs, fat, tags, foods, reactions, bookmarked
        case authorName = "author_name"
        case avatarInitial = "avatar_initial"
        case postType = "post_type"
        case imageUrl = "image_url"
        case mealLogGroupId = "meal_log_group_id"
        case checkinDate = "checkin_date"
        case challengeId = "challenge_id"
        case statusScore = "status_score"
        case healthLabel = "health_label"
        case aiNote = "ai_note"
        case createdAt = "created_at"
        case activeReactions = "active_reactions"
        case commentsCount = "comments_count"
        case recentComments = "recent_comments"
        case bookmarksCount = "bookmarks_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        author = try container.decodeIfPresent(String.self, forKey: .author)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
            ?? author
            ?? "食光用户"
        avatarInitial = try container.decodeIfPresent(String.self, forKey: .avatarInitial)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility) ?? "friends"
        postType = try container.decodeIfPresent(String.self, forKey: .postType)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "今日打卡"
        body = try container.decodeIfPresent(String.self, forKey: .body)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        mealLogGroupId = try container.decodeIfPresent(String.self, forKey: .mealLogGroupId)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        checkinDate = try container.decodeIfPresent(String.self, forKey: .checkinDate)
        challengeId = try container.decodeIfPresent(String.self, forKey: .challengeId)
        statusScore = try container.decodeIfPresent(Double.self, forKey: .statusScore)
        payload = try? container.decodeIfPresent(CommunityPostPayload.self, forKey: .payload)
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
        carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
        fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
        healthLabel = try container.decodeIfPresent(String.self, forKey: .healthLabel)
        aiNote = try container.decodeIfPresent(String.self, forKey: .aiNote)
        tags = (try? container.decodeIfPresent([String].self, forKey: .tags)) ?? []
        foods = (try? container.decodeIfPresent([CommunityFoodSnapshot].self, forKey: .foods)) ?? []
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? date
            ?? checkinDate
            ?? ""
        reactions = (try? container.decodeIfPresent([String: Int].self, forKey: .reactions)) ?? [:]
        activeReactions = (try? container.decodeIfPresent([String].self, forKey: .activeReactions)) ?? []
        commentsCount = try container.decodeIfPresent(Int.self, forKey: .commentsCount) ?? 0
        recentComments = (try? container.decodeIfPresent([CommunityComment].self, forKey: .recentComments)) ?? []
        bookmarksCount = try container.decodeIfPresent(Int.self, forKey: .bookmarksCount) ?? 0
        bookmarked = try container.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
    }

    var isCheckin: Bool {
        postType == "daily_checkin"
    }
}

struct CommunityPostPayload: Codable {
    let score: Double?
    let status: String?
    let headline: String?
    let dimensions: [NutritionScoreItem]?
    let highlights: [String]?
    let nextActions: [String]?
    let activeChallenges: [Challenge]?

    enum CodingKeys: String, CodingKey {
        case score, status, headline, dimensions, highlights
        case nextActions = "next_actions"
        case activeChallenges = "active_challenges"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = try container.decodeIfPresent(Double.self, forKey: .score)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        dimensions = try? container.decodeIfPresent([NutritionScoreItem].self, forKey: .dimensions)
        highlights = (try? container.decodeIfPresent([String].self, forKey: .highlights)) ?? nil
        nextActions = (try? container.decodeIfPresent([String].self, forKey: .nextActions)) ?? nil
        activeChallenges = try? container.decodeIfPresent([Challenge].self, forKey: .activeChallenges)
    }
}

struct CommunityFoodSnapshot: Codable, Identifiable {
    var id: String { "\(name)-\(servingSize ?? "")-\(calories)" }
    let name: String
    let calories: Double
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let servingSize: String?

    enum CodingKeys: String, CodingKey {
        case name, calories, protein, carbs, fat
        case servingSize = "serving_size"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "食物"
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        protein = try container.decodeIfPresent(Double.self, forKey: .protein)
        carbs = try container.decodeIfPresent(Double.self, forKey: .carbs)
        fat = try container.decodeIfPresent(Double.self, forKey: .fat)
        servingSize = try container.decodeIfPresent(String.self, forKey: .servingSize)
    }
}

struct CommunityComment: Codable, Identifiable {
    let id: String
    let user: String
    let body: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? "me"
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

// MARK: - Voice / Text Food Log
struct VoiceLogParseResponse: Codable {
    let rawText: String?
    let date: String?
    let source: String?
    let confidence: Double?
    let mealCategory: String?
    let foods: [VoiceParsedFood]
    let hydration: [VoiceParsedDrink]

    enum CodingKeys: String, CodingKey {
        case date, source, confidence, foods, hydration
        case rawText = "raw_text"
        case mealCategory = "meal_category"
    }
}

struct VoiceParsedFood: Codable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var sugar: Double = 0
    var sodium: Double = 0
    var servingSize = "1份"

    enum CodingKeys: String, CodingKey {
        case name, calories, protein, carbs, fat, fiber, sugar, sodium
        case servingSize = "serving_size"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
        carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
        fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
        fiber = try container.decodeIfPresent(Double.self, forKey: .fiber) ?? 0
        sugar = try container.decodeIfPresent(Double.self, forKey: .sugar) ?? 0
        sodium = try container.decodeIfPresent(Double.self, forKey: .sodium) ?? 0
        servingSize = try container.decodeIfPresent(String.self, forKey: .servingSize) ?? "1份"
    }
}

struct VoiceParsedDrink: Codable, Identifiable {
    var id = UUID().uuidString
    var drinkType = "water"
    var amountMl: Double = 250
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var sugar: Double = 0
    var note = ""

    enum CodingKeys: String, CodingKey {
        case note, calories
        case drinkType = "drink_type"
        case amountMl = "amount_ml"
        case protein = "protein_g"
        case carbs = "carbs_g"
        case fat = "fat_g"
        case sugar = "sugar_g"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        drinkType = try container.decodeIfPresent(String.self, forKey: .drinkType) ?? "water"
        amountMl = try container.decodeIfPresent(Double.self, forKey: .amountMl) ?? 250
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
        carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
        fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
        sugar = try container.decodeIfPresent(Double.self, forKey: .sugar) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct VoiceLogApplyResponse: Codable {
    let status: String?
    let date: String?
}

// MARK: - Sleep
struct SleepLogsResponse: Codable {
    var logs: [SleepLog]
}

struct SleepLog: Codable, Identifiable {
    var id: String
    var date: String
    var durationHours: Double
    var quality: Int
    var startAt: String
    var endAt: String
    var source: String
    var note: String
    var externalId: String
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, date, quality, source, note
        case durationHours = "duration_hours"
        case startAt = "start_at"
        case endAt = "end_at"
        case externalId = "external_id"
        case createdAt = "created_at"
    }
}

struct SleepSummary: Codable {
    var date: String = ""
    var durationHours: Double = 0
    var goalHours: Double = 7.5
    var quality: Int = 0
    var logsCount: Int = 0
    var status: String = "red"
    var message: String = "还没有记录睡眠"

    enum CodingKeys: String, CodingKey {
        case date, quality, status, message
        case durationHours = "duration_hours"
        case goalHours = "goal_hours"
        case logsCount = "logs_count"
    }
}

struct SleepLogSaveResponse: Codable {
    let status: String?
    let summary: SleepSummary?
}

// MARK: - User Preferences
struct UserPreferences: Codable {
    var dietType: String = "balanced"
    var allergies: [String] = []
    var avoidIngredients: [String] = []
    var favoriteCuisines: [String] = ["中式", "家常"]
    var budgetLevel: String = "medium"
    var prepTimeMinutes: Int = 20
    var includeImportedRecipesInMealPlans: Bool = true
    var tasteTags: [String] = ["清淡", "高蛋白"]
    var mealNames: [String: String] = ["breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"]

    enum CodingKeys: String, CodingKey {
        case dietType = "diet_type"
        case allergies
        case avoidIngredients = "avoid_ingredients"
        case favoriteCuisines = "favorite_cuisines"
        case budgetLevel = "budget_level"
        case prepTimeMinutes = "prep_time_minutes"
        case includeImportedRecipesInMealPlans = "include_imported_recipes_in_meal_plans"
        case tasteTags = "taste_tags"
        case mealNames = "meal_names"
    }
}

// MARK: - Meal Plan
struct MealPlanHistoryResponse: Codable {
    let plans: [MealPlanPayload]
}

struct MealPlanRecipeCollectionsResponse: Codable {
    let collections: [MealPlanRecipeCollection]
}

struct MealPlanRecipeCollection: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let tag: String
    let calorieRange: String?
    let recipeCount: Int
    let imageURL: String?
    let recipes: [MealPlanRecipeCollectionRecipe]

    enum CodingKeys: String, CodingKey {
        case id, title, description, tag, recipes
        case calorieRange = "calorie_range"
        case recipeCount = "recipe_count"
        case imageURL = "image_url"
    }
}

struct MealPlanRecipeCollectionRecipe: Codable, Identifiable {
    let id: String
    let title: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let servings: Int
    let imageURL: String?
    let sourceURL: String?
    let cookingTime: String?
    let tags: [String]
    let mealTypes: [String]
    let favorite: Bool
    let imported: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, calories, protein, carbs, fat, servings, tags, favorite, imported
        case imageURL = "image_url"
        case sourceURL = "source_url"
        case cookingTime = "cooking_time"
        case mealTypes = "meal_types"
    }
}

struct MealPlanDeleteResponse: Codable {
    let deleted: Bool
    let id: String?
}

struct IngredientRecipeDeleteResponse: Codable {
    let status: String?
    let deleted: Bool
    let recipeId: String?

    enum CodingKeys: String, CodingKey {
        case status, deleted
        case recipeId = "recipe_id"
    }
}

struct IngredientRecipeUpdateResponse: Codable {
    let status: String?
    let recipeId: String?
    let recipe: IngredientRecipeSuggestion
    let item: IngredientRecipeHistoryItem?

    enum CodingKeys: String, CodingKey {
        case status, recipe, item
        case recipeId = "recipe_id"
    }
}

struct MealSwapResponse: Codable {
    let meal: MealPlanMeal
    let plan: MealPlanPayload?
}

struct MealPlanPayload: Codable, Identifiable {
    var id: String?
    var planName: String
    var name: String?
    var source: String?
    var goalType: String?
    var mealsPerDay: Int?
    var prepTimeMinutes: Int?
    var dailyTargets: MealPlanTargets?
    var days: [MealPlanDay]
    var groceryList: [GroceryListGroup]
    var groceryCheckedItems: [String]?
    var dailyCalorieTarget: Double?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, source, days
        case planName = "plan_name"
        case goalType = "goal_type"
        case mealsPerDay = "meals_per_day"
        case prepTimeMinutes = "prep_time_minutes"
        case dailyTargets = "daily_targets"
        case groceryList = "grocery_list"
        case groceryCheckedItems = "grocery_checked_items"
        case dailyCalorieTarget = "daily_calorie_target"
        case createdAt = "created_at"
    }

    var displayId: String { id ?? planName }
    var displayName: String { planName.isEmpty ? (name ?? "餐单") : planName }
}

struct MealPlanTargets: Codable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
}

struct MealPlanDay: Codable, Identifiable {
    var id: String { day }
    let day: String
    var meals: [MealPlanMeal]
}

struct MealPlanMeal: Codable, Identifiable {
    var id: String { "\(mealType ?? "")-\(label ?? "")-\(name)" }
    let mealType: String?
    let label: String?
    let name: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let prepTimeMinutes: Int?
    let ingredients: [String]
    let reason: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case label, name, calories, protein, carbs, fat, fiber, sugar, sodium, ingredients, reason, source
        case mealType = "meal_type"
        case prepTimeMinutes = "prep_time_minutes"
    }
}

struct GroceryListGroup: Codable, Identifiable {
    var id: String { category }
    let category: String
    let items: [String]
}

// MARK: - Recommendations / Delivery
struct RecommendationFood: Codable, Identifiable {
    let id: String
    let name: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let servingSize: String
    let processingLevel: String?

    enum CodingKeys: String, CodingKey {
        case id, name, calories, protein, carbs, fat, fiber, sugar, sodium
        case servingSize = "serving_size"
        case processingLevel = "processing_level"
    }
}

struct RecommendationFit: Codable {
    let remainingCaloriesAfterLog: Double?
    let proteinGapAfterLog: Double?

    enum CodingKeys: String, CodingKey {
        case remainingCaloriesAfterLog = "remaining_calories_after_log"
        case proteinGapAfterLog = "protein_gap_after_log"
    }
}

struct MealRecommendation: Codable, Identifiable {
    let id: String
    let title: String
    let mealType: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let servingSize: String
    let prepTimeMinutes: Int
    let reason: String
    let source: String
    let portionMultiplier: Double?
    let foods: [RecommendationFood]
    let fit: RecommendationFit?

    enum CodingKeys: String, CodingKey {
        case id, title, calories, protein, carbs, fat, fiber, sugar, sodium, reason, source, foods, fit
        case mealType = "meal_type"
        case servingSize = "serving_size"
        case prepTimeMinutes = "prep_time_minutes"
        case portionMultiplier = "portion_multiplier"
    }
}

struct TodayRecommendationsResponse: Codable {
    let date: String?
    let remaining: RecommendationRemaining?
    let targetCalories: Double?
    let source: String?
    let recommendations: [MealRecommendation]

    enum CodingKeys: String, CodingKey {
        case date, remaining, source, recommendations
        case targetCalories = "target_calories"
    }
}

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues { $0.anyValue }
        case .array(let value): return value.map { $0.anyValue }
        case .null: return NSNull()
        }
    }
}

struct CoachAction: Codable, Identifiable {
    var id: String?
    var type: String
    var label: String
    var description: String?
    var payload: [String: JSONValue]?

    var stableId: String { id ?? type }
}

struct CoachMessage: Codable, Identifiable {
    var id: String?
    var role: String
    var content: String
    var payload: CoachMessagePayload?

    var stableId: String { id ?? "\(role)-\(content)" }
}

struct CoachMessagePayload: Codable {
    var recommendations: [MealRecommendation]?
    var actions: [CoachAction]?
}

struct CoachChatResponse: Codable {
    var reply: String?
    var actions: [CoachAction]?
    var recommendations: [MealRecommendation]?
    var messages: [CoachMessage]?
    var toolsUsed: [String]?

    enum CodingKeys: String, CodingKey {
        case reply, actions, recommendations, messages
        case toolsUsed = "tools_used"
    }
}

struct CoachApplyResponse: Codable {
    var status: String?
    var message: String?
}

struct RecommendationRemaining: Codable {
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

struct RecommendationLogResponse: Codable {
    let status: String?
    let date: String?
    let recommendationId: String?
    let alreadyLogged: Bool?
    let saved: Int?
    let foods: [FoodItem]?
    let summary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, saved, foods, summary
        case recommendationId = "recommendation_id"
        case alreadyLogged = "already_logged"
    }
}

struct DeliveryOrderItem: Codable, Identifiable {
    var id: String { "\(name)-\(servingSize)" }
    let name: String
    let servingSize: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    enum CodingKeys: String, CodingKey {
        case name, calories, protein, carbs, fat
        case servingSize = "serving_size"
    }
}

struct DeliveryPlatformOption: Codable, Identifiable {
    let id: String
    let name: String
    let url: String
    let searchQuery: String

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case searchQuery = "search_query"
    }
}

struct DeliveryNutrition: Codable {
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

struct DeliveryOrderDraft: Codable, Identifiable {
    let id: String
    let recommendationId: String
    let date: String?
    let mealType: String?
    let provider: String?
    let providerLabel: String?
    let searchQuery: String
    let restaurantHint: String
    let etaMinutes: Int
    let feeYuan: Double
    let orderNote: String
    let orderItems: [DeliveryOrderItem]
    let nutrition: DeliveryNutrition
    let portionMultiplier: Double
    let copyText: String?
    let platformOptions: [DeliveryPlatformOption]
    let guardrails: [String]

    enum CodingKeys: String, CodingKey {
        case id, date, provider, nutrition, guardrails
        case recommendationId = "recommendation_id"
        case mealType = "meal_type"
        case providerLabel = "provider_label"
        case searchQuery = "search_query"
        case restaurantHint = "restaurant_hint"
        case etaMinutes = "eta_minutes"
        case feeYuan = "fee_yuan"
        case orderNote = "order_note"
        case orderItems = "order_items"
        case portionMultiplier = "portion_multiplier"
        case copyText = "copy_text"
        case platformOptions = "platform_options"
    }
}

struct DeliveryDraftResponse: Codable {
    let status: String?
    let date: String?
    let draft: DeliveryOrderDraft
}

struct DeliveryMealRecommendation: Codable, Identifiable {
    let id: String
    let recommendationId: String?
    let title: String
    let restaurantName: String
    let platform: String?
    let platformLabel: String
    let mealType: String?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let deliveryMinutes: Int
    let priceYuan: Double
    let score: Double
    let reason: String
    let scoreReasons: [String]?
    let warnings: [String]?
    let suggestions: [String]?
    let orderNote: String
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, platform, calories, protein, carbs, fat, fiber, sugar, sodium, score, reason, warnings, suggestions, tags
        case recommendationId = "recommendation_id"
        case restaurantName = "restaurant_name"
        case platformLabel = "platform_label"
        case mealType = "meal_type"
        case deliveryMinutes = "delivery_minutes"
        case priceYuan = "price_yuan"
        case scoreReasons = "score_reasons"
        case orderNote = "order_note"
    }

    var logId: String { recommendationId ?? id }
}

struct DeliveryRecommendationsResponse: Codable {
    let date: String?
    let remaining: RecommendationRemaining?
    let source: String?
    let recommendations: [DeliveryMealRecommendation]
    let moreOptions: [DeliveryMealRecommendation]

    enum CodingKeys: String, CodingKey {
        case date, remaining, source, recommendations
        case moreOptions = "more_options"
    }
}

struct DeliveryDraftsResponse: Codable {
    let drafts: [DeliveryOrderDraft]
}

// MARK: - Ingredient Recipes
struct IngredientBreakdownItem: Codable, Identifiable {
    var id: String { "\(name)-\(amount)" }
    let name: String
    let amount: String
    let displayAmount: String?
    let calories: Double
    let protein: Double
    let carbs: Double?
    let fat: Double?
    let sugar: Double?
    let servingSize: String?
    let processingLevel: String?

    enum CodingKeys: String, CodingKey {
        case name, amount, calories, protein, carbs, fat, sugar
        case displayAmount = "display_amount"
        case servingSize = "serving_size"
        case processingLevel = "processing_level"
    }
}

struct RecipeServingSizeOption: Codable, Identifiable {
    let value: Double
    let unit: String
    let nutritionMultiplier: Double
    let label: String?

    var id: String {
        "\(displayLabel)-\(String(format: "%.4f", nutritionMultiplier))"
    }

    var displayLabel: String {
        let cleanLabel = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLabel.isEmpty { return cleanLabel }
        let cleanUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanUnit.isEmpty || cleanUnit == "份" {
            if abs(value - 0.5) < 0.01 { return "半份" }
            if abs(value - 1.0) < 0.01 { return "1份" }
            return "\(Self.numberText(value))份"
        }
        return "\(Self.numberText(value))\(cleanUnit)"
    }

    init(value: Double, unit: String = "份", nutritionMultiplier: Double? = nil, label: String? = nil) {
        self.value = value
        self.unit = unit
        self.nutritionMultiplier = nutritionMultiplier ?? value
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case value, unit, label
        case nutritionMultiplier = "nutrition_multiplier"
    }

    private static func numberText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.01 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }
}

struct IngredientRecipeSuggestion: Codable, Identifiable {
    let id: String
    let title: String
    let servings: Int
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let sodium: Double
    let sugar: Double?
    let prepTimeMinutes: Int
    let reason: String
    let instructions: [String]
    let ingredientsBreakdown: [IngredientBreakdownItem]
    let missingIngredients: [String]?
    let source: String
    let sourceURL: String?
    let cookingTime: String?
    let servingSizeLabel: String?
    let servingSizes: [RecipeServingSizeOption]?
    let imageURL: String?
    let tags: [String]?
    let mealTypes: [String]?
    let favorite: Bool?
    let activeTimeMinutes: Int?
    let inactiveTimeMinutes: Int?
    let addedSugar: Double?
    let satFat: Double?
    let transFat: Double?
    let monounsaturatedFat: Double?
    let polyunsaturatedFat: Double?
    let cholesterol: Double?
    let vitaminA: Double?
    let vitaminC: Double?
    let calcium: Double?
    let iron: Double?
    let potassium: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, servings, calories, protein, carbs, fat, fiber, sodium, sugar, reason, instructions, source
        case tags, favorite
        case prepTimeMinutes = "prep_time_minutes"
        case ingredientsBreakdown = "ingredients_breakdown"
        case missingIngredients = "missing_ingredients"
        case sourceURL = "source_url"
        case cookingTime = "cooking_time"
        case servingSizeLabel = "serving_size_label"
        case servingSizes = "serving_sizes"
        case imageURL = "image_url"
        case mealTypes = "meal_types"
        case activeTimeMinutes = "active_time_minutes"
        case inactiveTimeMinutes = "inactive_time_minutes"
        case addedSugar = "added_sugar"
        case satFat = "sat_fat"
        case transFat = "trans_fat"
        case monounsaturatedFat = "monounsaturated_fat"
        case polyunsaturatedFat = "polyunsaturated_fat"
        case cholesterol
        case vitaminA = "vitamin_a"
        case vitaminC = "vitamin_c"
        case calcium
        case iron
        case potassium
    }
}

struct RecipeURLImportResponse: Codable {
    let recipeName: String?
    let servings: Int?
    let caloriesPerServing: Double?
    let proteinPerServing: Double?
    let carbsPerServing: Double?
    let fatPerServing: Double?
    let cookingTime: String?
    let activeTimeMinutes: Int?
    let inactiveTimeMinutes: Int?
    let ingredients: [String]?
    let instructions: [String]?
    let sourceURL: String?
    let servingSizeLabel: String?
    let imageURL: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ingredients, instructions, error
        case recipeName = "recipe_name"
        case servings
        case caloriesPerServing = "calories_per_serving"
        case proteinPerServing = "protein_per_serving"
        case carbsPerServing = "carbs_per_serving"
        case fatPerServing = "fat_per_serving"
        case cookingTime = "cooking_time"
        case activeTimeMinutes = "active_time_minutes"
        case inactiveTimeMinutes = "inactive_time_minutes"
        case sourceURL = "source_url"
        case servingSizeLabel = "serving_size_label"
        case imageURL = "image_url"
    }
}

struct IngredientRecipesResponse: Codable {
    let date: String?
    let identifiedIngredients: [String]
    let recognitionSource: String?
    let message: String?
    let source: String?
    let recipes: [IngredientRecipeSuggestion]

    enum CodingKeys: String, CodingKey {
        case date, message, source, recipes
        case identifiedIngredients = "identified_ingredients"
        case recognitionSource = "recognition_source"
    }
}

struct IngredientRecipeHistoryResponse: Codable {
    let recipes: [IngredientRecipeHistoryItem]
}

struct IngredientRecipeHistoryItem: Codable, Identifiable {
    let id: String
    let date: String?
    let source: String?
    let logged: Int?
    let createdAt: String?
    let loggedAt: String?
    let loggedCount: Int?
    let recipe: IngredientRecipeSuggestion

    enum CodingKeys: String, CodingKey {
        case id, date, source, logged, recipe
        case createdAt = "created_at"
        case loggedAt = "logged_at"
        case loggedCount = "logged_count"
    }
}

struct IngredientRecipeLogResponse: Codable {
    let status: String?
    let date: String?
    let recipeId: String?
    let saved: Int?
    let foods: [FoodItem]?
    let summary: DailySummary?

    enum CodingKeys: String, CodingKey {
        case status, date, saved, foods, summary
        case recipeId = "recipe_id"
    }
}

// MARK: - Reminders
struct ReminderItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    var mealType: String = ""
    var time: String = ""
    var enabled: Bool = true
    var category: String = "meal"
    var title: String = ""
    var targetId: String = ""
    var daysOfWeek: String = ""
    var intervalMinutes: Int = 60

    enum CodingKeys: String, CodingKey {
        case id, time, enabled, category, title
        case mealType = "meal_type"
        case targetId = "target_id"
        case daysOfWeek = "days_of_week"
        case intervalMinutes = "interval_minutes"
    }

    var savePayload: [String: Any] {
        [
            "id": id,
            "meal_type": mealType,
            "time": time,
            "enabled": enabled,
            "category": category,
            "title": title,
            "target_id": targetId,
            "days_of_week": daysOfWeek,
            "interval_minutes": intervalMinutes,
        ]
    }
}

struct RemindersResponse: Codable {
    let reminders: [ReminderItem]
}

// MARK: - Fasting
struct FastingPreferences: Codable {
    var enabled: Bool = false
    var method: String = "16:8"
    var fastingHours: Double = 16
    var eatingHours: Double = 8
    var eatingWindowStart: String = "12:00"
    var remindersEnabled: Bool = true
    var timezone: String = "local"

    enum CodingKeys: String, CodingKey {
        case enabled, method, timezone
        case fastingHours = "fasting_hours"
        case eatingHours = "eating_hours"
        case eatingWindowStart = "eating_window_start"
        case remindersEnabled = "reminders_enabled"
    }
}

struct FastingStage: Codable, Identifiable {
    let id: String
    let label: String?
    let startsAtHours: Double?
    let endsAtHours: Double?
    let description: String?
    let advice: String?
    let color: String?
    let windowLabel: String?
    let active: Bool?
    let progressPct: Double?
    let nextLabel: String?
    let nextInSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, label, description, advice, color, active
        case startsAtHours = "starts_at_hours"
        case endsAtHours = "ends_at_hours"
        case windowLabel = "window_label"
        case progressPct = "progress_pct"
        case nextLabel = "next_label"
        case nextInSeconds = "next_in_seconds"
    }
}

struct FastingSession: Codable, Identifiable {
    let id: String
    let method: String?
    let fastingHours: Double?
    let startAt: String?
    let targetEndAt: String?
    let endedAt: String?
    let status: String?
    let notes: String?
    let elapsedSeconds: Int?
    let remainingSeconds: Int?
    let targetSeconds: Int?
    let progressPct: Double?
    let completed: Bool?
    let stage: FastingStage?

    enum CodingKeys: String, CodingKey {
        case id, method, status, notes, completed, stage
        case fastingHours = "fasting_hours"
        case startAt = "start_at"
        case targetEndAt = "target_end_at"
        case endedAt = "ended_at"
        case elapsedSeconds = "elapsed_seconds"
        case remainingSeconds = "remaining_seconds"
        case targetSeconds = "target_seconds"
        case progressPct = "progress_pct"
    }
}

struct FastingStatus: Codable {
    let preferences: FastingPreferences?
    let activeSession: FastingSession?
    let enabled: Bool?
    let isFasting: Bool?
    let currentStage: FastingStage?
    let stagePlan: [FastingStage]?
    let recentSessions: [FastingSession]?

    enum CodingKeys: String, CodingKey {
        case preferences, enabled
        case activeSession = "active_session"
        case isFasting = "is_fasting"
        case currentStage = "current_stage"
        case stagePlan = "stage_plan"
        case recentSessions = "recent_sessions"
    }
}

struct FastingHistorySummary: Codable {
    let totalSessions: Int?
    let completedSessions: Int?
    let completionRate: Int?
    let averageHours: Double?
    let currentStreak: Int?
    let longestStreak: Int?
    let weekCompletedDays: Int?
    let weekCompletedDates: [String]?

    enum CodingKeys: String, CodingKey {
        case totalSessions = "total_sessions"
        case completedSessions = "completed_sessions"
        case completionRate = "completion_rate"
        case averageHours = "average_hours"
        case currentStreak = "current_streak"
        case longestStreak = "longest_streak"
        case weekCompletedDays = "week_completed_days"
        case weekCompletedDates = "week_completed_dates"
    }
}

struct FastingHistory: Codable {
    let sessions: [FastingSession]
    let summary: FastingHistorySummary?
}

extension FoodItem {
    mutating func scaleNutrition(from base: FoodItem, factor: Double) {
        let ratio = max(0, factor)
        calories = base.calories * ratio
        protein = base.protein * ratio
        carbs = base.carbs * ratio
        fat = base.fat * ratio
        fiber = base.fiber * ratio
        sugar = base.sugar * ratio
        sodium = base.sodium * ratio
        addedSugar = base.addedSugar * ratio
        satFat = base.satFat * ratio
        transFat = base.transFat * ratio
        cholesterol = base.cholesterol * ratio
        vitaminA = base.vitaminA * ratio
        vitaminC = base.vitaminC * ratio
        calcium = base.calcium * ratio
        iron = base.iron * ratio
        potassium = base.potassium * ratio
        magnesium = base.magnesium * ratio
        zinc = base.zinc * ratio
        folate = base.folate * ratio
        vitaminD = base.vitaminD * ratio
        vitaminB12 = base.vitaminB12 * ratio
        vitaminE = base.vitaminE * ratio
        vitaminK = base.vitaminK * ratio
        omega3 = base.omega3 * ratio
        monounsaturatedFat = base.monounsaturatedFat * ratio
        polyunsaturatedFat = base.polyunsaturatedFat * ratio
    }
}

// MARK: - Onboarding
struct GoalPlanRequest: Codable {
    let currentWeightKg: Double
    let goalWeightKg: Double
    let heightCm: Double
    let age: Int
    let gender: String
    let activity: String
    let deficitPct: Double

    enum CodingKeys: String, CodingKey {
        case currentWeightKg = "current_weight_kg"
        case goalWeightKg = "goal_weight_kg"
        case heightCm = "height_cm"
        case age, gender, activity
        case deficitPct = "deficit_pct"
    }
}
