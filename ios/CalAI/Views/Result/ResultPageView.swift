import SwiftUI
import UIKit

struct ResultPageView: View {
    let result: DescribeMealResponse
    let imageBase64: String?
    let logDate: String
    let onSaved: (String?) -> Void
    let onClose: () -> Void
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var savedGroup: MealHistoryGroup?
    @State private var communityShareStatus: String?
    @State private var sharingCommunity = false
    @State private var editableFoods: [FoodItem] = []
    @State private var depthPatchStatus: String?
    @State private var savedUploadGroupIdForReplace = ""
    @State private var editingPhotoLabelFood: FoodItem?
    @State private var reviewScrollToken = 0
    @State private var depthPatchTasks: [String: Task<Void, Never>] = [:]
    @State private var previewTask: Task<Void, Never>?
    @State private var dailySummary: DailySummary?
    @State private var previewDecision: DecisionScoreResponse?
    @State private var previewLoading = false

    private var foods: [FoodItem] { editableFoods.isEmpty ? result.foods : editableFoods }
    private var totalCalories: Double { foods.reduce(0) { $0 + $1.calories } }
    private var totalProtein: Double { foods.reduce(0) { $0 + $1.protein } }
    private var totalCarbs: Double { foods.reduce(0) { $0 + $1.carbs } }
    private var totalFat: Double { foods.reduce(0) { $0 + $1.fat } }
    private var totalFiber: Double { foods.reduce(0) { $0 + $1.fiber } }
    private var totalSugar: Double { foods.reduce(0) { $0 + $1.sugar } }
    private var totalSodium: Double { foods.reduce(0) { $0 + $1.sodium } }
    private var totalAddedSugar: Double { foods.reduce(0) { $0 + $1.addedSugar } }
    private var totalSatFat: Double { foods.reduce(0) { $0 + $1.satFat } }
    private var totalCholesterol: Double { foods.reduce(0) { $0 + $1.cholesterol } }
    private var totalCalcium: Double { foods.reduce(0) { $0 + $1.calcium } }
    private var totalIron: Double { foods.reduce(0) { $0 + $1.iron } }
    private var totalPotassium: Double { foods.reduce(0) { $0 + $1.potassium } }
    private var totalMagnesium: Double { foods.reduce(0) { $0 + $1.magnesium } }
    private var totalZinc: Double { foods.reduce(0) { $0 + $1.zinc } }
    private var totalFolate: Double { foods.reduce(0) { $0 + $1.folate } }
    private var totalVitaminD: Double { foods.reduce(0) { $0 + $1.vitaminD } }
    private var totalVitaminB12: Double { foods.reduce(0) { $0 + $1.vitaminB12 } }
    private var totalVitaminE: Double { foods.reduce(0) { $0 + $1.vitaminE } }
    private var totalVitaminK: Double { foods.reduce(0) { $0 + $1.vitaminK } }
    private var totalOmega3: Double { foods.reduce(0) { $0 + $1.omega3 } }
    private var totalMonounsaturatedFat: Double { foods.reduce(0) { $0 + $1.monounsaturatedFat } }
    private var totalPolyunsaturatedFat: Double { foods.reduce(0) { $0 + $1.polyunsaturatedFat } }

    private var title: String {
        let names = foods.prefix(3).map(\.name)
        if names.isEmpty { return "餐食分析" }
        return names.joined(separator: "、") + (foods.count > 3 ? "等 \(foods.count) 项" : "")
    }

    private var shareText: String {
        "\(title)：\(Int(round(totalCalories))) 千卡，蛋白质 \(Int(round(totalProtein)))克，碳水 \(Int(round(totalCarbs)))克，脂肪 \(Int(round(totalFat)))克。"
    }

    private var heroUIImage: UIImage? {
        guard let imageBase64 else { return nil }
        let payload = imageBase64.split(separator: ",").last.map(String.init) ?? imageBase64
        guard let data = Data(base64Encoded: payload) else { return nil }
        return UIImage(data: data)
    }

