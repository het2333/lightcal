import SwiftUI
import UIKit

struct HistoryPageView: View {
    let onScanFood: (() -> Void)?

    @State private var summary: DailySummary?
    @State private var goalPlan: GoalPlan?
    @State private var macroGoals: MacroGoals?
    @State private var weights: [WeightLog] = []
    @State private var foods: [FoodLogRow] = []
    @State private var meals: [MealHistoryGroup] = []
    @State private var hydration: [HydrationLog] = []
    @State private var exercises: [ExerciseEntry] = []
    @State private var streakDays = 0
    @State private var selectedDay = Calendar.current.component(.day, from: Date())
    @State private var selectedTab: ProgressDashboardTab = .weight
    @State private var selectedRange = "6个月"
    @State private var showProgressEntry = false
    @State private var weightInput = ""
    @State private var isSavingProgress = false
    @State private var progressMessage = ""
    @State private var loadError: String?
    @State private var showAllWeightRows = false
    @State private var showRecordOverview = false

    private let ranges: [(String, Int)] = [("90天", 90), ("6个月", 180), ("1年", 365), ("全部", 1000)]

    init(onScanFood: (() -> Void)? = nil) {
        self.onScanFood = onScanFood
    }

    private var currentWeight: Double {
        let value = weights.last?.weightKg ?? summary?.weightKg ?? goalPlan?.currentWeightKg ?? 0
        return value > 0 ? value : 0
    }

    private var startingWeight: Double {
        if let first = weights.first?.weightKg, first > 0 { return first }
        if let current = goalPlan?.currentWeightKg, current > 0 { return current }
        return 0
    }

    private var goalWeight: Double {
        let value = goalPlan?.goalWeightKg ?? 0
        return value > 0 ? value : 0
    }

    private var dailyGoal: Double {
        let value = summary?.caloriesGoal ?? goalPlan?.dailyCalorieTarget ?? macroGoals?.dailyCalories ?? 0
        return value > 0 ? value : 0
    }

    private var weightDelta: Double { currentWeight - startingWeight }

    private var remainingWeight: Double { max(0, abs(currentWeight - goalWeight)) }

    private var weightGoalProgress: Double {
        let total = abs(startingWeight - goalWeight)
        guard total > 0 else { return 0 }
        return clamp(abs(startingWeight - currentWeight) / total * 100)
    }

    private var todayCalories: Double { summary?.caloriesConsumed ?? foodsForToday.reduce(0) { $0 + ($1.calories ?? 0) } }
    private var todayProtein: Double { summary?.protein ?? foodsForToday.reduce(0) { $0 + ($1.protein ?? 0) } }
    private var todayCarbs: Double { summary?.carbs ?? foodsForToday.reduce(0) { $0 + ($1.carbs ?? 0) } }
    private var todayFat: Double { summary?.fat ?? foodsForToday.reduce(0) { $0 + ($1.fat ?? 0) } }

    private var foodsForToday: [FoodLogRow] {
        let key = Self.dayString(Date())
        return foods.filter { ($0.date ?? "") == key }
    }

