import Foundation
import HealthKit

struct HealthImportRecordPayload {
    let externalId: String
    let recordType: String
    let value: Double
    let unit: String
    let date: String
    let startAt: String?
    let loggedAt: String?
    let metadata: [String: Any]

    var json: [String: Any] {
        var payload: [String: Any] = [
            "external_id": externalId,
            "record_type": recordType,
            "value": value,
            "unit": unit,
            "date": date,
            "metadata": metadata,
        ]
        if let startAt, !startAt.isEmpty {
            payload["start_at"] = startAt
        }
        if let loggedAt, !loggedAt.isEmpty {
            payload["logged_at"] = loggedAt
        }
        return payload
    }
}

struct HealthImportResponse: Codable {
    let imported: [HealthImportResult]?
    let skipped: [HealthImportSkipped]?
    let status: String?
}

struct HealthImportResult: Codable {
    let externalId: String?
    let recordType: String?

    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case recordType = "record_type"
    }
}

struct HealthImportSkipped: Codable {
    let externalId: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case reason
    }
}

@MainActor
final class HealthKitSyncService: ObservableObject {
    static let shared = HealthKitSyncService()
    private static let syncEnabledDefaultsKey = "HealthKitSyncEnabled"

    enum SyncState: Equatable {
        case idle
        case unavailable(String)
        case authorizing
        case syncing
        case done(imported: Int, skipped: Int)
        case failed(String)
    }

    @Published var state: SyncState = .idle
    @Published var preview: [HealthImportRecordPayload] = []

