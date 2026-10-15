import SwiftUI

@MainActor
class HomeViewModel: ObservableObject {
    @Published var selectedDate = HomeViewModel.todayString()
    @Published var summary: DailySummary?
    @Published var streak = 0
    @Published var waterMl: Double = 0
    @Published var weight: Double?
    @Published var fastingStatus: FastingStatus?
    @Published var isLoading = true
    @Published var recentMealGroups: [MealHistoryGroup] = []
    @Published var sleepSummary = SleepSummary()
    @Published var nutritionScore: NutritionScore?
    @Published var decisionContext: DecisionContext?
    @Published var activeChallengeTitle: String?
    @Published var activeChallengeProgress: Double?
    @Published var recommendations: [MealRecommendation] = []
    @Published var loadError = ""

    func refresh(date: String? = nil) {
        Task {
            let day = date ?? selectedDate
            selectedDate = day
            if summary == nil && nutritionScore == nil && recentMealGroups.isEmpty {
                isLoading = true
            }
            do {
                loadError = ""
                try await loadHomeData(day: day)
            } catch {
                try? await Task.sleep(nanoseconds: 900_000_000)
                do {
                    try await loadHomeData(day: day)
                    loadError = ""
                } catch {
                    loadError = homeLoadFriendlyError(error)
                }
            }
            isLoading = false
        }
    }

    private func loadHomeData(day: String) async throws {
        let loadedSummary = try await APIClient.shared.getDailySummary(date: day)
        summary = loadedSummary
        waterMl = summary?.hydrationEffectiveMl ?? summary?.waterMl ?? 0

        async let st = APIClient.shared.getStreak()
        async let wt = APIClient.shared.getWeights(days: 1)
        async let foods = APIClient.shared.getFoods(date: day, days: 1)
        async let sleep = APIClient.shared.getSleepSummary(date: day)
        async let score = APIClient.shared.getNutritionScore(date: day)
        async let decision = APIClient.shared.getDecisionContext(date: day)
        async let challenges = APIClient.shared.getChallenges()
        async let fasting = APIClient.shared.getFastingStatus()
        async let recs = APIClient.shared.getTodayRecommendations(mealType: "dinner", prepTimeMinutes: 20, limit: 4, useAI: false)

        streak = (try? await st.streakDays) ?? 0
        weight = (try? await wt.first?.weightKg)
        recentMealGroups = MealHistoryGroup.makeGroups(from: (try? await foods) ?? [])
        sleepSummary = (try? await sleep) ?? SleepSummary()
        nutritionScore = try? await score
        decisionContext = try? await decision
        fastingStatus = try? await fasting
        recommendations = (try? await recs.recommendations) ?? []
        let challengeList = (try? await challenges) ?? []
        let activeChallenge = challengeList.first { $0.status == "active" }
            ?? challengeList.first { $0.status == "available" }
        activeChallengeTitle = activeChallenge?.title
        activeChallengeProgress = activeChallenge?.progress?.percent
    }

    static func todayString() -> String {
        dayString(for: Date())
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private func homeLoadFriendlyError(_ error: Error) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
        return "今天数据暂时没加载出来，稍后下拉刷新一次。"
    }
    let lowercased = raw.lowercased()
    if lowercased.contains("could not connect")
        || lowercased.contains("connection")
        || lowercased.contains("timed out")
        || raw.contains("连接不到")
        || raw.contains("无法连接")
        || raw.contains("网络") {
        return "刚才没刷新成功，首页先保留可用数据。"
    }
    if lowercased.contains("not found") || raw.contains("404") {
        return "今天的数据暂时找不到，稍后刷新首页再试。"
    }
    if raw.hasPrefix("{") || raw.hasPrefix("[") || raw.count > 120 || lowercased.contains("json") {
        return "今天数据暂时没加载出来，稍后下拉刷新一次。"
    }
    return raw
}
