import SwiftUI

private extension String {
    var casefoldedForMealMatching: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}

private enum RecipeInputMode: String, CaseIterable, Identifiable {
    case manual
    case web
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "手动食材"
        case .web: return "链接导入"
        case .photo: return "拍食材"
        }
    }

    var subtitle: String {
        switch self {
        case .manual: return "逐项输入"
        case .web: return "粘贴链接"
        case .photo: return "扫描食物"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "list.bullet.rectangle"
        case .web: return "link"
        case .photo: return "camera.fill"
        }
    }
}

private struct IngredientRecipeMatchSheetView: View {
    let recipe: IngredientRecipeSuggestion
    let onSaved: (IngredientRecipeSuggestion) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [IngredientRecipeMatchDraft]
    @State private var replacingDraftId: String?
    @State private var searchQuery = ""
    @State private var searchResults: [FoodItem] = []
    @State private var searching = false
    @State private var saving = false
    @State private var message = ""

    init(recipe: IngredientRecipeSuggestion, onSaved: @escaping (IngredientRecipeSuggestion) -> Void) {
        self.recipe = recipe
        self.onSaved = onSaved
        _drafts = State(initialValue: recipe.ingredientsBreakdown.map { IngredientRecipeMatchDraft(item: $0) })
    }

    private var pendingCount: Int {
        drafts.filter(\.needsMatch).count
    }

    private var pendingDrafts: [IngredientRecipeMatchDraft] {
        drafts.filter(\.needsMatch)
    }

    private var matchedDrafts: [IngredientRecipeMatchDraft] {
        drafts.filter { !$0.needsMatch }
    }

