import SwiftUI
import UIKit

struct RecommendationsPageView: View {
    @Environment(\.dismiss) private var dismiss
    let onChanged: () -> Void
    @State private var summary: DailySummary?
    @State private var mealType = "dinner"
    @State private var prepTime = 20
    @State private var deliveryMode = false
    @State private var loading = false
    @State private var message = ""
    @State private var recommendations: [MealRecommendation] = []
    @State private var portions: [String: Double] = [:]
    @State private var loggingId = ""
    @State private var draftingId = ""
    @State private var draft: DeliveryOrderDraft?
    @State private var showRecipeBuilder = false

    @State private var tastes: [String] = ["清淡"]
    @State private var deliveryMealTypes: [String] = ["正餐"]
    @State private var platform = "any"
    @State private var budget = "20-35 元"
    @State private var deliveryTime = "45 分钟内"
    @State private var restrictions: [String] = ["高蛋白", "少油"]
    @State private var variant = 0
    @State private var deliveryPayload: DeliveryRecommendationsResponse?
    @State private var deliveryLoading = false
    @State private var showDeliveryQuick = false
    @State private var showDeliveryFilters = false
    @State private var showHomeFilters = false

    private let mealTypes = [("breakfast", "早餐"), ("lunch", "午餐"), ("dinner", "晚餐"), ("snack", "加餐")]
    private let prepOptions = [15, 20, 30]
    private let tasteOptions = ["清淡", "香辣", "酸辣", "麻辣", "咸鲜", "酱香", "番茄", "咖喱", "日式", "韩式", "中式家常", "西式轻食"]
    private let deliveryTypeOptions = ["正餐", "轻食", "麻辣烫", "米饭套餐", "面/粉", "沙拉", "便利店", "奶茶/饮品", "加餐", "断食后第一餐"]
    private let restrictionOptions = ["不吃辣", "少油", "少糖", "少盐", "不吃猪肉", "不吃牛肉", "不吃海鲜", "不吃香菜", "低碳水", "高蛋白", "控糖友好"]
    private let deliveryQuickOptions = ["想吃辣一点", "想吃便宜点", "想吃更饱", "不想吃轻食", "想吃米饭", "想喝饮品"]

    private var remainingCalories: Double {
        max(0, (summary?.caloriesGoal ?? 2000) - (summary?.caloriesConsumed ?? 0))
    }

    private var proteinGap: Double {
        max(0, (summary?.proteinGoal ?? 80) - (summary?.protein ?? 0))
    }

    private var recommendationHeadline: String {
        if remainingCalories <= 0 {
            return "今天热量差不多了"
        }
        if proteinGap >= 25 {
            return "下一餐先补蛋白"
        }
        if remainingCalories < 450 {
            return "下一餐吃轻一点"
        }
        return "下一餐可以正常吃"
    }

    private var recommendationSubline: String {
        if remainingCalories <= 0 {
            return "优先选清淡、高蛋白、少油的小份。"
        }
        if proteinGap >= 25 {
            return "优先选鸡蛋、鱼虾、鸡胸、豆制品。"
        }
        if remainingCalories < 450 {
            return "控制主食和油，保留蔬菜和蛋白。"
        }
        return "按下面方案吃，今天更容易稳住。"
    }

    private var primaryActionTitle: String {
        if deliveryMode {
            return deliveryLoading ? "正在挑外卖" : "挑一份外卖"
        }
        if loading { return "正在挑下一餐" }
        return recommendations.isEmpty ? "挑一份能吃的" : "换一份方案"
    }

    private var primaryActionIcon: String {
        deliveryMode ? "bag.fill" : "sparkles"
    }

