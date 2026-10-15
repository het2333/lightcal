import SwiftUI
import UIKit

struct HomePageView: View {
    @ObservedObject var vm: HomeViewModel
    let scrollToTopToken: Int
    let analysisJobs: [MealAnalysisJob]
    let onOpenSettings: () -> Void
    let onOpenFasting: () -> Void
    let onOpenHydration: () -> Void
    let onQuickAddWater: (String) -> Void
    let onOpenSleep: () -> Void
    let onOpenRecordOverview: () -> Void
    let onScanFood: () -> Void
    let onManualLog: () -> Void
    let onOpenRecommendations: () -> Void
    let onOpenMeal: (MealHistoryGroup) -> Void
    let onDismissAnalysisJob: (String) -> Void
    let onRetryAnalysisJob: (String) -> Void
    let onOpenAnalysisJob: (String) -> Void
    let onShareDailyCheckin: () async throws -> Void
    @State private var selectedDate = Date()
    @State private var deletingMealGroupId = ""
    @State private var mealPendingDeletion: MealHistoryGroup?
    @State private var deleteError = ""

    private var visibleAnalysisJobs: [MealAnalysisJob] {
        var hasFailureCard = false
        var output: [MealAnalysisJob] = []

        for job in analysisJobs {
            if case .failed = job.status {
                if hasFailureCard { continue }
                hasFailureCard = true
            }
            output.append(job)
            if output.count >= 3 { break }
        }

        return output
    }

    private var visibleRecentMealGroups: [MealHistoryGroup] {
        var hasFailureCard = false
        var output: [MealHistoryGroup] = []

        for meal in vm.recentMealGroups {
            if meal.isAnalysisFailure {
                if hasFailureCard { continue }
                hasFailureCard = true
            }
            output.append(meal)
            if output.count >= 4 { break }
        }

        return output
    }

    private var waterGoalMl: Double {
        vm.summary?.hydrationGoalMl ?? vm.summary?.waterGoalMl ?? 2100
    }

    private var selectedFastingSession: FastingSession? {
        if let active = vm.fastingStatus?.activeSession {
            return active
        }
        return vm.fastingStatus?.recentSessions?.first { session in
            [session.endedAt, session.startAt]
                .compactMap { $0 }
                .contains { $0.hasPrefix(selectedDayKey) }
        }
    }

    private var hasWellnessActivity: Bool {
        vm.waterMl > 0 || selectedFastingSession != nil
    }

    private var selectedDayKey: String {
        HomeViewModel.dayString(for: selectedDate)
    }