    private var weeklyEnergy: [WeeklyEnergyDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: foods) { $0.date ?? "" }
            .mapValues { rows in
                WeeklyEnergyAggregate(
                    calories: rows.reduce(0) { $0 + ($1.calories ?? 0) },
                    protein: rows.reduce(0) { $0 + ($1.protein ?? 0) }
                )
            }
        return (0..<7).map { index in
            let date = calendar.date(byAdding: .day, value: index - 6, to: Date()) ?? Date()
            let key = Self.dayString(date)
            let aggregate = grouped[key] ?? WeeklyEnergyAggregate(calories: 0, protein: 0)
            let weekday = calendar.component(.weekday, from: date)
            let label = ["日", "一", "二", "三", "四", "五", "六"][max(0, weekday - 1)]
            return WeeklyEnergyDay(
                key: key,
                label: label,
                calories: aggregate.calories,
                protein: aggregate.protein,
                ratio: dailyGoal > 0 ? clamp(aggregate.calories / dailyGoal * 100, max: 130) : 0
            )
        }
    }

    private var recordedDaysCount: Int {
        Set(foods.compactMap(\.date).filter { !$0.isEmpty }).count
    }

    private var calorieTargetRate: Int {
        let recorded = weeklyEnergy.filter { $0.calories > 0 }
        guard !recorded.isEmpty, dailyGoal > 0 else { return 0 }
        let rate = recorded.reduce(0.0) { total, day in
            total + clamp(100 - abs(day.calories - dailyGoal) / dailyGoal * 100)
        } / Double(recorded.count)
        return Int(round(rate))
    }

    private var proteinHitDays: Int {
        let proteinGoal = summary?.proteinGoal ?? macroGoals?.proteinG ?? 0
        guard proteinGoal > 0 else { return 0 }
        let count = weeklyEnergy.filter { $0.protein >= proteinGoal * 0.85 }.count
        return count
    }

    private var bmr: Double {
        goalPlan?.bmr ?? 0
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let width = max(0, proxy.size.width - 28)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        compactHeader
                        compactTabs
                        if let loadError {
                            ProgressNoticeCard(message: loadError) { loadProgress() }
                        }
                        selectedContent
                    }
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 102)
                }
                .background(AppShellBackground())
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { loadProgress() }
            .sheet(isPresented: $showProgressEntry) {
                weightEntrySheet
            }
            .fullScreenCover(isPresented: $showRecordOverview) {
                RecordOverviewPageView(
                    onClose: { showRecordOverview = false },
                    onStartRecord: {
                        showRecordOverview = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onScanFood?()
                        }
                    }
                )
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("进度")
                    .font(.system(size: 27, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("看见身体变化，坚持就会有收获")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "7B8492"))
            }
            Spacer()
            Button(action: handleAddAction) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black)
                    .clipShape(Circle())
            }
        }
    }

    private var compactTabs: some View {
        HStack(spacing: 0) {
            ForEach(ProgressDashboardTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 8) {
                        Text(tab.title)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(selectedTab == tab ? Color(hex: "16B75B") : Color(hex: "697386"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .allowsTightening(true)
                        Capsule()
                            .fill(selectedTab == tab ? Color(hex: "16B75B") : .clear)
                            .frame(height: 2.5)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 43)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .weight:
            if currentWeight > 0 {
                weightPage
            } else {
                progressEmptyState(
                    title: "还没有体重记录",
                    message: "记下第一次体重，之后才会生成真实趋势。",
                    buttonTitle: "记录体重",
                    icon: "scalemass.fill"
                ) { showProgressEntry = true }
            }
        case .diet:
            if !foods.isEmpty || todayCalories > 0 {
                dietPage
            } else {
                progressEmptyState(
                    title: "还没有饮食数据",
                    message: "先记录一餐，再根据真实摄入生成分析。",
                    buttonTitle: "拍照记录",
                    icon: "camera.fill"
                ) { onScanFood?() }
            }
        case .body:
            if currentWeight > 0 || bmr > 0 {
                bodyPage
            } else {
                progressEmptyState(
                    title: "还没有身体数据",
                    message: "目前不会用演示值代替你的真实指标。",
                    buttonTitle: "先记体重",
                    icon: "person.fill"
                ) { showProgressEntry = true }
            }
        case .habits:
            habitsPage
        }
    }

    private func progressEmptyState(
        title: String,
        message: String,
        buttonTitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        ProgressCard {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(Color(hex: "16B75B"))
                    .frame(width: 58, height: 58)
                    .background(Color(hex: "E8F8EE"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(message)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "6F7784"))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color(hex: "16B75B"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private var weightPage: some View {
        VStack(spacing: 10) {
            ProgressCard {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("当前体重")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "6F7784"))
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(String(format: "%.1f", currentWeight))
                                .font(.system(size: 30, weight: .black))
                            Text("kg")
                                .font(.system(size: 15, weight: .black))
                        }
                        HStack(spacing: 8) {
                            Label(String(format: "%.1f kg", abs(weightDelta)), systemImage: weightDelta <= 0 ? "arrow.down" : "arrow.up")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "17A957"))
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(Color(hex: "E8F8EE"))
                                .clipShape(Capsule())
                            Text("较起始")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: "6F7784"))
                        }
                        Spacer(minLength: 2)
                        HStack(spacing: 28) {
                            miniValue("起始体重", startingWeight > 0 ? String(format: "%.1f kg", startingWeight) : "--")
                            miniValue("目标体重", goalWeight > 0 ? String(format: "%.1f kg", goalWeight) : "--")
                        }
                    }
                    Spacer()
                    ProgressCircularRateView(
                        rate: goalWeight > 0 ? Int(round(weightGoalProgress)) : nil,
                        title: goalWeight > 0 ? "目标进度" : "目标未设置"
                    )
                        .frame(width: 116, height: 116)
                }
            }

            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    chartHeader("体重变化趋势")
                    if weights.count >= 2 {
                        ProgressWeightLineChart(points: weightChartPoints, showAllLabels: false)
                            .frame(height: 178)
                        insightStrip(title: "趋势解读", text: weightTrendInsight)
                    } else {
                        Text("已记下第一次体重。再记一次，才会开始判断变化趋势。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "6F7784"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 18)
                    }
                }
            }

            recordListCard(
                title: "体重记录",
                actionTitle: showAllWeightRows ? "收起" : "查看全部",
                rows: showAllWeightRows ? weightRows : Array(weightRows.prefix(5)),
                canToggleRows: weightRows.count > 5,
                onToggleRows: { showAllWeightRows.toggle() },
                buttonTitle: "记录体重",
                buttonIcon: "plus"
            ) {
                showProgressEntry = true
            }
        }
    }

    private var dietPage: some View {
        VStack(spacing: 10) {
            ProgressCard {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("今日饮食概览")
                            .font(.system(size: 13, weight: .black))
                        metricBlock("总摄入", "\(Int(round(todayCalories)))", "kcal")
                        metricBlock("还可摄入", dailyGoal > 0 ? "\(max(0, Int(round(dailyGoal - todayCalories))))" : "--", "kcal")
                    }
                    Spacer()
                    MacroRingView(value: todayCalories, goal: dailyGoal)
                        .frame(width: 126, height: 126)
                }
                HStack(spacing: 18) {
                    macroBar("蛋白质", value: todayProtein, goal: summary?.proteinGoal ?? macroGoals?.proteinG ?? 0, tint: Color(hex: "20C15A"))
                    macroBar("碳水", value: todayCarbs, goal: summary?.carbsGoal ?? macroGoals?.carbsG ?? 0, tint: Color(hex: "FDBA3B"))
                    macroBar("脂肪", value: todayFat, goal: summary?.fatGoal ?? macroGoals?.fatG ?? 0, tint: Color(hex: "FF8A35"))
                }
            }

            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    chartHeader("每日热量趋势")
                    ProgressCalorieBarChart(days: weeklyEnergy, goal: dailyGoal)
                        .frame(height: 186)
                }
            }

            mealRecordList
        }
    }

    private var bodyPage: some View {
        VStack(spacing: 10) {
            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("身体概览")
                        .font(.system(size: 13, weight: .black))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        bodyMetricCard("当前体重", currentWeight > 0 ? String(format: "%.1f", currentWeight) : "--", "kg", "来自真实记录")
                        bodyMetricCard("目标体重", goalWeight > 0 ? String(format: "%.1f", goalWeight) : "--", "kg", goalWeight > 0 ? "来自你的目标" : "尚未设置")
                        bodyMetricCard("基础代谢", bmr > 0 ? "\(Int(round(bmr)))" : "--", "kcal", bmr > 0 ? "根据已保存资料计算" : "尚未计算")
                        bodyMetricCard("已记录", "\(weights.count)", "次", weights.count >= 2 ? "可查看趋势" : "再记1次生成趋势")
                    }
                }
            }

            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    chartHeader("体重趋势")
                    if weights.count >= 2 {
                        bodyTrendRow("体重 (kg)", value: String(format: "%.1f", currentWeight), values: weightTrendValues)
                    } else {
                        Text("再记录一次体重，这里会生成真实趋势。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "7B8492"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 14)
                    }
                }
            }

            recordListCard(
                title: "体重记录",
                actionTitle: showAllWeightRows ? "收起" : "查看全部",
                rows: showAllWeightRows ? weightRows : Array(weightRows.prefix(5)),
                canToggleRows: weightRows.count > 5,
                onToggleRows: { showAllWeightRows.toggle() },
                buttonTitle: "记录体重",
                buttonIcon: "plus"
            ) {
                showProgressEntry = true
            }
        }
    }

    private var habitsPage: some View {
        VStack(spacing: 10) {
            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("目标进度")
                        .font(.system(size: 13, weight: .black))
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("体重目标")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: "6F7784"))
                            Text(goalWeight > 0 ? String(format: "%.1f kg", goalWeight) : "--")
                                .font(.system(size: 27, weight: .black))
                            Text("目标体重")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(hex: "8A909A"))
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("已完成")
                                Spacer()
                                Text("\(Int(round(weightGoalProgress)))%")
                                    .font(.system(size: 20, weight: .black))
                            }
                            .font(.system(size: 12, weight: .bold))
                            ProgressCapsuleBar(value: weightGoalProgress, tint: Color(hex: "16B75B"), height: 8)
                            HStack {
                                miniValue("距离目标", currentWeight > 0 && goalWeight > 0 ? String(format: "%.1f kg", remainingWeight) : "--")
                                miniValue("预计达成", goalPlan?.targetDate ?? goalPlan?.goalDate ?? "尚未设置")
                            }
                        }
                    }
                }
            }

            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("我的习惯", trailing: "")
                    habitRow(icon: "takeoutbag.and.cup.and.straw.fill", title: "每天记录饮食", subtitle: "连续 \(max(streakDays, 0)) 天", progress: Double(min(12, max(streakDays, 0))) / 12 * 100)
                    habitRow(icon: "drop.fill", title: "每天喝水 ≥ 8 杯", subtitle: "本周 \(hydrationDaysCount)/7 天", progress: Double(hydrationDaysCount) / 7 * 100)
                    habitRow(icon: "figure.run", title: "每周运动 ≥ 3 次", subtitle: "本周 \(weeklyExerciseCount)/3 次", progress: Double(min(3, weeklyExerciseCount)) / 3 * 100)
                    habitRow(icon: "moon.zzz.fill", title: "晚睡不熬夜", subtitle: "尚未同步睡眠数据", progress: 0)
                }
            }

            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("我的目标", trailing: "")
                    goalRow(icon: "flame.fill", title: "每日热量目标", subtitle: dailyGoal > 0 ? "\(Int(round(dailyGoal))) kcal" : "尚未设置", progress: dailyGoal > 0 ? todayCalories / dailyGoal * 100 : 0)
                    goalRow(icon: "figure.walk", title: "每周活动目标", subtitle: "\(weeklyExerciseCount) / 3 次", progress: Double(min(3, weeklyExerciseCount)) / 3 * 100)
                    goalRow(icon: "drop.fill", title: "每日饮水目标", subtitle: "\(Int(todayHydrationMl / 250)) / 8 杯", progress: todayHydrationMl / 2000 * 100)
                }
            }

            ProgressCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("成就徽章", trailing: "已获得 \(badgeCount) 个")
                    HStack(spacing: 14) {
                        badge("leaf.fill", Color(hex: "74D05A"), unlocked: recordedDaysCount >= 3)
                        badge("flame.fill", Color(hex: "FF7A45"), unlocked: streakDays >= 7)
                        badge("briefcase.fill", Color(hex: "72C85F"), unlocked: weeklyExerciseCount >= 3)
                        badge("calendar.badge.checkmark", Color(hex: "FF9D45"), unlocked: hydrationDaysCount >= 3)
                        badge("star.fill", Color(hex: "FFC83D"), unlocked: weightGoalProgress >= 25)
                    }
                }
            }
        }
    }

    private var mealRecordList: some View {
        ProgressCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("饮食记录", trailing: "查看全部") {
                    showRecordOverview = true
                }
                ForEach(displayMeals.prefix(3)) { meal in
                    ProgressMealListRow(meal: meal)
                }
                Button(action: { onScanFood?() }) {
                    Label("记录饮食", systemImage: "plus")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "16B75B"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "E5E8EC"), lineWidth: 1))
                }
            }
        }
    }

    private var weightChartPoints: [ProgressWeightPoint] {
        let sorted = weights.sorted { $0.date < $1.date }
        return sampledWeights(sorted, maxCount: 7)
    }

    private var weightTrendValues: [Double] {
        let values = weights.suffix(6).map(\.weightKg)
        return Array(values)
    }

    private var weightRows: [ProgressListRowData] {
        let rows = weights.sorted { $0.date > $1.date }.map {
            ProgressListRowData(title: shortDateLabel($0.date), detail: "早上", value: String(format: "%.1f kg", $0.weightKg))
        }
        return Array(rows)
    }

    private var weightTrendInsight: String {
        let delta = weightDelta
        if abs(delta) < 0.05 { return "体重目前基本稳定。" }
        let direction = delta < 0 ? "下降" : "上升"
        return "从首次记录到现在\(direction) \(String(format: "%.1f", abs(delta))) kg。"
    }

    private var displayMeals: [ProgressMealDisplay] {
        if !meals.isEmpty {
            return meals.map {
                ProgressMealDisplay(
                    id: $0.id,
                    time: $0.displayTime.isEmpty ? "--:--" : $0.displayTime,
                    meal: mealTitle(from: $0.displayTime),
                    title: $0.title,
                    calories: Int(round($0.calories)),
                    imageUrl: $0.imageUrl,
                    assetName: nil
                )
            }
        }
        return []
    }

    private var hydrationDaysCount: Int {
        Set(hydration.compactMap(\.date)).count
    }

    private var weeklyExerciseCount: Int {
        let keys = Set(lastSevenDayKeys())
        return exercises.filter { keys.contains($0.date) }.count
    }

    private var todayHydrationMl: Double {
        let key = Self.dayString(Date())
        let value = hydration.filter { $0.date == key }.reduce(0) { $0 + $1.effectiveMl }
        return value > 0 ? value : (summary?.hydrationMl ?? summary?.waterMl ?? 0)
    }

    private var badgeCount: Int {
        [recordedDaysCount >= 3, streakDays >= 7, weeklyExerciseCount >= 3, hydrationDaysCount >= 3, weightGoalProgress >= 25].filter { $0 }.count
    }

    private var weightEntrySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(Color(hex: "DEDEE5"))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
            Text("记录体重")
                .font(.system(size: 24, weight: .black))
            TextField(String(format: "%.1f", currentWeight), text: $weightInput)
                .keyboardType(.decimalPad)
                .font(.system(size: 22, weight: .black))
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button { Task { await saveWeight() } } label: {
                Text(isSavingProgress ? "正在保存" : "保存体重")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .disabled(isSavingProgress)
            if !progressMessage.isEmpty {
                Text(progressMessage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(progressMessageNeedsAttention(progressMessage) ? Color(hex: "DC2626") : Color(hex: "4B5563"))
            }
        }
        .padding(22)
        .presentationDetents([.height(290)])
        .presentationDragIndicator(.hidden)
    }

    private func loadProgress(days: Int? = nil) {
        let nextDays = days ?? ranges.first(where: { $0.0 == selectedRange })?.1 ?? 180
        Task {
            do {
                async let weightRows = APIClient.shared.getWeights(days: nextDays)
                async let foodRows = APIClient.shared.getFoods(days: max(nextDays, 30))
                async let daySummary = APIClient.shared.getDailySummary()
                async let plan = APIClient.shared.getGoalPlan()
                async let goals = APIClient.shared.getMacroGoals()
                async let streak = APIClient.shared.getStreak()
                async let hydrationRows = APIClient.shared.getHydration(days: 30)
                async let exerciseRows = APIClient.shared.getExercises()

                weights = ((try? await weightRows) ?? []).sorted { $0.date < $1.date }
                foods = (try? await foodRows) ?? []
                summary = try? await daySummary
                goalPlan = try? await plan
                macroGoals = try? await goals
                streakDays = (try? await streak.streakDays) ?? 0
                hydration = (try? await hydrationRows) ?? []
                exercises = (try? await exerciseRows) ?? []
                meals = MealHistoryGroup.makeGroups(from: foods)
                loadError = nil
            } catch {
                loadError = historyFriendlyError(error, fallback: "进度数据暂时没加载出来，稍后刷新一次。")
            }
        }
    }

    private func saveWeight() async {
        guard !isSavingProgress else { return }
        let raw = weightInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(raw), value > 0 else {
            progressMessage = "先输入数字，比如 62.4。"
            return
        }
        isSavingProgress = true
        defer { isSavingProgress = false }
        do {
            try await APIClient.shared.addWeight(kg: value)
            weightInput = ""
            progressMessage = "体重已保存。"
            showProgressEntry = false
            loadProgress()
        } catch {
            progressMessage = historyFriendlyError(error, fallback: "体重暂时没保存上，检查网络后再点保存。")
        }
    }

    private func handleAddAction() {
        switch selectedTab {
        case .diet:
            onScanFood?()
        default:
            showProgressEntry = true
        }
    }

    private func chartHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .black))
            Spacer()
            HStack(spacing: 7) {
                ForEach(ranges, id: \.0) { range in
                    Button {
                        selectedRange = range.0
                        loadProgress(days: range.1)
                    } label: {
                        Text(range.0)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(selectedRange == range.0 ? Color(hex: "16B75B") : Color(hex: "8A909A"))
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                            .background(selectedRange == range.0 ? Color(hex: "E8F8EE") : .clear)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func miniValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "7B8492"))
            Text(value)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func metricBlock(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "7B8492"))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 25, weight: .black))
                Text(unit)
                    .font(.system(size: 13, weight: .bold))
            }
        }
    }

    private func macroBar(_ title: String, value: Double, goal: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(round(value))) g")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(hex: "4B5563"))
            ProgressCapsuleBar(value: goal > 0 ? value / goal * 100 : 0, tint: tint, height: 5)
            Text("达标 \(Int(round(goal > 0 ? value / goal * 100 : 0)))%")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "7B8492"))
        }
    }

    private func bodyMetricCard(_ title: String, _ value: String, _ unit: String, _ subtitle: String, positive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "6F7784"))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .black))
                Text(unit)
                    .font(.system(size: 11, weight: .bold))
            }
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(positive ? Color(hex: "16B75B") : Color(hex: "7B8492"))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(Color(hex: "F7F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bodyTrendRow(_ title: String, value: String, values: [Double]) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "6F7784"))
                .frame(width: 80, alignment: .leading)
            MiniLine(values: values)
                .frame(height: 28)
            Text(value)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "16B75B"))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func habitRow(icon: String, title: String, subtitle: String, progress: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color(hex: "16B75B"))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .black))
                Text(subtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "7B8492"))
            }
            Spacer()
            ProgressCapsuleBar(value: progress, tint: Color(hex: "16B75B"), height: 7)
                .frame(width: 86)
        }
        .padding(10)
        .background(Color(hex: "F7F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func goalRow(icon: String, title: String, subtitle: String, progress: Double) -> some View {
        habitRow(icon: icon, title: title, subtitle: subtitle, progress: progress)
    }

    private func badge(_ icon: String, _ color: Color, unlocked: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .black))
            .foregroundStyle(unlocked ? color : Color(hex: "B8BEC8"))
            .frame(width: 46, height: 46)
            .background(unlocked ? color.opacity(0.14) : Color(hex: "F0F2F5"))
            .clipShape(Circle())
            .opacity(unlocked ? 1 : 0.55)
    }

    private func sectionTitle(_ title: String, trailing: String, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .black))
            Spacer()
            if !trailing.isEmpty {
                if let action {
                    Button(trailing, action: action)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "687180"))
                } else {
                    Text(trailing)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8A909A"))
                }
            }
        }
    }

    private func insightStrip(title: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "16B75B"))
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "6F7784"))
                .lineLimit(2)
            Spacer()
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "16B75B"))
                .frame(width: 34, height: 34)
                .background(Color(hex: "E8F8EE"))
                .clipShape(Circle())
        }
        .padding(12)
        .background(Color(hex: "F0FAF4"))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func recordListCard(
        title: String,
        actionTitle: String,
        rows: [ProgressListRowData],
        canToggleRows: Bool,
        onToggleRows: @escaping () -> Void,
        buttonTitle: String,
        buttonIcon: String,
        action: @escaping () -> Void
    ) -> some View {
        ProgressCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(title, trailing: canToggleRows ? actionTitle : "", action: canToggleRows ? onToggleRows : nil)
                ForEach(rows) { row in
                    ProgressSimpleListRow(row: row)
                }
                Button(action: action) {
                    Label(buttonTitle, systemImage: buttonIcon)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "16B75B"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "E5E8EC"), lineWidth: 1))
                }
            }
        }
    }

    private func sampledWeights(_ rows: [WeightLog], maxCount: Int) -> [ProgressWeightPoint] {
        let strideValue = max(1, rows.count / maxCount)
        return rows.enumerated()
            .filter { $0.offset % strideValue == 0 || $0.offset == rows.count - 1 }
            .map { ProgressWeightPoint(label: shortDateLabel($0.element.date), value: $0.element.weightKg) }
            .suffix(maxCount)
            .map { $0 }
    }

    private func shortDateLabel(_ value: String) -> String {
        let parts = value.split(separator: "-")
        guard parts.count >= 3 else { return value }
        return "\(parts[1])/\(parts[2])"
    }

    private func mealTitle(from time: String) -> String {
        guard let hour = Int(time.prefix(2)) else { return "餐食" }
        if hour < 10 { return "早餐" }
        if hour < 15 { return "午餐" }
        if hour < 21 { return "晚餐" }
        return "加餐"
    }

    private func lastSevenDayKeys() -> [String] {
        (0..<7).compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date()).map(Self.dayString)
        }
    }

    private func clamp(_ value: Double, min: Double = 0, max: Double = 100) -> Double {
        Swift.min(max, Swift.max(min, value))
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct RecordOverviewPageView: View {
    let onClose: () -> Void
    let onStartRecord: () -> Void

    @State private var summary: DailySummary?
    @State private var weights: [WeightLog] = []
    @State private var foods: [FoodLogRow] = []
    @State private var hydration: [HydrationLog] = []
    @State private var exercises: [ExerciseEntry] = []
    @State private var streakDays = 0
    @State private var selectedDay = Calendar.current.component(.day, from: Date())
    @State private var selectedMealGroup: MealHistoryGroup?

    private var currentMonthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: Date())
    }

    private var recordedDays: Int {
        Set(foods.compactMap(\.date)).count
    }

    private var averageCalories: Int {
        let grouped = Dictionary(grouping: foods) { $0.date ?? "" }
        let values = grouped.values.map { rows in rows.reduce(0) { $0 + ($1.calories ?? 0) } }
        guard !values.isEmpty else { return Int(round(summary?.caloriesConsumed ?? 0)) }
        return Int(round(values.reduce(0, +) / Double(values.count)))
    }

    private var weightChange: Double? {
        guard weights.count >= 2, let first = weights.first?.weightKg, let last = weights.last?.weightKg else { return nil }
        return last - first
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(width: 40, height: 40)
                        }
                        Spacer()
                        Text("记录总览")
                            .font(.system(size: 18, weight: .black))
                        Spacer()
                        Color.clear.frame(width: 40, height: 40)
                    }

                    Text(currentMonthTitle + " 〉")
                        .font(.system(size: 18, weight: .black))

                    CalendarMonthGrid(
                        foodDays: foodDays,
                        hydrationDays: hydrationDays,
                        weightDays: weightDays,
                        selectedDay: $selectedDay
                    )
                        .padding(.vertical, 6)

                    calendarLegend
                    selectedDaySection

                    ProgressCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("记录总览（本月）")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(hex: "6F7784"))
                            HStack(spacing: 20) {
                                overviewMetric("记录天数", "\(recordedDays)", "天")
                                overviewMetric("平均热量", "\(averageCalories)", "kcal")
                                overviewMetric("体重变化", weightChange.map { String(format: "%+.1f", $0) } ?? "--", "kg")
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        overviewRow(icon: "scalemass.fill", tint: Color(hex: "348CFF"), title: "体重记录", value: "\(weights.count) 次")
                        overviewRow(icon: "flame.fill", tint: Color(hex: "FF8A3D"), title: "饮食记录", value: "\(foods.count) 次")
                        overviewRow(icon: "person.fill", tint: Color(hex: "4C8EF7"), title: "身体数据", value: "\(weights.count) 次")
                        overviewRow(icon: "figure.run", tint: Color(hex: "42C45E"), title: "运动记录", value: "\(exercises.count) 次")
                        overviewRow(icon: "drop.fill", tint: Color(hex: "37A4FF"), title: "喝水记录", value: "\(hydration.count) 杯")
                        overviewRow(icon: "checkmark.seal.fill", tint: Color(hex: "28C76F"), title: "习惯打卡", value: "\(streakDays) 次")
                    }

                    Button(action: onStartRecord) {
                        Label("开始记录", systemImage: "plus")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                LinearGradient(colors: [Color(hex: "18C766"), Color(hex: "08A84E")], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .clipShape(Capsule())
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { loadOverview() }
            .fullScreenCover(item: $selectedMealGroup) { meal in
                MealGroupDetailPageView(group: meal) {
                    selectedMealGroup = nil
                    loadOverview()
                } onChanged: { _ in
                    loadOverview()
                }
            }
        }
    }

    private var foodDays: Set<Int> {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: Date())
        let days = foods.compactMap { row -> Int? in
            guard let date = row.date, date.hasPrefix(month) else { return nil }
            return Int(date.suffix(2))
        }
        return Set(days)
    }

    private var hydrationDays: Set<Int> {
        monthDays(from: hydration.compactMap(\.date))
    }

    private var weightDays: Set<Int> {
        monthDays(from: weights.map(\.date))
    }

    private var selectedDateKey: String {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        guard let first = Calendar.current.date(from: components),
              let date = Calendar.current.date(byAdding: .day, value: selectedDay - 1, to: first)
        else { return HistoryPageView.dayString(Date()) }
        return HistoryPageView.dayString(date)
    }

    private var selectedGroups: [MealHistoryGroup] {
        MealHistoryGroup.makeGroups(from: foods.filter { $0.date == selectedDateKey })
    }

    private var selectedHydrationTotal: Double {
        hydration.filter { $0.date == selectedDateKey }.reduce(0) { $0 + $1.amountMl }
    }

    private var selectedWeight: Double? {
        weights.last(where: { $0.date == selectedDateKey })?.weightKg
    }

    private var calendarLegend: some View {
        HStack(spacing: 16) {
            calendarLegendItem("饮食", color: Color(hex: "FF8A3D"))
            calendarLegendItem("饮水", color: Color(hex: "37A4FF"))
            calendarLegendItem("体重", color: Color(hex: "28C76F"))
            Spacer()
            Text("点日期查看")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
        }
    }

    private var selectedDaySection: some View {
        ProgressCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(Calendar.current.component(.month, from: Date()))月\(selectedDay)日")
                        .font(.system(size: 18, weight: .black))
                    Spacer()
                    HStack(spacing: 8) {
                        if selectedHydrationTotal > 0 {
                            Label("\(Int(round(selectedHydrationTotal))) ml", systemImage: "drop.fill")
                                .foregroundStyle(Color(hex: "37A4FF"))
                        }
                        if let selectedWeight {
                            Label(String(format: "%.1f kg", selectedWeight), systemImage: "scalemass.fill")
                                .foregroundStyle(Color(hex: "28C76F"))
                        }
                    }
                    .font(.system(size: 10, weight: .black))
                }

                if selectedGroups.isEmpty {
                    Text("当天还没有饮食记录")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(selectedGroups) { group in
                        Button {
                            selectedMealGroup = group
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "fork.knife")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Color(hex: "FF8A3D"))
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                        .font(.system(size: 13, weight: .black))
                                        .lineLimit(1)
                                    Text("\(group.count) 项 · \(group.displayTime)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(Int(round(group.calories))) kcal")
                                    .font(.system(size: 12, weight: .black))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(Color(hex: "A0A7B2"))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看餐食：\(group.title)，\(Int(round(group.calories)))千卡")
                    }
                }
            }
        }
    }

    private func calendarLegendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
        }
    }

    private func monthDays(from dateStrings: [String]) -> Set<Int> {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: Date())
        return Set(dateStrings.compactMap { value in
            guard value.hasPrefix(month) else { return nil }
            return Int(value.suffix(2))
        })
    }

    private func overviewMetric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "7B8492"))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .black))
                Text(unit)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "7B8492"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overviewRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 15, weight: .black))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .black))
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.8), lineWidth: 1))
    }

    private func loadOverview() {
        Task {
            async let weightRows = APIClient.shared.getWeights(days: 60)
            async let foodRows = APIClient.shared.getFoods(days: 35)
            async let hydrationRows = APIClient.shared.getHydration(days: 35)
            async let exerciseRows = APIClient.shared.getExercises()
            async let daySummary = APIClient.shared.getDailySummary()
            async let streak = APIClient.shared.getStreak()

            weights = ((try? await weightRows) ?? []).sorted { $0.date < $1.date }
            foods = (try? await foodRows) ?? []
            hydration = (try? await hydrationRows) ?? []
            exercises = (try? await exerciseRows) ?? []
            summary = try? await daySummary
            streakDays = (try? await streak.streakDays) ?? 0
        }
    }
}