    private var selectedDraftName: String {
        guard let replacingDraftId else { return "" }
        return drafts.first { $0.id == replacingDraftId }?.name ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("核对食材匹配")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text(recipe.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                        if pendingCount > 0 {
                            Label("\(pendingCount) 项食材还没有完整营养，请匹配常见食物。", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "92400E"))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(hex: "FFFBEB"))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            Label("所有食材都有营养值，仍可手动替换。", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "16A34A"))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(hex: "ECFDF3"))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if replacingDraftId != nil {
                        searchPanel
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("匹配的配料")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("这些匹配项是否正确？不准确的可以点“替换”。")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                        if matchedDrafts.isEmpty {
                            Text("先点“匹配”，把原料对应到常见食物。")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else {
                            ForEach(matchedDrafts) { draft in
                                ingredientRow(draft)
                            }
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if !pendingDrafts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("不匹配的配料")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("请帮助我们找到下面未匹配原料的匹配项。")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            ForEach(pendingDrafts) { draft in
                                ingredientRow(draft)
                            }
                        }
                        .padding(18)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ingredientRecipeMessageNeedsAttention(message) ? Color(hex: "EF4444") : Color(hex: "4B5563"))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveMatches() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("保存匹配")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .disabled(saving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await saveMatches() }
                } label: {
                    Text(saving ? "保存中" : pendingCount > 0 ? "先保存，可稍后继续匹配" : "保存匹配")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .disabled(saving)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索替换：\(selectedDraftName)", text: $searchQuery)
                    .font(.system(size: 14, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { Task { await searchFoods() } }
                Button {
                    Task { await searchFoods() }
                } label: {
                    if searching {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("搜索")
                            .font(.system(size: 12, weight: .black))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: "2563EB"))
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(hex: "F7F8FA"))
            .clipShape(Capsule())

            if !searchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(searchResults.prefix(6))) { food in
                        Button {
                            apply(food)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(food.name)
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                        .lineLimit(1)
                                    Text("\(Int(round(food.calories))) 千卡 · 蛋白 \(formatNumber(food.protein))克 · \(food.servingSize)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .accessibilityHidden(true)
                            }
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func ingredientRow(_ draft: IngredientRecipeMatchDraft) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(draft.name)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    if draft.needsMatch {
                        Text("待匹配")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "92400E"))
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color(hex: "FFFBEB"))
                            .clipShape(Capsule())
                    }
                }
                Text("\(Int(round(draft.calories))) 千卡 · 蛋白 \(formatNumber(draft.protein))克 · \(draft.amount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replacingDraftId = draft.id
                searchQuery = draft.name
                searchResults = []
                Task { await searchFoods() }
            } label: {
                Text(draft.needsMatch ? "匹配" : "替换")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func searchFoods() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true
        message = ""
        do {
            searchResults = try await APIClient.shared.searchFoods(query: query)
        } catch {
            message = ingredientRecipeFriendlyError(error, fallback: "搜索食材失败")
        }
        searching = false
    }

    private func apply(_ food: FoodItem) {
        guard let replacingDraftId, let index = drafts.firstIndex(where: { $0.id == replacingDraftId }) else { return }
        let oldName = drafts[index].name
        drafts[index] = IngredientRecipeMatchDraft(food: food, originalAmount: drafts[index].amount)
        self.replacingDraftId = nil
        searchQuery = ""
        searchResults = []
        message = "已用 \(food.name) 替换 \(oldName)，克数已保留为 \(drafts[index].amount)。"
    }

    private func saveMatches() async {
        guard !saving else { return }
        saving = true
        message = ""
        do {
            let response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                id: recipe.id,
                recipePayload: recipePayload()
            )
            onSaved(response.recipe)
        } catch {
            message = ingredientRecipeFriendlyError(error, fallback: "保存匹配失败")
        }
        saving = false
    }

    private func recipePayload() -> [String: Any] {
        let total = drafts.reduce(IngredientRecipeMatchTotals()) { partial, draft in
            partial.adding(draft.totals)
        }
        let servings = max(1, recipe.servings)
        var payload: [String: Any] = [
            "id": recipe.id,
            "title": recipe.title,
            "servings": servings,
            "calories": round1(total.calories / Double(servings)),
            "protein": round1(total.protein / Double(servings)),
            "carbs": round1(total.carbs / Double(servings)),
            "fat": round1(total.fat / Double(servings)),
            "fiber": round1(total.fiber / Double(servings)),
            "sodium": round1(total.sodium / Double(servings)),
            "sugar": round1(total.sugar / Double(servings)),
            "prep_time_minutes": recipe.prepTimeMinutes,
            "active_time_minutes": recipe.activeTimeMinutes ?? recipe.prepTimeMinutes,
            "inactive_time_minutes": recipe.inactiveTimeMinutes ?? 0,
            "reason": recipe.reason,
            "instructions": recipe.instructions,
            "ingredients_breakdown": drafts.map { $0.payload },
            "missing_ingredients": drafts.filter(\.needsMatch).map(\.name),
            "source": recipe.source,
            "tags": recipe.tags ?? [],
            "meal_types": RecipeMealType.inferredList(mealTypes: recipe.mealTypes, tags: recipe.tags)
        ]
        if let sourceURL = recipe.sourceURL, !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["source_url"] = sourceURL
        }
        if let cookingTime = recipe.cookingTime, !cookingTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["cooking_time"] = cookingTime
        }
        return payload
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func formatNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }
}

private func ingredientRecipeFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackText = ingredientRecipeFriendlyFallback(fallback)
    guard !raw.isEmpty else { return fallbackText }

    let lowercased = raw.lowercased()
    if lowercased.contains("could not connect")
        || lowercased.contains("connection")
        || lowercased.contains("timed out")
        || raw.contains("连接不到")
        || raw.contains("无法连接")
        || raw.contains("网络") {
        return "现在没连上，这次操作还没保存；检查网络后再点刚才的按钮。"
    }
    if lowercased.contains("not found") || raw.contains("404") {
        return "这条内容暂时找不到，返回后刷新列表。"
    }
    if raw.hasPrefix("{") || raw.hasPrefix("[") || raw.count > 120 || lowercased.contains("json") {
        return fallbackText
    }
    if raw.contains("失败")
        || raw.contains("错误")
        || raw.contains("异常")
        || raw.contains("无法")
        || lowercased.contains("failed")
        || lowercased.contains("error")
        || lowercased.contains("exception") {
        return fallbackText
    }
    return raw
}