    private var selectedDateLabel: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return "今天"
        }
        if Calendar.current.isDateInYesterday(selectedDate) {
            return "昨天"
        }
        return formattedMonthDay(selectedDate)
    }

    private var selectedDateHeaderText: String {
        if Calendar.current.isDateInToday(selectedDate) || Calendar.current.isDateInYesterday(selectedDate) {
            return "\(selectedDateLabel) · \(formattedMonthDay(selectedDate))"
        }
        return selectedDateLabel
    }

    private func formattedMonthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                    Color.clear
                        .frame(height: 0)
                        .id("homeTop")

                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.94))
                                .shadow(color: Color(hex: "22B8C9").opacity(0.16), radius: 18, x: 0, y: 10)
                            Image("BrandIcon")
                                .resizable()
                                .scaledToFit()
                                .padding(7)
                        }
                        .frame(width: 58, height: 58)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("食光")
                                .font(.system(size: 30, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .lineLimit(1)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 8)

                        Button(action: onOpenFasting) {
                            HStack(spacing: 8) {
                                Image(systemName: "timer")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(Color(hex: "20C05C"))
                                    .frame(width: 28, height: 28)
                                    .background(Color(hex: "E9FBEF"))
                                    .clipShape(Circle())
                                    .accessibilityHidden(true)
                                Text("进食窗口")
                                    .font(.system(size: 14, weight: .black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .black))
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(Color(hex: "111318"))
                            .padding(.leading, 8)
                            .padding(.trailing, 12)
                            .frame(height: 42)
                            .background(.white.opacity(0.86))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(hex: "35C86F").opacity(0.38), lineWidth: 1.4))
                            .shadow(color: Color(hex: "35C86F").opacity(0.10), radius: 14, x: 0, y: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开进食窗口")
                    }
                    .padding(.horizontal, 12)

                    ShiguangDateHeader(selectedDate: selectedDate, onOpenRecordOverview: onOpenRecordOverview)
                        .padding(.horizontal, 12)
                        .padding(.bottom, -10)

                    ShiguangDaySelector(selectedDate: $selectedDate)
                        .padding(.horizontal, 8)

                    CalorieHeroView(
                        summary: vm.summary,
                        waterMl: vm.waterMl,
                        waterGoalMl: waterGoalMl,
                        onOpenHydration: onOpenHydration,
                        onQuickAddWater: { onQuickAddWater(selectedDayKey) },
                        fastingStatus: vm.fastingStatus,
                        onOpenFasting: onOpenFasting,
                        onScanFood: onScanFood
                    )
                    .padding(.horizontal, 16)

                    if vm.weight != nil {
                        HStack(spacing: 12) {
                            WeightCardView(weight: vm.weight)
                        }
                        .padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最近记录")
                                .font(.system(size: 20, weight: .bold))
                            Spacer()
                            Button(action: onOpenRecordOverview) {
                                HStack(spacing: 5) {
                                    Text("查看全部")
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .black))
                                }
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "718095"))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                        if vm.recentMealGroups.isEmpty && visibleAnalysisJobs.isEmpty && !hasWellnessActivity {
                            Button(action: onScanFood) {
                                HStack(spacing: 16) {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "DDF7FF"))
                                            .frame(width: 46, height: 46)
                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 19, weight: .black))
                                            .foregroundStyle(.white)
                                            .frame(width: 36, height: 36)
                                            .background(LinearGradient(colors: [Color(hex: "5FD6E4"), Color(hex: "33BBD4")], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .clipShape(Circle())
                                            .accessibilityHidden(true)
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("今天还没有记录")
                                            .font(.system(size: 15, weight: .black))
                                            .foregroundStyle(Color(hex: "111318"))
                                        Text("记录你的第一餐吧")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Color(hex: "2088E8"))
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    HStack(spacing: 7) {
                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 13, weight: .black))
                                            .accessibilityHidden(true)
                                        Text("拍照记录")
                                            .font(.system(size: 14, weight: .black))
                                    }
                                    .foregroundStyle(Color(hex: "1A8DFF"))
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .background(Color(hex: "EAF4FF"))
                                    .clipShape(Capsule())
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .padding(.horizontal, 18)
                                .background(.white.opacity(0.86))
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.9), lineWidth: 1))
                                .shadow(color: Color(hex: "8BA7C2").opacity(0.10), radius: 18, x: 0, y: 10)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("还没有餐食记录，点这里拍照")
                        } else {
                            VStack(spacing: 12) {
                                if !deleteError.isEmpty {
                                    Text(deleteError)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color(hex: "DC2626"))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(Color(hex: "FFF1F2"))
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                if hasWellnessActivity {
                                    HomeWellnessRecordStack(
                                        waterMl: vm.waterMl,
                                        waterGoalMl: waterGoalMl,
                                        fastingSession: selectedFastingSession,
                                        fastingStatus: vm.fastingStatus,
                                        onOpenHydration: onOpenHydration,
                                        onOpenFasting: onOpenFasting
                                    )
                                }
                                ForEach(visibleAnalysisJobs) { job in
                                    AnalysisJobCard(
                                        job: job,
                                        onScanFood: onScanFood,
                                        onManualLog: onManualLog,
                                        onDismiss: { onDismissAnalysisJob(job.id) },
                                        onRetry: { onRetryAnalysisJob(job.id) },
                                        onOpenResult: { onOpenAnalysisJob(job.id) }
                                    )
                                }
                                ForEach(visibleRecentMealGroups) { meal in
                                    RecentMealCard(
                                        meal: meal,
                                        isDeleting: deletingMealGroupId == meal.id,
                                        onTap: { meal.isAnalysisFailure ? onScanFood() : onOpenMeal(meal) },
                                        onDelete: { mealPendingDeletion = meal }
                                    )
                            }
                        }
                    }

                    HomeRecommendationSection(
                        recommendations: vm.recommendations,
                        onOpenRecommendations: onOpenRecommendations
                    )

                }
                .padding(.horizontal, 14)
                }
                .padding(.top, 6)
                .padding(.bottom, 96)
            }
                .onChange(of: scrollToTopToken) { _, _ in
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                        proxy.scrollTo("homeTop", anchor: .top)
                    }
                }
            }
            .background(AppShellBackground())
            .onAppear { vm.refresh(date: selectedDayKey) }
            .onChange(of: selectedDate) { _, newDate in
                vm.refresh(date: HomeViewModel.dayString(for: newDate))
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("删除这次记录？", isPresented: Binding(
                get: { mealPendingDeletion != nil },
                set: { if !$0 { mealPendingDeletion = nil } }
            )) {
                Button("取消", role: .cancel) {
                    mealPendingDeletion = nil
                }
                Button("删除", role: .destructive) {
                    guard let meal = mealPendingDeletion else { return }
                    mealPendingDeletion = nil
                    Task { await deleteMealGroup(meal) }
                }
            } message: {
                Text(mealPendingDeletion.map { "将删除“\($0.title)”及其中所有食物，删除后无法撤销。" } ?? "删除后无法撤销。")
            }
        }
    }

    private func deleteMealGroup(_ meal: MealHistoryGroup) async {
        guard deletingMealGroupId.isEmpty else { return }
        deletingMealGroupId = meal.id
        deleteError = ""
        defer { deletingMealGroupId = "" }
        do {
            let ids = meal.foods.compactMap(\.id)
            _ = try await APIClient.shared.deleteFoodLogs(ids: ids, uploadGroupId: meal.id.hasPrefix("upload_") ? meal.id : "")
            vm.refresh(date: selectedDayKey)
        } catch {
            deleteError = homeFriendlyError(error, fallback: "这条记录暂时没删掉，检查网络后再点删除。")
        }
    }
}