    private var heroImageSize: CGSize {
        if let width = foods.compactMap(\.depthImageWidth).first,
           let height = foods.compactMap(\.depthImageHeight).first,
           width > 0,
           height > 0 {
            return CGSize(width: width, height: height)
        }
        return heroUIImage?.size ?? CGSize(width: 1, height: 1)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppShellBackground()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        sheet
                    }
                    .padding(.bottom, 104)
                }
                .ignoresSafeArea(edges: .top)
                .onChange(of: reviewScrollToken) { _, _ in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo("food-details", anchor: .top)
                    }
                }
            }

            bottomBar

            if isSaving {
                SavingOverlay()
                    .transition(.opacity)
            }
        }
        .task {
            if editableFoods.isEmpty {
                editableFoods = result.foods
            }
            await loadSavePreview()
        }
        .sheet(item: $editingPhotoLabelFood) { food in
            FoodLabelEditSheet(food: food) { newName, newGrams in
                applyLabelEdit(foodId: food.id, name: newName, grams: newGrams)
            }
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
        .alert("这餐还没保存上", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("再保存一次") {
                saveError = nil
                Task { _ = await saveIfNeeded() }
            }
            Button("先看这餐", role: .cancel) {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "这餐还没存到今天。先看结果也可以，网络好了再保存一次。")
        }
        .alert("分享这餐", isPresented: Binding(
            get: { communityShareStatus != nil },
            set: { if !$0 { communityShareStatus = nil } }
        )) {
            Button("继续看这餐", role: .cancel) {
                communityShareStatus = nil
            }
        } message: {
            Text(communityShareStatus ?? "")
        }
        .alert("调整这餐", isPresented: Binding(
            get: { depthPatchStatus != nil },
            set: { if !$0 { depthPatchStatus = nil } }
        )) {
            Button("继续看这餐", role: .cancel) {
                depthPatchStatus = nil
            }
        } message: {
            Text(depthPatchStatus ?? "")
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            heroPhotoBackground
            .frame(height: 320)
            .clipped()

            FoodPhotoCalloutOverlay(
                foods: foods,
                imageSize: heroImageSize,
                onSelect: { food in
                    editingPhotoLabelFood = food
                }
            )
            .padding(.top, 92)
            .padding(.horizontal, 18)
            .frame(height: 256)

            VStack(spacing: 0) {
                HStack {
                    CircleButton(systemName: "chevron.left", action: onClose)
                    Spacer()
                    Text("这餐结果")
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
                            Button("发到好友圈") {
                                Task { await shareSavedMeal(visibility: "friends") }
                            }
                            Button("再保存一次") {
                                savedGroup = nil
                                Task { _ = await saveIfNeeded() }
                            }
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
                        Text(savedGroup == nil ? (isSaving ? "正在保存" : "可改后保存") : "已保存到今天")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.78))
                        Text("\(foods.count) 项")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.34))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(round(totalCalories)))")
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

    @ViewBuilder
    private var heroPhotoBackground: some View {
        if let uiImage = heroUIImage {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .overlay(
                    LinearGradient(
                        colors: [
                            .black.opacity(0.30),
                            .black.opacity(0.04),
                            .black.opacity(0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        } else {
            LinearGradient(
                colors: [Color(hex: "20252B"), Color(hex: "111317")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.clear, Color(hex: "159BFF").opacity(0.16)],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            )
        }
    }

    private var sheet: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color(hex: "DEDEE5"))
                .frame(width: 48, height: 6)
                .padding(.top, 10)

            headerSection
            caloriesSection
            savePreviewSection
            if let decision = result.decision {
                decisionSection(decision)
            }
            reviewPromptSection
            ingredientsSection
            if shouldShowRecognitionEvidence {
                recognitionEvidenceSection
            }
            moreNutritionSection
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [.white, Color(hex: "FBFBFD")], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(TopRoundedRectangle(radius: 36))
        .shadow(color: .black.opacity(0.18), radius: 42, x: 0, y: -18)
        .offset(y: -28)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(savedGroup == nil ? "估算结果，确认后再保存" : "已保存，后面还能改")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "6D7480"))
                    Text(title)
                        .font(.system(size: 28, weight: .black))
                        .tracking(-0.6)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 7) {
                    Image(systemName: savedGroup == nil ? "pencil" : "checkmark")
                        .font(.system(size: 14, weight: .black))
                        .accessibilityHidden(true)
                    Text(savedGroup == nil ? "可修改" : "已保存")
                        .font(.system(size: 13, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 96, height: 42)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "E5E5EA"), lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
            }
        }
    }

    private var caloriesSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 32, weight: .bold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("这顿约")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(Int(round(totalCalories)))")
                            .font(.system(size: 42, weight: .black))
                            .tracking(-1)
                        Text("千卡")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(foods.count) 项食物")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "54545A"))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color(hex: "F7F7FB"))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12)

            MacroEnergyCard(protein: totalProtein, carbs: totalCarbs, fat: totalFat)

            HStack(spacing: 12) {
                MacroInfoCard(label: "蛋白质", value: totalProtein, color: Color(hex: "E8B8B8"), icon: "circle.hexagongrid.fill")
                MacroInfoCard(label: "碳水", value: totalCarbs, color: Color(hex: "E8D5B8"), icon: "leaf.fill")
                MacroInfoCard(label: "脂肪", value: totalFat, color: Color(hex: "BFD8F2"), icon: "drop.fill")
            }
        }
    }

    private var reviewPromptSection: some View {
        let fallbackCount = foods.filter { $0.depthFallback == true }.count
        let confidenceValues = foods.compactMap(\.depthVolumeConfidence).filter { $0 > 0 }
        let averageConfidence = confidenceValues.isEmpty ? nil : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        let promptTitle: String = {
            if fallbackCount > 0 {
                return "\(fallbackCount) 项份量建议看一眼"
            }
            if let averageConfidence {
                return averageConfidence >= 0.68 ? "可以先保存" : "克重建议看一眼"
            }
            return "食物和克重都能改"
        }()
        let confidenceText: String = {
            if fallbackCount > 0 {
                return "改完会重新计算"
            }
            if let averageConfidence {
                return averageConfidence >= 0.68 ? "保存后也能继续改" : "不确定的先修一下"
            }
            return "不准就点下面修正"
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checklist.checked")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "111318"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(promptTitle)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(confidenceText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "6D7480"))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            reviewActionButton(
                title: "检查并修改食物",
                icon: "pencil",
                filled: true
            ) {
                reviewScrollToken += 1
            }
        }
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "ECEEF2"), lineWidth: 1))
    }

    private func reviewActionButton(title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .foregroundStyle(filled ? .white : Color(hex: "111318"))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(filled ? Color(hex: "111318") : .white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(filled ? Color.clear : Color(hex: "E5E5EA"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var savePreviewSection: some View {
        let caloriesRemaining = (dailySummary?.caloriesGoal ?? 2000) - (dailySummary?.caloriesConsumed ?? 0) - totalCalories
        let proteinRemaining = (dailySummary?.proteinGoal ?? 50) - (dailySummary?.protein ?? 0) - totalProtein
        let carbsRemaining = (dailySummary?.carbsGoal ?? 250) - (dailySummary?.carbs ?? 0) - totalCarbs
        let fatRemaining = (dailySummary?.fatGoal ?? 65) - (dailySummary?.fat ?? 0) - totalFat
        let advice = previewDecision?.warnings.first
            ?? previewDecision?.suggestions.first
            ?? "保存前可以继续调整名称、份量和吃了多少。"

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("保存前预演")
                        .font(.system(size: 18, weight: .black))
                    Text("记录后今日还剩")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if previewLoading {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .accessibilityHidden(true)
                }
            }

            HStack(spacing: 8) {
                previewMetric("热量", caloriesRemaining, "千卡")
                previewMetric("蛋白", proteinRemaining, "克")
                previewMetric("碳水", carbsRemaining, "克")
                previewMetric("脂肪", fatRemaining, "克")
            }

            Text(advice)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "545B66"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "ECEEF2"), lineWidth: 1))
    }

    private func previewMetric(_ label: String, _ remaining: Double, _ unit: String) -> some View {
        let rounded = Int(round(abs(remaining)))
        return VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.secondary)
            Text(remaining >= 0 ? "\(rounded)" : "超\(rounded)")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(remaining >= 0 ? Color(hex: "111318") : Color(hex: "D95C5C"))
                .lineLimit(1)
                .minimumScaleFactor(0.66)
            Text(unit)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 66)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func decisionSection(_ decision: DecisionScoreResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.12))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(decisionScoreTypeText(decision.scoreType))
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.46))
                    Text(decision.headline.isEmpty ? (decision.label.isEmpty ? "这餐下一步" : decision.label) : decision.headline)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                Spacer()
                VStack(spacing: 0) {
                    Text("\(Int(round(decision.score)))")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(decisionScoreColor(decision.score))
                    Text("/100")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }

            if !decision.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(decision.reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                        Text(reason)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let warning = decision.warnings.first, !warning.isEmpty {
                Text(warning)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let suggestion = decision.suggestions.first, !suggestion.isEmpty {
                Text(suggestion)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Color(hex: "171A20"), Color(hex: "2A3038")], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 14)
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("食物明细")
                        .font(.system(size: 24, weight: .black))
                    Text("点食物改名称、克重和吃了多少。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(foods.count) 项")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color(hex: "F4F4F6"))
                    .clipShape(Capsule())
            }

            VStack(spacing: 12) {
                ForEach(Array(foods.enumerated()), id: \.element.id) { index, food in
                    IngredientResultCard(
                        food: food,
                        baseFood: baseFood(for: food),
                        onRenamed: { name in
                            applyLabelEdit(foodId: food.id, name: name, grams: nil)
                        },
                        onAdjusted: { grams, eatenRatio, quantityCount, quantityUnit in
                            adjustFood(
                                at: index,
                                grams: grams,
                                eatenRatio: eatenRatio,
                                quantityCount: quantityCount,
                                quantityUnit: quantityUnit
                            )
                        }
                    )
                }
            }
        }
        .id("food-details")
    }

    private var moreNutritionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更多营养")
                .font(.system(size: 20, weight: .black))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                NutritionMetric(label: "纤维", value: String(format: "%.1f克", totalFiber))
                NutritionMetric(label: "糖", value: String(format: "%.0f克", totalSugar))
                NutritionMetric(label: "添加糖", value: String(format: "%.1f克", totalAddedSugar))
                NutritionMetric(label: "饱和脂肪", value: String(format: "%.1f克", totalSatFat))
                NutritionMetric(label: "钠", value: "\(Int(round(totalSodium)))毫克")
                NutritionMetric(label: "胆固醇", value: "\(Int(round(totalCholesterol)))毫克")
                NutritionMetric(label: "钙", value: "\(Int(round(totalCalcium)))毫克")
                NutritionMetric(label: "铁", value: String(format: "%.1f毫克", totalIron))
                NutritionMetric(label: "钾", value: "\(Int(round(totalPotassium)))毫克")
                NutritionMetric(label: "镁", value: "\(Int(round(totalMagnesium)))毫克")
                NutritionMetric(label: "锌", value: String(format: "%.1f毫克", totalZinc))
                NutritionMetric(label: "叶酸", value: "\(Int(round(totalFolate)))微克")
                NutritionMetric(label: "维生素D", value: String(format: "%.1f微克", totalVitaminD))
                NutritionMetric(label: "维生素B12", value: String(format: "%.1f微克", totalVitaminB12))
                NutritionMetric(label: "维生素E", value: String(format: "%.1f毫克", totalVitaminE))
                NutritionMetric(label: "维生素K", value: "\(Int(round(totalVitaminK)))微克")
                NutritionMetric(label: "Omega-3", value: String(format: "%.1f克", totalOmega3))
                NutritionMetric(label: "单不饱和脂肪", value: String(format: "%.1f克", totalMonounsaturatedFat))
                NutritionMetric(label: "多不饱和脂肪", value: String(format: "%.1f克", totalPolyunsaturatedFat))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(bottomHelperText)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "6D7480"))
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            HStack(spacing: 12) {
                Button {
                    reviewScrollToken += 1
                } label: {
                    Label("修改食物", systemImage: "pencil")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .frame(width: 124, height: 56)
                        .background(.white.opacity(0.88))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "E5E5EA"), lineWidth: 1))
                }
                Button {
                    Task { await finish() }
                } label: {
                    Label(bottomPrimaryTitle, systemImage: isSaving ? "hourglass" : "checkmark")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Color(hex: "211D27"))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .background(.ultraThinMaterial)
    }

    private var bottomPrimaryTitle: String {
        if isSaving { return "正在保存" }
        if savedGroup == nil { return "保存这餐" }
        return "回到首页"
    }

    private var bottomHelperText: String {
        if isSaving { return "正在保存到今天。" }
        if savedGroup == nil { return "先检查食物名和克重，确认后再保存。" }
        return "已保存，可继续修正。"
    }

    private func decisionScoreColor(_ score: Double) -> Color {
        if score >= 80 { return Color(hex: "111318") }
        if score >= 65 { return Color(hex: "6D7480") }
        return Color(hex: "D95C5C")
    }

    private func decisionScoreTypeText(_ type: String) -> String {
        switch type {
        case "packaged_health_score": return "包装食品健康分"
        case "meal_nutrition_score": return "本餐营养分"
        case "today_fit_score": return "今日适配分"
        default: return "这餐建议"
        }
    }

    private var recognitionEvidenceSection: some View {
        let depthItems = foods.filter { $0.depthMealId != nil || $0.depthBbox != nil || $0.depthVolumeMl != nil }
        let fallbackItems = foods.filter { $0.depthFallback == true }
        let confidenceValues = foods.compactMap(\.depthVolumeConfidence).filter { $0 > 0 }
        let averageConfidence = confidenceValues.isEmpty ? 0 : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        let maskCount = foods.filter { ($0.depthMaskPreviewBase64 ?? "").isEmpty == false || ($0.depthMaskUrl ?? "").isEmpty == false }.count
        let needsCheckCount = fallbackItems.count
        let evidenceTitle = needsCheckCount > 0 ? "有 \(needsCheckCount) 项建议确认" : "这餐可以先保存"
        let evidenceMessage = depthItems.isEmpty
            ? "拍照成功后，这里会告诉你哪些地方可能不准。"
            : "照片标签、食物名称和克重都能改；改完会重新计算热量。"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(needsCheckCount > 0 ? Color(hex: "FFF3ED") : Color(hex: "F2F4F7"))
                    Image(systemName: needsCheckCount > 0 ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(needsCheckCount > 0 ? Color(hex: "F47B55") : Color(hex: "111318"))
                        .accessibilityHidden(true)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(evidenceTitle)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(evidenceMessage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(2)
                }
                Spacer()
                Text(depthItems.isEmpty ? "待确认" : "可修改")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(depthItems.isEmpty ? Color(hex: "8E949E") : Color(hex: "111318"))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color(hex: "F4F4F6"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                evidenceMetric("食物", "\(foods.count)项", "fork.knife", Color(hex: "111318"))
                evidenceMetric("标签", "\(maskCount)个", "tag.fill", Color(hex: "159BFF"))
                evidenceMetric("把握", confidenceValues.isEmpty ? "--" : "\(Int(round(averageConfidence * 100)))%", "gauge.with.dots.needle.bottom.50percent", Color(hex: "6D7480"))
                evidenceMetric("确认", "\(fallbackItems.count)项", "pencil", fallbackItems.isEmpty ? Color(hex: "72D3A2") : Color(hex: "F47B55"))
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 10)
    }

    private var shouldShowRecognitionEvidence: Bool {
        foods.contains { food in
            if food.depthMealId != nil { return true }
            if food.depthVolumeMl != nil { return true }
            if food.depthVolumeConfidence != nil { return true }
            if food.depthFallback == true { return true }
            if let bbox = food.depthBbox, bbox.count >= 4 { return true }
            if (food.depthMaskUrl ?? "").isEmpty == false { return true }
            if (food.depthMaskPreviewBase64 ?? "").isEmpty == false { return true }
            return false
        }
    }

    private func evidenceMetric(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color(hex: "8E949E"))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func saveIfNeeded() async -> MealHistoryGroup? {
        if let savedGroup { return savedGroup }
        guard !isSaving else { return nil }
        guard !foods.isEmpty else {
            saveError = "这张没有识别出可保存食物。重新拍完整餐盘，或回到加号手动补记。"
            return nil
        }
        let consumedFoods = foods.filter { $0.consumedRatio > 0.001 }
        guard !consumedFoods.isEmpty else {
            saveError = "所有食物都选了“没吃”，这餐不会计入记录。"
            return nil
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let replaceGroupId = savedUploadGroupIdForReplace.trimmingCharacters(in: .whitespacesAndNewlines)
            if !replaceGroupId.isEmpty, !replaceGroupId.hasPrefix("single-") {
                _ = try await APIClient.shared.deleteFoodLogs(uploadGroupId: replaceGroupId)
                try? await HealthKitSyncService.shared.deleteMeal(groupId: replaceGroupId)
            }
            let foodsToSave = consumedFoods.map { food -> FoodItem in
                var item = food
                if !logDate.isEmpty {
                    item.date = logDate
                }
                return item
            }
            let response = try await APIClient.shared.logFoods(
                foodsToSave,
                mealCategory: "",
                groupTitle: title,
                imageBase64: imageBase64 ?? "",
                date: logDate
            )
            try await confirmDepthDraftIfNeeded()
            onSaved(response.decision?.nextAdjustment)
            let groupId = response.foods?.compactMap { $0.uploadGroupId }.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !groupId.isEmpty {
                _ = await HealthKitSyncService.shared.writeMeal(foods: foodsToSave, groupId: groupId, date: logDate)
            }
            let rows = try await APIClient.shared.getFoods(date: logDate, days: 1)
            let groups = MealHistoryGroup.makeGroups(from: rows)
            let group = groups.first { group in
                !groupId.isEmpty && group.id == groupId
            } ?? groups.first { group in
                group.title == title
            } ?? groups.first
            savedGroup = group
            savedUploadGroupIdForReplace = ""
            return group
        } catch {
            saveError = resultFriendlyError(error, fallback: "这餐还没存到今天。检查网络后再点保存记录。")
            return nil
        }
    }

    @MainActor
    private func loadSavePreview() async {
        guard !foods.isEmpty else { return }
        previewLoading = true
        defer { previewLoading = false }
        do {
            async let summary = APIClient.shared.getDailySummary(date: logDate)
            async let decision = APIClient.shared.scoreMealDecision(foods: foods, date: logDate, persist: false)
            dailySummary = try await summary
            previewDecision = try await decision
        } catch {
            if dailySummary == nil {
                dailySummary = try? await APIClient.shared.getDailySummary(date: logDate)
            }
        }
    }

    private func scheduleSavePreview() {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await loadSavePreview()
        }
    }

    private func confirmDepthDraftIfNeeded() async throws {
        let mealIds = Set(foods.compactMap { food in
            food.depthMealId?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        for mealId in mealIds {
            try await APIClient.shared.confirmDepthMeal(mealId: mealId)
        }
    }

    private func baseFood(for food: FoodItem) -> FoodItem {
        result.foods.first { $0.id == food.id } ?? food
    }

    private func adjustFood(
        at index: Int,
        grams: Double,
        eatenRatio: Double,
        quantityCount: Double,
        quantityUnit: String
    ) {
        if editableFoods.isEmpty {
            editableFoods = result.foods
        }
        guard editableFoods.indices.contains(index) else { return }
        let base = baseFood(for: editableFoods[index])
        let baseGrams = max(1, base.estimatedGramsFromServingSize)
        let factor = max(0, grams / baseGrams * eatenRatio)
        editableFoods[index].scaleNutrition(from: base, factor: factor)
        editableFoods[index].servingSize = "\(Int(round(grams)))克"
        editableFoods[index].quantityCount = quantityCount
        editableFoods[index].quantityUnit = quantityUnit
        editableFoods[index].consumedRatio = eatenRatio
        editableFoods[index].gramsPerUnit = quantityUnit == "克" ? 1 : max(0.1, grams / max(0.01, quantityCount))
        editableFoods[index].quantityDescription = quantityUnit == "克"
            ? "\(Int(round(quantityCount)))克"
            : String(format: "%.1f%@（共%.0f克）", quantityCount, quantityUnit, grams)
        scheduleSavePreview()

        if let group = savedGroup {
            let groupId = group.foods.first?.uploadGroupId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? group.id
            if !groupId.isEmpty {
                savedUploadGroupIdForReplace = groupId
            }
            savedGroup = nil
        }

        let mealId = (editableFoods[index].depthMealId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = (editableFoods[index].depthItemId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mealId.isEmpty, !itemId.isEmpty else { return }
        let patchKey = editableFoods[index].id
        depthPatchTasks[patchKey]?.cancel()
        depthPatchTasks[patchKey] = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            do {
                _ = try await APIClient.shared.patchDepthMealItem(
                    mealId: mealId,
                    itemId: itemId,
                    estimatedGrams: grams,
                    eatenRatio: eatenRatio
                )
            } catch {
                await MainActor.run {
                    depthPatchStatus = resultFriendlyError(error, fallback: "页面已改好，还没存到今天；检查网络后点保存记录。")
                }
            }
        }
    }

    private func applyLabelEdit(foodId: String, name: String, grams: Double?) {
        if editableFoods.isEmpty {
            editableFoods = result.foods
        }
        guard let index = editableFoods.firstIndex(where: { $0.id == foodId }) else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            editableFoods[index].name = trimmedName
            scheduleSavePreview()
        }

        let finalGrams = grams.map { max(1, $0) }
        if let finalGrams {
            let base = baseFood(for: editableFoods[index])
            let currentRatio = editableFoods[index].caloriesRatio(comparedWith: base)
            let baseGrams = max(1, base.estimatedGramsFromServingSize)
            let factor = max(0, finalGrams / baseGrams * currentRatio)
            editableFoods[index].scaleNutrition(from: base, factor: factor)
            editableFoods[index].servingSize = "\(Int(round(finalGrams)))克"
            scheduleSavePreview()
        }

        if let group = savedGroup {
            let groupId = group.foods.first?.uploadGroupId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? group.id
            if !groupId.isEmpty {
                savedUploadGroupIdForReplace = groupId
            }
            savedGroup = nil
        }

        let mealId = (editableFoods[index].depthMealId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = (editableFoods[index].depthItemId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mealId.isEmpty, !itemId.isEmpty else { return }
        depthPatchTasks[foodId]?.cancel()
        depthPatchTasks[foodId] = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            do {
                _ = try await APIClient.shared.patchDepthMealItem(
                    mealId: mealId,
                    itemId: itemId,
                    nameZh: trimmedName.isEmpty ? nil : trimmedName,
                    estimatedGrams: finalGrams
                )
            } catch {
                await MainActor.run {
                    depthPatchStatus = resultFriendlyError(error, fallback: "图上标签已改好，还没存到今天；检查网络后点保存记录。")
                }
            }
        }
    }

    @MainActor
    private func shareSavedMeal(visibility: String) async {
        guard !sharingCommunity else { return }
        sharingCommunity = true
        defer { sharingCommunity = false }
        guard let group = await saveIfNeeded() else {
            communityShareStatus = saveError ?? "这餐还没存到今天，先保存后再分享。"
            return
        }
        let groupId = group.foods.first?.uploadGroupId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? group.id
        guard !groupId.isEmpty, !groupId.hasPrefix("single-") else {
            communityShareStatus = "这餐还没保存完整，先回首页刷新后再分享。"
            return
        }
        do {
            _ = try await APIClient.shared.shareMealToCommunity(
                uploadGroupId: groupId,
                visibility: visibility,
                caption: shareText
            )
            communityShareStatus = visibility == "public" ? "已发到发现。" : "已发到好友圈。"
        } catch {
            communityShareStatus = resultFriendlyError(error, fallback: "这餐还没发出去，检查网络后再点分享。")
        }
    }

    private func finish() async {
        _ = await saveIfNeeded()
        if saveError == nil {
            onClose()
        }
    }

    private func resultFriendlyError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return fallback }
        let lower = raw.lowercased()
        if lower.contains("could not connect")
            || lower.contains("connection")
            || lower.contains("timed out")
            || lower.contains("network")
            || raw.contains("连接不到")
            || raw.contains("无法连接") {
            return "现在没连上，这餐还没存到今天。检查网络后再点保存记录。"
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
}

private struct FoodPhotoCalloutOverlay: View {
    let foods: [FoodItem]
    let imageSize: CGSize
    let onSelect: (FoodItem) -> Void

    private var visibleFoods: [FoodItem] {
        Array(foods.filter { food in
            if let volume = food.depthVolumeMl, volume > 0 { return true }
            if let bbox = food.depthBbox, bbox.count >= 4 { return true }
            return food.calories > 0
        }.prefix(12))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let placements = calloutPlacements(in: size)
            ZStack {
                Canvas { context, _ in
                    for placement in placements {
                        let index = placement.index
                        let color = markerColor(index)
                        var connector = Path()
                        connector.move(to: placement.connectorStart)
                        connector.addLine(to: placement.anchor)
                        context.stroke(
                            connector,
                            with: .color(.white.opacity(0.92)),
                            style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
                        )
                        context.stroke(
                            connector,
                            with: .color(.black.opacity(0.18)),
                            style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
                        )
                        context.fill(
                            Path(ellipseIn: CGRect(x: placement.anchor.x - 6, y: placement.anchor.y - 6, width: 12, height: 12)),
                            with: .color(.white)
                        )
                        context.fill(
                            Path(ellipseIn: CGRect(x: placement.anchor.x - 4, y: placement.anchor.y - 4, width: 8, height: 8)),
                            with: .color(color)
                        )
                    }
                }

                ForEach(placements) { placement in
                    Button {
                        onSelect(placement.food)
                    } label: {
                        FoodDetectionLabel(
                            index: placement.index + 1,
                            food: placement.food,
                            color: markerColor(placement.index)
                        )
                    }
                    .buttonStyle(.plain)
                    .position(placement.label)
                    .accessibilityLabel("修改\(placement.food.name)标签")
                }
            }
        }
    }

    private struct CalloutPlacement: Identifiable {
        let index: Int
        let food: FoodItem
        let anchor: CGPoint
        let label: CGPoint
        let connectorStart: CGPoint

        var id: String { food.id }
    }

    private func calloutPlacements(in size: CGSize) -> [CalloutPlacement] {
        let entries = visibleFoods.enumerated().map { index, food in
            (index: index, food: food, anchor: anchorPoint(for: food, index: index, in: size))
        }
        guard !entries.isEmpty else { return [] }

        // Split by horizontal order so both columns stay balanced, even when
        // several overlapping detections have nearly identical centers.
        let horizontal = entries.sorted {
            $0.anchor.x == $1.anchor.x ? $0.anchor.y < $1.anchor.y : $0.anchor.x < $1.anchor.x
        }
        let leftCount = (horizontal.count + 1) / 2
        let leftIndexes = Set(horizontal.prefix(leftCount).map(\.index))
        let left = entries.filter { leftIndexes.contains($0.index) }.sorted { $0.anchor.y < $1.anchor.y }
        let right = entries.filter { !leftIndexes.contains($0.index) }.sorted { $0.anchor.y < $1.anchor.y }

        let labelHalfWidth: CGFloat = 64
        let connectorInset: CGFloat = 5
        let leftX = labelHalfWidth
        let rightX = size.width - labelHalfWidth
        let leftYs = lanePositions(count: left.count, in: size)
        let rightYs = lanePositions(count: right.count, in: size)

        let leftPlacements = zip(left, leftYs).map { entry, y in
            let label = CGPoint(x: leftX, y: y)
            return CalloutPlacement(
                index: entry.index,
                food: entry.food,
                anchor: entry.anchor,
                label: label,
                connectorStart: CGPoint(x: leftX + labelHalfWidth - connectorInset, y: y)
            )
        }
        let rightPlacements = zip(right, rightYs).map { entry, y in
            let label = CGPoint(x: rightX, y: y)
            return CalloutPlacement(
                index: entry.index,
                food: entry.food,
                anchor: entry.anchor,
                label: label,
                connectorStart: CGPoint(x: rightX - labelHalfWidth + connectorInset, y: y)
            )
        }
        return (leftPlacements + rightPlacements).sorted { $0.index < $1.index }
    }

    private func lanePositions(count: Int, in size: CGSize) -> [CGFloat] {
        guard count > 0 else { return [] }
        let top: CGFloat = 20
        let bottom = max(top, size.height - 52)
        if count == 1 { return [(top + bottom) / 2] }
        let step = (bottom - top) / CGFloat(count - 1)
        return (0..<count).map { top + CGFloat($0) * step }
    }

    private func mappedRect(for food: FoodItem, in size: CGSize) -> CGRect? {
        guard let bbox = food.depthBbox,
              bbox.count >= 4,
              imageSize.width > 1,
              imageSize.height > 1 else {
            return nil
        }

        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        let renderedWidth = imageSize.width * scale
        let renderedHeight = imageSize.height * scale
        let offsetX = (size.width - renderedWidth) / 2
        let offsetY = (size.height - renderedHeight) / 2

        let minX = CGFloat(min(bbox[0], bbox[2])) * scale + offsetX
        let minY = CGFloat(min(bbox[1], bbox[3])) * scale + offsetY
        let maxX = CGFloat(max(bbox[0], bbox[2])) * scale + offsetX
        let maxY = CGFloat(max(bbox[1], bbox[3])) * scale + offsetY
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return rect.intersection(CGRect(origin: .zero, size: size))
    }

    private func anchorPoint(for food: FoodItem, index: Int, in size: CGSize) -> CGPoint {
        if let bbox = food.depthBbox,
           bbox.count >= 4,
           imageSize.width > 1,
           imageSize.height > 1 {
            let center = CGPoint(
                x: (bbox[0] + bbox[2]) / 2,
                y: (bbox[1] + bbox[3]) / 2
            )
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let renderedWidth = imageSize.width * scale
            let renderedHeight = imageSize.height * scale
            let offsetX = (size.width - renderedWidth) / 2
            let offsetY = (size.height - renderedHeight) / 2
            return CGPoint(
                x: clamp(center.x * scale + offsetX, min: 18, max: size.width - 18),
                y: clamp(center.y * scale + offsetY, min: 18, max: size.height - 18)
            )
        }

        let fallback: [CGPoint] = [
            CGPoint(x: 0.30, y: 0.34),
            CGPoint(x: 0.68, y: 0.38),
            CGPoint(x: 0.38, y: 0.60),
            CGPoint(x: 0.72, y: 0.66),
            CGPoint(x: 0.48, y: 0.46),
            CGPoint(x: 0.58, y: 0.76)
        ]
        let point = fallback[index % fallback.count]
        return CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    private func markerColor(_ index: Int) -> Color {
        let colors = [
            Color(hex: "111318"),
            Color(hex: "24395F"),
            Color(hex: "159BFF"),
            Color(hex: "72D3A2"),
            Color(hex: "F47B55"),
            Color(hex: "8E949E")
        ]
        return colors[index % colors.count]
    }
}

private struct FoodLabelEditSheet: View {
    let food: FoodItem
    let onSave: (String, Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var gramsText: String

    init(food: FoodItem, onSave: @escaping (String, Double?) -> Void) {
        self.food = food
        self.onSave = onSave
        _name = State(initialValue: food.name)
        _gramsText = State(initialValue: "\(Int(round(food.estimatedGramsFromServingSize)))")
    }

    private var parsedGrams: Double? {
        let normalized = gramsText
            .replacingOccurrences(of: "克", with: "")
            .replacingOccurrences(of: "g", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("改图上食物")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("改完后，这餐明细和热量会一起更新。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "6D7480"))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "F4F4F6"))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 12) {
                TextField("食物名称", text: $name)
                    .font(.system(size: 18, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 10) {
                    TextField("克重", text: $gramsText)
                        .font(.system(size: 18, weight: .bold))
                        .keyboardType(.decimalPad)
                    Text("克")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button {
                onSave(name, parsedGrams)
                dismiss()
            } label: {
                Text("保存到这餐")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .background(Color.white)
    }
}

private struct FoodDetectionLabel: View {
    let index: Int
    let food: FoodItem
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Text("\(index)")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color)
                .clipShape(Circle())

            Text(food.name)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .frame(width: 128, height: 34, alignment: .leading)
        .background(.white.opacity(0.96))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
    }
}

private struct SavingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color(hex: "111318"))
            Text("正在保存这餐")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
    }
}

struct CircleButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.72))
                .clipShape(Circle())
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch systemName {
        case "chevron.left":
            return "返回"
        case "xmark":
            return "关闭"
        default:
            return "操作"
        }
    }
}