private enum ProgressDashboardTab: CaseIterable, Identifiable {
    case weight
    case diet
    case body
    case habits

    var id: String { title }
    var title: String {
        switch self {
        case .weight: return "体重趋势"
        case .diet: return "饮食分析"
        case .body: return "身体数据"
        case .habits: return "习惯与目标"
        }
    }
}

private struct WeeklyEnergyAggregate {
    let calories: Double
    let protein: Double
}

private struct WeeklyEnergyDay: Identifiable {
    let key: String
    let label: String
    let calories: Double
    let protein: Double
    let ratio: Double
    var id: String { key }
}

private struct ProgressWeightPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

private struct ProgressListRowData: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let value: String
}

private struct ProgressMealDisplay: Identifiable {
    let id: String
    let time: String
    let meal: String
    let title: String
    let calories: Int
    let imageUrl: URL?
    let assetName: String?
}

private struct ProgressCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.86), lineWidth: 1))
            .shadow(color: Color(hex: "111318").opacity(0.045), radius: 14, x: 0, y: 8)
    }
}

private struct ProgressCircularRateView: View {
    let rate: Int?
    var title: String = "目标进度"

    private var normalizedRate: Int { min(100, max(0, rate ?? 0)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: "E7F3EA"), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(normalizedRate) / 100)
                .stroke(Color(hex: "35C95E"), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "7B8492"))
                Text(rate.map { "\($0)%" } ?? "--")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
            }
        }
    }
}