private struct TopInsightPager: View {
    let summary: DailySummary?
    let score: NutritionScore?
    let sleepSummary: SleepSummary
    let waterMl: Double
    let waterGoalMl: Double
    let onOpenHydration: () -> Void
    let onQuickAddWater: () -> Void
    let fastingStatus: FastingStatus?
    let onOpenFasting: () -> Void
    let onOpenSleep: () -> Void
    let onScanFood: () -> Void
    let onShareDailyCheckin: () async throws -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $page) {
                CalorieHeroView(
                    summary: summary,
                    waterMl: waterMl,
                    waterGoalMl: waterGoalMl,
                    onOpenHydration: onOpenHydration,
                    onQuickAddWater: onQuickAddWater,
                    fastingStatus: fastingStatus,
                    onOpenFasting: onOpenFasting,
                    onScanFood: onScanFood
                )
                .tag(0)

                DailyStatusScoreCard(
                    score: score,
                    sleepSummary: sleepSummary,
                    onOpenSleep: onOpenSleep,
                    onScanFood: onScanFood,
                    onShareDailyCheckin: onShareDailyCheckin
                )
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: page == 0 ? 196 : 286)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: page)

            HStack(spacing: 5) {
                pageDot(0)
                pageDot(1)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }

    private func pageDot(_ index: Int) -> some View {
        Capsule()
            .fill(page == index ? Color(hex: "111318") : Color(hex: "CDD3DB"))
            .frame(width: page == index ? 16 : 6, height: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: page)
    }
}

private func homeFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lower = raw.lowercased()
    if lower.contains("could not connect")
        || lower.contains("connection")
        || lower.contains("timed out")
        || lower.contains("network")
        || raw.contains("连接不到")
        || raw.contains("无法连接") {
        return "现在没连上，这次没保存。检查网络后再点刚才的按钮。"
    }
    if lower.contains("not found") || lower.contains("404") {
        return "这条记录暂时找不到，刷新首页列表。"
    }
    if lower.contains("cancelled") || raw.contains("取消") {
        return "刚才的操作已取消，没有改动记录。"
    }
    if raw.contains("失败")
        || raw.contains("错误")
        || raw.contains("异常")
        || raw.contains("无法")
        || lower.contains("failed")
        || lower.contains("error")
        || lower.contains("exception")
        || lower.contains("server")
        || lower.contains("api") {
        return fallback
    }
    if raw.count > 80 || raw.contains("{") || raw.contains("}") {
        return fallback
    }
    return raw
}

private struct ShiguangDateHeader: View {
    let selectedDate: Date
    let onOpenRecordOverview: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text("今天 · \(monthDay(selectedDate))")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Spacer()
            Button(action: onOpenRecordOverview) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.88))
                    .clipShape(Circle())
                    .shadow(color: Color(hex: "8BA7C2").opacity(0.12), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开记录总览")
        }
    }

    private func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func lunarDate(_ date: Date) -> String {
        let calendar = Calendar(identifier: .chinese)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十", "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十", "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        guard months.indices.contains(month - 1), days.indices.contains(day - 1) else {
            return "农历"
        }
        return "农历\(months[month - 1])\(days[day - 1])"
    }
}

private struct ShiguangDaySelector: View {
    @Binding var selectedDate: Date

    var body: some View {
        HStack(spacing: 0) {
            ForEach(-3...3, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
                let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                let isPastOrSelected = offset <= 0
                VStack(spacing: 5) {
                    Text(weekdaySymbol(date))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "66758A"))
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 35, height: 35)
                        .background(isSelected ? .white.opacity(0.95) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: isSelected ? Color(hex: "8BA7C2").opacity(0.16) : .clear, radius: 12, x: 0, y: 7)
                    Circle()
                        .fill(isSelected ? Color(hex: "1A8DFF") : isPastOrSelected ? Color(hex: "35C86F") : Color(hex: "AAB6C4"))
                        .frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { selectedDate = date }
            }
        }
        .padding(.top, 0)
        .padding(.bottom, 0)
    }

    private func weekdaySymbol(_ date: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: date)
        return ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, weekday - 1))]
    }
}

private struct HomeRecommendationSection: View {
    let recommendations: [MealRecommendation]
    let onOpenRecommendations: () -> Void
    @State private var selectedFilter = "推荐"

    private let filters = ["推荐", "减脂餐", "高蛋白", "家常菜", "素食"]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("为你推荐")
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Button(action: onOpenRecommendations) {
                    HStack(spacing: 6) {
                        Text("换一批")
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .black))
                    }
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "1A8DFF"))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(filters, id: \.self) { filter in
                        Text(filter)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(selectedFilter == filter ? Color(hex: "1FBF58") : Color(hex: "66758A"))
                            .padding(.horizontal, selectedFilter == filter ? 12 : 0)
                            .frame(height: 30)
                            .background(selectedFilter == filter ? Color(hex: "E7FBEF") : .clear)
                            .clipShape(Capsule())
                            .onTapGesture { selectedFilter = filter }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(displayRecommendations.enumerated()), id: \.offset) { index, item in
                        HomeRecommendationCard(item: item, index: index)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.top, 0)
    }

    private var displayRecommendations: [HomeRecommendationItem] {
        if recommendations.isEmpty {
            return [
                HomeRecommendationItem(title: "牛油果鸡胸沙拉", calories: 385, tag: "低卡", tintIndex: 0),
                HomeRecommendationItem(title: "虾仁西兰花炒饭", calories: 482, tag: "高蛋白", tintIndex: 1),
                HomeRecommendationItem(title: "玉米排骨汤", calories: 320, tag: "低脂", tintIndex: 2),
                HomeRecommendationItem(title: "番茄鸡蛋面", calories: 260, tag: "低脂", tintIndex: 3)
            ]
        }
        return Array(recommendations.prefix(4)).enumerated().map { index, rec in
            HomeRecommendationItem(
                title: rec.title,
                calories: rec.calories,
                tag: rec.protein >= 25 ? "高蛋白" : rec.fat <= 12 ? "低脂" : rec.calories <= 400 ? "低卡" : "均衡",
                tintIndex: index
            )
        }
    }
}