    init(
        initialDeliveryMode: Bool = false,
        initialDeliveryMealTypes: [String] = ["正餐"],
        onChanged: @escaping () -> Void = {}
    ) {
        self.onChanged = onChanged
        _deliveryMode = State(initialValue: initialDeliveryMode)
        _deliveryMealTypes = State(initialValue: initialDeliveryMealTypes)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    statusCard
                    modeTabs
                    if deliveryMode {
                        deliveryControls
                        deliveryResults
                    } else {
                        recommendationControls
                        recommendationResults
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await loadInitial() }
        .sheet(item: $draft) { item in
            DeliveryDraftSheet(draft: item) {
                Task { await logRecommendation(id: item.recommendationId, portion: item.portionMultiplier, mealType: item.mealType ?? mealType) }
            }
        }
        .sheet(isPresented: $showRecipeBuilder) {
            IngredientRecipeSheetView {
                Task { summary = try? await APIClient.shared.getDailySummary() }
                onChanged()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .black))
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
            .accessibilityLabel("返回")
            VStack(alignment: .leading, spacing: 2) {
                Text("今天吃什么")
                    .font(.system(size: 24, weight: .black))
                    .tracking(-0.4)
                Text("先给你一顿能直接吃的方案。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    if deliveryMode { await generateDelivery() } else { await refreshRecommendations() }
                }
            } label: {
                Image(systemName: loading || deliveryLoading ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
            .accessibilityLabel(deliveryMode ? "重新挑外卖" : "重新挑下一餐")
        }
    }

    private var statusCard: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("下一餐怎么吃")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.58))
                    Text(recommendationHeadline)
                        .font(.system(size: 25, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    Text(recommendationSubline)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(2)
                        .lineSpacing(2)
                }
                Spacer()
                Image(systemName: deliveryMode ? "bag.fill" : "fork.knife.circle.fill")
                    .font(.system(size: 38, weight: .black))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            statusMetricRow
            primaryRecommendationActionButton
        }
        .padding(18)
        .background(
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color(hex: "111318"), Color(hex: "23262D")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(hex: "73D1A3").opacity(0.24))
                    .frame(width: 150, height: 150)
                    .offset(x: 58, y: -74)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 26, x: 0, y: 16))
    }

    private var statusMetricRow: some View {
        HStack(spacing: 10) {
            RecommendationMetric(label: "今日还可吃", value: "\(Int(remainingCalories))", unit: "千卡")
            RecommendationMetric(label: "蛋白还差", value: "\(Int(proteinGap))", unit: "克")
            RecommendationMetric(label: "已记录", value: "\(Int(summary?.mealsCount ?? 0))", unit: "餐")
        }
    }

    private var primaryRecommendationActionButton: some View {
        Button { runPrimaryAction() } label: {
            HStack(spacing: 9) {
                if loading || deliveryLoading {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: primaryActionIcon)
                        .accessibilityHidden(true)
                }
                Text(primaryActionTitle)
            }
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(Color(hex: "111318"))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .disabled(loading || deliveryLoading)
        .opacity((loading || deliveryLoading) ? 0.72 : 1)
    }

    private var modeTabs: some View {
        HStack(spacing: 8) {
            modeButton("在家吃", active: !deliveryMode) { deliveryMode = false }
            modeButton("点外卖", active: deliveryMode) { deliveryMode = true }
        }
    }

    private func modeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(active ? .white : Color(hex: "6B7280"))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(active ? Color.black : .white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "F0F0F3"), lineWidth: active ? 0 : 1))
        }
    }

    private var recommendationControls: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            homeFilterSummary
            if showHomeFilters {
                homeFilterControls
            }
            recipeBuilderButton
        }
        .padding(16)
        .softCard(radius: 24))
    }

    private var homeFilterSummary: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("默认按 \(mealLabel(mealType)) · \(prepTime) 分钟挑")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("先看方案，不合适再改餐次和时间。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 8)
            Button {
                showHomeFilters.toggle()
            } label: {
                Text(showHomeFilters ? "收起" : "改条件")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color(hex: "F4F5F7"))
                    .clipShape(Capsule())
            }
        }
    }

    private var homeFilterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            chipRow(mealTypes.map { ($0.0, $0.1) }, selection: $mealType) {
                Task { await refreshRecommendations() }
            }
            prepTimeRow
        }
    }

    private var prepTimeRow: some View {
        HStack(spacing: 8) {
            ForEach(prepOptions, id: \.self) { minutes in
                Button {
                    prepTime = minutes
                    Task { await refreshRecommendations() }
                } label: {
                    Text("\(minutes) 分钟")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(prepTime == minutes ? .white : Color(hex: "6B7280"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(prepTime == minutes ? Color.black : .white)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var recipeBuilderButton: some View {
        Button { showRecipeBuilder = true } label: {
            Label("用家里食材凑一餐", systemImage: "chef.hat")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.black)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var recommendationResults: some View {
        if loading && recommendations.isEmpty {
            loadingCard("正在按今天缺口挑下一餐，大约几秒...")
        }
        if !message.isEmpty {
            messageCard
        }
        if recommendations.isEmpty && !loading {
            emptyCard(
                "先挑一份能吃的",
                "我会按剩余热量、蛋白缺口和偏好给你一餐。",
                buttonTitle: "挑一份能吃的"
            ) {
                Task { await refreshRecommendations() }
            }
        }
        ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, rec in
            recommendationCard(rec, rank: index)
        }
    }

    private func recommendationCard(_ rec: MealRecommendation, rank: Int) -> AnyView {
        let portion = portions[rec.id] ?? 1
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(rank == 0 ? "最推荐" : mealLabel(rec.mealType)) · \(rec.source == "ai_enhanced" ? "按今天缺口挑" : "可直接吃")")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(rank == 0 ? Color(hex: "159BFF") : Color(hex: "6B7280"))
                    Text(rec.title)
                        .font(.system(size: 17, weight: .black))
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(round(rec.calories * portion)))")
                        .font(.system(size: 24, weight: .black))
                    Text("千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }
            Text(rec.reason)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
            Text("蛋白 \(Int(round(rec.protein * portion)))克 · 碳水 \(Int(round(rec.carbs * portion)))克 · 脂肪 \(Int(round(rec.fat * portion)))克 · \(rec.prepTimeMinutes) 分钟")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "4B5563"))
            if !rec.foods.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(rec.foods.prefix(4)) { food in
                        Text("\(food.name) \(Int(round(food.calories * portion)))千卡")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                }
            }
            HStack(spacing: 9) {
                portionStepper(id: rec.id)
                Button { Task { await createDraft(rec) } } label: {
                    Label(draftingId == rec.id ? "正在写" : "点单备注", systemImage: "bag")
                        .font(.system(size: 13, weight: .black))
                        .frame(width: 86, height: 40)
                        .background(.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                }
                .disabled(draftingId == rec.id)
                Button { Task { await logRecommendation(id: rec.id, portion: portion, mealType: rec.mealType) } } label: {
                    Text(loggingId == rec.id ? "正在保存" : "保存到今天")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .disabled(loggingId == rec.id)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12))
    }

    private var deliveryControls: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("先按默认给你挑")
                        .font(.system(size: 17, weight: .black))
                    Text("\(budget) · \(deliveryTime) · \(deliveryMealTypes.prefix(2).joined(separator: "、"))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showDeliveryFilters.toggle()
                } label: {
                    Text(showDeliveryFilters ? "收起" : "改条件")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color(hex: "F4F5F7"))
                        .clipShape(Capsule())
                }
            }

            if showDeliveryFilters {
                tagSection("口味", values: tasteOptions, selection: $tastes)
                tagSection("类型", values: deliveryTypeOptions, selection: $deliveryMealTypes)
                tagSection("限制", values: restrictionOptions, selection: $restrictions)
                HStack(spacing: 8) {
                    optionButton("都可以", active: platform == "any") { platform = "any" }
                    optionButton("美团", active: platform == "meituan") { platform = "meituan" }
                    optionButton("饿了么", active: platform == "eleme") { platform = "eleme" }
                }
                HStack(spacing: 8) {
                    optionButton("20 元内", active: budget == "20 元内") { budget = "20 元内" }
                    optionButton("20-35 元", active: budget == "20-35 元") { budget = "20-35 元" }
                    optionButton("35-50 元", active: budget == "35-50 元") { budget = "35-50 元" }
                    optionButton("不限", active: budget == "不限") { budget = "不限" }
                }
                HStack(spacing: 8) {
                    optionButton("30 分钟内", active: deliveryTime == "30 分钟内") { deliveryTime = "30 分钟内" }
                    optionButton("45 分钟内", active: deliveryTime == "45 分钟内") { deliveryTime = "45 分钟内" }
                    optionButton("不限", active: deliveryTime == "不限") { deliveryTime = "不限" }
                }
            }
            Button { Task { await generateDelivery() } } label: {
                Label(deliveryLoading ? "正在挑外卖" : "帮我选外卖", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .disabled(deliveryLoading)
        }
        .padding(16)
        .softCard(radius: 24))
    }

    @ViewBuilder
    private var deliveryResults: some View {
        if deliveryLoading && deliveryPayload == nil {
            loadingCard("正在按今天缺口筛外卖，大约几秒...")
        }
        if let payload = deliveryPayload {
            ForEach(payload.recommendations) { item in
                deliveryCard(item)
            }
            if !payload.moreOptions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("更多可点")
                        .font(.system(size: 17, weight: .black))
                    ForEach(payload.moreOptions) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.system(size: 14, weight: .black)).lineLimit(1)
                        Text("\(item.platformLabel) · ¥\(Int(round(item.priceYuan))) · \(item.deliveryMinutes) 分钟")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(round(item.calories))) 千卡")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .softCard(radius: 22)
            }
            HStack(spacing: 8) {
                Button {
                    variant += 1
                    Task { await generateDelivery() }
                } label: {
                Label(deliveryLoading ? "正在换" : "换一批", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "ECEEF2"), lineWidth: 1))
                }
                .disabled(deliveryLoading)

                Button {
                    showDeliveryQuick.toggle()
                } label: {
                    Label("我想吃点别的", systemImage: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "ECEEF2"), lineWidth: 1))
                }
            }

            if showDeliveryQuick {
                VStack(alignment: .leading, spacing: 10) {
                    Text("快速调整")
                        .font(.system(size: 15, weight: .black))
                    FlowTags(values: deliveryQuickOptions, active: []) { option in
                        applyDeliveryQuick(option)
                    }
                }
                .padding(16)
                .softCard(radius: 22)
            }
        } else if !deliveryLoading {
            emptyCard(
                "先让食光选一份",
                "默认按少油、高蛋白和当前预算筛，想改口味再展开条件。",
                buttonTitle: "帮我选外卖"
            ) {
                Task { await generateDelivery() }
            }
        }
    }

    private func deliveryCard(_ item: DeliveryMealRecommendation) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.restaurantName) · \(item.platformLabel)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(size: 17, weight: .black))
                        .lineLimit(2)
                }
                Spacer()
                Text("适合 \(Int(round(item.score)))")
                    .font(.system(size: 12, weight: .black))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }
            Text("约 \(Int(round(item.calories))) 千卡 · 蛋白 \(Int(round(item.protein)))克 · ¥\(Int(round(item.priceYuan))) · \(item.deliveryMinutes) 分钟")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "4B5563"))
            Text(item.reason)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
            if let warning = item.warnings?.first, !warning.isEmpty {
                Text(warning)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Text(item.suggestions?.first ?? item.orderNote)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { Task { await logRecommendation(id: item.logId, portion: 1, mealType: item.mealType ?? "dinner") } } label: {
                Label(loggingId == item.logId ? "正在保存" : "保存到今天", systemImage: "bag")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .disabled(loggingId == item.logId)
        }
        .padding(16)
        .softCard(radius: 22))
    }

    private func chipRow(_ items: [(String, String)], selection: Binding<String>, afterChange: @escaping () -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { item in
                    Button {
                        selection.wrappedValue = item.0
                        afterChange()
                    } label: {
                        Text(item.1)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(selection.wrappedValue == item.0 ? .white : Color(hex: "6B7280"))
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(selection.wrappedValue == item.0 ? Color.black : .white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func tagSection(_ title: String, values: [String], selection: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            FlowTags(values: values, active: selection.wrappedValue) { value in
                selection.wrappedValue = toggle(selection.wrappedValue, value)
            }
        }
    }

    private func optionButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(active ? .white : Color(hex: "6B7280"))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(active ? Color.black : Color(hex: "F7F8FA"))
                .clipShape(Capsule())
        }
    }

    private func portionStepper(id: String) -> some View {
        let value = portions[id] ?? 1
        return HStack(spacing: 4) {
            Button { portions[id] = max(0.5, ((value - 0.1) * 10).rounded() / 10) } label: { Image(systemName: "minus") }
                .accessibilityLabel("减少份量")
            Text(String(format: "%.1fx", value))
                .font(.system(size: 13, weight: .black))
                .frame(width: 42)
            Button { portions[id] = min(2, ((value + 0.1) * 10).rounded() / 10) } label: { Image(systemName: "plus") }
                .accessibilityLabel("增加份量")
        }
        .font(.system(size: 13, weight: .black))
        .frame(height: 40)
        .padding(.horizontal, 8)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private func loadingCard(_ text: String) -> AnyView {
        AnyView(HStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .softCard(radius: 22))
    }

    private func runPrimaryAction() {
        Task {
            if deliveryMode {
                await generateDelivery()
            } else {
                await refreshRecommendations()
            }
        }
    }

    private func emptyCard(_ title: String, _ body: String, buttonTitle: String? = nil, action: (() -> Void)? = nil) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 17, weight: .black))
            Text(body)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let buttonTitle, let action {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .softCard(radius: 22))
    }

    private var messageCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: recommendationMessageNeedsAttention(message) ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(recommendationMessageNeedsAttention(message) ? Color(hex: "DC2626") : Color(hex: "22A06B"))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(recommendationMessageNeedsAttention(message) ? Color(hex: "DC2626") : Color(hex: "4B5563"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .softCard(radius: 18)
    }

    private func loadInitial() async {
        summary = try? await APIClient.shared.getDailySummary()
        await refreshRecommendations()
    }

    private func refreshRecommendations() async {
        loading = true
        message = ""
        do {
            let response = try await APIClient.shared.getTodayRecommendations(mealType: mealType, prepTimeMinutes: prepTime, limit: 4)
            recommendations = response.recommendations
            if recommendations.isEmpty {
                message = "这次没挑出合适方案，换个餐次或时间再试。"
            }
        } catch {
            message = friendlyRecommendationError(error, fallback: "下一餐方案暂时没生成，换个餐次或检查网络后再点生成。")
        }
        loading = false
    }

    private func logRecommendation(id: String, portion: Double, mealType: String) async {
        loggingId = id
        message = ""
        do {
            let response = try await APIClient.shared.logRecommendation(id: id, portionMultiplier: portion, mealCategory: mealType)
            if let responseSummary = response.summary {
                summary = responseSummary
            } else {
                summary = try? await APIClient.shared.getDailySummary()
            }
            onChanged()
            message = response.alreadyLogged == true
                ? "这餐已经记录过了。"
                : "已保存这餐，共 \(response.saved ?? 0) 项食物。"
        } catch {
            message = friendlyRecommendationError(error, fallback: "这餐还没保存成功，检查网络后再点保存这餐。")
        }
        loggingId = ""
    }

    private func createDraft(_ rec: MealRecommendation) async {
        draftingId = rec.id
        message = ""
        do {
            let response = try await APIClient.shared.createDeliveryDraft(
                recommendationId: rec.id,
                portionMultiplier: portions[rec.id] ?? 1
            )
            draft = response.draft
        } catch {
            message = friendlyRecommendationError(error, fallback: "下单备注暂时没整理好，可以先直接保存这餐。")
        }
        draftingId = ""
    }

    private func generateDelivery() async {
        deliveryLoading = true
        message = ""
        do {
            deliveryPayload = try await APIClient.shared.getDeliveryRecommendations(
                tastes: tastes,
                mealTypes: deliveryMealTypes,
                platform: platform,
                budget: budget,
                deliveryTime: deliveryTime,
                restrictions: restrictions,
                variant: variant,
                limit: 3
            )
        } catch {
            message = friendlyRecommendationError(error, fallback: "外卖方案暂时没生成，换个预算后再试。")
        }
        deliveryLoading = false
    }

    private func friendlyRecommendationError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("could not connect")
            || lower.contains("connection")
            || lower.contains("timed out")
            || lower.contains("offline")
            || raw.contains("连接不到")
            || raw.contains("无法连接")
            || raw.contains("网络") {
            return "现在没连上，方案还没生成；检查网络后再点生成方案。"
        }
        if lower.contains("not found") || raw.contains("404") {
            return "这次没找到合适方案，换个餐次或预算再试。"
        }
        if raw.hasPrefix("{") || raw.hasPrefix("[") || raw.count > 120 || lower.contains("json") {
            return fallback
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
        return raw.isEmpty ? fallback : raw
    }

    private func recommendationMessageNeedsAttention(_ message: String) -> Bool {
        message.contains("失败")
            || message.contains("错误")
            || message.contains("连不上")
            || message.contains("连接不到")
            || message.contains("无法")
            || message.contains("暂时")
            || message.contains("还没")
            || message.contains("没挑出")
    }

    private func mealLabel(_ type: String) -> String {
        ["breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"][type] ?? "下一餐"
    }

    private func toggle(_ values: [String], _ value: String) -> [String] {
        values.contains(value) ? values.filter { $0 != value } : values + [value]
    }

    private func applyDeliveryQuick(_ option: String) {
        switch option {
        case "想吃辣一点":
            tastes = Array(Set(tastes.filter { $0 != "清淡" } + ["香辣"])).sorted()
        case "想吃便宜点":
            budget = "20 元内"
        case "想吃更饱":
            if !deliveryMealTypes.contains("米饭套餐") {
                deliveryMealTypes.append("米饭套餐")
            }
        case "不想吃轻食":
            deliveryMealTypes.removeAll { $0 == "轻食" || $0 == "沙拉" }
        case "想吃米饭":
            if !deliveryMealTypes.contains("米饭套餐") {
                deliveryMealTypes.append("米饭套餐")
            }
        case "想喝饮品":
            if !deliveryMealTypes.contains("奶茶/饮品") {
                deliveryMealTypes.append("奶茶/饮品")
            }
        default:
            break
        }
        deliveryPayload = nil
        showDeliveryQuick = false
    }
}