private struct MacroRingView: View {
    let value: Double
    let goal: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: "E7F3EA"), lineWidth: 11)
            Circle()
                .trim(from: 0.0, to: 0.37)
                .stroke(Color(hex: "5B8DFF"), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0.42, to: 0.70)
                .stroke(Color(hex: "FFC250"), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0.75, to: 0.98)
                .stroke(Color(hex: "62CD73"), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text("已摄入")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "7B8492"))
                Text("\(Int(round(value)))")
                    .font(.system(size: 17, weight: .black))
                Text("目标 \(Int(round(goal)))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "7B8492"))
            }
        }
    }
}

private struct ProgressCapsuleBar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: "ECEFF3"))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, value))) / 100)
            }
        }
        .frame(height: height)
    }
}

private struct ProgressWeightLineChart: View {
    let points: [ProgressWeightPoint]
    var showAllLabels = true

    var body: some View {
        GeometryReader { proxy in
            let left: CGFloat = 28
            let right: CGFloat = 10
            let top: CGFloat = 12
            let bottom: CGFloat = 24
            let width = max(1, proxy.size.width - left - right)
            let height = max(1, proxy.size.height - top - bottom)
            let values = points.map(\.value)
            let minValue = floor((values.min() ?? 58) - 1)
            let maxValue = ceil((values.max() ?? 66) + 1)
            let range = max(1, maxValue - minValue)
            let coordinates = points.enumerated().map { index, point in
                CGPoint(
                    x: left + (points.count <= 1 ? width / 2 : CGFloat(index) / CGFloat(points.count - 1) * width),
                    y: top + height - CGFloat((point.value - minValue) / range) * height
                )
            }

            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let y = top + CGFloat(index) / 3 * height
                    Path { path in
                        path.move(to: CGPoint(x: left, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width - right, y: y))
                    }
                    .stroke(Color(hex: "DCE1E8"), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    Text("\(Int(maxValue - Double(index) / 3 * range))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8A909A"))
                        .position(x: 10, y: y)
                }

                Path { path in
                    guard let first = coordinates.first else { return }
                    path.move(to: first)
                    coordinates.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Color(hex: "16B75B"), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                ForEach(Array(coordinates.enumerated()), id: \.offset) { item in
                    Circle()
                        .fill(item.offset == coordinates.count - 1 ? .white : Color(hex: "16B75B"))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(hex: "16B75B"), lineWidth: 2))
                        .position(item.element)
                }