private struct HomeRecommendationItem {
    let title: String
    let calories: Double
    let tag: String
    let tintIndex: Int
}

private struct HomeRecommendationCard: View {
    let item: HomeRecommendationItem
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeFoodIllustration(index: index)
                .frame(width: 126, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(item.title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            HStack(spacing: 6) {
                Text("约 \(Int(round(item.calories))) kcal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "66758A"))
                Spacer(minLength: 0)
                Text(item.tag)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(item.tag == "高蛋白" ? Color(hex: "F16B21") : Color(hex: "1FBF58"))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(item.tag == "高蛋白" ? Color(hex: "FFF1E8") : Color(hex: "EAFBEF"))
                    .clipShape(Capsule())
            }
        }
        .padding(6)
        .frame(width: 140)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.88), lineWidth: 1))
        .shadow(color: Color(hex: "8BA7C2").opacity(0.10), radius: 14, x: 0, y: 8)
    }
}

private struct HomeFoodIllustration: View {
    let index: Int

    var body: some View {
        Image("RecommendationDish\(index % 4 + 1)")
            .resizable()
            .scaledToFill()
            .accessibilityHidden(true)
    }
}

private struct DailyStatusScoreCard: View {
    let score: NutritionScore?
    let sleepSummary: SleepSummary
    let onOpenSleep: () -> Void
    let onScanFood: () -> Void
    let onShareDailyCheckin: () async throws -> Void
    @State private var checkinBusy = false
    @State private var checkinMessage = ""
    @State private var checkinError = ""

    private var value: Double {
        score?.score ?? 0
    }

    private var dimensions: [NutritionScoreItem] {
        Array((score?.displayDimensions ?? []).prefix(5))
    }

    private var tint: Color {
        hasStatusData ? statusColor(score?.status ?? "red") : Color(hex: "D8DDE5")
    }

    private var hasStatusData: Bool {
        guard let score else { return false }
        if score.score > 0 { return true }
        if !dimensions.isEmpty { return true }
        if !score.highlights.isEmpty || !score.nextActions.isEmpty || !score.adjustments.isEmpty { return true }
        let headline = score.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return !headline.isEmpty && !headline.contains("先拍") && !headline.contains("先记录")
    }

    private var headlineText: String {
        if hasStatusData, let headline = score?.headline.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
            return headline
        }
        return "记录后生成今日状态。"
    }

    private var actionText: String {
        if let action = score?.nextActions.first ?? score?.adjustments.first,
           !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return action
        }
        return "记录一餐或睡眠。"
    }

    private var sleepButtonTitle: String {
        sleepSummary.logsCount > 0 ? "更新睡眠" : "记录昨晚睡眠"
    }

    private var hasShareableStatus: Bool {
        guard let score else { return false }
        if score.score > 0 { return true }
        if !score.highlights.isEmpty || !score.nextActions.isEmpty { return true }
        let headline = score.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return !headline.isEmpty && !headline.contains("先拍") && !headline.contains("先记录")
    }

    private var checkinButtonTitle: String {
        if checkinBusy { return "正在发布" }
        return hasShareableStatus ? "发今日打卡" : "去记录"
    }

    private var checkinButtonIcon: String {
        hasShareableStatus ? "square.and.arrow.up" : "plus"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今日状态分")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(headlineText)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)
                Spacer()
                Group {
                    if hasStatusData {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("\(Int(round(value)))")
                                .font(.system(size: 40, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .minimumScaleFactor(0.76)
                                .monospacedDigit()
                            Text("/100")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("待记录")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color(hex: "6D7480"))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Color(hex: "F4F6F8"))
                            .clipShape(Capsule())
                    }
                }
                .frame(width: 92, alignment: .trailing)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "EEF0F3"))
                    Capsule()
                        .fill(tint)
                        .frame(width: hasStatusData ? proxy.size.width * min(100, max(0, value)) / 100 : 0)
                }
            }
            .frame(height: 8)

            if dimensions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12, weight: .black))
                    Text("记录后生成状态分")
                        .font(.system(size: 12, weight: .black))
                }
                .foregroundStyle(Color(hex: "6D7480"))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: max(1, min(5, dimensions.count))),
                    spacing: 6
                ) {
                    ForEach(dimensions) { item in
                        dimensionPill(item)
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(hasStatusData ? tint : Color(hex: "111318"))
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(actionText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .lineLimit(2)
            }
            .padding(12)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 10) {
                Button(action: onOpenSleep) {
                    HStack(spacing: 7) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 13, weight: .black))
                            .accessibilityHidden(true)
                        Text(sleepButtonTitle)
                            .font(.system(size: 13, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                    }
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(.white.opacity(0.82))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    if hasShareableStatus {
                        Task { await shareCheckin() }
                    } else {
                        checkinMessage = ""
                        checkinError = ""
                        onScanFood()
                    }
                } label: {
                    HStack(spacing: 7) {
                        if checkinBusy {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: checkinButtonIcon)
                                .font(.system(size: 13, weight: .black))
                                .accessibilityHidden(true)
                            Text(checkinButtonTitle)
                                .font(.system(size: 13, weight: .black))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(checkinBusy)
            }

            if !checkinMessage.isEmpty || !checkinError.isEmpty {
                Text(checkinError.isEmpty ? checkinMessage : checkinError)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(checkinError.isEmpty ? Color(hex: "159BFF") : Color(hex: "DC2626"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .softCard(radius: 24)
    }

    @MainActor
    private func shareCheckin() async {
        guard !checkinBusy else { return }
        checkinBusy = true
        checkinMessage = ""
        checkinError = ""
        defer { checkinBusy = false }
        do {
            try await onShareDailyCheckin()
            checkinMessage = "已发今日打卡"
        } catch {
            checkinError = homeFriendlyError(error, fallback: "今日打卡还没发出去，检查网络后再点发今日打卡。")
        }
    }

    private func dimensionPill(_ item: NutritionScoreItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor(item.status))
                    .frame(width: 6, height: 6)
                Text(item.label)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .lineLimit(1)
            }
            Text("\(Int(round(item.score)))")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .monospacedDigit()
                .lineLimit(1)
            Text("\(formatValue(item.value, unit: item.unit)) / \(formatValue(item.goal, unit: item.unit))\(displayUnit(item.unit))")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(hex: "9AA0AA"))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "green": return Color(hex: "111318")
        case "yellow": return Color(hex: "6D7480")
        default: return Color(hex: "D95C5C")
        }
    }

    private func formatValue(_ value: Double, unit: String) -> String {
        if unit == "小时" {
            return value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
        }
        return "\(Int(round(value)))"
    }

    private func displayUnit(_ unit: String) -> String {
        switch unit {
        case "kcal": return "千卡"
        case "ml": return "毫升"
        case "g": return "克"
        case "mg": return "毫克"
        default: return unit.isEmpty ? "" : "单位"
        }
    }
}