private func ingredientRecipeFriendlyFallback(_ fallback: String) -> String {
    if fallback.contains("搜索") {
        return "这次还没搜出来，换个更短的关键词再搜。"
    }
    if fallback.contains("生成") {
        return "这份菜谱暂时没整理好，检查网络后再点生成。"
    }
    if fallback.contains("导入") || fallback.contains("记录") {
        return "这次还没记上，内容还在，检查网络后再点导入。"
    }
    if fallback.contains("保存") {
        return "这次还没保存上，内容还在，检查网络后再点保存。"
    }
    return fallback
}

private func ingredientRecipeMessageNeedsAttention(_ message: String) -> Bool {
    message.contains("失败")
        || message.contains("错误")
        || message.contains("连不上")
        || message.contains("无法")
        || message.contains("暂时")
        || message.contains("还没")
        || message.contains("找不到")
}

private struct IngredientRecipeMatchDraft: Identifiable {
    let id = UUID().uuidString
    let name: String
    let amount: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let sodium: Double
    let sugar: Double
    let processingLevel: String?

    init(item: IngredientBreakdownItem) {
        name = item.name
        amount = item.displayAmount ?? item.amount
        calories = item.calories
        protein = item.protein
        carbs = item.carbs ?? 0
        fat = item.fat ?? 0
        fiber = 0
        sodium = 0
        sugar = item.sugar ?? 0
        processingLevel = item.processingLevel
    }

    init(food: FoodItem, originalAmount: String) {
        let cleanAmount = originalAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        let preservedAmount = cleanAmount.isEmpty ? food.servingSize : cleanAmount
        let originalGrams = IngredientRecipeMatchDraft.grams(from: preservedAmount)
        let servingGrams = IngredientRecipeMatchDraft.grams(from: food.servingSize)
        let scale: Double
        if let originalGrams, let servingGrams, servingGrams > 0 {
            scale = max(0.05, min(20, originalGrams / servingGrams))
        } else {
            scale = 1
        }
        name = food.name
        amount = preservedAmount
        calories = food.calories * scale
        protein = food.protein * scale
        carbs = food.carbs * scale
        fat = food.fat * scale
        fiber = food.fiber * scale
        sodium = food.sodium * scale
        sugar = food.sugar * scale
        processingLevel = food.processingLevel
    }

    var needsMatch: Bool {
        calories <= 0.05 && protein <= 0.05 && carbs <= 0.05 && fat <= 0.05
    }

    var totals: IngredientRecipeMatchTotals {
        IngredientRecipeMatchTotals(
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            fiber: fiber,
            sodium: sodium,
            sugar: sugar
        )
    }

    var payload: [String: Any] {
        var data: [String: Any] = [
            "name": name,
            "amount": amount,
            "display_amount": amount,
            "calories": round1(calories),
            "protein": round1(protein),
            "carbs": round1(carbs),
            "fat": round1(fat),
            "fiber": round1(fiber),
            "sodium": round1(sodium),
            "sugar": round1(sugar),
            "serving_size": amount
        ]
        if let processingLevel {
            data["processing_level"] = processingLevel
        }
        return data
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func grams(from text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: "Ｇ", with: "g")
            .replacingOccurrences(of: "ｇ", with: "g")
            .replacingOccurrences(of: "克", with: "g")
        guard let range = normalized.range(of: #"\d+(?:\.\d+)?\s*g"#, options: .regularExpression) else {
            return nil
        }
        let token = String(normalized[range])
        let number = token
            .replacingOccurrences(of: "g", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(number)
    }
}

private struct IngredientRecipeMatchTotals {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var sodium: Double = 0
    var sugar: Double = 0

    func adding(_ other: IngredientRecipeMatchTotals) -> IngredientRecipeMatchTotals {
        IngredientRecipeMatchTotals(
            calories: calories + other.calories,
            protein: protein + other.protein,
            carbs: carbs + other.carbs,
            fat: fat + other.fat,
            fiber: fiber + other.fiber,
            sodium: sodium + other.sodium,
            sugar: sugar + other.sugar
        )
    }
}

struct IngredientRecipeSheetView: View {
    let onLogged: () -> Void
    let onRecipesChanged: ([IngredientRecipeSuggestion]) -> Void
    let logDate: String
    let mealCategory: String
    let savedRecipes: [IngredientRecipeHistoryItem]
    let savedMeals: [SavedMealItem]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var inputMode: RecipeInputMode = .manual
    @State private var selectedMealCategory = "dinner"
    @State private var ingredientText = ""
    @State private var recipeURL = ""
    @State private var imageBase64 = ""
    @State private var showCamera = false
    @State private var showImagePicker = false
    @State private var servings = "1"
    @State private var recipes: [IngredientRecipeSuggestion] = []
    @State private var identified: [String] = []
    @State private var portions: [String: Double] = [:]
    @State private var loading = false
    @State private var importingURL = false
    @State private var loggingId = ""
    @State private var savingMealId = ""
    @State private var matchingRecipe: IngredientRecipeSuggestion?
    @State private var message = ""
    let onMealSaved: (SavedMealItem, Bool) -> Void