    private let store = HKHealthStore()
    private var isSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.syncEnabledDefaultsKey)
    }
    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func syncRecent(days: Int = 7) async {
        guard isHealthDataAvailable else {
            state = .unavailable("这台设备不支持苹果健康数据。")
            return
        }
        state = .authorizing
        do {
            try await requestAuthorization(includeNutritionWrite: false)
            UserDefaults.standard.set(true, forKey: Self.syncEnabledDefaultsKey)
            state = .syncing
            let records = try await collectRecentRecords(days: days)
            preview = records
            let response = try await APIClient.shared.importHealthRecords(records)
            let imported = response.imported?.count ?? 0
            let skipped = response.skipped?.count ?? 0
            state = .done(imported: imported, skipped: skipped)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func requestAuthorization(includeNutritionWrite: Bool) async throws {
        let readTypes = Set([
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.quantityType(forIdentifier: .bodyMass),
            HKObjectType.quantityType(forIdentifier: .dietaryWater),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
        ].compactMap { $0 })

        let shareTypes: Set<HKSampleType> = includeNutritionWrite
            ? Set(Self.nutritionDefinitions.compactMap { definition in
                HKObjectType.quantityType(forIdentifier: definition.identifier) as HKSampleType?
            })
            : []

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: shareTypes, read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitSync",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "未获得苹果健康读取权限"]
                    ))
                }
            }
        }
    }

    @discardableResult
    func writeMeal(foods: [FoodItem], groupId: String, date: String) async -> Bool {
        let cleanGroupId = groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSyncEnabled, isHealthDataAvailable, !foods.isEmpty, !cleanGroupId.isEmpty else { return false }
        do {
            try await requestAuthorization(includeNutritionWrite: true)
            try await deleteMeal(groupId: cleanGroupId)
            let totals = Self.nutritionTotals(foods)
            let mealDate = Self.mealDate(from: date)
            let metadata: [String: Any] = [
                Self.mealGroupMetadataKey: cleanGroupId,
                Self.recordSourceMetadataKey: "shiguang_ios",
                HKMetadataKeyWasUserEntered: true,
            ]
            let samples = Self.nutritionDefinitions.compactMap { definition -> HKQuantitySample? in
                guard let type = HKObjectType.quantityType(forIdentifier: definition.identifier) else { return nil }
                let value = definition.value(totals)
                guard value > 0 else { return nil }
                return HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: definition.unit, doubleValue: value),
                    start: mealDate,
                    end: mealDate,
                    metadata: metadata
                )
            }
            guard !samples.isEmpty else { return false }
            try await save(samples)
            return true
        } catch {
            return false
        }
    }

    func deleteMeal(groupId: String) async throws {
        let cleanGroupId = groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSyncEnabled, isHealthDataAvailable, !cleanGroupId.isEmpty else { return }
        let sampleTypes = Set(Self.nutritionDefinitions.compactMap { definition in
            HKObjectType.quantityType(forIdentifier: definition.identifier)
        })
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: Self.mealGroupMetadataKey,
            allowedValues: [cleanGroupId]
        )
        for type in sampleTypes {
            let samples = try await samples(type: type, predicate: predicate)
            if !samples.isEmpty {
                try await delete(samples)
            }
        }
    }

    private func save(_ samples: [HKSample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(samples) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitSync",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "餐食营养没有写入苹果健康"]
                    ))
                }
            }
        }
    }

    private func samples(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }

    private func delete(_ samples: [HKSample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.delete(samples) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitSync",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "旧的餐食营养记录没有删除"]
                    ))
                }
            }
        }
    }

    private func collectRecentRecords(days: Int) async throws -> [HealthImportRecordPayload] {
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -max(1, min(30, days)), to: end) ?? end

        async let steps = quantityRecords(
            identifier: .stepCount,
            recordType: "steps",
            unit: HKUnit.count(),
            unitText: "步",
            start: start,
            end: end,
            aggregateByDay: true
        )
        async let weights = quantityRecords(
            identifier: .bodyMass,
            recordType: "weight",
            unit: HKUnit.gramUnit(with: .kilo),
            unitText: "公斤",
            start: start,
            end: end,
            aggregateByDay: false
        )
        async let water = quantityRecords(
            identifier: .dietaryWater,
            recordType: "dietary_water",
            unit: HKUnit.literUnit(with: .milli),
            unitText: "毫升",
            start: start,
            end: end,
            aggregateByDay: false
        )
        async let energy = quantityRecords(
            identifier: .activeEnergyBurned,
            recordType: "active_energy",
            unit: HKUnit.kilocalorie(),
            unitText: "千卡",
            start: start,
            end: end,
            aggregateByDay: true
        )
        async let sleep = sleepRecords(start: start, end: end)

        let stepRecords = try await steps
        let weightRecords = try await weights
        let waterRecords = try await water
        let energyRecords = try await energy
        let sleepRecords = try await sleep
        let combined = stepRecords + weightRecords + waterRecords + energyRecords + sleepRecords
        return combined.sorted { $0.date > $1.date }.prefix(120).map { $0 }
    }

    private func quantityRecords(
        identifier: HKQuantityTypeIdentifier,
        recordType: String,
        unit: HKUnit,
        unitText: String,
        start: Date,
        end: Date,
        aggregateByDay: Bool
    ) async throws -> [HealthImportRecordPayload] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        if aggregateByDay {
            return try await dailyQuantityRecords(type: type, recordType: recordType, unit: unit, unitText: unitText, start: start, end: end)
        }
        return try await sampleQuantityRecords(type: type, recordType: recordType, unit: unit, unitText: unitText, start: start, end: end)
    }

    private func dailyQuantityRecords(
        type: HKQuantityType,
        recordType: String,
        unit: HKUnit,
        unitText: String,
        start: Date,
        end: Date
    ) async throws -> [HealthImportRecordPayload] {
        let calendar = Calendar.current
        return try await withCheckedThrowingContinuation { continuation in
            var interval = DateComponents()
            interval.day = 1
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: calendar.startOfDay(for: start),
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var records: [HealthImportRecordPayload] = []
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let value = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
                    guard value > 0 else { return }
                    let day = Self.dayString(statistics.startDate)
                    records.append(HealthImportRecordPayload(
                        externalId: "healthkit:\(recordType):\(day)",
                        recordType: recordType,
                        value: value,
                        unit: unitText,
                        date: day,
                        startAt: Self.isoString(statistics.startDate),
                        loggedAt: Self.isoString(statistics.endDate),
                        metadata: ["source_name": "苹果健康", "aggregation": "day"]
                    ))
                }
                continuation.resume(returning: records)
            }
            store.execute(query)
        }
    }

    private func sampleQuantityRecords(
        type: HKQuantityType,
        recordType: String,
        unit: HKUnit,
        unitText: String,
        start: Date,
        end: Date
    ) async throws -> [HealthImportRecordPayload] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 80, sortDescriptors: [descriptor]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let records = (samples as? [HKQuantitySample] ?? []).compactMap { sample -> HealthImportRecordPayload? in
                    let value = sample.quantity.doubleValue(for: unit)
                    guard value > 0 else { return nil }
                    return HealthImportRecordPayload(
                        externalId: "healthkit:\(recordType):\(sample.uuid.uuidString)",
                        recordType: recordType,
                        value: value,
                        unit: unitText,
                        date: Self.dayString(sample.endDate),
                        startAt: Self.isoString(sample.startDate),
                        loggedAt: Self.isoString(sample.endDate),
                        metadata: ["source_name": sample.sourceRevision.source.name]
                    )
                }
                continuation.resume(returning: records)
            }
            store.execute(query)
        }
    }

    private func sleepRecords(start: Date, end: Date) async throws -> [HealthImportRecordPayload] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 80, sortDescriptors: [descriptor]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let records = (samples as? [HKCategorySample] ?? []).compactMap { sample -> HealthImportRecordPayload? in
                    guard Self.isAsleepValue(sample.value) else { return nil }
                    let hours = max(0, sample.endDate.timeIntervalSince(sample.startDate) / 3600)
                    guard hours > 0 else { return nil }
                    return HealthImportRecordPayload(
                        externalId: "healthkit:sleep:\(sample.uuid.uuidString)",
                        recordType: "sleep_duration",
                        value: hours,
                        unit: "hour",
                        date: Self.dayString(sample.endDate),
                        startAt: Self.isoString(sample.startDate),
                        loggedAt: Self.isoString(sample.endDate),
                        metadata: ["source_name": sample.sourceRevision.source.name]
                    )
                }
                continuation.resume(returning: records)
            }
            store.execute(query)
        }
    }

    private struct MealNutritionTotals {
        var calories = 0.0
        var protein = 0.0
        var carbs = 0.0
        var fat = 0.0
        var fiber = 0.0
        var sugar = 0.0
        var sodium = 0.0
        var saturatedFat = 0.0
        var cholesterol = 0.0
        var vitaminC = 0.0
        var calcium = 0.0
        var iron = 0.0
        var potassium = 0.0
        var magnesium = 0.0
        var zinc = 0.0
        var folate = 0.0
        var vitaminD = 0.0
        var vitaminB12 = 0.0
        var vitaminE = 0.0
        var vitaminK = 0.0
        var monounsaturatedFat = 0.0
        var polyunsaturatedFat = 0.0
    }

    private struct NutritionDefinition {
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let value: (MealNutritionTotals) -> Double
    }

    private static var nutritionDefinitions: [NutritionDefinition] {
        [
            NutritionDefinition(identifier: .dietaryEnergyConsumed, unit: .kilocalorie(), value: { $0.calories }),
            NutritionDefinition(identifier: .dietaryProtein, unit: .gram(), value: { $0.protein }),
            NutritionDefinition(identifier: .dietaryCarbohydrates, unit: .gram(), value: { $0.carbs }),
            NutritionDefinition(identifier: .dietaryFatTotal, unit: .gram(), value: { $0.fat }),
            NutritionDefinition(identifier: .dietaryFiber, unit: .gram(), value: { $0.fiber }),
            NutritionDefinition(identifier: .dietarySugar, unit: .gram(), value: { $0.sugar }),
            NutritionDefinition(identifier: .dietarySodium, unit: .gramUnit(with: .milli), value: { $0.sodium }),
            NutritionDefinition(identifier: .dietaryFatSaturated, unit: .gram(), value: { $0.saturatedFat }),
            NutritionDefinition(identifier: .dietaryCholesterol, unit: .gramUnit(with: .milli), value: { $0.cholesterol }),
            NutritionDefinition(identifier: .dietaryVitaminC, unit: .gramUnit(with: .milli), value: { $0.vitaminC }),
            NutritionDefinition(identifier: .dietaryCalcium, unit: .gramUnit(with: .milli), value: { $0.calcium }),
            NutritionDefinition(identifier: .dietaryIron, unit: .gramUnit(with: .milli), value: { $0.iron }),
            NutritionDefinition(identifier: .dietaryPotassium, unit: .gramUnit(with: .milli), value: { $0.potassium }),
            NutritionDefinition(identifier: .dietaryMagnesium, unit: .gramUnit(with: .milli), value: { $0.magnesium }),
            NutritionDefinition(identifier: .dietaryZinc, unit: .gramUnit(with: .milli), value: { $0.zinc }),
            NutritionDefinition(identifier: .dietaryFolate, unit: .gramUnit(with: .micro), value: { $0.folate }),
            NutritionDefinition(identifier: .dietaryVitaminD, unit: .gramUnit(with: .micro), value: { $0.vitaminD }),
            NutritionDefinition(identifier: .dietaryVitaminB12, unit: .gramUnit(with: .micro), value: { $0.vitaminB12 }),
            NutritionDefinition(identifier: .dietaryVitaminE, unit: .gramUnit(with: .milli), value: { $0.vitaminE }),
            NutritionDefinition(identifier: .dietaryVitaminK, unit: .gramUnit(with: .micro), value: { $0.vitaminK }),
            NutritionDefinition(identifier: .dietaryFatMonounsaturated, unit: .gram(), value: { $0.monounsaturatedFat }),
            NutritionDefinition(identifier: .dietaryFatPolyunsaturated, unit: .gram(), value: { $0.polyunsaturatedFat }),
        ]
    }

    private static func nutritionTotals(_ foods: [FoodItem]) -> MealNutritionTotals {
        var totals = MealNutritionTotals()
        for food in foods {
            totals.calories += food.calories
            totals.protein += food.protein
            totals.carbs += food.carbs
            totals.fat += food.fat
            totals.fiber += food.fiber
            totals.sugar += food.sugar
            totals.sodium += food.sodium
            totals.saturatedFat += food.satFat
            totals.cholesterol += food.cholesterol
            totals.vitaminC += food.vitaminC
            totals.calcium += food.calcium
            totals.iron += food.iron
            totals.potassium += food.potassium
            totals.magnesium += food.magnesium
            totals.zinc += food.zinc
            totals.folate += food.folate
            totals.vitaminD += food.vitaminD
            totals.vitaminB12 += food.vitaminB12
            totals.vitaminE += food.vitaminE
            totals.vitaminK += food.vitaminK
            totals.monounsaturatedFat += food.monounsaturatedFat
            totals.polyunsaturatedFat += food.polyunsaturatedFat
        }
        return totals
    }

    nonisolated private static func mealDate(from day: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day), !day.isEmpty else { return Date() }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    private static let mealGroupMetadataKey = "com.shiguang.meal_group_id"
    private static let recordSourceMetadataKey = "com.shiguang.record_source"

    nonisolated private static func isAsleepValue(_ value: Int) -> Bool {
        [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ].contains(value)
    }

    nonisolated private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