private func homeWellnessProgress(_ session: FastingSession) -> Double {
    let elapsed = max(0, session.elapsedSeconds ?? 0)
    let target = max(1, session.targetSeconds ?? Int((session.fastingHours ?? 0) * 3600))
    return min(1, max(0, Double(elapsed) / Double(target)))
}

private func homeWellnessDuration(_ seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "0分钟" }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 && minutes > 0 {
        return "\(hours)小时\(minutes)分钟"
    }
    if hours > 0 {
        return "\(hours)小时"
    }
    return "\(max(1, minutes))分钟"
}

private struct HomeWellnessGlyph: View {
    let icon: String
    let accent: Color
    var size: CGFloat = 42

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(Color(hex: "111318"))
            Image(systemName: icon)
                .font(.system(size: size * 0.40, weight: .black))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Circle()
                .fill(accent)
                .frame(width: size * 0.24, height: size * 0.24)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .offset(x: size * 0.06, y: size * 0.06)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 6)
    }
}

private struct HomeWellnessRecordStack: View {
    let waterMl: Double
    let waterGoalMl: Double
    let fastingSession: FastingSession?
    let fastingStatus: FastingStatus?
    let onOpenHydration: () -> Void
    let onOpenFasting: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if waterMl > 0 {
                HomeWellnessRecordRow(
                    icon: "drop.fill",
                    title: "补水节奏",
                    subtitle: "\(Int(round(waterMl))) / \(Int(round(waterGoalMl))) 毫升",
                    detail: waterMl >= waterGoalMl ? "已达标" : "\(Int(round(min(100.0, max(0, waterMl / max(1, waterGoalMl)) * 100))))%",
                    tint: Color(hex: "159BFF"),
                    action: onOpenHydration
                )
            }

            if let fastingSession {
                HomeWellnessRecordRow(
                    icon: "timer",
                    title: "进食窗口",
                    subtitle: fastingRecordSubtitle(fastingSession),
                    detail: fastingSession.status == "completed" ? "完成" : "\(Int(round(homeWellnessProgress(fastingSession) * 100)))%",
                    tint: Color(hex: "35C86F"),
                    action: onOpenFasting
                )
            }
        }
    }

    private func fastingRecordSubtitle(_ session: FastingSession) -> String {
        if session.status == "completed" {
            return "\(session.method ?? fastingStatus?.preferences?.method ?? "16:8") · \(homeWellnessDuration(session.elapsedSeconds))"
        }
        if (session.remainingSeconds ?? 0) > 0 {
            return "\(session.method ?? fastingStatus?.preferences?.method ?? "16:8") · 还剩 \(homeWellnessDuration(session.remainingSeconds))"
        }
        return "\(session.method ?? fastingStatus?.preferences?.method ?? "16:8") · 可结束记录"
    }
}