                if let first = coordinates.first, let firstValue = points.first?.value {
                    Text(String(format: "%.1f", firstValue))
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Color(hex: "16B75B"))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .position(x: first.x, y: max(10, first.y - 18))
                }

                if let last = coordinates.last, let lastValue = points.last?.value {
                    Text(String(format: "%.1f", lastValue))
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "16B75B"))
                        .position(x: min(proxy.size.width - 20, last.x + 24), y: last.y - 8)
                }

                ForEach(Array(points.enumerated()), id: \.offset) { item in
                    if showAllLabels || item.offset == 0 || item.offset == points.count - 1 || item.offset % 2 == 0 {
                        Text(item.element.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: "8A909A"))
                            .position(
                                x: left + (points.count <= 1 ? width / 2 : CGFloat(item.offset) / CGFloat(points.count - 1) * width),
                                y: proxy.size.height - 8
                            )
                    }
                }
            }
        }
    }
}

private struct ProgressCalorieBarChart: View {
    let days: [WeeklyEnergyDay]
    let goal: Double

    var body: some View {
        GeometryReader { proxy in
            let maxCalories = max(goal * 1.25, days.map(\.calories).max() ?? 2100)
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(days) { day in
                    VStack(spacing: 7) {
                        Text(day.calories > 0 ? "\(Int(round(day.calories)))" : "")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: "6F7784"))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(day.calories >= goal * 0.95 && day.calories <= goal * 1.12 ? Color(hex: "41C968") : Color(hex: "FFA987"))
                            .frame(height: max(12, CGFloat(day.calories / maxCalories) * (proxy.size.height - 38)))
                        Text(day.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: "7B8492"))
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

private struct MiniLine: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let minValue = values.min() ?? 0
            let maxValue = values.max() ?? 1
            let range = max(1, maxValue - minValue)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: values.count <= 1 ? proxy.size.width / 2 : CGFloat(index) / CGFloat(values.count - 1) * proxy.size.width,
                    y: proxy.size.height - CGFloat((value - minValue) / range) * proxy.size.height
                )
            }
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(Color(hex: "16B75B"), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct ProgressMealListRow: View {
    let meal: ProgressMealDisplay

    var body: some View {
        HStack(spacing: 10) {
            mealImage
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(meal.meal)
                        .font(.system(size: 14, weight: .black))
                    Text(meal.time)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "8A909A"))
                }
                Text(meal.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "5E6878"))
                    .lineLimit(1)
            }
            Spacer()
            Text("\(meal.calories) kcal")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "16B75B"))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var mealImage: some View {
        if let url = meal.imageUrl {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
        } else if let assetName = meal.assetName {
            Image(assetName).resizable().scaledToFill()
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(hex: "F1F4F7")
            Image(systemName: "fork.knife")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "B8C0CB"))
        }
    }
}