struct MacroEnergyCard: View {
    let protein: Double
    let carbs: Double
    let fat: Double

    private var shares: [(String, Double, Color)] {
        let p = protein * 4
        let c = carbs * 4
        let f = fat * 9
        let total = max(1, p + c + f)
        return [
            ("蛋白质", p / total * 100, Color(hex: "E8B8B8")),
            ("碳水", c / total * 100, Color(hex: "E8D5B8")),
            ("脂肪", f / total * 100, Color(hex: "BFD8F2")),
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("宏量能量构成")
                    .font(.system(size: 15, weight: .black))
                Spacer()
                Text("蛋 \(Int(round(protein))) · 碳 \(Int(round(carbs))) · 脂 \(Int(round(fat)))")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(shares, id: \.0) { item in
                        Rectangle()
                            .fill(item.2)
                            .frame(width: proxy.size.width * item.1 / 100)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 8) {
                ForEach(shares, id: \.0) { item in
                    HStack(spacing: 6) {
                        Circle().fill(item.2).frame(width: 8, height: 8)
                        Text("\(item.0) \(Int(round(item.1)))%")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
    }
}

struct MacroInfoCard: View {
    let label: String
    let value: Double
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Color(hex: "F9FAFC"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
            Text("\(Int(round(value)))克")
                .font(.system(size: 23, weight: .black))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }
}

private struct IngredientResultCard: View {
    let food: FoodItem
    let baseFood: FoodItem
    let onRenamed: (String) -> Void
    let onAdjusted: (Double, Double, Double, String) -> Void
    @State private var name = ""
    @State private var grams: Double = 0
    @State private var eatenRatio: Double = 1
    @State private var quantityCount: Double = 1
    @State private var quantityUnit = "克"
    @State private var gramsPerUnit: Double = 1
    @State private var didInitialize = false

    private let quantityUnits = ["克", "片", "杯", "罐", "份"]

    private var consumedCalories: Int {
        Int(round(food.calories))
    }

    private var originalCalories: Int {
        Int(round(max(food.calories, baseFood.calories)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                editorLabel("名称", icon: "text.cursor")
                TextField("食物名称", text: $name)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onChange(of: name) { _, value in
                        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if didInitialize, !clean.isEmpty, clean != food.name {
                            onRenamed(clean)
                        }
                    }
            }
            .frame(minHeight: 54)

            Divider().overlay(Color(hex: "ECEEF2"))

            HStack(spacing: 8) {
                editorLabel("份量", icon: "scalemass")
                Spacer(minLength: 4)
                Menu {
                    ForEach(quantityUnits, id: \.self) { unit in
                        Button(unit) { changeUnit(unit) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(quantityUnit)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .black))
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color(hex: "F3F4F6"))
                    .clipShape(Capsule())
                }
                quantityButton(delta: -quantityStep)
                Text(quantityText)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(minWidth: 50)
                    .multilineTextAlignment(.center)
                quantityButton(delta: quantityStep)
            }
            .frame(minHeight: 58)

            Text(quantityUnit == "克" ? "按克重计算" : String(format: "每%@约 %.0f 克，共 %.0f 克", quantityUnit, gramsPerUnit, grams))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.bottom, 8)

            Divider().overlay(Color(hex: "ECEEF2"))

            VStack(spacing: 9) {
                HStack {
                    editorLabel("吃了多少", icon: "chart.pie.fill")
                    Spacer()
                    Text("已吃 \(Int(round(eatenRatio * 100)))% · \(consumedCalories) 千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                }

                Slider(value: $eatenRatio, in: 0...1, step: 0.05)
                    .tint(Color(hex: "111318"))
                    .frame(height: 24)
                    .onChange(of: eatenRatio) { _, newValue in
                        applyAdjustment(grams: grams, eatenRatio: newValue)
                    }

                HStack(spacing: 7) {
                    ratioButton("没吃", value: 0)
                    ratioButton("一半", value: 0.5)
                    ratioButton("大部分", value: 0.75)
                    ratioButton("吃完", value: 1)
                }
            }
            .padding(.vertical, 11)

            if food.depthMealId != nil {
                Divider().overlay(Color(hex: "ECEEF2"))
                depthEvidence
                    .padding(.top, 11)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(LinearGradient(colors: [.white, Color(hex: "FBFBFD")], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "ECECF2"), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 22, x: 0, y: 10)
        .onAppear {
            initializeIfNeeded()
        }
    }

    private func initializeIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true
        name = food.name
        grams = max(1, food.estimatedGramsFromServingSize)
        let existingUnit = quantityUnits.contains(food.quantityUnit) ? food.quantityUnit : "克"
        quantityUnit = existingUnit
        if existingUnit == "克" {
            gramsPerUnit = 1
            quantityCount = grams
        } else {
            gramsPerUnit = max(0.1, food.gramsPerUnit > 0 ? food.gramsPerUnit : grams)
            quantityCount = max(0.1, food.quantityCount ?? (grams / gramsPerUnit))
            grams = quantityCount * gramsPerUnit
        }
        eatenRatio = food.caloriesRatio(comparedWith: baseFood)
    }

    private func editorLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "6D7480"))
                .frame(width: 26, height: 26)
                .background(Color(hex: "F2F4F7"))
                .clipShape(Circle())
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "6D7480"))
        }
    }

    private func ratioButton(_ title: String, value: Double) -> some View {
        let selected = abs(eatenRatio - value) < 0.03
        return Button {
            eatenRatio = value
            applyAdjustment(grams: grams, eatenRatio: value)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(selected ? .white : Color(hex: "6D7480"))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(selected ? Color(hex: "111318") : Color(hex: "F3F4F6"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var quantityStep: Double {
        quantityUnit == "克" ? 5 : 0.25
    }

    private var quantityText: String {
        if quantityUnit == "克" || quantityCount.rounded() == quantityCount {
            return "\(Int(round(quantityCount)))"
        }
        return String(format: "%.2g", quantityCount)
    }

    private func quantityButton(delta: Double) -> some View {
        Button {
            quantityCount = max(quantityUnit == "克" ? 1 : 0.25, quantityCount + delta)
            grams = max(1, quantityCount * gramsPerUnit)
            applyAdjustment(grams: grams, eatenRatio: eatenRatio)
        } label: {
            Image(systemName: delta < 0 ? "minus" : "plus")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 38, height: 34)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "减少份量" : "增加份量")
    }

    private func changeUnit(_ newUnit: String) {
        guard newUnit != quantityUnit else { return }
        quantityUnit = newUnit
        if newUnit == "克" {
            gramsPerUnit = 1
            quantityCount = max(1, grams)
        } else {
            quantityCount = 1
            gramsPerUnit = max(1, grams)
        }
        applyAdjustment(grams: grams, eatenRatio: eatenRatio)
    }

    private func applyAdjustment(grams: Double, eatenRatio: Double) {
        guard didInitialize else { return }
        onAdjusted(
            max(1, grams),
            max(0, min(1, eatenRatio)),
            max(0.01, quantityCount),
            quantityUnit
        )
    }

    private var depthEvidence: some View {
        HStack(alignment: .top, spacing: 10) {
            if let preview = food.depthMaskPreviewBase64, !preview.isEmpty {
                MaskPreviewThumbnail(base64: preview)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    depthBadge(food.depthFallback == true ? "需确认" : "照片估重", color: food.depthFallback == true ? Color(hex: "6D7480") : Color(hex: "111318"))
                    if let maskConfidence = food.depthMaskConfidence, maskConfidence > 0 {
                        depthBadge("轮廓 \(Int(round(maskConfidence * 100)))%", color: Color(hex: "6D7480"))
                    }
                    if let volume = food.depthVolumeMl, volume > 0 {
                        depthBadge("\(Int(round(volume)))毫升", color: Color(hex: "111318"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if let confidence = food.depthVolumeConfidence, confidence > 0 {
                        Text("份量把握 \(Int(round(confidence * 100)))%")
                    }
                    if let semanticConfidence = food.depthSemanticConfidence, semanticConfidence > 0 {
                        Text("名称把握 \(Int(round(semanticConfidence * 100)))%")
                    }
                    if let area = food.depthMaskAreaPixels, area > 0 {
                        Text("图上已标出")
                    }
                }
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "6D7480"))

                HStack(spacing: 6) {
                    if let method = food.depthVolumeMethod, !method.isEmpty {
                        Text(depthMethodText(method))
                    }
                    if let density = food.depthDensity, density > 0 {
                        Text("已按食物换算")
                    }
                    if food.depthSemanticNeedsSplit == true {
                        Text("建议拆分")
                    }
                    if let reason = food.depthFallbackReason, !reason.isEmpty {
                        Text(depthReasonText(reason))
                    } else if food.depthSemanticIsFood == false {
                        Text("疑似非食物")
                    }
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func depthBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func depthMethodText(_ method: String) -> String {
        switch method {
        case "depth_mask_local_baseline_integration", "depth_plane_grid_integration":
            return "照片估重"
        case "depth_pointcloud_local_surface_integration":
            return "局部照片估重"
        case "depth_pointcloud_plane_grid_integration":
            return "平面照片估重"
        case "bbox_area_fallback":
            return "面积估算"
        case "container_capacity_fill_ratio":
            return "容器容量"
        default:
            return "其他估算"
        }
    }

    private func depthReasonText(_ reason: String) -> String {
        let lowercased = reason.lowercased()
        if lowercased.contains("depth") || lowercased.contains("quality") {
            return "份量依据不足，建议确认克重。"
        }
        if lowercased.contains("bbox") || lowercased.contains("detect") {
            return "食物边界不清，建议确认名称和份量。"
        }
        if lowercased.contains("mask") || lowercased.contains("segment") {
            return "食物轮廓不够清楚，建议确认份量。"
        }
        return "建议确认份量。"
    }

}

private extension FoodItem {
    var estimatedGramsFromServingSize: Double {
        if let quantityCount, quantityCount > 0, gramsPerUnit > 0 {
            return quantityCount * gramsPerUnit
        }
        let text = servingSize.replacingOccurrences(of: "克", with: "g")
        let range = NSRange(text.startIndex..., in: text)
        if let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*g"#, options: .caseInsensitive),
           let match = regex.matches(in: text, range: range).last,
           let valueRange = Range(match.range(at: 1), in: text),
           let value = Double(text[valueRange]), value > 0 {
            return value
        }
        return 100
    }

    func caloriesRatio(comparedWith base: FoodItem) -> Double {
        guard base.calories > 0 else { return 1 }
        return max(0, calories / base.calories)
    }

}

private struct MaskPreviewThumbnail: View {
    let base64: String

    private var image: UIImage? {
        let payload = base64.split(separator: ",").last.map(String.init) ?? base64
        guard let data = Data(base64Encoded: payload) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .background(Color(hex: "111318"))
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .background(Color(hex: "EEF0F4"))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct NutritionMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