private struct RecommendationMetric: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(.white)
            Text(unit)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowTags: View {
    let values: [String]
    let active: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
            ForEach(values, id: \.self) { value in
                Button { onTap(value) } label: {
                    Text(value)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(active.contains(value) ? .white : Color(hex: "6B7280"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(active.contains(value) ? Color.black : Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

private struct DeliveryDraftSheet: View {
    let draft: DeliveryOrderDraft
    let onLog: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("外卖点单草稿")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(draft.restaurantHint)
                            .font(.system(size: 22, weight: .black))
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 36, height: 36)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Circle())
                    }
            .accessibilityLabel("关闭下单备注")
                }
                HStack(spacing: 8) {
                    SmallDraftMetric(label: "时间", value: "\(draft.etaMinutes)分")
                    SmallDraftMetric(label: "配送费", value: "¥\(Int(round(draft.feeYuan)))")
                    SmallDraftMetric(label: "热量", value: "\(Int(round(draft.nutrition.calories)))")
                }
                infoBlock("搜索关键词", draft.searchQuery)
                infoBlock("点单备注", draft.orderNote)
                VStack(alignment: .leading, spacing: 8) {
                    Text("餐品")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                    ForEach(draft.orderItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 14, weight: .black)).lineLimit(1)
                                Text("\(item.servingSize) · 蛋白 \(Int(round(item.protein)))克")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(round(item.calories))) 千卡")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                if !draft.guardrails.isEmpty {
                    FlowTags(values: draft.guardrails, active: draft.guardrails) { _ in }
                }
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = draft.copyText ?? "\(draft.searchQuery)\n\(draft.orderNote)"
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                    Button {
                        onLog()
                        dismiss()
                    } label: {
                        Text("记录")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 96, height: 48)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .background(AppShellBackground())
    }

    private func infoBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "111318"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SmallDraftMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .black))
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