private struct HomeWellnessRecordRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let detail: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HomeWellnessGlyph(icon: icon, accent: tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Text(detail)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
            }
            .padding(14)
            .background(.white.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct PeakRoutineCoachCard: View {
    let summary: DailySummary?
    let score: NutritionScore?
    let sleepSummary: SleepSummary
    let decisionContext: DecisionContext?
    let streak: Int
    let challengeTitle: String?
    let challengeProgress: Double?
    let onOpenSleep: () -> Void
    let onOpenFasting: () -> Void
    let onOpenHydration: () -> Void
    let onOpenSettings: () -> Void

    private var routineScore: Int {
        Int(round(score?.score ?? 0))
    }

    private var recoveryScore: Int {
        let sleepPart: Double
        if sleepSummary.logsCount > 0 {
            let durationRatio = sleepSummary.goalHours > 0 ? min(1, sleepSummary.durationHours / sleepSummary.goalHours) : 0
            let qualityRatio = min(1, max(0, Double(sleepSummary.quality) / 5))
            sleepPart = (durationRatio * 70) + (qualityRatio * 30)
        } else {
            sleepPart = 35
        }
        let movementBonus = min(12, Double(summary?.steps ?? 0) / 10000 * 12)
        return Int(round(min(100, sleepPart + movementBonus)))
    }

    private var routineHeadline: String {
        if recoveryScore < 55 {
            return "今天先补恢复：睡好、喝水、轻走。"
        }
        if routineScore < 70 {
            return "今天节奏还可以，先做最容易的一项。"
        }
        return "今天状态不错，保持饮食和运动节奏。"
    }

    private var coachAdvice: String {
        if let action = score?.nextActions.first, !action.isEmpty {
            return action
        }
        if let body = decisionContext?.coachCards.first?.body, !body.isEmpty {
            return body
        }
        return decisionContext?.suggestedNextMeal.isEmpty == false
            ? (decisionContext?.suggestedNextMeal ?? "")
            : "下一餐优先高蛋白、够蔬菜、少油少加工。"
    }

    private var habitText: String {
        if let challengeTitle, !challengeTitle.isEmpty {
            let pct = Int(round((challengeProgress ?? 0) * 100))
            return pct > 0 ? "\(challengeTitle) · \(pct)%" : challengeTitle
        }
        if streak > 0 {
            return "已连续记录 \(streak) 天"
        }
        return "今天先做一项记录"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: "111318"))
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text("今日节奏教练")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("告诉你今天先补哪一项。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(recoveryScore)")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .monospacedDigit()
                    Text("恢复")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "9AA0AA"))
                }
            }

            Text(routineHeadline)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "374151"))
                .lineLimit(2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                routineMetric(
                    icon: "moon.fill",
                    label: "睡眠",
                    value: sleepSummary.logsCount > 0 ? formatHours(sleepSummary.durationHours) : "未记录",
                    caption: sleepSummary.logsCount > 0 ? sleepSummary.message : "补昨晚睡眠",
                    status: sleepSummary.status,
                    action: onOpenSleep
                )
                routineMetric(
                    icon: "figure.walk",
                    label: "运动",
                    value: "\(summary?.steps ?? 0)步",
                    caption: "目标 10000 步",
                    status: (summary?.steps ?? 0) >= 8000 ? "green" : ((summary?.steps ?? 0) >= 4000 ? "yellow" : "red"),
                    action: onOpenSettings
                )
                routineMetric(
                    icon: "heart.circle.fill",
                    label: "恢复",
                    value: "\(recoveryScore)/100",
                    caption: recoveryScore >= 70 ? "恢复节奏稳定" : "先补水和睡眠",
                    status: recoveryScore >= 70 ? "green" : (recoveryScore >= 50 ? "yellow" : "red"),
                    action: onOpenSleep
                )
                routineMetric(
                    icon: "fork.knife.circle.fill",
                    label: "营养",
                    value: "\(Int(round(summary?.protein ?? 0)))克蛋白",
                    caption: "\(Int(round(summary?.caloriesConsumed ?? 0)))/\(Int(round(summary?.caloriesGoal ?? 0)))千卡",
                    status: score?.displayDimensions.first(where: { $0.id == "nutrition" || $0.label == "饮食" })?.status ?? score?.status ?? "red",
                    action: onOpenSettings
                )
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("心理和习惯")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("\(habitText)。\(coachAdvice)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "6D7480"))
                        .lineLimit(3)
                }
            }
            .padding(12)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 8) {
                routineAction("断食", icon: "timer", action: onOpenFasting)
                routineAction("饮水", icon: "drop.fill", action: onOpenHydration)
                routineAction("目标", icon: "slider.horizontal.3", action: onOpenSettings)
            }
        }
        .padding(16)
        .background(.white.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 22, x: 0, y: 12)
    }

    private func routineMetric(
        icon: String,
        label: String,
        value: String,
        caption: String,
        status: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(statusColor(status))
                        .accessibilityHidden(true)
                    Text(label)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "6D7480"))
                    Spacer()
                    Circle()
                        .fill(statusColor(status))
                        .frame(width: 7, height: 7)
                }
                Text(value)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(caption)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "9AA0AA"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func routineAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(Color(hex: "111318"))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "green": return Color(hex: "2DBE72")
        case "yellow": return Color(hex: "C28A24")
        default: return Color(hex: "E85D5D")
        }
    }

    private func formatHours(_ hours: Double) -> String {
        let rounded = (hours * 10).rounded() / 10
        return rounded.rounded() == rounded ? "\(Int(rounded))小时" : String(format: "%.1f小时", rounded)
    }
}

private struct SleepStatusCard: View {
    let summary: SleepSummary
    let onTap: () -> Void

    private var progress: Double {
        guard summary.goalHours > 0 else { return 0 }
        return min(1, max(0, summary.durationHours / summary.goalHours))
    }

    private var statusColor: Color {
        switch summary.status {
        case "green": return Color(hex: "111318")
        case "yellow": return Color(hex: "6D7480")
        default: return Color(hex: "6D7480")
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color(hex: "EEF0F3"), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(statusColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "moon.fill")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text("睡眠")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(summary.logsCount > 0 ? "\(formatHours(summary.durationHours)) / 目标 \(formatHours(summary.goalHours))" : "记录昨晚睡眠")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(summary.message)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8B94A3"))
                        .lineLimit(1)
                }
                Spacer()
                Text(summary.logsCount > 0 ? "更新" : "记录")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12)
    }

    private func formatHours(_ hours: Double) -> String {
        let rounded = (hours * 10).rounded() / 10
        return rounded.rounded() == rounded ? "\(Int(rounded))小时" : String(format: "%.1f小时", rounded)
    }
}

