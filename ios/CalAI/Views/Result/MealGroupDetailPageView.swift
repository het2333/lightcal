import SwiftUI

enum MealDetailInitialAction {
    case leftover
    case fix
}

struct MealGroupDetailPageView: View {
    let group: MealHistoryGroup
    var initialAction: MealDetailInitialAction? = nil
    let onClose: () -> Void
    var onChanged: (String?) -> Void = { _ in }
    @State private var showLeftoverCamera = false
    @State private var estimatingLeftovers = false
    @State private var leftoverEstimate: LeftoverEstimateResponse?
    @State private var leftoverImageBase64 = ""
    @State private var leftoverError: String?
    @State private var showFixSheet = false
    @State private var fixStatus: String?
    @State private var didRunInitialAction = false
    @State private var communityShareStatus: String?
    @State private var sharingCommunity = false

    private var title: String {
        group.title.isEmpty ? "餐食记录" : group.title
    }

    private var uploadGroupId: String {
        group.foods.first?.uploadGroupId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? group.id
    }

    private var logDate: String {
        group.foods.first?.date ?? ""
    }

    private var shareText: String {
        "\(title)：\(Int(round(group.calories))) 千卡，蛋白质 \(Int(round(group.protein)))克，碳水 \(Int(round(group.carbs)))克，脂肪 \(Int(round(group.fat)))克。"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppShellBackground()

            ScrollView {
                VStack(spacing: 0) {
                    hero
                    sheet
                }
                .padding(.bottom, 170)
            }
            .ignoresSafeArea(edges: .top)

            bottomBar

            if estimatingLeftovers {
                LeftoverEstimatingOverlay()
                    .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: $showLeftoverCamera) {
            CameraView { capture in
                showLeftoverCamera = false
                Task { await estimateLeftovers(imageBase64: capture.imageBase64) }
            }
        }
        .sheet(item: $leftoverEstimate) { estimate in
            LeftoverConfirmationSheet(
                estimate: estimate,
                imageBase64: leftoverImageBase64,
                date: logDate,
                onClose: {
                    leftoverEstimate = nil
                },
                onApplied: {
                    leftoverEstimate = nil
                    onChanged($0)
                    onClose()
                }
            )
        }
        .sheet(isPresented: $showFixSheet) {
            FixRecognitionSheet(
                groupTitle: title,
                foods: group.foods,
                onClose: {
                    showFixSheet = false
                },
                onSubmitted: {
                    showFixSheet = false
                    fixStatus = "已收到修正，我会用来更新这次记录。"
                }
            )
        }
        .alert("这次还没修正好", isPresented: Binding(
            get: { leftoverError != nil },
            set: { if !$0 { leftoverError = nil } }
        )) {
            Button("先看这餐", role: .cancel) {
                leftoverError = nil
            }
        } message: {
            Text(leftoverError ?? "刚才的食后修正还没保存，检查网络后再点保存。")
        }
        .alert("已收到修正", isPresented: Binding(
            get: { fixStatus != nil },
            set: { if !$0 { fixStatus = nil } }
        )) {
            Button("继续看这餐", role: .cancel) {
                fixStatus = nil
            }
        } message: {
            Text(fixStatus ?? "")
        }
        .alert("分享结果", isPresented: Binding(
            get: { communityShareStatus != nil },
            set: { if !$0 { communityShareStatus = nil } }
        )) {
            Button("继续看这餐", role: .cancel) {
                communityShareStatus = nil
            }
        } message: {
            Text(communityShareStatus ?? "")
        }
        .onAppear {
            runInitialActionIfNeeded()
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            if let url = group.imageUrl {
                LocalMealImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        heroFallback
                    }
                }
                .frame(height: 320)
                .clipped()
            } else {
                heroFallback
            }

            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.05), .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)

            VStack {
                HStack {
                    CircleButton(systemName: "chevron.left", action: onClose)
                    Spacer()
                    Text("营养信息")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 12) {
                        ShareLink(item: shareText) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(width: 54, height: 54)
                                .background(.white.opacity(0.72))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("分享记录")
                        Menu {
                            Button("回到首页", action: onClose)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(width: 54, height: 54)
                                .background(.white.opacity(0.72))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("更多操作")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 54)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已记录餐食")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.78))
                        Text("\(group.count) 项 · \(group.displayTime)")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.34))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(round(group.calories)))")
                            .font(.system(size: 26, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("千卡")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.84))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 34)
            }
            .frame(height: 320)
        }
    }

    private var heroFallback: some View {
        LinearGradient(
            colors: [Color(hex: "20252B"), Color(hex: "111317")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            LinearGradient(colors: [Color.white.opacity(0.08), .clear, Color(hex: "159BFF").opacity(0.16)], startPoint: .topTrailing, endPoint: .bottomLeading)
        )
        .frame(height: 320)
    }

    private var sheet: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color(hex: "DEDEE5"))
                .frame(width: 48, height: 6)
                .padding(.top, 10)

            headerSection
            mealInsightSection
            caloriesSection
            ingredientsSection
            moreNutritionSection
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .background(LinearGradient(colors: [.white, Color(hex: "FBFBFD")], startPoint: .top, endPoint: .bottom))
        .clipShape(TopRoundedRectangle(radius: 36))
        .shadow(color: .black.opacity(0.18), radius: 42, x: 0, y: -18)
        .offset(y: -28)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "bookmark")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(hex: "F8F8FB"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(group.displayTime.isEmpty ? Date().formatted(.dateTime.hour().minute()) : group.displayTime)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "54545A"))
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(Color(hex: "F7F7FB"))
                    .clipShape(Capsule())
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                Text(title)
                    .font(.system(size: 31, weight: .black))
                    .tracking(-0.8)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showFixSheet = true
                } label: {
                    HStack(spacing: 9) {
                        Text("识别有误")
                        Image(systemName: "pencil")
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 116, height: 48)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "E5E5EA"), lineWidth: 1))
                    .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("反馈识别有误")
            }
        }
    }

    private var mealInsightSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: mealInsightIcon)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(mealInsightColor)
                .frame(width: 40, height: 40)
                .background(mealInsightColor.opacity(0.12))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(mealInsightTitle)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(2)
                Text(mealInsightBody)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
        }
        .padding(15)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var mealInsightTitle: String {
        if group.calories >= 900 {
            return "这餐热量偏高"
        }
        if fatEnergyRatio >= 0.45 {
            return "这餐有点油"
        }
        if group.calories >= 350, group.protein < 18 {
            return "这餐蛋白偏少"
        }
        if group.fiber >= 8 {
            return "这餐蔬菜和纤维不错"
        }
        return "这餐已记上"
    }

    private var mealInsightBody: String {
        if group.calories >= 900 {
            return "后面一餐优先清淡、高蛋白、少油；记录前请核对实际吃下的份量。"
        }
        if fatEnergyRatio >= 0.45 {
            return "脂肪占比偏高，下一餐少油少炸；照片营养是估算，请核对份量。"
        }
        if group.calories >= 350, group.protein < 18 {
            return "下一餐可以补鸡蛋、鱼虾、豆腐或鸡胸肉，让饱腹感更稳。"
        }
        if group.fiber >= 8 {
            return "这餐纤维较充足，下一餐继续注意蛋白和蔬菜。"
        }
        return "食物和克重均为估算，请在保存前核对实际吃下的份量。"
    }

    private var mealInsightIcon: String {
        if group.calories >= 900 || fatEnergyRatio >= 0.45 { return "exclamationmark.circle.fill" }
        if group.calories >= 350, group.protein < 18 { return "fork.knife.circle.fill" }
        return "checkmark.seal.fill"
    }

    private var mealInsightColor: Color {
        if group.calories >= 900 || fatEnergyRatio >= 0.45 { return Color(hex: "F05A5A") }
        if group.calories >= 350, group.protein < 18 { return Color(hex: "D9902F") }
        return Color(hex: "21A366")
    }

    private var fatEnergyRatio: Double {
        let total = max(group.calories, group.protein * 4 + group.carbs * 4 + group.fat * 9, 1)
        return (group.fat * 9) / total
    }

    private var caloriesSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 27, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 54, height: 54)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("卡路里")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.secondary)
                    Text("\(Int(round(group.calories)))")
                        .font(.system(size: 42, weight: .black))
                        .tracking(-1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer()
                Text(group.count > 1 ? "一餐记录" : "单项记录")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "54545A"))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color(hex: "F7F7FB"))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12)

            MacroEnergyCard(protein: group.protein, carbs: group.carbs, fat: group.fat)

            HStack(spacing: 12) {
                MacroInfoCard(label: "蛋白质", value: group.protein, color: Color(hex: "E8B8B8"), icon: "circle.hexagongrid.fill")
                MacroInfoCard(label: "碳水", value: group.carbs, color: Color(hex: "E8D5B8"), icon: "leaf.fill")
                MacroInfoCard(label: "脂肪", value: group.fat, color: Color(hex: "BFD8F2"), icon: "drop.fill")
            }
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("配料")
                        .font(.system(size: 24, weight: .black))
                    Text("实际吃掉多少可以单独微调")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(group.foods.count) 项")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color(hex: "F4F4F6"))
                    .clipShape(Capsule())
            }

            VStack(spacing: 12) {
                ForEach(group.foods) { food in
                    FoodLogIngredientCard(food: food)
                }
            }
        }
    }

    private var moreNutritionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更多营养")
                .font(.system(size: 20, weight: .black))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                NutritionMetric(label: "纤维", value: String(format: "%.1f克", group.fiber))
                NutritionMetric(label: "糖", value: String(format: "%.0f克", group.sugar))
                NutritionMetric(label: "钠", value: "\(Int(round(group.sodium)))毫克")
                NutritionMetric(label: "饱和脂肪", value: "--")
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button(action: onClose) {
                Label("完成并返回首页", systemImage: "checkmark")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(hex: "211D27"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.05), .white.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial)
        )
    }

    private func detailActionButton(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 34, height: 34)
                    .background(Color(hex: "F2F4F7"))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(subtitle)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "E5E5EA"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func startLeftoverFlow() {
        guard !uploadGroupId.isEmpty else {
            leftoverError = "这餐还没保存完整，先返回首页刷新后再拍剩余照片。"
            return
        }
        showLeftoverCamera = true
    }

    @MainActor
    private func shareToCommunity(visibility: String) async {
        guard !sharingCommunity else { return }
        let groupId = uploadGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupId.isEmpty, !groupId.hasPrefix("single-") else {
            communityShareStatus = "这餐还没保存完整，先回首页刷新后再分享。"
            return
        }
        sharingCommunity = true
        defer { sharingCommunity = false }
        do {
            _ = try await APIClient.shared.shareMealToCommunity(
                uploadGroupId: groupId,
                visibility: visibility,
                caption: shareText
            )
            communityShareStatus = visibility == "public" ? "已发到发现菜品。" : "已发到好友圈。"
        } catch {
            communityShareStatus = mealDetailFriendlyError(error, fallback: "这餐还没发出去，检查网络后再点分享。")
        }
    }

    private func estimateLeftovers(imageBase64: String) async {
        guard !imageBase64.isEmpty else { return }
        estimatingLeftovers = true
        leftoverError = nil
        leftoverImageBase64 = imageBase64
        defer { estimatingLeftovers = false }
        do {
            leftoverEstimate = try await APIClient.shared.estimateFoodLogLeftovers(
                uploadGroupId: uploadGroupId,
                imageBase64: imageBase64,
                date: logDate,
                description: "手机食后剩余照片"
            )
        } catch {
            leftoverError = mealDetailFriendlyError(error, fallback: "这张食后照片没算出来。换个角度拍剩余食物会更稳。")
        }
    }

    private func runInitialActionIfNeeded() {
        guard !didRunInitialAction, let initialAction else { return }
        didRunInitialAction = true
        switch initialAction {
        case .leftover:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                startLeftoverFlow()
            }
        case .fix:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                showFixSheet = true
            }
        }
    }
}