private struct ProgressSimpleListRow: View {
    let row: ProgressListRowData

    var body: some View {
        HStack {
            Text(row.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "4B5563"))
            Text(row.detail)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "8A909A"))
            Spacer()
            Text(row.value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(height: 36)
    }
}

private struct CalendarMonthGrid: View {
    let foodDays: Set<Int>
    let hydrationDays: Set<Int>
    let weightDays: Set<Int>
    @Binding var selectedDay: Int

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        VStack(spacing: 12) {
            HStack {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "4B5563"))
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(monthCells, id: \.self) { day in
                    if day == 0 {
                        Color.clear.frame(height: 32)
                    } else {
                        Button {
                            selectedDay = day
                        } label: {
                            VStack(spacing: 4) {
                                Text("\(day)")
                                    .font(.system(size: selectedDay == day ? 13 : 12, weight: .bold))
                                    .foregroundStyle(selectedDay == day ? .white : Color(hex: "111318"))
                                    .frame(width: 31, height: 31)
                                    .background(selectedDay == day ? Color(hex: "111318") : .clear)
                                    .clipShape(Circle())
                                HStack(spacing: 2) {
                                    recordDot(visible: foodDays.contains(day), color: Color(hex: "FF8A3D"))
                                    recordDot(visible: hydrationDays.contains(day), color: Color(hex: "37A4FF"))
                                    recordDot(visible: weightDays.contains(day), color: Color(hex: "28C76F"))
                                }
                                .frame(height: 5)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(day)日，查看当天记录")
                    }
                }
            }
        }
    }

    private func recordDot(visible: Bool, color: Color) -> some View {
        Circle()
            .fill(visible ? color : Color.clear)
            .frame(width: 4, height: 4)
    }

    private var monthCells: [Int] {
        let calendar = Calendar.current
        let now = Date()
        let comps = calendar.dateComponents([.year, .month], from: now)
        guard let first = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let leading = calendar.component(.weekday, from: first) - 1
        return Array(repeating: 0, count: leading) + Array(range)
    }
}

private struct ProgressNoticeCard: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "DC2626"))
            Text(message)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "6F7784"))
                .lineLimit(2)
            Spacer()
            Button("刷新", action: action)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "16B75B"))
        }
        .padding(12)
        .background(Color(hex: "FFF7F7"))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private func historyFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lower = raw.lowercased()
    if lower.contains("could not connect")
        || lower.contains("connection")
        || lower.contains("timed out")
        || raw.contains("连接不到")
        || raw.contains("无法连接") {
        return "现在没连上，稍后刷新一次。"
    }
    if lower.contains("not found") || raw.contains("404") {
        return "这条记录暂时找不到，刷新列表。"
    }
    if raw.count > 120 || raw.contains("{") || raw.contains("}") {
        return fallback
    }
    return raw
}

private func progressMessageNeedsAttention(_ message: String) -> Bool {
    message.contains("失败")
        || message.contains("错误")
        || message.contains("没")
        || message.contains("不能")
        || message.contains("无法")
        || message.contains("暂时")
        || message.contains("连不上")
        || message.contains("连接不到")
}