private struct AnalysisJobCard: View {
    let job: MealAnalysisJob
    let onScanFood: () -> Void
    let onManualLog: () -> Void
    let onDismiss: () -> Void
    let onRetry: () -> Void
    let onOpenResult: () -> Void

    private var progress: Int {
        max(0, min(100, Int(round(job.progress))))
    }

    private var failed: Bool {
        if case .failed = job.status { return true }
        return false
    }

    private var ready: Bool {
        if case .ready = job.status { return true }
        return false
    }

    private var statusTitle: String {
        if failed { return "需要重试一下" }
        if ready { return "识别好了，先检查" }
        return "正在算这餐"
    }

    private var needsFreshScan: Bool {
        let raw = job.message
        let lower = raw.lowercased()
        return raw.contains("Depth")
            || raw.contains("LiDAR")
            || raw.contains("深度")
            || lower.contains("has_depth")
            || lower.contains("capture_pipeline")
            || lower.contains("image_scan")
    }

    private var canRetryCurrentPhoto: Bool {
        job.capture != nil && !needsFreshScan
    }

    private var cleanMessage: String {
        let raw = job.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            if failed { return "重拍会更准，也可以先手动记。" }
            if ready { return "先看食物名和克重，确认后才会记到今天。" }
            return "可以继续浏览首页，处理完成后会留在这里。"
        }
        let lower = raw.lowercased()
        if raw.contains("Could not connect")
            || raw.contains("连接不到后端")
            || raw.contains("连接不到")
            || raw.contains("Not Found")
            || lower.contains("not found")
            || lower.contains("404")
            || lower.contains("connection refused")
            || lower.contains("http ") {
            return "网络刚才不稳，重试这张或拍新照。"
        }
        if raw.contains("Depth") || raw.contains("depth") || raw.contains("LiDAR") {
            return "这次照片信息不完整，拍新照会更稳。"
        }
        if raw.count > 70
            || raw.contains("{")
            || raw.contains("}")
            || lower.contains("api")
            || lower.contains("server")
            || lower.contains("pipeline")
            || lower.contains("metadata")
            || lower.contains("capture_pipeline")
            || lower.contains("image_scan")
            || lower.contains("has_depth")
            || lower.contains("endpoint")
            || lower.contains("input/output")
            || lower.contains("errno")
            || lower.contains("traceback")
            || lower.contains("http") {
            return failed ? "重拍会更准，也可以先手动记。" : "正在分析这餐，保存后可改。"
        }
        if raw.contains("失败")
            || raw.contains("错误")
            || raw.contains("异常")
            || raw.contains("无法")
            || lower.contains("failed")
            || lower.contains("error")
            || lower.contains("exception") {
            return failed ? "重拍会更准，也可以先手动记。" : "正在分析这餐，保存后可改。"
        }
        return raw
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                thumbnail
                    .frame(width: 100, height: 100)
                    .clipped()
                    .saturation(failed ? 0 : 1)
                    .blur(radius: failed ? 0 : 2)
                    .scaleEffect(failed ? 1 : 1.05)
                Color.black.opacity(0.25)
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.28), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: Double(progress) / 100)
                        .stroke(failed ? Color(hex: "EF4444") : .white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(failed ? "!" : ready ? "✓" : "\(progress)%")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .padding(6)
                .background(.black.opacity(0.18))
                .clipShape(Circle())
            }
            .frame(width: 100, height: 100)
            .background(Color(hex: "F1F2F5"))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Spacer()
                    if failed {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(Color(hex: "EF4444"))
                                .frame(width: 28, height: 28)
                                .background(Color(hex: "FFF1F2"))
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除这次失败记录")
                    }
                }
                if !failed && !ready {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 6) {
                            runningHintPill(job.capture?.hasDepthCaptureBundle == true ? "约 20–60 秒" : "约 30–90 秒", icon: "clock")
                            runningHintPill("已等 \(max(0, Int(context.date.timeIntervalSince(job.startedAt)))) 秒", icon: "hourglass")
                            runningHintPill("\(progress)%", icon: "chart.line.uptrend.xyaxis")
                        }
                    }
                }
                Text(cleanMessage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(failed ? Color(hex: "6B7280") : .secondary)
                    .lineLimit(2)
                if ready {
                    Button(action: onOpenResult) {
                        recoveryButtonContent(title: "检查并保存", icon: "checklist.checked", filled: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("检查识别结果")
                } else if failed {
                    HStack(spacing: 8) {
                        if canRetryCurrentPhoto {
                            Button(action: onRetry) {
                                recoveryButtonContent(title: "重试这张", icon: "arrow.clockwise", filled: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("重新分析这张照片")
                        }

                        Button(action: onScanFood) {
                            recoveryButtonContent(title: "拍新照片", icon: "camera.fill", filled: !canRetryCurrentPhoto)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("重新拍一张照片")

                        Button(action: onManualLog) {
                            recoveryButtonContent(title: "手动记", icon: "square.and.pencil", filled: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("手动补记这餐")
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: failed || ready ? 128 : 112)
        .background(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12)
    }

    private func recoveryButtonContent(title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: .black))
        }
        .foregroundStyle(filled ? .white : Color(hex: "111318"))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(filled ? Color(hex: "111318") : Color(hex: "F6F7F9"))
        .clipShape(Capsule())
    }

    private func runningHintPill(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .black))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10, weight: .black))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(Color(hex: "6D7480"))
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = Data(base64Encoded: job.imageBase64), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color(hex: "E5E7EB")
        }
    }
}

