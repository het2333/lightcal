import Foundation

struct RecipeMealType: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String

    static let all: [RecipeMealType] = [
        RecipeMealType(id: "breakfast", title: "早餐", icon: "sunrise.fill"),
        RecipeMealType(id: "lunch", title: "午餐", icon: "sun.max.fill"),
        RecipeMealType(id: "dinner", title: "晚餐", icon: "moon.stars.fill"),
        RecipeMealType(id: "snack", title: "加餐", icon: "leaf.fill"),
    ]

    static func normalized(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text == "breakfast" || text.contains("早餐") || text.contains("早饭") || text.contains("morning") {
            return "breakfast"
        }
        if text == "lunch" || text.contains("午餐") || text.contains("中餐") || text.contains("午饭") {
            return "lunch"
        }
        if text == "dinner" || text.contains("晚餐") || text.contains("晚饭") || text.contains("正餐") {
            return "dinner"
        }
        if text == "snack" || text.contains("加餐") || text.contains("零食") || text.contains("点心") || text.contains("下午茶") {
            return "snack"
        }
        return nil
    }

    static func title(for id: String) -> String {
        all.first { $0.id == id }?.title ?? id
    }

    static func normalizedList(_ values: [String]?) -> [String] {
        var result: [String] = []
        for value in values ?? [] {
            if let normalized = normalized(value), !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    static func inferredList(mealTypes: [String]?, tags: [String]?) -> [String] {
        var result = normalizedList(mealTypes)
        for tag in tags ?? [] {
            if let normalized = normalized(tag), !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }
}