private struct LeftoverEstimatingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .tint(Color(hex: "111318"))
                    .scaleEffect(1.2)
                Text("正在估算剩余")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("根据食后照片计算实际摄入")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(.white.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 16)
        }
    }
}

private struct LeftoverConfirmationSheet: View {
    let estimate: LeftoverEstimateResponse
    let imageBase64: String
    let date: String
    let onClose: () -> Void
    let onApplied: (String?) -> Void

    @State private var items: [LeftoverEstimateItem]
    @State private var applying = false
    @State private var error = ""

    private var leftoverCalories: Double {
        items.reduce(0) { total, item in
            total + (item.originalCalories ?? 0) * item.remainingPercent / 100
        }
    }

    private var consumedCalories: Double {
        max(0, estimate.originalCalories - leftoverCalories)
    }

    init(
        estimate: LeftoverEstimateResponse,
        imageBase64: String,
        date: String,
        onClose: @escaping () -> Void,
        onApplied: @escaping (String?) -> Void
    ) {
        self.estimate = estimate
        self.imageBase64 = imageBase64
        self.date = date
        self.onClose = onClose
        self.onApplied = onApplied
        _items = State(initialValue: estimate.items)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    grabber
                    header
                    summaryCard
                    itemList
                    if let notes = estimate.notes, !notes.isEmpty {
                        noteCard(notes)
                    }
                    if !error.isEmpty {
                        errorCard
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 104)
            }
            .background(AppShellBackground())
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await apply() }
                } label: {
                    HStack(spacing: 8) {
                        if applying {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                        Text("应用修正")
                    }
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .background(.ultraThinMaterial)
                }
                .disabled(applying)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color(hex: "DEDEE5"))
            .frame(width: 44, height: 5)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .accessibilityHidden(true)
                    Text("吃剩了多少")
                }
                .font(.system(size: 25, weight: .black))
                Text("按剩余比例重新计算实际摄入")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
            .accessibilityLabel("关闭食后修正")
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            metric("原记录", "\(Int(round(estimate.originalCalories)))", "千卡")
            metric("剩余", "\(Int(round(leftoverCalories)))", "千卡")
            metric("实际摄入", "\(Int(round(consumedCalories)))", "千卡")
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var itemList: some View {
        VStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                leftoverRow(index)
            }
        }
    }

    private func leftoverRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(items[index].name)
                        .font(.system(size: 16, weight: .black))
                        .lineLimit(2)
                    Text("原 \(Int(round(items[index].originalCalories ?? 0))) 千卡 · 置信 \(Int(round(items[index].confidence * 100)))%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("剩 \(Int(round(items[index].remainingPercent)))%")
                    .font(.system(size: 20, weight: .black))
            }

            Slider(value: $items[index].remainingPercent, in: 0...100, step: 1)
                .tint(Color(hex: "111318"))

            HStack {
                Button("吃完") { items[index].remainingPercent = 0 }
                Spacer()
                Button("剩一半") { items[index].remainingPercent = 50 }
                Spacer()
                Button("没吃") { items[index].remainingPercent = 100 }
            }
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(Color(hex: "111318"))

            if !items[index].reason.isEmpty {
                Text(items[index].reason)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func metric(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .black))
                Text(unit)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func noteCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var errorCard: some View {
        Text(error)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(hex: "D93025"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(hex: "FFF1F0"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func apply() async {
        guard !applying else { return }
        applying = true
        error = ""
        defer { applying = false }
        do {
            let response = try await APIClient.shared.applyFoodLogLeftovers(
                uploadGroupId: estimate.uploadGroupId,
                imageBase64: imageBase64,
                date: date,
                items: items
            )
            let consumed = Int(round(response.consumedCalories))
            let sourceLabel = imageBase64.isEmpty ? "手动调整" : "剩余照片"
            let message = consumed > 0 ? "已按\(sourceLabel)修正：摄入约 \(consumed) 千卡" : "已按\(sourceLabel)修正"
            onApplied(message)
        } catch {
            self.error = mealDetailFriendlyError(error, fallback: "吃剩修正还没存到今天。检查网络后再点保存修正。")
        }
    }
}

private struct FixRecognitionSheet: View {
    let groupTitle: String
    let foods: [FoodLogRow]
    let onClose: () -> Void
    let onSubmitted: () -> Void

    @State private var detail = ""
    @State private var submitting = false
    @State private var error = ""
    @State private var votingFoodId = ""
    @State private var voteMessage = ""

    private let tags = ["克重不准", "漏了食物", "热量偏高", "重复识别", "名字不对", "吃剩了"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    grabber
                    header
                    tagGrid
                    textBox
                    foodVoteList
                    if !voteMessage.isEmpty {
                        infoCard(voteMessage)
                    }
                    if !error.isEmpty {
                        errorCard
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 104)
            }
            .background(AppShellBackground())
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(action: onClose) {
                        Text("先不改")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "E5E5EA"), lineWidth: 1))
                    }
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if submitting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(submitting ? "正在保存" : "保存修正")
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .disabled(submitting)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color(hex: "DEDEE5"))
            .frame(width: 44, height: 5)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .accessibilityHidden(true)
                    Text("修正这餐")
                }
                .font(.system(size: 25, weight: .black))
                Text("写一句实际情况，我会按这次记录修正。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
            .accessibilityLabel("关闭修正弹窗")
        }
    }

    private var textBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("怎么不准")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            TextEditor(text: $detail)
                .font(.system(size: 15, weight: .bold))
                .frame(minHeight: 124)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("例如：米饭剩一半，鸡胸肉吃完了；紫甘蓝只有几口，不是 100 克。")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(hex: "A0A4AD"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var tagGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("先选问题")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text(detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "可多选" : "已选择")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "8B919B"))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    let selected = detail.contains(tag)
                    Button {
                        appendTag(tag)
                    } label: {
                        Text(tag)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(selected ? .white : Color(hex: "555A62"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(selected ? Color(hex: "111318") : Color(hex: "F1F2F5"))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("只选标签也能保存；补一句会更准。")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "8B919B"))
                .lineLimit(2)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var foodVoteList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("哪项有问题")
                .font(.system(size: 17, weight: .black))
            ForEach(foods) { food in
                foodVoteRow(food)
            }
        }
    }

    private func foodVoteRow(_ food: FoodLogRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(food.displayName)
                    .font(.system(size: 14, weight: .black))
                    .lineLimit(1)
                Text("\(Int(round(food.calories ?? 0))) 千卡 · \(food.displayServingSize)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            voteButton(food, vote: "accurate", label: "准确")
            voteButton(food, vote: "inaccurate", label: "不准")
            voteButton(food, vote: "helpful", label: "有用")
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func voteButton(_ food: FoodLogRow, vote: String, label: String) -> some View {
        let foodId = food.id.map(String.init) ?? ""
        return Button {
            Task { await castVote(food: food, vote: vote) }
        } label: {
            if votingFoodId == "\(foodId)-\(vote)" {
                ProgressView()
                    .scaleEffect(0.75)
                    .frame(width: 38, height: 30)
            } else {
                Text(label)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "555A62"))
                    .frame(width: 38, height: 30)
            }
        }
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
        .disabled(foodId.isEmpty || !votingFoodId.isEmpty)
    }

    private func infoCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color(hex: "111318"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var errorCard: some View {
        Text(error)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(hex: "D93025"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(hex: "FFF1F0"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func appendTag(_ tag: String) {
        guard !detail.contains(tag) else { return }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = trimmed.isEmpty ? tag : "\(trimmed)，\(tag)"
    }

    private func castVote(food: FoodLogRow, vote: String) async {
        guard let id = food.id else { return }
        votingFoodId = "\(id)-\(vote)"
        voteMessage = ""
        defer { votingFoodId = "" }
        do {
            try await APIClient.shared.voteFood(foodId: String(id), foodName: food.displayName, vote: vote)
            voteMessage = "已记下“\(food.displayName)”的反馈"
        } catch {
            self.error = mealDetailFriendlyError(error, fallback: "这项还没记上，检查网络后再点一次。")
        }
    }

    private func submit() async {
        guard !submitting else { return }
        let validFoods = foods.filter { $0.id != nil }
        guard !validFoods.isEmpty else {
            error = "这餐还没保存完整，先返回首页刷新后再修正。"
            return
        }
        submitting = true
        error = ""
        defer { submitting = false }

        let names = foods.map(\.displayName).filter { !$0.isEmpty }.joined(separator: "、")
        let userNote = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = userNote.isEmpty ? "用户反馈这条营养识别需要修复" : userNote
        let detailText = "用户从手机营养详情页反馈这餐需要修复：\(groupTitle.isEmpty ? names : groupTitle)。补充：\(note)"

        do {
            for food in validFoods {
                let foodId = String(food.id ?? 0)
                try await APIClient.shared.reportFood(
                    foodId: foodId,
                    foodName: food.displayName,
                    reason: "wrong_nutrition",
                    detail: detailText
                )
                try await APIClient.shared.fixFood(
                    foodId: foodId,
                    originalName: food.displayName,
                    note: detailText
                )
            }
            onSubmitted()
        } catch {
            self.error = mealDetailFriendlyError(error, fallback: "修正还没存到今天，检查网络后再点保存修正。")
        }
    }
}

private func mealDetailFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lower = raw.lowercased()
    if lower.contains("could not connect")
        || lower.contains("connection")
        || lower.contains("timed out")
        || lower.contains("network")
        || raw.contains("连接不到")
        || raw.contains("无法连接") {
        return "现在没连上，修改还没存到今天；检查网络后再点保存。"
    }
    if lower.contains("not found") || lower.contains("404") {
        return "这餐还没保存完整，返回首页刷新后再看。"
    }
    if lower.contains("cancelled") || raw.contains("取消") {
        return "刚才的操作已取消，没有改动这次记录。"
    }
    if raw.contains("失败")
        || raw.contains("错误")
        || raw.contains("异常")
        || raw.contains("无法")
        || lower.contains("failed")
        || lower.contains("error")
        || lower.contains("exception")
        || lower.contains("server")
        || lower.contains("api")
        || raw.hasPrefix("{")
        || raw.hasPrefix("[")
        || raw.count > 120 {
        return fallback
    }
    return raw
}

private struct FoodLogIngredientCard: View {
    let food: FoodLogRow

    private var consumedPercent: Int { food.consumedPercent }
    private var remainingPercent: Int { max(0, 100 - consumedPercent) }
    private var originalCalories: Int { Int(round(food.originalCalorieValue)) }
    private var consumedCalories: Int { Int(round(food.calories ?? 0)) }

    var body: some View {
        VStack(spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(food.displayName)
                        .font(.system(size: 17, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    HStack(spacing: 6) {
                        Text("\(consumedCalories) / \(originalCalories) 千卡")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                        if !food.displayQuantity.isEmpty {
                            badge(food.displayQuantity)
                        }
                        badge(food.displayServingSize)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(consumedPercent)%")
                        .font(.system(size: 24, weight: .black))
                    Text("已吃")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 7) {
                HStack {
                    Text("食用比例")
                    Spacer()
                    Text("剩余 \(remainingPercent)%")
                }
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: "E6E8EF")).frame(height: 6)
                        Capsule()
                            .fill(Color(hex: "111318"))
                            .frame(width: proxy.size.width * CGFloat(consumedPercent) / 100, height: 6)
                        Circle()
                            .fill(Color(hex: "111318"))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                            .offset(x: max(0, proxy.size.width * CGFloat(consumedPercent) / 100 - 8))
                    }
                }
                .frame(height: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(hex: "F6F7FA"))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .padding(12)
        .background(LinearGradient(colors: [.white, Color(hex: "FBFBFD")], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "ECECF2"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 8)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(hex: "F2F2F5"))
            .clipShape(Capsule())
    }
}