private struct RecentMealCard: View {
    let meal: MealHistoryGroup
    let isDeleting: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    private var displayTitle: String {
        meal.isAnalysisFailure ? "照片不完整" : meal.title
    }

    var body: some View {
        let tintColor = meal.isAnalysisFailure ? "F6F7F9" : (meal.adjustedByLeftovers ? "EAF4FF" : "FFF2F0")

        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    mealImage

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayTitle)
                                    .font(.system(size: 16, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                                HStack(spacing: 6) {
                                    sourcePill
                                    if meal.adjustedByLeftovers && !meal.isAnalysisFailure {
                                        Text("食后修正")
                                            .font(.system(size: 10, weight: .black))
                                            .foregroundStyle(Color(hex: "159BFF"))
                                            .padding(.horizontal, 7)
                                            .frame(height: 20)
                                            .background(Color(hex: "EAF4FF"))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            trailingMetadata
                        }

                        HStack(alignment: .center, spacing: 10) {
                            calorieBlock
                            Spacer(minLength: 4)
                            macroGrid
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(meal.isAnalysisFailure ? "照片不完整，点这里重新拍" : "\(meal.title)，\(Int(round(meal.calories)))千卡，点开可修正")
            .accessibilityAction(named: "删除记录") { onDelete() }

            deleteControl
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.94), Color(hex: tintColor).opacity(0.78)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var mealImage: some View {
        if meal.isAnalysisFailure {
            ZStack {
                Color(hex: "F5F7FA")
                VStack(spacing: 7) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22, weight: .black))
                    Text("重拍")
                        .font(.system(size: 11, weight: .black))
                }
                .foregroundStyle(Color(hex: "111318"))
            }
            .frame(width: 86, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "ECEFF3"), lineWidth: 1))
        } else {
            ZStack(alignment: .bottomLeading) {
                if let url = meal.imageUrl {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            imagePlaceholder
                        }
                    }
                } else {
                    imagePlaceholder
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.38)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                Text("\(meal.count)项")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(.black.opacity(0.35))
                    .clipShape(Capsule())
                    .padding(6)
            }
            .frame(width: 86, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            Color(hex: "F1F2F5")
            Image(systemName: "fork.knife")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color(hex: "C6C9D0"))
        }
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private var sourcePill: some View {
        HStack(spacing: 4) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 9, weight: .black))
                .accessibilityHidden(true)
            Text(meal.isAnalysisFailure ? "点这里重拍" : meal.count > 1 ? "一餐 · \(meal.count) 项食物" : "单项记录")
                .font(.system(size: 10, weight: .black))
        }
        .foregroundStyle(meal.isAnalysisFailure ? Color(hex: "111318") : Color(hex: "6B7280"))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(.white.opacity(0.72))
        .clipShape(Capsule())
        .lineLimit(1)
    }

    private var trailingMetadata: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(meal.displayTime)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "9CA3AF"))
                .monospacedDigit()
                .padding(.top, 1)
            if !meal.isAnalysisFailure {
                Text("可修改")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(.white.opacity(0.78))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
            }
        }
    }

    private var deleteControl: some View {
        Button(action: onDelete) {
            if isDeleting {
                ProgressView()
                    .tint(Color(hex: "DC2626"))
                    .scaleEffect(0.72)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: meal.isAnalysisFailure ? "xmark" : "trash")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(meal.isAnalysisFailure ? Color(hex: "6B7280") : Color(hex: "DC2626"))
                    .frame(width: 32, height: 32)
                    .background(meal.isAnalysisFailure ? Color(hex: "F6F7F9") : Color(hex: "FFF1F2"))
                    .clipShape(Circle())
            }
        }
        .disabled(isDeleting)
        .buttonStyle(.plain)
        .accessibilityLabel("删除这次记录")
        .accessibilityHidden(true)
    }

    private var calorieBlock: some View {
        Group {
            if meal.isAnalysisFailure {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .black))
                        .accessibilityHidden(true)
                    Text("重拍更稳")
                        .font(.system(size: 15, weight: .black))
                }
                .foregroundStyle(Color(hex: "111318"))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .bold))
                        .accessibilityHidden(true)
                    Text("\(Int(round(meal.calories)))")
                        .font(.system(size: 20, weight: .black))
                        .monospacedDigit()
                    Text("千卡")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "6B7280"))
                }
                .foregroundStyle(Color(hex: "111318"))
            }
        }
    }

    private var macroGrid: some View {
        Group {
            if meal.isAnalysisFailure {
                Text("没有保存热量")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "9AA0AA"))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(.white.opacity(0.68))
                    .clipShape(Capsule())
            } else {
                HStack(spacing: 4) {
                    macroChip("蛋白", meal.protein, color: "EF5A5A")
                    macroChip("碳水", meal.carbs, color: "E59A42")
                    macroChip("脂肪", meal.fat, color: "4B8FEA")
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }

    private func macroChip(_ label: String, _ value: Double, color: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(Color(hex: color))
            Text("\(Int(round(value)))克")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "6B7280"))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(.white.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "F2F3F5"), lineWidth: 1))
        .lineLimit(1)
    }
}