    init(
        logDate: String = "",
        mealCategory: String = "dinner",
        initialInputMode: String = "manual",
        savedRecipes: [IngredientRecipeHistoryItem] = [],
        savedMeals: [SavedMealItem] = [],
        onRecipesChanged: @escaping ([IngredientRecipeSuggestion]) -> Void = { _ in },
        onMealSaved: @escaping (SavedMealItem, Bool) -> Void = { _, _ in },
        onLogged: @escaping () -> Void
    ) {
        self.logDate = logDate
        self.mealCategory = mealCategory
        self.savedRecipes = savedRecipes
        self.savedMeals = savedMeals
        self.onRecipesChanged = onRecipesChanged
        self.onMealSaved = onMealSaved
        self.onLogged = onLogged
        _inputMode = State(initialValue: RecipeInputMode(rawValue: initialInputMode) ?? .manual)
        _selectedMealCategory = State(initialValue: IngredientRecipeSheetView.normalizedMealCategory(mealCategory))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    inputCard
                    if !message.isEmpty { messageCard }
                    if loading && recipes.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在整理成可保存菜谱...")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .softCard(radius: 22)
                    }
                    if !identified.isEmpty {
                        FlowTags(values: identified, active: identified) { _ in }
                            .padding(14)
                            .softCard(radius: 20)
                    }
                    ForEach(recipes) { recipe in
                        recipeCard(recipe)
                    }
                }
                .padding(20)
                .padding(.bottom, 30)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .principal) {
                    Text(sheetTitle)
                        .font(.system(size: 17, weight: .black))
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(source: "ingredient_recipe") { capture in
                imageBase64 = capture.imageBase64
                inputMode = .photo
                showCamera = false
                message = "已拍摄食材图片，会和说明一起整理。"
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker { image in
                if let data = image.jpegData(compressionQuality: 0.9) {
                    imageBase64 = data.base64EncodedString()
                    inputMode = .photo
                    message = "已选择食材图片，会和说明一起整理。"
                }
            }
        }
        .sheet(item: $matchingRecipe) { recipe in
            IngredientRecipeMatchSheetView(recipe: recipe) { updatedRecipe in
                recipes.removeAll { $0.id == updatedRecipe.id }
                recipes.insert(updatedRecipe, at: 0)
                onRecipesChanged([updatedRecipe])
                matchingRecipe = nil
                message = "已保存食材匹配：\(updatedRecipe.title)。"
            }
        }
    }

    private var sheetTitle: String {
        switch inputMode {
        case .manual:
            return "食材做菜"
        case .web:
            return "导入食谱"
        case .photo:
            return "拍食材做菜谱"
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "chef.hat")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(inputMode == .web ? "导入一个食谱" : "用现有食材做一餐")
                        .font(.system(size: 19, weight: .black))
                    Text(inputMode == .web ? "粘贴食谱链接，会整理配料和做法。" : "整理好后可一键写入今天的食物日志。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }

            inputModeSelector
            targetMealPicker

            switch inputMode {
            case .manual:
                manualIngredientInput
                recipeBuildControls
            case .web:
                webImportInput
            case .photo:
                photoIngredientInput
                manualIngredientInput
                recipeBuildControls
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private var inputModeSelector: some View {
        HStack(spacing: 8) {
            ForEach(RecipeInputMode.allCases) { mode in
                Button {
                    inputMode = mode
                    message = ""
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 16, weight: .black))
                            .accessibilityHidden(true)
                        Text(mode.title)
                            .font(.system(size: 11, weight: .black))
                            .lineLimit(1)
                        Text(mode.subtitle)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(inputMode == mode ? Color.white.opacity(0.78) : .secondary)
                            .lineLimit(1)
                    }
                    .foregroundStyle(inputMode == mode ? .white : Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 74)
                    .background(inputMode == mode ? Color.black : Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
            }
        }
    }

    private var targetMealPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .accessibilityHidden(true)
                Text("记录到")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                Text(mealCategoryTitle(selectedMealCategory))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(IngredientRecipeSheetView.mealCategoryOptions, id: \.0) { option in
                    Button {
                        selectedMealCategory = option.0
                        message = "做好后的食谱将记录到\(option.1)。"
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.2)
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                            Text(option.1)
                                .font(.system(size: 11, weight: .black))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selectedMealCategory == option.0 ? .white : Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(selectedMealCategory == option.0 ? Color.black : Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录到\(option.1)")
                }
            }
        }
        .padding(12)
        .background(Color(hex: "FBFBFC"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var manualIngredientInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(inputMode == .photo ? "补充说明" : "食材")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $ingredientText)
                    .font(.system(size: 15, weight: .bold))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: inputMode == .photo ? 70 : 88)
                    .padding(10)
                if ingredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(inputMode == .photo ? "可选：补充份量或做法，比如少油、两人份" : "例如：鸡蛋2个、番茄1个、米饭150克")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: "9CA3AF"))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var webImportInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("食谱链接")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("粘贴食谱链接", text: $recipeURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button {
                    Task { await importRecipeURL() }
                } label: {
                    if importingURL {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                            .frame(width: 70, height: 42)
                            .background(Color.black)
                            .clipShape(Capsule())
                    } else {
                        Text("导入")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 70, height: 42)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(importingURL || recipeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("从链接导入食谱")
            }
            Text("先解析配料和做法，再保存到我的食谱；导入后可逐项匹配食材。")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private var photoIngredientInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("食材照片")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    showCamera = true
                } label: {
                    Label("拍食材", systemImage: "camera.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Button {
                    showImagePicker = true
                } label: {
                    Label("选图片", systemImage: "photo")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !imageBase64.isEmpty {
                    Button {
                        imageBase64 = ""
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 42, height: 42)
                            .background(Color(hex: "F4F5F7"))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityLabel("移除已选图片")
                }
            }
            Text(imageBase64.isEmpty ? "拍纸质食谱或现有食材，做好后仍可核对食材匹配。" : "已选择图片，可继续补充说明后整理。")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private var recipeBuildControls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text("份数")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                TextField("1", text: $servings)
                    .keyboardType(.numberPad)
                    .font(.system(size: 18, weight: .black))
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button { Task { await buildRecipes() } } label: {
                Label(loading ? "正在整理" : "做成菜谱", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .disabled(loading || importingURL)
        }
    }

    private var messageCard: some View {
        Text(message)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(ingredientRecipeMessageNeedsAttention(message) ? Color(hex: "DC2626") : Color(hex: "4B5563"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .softCard(radius: 18)
    }

    private func recipeCard(_ recipe: IngredientRecipeSuggestion) -> some View {
        let portion = portions[recipe.id] ?? 1
        let pendingMatches = recipePendingMatchCount(recipe)
        let mealTypes = RecipeMealType.inferredList(mealTypes: recipe.mealTypes, tags: recipe.tags)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recipeSourceDisplay(recipe))
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                    Text(recipe.title)
                        .font(.system(size: 17, weight: .black))
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(round(recipe.calories * portion)))")
                        .font(.system(size: 24, weight: .black))
                    Text("千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }
            Text(recipe.reason)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
            Text("蛋白 \(Int(round(recipe.protein * portion)))克 · 碳水 \(Int(round(recipe.carbs * portion)))克 · 脂肪 \(Int(round(recipe.fat * portion)))克 · \(recipeTimeDisplay(recipe))")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "4B5563"))
            Label("已保存到我的食谱，可继续核对、记录或保存为餐品。", systemImage: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "16A34A"))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
                .background(Color(hex: "ECFDF5"))
                .clipShape(Capsule())
            if !mealTypes.isEmpty {
                HStack(spacing: 7) {
                    ForEach(mealTypes, id: \.self) { mealType in
                        Text("适用\(RecipeMealType.title(for: mealType))")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "166534"))
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(Color(hex: "F0FDF4"))
                            .clipShape(Capsule())
                    }
                }
            }
            if let sourceURL = validRecipeSourceURL(recipe) {
                Button {
                    openURL(sourceURL)
                } label: {
                    Label("打开原网页", systemImage: "safari")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color(hex: "EFF6FF"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开食谱原网页")
            }
            if !recipe.ingredientsBreakdown.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(recipe.ingredientsBreakdown.prefix(6)) { item in
                        Text("\(item.name) · \(item.displayAmount ?? item.amount)")
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
            if pendingMatches > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "F59E0B"))
                        .accessibilityHidden(true)
                    Text("\(pendingMatches) 项食材需要匹配常见食物")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "92400E"))
                    Spacer()
                    Button {
                        matchingRecipe = recipe
                    } label: {
                        Text("核对")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color(hex: "2563EB"))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color(hex: "FFFBEB"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: "FDE68A"), lineWidth: 1)
                )
            } else if !recipe.ingredientsBreakdown.isEmpty {
                Button {
                    matchingRecipe = recipe
                } label: {
                    Label("核对食材匹配", systemImage: "checklist")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(recipe.instructions.prefix(3).enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                portionStepper(id: recipe.id)
                Button { Task { await saveRecipeAsMeal(recipe) } } label: {
                    Text(savingMealId == recipe.id ? "保存中" : "保存为餐品")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                }
                .disabled(!savingMealId.isEmpty)
                Button { Task { await log(recipe, portion: portion) } } label: {
                    Text(loggingId == recipe.id ? "记录中" : "一键记录")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .disabled(loggingId == recipe.id)
            }
        }
        .padding(16)
        .softCard(radius: 22)
    }

    private func validRecipeSourceURL(_ recipe: IngredientRecipeSuggestion) -> URL? {
        guard let raw = recipe.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return nil
        }
        return url
    }

    private func recipePendingMatchCount(_ recipe: IngredientRecipeSuggestion) -> Int {
        recipe.ingredientsBreakdown.filter { ingredient in
            ingredient.calories <= 0.05
                && ingredient.protein <= 0.05
                && (ingredient.carbs ?? 0) <= 0.05
                && (ingredient.fat ?? 0) <= 0.05
        }.count
    }

    private func recipeSourceDisplay(_ recipe: IngredientRecipeSuggestion) -> String {
        switch recipe.source {
        case "recipe_url_import":
            return "链接导入"
        case "ai_enhanced":
            return "已优化"
        case "ingredient_ai":
            return "食材整理"
        case "manual":
            return "手动食谱"
        default:
            return "基础推荐"
        }
    }

    private func recipeTimeDisplay(_ recipe: IngredientRecipeSuggestion) -> String {
        if let cookingTime = recipe.cookingTime, !cookingTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cookingTime
        }
        return "\(recipe.prepTimeMinutes) 分钟"
    }

    private func saveRecipeAsMeal(_ recipe: IngredientRecipeSuggestion) async {
        guard savingMealId.isEmpty else { return }
        savingMealId = recipe.id
        message = ""
        do {
            let food = recipeFoodItem(recipe)
            let matchingMeal = savedMeals.first {
                $0.title.casefoldedForMealMatching == recipe.title.casefoldedForMealMatching
            }
            let meal: SavedMealItem
            if let matchingMeal {
                meal = try await APIClient.shared.updateSavedMeal(
                    id: matchingMeal.id,
                    title: matchingMeal.title,
                    foods: [food],
                    mealCategory: selectedMealCategory,
                    imageUrl: matchingMeal.imageUrl ?? "",
                    note: recipe.reason,
                    instructions: recipe.instructions
                )
                onMealSaved(meal, true)
                message = "已替换同名餐品：\(meal.title)。"
            } else {
                meal = try await APIClient.shared.saveMealTemplate(
                    title: recipe.title,
                    foods: [food],
                    mealCategory: selectedMealCategory,
                    note: recipe.reason,
                    instructions: recipe.instructions
                )
                onMealSaved(meal, false)
                message = "已保存为餐品：\(meal.title)。"
            }
        } catch {
            message = ingredientRecipeFriendlyError(error, fallback: "保存为餐品失败")
        }
        savingMealId = ""
    }

    private func recipeFoodItem(_ recipe: IngredientRecipeSuggestion) -> FoodItem {
        var food = FoodItem(name: recipe.title)
        food.calories = recipe.calories
        food.protein = recipe.protein
        food.carbs = recipe.carbs
        food.fat = recipe.fat
        food.fiber = recipe.fiber
        food.sodium = recipe.sodium
        food.sugar = recipe.sugar ?? 0
        food.servingSize = "1份"
        food.processingLevel = "processed"
        return food
    }

    private func portionStepper(id: String) -> some View {
        let value = portions[id] ?? 1
        return HStack(spacing: 5) {
            Button { portions[id] = max(0.5, ((value - 0.1) * 10).rounded() / 10) } label: { Image(systemName: "minus") }
                .accessibilityLabel("减少份量")
            Text(String(format: "%.1fx", value))
                .font(.system(size: 13, weight: .black))
                .frame(width: 42)
            Button { portions[id] = min(2, ((value + 0.1) * 10).rounded() / 10) } label: { Image(systemName: "plus") }
                .accessibilityLabel("增加份量")
        }
        .font(.system(size: 13, weight: .black))
        .frame(height: 42)
        .padding(.horizontal, 9)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private func matchingSavedRecipe(title: String) -> IngredientRecipeHistoryItem? {
        let normalizedTitle = title.casefoldedForMealMatching
        guard !normalizedTitle.isEmpty else { return nil }
        return savedRecipes.first { $0.recipe.title.casefoldedForMealMatching == normalizedTitle }
    }

    private func upsertRecipe(_ recipe: IngredientRecipeSuggestion) {
        let normalizedTitle = recipe.title.casefoldedForMealMatching
        recipes.removeAll { existing in
            existing.id == recipe.id || (!normalizedTitle.isEmpty && existing.title.casefoldedForMealMatching == normalizedTitle)
        }
        recipes.insert(recipe, at: 0)
    }

    private func buildRecipes() async {
        let text = ingredientText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !imageBase64.isEmpty else {
            message = "先拍一张食材照片，或输入你手头有什么食材。"
            return
        }
        loading = true
        message = ""
        do {
            let response = try await APIClient.shared.buildRecipesFromIngredients(
                ingredients: text,
                imageBase64: imageBase64.isEmpty ? nil : imageBase64,
                servings: max(1, min(8, Int(servings) ?? 1)),
                limit: 3,
                useAI: true,
                date: logDate
            )
            identified = response.identifiedIngredients
            recipes = []
            response.recipes.reversed().forEach { upsertRecipe($0) }
            onRecipesChanged(response.recipes)
            message = response.message ?? "已整理好可记录菜谱。"
        } catch {
            message = ingredientRecipeFriendlyError(error, fallback: "菜谱暂时没做好")
        }
        loading = false
    }

    private func importRecipeURL() async {
        let url = recipeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        importingURL = true
        message = ""
        do {
            let imported = try await APIClient.shared.importRecipeFromURL(url)
            if let error = imported.error, !error.isEmpty {
                message = error
                importingURL = false
                return
            }
            let ingredients = imported.ingredients ?? []
            if !ingredients.isEmpty {
                ingredientText = ingredients.joined(separator: "，")
                identified = ingredients
            }
            let payload = importedRecipePayload(imported, sourceURL: url)
            let importedTitle = String(describing: payload["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let matched = matchingSavedRecipe(title: importedTitle)
            let response: IngredientRecipeUpdateResponse
            if let matched {
                response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                    id: matched.id,
                    recipePayload: payload
                )
            } else {
                response = try await APIClient.shared.createIngredientRecipeSuggestion(
                    recipePayload: payload,
                    date: logDate,
                    source: "recipe_url_import"
                )
            }
            upsertRecipe(response.recipe)
            onRecipesChanged([response.recipe])
            message = matched == nil ? "已导入并保存食谱：\(response.recipe.title)。" : "已导入并替换同名食谱：\(response.recipe.title)。"
        } catch {
            message = ingredientRecipeFriendlyError(error, fallback: "导入食谱失败")
        }
        importingURL = false
    }

    private func log(_ recipe: IngredientRecipeSuggestion, portion: Double) async {
        loggingId = recipe.id
        message = ""
        do {
            let response = try await APIClient.shared.logIngredientRecipe(
                id: recipe.id,
                portionMultiplier: portion,
                mealCategory: selectedMealCategory,
                date: logDate
            )
            message = "已记录 \(response.saved ?? 0) 项到\(mealCategoryTitle(selectedMealCategory))。"
            onLogged()
        } catch {
            message = ingredientRecipeFriendlyError(error, fallback: "记录失败")
        }
        loggingId = ""
    }

    private func importedRecipePayload(_ imported: RecipeURLImportResponse, sourceURL: String) -> [String: Any] {
        let title = (imported.recipeName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let servingsCount = max(1, min(24, imported.servings ?? 1))
        let ingredients = imported.ingredients ?? []
        let instructions = (imported.instructions ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let activeMinutes = max(0, min(480, imported.activeTimeMinutes ?? minutes(from: imported.cookingTime)))
        let inactiveMinutes = max(0, min(480, imported.inactiveTimeMinutes ?? 0))
        var payload: [String: Any] = [
            "id": "recipe_url_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))",
            "title": title.isEmpty ? "导入食谱" : title,
            "servings": servingsCount,
            "serving_size_label": (imported.servingSizeLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1份" : imported.servingSizeLabel!,
            "calories": imported.caloriesPerServing ?? 0,
            "protein": imported.proteinPerServing ?? 0,
            "carbs": imported.carbsPerServing ?? 0,
            "fat": imported.fatPerServing ?? 0,
            "fiber": 0,
            "sodium": 0,
            "sugar": 0,
            "prep_time_minutes": min(480, activeMinutes + inactiveMinutes),
            "active_time_minutes": activeMinutes,
            "inactive_time_minutes": inactiveMinutes,
            "reason": "从链接食谱导入",
            "instructions": instructions.isEmpty ? ["按原链接食谱步骤制作。"] : instructions,
            "ingredients_breakdown": ingredients.map { ingredientPayload($0) },
            "missing_ingredients": [],
            "source": "recipe_url_import",
            "source_url": imported.sourceURL ?? sourceURL,
            "tags": ["导入", "网页食谱"],
            "meal_types": [RecipeMealType.normalized(selectedMealCategory) ?? "dinner"]
        ]
        if let cookingTime = imported.cookingTime, !cookingTime.isEmpty {
            payload["cooking_time"] = cookingTime
        }
        if let imageURL = imported.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
            payload["image_url"] = imageURL
        }
        return payload
    }

    private func ingredientPayload(_ ingredient: String) -> [String: Any] {
        let clean = ingredient.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "name": clean.isEmpty ? "食材" : clean,
            "amount": clean.isEmpty ? "适量" : clean,
            "display_amount": clean.isEmpty ? "适量" : clean,
            "calories": 0,
            "protein": 0,
            "carbs": 0,
            "fat": 0,
            "sugar": 0,
            "serving_size": clean.isEmpty ? "适量" : clean,
            "processing_level": "ingredient"
        ]
    }

    private func minutes(from text: String?) -> Int {
        guard let text else { return 0 }
        let digits = text.compactMap { $0.isNumber ? String($0) : nil }.joined()
        return min(480, max(0, Int(digits) ?? 0))
    }

    private func mealCategoryTitle(_ value: String) -> String {
        switch IngredientRecipeSheetView.normalizedMealCategory(value) {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        case "snack": return "加餐"
        default: return "今天"
        }
    }

    private static let mealCategoryOptions = [
        ("breakfast", "早餐", "sunrise.fill"),
        ("lunch", "午餐", "sun.max.fill"),
        ("dinner", "晚餐", "moon.stars.fill"),
        ("snack", "加餐", "leaf.fill"),
    ]

    private static func normalizedMealCategory(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch clean {
        case "breakfast", "lunch", "dinner", "snack":
            return clean
        default:
            return "dinner"
        }
    }
}
