import SwiftUI
import UIKit

private func recipeServingSizeLabel(_ recipe: IngredientRecipeSuggestion) -> String {
    let label = (recipe.servingSizeLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? "1份" : label
}

private func recipeServingSizeOptions(for recipe: IngredientRecipeSuggestion, fallbackLabel: String? = nil) -> [RecipeServingSizeOption] {
    let baseLabel = (fallbackLabel ?? recipeServingSizeLabel(recipe)).trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanBaseLabel = baseLabel.isEmpty ? "1份" : baseLabel
    var options: [RecipeServingSizeOption] = []
    var seen = Set<String>()

    func add(_ option: RecipeServingSizeOption) {
        let cleanLabel = option.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(cleanLabel)-\(String(format: "%.4f", option.nutritionMultiplier))"
        guard !cleanLabel.isEmpty, !seen.contains(key) else { return }
        seen.insert(key)
        options.append(option)
    }

    for option in recipe.servingSizes ?? [] {
        add(option)
    }
    add(RecipeServingSizeOption(value: 0.5, nutritionMultiplier: 0.5, label: "半份"))
    add(RecipeServingSizeOption(value: 1, nutritionMultiplier: 1, label: cleanBaseLabel))
    add(RecipeServingSizeOption(value: 1.5, nutritionMultiplier: 1.5, label: "1.5份"))
    add(RecipeServingSizeOption(value: 2, nutritionMultiplier: 2, label: "2份"))
    return Array(options.prefix(8))
}

private func recipeServingSizeOptionsPayload(_ options: [RecipeServingSizeOption]) -> [[String: Any]] {
    options.map { option in
        [
            "value": option.value,
            "unit": option.unit,
            "nutrition_multiplier": option.nutritionMultiplier,
            "label": option.displayLabel,
        ]
    }
}

private func recipeServingSizeLabelForLog(_ recipe: IngredientRecipeSuggestion, multiplier: Double) -> String {
    let safeMultiplier = max(0.05, min(20.0, multiplier))
    if let matched = recipeServingSizeOptions(for: recipe).first(where: { abs($0.nutritionMultiplier - safeMultiplier) < 0.01 }) {
        return matched.displayLabel
    }
    let base = recipeServingSizeLabel(recipe)
    if abs(safeMultiplier - 1.0) < 0.01 {
        return base
    }
    let text = abs(safeMultiplier.rounded() - safeMultiplier) < 0.01 ? "\(Int(round(safeMultiplier)))" : String(format: "%.2f", safeMultiplier)
    return "\(text)份 × \(base)"
}

private func recipeImageURL(_ recipe: IngredientRecipeSuggestion) -> URL? {
    guard let raw = recipe.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let url = URL(string: raw),
          url.scheme?.hasPrefix("http") == true else {
        return nil
    }
    return url
}

private func recipeExtendedNutritionPayload(_ recipe: IngredientRecipeSuggestion) -> [String: Any] {
    var payload: [String: Any] = [:]
    if let value = recipe.addedSugar { payload["added_sugar"] = value }
    if let value = recipe.satFat { payload["sat_fat"] = value }
    if let value = recipe.transFat { payload["trans_fat"] = value }
    if let value = recipe.monounsaturatedFat { payload["monounsaturated_fat"] = value }
    if let value = recipe.polyunsaturatedFat { payload["polyunsaturated_fat"] = value }
    if let value = recipe.cholesterol { payload["cholesterol"] = value }
    if let value = recipe.vitaminA { payload["vitamin_a"] = value }
    if let value = recipe.vitaminC { payload["vitamin_c"] = value }
    if let value = recipe.calcium { payload["calcium"] = value }
    if let value = recipe.iron { payload["iron"] = value }
    if let value = recipe.potassium { payload["potassium"] = value }
    return payload
}

struct InfoPageView: View {
    let logDate: String
    let onChanged: () -> Void
    let onScanFood: () -> Void
    let onVoiceLog: () -> Void

    @Environment(\.openURL) private var openURL

    private let savedLibraryPageSize = 100

    @State private var goalType = "fat_loss"
    @State private var dailyCalories = "2000"
    @State private var days = "3"
    @State private var mealsPerDay = "3"
    @State private var prepTime = "20"
    @State private var preferences = "高蛋白，家常，少油"
    @State private var avoid = ""
    @State private var plan: MealPlanPayload?
    @State private var history: [MealPlanPayload] = []
    @State private var recipeCollections: [MealPlanRecipeCollection] = []
    @State private var recipeSuggestions: [IngredientRecipeHistoryItem] = []
    @State private var savedMeals: [SavedMealItem] = []
    @State private var savedFoods: [SavedFoodItem] = []
    @State private var recentFoods: [FoodLogRow] = []
    @State private var frequentFoodItems: [FrequentFoodItem] = []
    @State private var dailySummary: DailySummary?
    @State private var userPreferences = UserPreferences()
    @State private var macroGoals = MacroGoals()
    @State private var mealShareDraft: [String: Double] = ["breakfast": 0.25, "lunch": 0.35, "dinner": 0.30, "snack": 0.10]
    @State private var mealNamesDraft: [String: String] = ["breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"]
    @State private var searchQuery = ""
    @State private var recentSearchTerms: [String] = []
    @State private var savedLibraryQuery = ""
    @State private var savedLibraryScope = "all"
    @State private var savedLibraryMealCategoryFilter = "all"
    @State private var savedRecipeTagFilter = "all"
    @State private var savedLibrarySort = "created"
    @AppStorage("savedLibrary.showAllMealCategories") private var showAllMealCategoriesInSavedLibrary = true
    @State private var frequentFoodsMealFilter = "all"
    @State private var expandedSavedFoods = false
    @State private var expandedSavedMeals = false
    @State private var expandedSavedRecipes = false
    @State private var expandedRecentIndividualFoods = false
    @State private var expandedDiaryMealCategories: Set<String> = []
    @State private var searchResults: [FoodItem] = []
    @State private var searchResultsVisibleLimit = 5
    @State private var selectedSearchFoodIds: Set<String> = []
    @State private var selectedFrequentFoodIds: Set<String> = []
    @State private var selectedSavedFoodIds: Set<String> = []
    @State private var selectedSavedMealIds: Set<String> = []
    @State private var selectedSavedRecipeIds: Set<String> = []
    @State private var searchingFoods = false
    @State private var loadingSavedLibrary = false
    @State private var loadingMoreSavedLibrary = false
    @State private var loadingFrequentFoods = false
    @State private var hasMoreSavedFoods = true
    @State private var hasMoreSavedMeals = true
    @State private var hasMoreSavedRecipes = true
    @State private var loading = false
    @State private var initialLoading = true
    @State private var message = ""
    @State private var diaryNoteText = ""
    @State private var savedDiaryNoteText = ""
    @State private var savingDiaryNote = false
    @State private var completingDiary = false
    @State private var savingMealGoalShares = false
    @State private var savingMealNames = false
    @State private var savingImportedRecipePlanPreference = false
    @State private var loggingMealId = ""
    @State private var loggingFoodId = ""
    @State private var loggingSelectedSearchFoods = false
    @State private var loggingSelectedFrequentFoods = false
    @State private var savingSelectedSearchFoodsAsTemplates = false
    @State private var loggingRecentGroupId = ""
    @State private var loggingPlanDayId = ""
    @State private var loggingRecipeSuggestionId = ""
    @State private var deletingRecipeSuggestionId = ""
    @State private var savingRecipeAsMealId = ""
    @State private var duplicatingRecipeSuggestionId = ""
    @State private var favoritingRecipeSuggestionId = ""
    @State private var deletingFoodLogId = 0
    @State private var adjustingFoodLogId = 0
    @State private var movingFoodLogId = 0
    @State private var copyingMealCategory = ""
    @State private var clearingMealCategory = ""
    @State private var replacingMealCategory = ""
    @State private var pendingClearMealCategoryKey = ""
    @State private var pendingClearMealCategoryTitle = ""
    @State private var showingClearMealConfirmation = false
    @State private var savingMealCategory = ""
    @State private var savingMealCategoryAsRecipe = ""
    @State private var deletingRecentGroupId = ""
    @State private var savingRecentMealId = ""
    @State private var loggingSavedMealId = ""
    @State private var deletingSavedMealId = ""
    @State private var duplicatingSavedMealId = ""
    @State private var favoritingSavedMealId = ""
    @State private var savingFoodTemplateId = ""
    @State private var loggingSavedFoodId = ""
    @State private var loggingSelectedSavedFoods = false
    @State private var deletingSelectedSavedFoods = false
    @State private var loggingSelectedSavedMeals = false
    @State private var loggingSelectedSavedRecipes = false
    @State private var deletingSelectedSavedMeals = false
    @State private var deletingSelectedSavedRecipes = false
    @State private var savingSelectedRecipesAsMeals = false
    @State private var deletingSavedFoodId = ""
    @State private var pendingDeleteSavedFoodId = ""
    @State private var pendingDeleteSavedFoodName = ""
    @State private var showingDeleteSavedFoodConfirmation = false
    @State private var showingDeleteSelectedSavedFoodsConfirmation = false
    @State private var pendingDeleteSavedMealId = ""
    @State private var pendingDeleteSavedMealTitle = ""
    @State private var showingDeleteSavedMealConfirmation = false
    @State private var showingDeleteSelectedSavedMealsConfirmation = false
    @State private var pendingDeleteSavedRecipeId = ""
    @State private var pendingDeleteSavedRecipeTitle = ""
    @State private var showingDeleteSavedRecipeConfirmation = false
    @State private var showingDeleteSelectedSavedRecipesConfirmation = false
    @State private var deletingMealPlanId = ""
    @State private var swappingMealId = ""
    @State private var selectedMealCategory = "breakfast"
    @State private var selectedInfoMode = "diary"
    @AppStorage("CalAI.InfoPage.alwaysUseMultiAdd") private var alwaysUseMultiAdd = true
    @State private var showAllMealTools = false
    @State private var showingQuickAdd = false
    @State private var showingSavedLibraryAddItems = false
    @State private var showingBarcodeLookup = false
    @State private var showingCreateSavedMeal = false
    @State private var showingSavedLibrarySortFilter = false
    @State private var showingSaveSelectedFoodsAsMeal = false
    @State private var showingSaveSelectedSearchFoodsAsMeal = false
    @State private var showingSaveSelectedFrequentFoodsAsMeal = false
    @State private var showingSaveSelectedFoodsAsRecipe = false
    @State private var showingSaveSelectedSearchFoodsAsRecipe = false
    @State private var showingSaveSelectedFrequentFoodsAsRecipe = false
    @State private var showingSaveSelectedMealsAsRecipe = false
    @State private var showingNutritionLabelEntry = false
    @State private var showingManualRecipeBuilder = false
    @State private var showingIngredientRecipeBuilder = false
    @State private var ingredientRecipeInitialInputMode = "manual"
    @State private var selectedDatabaseFoodDetail: FoodItem?
    @State private var selectedRecipeDetail: IngredientRecipeHistoryItem?
    @State private var selectedSavedMealDetail: SavedMealItem?
    @State private var selectedSavedFoodDetail: SavedFoodItem?
    @State private var selectedSavedFoodPortionTarget: SavedFoodItem?
    @State private var selectedSavedMealPortionTarget: SavedMealItem?
    @State private var selectedSavedRecipePortionTarget: IngredientRecipeHistoryItem?
    @State private var selectedDiaryFoodPortionEdit: DiaryFoodPortionEditTarget?
    @State private var selectedMealCategoryDetail: MealCategoryDetailTarget?
    @State private var selectedMealCategorySaveTarget: MealCategorySaveTarget?
    @State private var selectedMealCopyTarget: MealCategoryCopyTarget?
    @State private var selectedRecentMealCopyTarget: MealHistoryGroup?
    @State private var copiedGroceryPlanId = ""
    @State private var updatingGroceryItemKey = ""
    @State private var expandedRecentGroupId = ""

    private let goalOptions = [
        ("fat_loss", "减脂"),
        ("muscle_gain", "增肌"),
        ("maintain", "维持"),
    ]

    private let mealCategoryBaseOptions = [
        ("breakfast", "早餐", "sunrise.fill"),
        ("lunch", "午餐", "sun.max.fill"),
        ("dinner", "晚餐", "moon.stars.fill"),
        ("snack", "加餐", "leaf.fill"),
    ]

    private var mealCategoryOptions: [(String, String, String)] {
        mealCategoryBaseOptions.map { key, fallback, icon in
            let custom = (mealNamesDraft[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (key, custom.isEmpty ? fallback : custom, icon)
        }
    }

    private let infoModeOptions = [
        ("diary", "今天", "list.bullet.rectangle"),
        ("plan", "餐品库", "book.pages.fill"),
    ]

    private let savedLibraryScopes = [
        ("all", "全部"),
        ("recent", "最近的"),
        ("frequent", "常用"),
        ("food", "我的食物"),
        ("meal", "我的餐品"),
        ("meal_favorite", "收藏餐品"),
        ("recipe", "我的食谱"),
        ("recipe_favorite", "收藏食谱"),
        ("recipe_imported", "导入食谱"),
    ]

    private let savedLibrarySortOptions = [
        ("created", "最近创建"),
        ("logged", "最近记录"),
        ("frequent", "最常用"),
        ("calories", "热量"),
        ("name", "名称"),
    ]

    private let savedRecipeTagOptions = [
        ("all", "全部目标", "sparkles"),
        ("high_protein", "高蛋白", "bolt.heart.fill"),
        ("low_calorie", "低卡", "flame.fill"),
        ("low_carb", "低碳", "leaf.fill"),
        ("low_sodium", "低钠", "drop.fill"),
        ("low_fat", "低脂", "circle.lefthalf.filled"),
        ("high_fiber", "高纤维", "heart.text.square.fill"),
    ]

    private let popularSearchTerms = [
        "米饭", "鸡蛋", "鸡胸肉", "牛奶", "香蕉", "燕麦", "豆腐", "酸奶"
    ]

    private let recentSearchTermsKey = "CalAI.InfoPage.recentFoodSearchTerms"
    private let maximumMultiAddItems = 10

    private let portionRatioOptions = [
        (0.5, "一半"),
        (0.75, "75%"),
        (1.0, "原份"),
        (1.25, "加量 25%"),
    ]

    init(
        logDate: String = "",
        onChanged: @escaping () -> Void = {},
        onScanFood: @escaping () -> Void = {},
        onVoiceLog: @escaping () -> Void = {}
    ) {
        self.logDate = logDate
        self.onChanged = onChanged
        self.onScanFood = onScanFood
        self.onVoiceLog = onVoiceLog
    }

    private var visiblePlan: MealPlanPayload? {
        plan ?? history.first
    }

    private var recentMealGroups: [MealHistoryGroup] {
        Array(MealHistoryGroup.makeGroups(from: recentFoods).prefix(4))
    }

    private var recentIndividualFoods: [FoodLogRow] {
        var seen: Set<String> = []
        var rows: [FoodLogRow] = []
        for row in recentFoods {
            let name = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = "\(name.lowercased())|\(row.displayServingSize.lowercased())"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            rows.append(row)
            if rows.count >= 20 { break }
        }
        return rows
    }

    private var filteredRecentIndividualFoods: [FoodLogRow] {
        guard selectedInfoMode == "plan", !normalizedSavedLibraryQuery.isEmpty else {
            return recentIndividualFoods
        }
        return recentIndividualFoods.filter { row in
            row.displayName.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || row.displayServingSize.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || (row.uploadGroupTitle ?? "").localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
        }
    }

    private var visibleRecentIndividualFoods: [FoodLogRow] {
        if expandedRecentIndividualFoods || !normalizedSavedLibraryQuery.isEmpty {
            return filteredRecentIndividualFoods
        }
        return Array(filteredRecentIndividualFoods.prefix(6))
    }

    private var visibleFrequentFoods: [FrequentFood] {
        guard selectedInfoMode == "plan", !normalizedSavedLibraryQuery.isEmpty else {
            return frequentFoods
        }
        return frequentFoods.filter { food in
            food.name.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || food.servingSize.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
        }
    }

    private var normalizedSavedLibraryQuery: String {
        savedLibraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canLoadMoreSavedLibrary: Bool {
        switch savedLibraryScope {
        case "recent", "frequent":
            return false
        case "food":
            return hasMoreSavedFoods
        case "meal", "meal_favorite":
            return hasMoreSavedMeals
        case "recipe", "recipe_favorite", "recipe_imported":
            return hasMoreSavedRecipes
        default:
            return hasMoreSavedFoods || hasMoreSavedMeals || hasMoreSavedRecipes
        }
    }

    private var savedLibraryTitle: String {
        switch savedLibraryScope {
        case "recent":
            return "最近的"
        case "frequent":
            return "常用"
        case "meal":
            return "我的餐品"
        case "meal_favorite":
            return "收藏餐品"
        case "recipe":
            return "我的食谱"
        case "recipe_favorite":
            return "收藏食谱"
        case "recipe_imported":
            return "导入食谱"
        case "food":
            return "我的食物"
        default:
            return "全部食物入口"
        }
    }

    private var savedLibrarySubtitle: String {
        switch savedLibraryScope {
        case "recent":
            return "最近的：复用最近记录过的单项食物。"
        case "frequent":
            return "常用：按记录次数排序，适合每天重复记录。"
        case "meal":
            return "我的餐品：保存常吃整餐，下次一键记录。"
        case "meal_favorite":
            return "收藏餐品：快速找到已星标的常用整餐。"
        case "recipe":
            return "我的食谱：保存配料、做法和每份营养。"
        case "recipe_favorite":
            return "收藏食谱：快速找到已星标的常用食谱。"
        case "recipe_imported":
            return "导入食谱：从网页链接导入后保留来源和做法。"
        case "food":
            return "我的食物：保存自定义单个食物。"
        default:
            return "包含最近的、常用、我的食物、餐品和食谱。"
        }
    }

    private var mealsHubSubtitle: String {
        if dailyFoods.isEmpty {
            return "先拍或补记一餐，马上知道今天还剩多少。"
        }
        if remainingCalories <= max(calorieGoal * 0.12, 120) {
            return "今天已记录 \(dailyFoods.count) 项，剩余不多，下一餐清淡一点。"
        }
        return "今天已记录 \(dailyFoods.count) 项，还剩 \(Int(round(remainingCalories))) 千卡。"
    }

    private var savedLibrarySearchPlaceholder: String {
        switch savedLibraryScope {
        case "recent":
            return "搜索最近食物"
        case "frequent":
            return "搜索常用食物"
        case "meal":
            return "搜索我的餐品"
        case "meal_favorite":
            return "搜索收藏餐品"
        case "recipe":
            return "搜索我的食谱"
        case "recipe_favorite":
            return "搜索收藏食谱"
        case "recipe_imported":
            return "搜索导入食谱"
        case "food":
            return "搜索我的食物"
        default:
            return "搜索最近、常用、食物、餐品或食谱"
        }
    }

    private var savedLibraryFilteredCount: Int {
        switch savedLibraryScope {
        case "recent":
            return visibleRecentIndividualFoods.count
        case "frequent":
            return visibleFrequentFoods.count
        case "meal", "meal_favorite":
            return filteredSavedMeals.count
        case "recipe", "recipe_favorite", "recipe_imported":
            return filteredRecipeSuggestions.count
        case "food":
            return filteredSavedFoods.count
        default:
            return visibleRecentIndividualFoods.count
                + visibleFrequentFoods.count
                + filteredSavedMeals.count
                + filteredRecipeSuggestions.count
                + filteredSavedFoods.count
        }
    }

    private var savedLibraryFilterSummary: String {
        let scope = savedLibraryScopes.first { $0.0 == savedLibraryScope }?.1 ?? "全部"
        if let fixedOrder = savedLibraryFixedOrderLabel {
            return "\(scope) · \(fixedOrder) · \(savedLibraryFilteredCount) 项"
        }
        let sort = savedLibrarySortOptions.first { $0.0 == savedLibrarySort }?.1 ?? "最近创建"
        let mealFilter = savedLibraryMealCategoryFilter == "all"
            ? ""
            : " · \(mealCategoryTitle(savedLibraryMealCategoryFilter))"
        if savedLibraryScope == "all" {
            return "最近/常用固定 · 保存库\(mealFilter)按\(sort) · \(savedLibraryFilteredCount) 项"
        }
        return "\(scope)\(mealFilter) · \(sort) · \(savedLibraryFilteredCount) 项"
    }

    private var savedLibraryUsesSavedSort: Bool {
        savedLibraryScope != "recent" && savedLibraryScope != "frequent"
    }

    private var savedLibraryFixedOrderLabel: String? {
        switch savedLibraryScope {
        case "recent":
            return "按最近记录"
        case "frequent":
            return "按记录次数"
        default:
            return nil
        }
    }

    private var savedLibraryHelpText: String {
        switch savedLibraryScope {
        case "recent":
            return "向右滑动就能直接加入；也可以从最近记录里复制常吃食物。"
        case "frequent":
            return "常用食物按记录次数展示，向右滑动可直接加入当前餐次。"
        case "food":
            return "想记自定义食物？我的食物会显示以前创建的所有自定义食物。"
        case "meal":
            return "尚未保存最喜欢的餐食？我的餐品可以方便地检索以前保存的整餐。"
        case "meal_favorite":
            return "把常吃餐品点星标收藏，之后能像收藏夹一样快速记录。"
        case "recipe":
            return "经常做饭的话，可创建食谱计算配料营养；保存后可直接加入日记。"
        case "recipe_favorite":
            return "把常做食谱点星标收藏，之后能像收藏夹一样快速记录。"
        case "recipe_imported":
            return "从网页链接导入的食谱会保留来源、做法和时间，适合复做。"
        default:
            return "向右滑动就能直接加入，也可以在最近、常用、我的食物、餐品和食谱之间切换。"
        }
    }

    private var hasActiveSavedLibraryFilters: Bool {
        savedLibraryScope != "all"
            || !normalizedSavedLibraryQuery.isEmpty
            || savedLibraryMealCategoryFilter != "all"
            || savedRecipeTagFilter != "all"
            || (savedLibraryUsesSavedSort && savedLibrarySort != "created")
    }

    private func savedLibraryScopeCount(_ scope: String) -> Int {
        switch scope {
        case "recent":
            return recentIndividualFoods.count
        case "frequent":
            return frequentFoods.count
        case "meal":
            return savedMeals.count
        case "meal_favorite":
            return savedMeals.filter { $0.favorite == true }.count
        case "recipe":
            return recipeSuggestions.count
        case "recipe_favorite":
            return recipeSuggestions.filter { $0.recipe.favorite == true }.count
        case "recipe_imported":
            return recipeSuggestions.filter { isImportedRecipe($0) }.count
        case "food":
            return savedFoods.count
        default:
            return recentIndividualFoods.count + frequentFoods.count + savedMeals.count + recipeSuggestions.count + savedFoods.count
        }
    }

    private func isImportedRecipe(_ item: IngredientRecipeHistoryItem) -> Bool {
        let source = (item.recipe.source.isEmpty ? (item.source ?? "") : item.recipe.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sourceURL = (item.recipe.sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return source == "recipe_url_import" || !sourceURL.isEmpty
    }

    private var selectedSearchFoods: [FoodItem] {
        searchResults.filter { selectedSearchFoodIds.contains($0.id) }
    }

    private var selectedFrequentFoods: [FrequentFood] {
        frequentFoods.filter { selectedFrequentFoodIds.contains($0.id) }
    }

    private var selectedSavedFoods: [SavedFoodItem] {
        savedFoods.filter { selectedSavedFoodIds.contains($0.id) }
    }

    private var selectedSavedMeals: [SavedMealItem] {
        savedMeals.filter { selectedSavedMealIds.contains($0.id) }
    }

    private var selectedSavedRecipes: [IngredientRecipeHistoryItem] {
        recipeSuggestions.filter { selectedSavedRecipeIds.contains($0.id) }
    }

    private var savedLibraryMultiAddCount: Int {
        switch savedLibraryScope {
        case "frequent":
            return selectedFrequentFoodIds.count
        case "food":
            return selectedSavedFoodIds.count
        case "meal", "meal_favorite":
            return selectedSavedMealIds.count
        case "recipe", "recipe_favorite", "recipe_imported":
            return selectedSavedRecipeIds.count
        case "recent":
            return 0
        default:
            return selectedFrequentFoodIds.count
                + selectedSavedFoodIds.count
                + selectedSavedMealIds.count
                + selectedSavedRecipeIds.count
        }
    }

    private var totalMultiAddCount: Int {
        selectedSearchFoodIds.count
            + selectedFrequentFoodIds.count
            + selectedSavedFoodIds.count
            + selectedSavedMealIds.count
            + selectedSavedRecipeIds.count
    }

    private var savedLibraryMultiAddSubtitle: String {
        if !alwaysUseMultiAdd {
            return "多选已关闭，列表会优先显示直接加入和右滑记录。"
        }
        if savedLibraryMultiAddCount > 0 {
            return "已选 \(savedLibraryMultiAddCount)/\(maximumMultiAddItems) 项，点“加入选中”一次写入\(mealCategoryTitle(selectedMealCategory))。"
        }
        switch savedLibraryScope {
        case "recent":
            return "最近食物支持右滑记录；要多选可切到常用、我的食物、餐品或食谱。"
        case "meal", "meal_favorite":
            return "勾选多个餐品后，可一次加入当前餐次，或保存为新的食谱。"
        case "recipe", "recipe_favorite", "recipe_imported":
            return "勾选多个食谱后，可一次加入当前餐次，或保存为餐品。"
        default:
            return "多选模式：勾选多个项目后，可一次加入当前餐次；常吃组合还能保存成餐品或食谱。"
        }
    }

    private var savedMealCategoryFilterForRequest: String {
        savedLibraryMealCategoryFilter == "all" ? "" : savedLibraryMealCategoryFilter
    }

    private var savedRecipeMealTypeFilterForRequest: String {
        savedLibraryMealCategoryFilter == "all" ? "" : savedLibraryMealCategoryFilter
    }

    private var savedRecipeTagFilterForRequest: String {
        savedRecipeTagFilter == "all" ? "" : savedRecipeTagFilter
    }

    private var savedLibrarySupportsMealTypeFilter: Bool {
        savedLibraryScope == "all"
            || savedLibraryScope == "meal"
            || savedLibraryScope == "meal_favorite"
            || savedLibraryScope == "recipe"
            || savedLibraryScope == "recipe_favorite"
            || savedLibraryScope == "recipe_imported"
    }

    private var savedLibrarySupportsRecipeTagFilter: Bool {
        savedLibraryScope == "all"
            || savedLibraryScope == "recipe"
            || savedLibraryScope == "recipe_favorite"
            || savedLibraryScope == "recipe_imported"
    }

    private func normalizedRecipeTag(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compactScalars = text.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        let compact = String(String.UnicodeScalarView(Array(compactScalars)))
        let aliases: [String: String] = [
            "highprotein": "high_protein",
            "高蛋白": "high_protein",
            "蛋白高": "high_protein",
            "lowcarb": "low_carb",
            "低碳": "low_carb",
            "低碳水": "low_carb",
            "lowcalorie": "low_calorie",
            "低卡": "low_calorie",
            "低热量": "low_calorie",
            "lowsodium": "low_sodium",
            "低钠": "low_sodium",
            "低盐": "low_sodium",
            "lowfat": "low_fat",
            "低脂": "low_fat",
            "少油": "low_fat",
            "highfiber": "high_fiber",
            "高纤维": "high_fiber",
        ]
        return aliases[compact] ?? compact
    }

    private func recipeMatchesSavedTag(_ item: IngredientRecipeHistoryItem) -> Bool {
        let target = normalizedRecipeTag(savedRecipeTagFilterForRequest)
        guard !target.isEmpty else { return true }
        return (item.recipe.tags ?? []).contains { normalizedRecipeTag($0) == target }
    }

    private func savedFrequentMealFilterForRequest() -> String {
        frequentFoodsMealFilter == "all" ? "" : frequentFoodsMealFilter
    }

    private var filteredSavedFoods: [SavedFoodItem] {
        let items: [SavedFoodItem]
        if normalizedSavedLibraryQuery.isEmpty {
            items = savedFoods
        } else {
            items = savedFoods.filter { item in
            item.name.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
            || item.food.name.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
            || item.food.servingSize.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
            }
        }
        return sortSavedFoods(items)
    }

    private var filteredSavedMeals: [SavedMealItem] {
        let items: [SavedMealItem]
        if normalizedSavedLibraryQuery.isEmpty {
            items = savedMeals
        } else {
            items = savedMeals.filter { meal in
                let noteText = meal.note ?? ""
                let instructionsText = (meal.instructions ?? []).joined(separator: " ")
                return meal.title.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || meal.names.joined(separator: " ").localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || (meal.mealCategory ?? "").localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || noteText.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || instructionsText.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
            }
        }
        let scopedItems: [SavedMealItem]
        if savedLibraryScope == "meal_favorite" {
            scopedItems = items.filter { $0.favorite == true }
        } else {
            scopedItems = items
        }
        let mealFilteredItems: [SavedMealItem]
        if savedLibraryMealCategoryFilter == "all" {
            mealFilteredItems = scopedItems
        } else {
            mealFilteredItems = scopedItems.filter { ($0.mealCategory ?? "") == savedLibraryMealCategoryFilter }
        }
        return sortSavedMeals(mealFilteredItems)
    }

    private var filteredRecipeSuggestions: [IngredientRecipeHistoryItem] {
        let items: [IngredientRecipeHistoryItem]
        if normalizedSavedLibraryQuery.isEmpty {
            items = recipeSuggestions
        } else {
            items = recipeSuggestions.filter { item in
                let recipe = item.recipe
                let searchableRecipeDetails = [
                    recipe.reason,
                    recipe.instructions.joined(separator: " "),
                    recipe.missingIngredients?.joined(separator: " ") ?? "",
                    recipe.sourceURL ?? "",
                    recipe.cookingTime ?? "",
                ].joined(separator: " ")
                return item.recipe.title.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || item.recipe.ingredientsBreakdown.map(\.name).joined(separator: " ").localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
                || searchableRecipeDetails.localizedCaseInsensitiveContains(normalizedSavedLibraryQuery)
            }
        }
        let scopedItems: [IngredientRecipeHistoryItem]
        if savedLibraryScope == "recipe_favorite" {
            scopedItems = items.filter { $0.recipe.favorite == true }
        } else if savedLibraryScope == "recipe_imported" {
            scopedItems = items.filter { isImportedRecipe($0) }
        } else {
            scopedItems = items
        }
        let mealFilteredItems: [IngredientRecipeHistoryItem]
        if savedRecipeMealTypeFilterForRequest.isEmpty {
            mealFilteredItems = scopedItems
        } else {
            mealFilteredItems = scopedItems.filter { item in
                RecipeMealType.inferredList(mealTypes: item.recipe.mealTypes, tags: item.recipe.tags).contains(savedRecipeMealTypeFilterForRequest)
            }
        }
        let tagFilteredItems = mealFilteredItems.filter { recipeMatchesSavedTag($0) }
        return sortRecipeSuggestions(tagFilteredItems)
    }

    private func sortSavedFoods(_ items: [SavedFoodItem]) -> [SavedFoodItem] {
        switch savedLibrarySort {
        case "logged":
            return items.sorted { ($0.loggedAt ?? "") > ($1.loggedAt ?? "") }
        case "frequent":
            return items.sorted {
                (($0.loggedCount ?? 0), $0.loggedAt ?? "", $0.createdAt ?? "") > (($1.loggedCount ?? 0), $1.loggedAt ?? "", $1.createdAt ?? "")
            }
        case "calories":
            return items.sorted { $0.food.calories > $1.food.calories }
        case "name":
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        default:
            return items.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        }
    }

    private func sortSavedMeals(_ items: [SavedMealItem]) -> [SavedMealItem] {
        switch savedLibrarySort {
        case "logged":
            return items.sorted { ($0.loggedAt ?? "") > ($1.loggedAt ?? "") }
        case "frequent":
            return items.sorted { lhs, rhs in
                let lhsFavorite = lhs.favorite == true
                let rhsFavorite = rhs.favorite == true
                if lhsFavorite != rhsFavorite { return lhsFavorite }
                let lhsCount = lhs.loggedCount ?? 0
                let rhsCount = rhs.loggedCount ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                let lhsLoggedAt = lhs.loggedAt ?? ""
                let rhsLoggedAt = rhs.loggedAt ?? ""
                if lhsLoggedAt != rhsLoggedAt { return lhsLoggedAt > rhsLoggedAt }
                return (lhs.createdAt ?? "") > (rhs.createdAt ?? "")
            }
        case "calories":
            return items.sorted { $0.calories > $1.calories }
        case "name":
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        default:
            return items.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        }
    }

    private func sortRecipeSuggestions(_ items: [IngredientRecipeHistoryItem]) -> [IngredientRecipeHistoryItem] {
        switch savedLibrarySort {
        case "logged":
            return items.sorted { ($0.loggedAt ?? "") > ($1.loggedAt ?? "") }
        case "frequent":
            return items.sorted {
                (($0.loggedCount ?? 0), $0.loggedAt ?? "", $0.createdAt ?? "") > (($1.loggedCount ?? 0), $1.loggedAt ?? "", $1.createdAt ?? "")
            }
        case "calories":
            return items.sorted { $0.recipe.calories > $1.recipe.calories }
        case "name":
            return items.sorted { $0.recipe.title.localizedCaseInsensitiveCompare($1.recipe.title) == .orderedAscending }
        default:
            return items.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        }
    }

    private var consumedCalories: Double {
        dailySummary?.caloriesConsumed ?? dailyFoods.reduce(0) { $0 + ($1.calories ?? 0) }
    }

    private var calorieGoal: Double {
        dailySummary?.caloriesGoal ?? Double(safeInt(dailyCalories, 2000))
    }

    private var remainingCalories: Double {
        max(0, calorieGoal - consumedCalories + (dailySummary?.caloriesBurned ?? 0))
    }

    private var loggedMealCategoryCount: Int {
        mealCategoryOptions.filter { !rowsForMealCategory($0.0).isEmpty }.count
    }

    private var missingMealCategoryTitles: [String] {
        mealCategoryOptions
            .filter { rowsForMealCategory($0.0).isEmpty }
            .map(\.1)
    }

    private var nextDiaryMealCategory: (key: String, title: String) {
        if let firstMissing = mealCategoryOptions.first(where: { rowsForMealCategory($0.0).isEmpty }) {
            return (firstMissing.0, firstMissing.1)
        }
        if let selected = mealCategoryOptions.first(where: { $0.0 == selectedMealCategory }) {
            return (selected.0, selected.1)
        }
        return ("snack", "加餐")
    }

    private var diaryReviewMessage: String {
        if dailyFoods.isEmpty {
            return "先拍或补记一餐，我会马上算出今天还剩多少热量。"
        }
        if loggedMealCategoryCount >= mealCategoryOptions.count {
            return "今天记录已经完整，重点检查份量有没有偏差。"
        }
        let missing = missingMealCategoryTitles.prefix(2).joined(separator: "、")
        return "最该补记：\(missing)。补上后，今天的判断会更准。"
    }

    private var frequentFoods: [FrequentFood] {
        let remoteFoods = frequentFoodItems.compactMap { FrequentFood(item: $0) }
        if !remoteFoods.isEmpty {
            return remoteFoods
        }
        let filteredRows = frequentFoodsMealFilter == "all"
            ? recentFoods
            : recentFoods.filter { normalizedMealCategory($0.mealCategory) == frequentFoodsMealFilter }
        let grouped = Dictionary(grouping: filteredRows) { row in
            row.displayName
        }
        let ranked = grouped.compactMap { name, rows -> FrequentFood? in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let sorted = rows.sorted { ($0.loggedAt ?? "") > ($1.loggedAt ?? "") }
            guard let latest = sorted.first else { return nil }
            return FrequentFood(
                id: "frequent-\(name)",
                name: name,
                count: rows.count,
                calories: latest.calories ?? 0,
                protein: latest.protein ?? 0,
                carbs: latest.carbs ?? 0,
                fat: latest.fat ?? 0,
                fiber: latest.fiber ?? 0,
                sugar: latest.sugar ?? 0,
                sodium: latest.sodium ?? 0,
                servingSize: latest.displayServingSize
            )
        }
        .sorted {
            if $0.count == $1.count {
                return $0.name < $1.name
            }
            return $0.count > $1.count
        }
        return Array(ranked.prefix(8))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    infoModePicker
                    if !message.isEmpty {
                        messageCard
                    }
                    if selectedInfoMode == "diary" {
                        mealsHubCard
                        diaryBudgetCard
                        diaryMealLogCard
                        mealToolsCard
                        savedLibraryToolsCard
                        librarySmartPromptCard
                        frequentFoodsCard
                        recentIndividualFoodsCard
                        foodDatabaseCard
                        if savedLibraryScope == "all" || savedLibraryScope == "meal" || savedLibraryScope == "meal_favorite" {
                            savedMealsCard
                        }
                        if savedLibraryScope == "all" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" {
                            savedRecipesCard
                        }
                        if savedLibraryScope == "all" || savedLibraryScope == "food" {
                            savedFoodsCard
                        }
                        ingredientRecipeEntryCard
                        recentMealsCard
                        diaryCompletionCard
                        diaryNoteCard
                        mealGoalsByMealCard
                        mealCategoryNamesCard
                    } else {
                        recipeLibraryWorkbenchCard
                        if savedLibraryScope == "all" || savedLibraryScope == "food" || savedLibraryScope == "frequent" {
                            frequentFoodsCard
                        }
                        if savedLibraryScope == "all" || savedLibraryScope == "food" || savedLibraryScope == "recent" {
                            recentIndividualFoodsCard
                        }
                        planScopeEmptyStateCard
                        if savedLibraryScope == "all" || savedLibraryScope == "food" {
                            foodDatabaseCard
                        }
                        if savedLibraryScope == "all" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" {
                            ingredientRecipeEntryCard
                        }
                        if savedLibraryScope == "all" || savedLibraryScope == "meal" || savedLibraryScope == "meal_favorite" {
                            savedMealsCard
                        }
                        if savedLibraryScope == "all" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" {
                            savedRecipesCard
                        }
                        if savedLibraryScope == "all" || savedLibraryScope == "food" {
                            savedFoodsCard
                        }
                        if canLoadMoreSavedLibrary || loadingMoreSavedLibrary {
                            savedLibraryLoadMoreButton
                        }
                        plannerCard
                        if initialLoading {
                            loadingHistoryCard
                        }
                        historyScroller
                        if let visiblePlan {
                            planSummary(visiblePlan)
                            planDays(visiblePlan)
                            groceryCard(visiblePlan)
                        } else if !initialLoading {
                            emptyPlanCard
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 118)
            }
            .refreshable {
                await refreshVisibleInfoPage()
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await loadInitialData() }
        .onAppear {
            loadRecentSearchTerms()
        }
        .onChange(of: savedLibraryScope) { _, _ in
            if !savedLibrarySupportsMealTypeFilter {
                savedLibraryMealCategoryFilter = "all"
            }
            if !savedLibrarySupportsRecipeTagFilter {
                savedRecipeTagFilter = "all"
            }
            clearMultiAddSelections()
            resetSavedLibraryExpansion()
        }
        .onChange(of: savedLibraryMealCategoryFilter) { _, _ in
            clearMultiAddSelections()
            resetSavedLibraryExpansion()
        }
        .onChange(of: savedRecipeTagFilter) { _, _ in
            clearMultiAddSelections()
            resetSavedLibraryExpansion()
        }
        .onChange(of: savedLibrarySort) { _, _ in
            clearMultiAddSelections()
            resetSavedLibraryExpansion()
        }
        .sheet(isPresented: $showingQuickAdd) {
            ManualLogSheetView(
                logDate: activeLogDate,
                initialMealCategory: selectedMealCategory,
                onClose: { showingQuickAdd = false },
                onLogged: {
                    showingQuickAdd = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSavedLibraryAddItems) {
            SavedLibraryAddItemsSheetView(
                mealTitle: mealCategoryTitle(selectedMealCategory),
                onClose: { showingSavedLibraryAddItems = false },
                onScanFood: {
                    showingSavedLibraryAddItems = false
                    onScanFood()
                },
                onSearchFood: {
                    showingSavedLibraryAddItems = false
                    selectedInfoMode = "plan"
                    savedLibraryScope = "all"
                    savedLibraryQuery = ""
                    resetSavedLibraryExpansion()
                    message = "在上方搜索食品、品牌、口味，也可以从最近、常用和保存库复用。"
                    Task { await refreshSavedLibraryFromServer() }
                },
                onQuickAdd: {
                    showingSavedLibraryAddItems = false
                    showingQuickAdd = true
                    message = ""
                },
                onBarcode: {
                    showingSavedLibraryAddItems = false
                    showingBarcodeLookup = true
                    message = ""
                },
                onCreateFood: {
                    showingSavedLibraryAddItems = false
                    showingNutritionLabelEntry = true
                    message = ""
                },
                onCreateMeal: {
                    showingSavedLibraryAddItems = false
                    showingCreateSavedMeal = true
                    message = ""
                },
                onCreateRecipe: {
                    showingSavedLibraryAddItems = false
                    showingManualRecipeBuilder = true
                    message = ""
                },
                onVoiceLog: {
                    showingSavedLibraryAddItems = false
                    onVoiceLog()
                }
            )
        }
        .sheet(isPresented: $showingBarcodeLookup) {
            BarcodeLookupSheetView(
                onClose: { showingBarcodeLookup = false },
                onFoodFound: { food in
                    showingBarcodeLookup = false
                    selectedDatabaseFoodDetail = food
                }
            )
        }
        .sheet(isPresented: $showingSavedLibrarySortFilter) {
            SavedLibrarySortFilterSheetView(
                scope: $savedLibraryScope,
                mealCategoryFilter: $savedLibraryMealCategoryFilter,
                sort: $savedLibrarySort,
                scopes: savedLibraryScopes,
                mealCategoryOptions: mealCategoryOptions,
                sortOptions: savedLibrarySortOptions,
                resultSummary: savedLibraryFilterSummary,
                onReset: {
                    clearSavedLibraryFilters()
                    resetSavedLibraryExpansion()
                    Task { await refreshSavedLibraryFromServer() }
                },
                onClose: {
                    showingSavedLibrarySortFilter = false
                    resetSavedLibraryExpansion()
                    Task { await refreshSavedLibraryFromServer() }
                }
            )
        }
        .sheet(isPresented: $showingNutritionLabelEntry) {
            NutritionLabelFoodSheetView(
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                onClose: { showingNutritionLabelEntry = false },
                onSaved: { saved in
                    savedFoods.removeAll { $0.id == saved.id || $0.food.name == saved.food.name }
                    savedFoods.insert(saved, at: 0)
                    syncSavedLibraryAfterMutation()
                    message = "已保存标签食物：\(saved.name)。"
                },
                onLogged: {
                    showingNutritionLabelEntry = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingCreateSavedMeal) {
            CreateSavedMealSheetView(
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                savedMeals: savedMeals,
                onClose: { showingCreateSavedMeal = false },
                onSaved: { meal, replaced in
                    upsertSavedMeal(meal)
                    savedLibraryScope = "meal"
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名餐品：\(meal.title)。" : "已新建餐品：\(meal.title)。"
                },
                onLogged: {
                    showingCreateSavedMeal = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSaveSelectedFoodsAsMeal) {
            SelectedSavedFoodsMealSaveSheetView(
                foods: selectedSavedFoods.map(\.food),
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                savedMeals: savedMeals,
                onClose: { showingSaveSelectedFoodsAsMeal = false },
                onSaved: { meal, replaced in
                    upsertSavedMeal(meal)
                    selectedSavedFoodIds.removeAll()
                    savedLibraryScope = "meal"
                    savedLibraryMealCategoryFilter = meal.mealCategory ?? "all"
                    showAllMealCategoriesInSavedLibrary = savedLibraryMealCategoryFilter == "all"
                    showingSaveSelectedFoodsAsMeal = false
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名餐品：\(meal.title)。" : "已保存为餐品：\(meal.title)。"
                },
                onLogged: {
                    showingSaveSelectedFoodsAsMeal = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSaveSelectedSearchFoodsAsMeal) {
            SelectedSavedFoodsMealSaveSheetView(
                foods: selectedSearchFoods,
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                savedMeals: savedMeals,
                onClose: { showingSaveSelectedSearchFoodsAsMeal = false },
                onSaved: { meal, replaced in
                    upsertSavedMeal(meal)
                    selectedSearchFoodIds.removeAll()
                    savedLibraryScope = "meal"
                    savedLibraryMealCategoryFilter = meal.mealCategory ?? "all"
                    showAllMealCategoriesInSavedLibrary = savedLibraryMealCategoryFilter == "all"
                    showingSaveSelectedSearchFoodsAsMeal = false
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名餐品：\(meal.title)。" : "已保存为餐品：\(meal.title)。"
                },
                onLogged: {
                    showingSaveSelectedSearchFoodsAsMeal = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSaveSelectedSearchFoodsAsRecipe) {
            SelectedFoodsRecipeSaveSheetView(
                foods: selectedSearchFoods,
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                savedRecipes: recipeSuggestions,
                onClose: { showingSaveSelectedSearchFoodsAsRecipe = false },
                onSaved: { item, replaced in
                    upsertRecipeSuggestion(item)
                    selectedSearchFoodIds.removeAll()
                    savedLibraryScope = "recipe"
                    showingSaveSelectedSearchFoodsAsRecipe = false
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名食谱：\(item.recipe.title)。" : "已保存为食谱：\(item.recipe.title)。"
                },
                onLogged: {
                    showingSaveSelectedSearchFoodsAsRecipe = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSaveSelectedFrequentFoodsAsMeal) {
            SelectedSavedFoodsMealSaveSheetView(
                foods: selectedFrequentFoods.map(\.foodItem),
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                savedMeals: savedMeals,
                onClose: { showingSaveSelectedFrequentFoodsAsMeal = false },
                onSaved: { meal, replaced in
                    upsertSavedMeal(meal)
                    selectedFrequentFoodIds.removeAll()
                    savedLibraryScope = "meal"
                    savedLibraryMealCategoryFilter = meal.mealCategory ?? "all"
                    showAllMealCategoriesInSavedLibrary = savedLibraryMealCategoryFilter == "all"
                    showingSaveSelectedFrequentFoodsAsMeal = false
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名餐品：\(meal.title)。" : "已保存为餐品：\(meal.title)。"
                },
                onLogged: {
                    showingSaveSelectedFrequentFoodsAsMeal = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSaveSelectedFrequentFoodsAsRecipe) {
            SelectedFoodsRecipeSaveSheetView(
                foods: selectedFrequentFoods.map(\.foodItem),
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                savedRecipes: recipeSuggestions,
                onClose: { showingSaveSelectedFrequentFoodsAsRecipe = false },
                onSaved: { item, replaced in
                    upsertRecipeSuggestion(item)
                    selectedFrequentFoodIds.removeAll()
                    savedLibraryScope = "recipe"
                    showingSaveSelectedFrequentFoodsAsRecipe = false
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名食谱：\(item.recipe.title)。" : "已保存为食谱：\(item.recipe.title)。"
                },
                onLogged: {
                    showingSaveSelectedFrequentFoodsAsRecipe = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSaveSelectedFoodsAsRecipe) {
            SelectedFoodsRecipeSaveSheetView(
                foods: selectedSavedFoods.map(\.food),
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                savedRecipes: recipeSuggestions,
                onClose: { showingSaveSelectedFoodsAsRecipe = false },
                onSaved: { item, replaced in
                    upsertRecipeSuggestion(item)
                    selectedSavedFoodIds.removeAll()
                    savedLibraryScope = "recipe"
                    showingSaveSelectedFoodsAsRecipe = false
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名食谱：\(item.recipe.title)。" : "已保存为食谱：\(item.recipe.title)。"
                },
                onLogged: {
                    showingSaveSelectedFoodsAsRecipe = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingSaveSelectedMealsAsRecipe) {
            SelectedFoodsRecipeSaveSheetView(
                foods: selectedSavedMeals.flatMap(\.foods),
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                savedRecipes: recipeSuggestions,
                onClose: { showingSaveSelectedMealsAsRecipe = false },
                onSaved: { item, replaced in
                    upsertRecipeSuggestion(item)
                    selectedSavedMealIds.removeAll()
                    savedLibraryScope = "recipe"
                    showingSaveSelectedMealsAsRecipe = false
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名食谱：\(item.recipe.title)。" : "已保存为食谱：\(item.recipe.title)。"
                },
                onLogged: {
                    showingSaveSelectedMealsAsRecipe = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingManualRecipeBuilder) {
            CreateManualRecipeSheetView(
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                savedRecipes: recipeSuggestions,
                onClose: { showingManualRecipeBuilder = false },
                onSaved: { item, replaced in
                    upsertRecipeSuggestion(item)
                    savedLibraryScope = "recipe"
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名食谱：\(item.recipe.title)。" : "已新建食谱：\(item.recipe.title)。"
                },
                onLogged: {
                    showingManualRecipeBuilder = false
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(isPresented: $showingIngredientRecipeBuilder) {
            IngredientRecipeSheetView(
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                initialInputMode: ingredientRecipeInitialInputMode,
                savedRecipes: recipeSuggestions,
                savedMeals: savedMeals,
                onRecipesChanged: { recipes in
                    savedLibraryScope = "recipe"
                    if !recipes.isEmpty {
                        message = "已整理好 \(recipes.count) 个食谱，正在同步到餐品库。"
                    }
                    Task { await refreshSavedLibraryFromServer() }
                },
                onMealSaved: { meal, replaced in
                    upsertSavedMeal(meal)
                    savedLibraryScope = "meal"
                    syncSavedLibraryAfterMutation()
                    message = replaced ? "已替换同名餐品：\(meal.title)。" : "已保存为餐品：\(meal.title)。"
                }
            ) {
                showingIngredientRecipeBuilder = false
                Task { await refreshFoodStateAfterLogging() }
            }
        }
        .sheet(item: $selectedDatabaseFoodDetail) { food in
            DatabaseFoodDetailSheetView(
                food: food,
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                onClose: { selectedDatabaseFoodDetail = nil },
                onSaved: { saved in
                    savedFoods.removeAll { $0.id == saved.id || $0.food.name == saved.food.name }
                    savedFoods.insert(saved, at: 0)
                    syncSavedLibraryAfterMutation()
                    message = "已保存到我的食物：\(saved.name)。"
                },
                onLogged: {
                    selectedDatabaseFoodDetail = nil
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(item: $selectedRecipeDetail) { item in
            SavedRecipeDetailSheetView(
                item: item,
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                savedMeals: savedMeals,
                onClose: { selectedRecipeDetail = nil },
                onUpdated: { updated in
                    upsertRecipeSuggestion(updated)
                    syncSavedLibraryAfterMutation()
                    message = "已更新食谱：\(updated.recipe.title)。"
                },
                onMealCreated: { meal in
                    upsertSavedMeal(meal)
                    if savedLibraryScope == "food" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" {
                        savedLibraryScope = "meal"
                    }
                    syncSavedLibraryAfterMutation()
                    message = "已保存为我的餐品：\(meal.title)。"
                },
                onMealUpdated: { meal in
                    upsertSavedMeal(meal)
                    if savedLibraryScope == "food" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" {
                        savedLibraryScope = "meal"
                    }
                    syncSavedLibraryAfterMutation()
                    message = "已替换同名餐品：\(meal.title)。"
                },
                onRecipeCreated: { recipe in
                    upsertRecipeSuggestion(recipe)
                    savedLibraryScope = "recipe"
                    syncSavedLibraryAfterMutation()
                    message = "已另存为新食谱：\(recipe.recipe.title)。"
                },
                onDeleted: { recipe in
                    recipeSuggestions.removeAll { $0.id == recipe.id }
                    selectedRecipeDetail = nil
                    savedLibraryScope = "recipe"
                    syncSavedLibraryAfterMutation()
                    message = "已删除食谱：\(recipe.recipe.title)。"
                },
                onFoodSaved: { saved in
                    savedFoods.removeAll { $0.id == saved.id || $0.food.name == saved.food.name }
                    savedFoods.insert(saved, at: 0)
                    savedLibraryScope = "food"
                    syncSavedLibraryAfterMutation()
                    message = "已保存到我的食物：\(saved.name)。"
                },
                onLogged: {
                    selectedRecipeDetail = nil
                    selectedInfoMode = "diary"
                    message = "已记录食谱：\(item.recipe.title)。"
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(item: $selectedSavedMealDetail) { meal in
            SavedMealDetailSheetView(
                meal: meal,
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                onClose: { selectedSavedMealDetail = nil },
                onUpdated: { updated in
                    upsertSavedMeal(updated)
                    syncSavedLibraryAfterMutation()
                    message = "已更新餐品：\(updated.title)。"
                },
                onCreated: { created in
                    upsertSavedMeal(created)
                    if savedLibraryScope == "food" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" {
                        savedLibraryScope = "meal"
                    }
                    syncSavedLibraryAfterMutation()
                    message = "已另存为新餐品：\(created.title)。"
                },
                onFoodSaved: { saved in
                    savedFoods.removeAll { $0.id == saved.id || $0.food.name == saved.food.name }
                    savedFoods.insert(saved, at: 0)
                    savedLibraryScope = "food"
                    syncSavedLibraryAfterMutation()
                    message = "已保存到我的食物：\(saved.name)。"
                },
                onRecipeCreated: { recipe in
                    upsertRecipeSuggestion(recipe)
                    savedLibraryScope = "recipe"
                    syncSavedLibraryAfterMutation()
                    message = "已保存为食谱：\(recipe.recipe.title)。"
                },
                onDeleted: { meal in
                    savedMeals.removeAll { $0.id == meal.id }
                    selectedSavedMealDetail = nil
                    savedLibraryScope = "meal"
                    syncSavedLibraryAfterMutation()
                    message = "已删除餐品：\(meal.title)。"
                },
                onLogged: {
                    selectedSavedMealDetail = nil
                    selectedInfoMode = "diary"
                    message = "已记录餐品：\(meal.title)。"
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(item: $selectedSavedMealPortionTarget) { meal in
            SavedLibraryPortionLogSheetView(
                title: meal.title,
                subtitle: "\(meal.foods.count) 项 · \(Int(round(meal.calories))) 千卡/份",
                baseCalories: meal.calories,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                onClose: { selectedSavedMealPortionTarget = nil },
                onApply: { multiplier, mealCategory, dates, _ in
                    selectedSavedMealPortionTarget = nil
                    Task { await logSavedMealDates(meal, mealCategory: mealCategory, portionMultiplier: multiplier, dates: dates) }
                }
            )
        }
        .sheet(item: $selectedSavedRecipePortionTarget) { item in
            SavedLibraryPortionLogSheetView(
                title: item.recipe.title,
                subtitle: "每份 \(recipeServingSizeLabel(item.recipe)) · 共 \(item.recipe.servings) 份 · \(Int(round(item.recipe.calories))) 千卡/份",
                baseCalories: item.recipe.calories,
                servingSizeOptions: recipeServingSizeOptions(for: item.recipe),
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                onClose: { selectedSavedRecipePortionTarget = nil },
                onApply: { multiplier, mealCategory, dates, servingSizeLabel in
                    selectedSavedRecipePortionTarget = nil
                    Task { await logSavedRecipeDates(item, mealCategory: mealCategory, portionMultiplier: multiplier, servingSizeLabel: servingSizeLabel, dates: dates) }
                }
            )
        }
        .sheet(item: $selectedSavedFoodPortionTarget) { item in
            SavedLibraryPortionLogSheetView(
                title: item.name,
                subtitle: "\(item.food.servingSize) · \(Int(round(item.food.calories))) 千卡/份",
                baseCalories: item.food.calories,
                mealCategory: selectedMealCategory,
                mealCategoryOptions: mealCategoryOptions,
                onClose: { selectedSavedFoodPortionTarget = nil },
                onApply: { multiplier, mealCategory, dates, _ in
                    selectedSavedFoodPortionTarget = nil
                    Task { await logSavedFoodDates(item, mealCategory: mealCategory, portionMultiplier: multiplier, dates: dates) }
                }
            )
        }
        .sheet(item: $selectedSavedFoodDetail) { item in
            SavedFoodDetailSheetView(
                item: item,
                logDate: activeLogDate,
                mealCategory: selectedMealCategory,
                onClose: { selectedSavedFoodDetail = nil },
                onUpdated: { updated in
                    if let index = savedFoods.firstIndex(where: { $0.id == updated.id }) {
                        savedFoods[index] = updated
                    }
                    syncSavedLibraryAfterMutation()
                    message = "已更新食物：\(updated.name)。"
                },
                onCreated: { created in
                    savedFoods.removeAll { $0.id == created.id }
                    savedFoods.insert(created, at: 0)
                    syncSavedLibraryAfterMutation()
                    message = "已另存为新食物：\(created.name)。"
                },
                onLogged: {
                    selectedSavedFoodDetail = nil
                    Task { await refreshFoodStateAfterLogging() }
                }
            )
        }
        .sheet(item: $selectedDiaryFoodPortionEdit) { target in
            DiaryFoodPortionSheetView(
                row: target.row,
                onClose: { selectedDiaryFoodPortionEdit = nil },
                onApply: { ratio in
                    selectedDiaryFoodPortionEdit = nil
                    Task { await adjustDiaryFoodPortion(target.row, ratio: ratio) }
                }
            )
        }
        .sheet(item: $selectedMealCategoryDetail) { target in
            let rows = rowsForMealCategory(target.key)
            MealCategoryDetailSheetView(
                target: target,
                rows: rows,
                calorieTarget: mealTargetCalories(target.key),
                proteinTarget: mealMacroTarget(target.key, totalGoal: dailySummary?.proteinGoal ?? 50),
                carbsTarget: mealMacroTarget(target.key, totalGoal: dailySummary?.carbsGoal ?? 250),
                fatTarget: mealMacroTarget(target.key, totalGoal: dailySummary?.fatGoal ?? 65),
                saving: savingMealCategory == target.key,
                copying: copyingMealCategory == target.key,
                clearing: clearingMealCategory == target.key,
                onClose: { selectedMealCategoryDetail = nil },
                onQuickAdd: {
                    selectedMealCategoryDetail = nil
                    selectedMealCategory = target.key
                    showingQuickAdd = true
                    message = ""
                },
                onOpenLibrary: {
                    selectedMealCategoryDetail = nil
                    openSavedLibraryForMeal(target.key, title: target.title)
                },
                onSaveMeal: {
                    selectedMealCategoryDetail = nil
                    openMealCategorySaveSheet(target.key, title: target.title)
                },
                onCopyPrevious: {
                    selectedMealCategoryDetail = nil
                    Task {
                        await copyPreviousMealCategory(target.key, title: target.title)
                    }
                },
                onCopyTomorrow: {
                    selectedMealCategoryDetail = nil
                    Task {
                        await copyMealCategory(
                            target.key,
                            title: target.title,
                            to: offsetDateString(activeLogDate, days: 1),
                            targetLabel: "明天"
                        )
                    }
                },
                onCopyDate: {
                    selectedMealCategoryDetail = nil
                    selectedMealCopyTarget = MealCategoryCopyTarget(
                        key: target.key,
                        title: target.title,
                        sourceDate: activeLogDate,
                        initialDate: dateFromString(offsetDateString(activeLogDate, days: 1))
                    )
                },
                onClear: {
                    selectedMealCategoryDetail = nil
                    pendingClearMealCategoryKey = target.key
                    pendingClearMealCategoryTitle = target.title
                    showingClearMealConfirmation = true
                },
                onEditFood: { row in
                    selectedMealCategoryDetail = nil
                    selectedDiaryFoodPortionEdit = DiaryFoodPortionEditTarget(row: row)
                }
            )
        }
        .sheet(item: $selectedMealCategorySaveTarget) { target in
            MealCategorySaveSheetView(
                target: target,
                saving: savingMealCategory == target.key,
                savingRecipe: savingMealCategoryAsRecipe == target.key,
                replacing: replacingMealCategory == target.key,
                savedMeals: savedMeals,
                savedRecipes: recipeSuggestions,
                onClose: { selectedMealCategorySaveTarget = nil },
                onSave: { customTitle in
                    Task {
                        await saveMealCategoryTemplate(
                            target.key,
                            title: target.title,
                            customTitle: customTitle
                        )
                    }
                },
                onSaveRecipe: { customTitle in
                    Task {
                        await saveMealCategoryAsRecipe(
                            target.key,
                            title: target.title,
                            customTitle: customTitle
                        )
                    }
                },
                onReplace: { meal in
                    Task {
                        await replaceSavedMealWithCategory(
                            target.key,
                            title: target.title,
                            savedMeal: meal
                        )
                    }
                },
                onReplaceRecipe: { recipe in
                    Task {
                        await replaceSavedRecipeWithCategory(
                            target.key,
                            title: target.title,
                            savedRecipe: recipe
                        )
                    }
                }
            )
        }
        .sheet(item: $selectedMealCopyTarget) { target in
            MealCategoryCopyDateSheetView(
                target: target,
                onClose: { selectedMealCopyTarget = nil },
                onCopy: { dateString in
                    selectedMealCopyTarget = nil
                    Task {
                        await copyMealCategory(target.key, title: target.title, to: dateString)
                    }
                }
            )
        }
        .sheet(item: $selectedRecentMealCopyTarget) { group in
            RecentMealCopyDateSheetView(
                group: group,
                onClose: { selectedRecentMealCopyTarget = nil },
                onCopy: { dateString, label in
                    selectedRecentMealCopyTarget = nil
                    Task {
                        await copyRecentMealGroup(group, to: dateString, label: label)
                    }
                }
            )
        }
        .confirmationDialog(
            "清空\(pendingClearMealCategoryTitle)",
            isPresented: $showingClearMealConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空\(pendingClearMealCategoryTitle)", role: .destructive) {
                let key = pendingClearMealCategoryKey
                let title = pendingClearMealCategoryTitle
                pendingClearMealCategoryKey = ""
                pendingClearMealCategoryTitle = ""
                Task { await clearMealCategory(key, title: title) }
            }
            Button("取消", role: .cancel) {
                pendingClearMealCategoryKey = ""
                pendingClearMealCategoryTitle = ""
            }
        } message: {
            Text("会删除该餐次的所有食物记录，并重新计算今日摄入。")
        }
        .confirmationDialog(
            "删除我的食物",
            isPresented: $showingDeleteSavedFoodConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除\(pendingDeleteSavedFoodName)", role: .destructive) {
                let id = pendingDeleteSavedFoodId
                pendingDeleteSavedFoodId = ""
                pendingDeleteSavedFoodName = ""
                if let item = savedFoods.first(where: { $0.id == id }) {
                    Task { await deleteSavedFood(item) }
                }
            }
            Button("取消", role: .cancel) {
                pendingDeleteSavedFoodId = ""
                pendingDeleteSavedFoodName = ""
            }
        } message: {
            Text("删除后会从“我的食物”移除，已记录过的历史日志不会受影响。")
        }
        .confirmationDialog(
            "删除选中食物",
            isPresented: $showingDeleteSelectedSavedFoodsConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedSavedFoodIds.count) 个食物", role: .destructive) {
                Task { await deleteSelectedSavedFoods() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后会从“我的食物”移除，已记录过的历史日志不会受影响。")
        }
        .confirmationDialog(
            "删除我的餐品",
            isPresented: $showingDeleteSavedMealConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除\(pendingDeleteSavedMealTitle)", role: .destructive) {
                let id = pendingDeleteSavedMealId
                pendingDeleteSavedMealId = ""
                pendingDeleteSavedMealTitle = ""
                if let meal = savedMeals.first(where: { $0.id == id }) {
                    Task { await deleteSavedMeal(meal) }
                }
            }
            Button("取消", role: .cancel) {
                pendingDeleteSavedMealId = ""
                pendingDeleteSavedMealTitle = ""
            }
        } message: {
            Text("删除后会从“我的餐品”移除，已记录过的历史日志不会受影响。")
        }
        .confirmationDialog(
            "删除选中餐品",
            isPresented: $showingDeleteSelectedSavedMealsConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedSavedMealIds.count) 个餐品", role: .destructive) {
                Task { await deleteSelectedSavedMeals() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后会从“我的餐品”移除，已记录过的历史日志不会受影响。")
        }
        .confirmationDialog(
            "删除我的食谱",
            isPresented: $showingDeleteSavedRecipeConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除\(pendingDeleteSavedRecipeTitle)", role: .destructive) {
                let id = pendingDeleteSavedRecipeId
                pendingDeleteSavedRecipeId = ""
                pendingDeleteSavedRecipeTitle = ""
                if let item = recipeSuggestions.first(where: { $0.id == id }) {
                    Task { await deleteSavedRecipe(item) }
                }
            }
            Button("取消", role: .cancel) {
                pendingDeleteSavedRecipeId = ""
                pendingDeleteSavedRecipeTitle = ""
            }
        } message: {
            Text("删除后会从“我的食谱”移除，已记录过的历史日志不会受影响。")
        }
        .confirmationDialog(
            "删除选中食谱",
            isPresented: $showingDeleteSelectedSavedRecipesConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedSavedRecipeIds.count) 个食谱", role: .destructive) {
                Task { await deleteSelectedSavedRecipes() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后会从“我的食谱”移除，已记录过的历史日志不会受影响。")
        }
    }

    private var header: some View {
        CalPageHeader(
            title: "今天吃什么",
            subtitle: "拍照、补记、复用常吃餐品",
            systemImage: "fork.knife"
        ) {
            NavigationLink {
                RecommendationsPageView(onChanged: onChanged)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black)
                    .clipShape(Circle())
            }
            .accessibilityLabel("下一餐建议")
        }
    }

    private var infoModePicker: some View {
        HStack(spacing: 8) {
            ForEach(infoModeOptions, id: \.0) { item in
                Button {
                    selectedInfoMode = item.0
                    if item.0 == "plan" {
                        Task { await refreshSavedLibraryFromServer() }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.2)
                            .font(.system(size: 13, weight: .black))
                            .accessibilityHidden(true)
                        Text(item.1)
                            .font(.system(size: 14, weight: .black))
                    }
                    .foregroundStyle(selectedInfoMode == item.0 ? .white : Color(hex: "6B7280"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(selectedInfoMode == item.0 ? Color.black : .white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(hex: "E8EAEE"), lineWidth: selectedInfoMode == item.0 ? 0 : 1))
                    .shadow(color: selectedInfoMode == item.0 ? .black.opacity(0.12) : .clear, radius: 12, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到\(item.1)")
            }
        }
        .padding(5)
        .background(.white.opacity(0.72))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.75), lineWidth: 1))
    }

    private var mealsHubCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日摄入")
                        .font(.system(size: 26, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                    Text(mealsHubSubtitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(remainingCalories)))")
                        .font(.system(size: 34, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                    Text("剩余千卡")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            HStack(spacing: 8) {
                mealsHubMetric(icon: "flame.fill", label: "已吃", value: "\(Int(round(consumedCalories)))")
                mealsHubMetric(icon: "target", label: "目标", value: "\(Int(round(calorieGoal)))")
                mealsHubMetric(icon: "figure.run", label: "消耗", value: "\(Int(round(dailySummary?.caloriesBurned ?? 0)))")
            }

            HStack(spacing: 10) {
                Button {
                    onScanFood()
                } label: {
                    mealsHubActionButton(
                        title: "扫描这餐",
                        subtitle: "最快保存记录",
                        icon: "camera.viewfinder",
                        primary: true
                    )
                }
                .buttonStyle(.plain)

                Button {
                    onVoiceLog()
                } label: {
                    mealsHubActionButton(
                        title: "一句话补记",
                        subtitle: "说完再改",
                        icon: "text.bubble.fill",
                        primary: false
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 9) {
                mealMacroProgress(
                    label: "蛋白质",
                    value: dailySummary?.protein ?? dailyFoods.reduce(0) { $0 + ($1.protein ?? 0) },
                    goal: dailySummary?.proteinGoal ?? 50,
                    color: Color(hex: "F87171")
                )
                mealMacroProgress(
                    label: "碳水",
                    value: dailySummary?.carbs ?? dailyFoods.reduce(0) { $0 + ($1.carbs ?? 0) },
                    goal: dailySummary?.carbsGoal ?? 250,
                    color: Color(hex: "F59E0B")
                )
                mealMacroProgress(
                    label: "脂肪",
                    value: dailySummary?.fat ?? dailyFoods.reduce(0) { $0 + ($1.fat ?? 0) },
                    goal: dailySummary?.fatGoal ?? 65,
                    color: Color(hex: "60A5FA")
                )
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(hex: "171A20"), Color(hex: "2A3038")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 14)
    }

    private func mealsHubActionButton(title: String, subtitle: String, icon: String, primary: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(primary ? Color(hex: "111318") : .white)
                .frame(width: 30, height: 30)
                .background(primary ? .white : .white.opacity(0.12))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(primary ? Color(hex: "111318") : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(subtitle)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(primary ? Color(hex: "5F6671") : .white.opacity(0.56))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(primary ? .white : .white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(primary ? 0 : 0.08), lineWidth: 1))
    }

    private func mealsHubMetric(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func mealMacroProgress(label: String, value: Double, goal: Double, color: Color) -> some View {
        let safeGoal = max(goal, 1)
        let progress = max(0, min(1, value / safeGoal))
        return VStack(spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                Text("\(Int(round(value)))/\(Int(round(safeGoal)))克")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.78))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.13))
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 7)
        }
    }

    private var activeLogDate: String {
        if !logDate.isEmpty { return logDate }
        return Self.dateString(from: Date())
    }

    private var todayDateString: String {
        Self.dateString(from: Date())
    }

    private static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var dailyFoods: [FoodLogRow] {
        let datedRows = recentFoods.filter { row in
            let date = row.date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !date.isEmpty
        }
        if datedRows.isEmpty { return recentFoods }
        return datedRows.filter { ($0.date ?? "").hasPrefix(activeLogDate) }
    }

    private var diaryProtein: Double {
        let value = dailyFoods.reduce(0) { $0 + ($1.protein ?? 0) }
        return value > 0 ? value : (dailySummary?.protein ?? 0)
    }

    private var diaryCarbs: Double {
        let value = dailyFoods.reduce(0) { $0 + ($1.carbs ?? 0) }
        return value > 0 ? value : (dailySummary?.carbs ?? 0)
    }

    private var diaryFat: Double {
        let value = dailyFoods.reduce(0) { $0 + ($1.fat ?? 0) }
        return value > 0 ? value : (dailySummary?.fat ?? 0)
    }

    private var normalizedMealShareDraft: [String: Double] {
        normalizedMealShares(mealShareDraft)
    }

    private var mealShareDraftTotal: Double {
        mealCategoryOptions.reduce(0) { $0 + max(0, mealShareDraft[$1.0] ?? defaultMealShare($1.0)) }
    }

    private var diaryBudgetCard: some View {
        let food = consumedCalories
        let goal = calorieGoal
        let exercise = dailySummary?.caloriesBurned ?? 0
        let remaining = goal - food + exercise
        let over = remaining < 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日剩余预算")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("不用自己算，先看还能吃多少")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(abs(remaining))))")
                        .font(.system(size: 38, weight: .black))
                        .foregroundStyle(over ? Color(hex: "EF4444") : Color(hex: "111318"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(over ? "已超出" : "千卡可用")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(over ? Color(hex: "EF4444") : .secondary)
                }
            }

            HStack(spacing: 8) {
                diaryBudgetMetric("目标", value: goal, color: Color(hex: "111318"))
                diaryBudgetMetric("食物", value: food, color: Color(hex: "EF4444"))
                diaryBudgetMetric("运动", value: exercise, color: Color(hex: "22C55E"))
                diaryBudgetMetric(over ? "超出" : "剩余", value: abs(remaining), color: over ? Color(hex: "EF4444") : Color(hex: "2563EB"))
            }

            VStack(spacing: 9) {
                diaryMacroBudgetRow("蛋白", value: diaryProtein, goal: dailySummary?.proteinGoal ?? 50, color: Color(hex: "F87171"))
                diaryMacroBudgetRow("碳水", value: diaryCarbs, goal: dailySummary?.carbsGoal ?? 250, color: Color(hex: "F59E0B"))
                diaryMacroBudgetRow("脂肪", value: diaryFat, goal: dailySummary?.fatGoal ?? 65, color: Color(hex: "60A5FA"))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
    }

    private func diaryBudgetMetric(_ label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            Text("\(Int(round(value)))")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func diaryMacroBudgetRow(_ label: String, value: Double, goal: Double, color: Color) -> some View {
        let safeGoal = max(goal, 1)
        let progress = min(max(value / safeGoal, 0), 1.2)
        let over = progress > 1.05
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "4B5563"))
                    .frame(width: 34, alignment: .leading)
                Text("\(formatMacro(value))/\(formatMacro(safeGoal))克")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(over ? "偏高" : "\(Int(round(progress * 100)))%")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(over ? Color(hex: "EF4444") : Color(hex: "6B7280"))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "E9ECF1"))
                    Capsule()
                        .fill(over ? Color(hex: "EF4444") : color)
                        .frame(width: proxy.size.width * min(progress, 1))
                }
            }
            .frame(height: 6)
        }
    }

    private var mealGoalsByMealCard: some View {
        let normalized = normalizedMealShareDraft
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每餐目标")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("按餐次分配今日热量，保存后本页预算同步更新。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(Int(round(mealShareDraftTotal * 100)))%")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(abs(mealShareDraftTotal - 1.0) <= 0.01 ? Color(hex: "22C55E") : Color(hex: "EF4444"))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            VStack(spacing: 12) {
                ForEach(mealCategoryOptions, id: \.0) { option in
                    mealGoalShareRow(
                        key: option.0,
                        title: option.1,
                        icon: option.2,
                        normalizedShare: normalized[option.0] ?? defaultMealShare(option.0)
                    )
                }
            }

            Button {
                Task { await saveMealGoalShares() }
            } label: {
                HStack(spacing: 8) {
                    if savingMealGoalShares {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.74)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(savingMealGoalShares ? "保存中" : "保存每餐目标")
                        .font(.system(size: 14, weight: .black))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(savingMealGoalShares ? Color(hex: "A0A7B3") : Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(savingMealGoalShares)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 16, x: 0, y: 8)
    }

    private func mealGoalShareRow(key: String, title: String, icon: String, normalizedShare: Double) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 30, height: 30)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("\(Int(round(calorieGoal * normalizedShare))) 千卡")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(round(normalizedShare * 100)))%")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 48, alignment: .trailing)
            }
            Slider(value: mealShareBinding(key), in: 0.05...0.60, step: 0.01)
                .tint(Color.black)
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mealCategoryNamesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("餐次名称")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("可自定义早餐、午餐、晚餐和加餐名称。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "textformat")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(mealCategoryBaseOptions, id: \.0) { option in
                    VStack(alignment: .leading, spacing: 7) {
                        Label(option.1, systemImage: option.2)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                        TextField(option.1, text: mealNameBinding(option.0, fallback: option.1))
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(12)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            Button {
                Task { await saveMealCategoryNames() }
            } label: {
                HStack(spacing: 8) {
                    if savingMealNames {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.74)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(savingMealNames ? "保存中" : "保存餐次名称")
                        .font(.system(size: 14, weight: .black))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(savingMealNames ? Color(hex: "A0A7B3") : Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(savingMealNames)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 16, x: 0, y: 8)
    }

    private var diaryMealLogCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日餐品日志")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("按餐次记录食物，搜索后会加入当前选中的餐次。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(dailyFoods.reduce(0) { $0 + ($1.calories ?? 0) })))")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                ForEach(mealCategoryOptions, id: \.0) { item in
                    diaryMealRow(key: item.0, title: item.1, icon: item.2)
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
    }

    private var diaryCompletionCard: some View {
        let proteinGoal = max(dailySummary?.proteinGoal ?? 50, 1)
        let proteinGap = max(0, proteinGoal - diaryProtein)
        let nextMeal = nextDiaryMealCategory
        let projection = dailySummary?.weightProjection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: loggedMealCategoryCount >= mealCategoryOptions.count ? "checkmark.circle.fill" : "checklist")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(loggedMealCategoryCount >= mealCategoryOptions.count ? Color(hex: "22C55E") : Color(hex: "111318"))
                    .frame(width: 44, height: 44)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("今日日记复盘")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(diaryReviewMessage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                diaryReviewMetric(
                    title: "已记录餐次",
                    value: "\(loggedMealCategoryCount)/\(mealCategoryOptions.count)",
                    tint: Color(hex: "111318")
                )
                diaryReviewMetric(
                    title: "剩余热量",
                    value: "\(Int(round(remainingCalories)))",
                    tint: remainingCalories <= calorieGoal * 0.12 ? Color(hex: "EF4444") : Color(hex: "2563EB")
                )
                diaryReviewMetric(
                    title: "蛋白缺口",
                    value: "\(formatMacro(proteinGap))克",
                    tint: proteinGap <= 0 ? Color(hex: "22C55E") : Color(hex: "F87171")
                )
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: projection.isEmpty ? "scale.3d" : "chart.line.uptrend.xyaxis")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(projection.isEmpty ? "保存日记后，会按今天的摄入、运动和体重数据整理趋势提示。" : projection)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "4B5563"))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "F8FAFC"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    Task { await completeDiary() }
                } label: {
                    HStack(spacing: 7) {
                        if completingDiary {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .black))
                                .accessibilityHidden(true)
                        }
                        Text(completingDiary ? "正在保存" : "保存今日日记")
                            .font(.system(size: 12, weight: .black))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.black)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(completingDiary)
                .accessibilityLabel("保存今日日记")

                Button {
                    selectedMealCategory = nextMeal.key
                    showingQuickAdd = true
                    message = ""
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .black))
                            .accessibilityHidden(true)
                        Text("记录\(nextMeal.title)")
                            .font(.system(size: 12, weight: .black))
                    }
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("记录\(nextMeal.title)")
            }

            HStack(spacing: 8) {
                Button {
                    openSavedLibraryForMeal(nextMeal.key, title: nextMeal.title)
                } label: {
                    Text("从历史/餐品库")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从历史或餐品库记录\(nextMeal.title)")
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private func diaryReviewMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(value)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var diaryNoteCard: some View {
        let changed = diaryNoteText.trimmingCharacters(in: .whitespacesAndNewlines) != savedDiaryNoteText
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: savedDiaryNoteText.isEmpty ? "note.text" : "note.text.badge.plus")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("日记备注")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("记录今天的饮食感觉、外食原因或需要下次注意的点。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            ZStack(alignment: .topLeading) {
                if diaryNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("例如：午餐油有点多；晚餐少喝汤；明天早餐补蛋白。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "A0A7B3"))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 13)
                }
                TextEditor(text: $diaryNoteText)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "111318"))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 92)
                    .padding(8)
            }
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    Task { await saveDiaryNote() }
                } label: {
                    HStack(spacing: 7) {
                        if savingDiaryNote {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.74)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .black))
                                .accessibilityHidden(true)
                        }
                        Text(savingDiaryNote ? "保存中" : (changed ? "保存备注" : "已保存"))
                            .font(.system(size: 12, weight: .black))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(changed ? Color.black : Color(hex: "A0A7B3"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!changed || savingDiaryNote)

                Button {
                    diaryNoteText = ""
                    Task { await saveDiaryNote() }
                } label: {
                    Text("清空")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(savedDiaryNoteText.isEmpty && diaryNoteText.isEmpty ? Color(hex: "A0A7B3") : Color(hex: "EF4444"))
                        .frame(width: 74)
                        .frame(height: 38)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled((savedDiaryNoteText.isEmpty && diaryNoteText.isEmpty) || savingDiaryNote)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private func diaryMealRow(key: String, title: String, icon: String) -> some View {
        let rows = rowsForMealCategory(key)
        let calories = rows.reduce(0) { $0 + ($1.calories ?? 0) }
        let protein = rows.reduce(0) { $0 + ($1.protein ?? 0) }
        let carbs = rows.reduce(0) { $0 + ($1.carbs ?? 0) }
        let fat = rows.reduce(0) { $0 + ($1.fat ?? 0) }
        let selected = selectedMealCategory == key
        let target = mealTargetCalories(key)
        let proteinTarget = mealMacroTarget(key, totalGoal: dailySummary?.proteinGoal ?? 50)
        let carbsTarget = mealMacroTarget(key, totalGoal: dailySummary?.carbsGoal ?? 250)
        let fatTarget = mealMacroTarget(key, totalGoal: dailySummary?.fatGoal ?? 65)
        let remaining = target - calories
        let expanded = expandedDiaryMealCategories.contains(key)
        let visibleRows = expanded ? rows : Array(rows.prefix(3))

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    selectedMealCategory = key
                    message = "已切换到\(title)，搜索食物后会记录到这个餐次。"
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(selected ? .white : Color(hex: "111318"))
                            .frame(width: 34, height: 34)
                            .background(selected ? Color.black : Color(hex: "EEF1F5"))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                Text("\(rows.count)项")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .frame(height: 20)
                                    .background(.white)
                                    .clipShape(Capsule())
                            }
                            Text(diaryMealDetail(rows: rows, protein: protein, carbs: carbs, fat: fat, target: target))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(Int(round(calories)))")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text(mealBudgetLabel(target: target, remaining: remaining))
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(remaining < 0 ? Color(hex: "EF4444") : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择\(title)")

                Menu {
                    Button {
                        selectedMealCategoryDetail = MealCategoryDetailTarget(key: key, title: title, icon: icon)
                    } label: {
                        Label("查看本餐详情", systemImage: "chart.pie.fill")
                    }
                    Button {
                        openMealCategorySaveSheet(key, title: title)
                    } label: {
                        Label("记住这餐", systemImage: "tray.and.arrow.down.fill")
                    }
                    .disabled(rows.isEmpty || !savingMealCategory.isEmpty)
                    Divider()
                    Button {
                        Task { await copyPreviousMealCategory(key, title: title) }
                    } label: {
                        Label("复制之前到\(title)", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        Task {
                            await copyMealCategory(
                                key,
                                title: title,
                                to: offsetDateString(activeLogDate, days: 1),
                                targetLabel: "明天"
                            )
                        }
                    } label: {
                        Label("本餐复制到明天", systemImage: "calendar.badge.plus")
                    }
                    .disabled(rows.isEmpty)
                    Button {
                        selectedMealCopyTarget = MealCategoryCopyTarget(
                            key: key,
                            title: title,
                            sourceDate: activeLogDate,
                            initialDate: dateFromString(offsetDateString(activeLogDate, days: 1))
                        )
                    } label: {
                        Label("本餐复制到日期", systemImage: "calendar")
                    }
                    .disabled(rows.isEmpty)
                    Divider()
                    Button(role: .destructive) {
                        pendingClearMealCategoryKey = key
                        pendingClearMealCategoryTitle = title
                        showingClearMealConfirmation = true
                    } label: {
                        Label("清空\(title)", systemImage: "trash")
                    }
                    .disabled(rows.isEmpty)
                } label: {
                    if copyingMealCategory == key || clearingMealCategory == key {
                        ProgressView()
                            .tint(Color(hex: "111318"))
                            .scaleEffect(0.72)
                            .frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 34, height: 34)
                            .background(Color(hex: "EEF1F5"))
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .disabled(!copyingMealCategory.isEmpty || !clearingMealCategory.isEmpty)
                .accessibilityLabel("\(title)餐次工具")

                Button {
                    openMealCategorySaveSheet(key, title: title)
                } label: {
                    if savingMealCategory == key {
                        ProgressView()
                            .tint(Color(hex: "111318"))
                            .scaleEffect(0.72)
                            .frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(rows.isEmpty ? Color(hex: "A0A7B3") : Color(hex: "111318"))
                            .frame(width: 34, height: 34)
                            .background(rows.isEmpty ? Color(hex: "F3F4F6") : Color(hex: "EEF1F5"))
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .disabled(rows.isEmpty || !savingMealCategory.isEmpty)
                .accessibilityLabel("记住这餐，保存\(title)为我的餐品")

                Menu {
                    Button {
                        selectedMealCategory = key
                        showingQuickAdd = true
                        message = ""
                    } label: {
                        Label("手动记", systemImage: "plus.app.fill")
                    }
                    Button {
                        selectedMealCategory = key
                        showingNutritionLabelEntry = true
                        message = ""
                    } label: {
                        Label("营养标签", systemImage: "list.clipboard.fill")
                    }
                    Button {
                        openSavedLibraryForMeal(key, title: title, scope: "meal")
                    } label: {
                        Label("从我的餐品加入", systemImage: "rectangle.stack.fill")
                    }
                    Button {
                        openSavedLibraryForMeal(key, title: title, scope: "recipe")
                    } label: {
                        Label("从我的食谱加入", systemImage: "book.closed.fill")
                    }
                    Button {
                        openSavedLibraryForMeal(key, title: title, scope: "food")
                    } label: {
                        Label("从我的食物加入", systemImage: "fork.knife.circle.fill")
                    }
                    Button {
                        openFoodDatabaseForMeal(key, title: title)
                    } label: {
                        Label("找食物", systemImage: "magnifyingglass")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("加入\(title)食物")
            }

            mealProgressBar(value: calories, target: target)

            HStack(spacing: 6) {
                mealMacroChip("蛋白", value: protein, target: proteinTarget, color: Color(hex: "F87171"))
                mealMacroChip("碳水", value: carbs, target: carbsTarget, color: Color(hex: "F59E0B"))
                mealMacroChip("脂肪", value: fat, target: fatTarget, color: Color(hex: "60A5FA"))
            }

            if !rows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(visibleRows) { row in
                        diaryFoodRow(row)
                    }
                    if rows.count > 3 {
                        Button {
                            toggleDiaryMealExpansion(key)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .black))
                                    .accessibilityHidden(true)
                                Text(expanded ? "收起\(title)明细" : "展开全部 \(rows.count) 项")
                                    .font(.system(size: 11, weight: .black))
                            }
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(.white.opacity(0.72))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 46)
                        .accessibilityLabel(expanded ? "收起\(title)全部食物" : "展开\(title)全部食物")
                    }
                    mealInlineAddMenu(key: key, title: title)
                }
            } else {
                mealInlineAddMenu(key: key, title: title, isEmpty: true)
            }
        }
        .padding(12)
        .background(selected ? Color(hex: "EEF7FF") : Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1))
    }

    private func mealInlineAddMenu(key: String, title: String, isEmpty: Bool = false) -> some View {
        Menu {
            Button {
                selectedMealCategory = key
                showingQuickAdd = true
                message = ""
            } label: {
                Label("手动记", systemImage: "plus.app.fill")
            }
            Button {
                selectedMealCategory = key
                showingNutritionLabelEntry = true
                message = ""
            } label: {
                Label("营养标签", systemImage: "list.clipboard.fill")
            }
            Button {
                openSavedLibraryForMeal(key, title: title, scope: "meal")
            } label: {
                Label("从我的餐品添加", systemImage: "rectangle.stack.fill")
            }
            Button {
                openSavedLibraryForMeal(key, title: title, scope: "recipe")
            } label: {
                Label("从我的食谱添加", systemImage: "book.closed.fill")
            }
            Button {
                openSavedLibraryForMeal(key, title: title, scope: "food")
            } label: {
                Label("从我的食物添加", systemImage: "fork.knife.circle.fill")
            }
            Button {
                openFoodDatabaseForMeal(key, title: title)
            } label: {
                Label("找食物", systemImage: "magnifyingglass")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .accessibilityHidden(true)
                Text(isEmpty ? "添加食物到\(title)" : "添加更多到\(title)")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                Spacer()
                Text("快加 / 标签 / 餐品 / 食谱")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .frame(height: 36)
            .background(.white.opacity(isEmpty ? 0.86 : 0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("添加食物到\(title)")
    }

    private func mealProgressBar(value: Double, target: Double) -> some View {
        let safeTarget = max(target, 1)
        let progress = min(max(value / safeTarget, 0), 1.2)
        let isOver = progress > 1.05
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: "E9ECF1"))
                Capsule()
                    .fill(isOver ? Color(hex: "EF4444") : Color(hex: "111318"))
                    .frame(width: proxy.size.width * min(progress, 1))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("餐次热量进度 \(Int(round(value))) / \(Int(round(safeTarget))) 千卡")
    }

    private func mealMacroChip(_ label: String, value: Double, target: Double, color: Color) -> some View {
        let safeTarget = max(target, 1)
        let progress = value / safeTarget
        let isOver = progress > 1.12
        return HStack(spacing: 5) {
            Circle()
                .fill(isOver ? Color(hex: "EF4444") : color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color(hex: "4B5563"))
            Text("\(formatMacro(value))/\(formatMacro(safeTarget))克")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(.white.opacity(0.78))
        .clipShape(Capsule())
        .accessibilityLabel("\(label) \(formatMacro(value)) / \(formatMacro(safeTarget)) 克")
    }

    private func diaryFoodRow(_ row: FoodLogRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(row.displayServingSize) · 蛋白 \(formatMacro(row.protein))克 · 碳水 \(formatMacro(row.carbs))克 · 脂肪 \(formatMacro(row.fat))克")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(Int(round(row.calories ?? 0)))")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))

            if let id = row.id {
                Menu {
                    ForEach(portionRatioOptions, id: \.0) { option in
                        Button(option.1) {
                            Task { await adjustDiaryFoodPortion(row, ratio: option.0) }
                        }
                    }
                    Divider()
                    Button("自定义份数") {
                        selectedDiaryFoodPortionEdit = DiaryFoodPortionEditTarget(row: row)
                    }
                    Divider()
                    Button {
                        Task { await saveFoodAsTemplate(foodItemFromLogRow(row)) }
                    } label: {
                        Label("保存到我的食物", systemImage: "star")
                    }
                    Divider()
                    Menu("移动到") {
                        ForEach(mealCategoryOptions, id: \.0) { option in
                            if option.0 != normalizedMealCategory(row.mealCategory) {
                                Button {
                                    Task { await moveDiaryFood(row, to: option.0) }
                                } label: {
                                    Label(option.1, systemImage: option.2)
                                }
                            }
                        }
                    }
                } label: {
                    Text(movingFoodLogId == id ? "移动中" : (adjustingFoodLogId == id ? "..." : row.consumedPortionLabel))
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .frame(minWidth: 42, minHeight: 28)
                        .background(Color(hex: "EFF6FF"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(adjustingFoodLogId != 0 || deletingFoodLogId != 0 || movingFoodLogId != 0 || !savingFoodTemplateId.isEmpty || !clearingMealCategory.isEmpty)
                .accessibilityLabel("调整\(row.displayName)份量")

                Button {
                    Task { await deleteDiaryFood(row) }
                } label: {
                    Image(systemName: deletingFoodLogId == id ? "hourglass" : "trash")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "EF4444"))
                        .frame(width: 28, height: 28)
                        .background(Color(hex: "FFF1F2"))
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(deletingFoodLogId != 0 || adjustingFoodLogId != 0 || movingFoodLogId != 0 || !savingFoodTemplateId.isEmpty || !clearingMealCategory.isEmpty)
                .accessibilityLabel("删除\(row.displayName)")
            }
        }
        .padding(.leading, 46)
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .background(.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var diaryQuickAddCard: some View {
        VStack(spacing: 10) {
            Button {
                showingQuickAdd = true
                message = ""
            } label: {
                quickActionRow(
                    icon: "plus.app.fill",
                    title: "手动记一项",
                    subtitle: "知道大概热量时，先记到\(mealCategoryTitle(selectedMealCategory))。",
                    tint: Color.black
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("手动记录到\(mealCategoryTitle(selectedMealCategory))")

            Button {
                showingNutritionLabelEntry = true
                message = ""
            } label: {
                quickActionRow(
                    icon: "list.clipboard.fill",
                    title: "拍营养表",
                    subtitle: "照着包装营养成分表录入，保存到我的食物。",
                    tint: Color(hex: "2563EB")
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("录入营养成分表")
        }
    }

    private func quickActionRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(subtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "A0A6B0"))
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
    }

    private var ingredientRecipeEntryCard: some View {
        Button {
            ingredientRecipeInitialInputMode = "manual"
            showingIngredientRecipeBuilder = true
            message = ""
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "chef.hat.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 46, height: 46)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("食材做菜")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("输入或拍下手头食材，做成菜谱后记录到\(mealCategoryTitle(selectedMealCategory))。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(mealCategoryTitle(selectedMealCategory))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "F2F4F7"))
                    .clipShape(Capsule())
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用食材做菜谱并记录到\(mealCategoryTitle(selectedMealCategory))")
    }

    private func diaryMealDetail(rows: [FoodLogRow], protein: Double, carbs: Double, fat: Double, target: Double) -> String {
        guard !rows.isEmpty else { return "建议预算 \(Int(round(target))) 千卡，点加号添加" }
        let names = rows.prefix(2).map { $0.displayName }.joined(separator: "、")
        let tail = rows.count > 2 ? "等 \(rows.count) 项" : ""
        return "\(names)\(tail) · 蛋白 \(Int(round(protein)))克 · 碳水 \(Int(round(carbs)))克 · 脂肪 \(Int(round(fat)))克"
    }

    @ViewBuilder
    private var planScopeEmptyStateCard: some View {
        if selectedInfoMode == "plan", savedLibraryScope == "recent", visibleRecentIndividualFoods.isEmpty {
            libraryEmptyStateCard(
                icon: "clock.arrow.circlepath",
                title: recentIndividualFoods.isEmpty ? "先拍一餐，之后可直接复用" : "没有匹配的最近食物",
                message: recentIndividualFoods.isEmpty
                    ? "拍照或搜索记录过的单项食物会出现在这里，下一次不用重新找。"
                    : "换个关键词，或搜索常见食物后加入当前餐次。",
                primaryTitle: recentIndividualFoods.isEmpty ? "拍第一餐" : "搜索食物",
                secondaryTitle: recentIndividualFoods.isEmpty ? "搜索食物" : "手动记"
            ) {
                if recentIndividualFoods.isEmpty {
                    onScanFood()
                } else {
                    savedLibraryScope = "food"
                    savedLibraryQuery = ""
                    resetSavedLibraryExpansion()
                    message = "可搜索常见食物后加入\(mealCategoryTitle(selectedMealCategory))。"
                    Task { await refreshSavedLibraryFromServer() }
                }
            } secondaryAction: {
                if recentIndividualFoods.isEmpty {
                    savedLibraryScope = "food"
                    savedLibraryQuery = ""
                    resetSavedLibraryExpansion()
                    message = "可搜索常见食物后加入\(mealCategoryTitle(selectedMealCategory))。"
                    Task { await refreshSavedLibraryFromServer() }
                } else {
                    showingQuickAdd = true
                    message = ""
                }
            }
        } else if selectedInfoMode == "plan", savedLibraryScope == "frequent", visibleFrequentFoods.isEmpty {
            libraryEmptyStateCard(
                icon: "clock.badge.checkmark",
                    title: frequentFoods.isEmpty ? "多记几次，我会整理常吃项" : "没有匹配的常用食物",
                message: frequentFoods.isEmpty
                        ? "拍照、搜索或手动记录都可以，常吃食物会自动排到前面。"
                    : "换个关键词，或搜索常见食物后加入当前餐次。",
                primaryTitle: frequentFoods.isEmpty ? "拍第一餐" : "搜索食物",
                secondaryTitle: frequentFoods.isEmpty ? "搜索食物" : "手动记"
            ) {
                if frequentFoods.isEmpty {
                    onScanFood()
                } else {
                    savedLibraryScope = "food"
                    savedLibraryQuery = ""
                    resetSavedLibraryExpansion()
                    message = "可搜索常见食物后加入\(mealCategoryTitle(selectedMealCategory))。"
                    Task { await refreshSavedLibraryFromServer() }
                }
            } secondaryAction: {
                if frequentFoods.isEmpty {
                    savedLibraryScope = "food"
                    savedLibraryQuery = ""
                    resetSavedLibraryExpansion()
                    message = "可搜索常见食物后加入\(mealCategoryTitle(selectedMealCategory))。"
                    Task { await refreshSavedLibraryFromServer() }
                } else {
                    showingQuickAdd = true
                    message = ""
                }
            }
        }
    }

    @ViewBuilder
    private var frequentFoodsCard: some View {
        if !visibleFrequentFoods.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("常吃食物")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("按真实记录次数排序，选择餐次快速记录。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if loadingFrequentFoods {
                        ProgressView()
                            .tint(Color(hex: "111318"))
                            .scaleEffect(0.72)
                    }
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 38, height: 38)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        frequentMealFilterChip(key: "all", title: "全部", icon: "clock.fill")
                        ForEach(mealCategoryOptions, id: \.0) { option in
                            frequentMealFilterChip(key: option.0, title: option.1, icon: option.2)
                        }
                    }
                }

                if !selectedFrequentFoodIds.isEmpty {
                    selectedFrequentFoodsActionBar
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(visibleFrequentFoods) { food in
                        frequentFoodButton(food)
                    }
                }
            }
            .padding(18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        }
    }

    private func frequentMealFilterChip(key: String, title: String, icon: String) -> some View {
        let selected = frequentFoodsMealFilter == key
        return Button {
            frequentFoodsMealFilter = key
            selectedFrequentFoodIds.removeAll()
            if key != "all" {
                selectedMealCategory = key
            }
            Task { await refreshFrequentFoodsFromServer() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(selected ? .white : Color(hex: "111318"))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Color.black : Color(hex: "F7F8FA"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(title)常吃食物")
    }

    private var selectedFrequentFoodsActionBar: some View {
        let foods = selectedFrequentFoods
        let calories = foods.reduce(0) { $0 + $1.calories }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已选 \(foods.count) 个常吃食物")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("\(Int(round(calories))) 千卡 · 加入\(mealCategoryTitle(selectedMealCategory))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selectedFrequentFoodIds.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .black))
                    .accessibilityHidden(true)
                    .foregroundStyle(Color(hex: "6B7280"))
                    .frame(width: 34, height: 34)
                    .background(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedFrequentFoods)
            .accessibilityLabel("清空已选择的常吃食物")

            Button {
                showingSaveSelectedFrequentFoodsAsMeal = true
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 12, weight: .black))
                    .accessibilityHidden(true)
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 34, height: 34)
                    .background(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedFrequentFoods || foods.isEmpty)
            .accessibilityLabel("把选中的常吃食物保存为餐品")

            Button {
                showingSaveSelectedFrequentFoodsAsRecipe = true
            } label: {
                Image(systemName: "book.closed")
                    .font(.system(size: 12, weight: .black))
                    .accessibilityHidden(true)
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 34, height: 34)
                    .background(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedFrequentFoods || foods.isEmpty)
            .accessibilityLabel("把选中的常吃食物保存为食谱")

            Button {
                Task { await logSelectedFrequentFoods() }
            } label: {
                HStack(spacing: 5) {
                    if loggingSelectedFrequentFoods {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(loggingSelectedFrequentFoods ? "加入中" : "加入\(mealCategoryTitle(selectedMealCategory))")
                        .font(.system(size: 12, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 92, height: 34)
            .background(Color.black)
            .clipShape(Capsule())
            .disabled(loggingSelectedFrequentFoods || foods.isEmpty)
        }
        .padding(12)
        .background(Color(hex: "EEF7FF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.22), lineWidth: 1))
    }

    @ViewBuilder
    private var recentIndividualFoodsCard: some View {
        if !visibleRecentIndividualFoods.isEmpty {
            let filteredRows = filteredRecentIndividualFoods
            let hiddenCount = max(filteredRows.count - visibleRecentIndividualFoods.count, 0)
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最近食物")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("最近记录过的单项食物，可直接加入当前餐次。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    Spacer()
                    Text("\(filteredRows.count) 项")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                }

                VStack(spacing: 9) {
                    ForEach(Array(visibleRecentIndividualFoods.enumerated()), id: \.offset) { _, row in
                        recentIndividualFoodRow(row)
                    }
                }

                if filteredRows.count > visibleRecentIndividualFoods.count || expandedRecentIndividualFoods {
                    libraryExpandButton(
                        expanded: expandedRecentIndividualFoods,
                        hiddenCount: hiddenCount,
                        noun: "日志历史记录"
                    ) {
                        expandedRecentIndividualFoods.toggle()
                    }
                }
            }
            .padding(18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        }
    }

    private func recentIndividualFoodRow(_ row: FoodLogRow) -> some View {
        let food = foodItemFromLogRow(row)
        let groupTitle = (row.uploadGroupTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isLogging = loggingFoodId == food.id
        let isSaving = savingFoodTemplateId == food.id
        return HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "2563EB"))
                .frame(width: 34, height: 34)
                .background(Color(hex: "EFF6FF"))
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(row.displayServingSize) · \(Int(round(row.calories ?? 0))) 千卡")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Task { await saveFoodAsTemplate(food) }
            } label: {
                ZStack {
                    if isSaving {
                        ProgressView()
                            .tint(Color(hex: "111318"))
                            .scaleEffect(0.62)
                    } else {
                        Image(systemName: "star")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .accessibilityHidden(true)
                    }
                }
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!savingFoodTemplateId.isEmpty || !loggingFoodId.isEmpty)
            .accessibilityLabel("保存\(row.displayName)到我的食物")

            Button {
                Task {
                    await logFoodItem(
                        food,
                        groupTitle: groupTitle.isEmpty ? "最近食物" : groupTitle,
                        mealCategory: selectedMealCategory
                    )
                }
            } label: {
                HStack(spacing: 5) {
                    if isLogging {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(isLogging ? "加入中" : "加入")
                        .font(.system(size: 11, weight: .black))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!loggingFoodId.isEmpty || !savingFoodTemplateId.isEmpty)
            .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))：\(row.displayName)")
        }
        .padding(10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task {
                    await logFoodItem(
                        food,
                        groupTitle: groupTitle.isEmpty ? "最近食物" : groupTitle,
                        mealCategory: selectedMealCategory
                    )
                }
            } label: {
                Label("手动记", systemImage: "plus.circle.fill")
            }
            .tint(.black)
        }
    }

    private func frequentFoodButton(_ frequent: FrequentFood) -> some View {
        let selected = selectedFrequentFoodIds.contains(frequent.id)
        return HStack(alignment: .top, spacing: 8) {
            if alwaysUseMultiAdd {
                Button {
                    toggleFrequentFoodSelection(frequent)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(selected ? Color(hex: "2563EB") : Color(hex: "A0A7B3"))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(!loggingFoodId.isEmpty || loggingSelectedFrequentFoods)
                .accessibilityLabel(selected ? "取消选择常吃食物\(frequent.name)" : "选择常吃食物\(frequent.name)")
            }

            Menu {
                ForEach(mealCategoryOptions, id: \.0) { option in
                    Button {
                        Task {
                            await logFoodItem(
                                frequent.foodItem,
                                groupTitle: option.1,
                                mealCategory: option.0
                            )
                        }
                    } label: {
                        Label("加入\(option.1)", systemImage: "plus.circle.fill")
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(frequent.name)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(loggingFoodId == frequent.id ? "加入中" : "加入\(mealCategoryTitle(selectedMealCategory))")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                    Text("\(Int(round(frequent.calories))) 千卡 · \(frequent.count) 次")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(!loggingFoodId.isEmpty || loggingSelectedFrequentFoods)
            .accessibilityLabel("记录常吃食物 \(frequent.name)")
        }
        .padding(12)
        .background(selected ? Color(hex: "EFF6FF") : Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Color.blue.opacity(0.28) : Color.clear, lineWidth: 1))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task {
                    await logFoodItem(
                        frequent.foodItem,
                        groupTitle: "常用",
                        mealCategory: selectedMealCategory
                    )
                }
            } label: {
                Label("手动记", systemImage: "plus.circle.fill")
            }
            .tint(.black)
        }
    }

    private func mealCategoryPicker() -> some View {
        HStack(spacing: 8) {
            ForEach(mealCategoryOptions, id: \.0) { item in
                Button {
                    selectedMealCategory = item.0
                } label: {
                    Text(item.1)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(selectedMealCategory == item.0 ? .white : Color(hex: "6B7280"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(selectedMealCategory == item.0 ? Color.black : Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func popularSearchStrip() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("热门搜索")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(popularSearchTerms, id: \.self) { term in
                        Button {
                            searchQuery = term
                            Task { await searchFoodDatabase() }
                        } label: {
                            Text(term)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(searchingFoods)
                        .accessibilityLabel("搜索\(term)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentSearchStrip() -> some View {
        if !recentSearchTerms.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近搜索")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        recentSearchTerms = []
                        UserDefaults.standard.removeObject(forKey: recentSearchTermsKey)
                    } label: {
                        Text("清空")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "9CA3AF"))
                    }
                    .buttonStyle(.plain)
                    .disabled(searchingFoods)
                    .accessibilityLabel("清空最近搜索")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentSearchTerms, id: \.self) { term in
                            Button {
                                searchQuery = term
                                Task { await searchFoodDatabase() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 9, weight: .black))
                                        .accessibilityHidden(true)
                                    Text(term)
                                        .lineLimit(1)
                                }
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Color(hex: "EEF7FF"))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(searchingFoods)
                            .accessibilityLabel("再次搜索\(term)")
                        }
                    }
                }
            }
        }
    }

    private func rowsForMealCategory(_ key: String) -> [FoodLogRow] {
        dailyFoods.filter { normalizedMealCategory($0.mealCategory) == key }
    }

    private func toggleDiaryMealExpansion(_ key: String) {
        if expandedDiaryMealCategories.contains(key) {
            expandedDiaryMealCategories.remove(key)
        } else {
            expandedDiaryMealCategories.insert(key)
        }
    }

    private func normalizedMealCategory(_ value: String?) -> String {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("breakfast") || text.contains("早餐") { return "breakfast" }
        if text.contains("lunch") || text.contains("午餐") { return "lunch" }
        if text.contains("dinner") || text.contains("晚餐") { return "dinner" }
        if text.contains("snack") || text.contains("加餐") || text.contains("零食") { return "snack" }
        return "snack"
    }

    private func mealCategoryTitle(_ key: String) -> String {
        mealCategoryOptions.first { $0.0 == key }?.1 ?? "加餐"
    }

    private func formatPortionMultiplier(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.001 {
            return "\(Int(rounded))份"
        }
        return String(format: "%.1f份", rounded)
    }

    private func openSavedLibraryForMeal(_ key: String, title: String, scope: String = "all") {
        selectedMealCategory = key
        selectedInfoMode = "diary"
        savedLibraryScope = scope
        savedLibraryMealCategoryFilter = key
        showAllMealCategoriesInSavedLibrary = false
        savedLibraryQuery = ""
        resetSavedLibraryExpansion()
        let scopeLabel = savedLibraryScopes.first { $0.0 == scope }?.1 ?? "我的食物、餐品或食谱"
        message = "已切换到\(title)，可从\(scopeLabel)添加。"
        Task { await refreshSavedLibraryFromServer() }
    }

    private func openFoodDatabaseForMeal(_ key: String, title: String) {
        selectedMealCategory = key
        selectedInfoMode = "diary"
        savedLibraryScope = "all"
        savedLibraryMealCategoryFilter = key
        showAllMealCategoriesInSavedLibrary = false
        resetSavedLibraryExpansion()
        message = "已切换到\(title)，可搜索常见食物后加入这个餐次。"
    }

    private func mealTargetCalories(_ key: String) -> Double {
        mealMacroTarget(key, totalGoal: calorieGoal)
    }

    private func mealMacroTarget(_ key: String, totalGoal: Double) -> Double {
        let share = normalizedMealShareDraft[key] ?? defaultMealShare(key)
        return max(0, totalGoal * share)
    }

    private func defaultMealShare(_ key: String) -> Double {
        switch key {
        case "breakfast": return 0.25
        case "lunch": return 0.35
        case "dinner": return 0.30
        default: return 0.10
        }
    }

    private func normalizedMealShares(_ shares: [String: Double]) -> [String: Double] {
        var values: [String: Double] = [:]
        for option in mealCategoryOptions {
            values[option.0] = max(0.01, shares[option.0] ?? defaultMealShare(option.0))
        }
        let total = values.values.reduce(0, +)
        guard total > 0 else {
            return ["breakfast": 0.25, "lunch": 0.35, "dinner": 0.30, "snack": 0.10]
        }
        for key in Array(values.keys) {
            values[key] = (values[key] ?? 0) / total
        }
        return values
    }

    private func mealShareBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { mealShareDraft[key] ?? defaultMealShare(key) },
            set: { value in mealShareDraft[key] = value }
        )
    }

    private func saveMealGoalShares() async {
        guard !savingMealGoalShares else { return }
        savingMealGoalShares = true
        message = ""
        do {
            var goals = macroGoals
            goals.mealShares = normalizedMealShareDraft
            try await APIClient.shared.saveMacroGoals(goals)
            macroGoals = goals
            mealShareDraft = goals.mealShares
            message = "已保存每餐目标。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存每餐目标失败")
        }
        savingMealGoalShares = false
    }

    private func mealNameBinding(_ key: String, fallback: String) -> Binding<String> {
        Binding(
            get: { mealNamesDraft[key] ?? fallback },
            set: { value in mealNamesDraft[key] = String(value.prefix(12)) }
        )
    }

    private func normalizedMealNames(_ names: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for option in mealCategoryBaseOptions {
            let clean = (names[option.0] ?? option.1).trimmingCharacters(in: .whitespacesAndNewlines)
            normalized[option.0] = clean.isEmpty ? option.1 : String(clean.prefix(12))
        }
        return normalized
    }

    private func saveMealCategoryNames() async {
        guard !savingMealNames else { return }
        savingMealNames = true
        message = ""
        do {
            var prefs = userPreferences
            prefs.mealNames = normalizedMealNames(mealNamesDraft)
            let saved = try await APIClient.shared.saveUserPreferences(prefs)
            userPreferences = saved
            mealNamesDraft = normalizedMealNames(saved.mealNames)
            message = "已保存餐次名称。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存餐次名称失败")
        }
        savingMealNames = false
    }

    private func saveImportedRecipePlanPreference(_ enabled: Bool) async {
        guard !savingImportedRecipePlanPreference else { return }
        savingImportedRecipePlanPreference = true
        message = ""
        do {
            var prefs = userPreferences
            prefs.includeImportedRecipesInMealPlans = enabled
            let saved = try await APIClient.shared.saveUserPreferences(prefs)
            userPreferences = saved
            message = enabled ? "餐单会混入导入食谱。" : "餐单已暂不使用导入食谱。"
        } catch {
            userPreferences.includeImportedRecipesInMealPlans.toggle()
            message = infoFriendlyError(error, fallback: "保存导入食谱设置失败")
        }
        savingImportedRecipePlanPreference = false
    }

    private func mealBudgetLabel(target: Double, remaining: Double) -> String {
        let targetText = Int(round(target))
        if remaining < 0 {
            return "目标 \(targetText) · 超出 \(Int(round(abs(remaining))))"
        }
        return "目标 \(targetText) · 剩余 \(Int(round(remaining)))"
    }

    private var foodDatabaseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("找食物")
                        .font(.system(size: 18, weight: .black))
                    Text("找到后点记录，直接写到今天。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            mealCategoryPicker()
            recentSearchStrip()
            popularSearchStrip()

            HStack(spacing: 10) {
                TextField("搜索米饭、鸡蛋、牛奶...", text: $searchQuery)
                    .font(.system(size: 15, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await searchFoodDatabase() }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    Task { await searchFoodDatabase() }
                } label: {
                    if searchingFoods {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .black))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 48, height: 48)
                .background(Color.black)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(searchingFoods || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel(searchingFoods ? "正在搜索食物" : "搜索食物")
            }

            if searchResults.isEmpty {
                databaseSearchEmptyCard
            } else {
                let visibleResults = Array(searchResults.prefix(searchResultsVisibleLimit))
                let moreResults = Array(visibleResults.dropFirst())
                VStack(spacing: 10) {
                    if let bestMatch = visibleResults.first {
                        databaseResultSectionHeader("最佳匹配")
                        databaseFoodRow(bestMatch)
                    }
                    if !moreResults.isEmpty {
                        databaseResultSectionHeader("更多搜索结果")
                        ForEach(moreResults) { food in
                            databaseFoodRow(food)
                        }
                    }
                }
                if searchResults.count > searchResultsVisibleLimit {
                    searchResultsMoreButton
                }
                if !selectedSearchFoodIds.isEmpty {
                    selectedSearchFoodsActionBar
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var databaseSearchEmptyCard: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: query.isEmpty ? "magnifyingglass" : "exclamationmark.magnifyingglass")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(query.isEmpty ? Color(hex: "8A93A3") : Color(hex: "F59E0B"))
                .frame(width: 30, height: 30)
                .background(.white)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(query.isEmpty ? "输入食物名开始搜索" : "没搜到“\(query)”")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(query.isEmpty ? "可以搜索食品、品牌或口味。" : "删掉品牌或口味再搜，找不到就创建食物。")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "8A93A3"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !query.isEmpty {
                VStack(spacing: 8) {
                    Button {
                        showingNutritionLabelEntry = true
                        message = ""
                    } label: {
                        Text("创建食物")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        searchQuery = ""
                        searchResults = []
                        selectedSearchFoodIds.removeAll()
                        message = ""
                    } label: {
                        Text("清空")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "6B7280"))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func databaseResultSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "8A93A3"))
            Spacer()
        }
        .padding(.top, title == "最佳匹配" ? 0 : 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func databaseFoodRow(_ food: FoodItem) -> some View {
        let selected = selectedSearchFoodIds.contains(food.id)
        return HStack(spacing: 12) {
            if alwaysUseMultiAdd {
                Button {
                    toggleSearchFoodSelection(food)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(selected ? Color(hex: "2563EB") : Color(hex: "A0A7B3"))
                        .frame(width: 30, height: 36)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(loggingSelectedSearchFoods || savingSelectedSearchFoodsAsTemplates)
                .accessibilityLabel(selected ? "取消选择\(food.name)" : "选择\(food.name)")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(food.name)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(food.servingSize) · 蛋白 \(Int(round(food.protein)))克 · 碳水 \(Int(round(food.carbs)))克 · 脂肪 \(Int(round(food.fat)))克")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(round(food.calories)))")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("千卡")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await saveFoodAsTemplate(food) }
            } label: {
                if savingFoodTemplateId == food.id {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                } else {
                    Image(systemName: savedFoods.contains(where: { $0.food.name == food.name }) ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .black))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 36, height: 36)
            .background(.white)
            .foregroundStyle(Color(hex: "111318"))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            .disabled(!savingFoodTemplateId.isEmpty || savingSelectedSearchFoodsAsTemplates)
            .accessibilityLabel(savingFoodTemplateId == food.id ? "正在收藏 \(food.name)" : "收藏 \(food.name)")
            Button {
                selectedDatabaseFoodDetail = food
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .black))
                    .accessibilityHidden(true)
            }
            .frame(width: 36, height: 36)
            .background(.white)
            .foregroundStyle(Color(hex: "111318"))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            .accessibilityLabel("打开\(food.name)详情并调整份数")
            Button {
                Task { await logDatabaseFood(food) }
            } label: {
                HStack(spacing: 4) {
                    if loggingFoodId == food.id {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.68)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(loggingFoodId == food.id ? "加入中" : "加入")
                        .font(.system(size: 10, weight: .black))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(Color.black)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .disabled(!loggingFoodId.isEmpty || loggingSelectedSearchFoods || savingSelectedSearchFoodsAsTemplates)
            .accessibilityLabel(loggingFoodId == food.id ? "正在加入 \(food.name)" : "加入\(mealCategoryTitle(selectedMealCategory))：\(food.name)")
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var selectedSearchFoodsActionBar: some View {
        let foods = selectedSearchFoods
        let calories = foods.reduce(0) { $0 + $1.calories }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已选择 \(foods.count) 项")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("\(Int(round(calories))) 千卡 · 加入\(mealCategoryTitle(selectedMealCategory))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selectedSearchFoodIds.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .black))
                    .accessibilityHidden(true)
                    .foregroundStyle(Color(hex: "6B7280"))
                    .frame(width: 36, height: 36)
                    .background(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSearchFoods || savingSelectedSearchFoodsAsTemplates)
            .accessibilityLabel("清空已选择的搜索食物")

            Button {
                Task { await saveSelectedSearchFoodsAsTemplates() }
            } label: {
                if savingSelectedSearchFoodsAsTemplates {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                } else {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .black))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 36, height: 36)
            .background(.white)
            .foregroundStyle(Color(hex: "111318"))
            .clipShape(Circle())
            .disabled(loggingSelectedSearchFoods || savingSelectedSearchFoodsAsTemplates || foods.isEmpty)
            .accessibilityLabel("把选中的搜索食物收藏到我的食物")

            Button {
                showingSaveSelectedSearchFoodsAsMeal = true
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 12, weight: .black))
                    .accessibilityHidden(true)
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 36, height: 36)
                .background(.white)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSearchFoods || savingSelectedSearchFoodsAsTemplates || foods.isEmpty)
            .accessibilityLabel("把选中的搜索食物保存为餐品")

            Button {
                showingSaveSelectedSearchFoodsAsRecipe = true
            } label: {
                Image(systemName: "book.closed")
                    .font(.system(size: 12, weight: .black))
                    .accessibilityHidden(true)
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 36, height: 36)
                    .background(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSearchFoods || savingSelectedSearchFoodsAsTemplates || foods.isEmpty)
            .accessibilityLabel("把选中的搜索食物保存为食谱")

            Button {
                Task { await logSelectedSearchFoods() }
            } label: {
                HStack(spacing: 5) {
                    if loggingSelectedSearchFoods {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(loggingSelectedSearchFoods ? "加入中" : "加入\(mealCategoryTitle(selectedMealCategory))")
                        .font(.system(size: 12, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 92, height: 36)
            .background(Color.black)
            .clipShape(Capsule())
            .disabled(loggingSelectedSearchFoods || savingSelectedSearchFoodsAsTemplates)
        }
        .padding(12)
        .background(Color(hex: "EEF7FF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.22), lineWidth: 1))
    }

    private var searchResultsMoreButton: some View {
        let remaining = max(0, searchResults.count - searchResultsVisibleLimit)
        return Button {
            searchResultsVisibleLimit = min(searchResults.count, searchResultsVisibleLimit + 5)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .black))
                    .accessibilityHidden(true)
                Text("查看更多结果（还有 \(remaining) 项）")
                    .font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(Color(hex: "111318"))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Color(hex: "EEF1F5"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看更多食物搜索结果")
    }

    private var savedLibraryToolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(savedLibraryTitle)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(savedLibrarySubtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(savedLibraryFilterSummary)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "9CA3AF"))
                }
                Spacer()
                Text("\(savedFoods.count + savedMeals.count + recipeSuggestions.count) 项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(savedLibrarySearchPlaceholder, text: $savedLibraryQuery)
                    .font(.system(size: 13, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        rememberSearchTerm(savedLibraryQuery)
                        resetSavedLibraryExpansion()
                        Task { await searchSavedLibraryAndDatabase() }
                    }
                if !savedLibraryQuery.isEmpty {
                    Button {
                        savedLibraryQuery = ""
                        resetSavedLibraryExpansion()
                        Task { await refreshSavedLibraryFromServer() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "A0A7B3"))
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空餐品库搜索")
                }
                if loadingSavedLibrary || searchingFoods {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                        .scaleEffect(0.72)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            savedLibraryMealTargetCard

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(savedLibraryScopes, id: \.0) { scope in
                        Button {
                            savedLibraryScope = scope.0
                            resetSavedLibraryExpansion()
                            Task { await refreshSavedLibraryFromServer() }
                        } label: {
                            HStack(spacing: 5) {
                                Text(scope.1)
                                Text("\(savedLibraryScopeCount(scope.0))")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(savedLibraryScope == scope.0 ? .white.opacity(0.72) : Color(hex: "9CA3AF"))
                            }
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(savedLibraryScope == scope.0 ? .white : Color(hex: "111318"))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(savedLibraryScope == scope.0 ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("筛选\(scope.1)")
                    }
                }
            }

            savedLibraryOverviewCard

            if savedLibrarySupportsMealTypeFilter {
                VStack(alignment: .leading, spacing: 8) {
                    Text("适用餐次")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "9AA1AD"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            savedMealCategoryFilterChip(key: "all", title: "全部餐次", icon: "tray.full.fill")
                            ForEach(mealCategoryOptions, id: \.0) { option in
                                savedMealCategoryFilterChip(key: option.0, title: option.1, icon: option.2)
                            }
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(savedLibrarySortOptions, id: \.0) { option in
                        Button {
                            savedLibrarySort = option.0
                            resetSavedLibraryExpansion()
                            Task { await refreshSavedLibraryFromServer() }
                        } label: {
                            HStack(spacing: 4) {
                                if savedLibrarySort == option.0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .black))
                                        .accessibilityHidden(true)
                                }
                                Text(option.1)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(savedLibrarySort == option.0 ? Color(hex: "111318") : Color(hex: "6B7280"))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(savedLibrarySort == option.0 ? Color(hex: "EEF1F5") : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("按\(option.1)排序")
                    }
                }
            }

            savedLibraryLoadMoreButton
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var savedLibraryLoadMoreButton: some View {
        Button {
            Task { await loadMoreSavedLibrary() }
        } label: {
            HStack(spacing: 8) {
                if loadingMoreSavedLibrary {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                        .scaleEffect(0.78)
                } else {
                    Image(systemName: canLoadMoreSavedLibrary ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .black))
                        .accessibilityHidden(true)
                }
                Text(loadingMoreSavedLibrary ? "正在找更多" : (canLoadMoreSavedLibrary ? "加载更多" : "已全部加载"))
                    .font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(canLoadMoreSavedLibrary ? Color(hex: "111318") : Color(hex: "9CA3AF"))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Color(hex: "EEF1F5"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(loadingMoreSavedLibrary || loadingSavedLibrary || !canLoadMoreSavedLibrary)
        .accessibilityLabel("加载更多餐品库内容")
    }

    private var mealToolsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("餐食工具")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("先记上，再慢慢改。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Spacer()
                Text(mealCategoryTitle(selectedMealCategory))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                libraryActionButton(
                    icon: "camera.viewfinder",
                    title: "拍照记录",
                    subtitle: "最省事"
                ) {
                    onScanFood()
                }
                libraryActionButton(
                    icon: "plus.app.fill",
                    title: "手动补记",
                    subtitle: "先填大概"
                ) {
                    showingQuickAdd = true
                }
                libraryActionButton(
                    icon: "barcode.viewfinder",
                    title: "扫包装",
                    subtitle: "条形码"
                ) {
                    showingBarcodeLookup = true
                }
                libraryActionButton(
                    icon: "waveform",
                    title: "说一句",
                    subtitle: "语音补记"
                ) {
                    onVoiceLog()
                }
            }

            DisclosureGroup(isExpanded: $showAllMealTools) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    libraryActionButton(
                        icon: "rectangle.stack.badge.plus",
                        title: "创建餐食",
                        subtitle: "组合"
                    ) {
                        showingCreateSavedMeal = true
                    }
                    libraryActionButton(
                        icon: "doc.text.magnifyingglass",
                        title: "创建食物",
                        subtitle: "标签"
                    ) {
                        showingNutritionLabelEntry = true
                    }
                    libraryActionButton(
                        icon: "book.closed.fill",
                        title: "创建食谱",
                        subtitle: "手动"
                    ) {
                        showingManualRecipeBuilder = true
                    }
                    libraryActionButton(
                        icon: "camera.fill",
                        title: "拍食材",
                        subtitle: "做成食谱"
                    ) {
                        ingredientRecipeInitialInputMode = "photo"
                        showingIngredientRecipeBuilder = true
                        savedLibraryScope = "recipe"
                        message = "拍食材或纸质食谱，做好后可核对配料并保存。"
                    }
                    libraryActionButton(
                        icon: "square.and.arrow.down.fill",
                        title: "导入",
                        subtitle: "食谱链接"
                    ) {
                        ingredientRecipeInitialInputMode = "web"
                        showingIngredientRecipeBuilder = true
                        savedLibraryScope = "recipe"
                        message = ""
                    }
                    libraryActionButton(
                        icon: "arrow.uturn.backward",
                        title: "复制之前",
                        subtitle: "餐食内容"
                    ) {
                        let title = mealCategoryTitle(selectedMealCategory)
                        Task { await copyPreviousMealCategory(selectedMealCategory, title: title) }
                    }
                    .disabled(!copyingMealCategory.isEmpty)
                    .opacity(copyingMealCategory.isEmpty ? 1 : 0.48)
                    libraryActionButton(
                        icon: "tray.and.arrow.down.fill",
                        title: "保存本餐",
                        subtitle: mealCategoryTitle(selectedMealCategory)
                    ) {
                        openMealCategorySaveSheet(
                            selectedMealCategory,
                            title: mealCategoryTitle(selectedMealCategory)
                        )
                    }
                    .disabled(rowsForMealCategory(selectedMealCategory).isEmpty || !savingMealCategory.isEmpty)
                    .opacity(rowsForMealCategory(selectedMealCategory).isEmpty ? 0.48 : 1)
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "6B7280"))
                        .accessibilityHidden(true)
                    Text(showAllMealTools ? "收起更多管理" : "更多管理")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Spacer()
                    Text("餐品/食谱/复制")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "9CA3AF"))
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .tint(Color(hex: "111318"))
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var savedLibraryMealTargetCard: some View {
        let targetTitle = mealCategoryTitle(selectedMealCategory)
        let rows = rowsForMealCategory(selectedMealCategory)
        let calories = rows.reduce(0) { $0 + ($1.calories ?? 0) }

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .accessibilityHidden(true)
                Text("当前加入到")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "9CA3AF"))
                Text(targetTitle)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text(rows.isEmpty ? "这餐还没记录" : "\(rows.count) 项 · \(Int(round(calories))) 千卡")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            HStack(spacing: 8) {
                ForEach(mealCategoryOptions, id: \.0) { option in
                    let selected = selectedMealCategory == option.0
                    Button {
                        selectedMealCategory = option.0
                        if !showAllMealCategoriesInSavedLibrary || savedLibraryMealCategoryFilter != "all" {
                            savedLibraryMealCategoryFilter = option.0
                            resetSavedLibraryExpansion()
                            Task { await refreshSavedLibraryFromServer() }
                        }
                        message = "已切换到\(option.1)，加入按钮会记录到这个餐次。"
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.2)
                                .font(.system(size: 9, weight: .black))
                                .accessibilityHidden(true)
                            Text(option.1)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(selected ? .white : Color(hex: "111318"))
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(selected ? Color.black : .white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(selected ? Color.clear : Color(hex: "E5E7EB"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("把加入目标切换到\(option.1)")
                }
            }

            HStack(spacing: 10) {
                Image(systemName: showAllMealCategoriesInSavedLibrary ? "tray.full.fill" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(showAllMealCategoriesInSavedLibrary ? Color(hex: "2563EB") : Color(hex: "111318"))
                    .frame(width: 32, height: 32)
                    .background(.white)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("显示所有餐次餐品")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(showAllMealCategoriesInSavedLibrary ? "餐品库会显示早餐、午餐、晚餐和加餐。" : "餐品库只显示\(targetTitle)保存的餐品。")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "8A93A3"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { showAllMealCategoriesInSavedLibrary },
                    set: { newValue in
                        showAllMealCategoriesInSavedLibrary = newValue
                        savedLibraryMealCategoryFilter = newValue ? "all" : selectedMealCategory
                        resetSavedLibraryExpansion()
                        Task { await refreshSavedLibraryFromServer() }
                    }
                ))
                .labelsHidden()
                .tint(Color(hex: "111318"))
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var savedLibraryOverviewCard: some View {
        HStack(spacing: 8) {
            savedLibraryOverviewButton(
                scope: "meal",
                icon: "rectangle.stack.fill",
                title: "餐品",
                value: "\(savedMeals.count)",
                subtitle: "整餐复用",
                tint: Color(hex: "111318")
            )
            savedLibraryOverviewButton(
                scope: "recipe",
                icon: "book.closed.fill",
                title: "食谱",
                value: "\(recipeSuggestions.count)",
                subtitle: "配料配方",
                tint: Color(hex: "16A34A")
            )
            savedLibraryOverviewButton(
                scope: "food",
                icon: "fork.knife.circle.fill",
                title: "食物",
                value: "\(savedFoods.count)",
                subtitle: "单项收藏",
                tint: Color(hex: "2563EB")
            )
        }
        .padding(10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func savedLibraryOverviewButton(
        scope: String,
        icon: String,
        title: String,
        value: String,
        subtitle: String,
        tint: Color
    ) -> some View {
        let selected = savedLibraryScope == scope
        return Button {
            savedLibraryScope = scope
            resetSavedLibraryExpansion()
            Task { await refreshSavedLibraryFromServer() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(selected ? .white : tint)
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(selected ? .white : Color(hex: "111318"))
                }
                Text(title)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(selected ? .white : Color(hex: "111318"))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(selected ? .white.opacity(0.72) : Color(hex: "9CA3AF"))
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.black : .white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看\(title)")
    }

    private var librarySmartPromptCard: some View {
        let mealTitle = mealCategoryTitle(selectedMealCategory)
        let currentRows = rowsForMealCategory(selectedMealCategory)
        let currentCalories = currentRows.reduce(0) { $0 + ($1.calories ?? 0) }
        let primaryTitle = currentRows.isEmpty ? "给\(mealTitle)添加食物" : "\(mealTitle)已记录 \(currentRows.count) 项"
        let primarySubtitle = currentRows.isEmpty
            ? "优先从常吃、餐品和食谱复用，少输一次就快一点。"
            : "\(Int(round(currentCalories))) 千卡 · 可保存成餐品，或继续从库里补充。"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: currentRows.isEmpty ? "sparkles" : "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(currentRows.isEmpty ? Color(hex: "2563EB") : Color(hex: "16A34A"))
                    .frame(width: 34, height: 34)
                    .background(currentRows.isEmpty ? Color(hex: "EFF6FF") : Color(hex: "ECFDF5"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryTitle)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(primarySubtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                smartLibraryShortcut(
                    title: "常吃",
                    subtitle: "\(frequentFoods.count)",
                    icon: "clock.badge.checkmark",
                    tint: Color(hex: "2563EB")
                ) {
                    selectedMealCategory = selectedMealCategory
                    message = "下面常吃食物可直接加入\(mealTitle)。"
                }

                smartLibraryShortcut(
                    title: "餐品",
                    subtitle: "\(filteredSavedMeals.count)",
                    icon: "rectangle.stack.fill",
                    tint: Color(hex: "111318")
                ) {
                    savedLibraryScope = "meal"
                    savedLibraryMealCategoryFilter = selectedMealCategory
                    showAllMealCategoriesInSavedLibrary = false
                    resetSavedLibraryExpansion()
                    Task { await refreshSavedLibraryFromServer() }
                }

                smartLibraryShortcut(
                    title: "食谱",
                    subtitle: "\(filteredRecipeSuggestions.count)",
                    icon: "book.closed.fill",
                    tint: Color(hex: "16A34A")
                ) {
                    savedLibraryScope = "recipe"
                    resetSavedLibraryExpansion()
                    Task { await refreshSavedLibraryFromServer() }
                }

                smartLibraryShortcut(
                    title: currentRows.isEmpty ? "搜索" : "存本餐",
                    subtitle: currentRows.isEmpty ? "常见食物" : "\(currentRows.count)项",
                    icon: currentRows.isEmpty ? "magnifyingglass" : "tray.and.arrow.down.fill",
                    tint: currentRows.isEmpty ? Color(hex: "F59E0B") : Color(hex: "2563EB")
                ) {
                    if currentRows.isEmpty {
                        savedLibraryScope = "all"
                        savedLibraryQuery = ""
                        message = "可搜索常见食物后加入\(mealTitle)。"
                    } else {
                        openMealCategorySaveSheet(selectedMealCategory, title: mealTitle)
                    }
                }
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color(hex: "F8FBFF"), .white], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "E6EEF8"), lineWidth: 1))
    }

    private func smartLibraryShortcut(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(.white.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func savedMealCategoryFilterChip(key: String, title: String, icon: String) -> some View {
        let selected = savedLibraryMealCategoryFilter == key
        return Button {
            savedLibraryMealCategoryFilter = key
            showAllMealCategoriesInSavedLibrary = key == "all"
            if key != "all" {
                selectedMealCategory = key
            }
            resetSavedLibraryExpansion()
            Task { await refreshSavedLibraryFromServer() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(selected ? .white : Color(hex: "111318"))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Color.black : Color(hex: "F7F8FA"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(title)餐品")
    }

    private func savedRecipeTagFilterChip(key: String, title: String, icon: String) -> some View {
        let selected = savedRecipeTagFilter == key
        return Button {
            savedRecipeTagFilter = key
            resetSavedLibraryExpansion()
            Task { await refreshSavedLibraryFromServer() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(selected ? .white : Color(hex: "111318"))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Color.black : Color(hex: "F7F8FA"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(title)食谱")
    }

    private func libraryActionButton(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(subtitle)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)：\(subtitle)")
    }

    private func libraryExpandButton(
        expanded: Bool,
        hiddenCount: Int,
        noun: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .black))
                    .accessibilityHidden(true)
                Text(expanded ? "收起" : "还有 \(max(hiddenCount, 0)) 个\(noun)")
                    .font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(Color(hex: "111318"))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Color(hex: "F7F8FA"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起\(noun)列表" : "展开更多\(noun)")
    }

    private func librarySelectionToggleButton(
        allSelected: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(allSelected ? "取消全选" : "全选")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(disabled ? Color(hex: "A0A7B3") : Color(hex: "111318"))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(allSelected ? "取消全选当前列表" : "全选当前列表")
    }

    @ViewBuilder
    private var savedFoodsCard: some View {
        let items = filteredSavedFoods
        let visibleItems = expandedSavedFoods ? items : Array(items.prefix(12))
        let visibleIds = Set(visibleItems.map(\.id))
        let allVisibleSelected = !visibleIds.isEmpty && visibleIds.isSubset(of: selectedSavedFoodIds)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的食物")
                        .font(.system(size: 18, weight: .black))
                    Text("收藏单个食物，下次不用重新搜索。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(savedFoods.count) 个")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
                if alwaysUseMultiAdd && !visibleIds.isEmpty {
                    librarySelectionToggleButton(
                        allSelected: allVisibleSelected,
                        disabled: loggingSelectedSavedFoods || deletingSelectedSavedFoods || !loggingSavedFoodId.isEmpty || !deletingSavedFoodId.isEmpty
                    ) {
                        toggleSavedFoodSelection(ids: visibleIds)
                    }
                }
            }

            if items.isEmpty {
                libraryEmptyStateCard(
                    icon: "fork.knife.circle.fill",
                    title: savedFoods.isEmpty ? "先保存一个常吃食物" : "没有匹配的食物",
                    message: savedFoods.isEmpty
                        ? "找不到时自己创建一次；以后就能一键加入。"
                        : "换个关键词，或创建自己的食物。",
                    primaryTitle: "创建食物",
                    secondaryTitle: "找食物"
                ) {
                    showingNutritionLabelEntry = true
                    savedLibraryScope = "food"
                    message = ""
                } secondaryAction: {
                    savedLibraryScope = "food"
                    savedLibraryQuery = ""
                    message = "可搜索常见食物后加入\(mealCategoryTitle(selectedMealCategory))，也能保存到我的食物。"
                }
            } else {
                if !selectedSavedFoodIds.isEmpty {
                    selectedSavedFoodsActionBar
                }
                ForEach(visibleItems) { item in
                    savedFoodRow(item)
                }
                if items.count > 12 {
                    libraryExpandButton(
                        expanded: expandedSavedFoods,
                        hiddenCount: items.count - 12,
                        noun: "食物"
                    ) {
                        expandedSavedFoods.toggle()
                    }
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var selectedSavedFoodsActionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedSavedFoodIds.count) 项")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("可加入餐次，也可保存为餐品或食谱")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer()
            Button {
                selectedSavedFoodIds.removeAll()
            } label: {
                Text("取消")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 54, height: 34)
                    .background(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedFoods || deletingSelectedSavedFoods)

            Menu {
                Button {
                    showingSaveSelectedFoodsAsMeal = true
                } label: {
                    Label("保存为餐品", systemImage: "rectangle.stack.badge.plus")
                }
                Button {
                    showingSaveSelectedFoodsAsRecipe = true
                } label: {
                    Label("保存为食谱", systemImage: "book.closed")
                }
                Section("加入其他餐次") {
                    ForEach(mealCategoryOptions, id: \.0) { option in
                        Button {
                            Task { await logSelectedSavedFoods(mealCategory: option.0) }
                        } label: {
                            Label("加入\(option.1)", systemImage: option.2)
                        }
                    }
                }
                Button(role: .destructive) {
                    showingDeleteSelectedSavedFoodsConfirmation = true
                } label: {
                    Label("删除选中食物", systemImage: "trash")
                }
            } label: {
                ZStack {
                    if deletingSelectedSavedFoods {
                        ProgressView()
                            .scaleEffect(0.68)
                            .tint(Color(hex: "2563EB"))
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 34, height: 34)
                .background(.white)
                .clipShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedFoods || deletingSelectedSavedFoods || selectedSavedFoodIds.isEmpty)
            .accessibilityLabel("更多选中食物操作")

            Button {
                Task { await logSelectedSavedFoods(mealCategory: selectedMealCategory) }
            } label: {
                HStack(spacing: 6) {
                    if loggingSelectedSavedFoods {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(loggingSelectedSavedFoods ? "加入中" : "加入选中")
                        .font(.system(size: 12, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(.white)
                .frame(width: 92, height: 34)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedFoods || deletingSelectedSavedFoods)
            .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))：选中食物")
        }
        .padding(12)
        .background(Color(hex: "EEF7FF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.22), lineWidth: 1))
    }

    private func useCountBadge(_ count: Int) -> some View {
        Text("用过 \(count) 次")
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(Color(hex: "2563EB"))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Color(hex: "EFF6FF"))
            .clipShape(Capsule())
    }

    private func librarySourceLabel(_ source: String?, fallback: String) -> String {
        switch (source ?? "").lowercased() {
        case "ios_manual", "manual", "manually":
            return "手动创建"
        case "ios_meal_category":
            return "从餐次保存"
        case "ios_meal_template":
            return "从餐品保存"
        case "ios_recipe":
            return "从食谱保存"
        case "recipe_url_import":
            return "链接导入"
        case "ingredient_ai":
            return "食材整理"
        case "ai_enhanced", "ai_swap":
            return "更贴合今天"
        case "rules", "rules_fallback", "delivery_rules":
            return "基础规则"
        case "text":
            return "文字整理"
        case "photo_analysis":
            return "拍照整理"
        case "nutrition_label":
            return "标签录入"
        case "food_log":
            return "从日志保存"
        case "recommendation":
            return "推荐保存"
        default:
            return fallback
        }
    }

    private func libraryCompactDateLabel(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "还没记录" }
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let datePart = normalized.split(separator: " ").first.map(String.init) ?? normalized
        if datePart.count >= 10 {
            let start = datePart.index(datePart.startIndex, offsetBy: 5)
            return String(datePart[start...])
        }
        return datePart
    }

    private func libraryUsageLine(source: String?, loggedAt: String?, createdAt: String?, fallback: String) -> String {
        let date = (loggedAt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "创建 \(libraryCompactDateLabel(createdAt))"
            : "最近 \(libraryCompactDateLabel(loggedAt))"
        return "\(librarySourceLabel(source, fallback: fallback)) · \(date)"
    }

    private func libraryDateStatusLabel(loggedAt: String?, createdAt: String?) -> String {
        (loggedAt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "创建 \(libraryCompactDateLabel(createdAt))"
            : "最近 \(libraryCompactDateLabel(loggedAt))"
    }

    private func libraryMetaChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .black))
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .font(.system(size: 9, weight: .black))
        .foregroundStyle(Color(hex: "6B7280"))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(.white)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
    }

    private func libraryMacroLine(protein: Double, carbs: Double, fat: Double, fiber: Double? = nil) -> String {
        var parts = [
            "蛋白 \(formatMacro(protein))克",
            "碳水 \(formatMacro(carbs))克",
            "脂肪 \(formatMacro(fat))克"
        ]
        if let fiber, fiber >= 0.5 {
            parts.append("纤维 \(formatMacro(fiber))克")
        }
        return parts.joined(separator: " · ")
    }

    private func libraryNutritionHighlights(
        sugar: Double? = nil,
        sodium: Double? = nil,
        addedSugar: Double? = nil,
        satFat: Double? = nil,
        cholesterol: Double? = nil,
        potassium: Double? = nil
    ) -> [String] {
        var parts: [String] = []
        if let sodium, sodium >= 50 {
            parts.append("钠 \(Int(round(sodium)))mg")
        }
        if let sugar, sugar >= 1 {
            parts.append("糖 \(formatMacro(sugar))克")
        }
        if let addedSugar, addedSugar >= 1 {
            parts.append("添加糖 \(formatMacro(addedSugar))克")
        }
        if let satFat, satFat >= 0.5 {
            parts.append("饱和脂肪 \(formatMacro(satFat))克")
        }
        if let cholesterol, cholesterol >= 5 {
            parts.append("胆固醇 \(Int(round(cholesterol)))mg")
        }
        if let potassium, potassium >= 50 {
            parts.append("钾 \(Int(round(potassium)))mg")
        }
        return Array(parts.prefix(3))
    }

    private func libraryEmptyStateCard(
        icon: String,
        title: String,
        message: String,
        primaryTitle: String,
        secondaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 42, height: 42)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(message)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button(action: primaryAction) {
                    Text(primaryTitle)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: secondaryAction) {
                    Text(secondaryTitle)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func savedFoodRow(_ item: SavedFoodItem) -> some View {
        let selected = selectedSavedFoodIds.contains(item.id)
        return HStack(spacing: 12) {
            if alwaysUseMultiAdd {
                Button {
                    toggleSavedFoodSelection(item)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(selected ? Color(hex: "2563EB") : Color(hex: "A0A7B3"))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(loggingSelectedSavedFoods || deletingSelectedSavedFoods || !loggingSavedFoodId.isEmpty || !deletingSavedFoodId.isEmpty)
                .accessibilityLabel(selected ? "取消选择\(item.name)" : "选择\(item.name)")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    if (item.loggedCount ?? 0) > 0 {
                        useCountBadge(item.loggedCount ?? 0)
                    }
                }
                Text("\(item.food.servingSize) · \(Int(round(item.food.calories))) 千卡")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(libraryMacroLine(protein: item.food.protein, carbs: item.food.carbs, fat: item.food.fat, fiber: item.food.fiber))
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    libraryMetaChip(librarySourceLabel(item.source, fallback: "我的食物"), icon: "tag.fill")
                    libraryMetaChip(libraryDateStatusLabel(loggedAt: item.loggedAt, createdAt: item.createdAt), icon: "clock.fill")
                }
            }
            Spacer()
            Menu {
                Button {
                    selectedSavedFoodDetail = item
                } label: {
                    Label("查看并编辑", systemImage: "slider.horizontal.3")
                }
                Section("记录到其他餐次") {
                    ForEach(mealCategoryOptions, id: \.0) { option in
                        Button {
                            Task { await logSavedFood(item, mealCategory: option.0) }
                        } label: {
                            Label("加入\(option.1)", systemImage: option.2)
                        }
                    }
                }
                Section("自定义份数") {
                    ForEach(mealCategoryOptions, id: \.0) { option in
                        Button {
                            selectedMealCategory = option.0
                            selectedSavedFoodPortionTarget = item
                        } label: {
                            Label("\(option.1)自定义份数", systemImage: "slider.horizontal.3")
                        }
                    }
                }
                Button(role: .destructive) {
                    pendingDeleteSavedFoodId = item.id
                    pendingDeleteSavedFoodName = item.name
                    showingDeleteSavedFoodConfirmation = true
                } label: {
                    Label("删除食物", systemImage: "trash")
                }
            } label: {
                ZStack {
                    if deletingSavedFoodId == item.id {
                        ProgressView()
                            .scaleEffect(0.66)
                            .tint(Color(hex: "2563EB"))
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 30, height: 30)
                .background(.white)
                .clipShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedFoods || deletingSelectedSavedFoods || !deletingSavedFoodId.isEmpty || !loggingSavedFoodId.isEmpty)
            .accessibilityLabel("更多食物操作 \(item.name)")

            Button {
                Task { await logSavedFood(item, mealCategory: selectedMealCategory) }
            } label: {
                HStack(spacing: 5) {
                    if loggingSavedFoodId == item.id {
                        ProgressView()
                            .scaleEffect(0.68)
                            .tint(.white)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(loggingSavedFoodId == item.id ? "加入中" : "加入\(mealCategoryTitle(selectedMealCategory))")
                        .font(.system(size: 11, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(minWidth: 76)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedFoods || deletingSelectedSavedFoods || !loggingSavedFoodId.isEmpty || !deletingSavedFoodId.isEmpty)
            .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))：\(item.name)")
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await logSavedFood(item, mealCategory: selectedMealCategory) }
            } label: {
                Label("手动记", systemImage: "plus.circle.fill")
            }
            .tint(.black)
        }
    }

    @ViewBuilder
    private var savedMealsCard: some View {
        let meals = filteredSavedMeals
        let visibleMeals = expandedSavedMeals ? meals : Array(meals.prefix(10))
        let visibleIds = Set(visibleMeals.map(\.id))
        let allVisibleSelected = !visibleIds.isEmpty && visibleIds.isSubset(of: selectedSavedMealIds)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的餐品")
                        .font(.system(size: 18, weight: .black))
                    Text("把常吃的一整餐保存下来，下次一键记录。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(meals.count) 个")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
                if alwaysUseMultiAdd && !visibleIds.isEmpty {
                    librarySelectionToggleButton(
                        allSelected: allVisibleSelected,
                        disabled: loggingSelectedSavedMeals || deletingSelectedSavedMeals || !loggingSavedMealId.isEmpty || !deletingSavedMealId.isEmpty || !duplicatingSavedMealId.isEmpty
                    ) {
                        toggleSavedMealSelection(ids: visibleIds)
                    }
                }
            }

            if meals.isEmpty {
                libraryEmptyStateCard(
                    icon: "rectangle.stack.badge.plus",
                    title: savedMeals.isEmpty ? "先保存一份常吃餐" : "没有匹配的餐品",
                    message: savedMeals.isEmpty
                        ? "把经常一起吃的几项食物存成一餐，下次不用重新搭。"
                        : "换个关键词，或把当前餐次保存成餐品。",
                    primaryTitle: "新建餐品",
                    secondaryTitle: rowsForMealCategory(selectedMealCategory).isEmpty ? "复制之前" : "保存此餐食"
                ) {
                    showingCreateSavedMeal = true
                    savedLibraryScope = "meal"
                    message = ""
                } secondaryAction: {
                    if rowsForMealCategory(selectedMealCategory).isEmpty {
                        let title = mealCategoryTitle(selectedMealCategory)
                        Task { await copyPreviousMealCategory(selectedMealCategory, title: title) }
                    } else {
                        openMealCategorySaveSheet(
                            selectedMealCategory,
                            title: mealCategoryTitle(selectedMealCategory)
                        )
                    }
                }
            } else {
                if !selectedSavedMealIds.isEmpty {
                    selectedSavedMealsActionBar
                }
                ForEach(visibleMeals) { meal in
                    savedMealRow(meal)
                }
                if meals.count > 10 {
                    libraryExpandButton(
                        expanded: expandedSavedMeals,
                        hiddenCount: meals.count - 10,
                        noun: "餐品"
                    ) {
                        expandedSavedMeals.toggle()
                    }
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var selectedSavedMealsActionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已选 \(selectedSavedMealIds.count) 个餐品")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("可加入餐次，也可转换为食谱")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer()
            Button {
                selectedSavedMealIds.removeAll()
            } label: {
                Text("取消")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedMeals || deletingSelectedSavedMeals)

            Menu {
                Button {
                    showingSaveSelectedMealsAsRecipe = true
                } label: {
                    Label("保存为食谱", systemImage: "book.closed")
                }
                Section("加入其他餐次") {
                    ForEach(mealCategoryOptions, id: \.0) { option in
                        Button {
                            Task { await logSelectedSavedMeals(mealCategory: option.0) }
                        } label: {
                            Label("加入\(option.1)", systemImage: option.2)
                        }
                    }
                }
                Button(role: .destructive) {
                    showingDeleteSelectedSavedMealsConfirmation = true
                } label: {
                    Label("删除选中餐品", systemImage: "trash")
                }
            } label: {
                ZStack {
                    if deletingSelectedSavedMeals {
                        ProgressView()
                            .scaleEffect(0.68)
                            .tint(Color(hex: "2563EB"))
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 34, height: 34)
                .background(.white)
                .clipShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedMeals || deletingSelectedSavedMeals || selectedSavedMealIds.isEmpty)
            .accessibilityLabel("更多选中餐品操作")

            Button {
                Task { await logSelectedSavedMeals(mealCategory: selectedMealCategory) }
            } label: {
                HStack(spacing: 6) {
                    if loggingSelectedSavedMeals {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(loggingSelectedSavedMeals ? "加入中" : "加入选中")
                        .font(.system(size: 12, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(.white)
                .frame(width: 92, height: 34)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedMeals || deletingSelectedSavedMeals)
            .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))：选中餐品")
        }
        .padding(12)
        .background(Color(hex: "EEF7FF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.22), lineWidth: 1))
    }

    private func savedMealRow(_ meal: SavedMealItem) -> some View {
        let selected = selectedSavedMealIds.contains(meal.id)
        let nutrientHighlights = libraryNutritionHighlights(
            sugar: meal.sugar,
            sodium: meal.sodium,
            addedSugar: meal.addedSugar,
            satFat: meal.satFat,
            cholesterol: meal.cholesterol,
            potassium: meal.potassium
        )
        let defaultMealCategory = (meal.mealCategory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultMealTitle = defaultMealCategory.isEmpty ? "" : mealCategoryTitle(normalizedMealCategory(defaultMealCategory))
        let mealNote = (meal.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mealInstructionCount = meal.instructions?.count ?? 0
        let isFavoriting = favoritingSavedMealId == meal.id
        let isFavorite = meal.favorite == true
        let mealActionBusy = loggingSelectedSavedMeals || deletingSelectedSavedMeals || !loggingSavedMealId.isEmpty || !deletingSavedMealId.isEmpty || !duplicatingSavedMealId.isEmpty || !favoritingSavedMealId.isEmpty
        return HStack(spacing: 12) {
            if alwaysUseMultiAdd {
                Button {
                    toggleSavedMealSelection(meal)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(selected ? Color(hex: "2563EB") : Color(hex: "A0A7B3"))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(mealActionBusy)
                .accessibilityLabel(selected ? "取消选择餐品\(meal.title)" : "选择餐品\(meal.title)")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(meal.title)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    if (meal.loggedCount ?? 0) > 0 {
                        useCountBadge(meal.loggedCount ?? 0)
                    }
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "F59E0B"))
                            .accessibilityLabel("已收藏")
                    }
                    if !defaultMealTitle.isEmpty {
                        Text("默认 \(defaultMealTitle)")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "16A34A"))
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color(hex: "ECFDF5"))
                            .clipShape(Capsule())
                    }
                }
                Text("\(meal.foods.count) 项 · \(Int(round(meal.calories))) 千卡")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(libraryMacroLine(protein: meal.protein, carbs: meal.carbs, fat: meal.fat, fiber: meal.fiber))
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .lineLimit(1)
                if !nutrientHighlights.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(nutrientHighlights, id: \.self) { item in
                            libraryMetaChip(item, icon: "chart.bar.doc.horizontal")
                        }
                    }
                }
                Text(meal.names.prefix(3).joined(separator: "、"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "9CA3AF"))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    libraryMetaChip(librarySourceLabel(meal.source, fallback: "我的餐品"), icon: "tag.fill")
                    libraryMetaChip(libraryDateStatusLabel(loggedAt: meal.loggedAt, createdAt: meal.createdAt), icon: "clock.fill")
                }
                if !mealNote.isEmpty || mealInstructionCount > 0 {
                    HStack(spacing: 6) {
                        if !mealNote.isEmpty {
                            libraryMetaChip("有说明", icon: "text.bubble.fill")
                        }
                        if mealInstructionCount > 0 {
                            libraryMetaChip("做法 \(mealInstructionCount)步", icon: "list.number")
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button {
                    Task { await toggleSavedMealFavorite(meal) }
                } label: {
                    ZStack {
                        if isFavoriting {
                            ProgressView()
                                .scaleEffect(0.62)
                                .tint(Color(hex: "F59E0B"))
                        } else {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 14, weight: .black))
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(isFavorite ? Color(hex: "F59E0B") : Color(hex: "6B7280"))
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(mealActionBusy && !isFavoriting)
                .accessibilityLabel(isFavorite ? "取消收藏餐品 \(meal.title)" : "收藏餐品 \(meal.title)")

                Menu {
                    Button {
                        Task { await toggleSavedMealFavorite(meal) }
                    } label: {
                        Label(isFavorite ? "取消收藏餐品" : "收藏餐品", systemImage: isFavorite ? "star.slash" : "star")
                    }
                    Button {
                        selectedSavedMealDetail = meal
                    } label: {
                        Label("查看并编辑", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        Task { await duplicateSavedMeal(meal) }
                    } label: {
                        Label("复制餐品", systemImage: "doc.on.doc")
                    }
                    Section("记录到其他餐次") {
                        ForEach(mealCategoryOptions, id: \.0) { option in
                            Button {
                                Task { await logSavedMeal(meal, mealCategory: option.0) }
                            } label: {
                                Label("加入\(option.1)", systemImage: option.2)
                            }
                        }
                    }
                    Section {
                        Button {
                            selectedSavedMealPortionTarget = meal
                        } label: {
                            Label("自定义份数", systemImage: "slider.horizontal.3")
                        }
                    }
                    Button(role: .destructive) {
                        pendingDeleteSavedMealId = meal.id
                        pendingDeleteSavedMealTitle = meal.title
                        showingDeleteSavedMealConfirmation = true
                    } label: {
                        Label("删除餐品", systemImage: "trash")
                    }
                } label: {
                    ZStack {
                        if duplicatingSavedMealId == meal.id || deletingSavedMealId == meal.id || isFavoriting {
                            ProgressView()
                                .scaleEffect(0.66)
                                .tint(Color(hex: "2563EB"))
                        } else {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .black))
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .disabled(mealActionBusy && !isFavoriting)
                .accessibilityLabel("更多餐品操作 \(meal.title)")

                Button {
                    Task { await logSavedMeal(meal, mealCategory: selectedMealCategory) }
                } label: {
                    HStack(spacing: 5) {
                        if loggingSavedMealId == meal.id {
                            ProgressView()
                                .scaleEffect(0.68)
                                .tint(.white)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                        }
                        Text(loggingSavedMealId == meal.id ? "加入中" : "加入\(mealCategoryTitle(selectedMealCategory))")
                            .font(.system(size: 11, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(minWidth: 76)
                    .background(Color.black)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(mealActionBusy)
                .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))：\(meal.title)")
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await logSavedMeal(meal, mealCategory: selectedMealCategory) }
            } label: {
                Label("手动记", systemImage: "plus.circle.fill")
            }
            .tint(.black)
        }
    }

    private var recentMealsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近餐食")
                    .font(.system(size: 18, weight: .black))
                Spacer()
                Text("\(recentFoods.count) 项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            if recentMealGroups.isEmpty {
                Text("先用加号拍一餐，或搜索常见食物记录一项。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(recentMealGroups) { group in
                    recentMealRow(group)
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func recentMealRow(_ group: MealHistoryGroup) -> some View {
        let expanded = expandedRecentGroupId == group.id
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                AsyncImage(url: group.imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "fork.knife")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(hex: "F7F8FA"))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    expandedRecentGroupId = expanded ? "" : group.id
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.title)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        Text("\(group.count) 项 · \(group.displayTime.isEmpty ? "最近记录" : group.displayTime)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(group.names.prefix(3).joined(separator: "、"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: "9CA3AF"))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起\(group.title)" : "展开\(group.title)")

                VStack(alignment: .trailing, spacing: 7) {
                    Text("\(Int(round(group.calories))) 千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Menu {
                            Section("复制餐食") {
                                Button {
                                    Task { await copyRecentMealGroup(group, to: todayDateString, label: "今天") }
                                } label: {
                                    Label("复制到今天", systemImage: "calendar.badge.plus")
                                }
                                if activeLogDate != todayDateString {
                                    Button {
                                        Task { await copyRecentMealGroup(group, to: activeLogDate, label: displayDateLabel(activeLogDate)) }
                                    } label: {
                                        Label("复制到当前日期", systemImage: "doc.on.doc")
                                    }
                                }
                                Button {
                                    selectedRecentMealCopyTarget = group
                                } label: {
                                    Label("复制到日期", systemImage: "calendar")
                                }
                            }
                            Section("加入其他餐次") {
                                ForEach(mealCategoryOptions, id: \.0) { option in
                                    Button {
                                        Task { await logRecentMealGroup(group, mealCategory: option.0) }
                                    } label: {
                                        Label("加入\(option.1)", systemImage: option.2)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(width: 26, height: 26)
                                .background(.white)
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .disabled(!loggingRecentGroupId.isEmpty || !deletingRecentGroupId.isEmpty)
                        .accessibilityLabel("选择其他餐次加入同款 \(group.title)")

                        Button {
                            Task { await logRecentMealGroup(group, mealCategory: selectedMealCategory) }
                        } label: {
                            HStack(spacing: 4) {
                                if loggingRecentGroupId == group.id {
                                    ProgressView()
                                        .scaleEffect(0.72)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .black))
                                        .accessibilityHidden(true)
                                }
                                Text(loggingRecentGroupId == group.id ? "加入中" : "加入\(mealCategoryTitle(selectedMealCategory))")
                                    .font(.system(size: 10, weight: .black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(Color.black)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!loggingRecentGroupId.isEmpty || !deletingRecentGroupId.isEmpty)
                        .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))同款 \(group.title)")
                    }
                }
            }

            if expanded {
                recentMealDetails(group)
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func recentMealDetails(_ group: MealHistoryGroup) -> some View {
        VStack(spacing: 8) {
            ForEach(group.foods.prefix(4)) { row in
                HStack(spacing: 8) {
                    Text(row.displayName)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(round(row.calories ?? 0))) 千卡")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.white.opacity(0.78))
                .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                Text("蛋白 \(formatMacro(group.protein))克 · 碳水 \(formatMacro(group.carbs))克 · 脂肪 \(formatMacro(group.fat))克")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    Task { await saveRecentMealAsTemplate(group) }
                } label: {
                    HStack(spacing: 5) {
                        if savingRecentMealId == group.id {
                            ProgressView()
                                .scaleEffect(0.68)
                                .tint(Color(hex: "111318"))
                        } else {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                        }
                        Text(savingRecentMealId == group.id ? "保存中" : "保存餐品")
                            .font(.system(size: 10, weight: .black))
                    }
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!savingRecentMealId.isEmpty || !deletingRecentGroupId.isEmpty)
                .accessibilityLabel("保存餐品 \(group.title)")

                Button {
                    Task { await copyRecentMealGroup(group, to: todayDateString, label: "今天") }
                } label: {
                    HStack(spacing: 5) {
                        if loggingRecentGroupId == group.id {
                            ProgressView()
                                .scaleEffect(0.68)
                                .tint(Color(hex: "2563EB"))
                        } else {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                        }
                        Text(loggingRecentGroupId == group.id ? "复制中" : "复制到今天")
                            .font(.system(size: 10, weight: .black))
                    }
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!loggingRecentGroupId.isEmpty || !savingRecentMealId.isEmpty || !deletingRecentGroupId.isEmpty)
                .accessibilityLabel("复制\(group.title)到今天")

                Button {
                    Task { await deleteRecentMealGroup(group) }
                } label: {
                    HStack(spacing: 5) {
                        if deletingRecentGroupId == group.id {
                            ProgressView()
                                .scaleEffect(0.68)
                                .tint(Color(hex: "EF4444"))
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                        }
                        Text(deletingRecentGroupId == group.id ? "删除中" : "删除")
                            .font(.system(size: 10, weight: .black))
                    }
                    .foregroundStyle(Color(hex: "EF4444"))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color(hex: "FFF1F2"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!deletingRecentGroupId.isEmpty || !loggingRecentGroupId.isEmpty)
                .accessibilityLabel("删除\(group.title)")
            }
        }
    }

    private var plannerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("下一餐计划")
                        .font(.system(size: 18, weight: .black))
                    Text("按目标整理食谱、餐次安排和购物清单。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(goalOptions, id: \.0) { item in
                    Button {
                        goalType = item.0
                    } label: {
                        Text(item.1)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(goalType == item.0 ? .white : Color(hex: "6B7280"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(goalType == item.0 ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                planInput(icon: "target", label: "每日热量", text: $dailyCalories, range: 1000...4500)
                planInput(icon: "calendar", label: "天数", text: $days, range: 1...14)
                planInput(icon: "fork.knife", label: "每日餐数", text: $mealsPerDay, range: 2...5)
                planInput(icon: "timer", label: "烹饪分钟", text: $prepTime, range: 5...120)
            }

            VStack(alignment: .leading, spacing: 12) {
                preferenceInput(label: "偏好", placeholder: "高蛋白，家常，少油", text: $preferences)
                preferenceInput(label: "忌口", placeholder: "花生，牛奶", text: $avoid)
            }

            importedRecipesPlanPreferenceRow
            mealPlanRecipeCollectionsCard

            Button { Task { await generatePlan() } } label: {
                HStack(spacing: 8) {
                    if loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .accessibilityHidden(true)
                    }
                    Text(loading ? "正在整理" : "做一份餐单")
                }
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .disabled(loading)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 12)
    }

    private var importedRecipesPlanPreferenceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "16A34A"))
                .frame(width: 38, height: 38)
                .background(Color(hex: "DCFCE7"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("餐单使用导入食谱")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(userPreferences.includeImportedRecipesInMealPlans ? "会把网页导入食谱加入餐单。" : "餐单只使用你的目标和常见食物候选。")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "8A8F98"))
                    .lineLimit(2)
            }
            Spacer()
            if savingImportedRecipePlanPreference {
                ProgressView()
                    .frame(width: 46, height: 30)
            } else {
                Toggle("", isOn: Binding(
                    get: { userPreferences.includeImportedRecipesInMealPlans },
                    set: { value in
                        userPreferences.includeImportedRecipesInMealPlans = value
                        Task { await saveImportedRecipePlanPreference(value) }
                    }
                ))
                .labelsHidden()
                .tint(Color(hex: "16A34A"))
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "ECEFF3"), lineWidth: 1))
    }

    private var mealPlanRecipeCollectionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 34, height: 34)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "ECEFF3"), lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("食谱集合")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("按高蛋白、低碳、低卡和餐次整理你的食谱。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "8A8F98"))
                        .lineLimit(2)
                }
                Spacer()
                Text(recipeCollections.isEmpty ? "待整理" : "\(recipeCollections.count)组")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.white)
                    .clipShape(Capsule())
            }

            if recipeCollections.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "9CA3AF"))
                        .accessibilityHidden(true)
                    Text("保存或导入食谱后，这里会整理成适合餐单使用的集合。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "6B7280"))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        showingIngredientRecipeBuilder = true
                    } label: {
                        Text("创建")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "ECEFF3"), lineWidth: 1))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(recipeCollections) { collection in
                            MealPlanRecipeCollectionCard(collection: collection) {
                                applyRecipeCollectionFilter(collection)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "ECEFF3"), lineWidth: 1))
    }

    private var recipeLibraryWorkbenchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("餐食、食谱和食物")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存常吃餐品、创建食谱，也能手动记、扫条码和新建食物。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    recipeLibraryStatButton(title: "全部", value: "\(savedLibraryScopeCount("all"))", icon: "square.grid.2x2.fill", scope: "all")
                    recipeLibraryStatButton(title: "最近的", value: "\(savedLibraryScopeCount("recent"))", icon: "clock.arrow.circlepath", scope: "recent")
                    recipeLibraryStatButton(title: "常用", value: "\(savedLibraryScopeCount("frequent"))", icon: "clock.badge.checkmark", scope: "frequent")
                    recipeLibraryStatButton(title: "我的食物", value: "\(savedFoods.count)", icon: "fork.knife.circle.fill", scope: "food")
                    recipeLibraryStatButton(title: "我的餐品", value: "\(savedMeals.count)", icon: "rectangle.stack.fill", scope: "meal")
                    recipeLibraryStatButton(title: "收藏餐品", value: "\(savedLibraryScopeCount("meal_favorite"))", icon: "star.circle.fill", scope: "meal_favorite")
                    recipeLibraryStatButton(title: "我的食谱", value: "\(recipeSuggestions.count)", icon: "book.closed.fill", scope: "recipe")
                    recipeLibraryStatButton(title: "收藏食谱", value: "\(savedLibraryScopeCount("recipe_favorite"))", icon: "star.fill", scope: "recipe_favorite")
                    recipeLibraryStatButton(title: "导入食谱", value: "\(savedLibraryScopeCount("recipe_imported"))", icon: "link.circle.fill", scope: "recipe_imported")
                }
            }

            recipeLibraryTargetMealPicker

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(savedLibrarySearchPlaceholder, text: $savedLibraryQuery)
                    .font(.system(size: 13, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        rememberSearchTerm(savedLibraryQuery)
                        resetSavedLibraryExpansion()
                        Task { await searchSavedLibraryAndDatabase() }
                    }
                if !savedLibraryQuery.isEmpty {
                    Button {
                        savedLibraryQuery = ""
                        resetSavedLibraryExpansion()
                        Task { await refreshSavedLibraryFromServer() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "A0A7B3"))
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空\(savedLibraryTitle)搜索")
                }
                Button {
                    showingSavedLibrarySortFilter = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: hasActiveSavedLibraryFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 14, weight: .black))
                            .accessibilityHidden(true)
                        Text("排序和筛选")
                            .font(.system(size: 11, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(hasActiveSavedLibraryFilters ? .white : Color(hex: "111318"))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(hasActiveSavedLibraryFilters ? Color.black : .white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开排序和筛选")
                if loadingSavedLibrary {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                        .scaleEffect(0.72)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            savedLibraryRecentSearchStrip

            savedLibraryDatabaseSearchStatusCard

            savedLibraryContextActionsCard

            savedLibraryToolTipsCard

            savedLibrarySwipeHelpCard

            savedLibraryMultiAddHintCard

            if savedLibraryUsesSavedSort {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(savedLibrarySortOptions, id: \.0) { option in
                            Button {
                                savedLibrarySort = option.0
                                resetSavedLibraryExpansion()
                                Task { await refreshSavedLibraryFromServer() }
                            } label: {
                                HStack(spacing: 4) {
                                    if savedLibrarySort == option.0 {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .black))
                                            .accessibilityHidden(true)
                                    }
                                    Text(option.1)
                                        .lineLimit(1)
                                }
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(savedLibrarySort == option.0 ? Color(hex: "111318") : Color(hex: "6B7280"))
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(savedLibrarySort == option.0 ? Color(hex: "EEF1F5") : Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(savedLibraryTitle)按\(option.1)排序")
                        }
                    }
                }
            } else if let fixedOrder = savedLibraryFixedOrderLabel {
                HStack(spacing: 8) {
                    Image(systemName: savedLibraryScope == "recent" ? "clock.arrow.circlepath" : "clock.badge.checkmark")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .accessibilityHidden(true)
                    Text(fixedOrder)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Spacer()
                    Text("\(savedLibraryFilteredCount) 项")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "8A93A3"))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
            }

            if savedLibrarySupportsMealTypeFilter {
                VStack(alignment: .leading, spacing: 8) {
                    Text("筛选适用餐次")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "9AA1AD"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            savedMealCategoryFilterChip(key: "all", title: "全部餐次", icon: "tray.full.fill")
                            ForEach(mealCategoryOptions, id: \.0) { option in
                                savedMealCategoryFilterChip(key: option.0, title: option.1, icon: option.2)
                            }
                        }
                    }
                }
            }

            if savedLibrarySupportsRecipeTagFilter {
                VStack(alignment: .leading, spacing: 8) {
                    Text("筛选饮食目标")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "9AA1AD"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(savedRecipeTagOptions, id: \.0) { option in
                                savedRecipeTagFilterChip(key: option.0, title: option.1, icon: option.2)
                            }
                        }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                libraryActionButton(
                    icon: "camera.viewfinder",
                    title: "扫描食物",
                    subtitle: "AI 分析你的食物"
                ) {
                    onScanFood()
                }
                libraryActionButton(
                    icon: "plus.app.fill",
                    title: "手动记",
                    subtitle: "卡路里"
                ) {
                    showingQuickAdd = true
                    message = ""
                }
                libraryActionButton(
                    icon: "barcode.viewfinder",
                    title: "条形码扫描",
                    subtitle: "包装食品"
                ) {
                    showingBarcodeLookup = true
                    message = ""
                }
                libraryActionButton(
                    icon: "waveform",
                    title: "语音日志",
                    subtitle: "说出食物"
                ) {
                    onVoiceLog()
                }
                libraryActionButton(
                    icon: "doc.text.magnifyingglass",
                    title: "创建食物",
                    subtitle: "标签"
                ) {
                    showingNutritionLabelEntry = true
                    message = ""
                }
                libraryActionButton(
                    icon: "rectangle.stack.badge.plus",
                    title: "创建餐食",
                    subtitle: "组合保存"
                ) {
                    showingCreateSavedMeal = true
                    message = ""
                }
                libraryActionButton(
                    icon: "book.closed.fill",
                    title: "创建食谱",
                    subtitle: "配料营养"
                ) {
                    showingManualRecipeBuilder = true
                    message = ""
                }
                libraryActionButton(
                    icon: "camera.fill",
                    title: "拍食材",
                    subtitle: "识别成食谱"
                ) {
                    ingredientRecipeInitialInputMode = "photo"
                    showingIngredientRecipeBuilder = true
                    savedLibraryScope = "recipe"
                    message = "拍食材或纸质食谱，做好后可核对配料并保存。"
                }
                libraryActionButton(
                    icon: "sparkles",
                    title: "发现",
                    subtitle: "食谱灵感"
                ) {
                    ingredientRecipeInitialInputMode = "manual"
                    showingIngredientRecipeBuilder = true
                    savedLibraryScope = "recipe"
                    message = "输入手头食材，做成可保存和记录的食谱。"
                }
                libraryActionButton(
                    icon: "square.and.arrow.down.fill",
                    title: "导入",
                    subtitle: "食谱链接"
                ) {
                    ingredientRecipeInitialInputMode = "web"
                    showingIngredientRecipeBuilder = true
                    savedLibraryScope = "recipe"
                    message = ""
                }
                libraryActionButton(
                    icon: "tray.and.arrow.down.fill",
                    title: "保存本餐",
                    subtitle: mealCategoryTitle(selectedMealCategory)
                ) {
                    openMealCategorySaveSheet(
                        selectedMealCategory,
                        title: mealCategoryTitle(selectedMealCategory)
                    )
                }
                .disabled(rowsForMealCategory(selectedMealCategory).isEmpty || !savingMealCategory.isEmpty)
                .opacity(rowsForMealCategory(selectedMealCategory).isEmpty ? 0.48 : 1)
                libraryActionButton(
                    icon: "arrow.uturn.backward",
                    title: "复制之前",
                    subtitle: "餐食内容"
                ) {
                    let title = mealCategoryTitle(selectedMealCategory)
                    Task { await copyPreviousMealCategory(selectedMealCategory, title: title) }
                }
                .disabled(!copyingMealCategory.isEmpty)
                .opacity(copyingMealCategory.isEmpty ? 1 : 0.48)
                libraryActionButton(
                    icon: "list.bullet.rectangle",
                    title: "回到日记",
                    subtitle: "记录餐食"
                ) {
                    selectedInfoMode = "diary"
                    savedLibraryScope = "all"
                    message = "可从最近、常用、我的食物、餐品和食谱加入\(mealCategoryTitle(selectedMealCategory))。"
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
    }

    private var recipeLibraryTargetMealPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .accessibilityHidden(true)
                Text("加入到")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "9CA3AF"))
                Text(mealCategoryTitle(selectedMealCategory))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(mealCategoryOptions, id: \.0) { option in
                        let selected = selectedMealCategory == option.0
                        Button {
                            selectedMealCategory = option.0
                            message = "已切换到\(option.1)，加入按钮会记录到这个餐次。"
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: option.2)
                                    .font(.system(size: 9, weight: .black))
                                    .accessibilityHidden(true)
                                Text(option.1)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(selected ? .white : Color(hex: "111318"))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(selected ? Color.black : .white)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(selected ? Color.clear : Color(hex: "E5E7EB"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("把加入目标切换到\(option.1)")
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var savedLibraryRecentSearchStrip: some View {
        if !recentSearchTerms.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近搜索")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "8A93A3"))
                    Spacer()
                    Button {
                        recentSearchTerms = []
                        UserDefaults.standard.removeObject(forKey: recentSearchTermsKey)
                    } label: {
                        Text("清空")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "9CA3AF"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空餐品库最近搜索")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentSearchTerms, id: \.self) { term in
                            Button {
                                savedLibraryQuery = term
                                rememberSearchTerm(term)
                                resetSavedLibraryExpansion()
                                Task { await searchSavedLibraryAndDatabase() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 9, weight: .black))
                                        .accessibilityHidden(true)
                                    Text(term)
                                        .lineLimit(1)
                                }
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("搜索\(term)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var savedLibraryDatabaseSearchStatusCard: some View {
        let query = normalizedSavedLibraryQuery
        if !query.isEmpty && (savedLibraryScope == "all" || savedLibraryScope == "food") {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: searchingFoods ? "magnifyingglass.circle.fill" : (searchResults.isEmpty ? "exclamationmark.magnifyingglass" : "checkmark.circle.fill"))
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(searchingFoods ? Color(hex: "2563EB") : (searchResults.isEmpty ? Color(hex: "F59E0B") : Color(hex: "16A34A")))
                    .frame(width: 28, height: 28)
                    .background(.white)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(searchingFoods ? "正在查找食物" : (searchResults.isEmpty ? "没搜到结果" : "找到 \(searchResults.count) 项"))
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(searchResults.isEmpty && !searchingFoods ? "换个更短的关键词，或直接创建自己的食物。" : "选一个就能加入\(mealCategoryTitle(selectedMealCategory))。")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8A93A3"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 8)
                if searchResults.isEmpty && !searchingFoods {
                    Button {
                        showingNutritionLabelEntry = true
                        message = ""
                    } label: {
                        Text("创建食物")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var savedLibrarySwipeHelpCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "2563EB"))
                .frame(width: 28, height: 28)
                .background(.white)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("向右滑动即可记录")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(savedLibraryHelpText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "8A93A3"))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(hex: "EEF7FF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.14), lineWidth: 1))
    }

    private var savedLibraryToolTipsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.max.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "F59E0B"))
                    .frame(width: 28, height: 28)
                    .background(.white)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加项目")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("添加食物、食谱和餐品；也可以扫条码、拍照或手动记卡路里。")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8A93A3"))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                savedLibraryTipAction(title: "历史记录", icon: "clock.arrow.circlepath") {
                    savedLibraryScope = "recent"
                    resetSavedLibraryExpansion()
                    message = "查看你已记录的食物，选择之后可直接添加到日记中。"
                    Task { await refreshSavedLibraryFromServer() }
                }
                savedLibraryTipAction(title: "排序和筛选", icon: "line.3.horizontal.decrease.circle") {
                    showingSavedLibrarySortFilter = true
                }
                savedLibraryTipAction(title: "添加项目", icon: "plus.circle.fill") {
                    showingSavedLibraryAddItems = true
                }
            }
        }
        .padding(12)
        .background(Color(hex: "FFF7ED"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.14), lineWidth: 1))
    }

    private func savedLibraryTipAction(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(Color(hex: "111318"))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(.white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var savedLibraryMultiAddHintCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(savedLibraryMultiAddCount > 0 ? .white : Color(hex: "111318"))
                .frame(width: 28, height: 28)
                .background(savedLibraryMultiAddCount > 0 ? Color.black : .white)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alwaysUseMultiAdd ? "多选模式" : "直接添加")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    if savedLibraryMultiAddCount > 0 {
                        Text("\(savedLibraryMultiAddCount)/\(maximumMultiAddItems)")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                }
                Text(savedLibraryMultiAddSubtitle)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "8A93A3"))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            Spacer(minLength: 0)
            Button {
                alwaysUseMultiAdd.toggle()
                if !alwaysUseMultiAdd {
                    clearMultiAddSelections()
                }
            } label: {
                Text(alwaysUseMultiAdd ? "收起多选" : "多选")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(alwaysUseMultiAdd ? .white : Color(hex: "111318"))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(alwaysUseMultiAdd ? Color.black : .white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(alwaysUseMultiAdd ? Color.clear : Color(hex: "E5E7EB"), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(alwaysUseMultiAdd ? "收起多选模式" : "进入多选模式")
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var savedLibraryContextActionsCard: some View {
        let mealTitle = mealCategoryTitle(selectedMealCategory)
        let hasCurrentMealRows = !rowsForMealCategory(selectedMealCategory).isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 26, height: 26)
                    .background(.white)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(savedLibraryTitle)的下一步")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(savedLibraryFilterSummary)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "8A93A3"))
                        .lineLimit(1)
                }
                Spacer()
                if hasActiveSavedLibraryFilters {
                    Button {
                        clearSavedLibraryFilters()
                    } label: {
                        Text("清除筛选")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除餐品库筛选")
                }
            }

            HStack(spacing: 10) {
                switch savedLibraryScope {
                case "recent":
                    libraryContextActionButton(
                        icon: "arrow.uturn.backward",
                        title: "复制之前",
                        subtitle: "餐食内容 · \(mealTitle)",
                        filled: true,
                        disabled: !copyingMealCategory.isEmpty
                    ) {
                        Task { await copyPreviousMealCategory(selectedMealCategory, title: mealTitle) }
                    }
                    libraryContextActionButton(
                        icon: "magnifyingglass",
                        title: "搜索食物",
                        subtitle: "继续补充",
                        filled: false
                    ) {
                        savedLibraryScope = "food"
                        savedLibraryQuery = ""
                        resetSavedLibraryExpansion()
                        Task { await refreshSavedLibraryFromServer() }
                    }
                case "frequent":
                    libraryContextActionButton(
                        icon: "plus.circle.fill",
                        title: "加入选中",
                        subtitle: mealTitle,
                        filled: true,
                        disabled: selectedFrequentFoodIds.isEmpty || loggingSelectedFrequentFoods
                    ) {
                        Task { await logSelectedFrequentFoods() }
                    }
                    libraryContextActionButton(
                        icon: "rectangle.stack.badge.plus",
                        title: "保存成餐品",
                        subtitle: "\(selectedFrequentFoodIds.count) 项",
                        filled: false,
                        disabled: selectedFrequentFoodIds.isEmpty || loggingSelectedFrequentFoods
                    ) {
                        showingSaveSelectedFrequentFoodsAsMeal = true
                    }
                case "food":
                    libraryContextActionButton(
                        icon: "doc.text.magnifyingglass",
                        title: "创建食物",
                        subtitle: "录入营养标签",
                        filled: true
                    ) {
                        showingNutritionLabelEntry = true
                        message = ""
                    }
                    libraryContextActionButton(
                        icon: "barcode.viewfinder",
                        title: "条形码扫描",
                        subtitle: "包装食品",
                        filled: false
                    ) {
                        showingBarcodeLookup = true
                        message = ""
                    }
                case "meal", "meal_favorite":
                    libraryContextActionButton(
                        icon: "rectangle.stack.badge.plus",
                        title: "创建餐食",
                        subtitle: "保存常吃组合",
                        filled: true
                    ) {
                        showingCreateSavedMeal = true
                        message = ""
                    }
                    libraryContextActionButton(
                        icon: hasCurrentMealRows ? "tray.and.arrow.down.fill" : "arrow.uturn.backward",
                        title: hasCurrentMealRows ? "保存此餐食" : "复制之前",
                        subtitle: mealTitle,
                        filled: false,
                        disabled: !hasCurrentMealRows && !copyingMealCategory.isEmpty
                    ) {
                        if hasCurrentMealRows {
                            openMealCategorySaveSheet(selectedMealCategory, title: mealTitle)
                        } else {
                            Task { await copyPreviousMealCategory(selectedMealCategory, title: mealTitle) }
                        }
                    }
                case "recipe":
                    libraryContextActionButton(
                        icon: "book.closed.fill",
                        title: "创建食谱",
                        subtitle: "配料和每份营养",
                        filled: true
                    ) {
                        showingManualRecipeBuilder = true
                        message = ""
                    }
                    libraryContextActionButton(
                        icon: "square.and.arrow.down.fill",
                        title: "导入",
                        subtitle: "食谱链接",
                        filled: false
                    ) {
                        ingredientRecipeInitialInputMode = "web"
                        showingIngredientRecipeBuilder = true
                        savedLibraryScope = "recipe"
                        message = ""
                    }
                default:
                    libraryContextActionButton(
                        icon: "plus.app.fill",
                        title: "手动记",
                        subtitle: "直接记录卡路里",
                        filled: true
                    ) {
                        showingQuickAdd = true
                        message = ""
                    }
                    libraryContextActionButton(
                        icon: "barcode.viewfinder",
                        title: "条形码扫描",
                        subtitle: "包装食品",
                        filled: false
                    ) {
                        showingBarcodeLookup = true
                        message = ""
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func libraryContextActionButton(
        icon: String,
        title: String,
        subtitle: String,
        filled: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(subtitle)
                        .font(.system(size: 9, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .opacity(0.72)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(filled ? .white : Color(hex: "111318"))
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(filled ? Color.black : .white)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .opacity(disabled ? 0.48 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("\(title)：\(subtitle)")
    }

    private func recipeLibraryStatButton(title: String, value: String, icon: String, scope: String) -> some View {
        Button {
            savedLibraryScope = scope
            resetSavedLibraryExpansion()
            Task { await refreshSavedLibraryFromServer() }
        } label: {
            recipeLibraryStatChip(
                title: title,
                value: value,
                icon: icon,
                selected: savedLibraryScope == scope
            )
            .frame(width: 118)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看\(title)")
    }

    private func recipeLibraryStatChip(title: String, value: String, icon: String, selected: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(selected ? .white : Color(hex: "111318"))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(selected ? .white.opacity(0.68) : Color(hex: "9CA3AF"))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(selected ? .white : Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(selected ? Color.black : Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var loadingHistoryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在整理你的餐品库")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("常吃、最近和保存餐品会自动排好。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .softCard(radius: 22)
    }

    @ViewBuilder
    private var savedRecipesCard: some View {
        let items = filteredRecipeSuggestions
        let visibleItems = expandedSavedRecipes ? items : Array(items.prefix(10))
        let visibleIds = Set(visibleItems.map(\.id))
        let allVisibleSelected = !visibleIds.isEmpty && visibleIds.isSubset(of: selectedSavedRecipeIds)
        let shouldShowRecipesCard = selectedInfoMode == "plan"
            || !recipeSuggestions.isEmpty
            || (selectedInfoMode == "diary" && (savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" || savedLibraryScope == "all"))
        if shouldShowRecipesCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的食谱")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("最近保存的食谱，可直接加入日记。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(items.count) 个")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                    if alwaysUseMultiAdd && !visibleIds.isEmpty {
                        librarySelectionToggleButton(
                            allSelected: allVisibleSelected,
                            disabled: loggingSelectedSavedRecipes || deletingSelectedSavedRecipes || !loggingRecipeSuggestionId.isEmpty || !deletingRecipeSuggestionId.isEmpty || !savingRecipeAsMealId.isEmpty || !duplicatingRecipeSuggestionId.isEmpty
                        ) {
                            toggleSavedRecipeSelection(ids: visibleIds)
                        }
                    }
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 40, height: 40)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                }

                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "16A34A"))
                        .accessibilityHidden(true)
                    Text("加入目标：\(mealCategoryTitle(selectedMealCategory))")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "6B7280"))
                    Spacer()
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())

                if items.isEmpty {
                    libraryEmptyStateCard(
                        icon: "book.closed.fill",
                        title: savedLibraryScope == "recipe_favorite"
                            ? "先收藏一个常用食谱"
                            : (savedLibraryScope == "recipe_imported"
                                ? "先导入一个常做食谱"
                                : (recipeSuggestions.isEmpty ? "先创建一个可复用食谱" : "没有匹配的食谱")),
                        message: savedLibraryScope == "recipe_favorite"
                            ? "点食谱右侧星标即可收藏，之后能像收藏夹一样快速找到。"
                            : (savedLibraryScope == "recipe_imported"
                                ? "粘贴食谱网页链接，我会保留配料、做法和时间。"
                                : (recipeSuggestions.isEmpty
                                    ? "保存配料、做法和每份营养，以后可直接加入日记。"
                                    : "换个关键词，或新建一个食谱。")),
                        primaryTitle: "创建食谱",
                        secondaryTitle: "导入食谱"
                    ) {
                        showingManualRecipeBuilder = true
                        savedLibraryScope = "recipe"
                        message = ""
                    } secondaryAction: {
                        ingredientRecipeInitialInputMode = "web"
                        showingIngredientRecipeBuilder = true
                        savedLibraryScope = "recipe"
                        message = "粘贴食谱链接即可导入配料和做法。"
                    }
                } else {
                    VStack(spacing: 10) {
                        if !selectedSavedRecipeIds.isEmpty {
                            selectedSavedRecipesActionBar
                        }
                        ForEach(visibleItems) { item in
                            savedRecipeRow(item)
                        }
                        if items.count > 10 {
                            libraryExpandButton(
                                expanded: expandedSavedRecipes,
                                hiddenCount: items.count - 10,
                                noun: "食谱"
                            ) {
                                expandedSavedRecipes.toggle()
                            }
                        }
                    }
                }
            }
            .padding(18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
        }
    }

    private var selectedSavedRecipesActionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已选 \(selectedSavedRecipeIds.count) 个食谱")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("可加入餐次，也可保存为餐品")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer()
            Button {
                selectedSavedRecipeIds.removeAll()
            } label: {
                Text("取消")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedRecipes || deletingSelectedSavedRecipes || savingSelectedRecipesAsMeals)

            Menu {
                Button {
                    Task { await saveSelectedRecipesAsMeals() }
                } label: {
                    Label("保存为餐品", systemImage: "tray.and.arrow.down")
                }
                Section("加入其他餐次") {
                    ForEach(mealCategoryOptions, id: \.0) { option in
                        Button {
                            Task { await logSelectedSavedRecipes(mealCategory: option.0) }
                        } label: {
                            Label("加入\(option.1)", systemImage: option.2)
                        }
                    }
                }
                Button(role: .destructive) {
                    showingDeleteSelectedSavedRecipesConfirmation = true
                } label: {
                    Label("删除选中食谱", systemImage: "trash")
                }
            } label: {
                ZStack {
                    if deletingSelectedSavedRecipes || savingSelectedRecipesAsMeals {
                        ProgressView()
                            .scaleEffect(0.68)
                            .tint(Color(hex: "2563EB"))
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 34, height: 34)
                .background(.white)
                .clipShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedRecipes || deletingSelectedSavedRecipes || savingSelectedRecipesAsMeals || selectedSavedRecipeIds.isEmpty)
            .accessibilityLabel("更多选中食谱操作")

            Button {
                Task { await logSelectedSavedRecipes(mealCategory: selectedMealCategory) }
            } label: {
                HStack(spacing: 6) {
                    if loggingSelectedSavedRecipes {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(loggingSelectedSavedRecipes ? "加入中" : "加入选中")
                        .font(.system(size: 12, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(.white)
                .frame(width: 92, height: 34)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loggingSelectedSavedRecipes || deletingSelectedSavedRecipes || savingSelectedRecipesAsMeals)
            .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))：选中食谱")
        }
        .padding(12)
        .background(Color(hex: "EEF7FF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.22), lineWidth: 1))
    }

    private func savedRecipeRow(_ item: IngredientRecipeHistoryItem) -> some View {
        let recipe = item.recipe
        let selected = selectedSavedRecipeIds.contains(item.id)
        let isLogging = loggingRecipeSuggestionId == item.id
        let isDeleting = deletingRecipeSuggestionId == item.id
        let isSavingMeal = savingRecipeAsMealId == item.id
        let isDuplicating = duplicatingRecipeSuggestionId == item.id
        let isFavoriting = favoritingRecipeSuggestionId == item.id
        let isFavorite = recipe.favorite == true
        let recipeSourceURL: URL? = {
            guard let raw = recipe.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw),
                  url.scheme?.hasPrefix("http") == true else {
                return nil
            }
            return url
        }()
        let coverURL = recipeImageURL(recipe)
        let hasSourceURL = recipeSourceURL != nil
        let recipeInstructionCount = recipe.instructions.count
        let activeMinutes = recipe.activeTimeMinutes ?? recipe.prepTimeMinutes
        let inactiveMinutes = recipe.inactiveTimeMinutes ?? 0
        let recipeTimeText = recipe.cookingTime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? recipe.cookingTime!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (inactiveMinutes > 0 ? "主动\(activeMinutes)分 · 等待\(inactiveMinutes)分" : "\(activeMinutes) 分钟")
        let servingLabel = recipeServingSizeLabel(recipe)
        let recipeMealTypes = RecipeMealType.inferredList(mealTypes: recipe.mealTypes, tags: recipe.tags)
        let recipeTags = (recipe.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && RecipeMealType.normalized($0) == nil }
        let nutrientHighlights = libraryNutritionHighlights(
            sugar: recipe.sugar,
            sodium: recipe.sodium,
            addedSugar: recipe.addedSugar,
            satFat: recipe.satFat,
            cholesterol: recipe.cholesterol,
            potassium: recipe.potassium
        )
        let missingIngredientCount = recipe.missingIngredients?.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count ?? 0
        let recipeActionBusy = loggingSelectedSavedRecipes || deletingSelectedSavedRecipes || savingSelectedRecipesAsMeals || !loggingRecipeSuggestionId.isEmpty || !deletingRecipeSuggestionId.isEmpty || !savingRecipeAsMealId.isEmpty || !duplicatingRecipeSuggestionId.isEmpty || !favoritingRecipeSuggestionId.isEmpty
        return HStack(alignment: .center, spacing: 12) {
            if alwaysUseMultiAdd {
                Button {
                    toggleSavedRecipeSelection(item)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(selected ? Color(hex: "2563EB") : Color(hex: "A0A7B3"))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(recipeActionBusy)
                .accessibilityLabel(selected ? "取消选择食谱\(recipe.title)" : "选择食谱\(recipe.title)")
            }

            if let coverURL {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        ZStack {
                            LinearGradient(
                                colors: [Color(hex: "F4F6FA"), Color(hex: "ECFDF5")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "fork.knife.circle.fill")
                                .font(.system(size: 20, weight: .black))
                                .foregroundStyle(Color(hex: "16A34A"))
                        }
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "EEF0F4"), lineWidth: 1))
                .accessibilityLabel("食谱封面图")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(recipe.title)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    if (item.logged ?? 0) != 0 {
                        Text("已记过")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "2563EB"))
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color(hex: "EFF6FF"))
                            .clipShape(Capsule())
                    }
                    if (item.loggedCount ?? 0) > 0 {
                        useCountBadge(item.loggedCount ?? 0)
                    }
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "F59E0B"))
                            .accessibilityHidden(true)
                    }
                }
                Text("\(Int(round(recipe.calories))) 千卡/每份 · \(servingLabel) · 共 \(recipe.servings) 份 · \(recipeTimeText)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(libraryMacroLine(protein: recipe.protein, carbs: recipe.carbs, fat: recipe.fat, fiber: recipe.fiber))
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .lineLimit(1)
                if !nutrientHighlights.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(nutrientHighlights, id: \.self) { item in
                            libraryMetaChip(item, icon: "chart.bar.doc.horizontal")
                        }
                    }
                }
                if !recipe.ingredientsBreakdown.isEmpty {
                    Text(recipe.ingredientsBreakdown.prefix(3).map { $0.name }.joined(separator: "、"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "9CA3AF"))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    libraryMetaChip(librarySourceLabel(item.source ?? recipe.source, fallback: "我的食谱"), icon: "tag.fill")
                    libraryMetaChip(libraryDateStatusLabel(loggedAt: item.loggedAt, createdAt: item.createdAt), icon: "clock.fill")
                }
                if !recipeTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(recipeTags.prefix(3)), id: \.self) { tag in
                            libraryMetaChip(tag, icon: "number")
                        }
                    }
                }
                if !recipeMealTypes.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(recipeMealTypes.prefix(4)), id: \.self) { mealType in
                            libraryMetaChip("适用\(RecipeMealType.title(for: mealType))", icon: "fork.knife")
                        }
                    }
                }
                if recipeInstructionCount > 0 || hasSourceURL || missingIngredientCount > 0 {
                    HStack(spacing: 6) {
                        if missingIngredientCount > 0 {
                            libraryMetaChip("待匹配 \(missingIngredientCount)项", icon: "exclamationmark.triangle.fill")
                        }
                        if recipeInstructionCount > 0 {
                            libraryMetaChip("做法 \(recipeInstructionCount)步", icon: "list.number")
                        }
                        if hasSourceURL {
                            libraryMetaChip("原网页", icon: "link")
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    Task { await toggleRecipeFavorite(item) }
                } label: {
                    ZStack {
                        if isFavoriting {
                            ProgressView()
                                .scaleEffect(0.64)
                                .tint(Color(hex: "F59E0B"))
                        } else {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(isFavorite ? Color(hex: "F59E0B") : Color(hex: "111318"))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(recipeActionBusy)
                .accessibilityLabel(isFavorite ? "取消收藏食谱 \(recipe.title)" : "收藏食谱 \(recipe.title)")

                Menu {
                    Button {
                        selectedRecipeDetail = item
                    } label: {
                        Label("查看并编辑", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        Task { await toggleRecipeFavorite(item) }
                    } label: {
                        Label(isFavorite ? "取消收藏" : "收藏食谱", systemImage: isFavorite ? "star.slash" : "star")
                    }
                    Button {
                        Task { await duplicateSavedRecipe(item) }
                    } label: {
                        Label("复制食谱", systemImage: "doc.on.doc")
                    }
                    Button {
                        Task { await saveRecipeAsMeal(item) }
                    } label: {
                        Label("保存为餐品", systemImage: "tray.and.arrow.down")
                    }
                    if let recipeSourceURL {
                        Button {
                            openURL(recipeSourceURL)
                        } label: {
                            Label("打开原网页", systemImage: "safari")
                        }
                    }
                    Section("记录到其他餐次") {
                        ForEach(mealCategoryOptions, id: \.0) { option in
                            Button {
                                Task { await logSavedRecipe(item, mealCategory: option.0) }
                            } label: {
                                Label("加入\(option.1)", systemImage: option.2)
                            }
                        }
                    }
                    Section {
                        Button {
                            selectedSavedRecipePortionTarget = item
                        } label: {
                            Label("自定义份数", systemImage: "slider.horizontal.3")
                        }
                    }
                    Button(role: .destructive) {
                        pendingDeleteSavedRecipeId = item.id
                        pendingDeleteSavedRecipeTitle = item.recipe.title
                        showingDeleteSavedRecipeConfirmation = true
                    } label: {
                        Label("删除食谱", systemImage: "trash")
                    }
                } label: {
                    ZStack {
                        if isDuplicating || isSavingMeal || isDeleting {
                            ProgressView()
                                .scaleEffect(0.66)
                                .tint(Color(hex: "2563EB"))
                        } else {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .black))
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 30, height: 30)
                    .background(.white)
                    .clipShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .disabled(recipeActionBusy)
                .accessibilityLabel("更多食谱操作 \(recipe.title)")

                Button {
                    Task { await logSavedRecipe(item, mealCategory: selectedMealCategory) }
                } label: {
                    HStack(spacing: 5) {
                        if isLogging {
                            ProgressView()
                                .scaleEffect(0.68)
                                .tint(.white)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                        }
                        Text(isLogging ? "加入中" : "加入\(mealCategoryTitle(selectedMealCategory))")
                            .font(.system(size: 11, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(minWidth: 76)
                    .background(Color.black)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(recipeActionBusy)
                .accessibilityLabel("加入\(mealCategoryTitle(selectedMealCategory))：\(recipe.title)")
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await logSavedRecipe(item, mealCategory: selectedMealCategory) }
            } label: {
                Label("手动记", systemImage: "plus.circle.fill")
            }
            .tint(.black)
        }
    }

    private var messageCard: some View {
        let isError = infoMessageNeedsAttention(message)
        let isAdded = message.contains("已记录") || message.contains("已加入")
        let isSaved = message.contains("已保存") || message.contains("已新建") || message.contains("已复制")
        let title = isError ? "这次没完成" : (isAdded ? "已添加" : (isSaved ? "已保存" : "提示"))
        let icon = isError ? "exclamationmark.circle.fill" : (isAdded ? "checkmark.circle.fill" : "info.circle.fill")
        let accent = isError ? Color(hex: "DC2626") : (isAdded ? Color(hex: "16A34A") : Color(hex: "111318"))
        let displayMessage = infoFriendlyInlineMessage(message)

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.10))
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(displayMessage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isError ? Color(hex: "DC2626") : Color(hex: "4B5563"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isAdded {
                Button {
                    selectedInfoMode = "diary"
                } label: {
                    Text("查看日记")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看已添加到日记的食物")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(isError || isAdded ? 0.18 : 0.08), lineWidth: 1))
        .shadow(color: accent.opacity(isError || isAdded ? 0.08 : 0.04), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private var historyScroller: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("历史餐单")
                    .font(.system(size: 17, weight: .black))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(history, id: \.displayId) { item in
                            ZStack(alignment: .topTrailing) {
                                Button {
                                    plan = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.displayName)
                                            .font(.system(size: 13, weight: .black))
                                            .foregroundStyle(Color(hex: "111318"))
                                            .lineLimit(2)
                                        Text("\(Int(item.dailyTargets?.calories ?? item.dailyCalorieTarget ?? 0)) 千卡 · \(item.days.count) 天")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.secondary)
                                        Text(plan?.displayId == item.displayId ? "当前查看" : "点按查看")
                                            .font(.system(size: 10, weight: .black))
                                            .foregroundStyle(plan?.displayId == item.displayId ? Color(hex: "16A34A") : Color(hex: "9CA3AF"))
                                    }
                                    .frame(width: 158, alignment: .leading)
                                    .padding(12)
                                    .padding(.trailing, 18)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(plan?.displayId == item.displayId ? Color(hex: "16A34A").opacity(0.35) : Color(hex: "F0F0F3"), lineWidth: 1))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    Task { await deleteMealPlan(item) }
                                } label: {
                                    Image(systemName: deletingMealPlanId == item.displayId ? "hourglass" : "xmark")
                                        .font(.system(size: 10, weight: .black))
                                        .foregroundStyle(Color(hex: "EF4444"))
                                        .frame(width: 26, height: 26)
                                        .background(Color(hex: "FFF1F2"))
                                        .clipShape(Circle())
                                        .accessibilityHidden(true)
                                }
                                .buttonStyle(.plain)
                                .disabled(!deletingMealPlanId.isEmpty)
                                .accessibilityLabel("删除餐单 \(item.displayName)")
                                .padding(6)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyPlanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            Text("点上方生成一份餐单")
                .font(.system(size: 18, weight: .black))
            Text("会按你的目标、偏好和忌口安排每天吃什么，并带购物清单。")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .softCard(radius: 24)
    }

    private func planSummary(_ plan: MealPlanPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.displayName)
                        .font(.system(size: 20, weight: .black))
                    Text("\(Int(plan.dailyTargets?.calories ?? plan.dailyCalorieTarget ?? 0)) 千卡 · 蛋白 \(Int(plan.dailyTargets?.protein ?? 0))克 · \(plan.mealsPerDay ?? 3) 餐")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "list.clipboard")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                SmallPlanMetric(label: "天数", value: "\(plan.days.count)")
                SmallPlanMetric(label: "烹饪", value: "\(plan.prepTimeMinutes ?? safeInt(prepTime, 20)) 分")
                SmallPlanMetric(label: "来源", value: plan.source == "ai_enhanced" ? "更贴合今天" : "基础规则")
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private func planDays(_ plan: MealPlanPayload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("餐次安排")
                .font(.system(size: 20, weight: .black))
            ForEach(plan.days) { day in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.day)
                                .font(.system(size: 15, weight: .black))
                            Text("\(day.meals.count) 餐 · \(Int(round(day.meals.reduce(0) { $0 + $1.calories }))) 千卡")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await logPlanDay(day, groupTitle: "\(plan.displayName) · \(day.day)") }
                        } label: {
                            HStack(spacing: 5) {
                                if loggingPlanDayId == day.id {
                                    ProgressView()
                                        .scaleEffect(0.72)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .black))
                                        .accessibilityHidden(true)
                                }
                                Text(loggingPlanDayId == day.id ? "记录中" : "记录当天")
                                    .font(.system(size: 11, weight: .black))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(Color.black)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!loggingPlanDayId.isEmpty || !loggingMealId.isEmpty || !swappingMealId.isEmpty)
                        .accessibilityLabel("记录\(day.day)餐单")
                    }
                    MealPlanDayProgress(day: day, targets: plan.dailyTargets)
                    ForEach(day.meals) { meal in
                        MealPlanMealRow(
                            meal: meal,
                            isLogging: loggingMealId == meal.id,
                            isSwapping: swappingMealId == meal.id,
                            onLog: {
                                Task { await logMeal(meal, groupTitle: plan.displayName) }
                            },
                            onSwap: {
                                Task { await swapMeal(in: plan, day: day, meal: meal) }
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groceryCard(_ plan: MealPlanPayload) -> some View {
        if !plan.groceryList.isEmpty {
            let totalItems = plan.groceryList.reduce(0) { $0 + $1.items.count }
            let checkedCount = groceryCheckedCount(plan)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "basket.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("购物清单")
                            .font(.system(size: 18, weight: .black))
                        Text("\(plan.groceryList.count) 类 · \(totalItems) 项食材")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if checkedCount > 0 {
                        Button {
                            Task { await clearGroceryChecked(plan) }
                        } label: {
                            Text("清空")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(Color(hex: "4B5563"))
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!updatingGroceryItemKey.isEmpty)
                        .accessibilityLabel("清空购物清单勾选")
                    }
                    Button {
                        copyGroceryList(plan)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copiedGroceryPlanId == plan.displayId ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                            Text(copiedGroceryPlanId == plan.displayId ? "已复制" : "复制")
                                .font(.system(size: 11, weight: .black))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(Color.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制购物清单")
                }
                groceryProgressBar(checked: checkedCount, total: totalItems)
                ForEach(plan.groceryList) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.category)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(group.items, id: \.self) { item in
                                groceryItemButton(plan: plan, category: group.category, item: item)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .softCard(radius: 24)
        }
    }

    private func groceryItemButton(plan: MealPlanPayload, category: String, item: String) -> some View {
        let key = groceryItemKey(category: category, item: item)
        let checked = (plan.groceryCheckedItems ?? []).contains(key)
        let updating = updatingGroceryItemKey == key
        return Button {
            Task { await toggleGroceryItem(plan: plan, category: category, item: item) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: updating ? "hourglass" : (checked ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(checked ? Color(hex: "16A34A") : Color(hex: "9CA3AF"))
                    .accessibilityHidden(true)
                Text(item)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(checked ? Color(hex: "9CA3AF") : Color(hex: "4B5563"))
                    .strikethrough(checked, color: Color(hex: "9CA3AF"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(checked ? Color(hex: "F0FDF4") : Color(hex: "F7F8FA"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!updatingGroceryItemKey.isEmpty)
        .accessibilityLabel(checked ? "取消勾选\(item)" : "勾选\(item)")
    }

    private func groceryProgressBar(checked: Int, total: Int) -> some View {
        let safeTotal = max(total, 1)
        let progress = min(max(Double(checked) / Double(safeTotal), 0), 1)
        return VStack(spacing: 6) {
            HStack {
                Text("采购进度")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(checked)/\(total) 项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "4B5563"))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "EEF1F5"))
                    Capsule()
                        .fill(Color(hex: "16A34A"))
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 7)
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func planInput(icon: String, label: String, text: Binding<String>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .accessibilityHidden(true)
                Text(label)
            }
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(.secondary)
            TextField(label, text: text)
                .keyboardType(.numberPad)
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .onChange(of: text.wrappedValue) { _, newValue in
                    let clean = newValue.filter(\.isNumber)
                    let value = min(range.upperBound, max(range.lowerBound, Int(clean) ?? range.lowerBound))
                    if clean != newValue || String(value) != newValue {
                        text.wrappedValue = String(value)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func preferenceInput(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func loadInitialData() async {
        initialLoading = true
        async let summaryTask = APIClient.shared.getDailySummary()
        async let prefsTask = APIClient.shared.getUserPreferences()
        async let historyTask = APIClient.shared.getMealPlanHistory()
        async let collectionsTask = APIClient.shared.getMealPlanRecipeCollections(limit: 6)
        async let foodsTask = APIClient.shared.getFoods(days: 14)
        async let recipeTask = APIClient.shared.getIngredientRecipeSuggestions(limit: savedLibraryPageSize)
        async let savedMealsTask = APIClient.shared.getSavedMeals(limit: savedLibraryPageSize)
        async let savedFoodsTask = APIClient.shared.getSavedFoods(limit: savedLibraryPageSize)
        async let frequentFoodsTask = APIClient.shared.getFrequentFoods(limit: 12, mealCategory: savedFrequentMealFilterForRequest())
        async let diaryNoteTask = APIClient.shared.getDiaryNote(date: activeLogDate)
        async let macroGoalsTask = APIClient.shared.getMacroGoals()

        if let summary = try? await summaryTask {
            dailySummary = summary
            dailyCalories = "\(Int(summary.caloriesGoal))"
        }
        if let goals = try? await macroGoalsTask {
            macroGoals = goals
            mealShareDraft = normalizedMealShares(goals.mealShares)
        }
        if let prefs = try? await prefsTask {
            userPreferences = prefs
            prepTime = "\(prefs.prepTimeMinutes)"
            preferences = prefs.tasteTags.joined(separator: "，")
            avoid = prefs.avoidIngredients.joined(separator: "，")
            mealNamesDraft = normalizedMealNames(prefs.mealNames)
        }
        history = (try? await historyTask) ?? []
        recipeCollections = (try? await collectionsTask) ?? []
        recentFoods = (try? await foodsTask) ?? []
        recipeSuggestions = (try? await recipeTask) ?? []
        savedMeals = (try? await savedMealsTask) ?? []
        savedFoods = (try? await savedFoodsTask) ?? []
        frequentFoodItems = (try? await frequentFoodsTask) ?? []
        if let diaryNote = try? await diaryNoteTask {
            diaryNoteText = diaryNote.note
            savedDiaryNoteText = diaryNote.note
        }
        hasMoreSavedRecipes = recipeSuggestions.count >= savedLibraryPageSize
        hasMoreSavedMeals = savedMeals.count >= savedLibraryPageSize
        hasMoreSavedFoods = savedFoods.count >= savedLibraryPageSize
        initialLoading = false
    }

    private func refreshFoodStateAfterLogging() async {
        async let foodsTask = APIClient.shared.getFoods(days: 14)
        async let summaryTask = APIClient.shared.getDailySummary()
        async let recipeTask = APIClient.shared.getIngredientRecipeSuggestions(limit: savedLibraryPageSize)
        async let savedMealsTask = APIClient.shared.getSavedMeals(limit: savedLibraryPageSize)
        async let savedFoodsTask = APIClient.shared.getSavedFoods(limit: savedLibraryPageSize)
        async let frequentFoodsTask = APIClient.shared.getFrequentFoods(limit: 12, mealCategory: savedFrequentMealFilterForRequest())

        recentFoods = (try? await foodsTask) ?? recentFoods
        dailySummary = (try? await summaryTask) ?? dailySummary
        let nextRecipes = (try? await recipeTask) ?? recipeSuggestions
        let nextMeals = (try? await savedMealsTask) ?? savedMeals
        let nextFoods = (try? await savedFoodsTask) ?? savedFoods
        frequentFoodItems = (try? await frequentFoodsTask) ?? frequentFoodItems
        selectedFrequentFoodIds.formIntersection(Set(frequentFoods.map(\.id)))
        recipeSuggestions = nextRecipes
        savedMeals = nextMeals
        savedFoods = nextFoods
        hasMoreSavedRecipes = nextRecipes.count >= savedLibraryPageSize
        hasMoreSavedMeals = nextMeals.count >= savedLibraryPageSize
        hasMoreSavedFoods = nextFoods.count >= savedLibraryPageSize
        onChanged()
    }

    private func saveDiaryNote() async {
        guard !savingDiaryNote else { return }
        savingDiaryNote = true
        message = ""
        do {
            let saved = try await APIClient.shared.saveDiaryNote(date: activeLogDate, note: diaryNoteText)
            diaryNoteText = saved.note
            savedDiaryNoteText = saved.note
            message = saved.note.isEmpty ? "已清空日记备注。" : "日记备注已保存。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存日记备注失败")
        }
        savingDiaryNote = false
    }

    private func completeDiary() async {
        guard !completingDiary else { return }
        completingDiary = true
        message = ""
        do {
            let response = try await APIClient.shared.completeDiary(date: activeLogDate)
            if let summary = response.summary {
                dailySummary = summary
            }
            let projection = response.projection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = projection.isEmpty ? (response.message ?? "今日日记已保存。") : projection
        } catch {
            message = infoFriendlyError(error, fallback: "保存日记失败")
        }
        completingDiary = false
    }

    private func refreshFrequentFoodsFromServer() async {
        guard !loadingFrequentFoods else { return }
        loadingFrequentFoods = true
        let mealCategory = savedFrequentMealFilterForRequest()
        if let foods = try? await APIClient.shared.getFrequentFoods(limit: 12, mealCategory: mealCategory) {
            frequentFoodItems = foods
            selectedFrequentFoodIds.formIntersection(Set(frequentFoods.map(\.id)))
        }
        loadingFrequentFoods = false
    }

    private func refreshSavedLibraryFromServer() async {
        guard !loadingSavedLibrary else { return }
        loadingSavedLibrary = true
        if savedLibraryScope == "recent" {
            recentFoods = (try? await APIClient.shared.getFoods(days: 14)) ?? recentFoods
            loadingSavedLibrary = false
            return
        }
        if savedLibraryScope == "frequent" {
            frequentFoodItems = (try? await APIClient.shared.getFrequentFoods(limit: 12, mealCategory: savedFrequentMealFilterForRequest())) ?? frequentFoodItems
            selectedFrequentFoodIds.formIntersection(Set(frequentFoods.map(\.id)))
            loadingSavedLibrary = false
            return
        }
        let query = normalizedSavedLibraryQuery
        let sort = savedLibrarySort
        let mealCategory = savedMealCategoryFilterForRequest
        let recipeMealType = savedRecipeMealTypeFilterForRequest
        let recipeTag = savedRecipeTagFilterForRequest
        async let recipesTask = APIClient.shared.getIngredientRecipeSuggestions(
            limit: savedLibraryPageSize,
            query: query,
            sort: sort,
            favorite: savedLibraryScope == "recipe_favorite",
            imported: savedLibraryScope == "recipe_imported",
            mealType: recipeMealType,
            tag: recipeTag
        )
        async let mealsTask = APIClient.shared.getSavedMeals(
            limit: savedLibraryPageSize,
            query: query,
            sort: sort,
            mealCategory: mealCategory,
            favorite: savedLibraryScope == "meal_favorite"
        )
        async let foodsTask = APIClient.shared.getSavedFoods(limit: savedLibraryPageSize, query: query, sort: sort)
        let nextRecipes = (try? await recipesTask) ?? recipeSuggestions
        let nextMeals = (try? await mealsTask) ?? savedMeals
        let nextFoods = (try? await foodsTask) ?? savedFoods
        recipeSuggestions = nextRecipes
        savedMeals = nextMeals
        savedFoods = nextFoods
        hasMoreSavedRecipes = nextRecipes.count >= savedLibraryPageSize
        hasMoreSavedMeals = nextMeals.count >= savedLibraryPageSize
        hasMoreSavedFoods = nextFoods.count >= savedLibraryPageSize
        loadingSavedLibrary = false
    }

    private func searchSavedLibraryAndDatabase() async {
        let query = normalizedSavedLibraryQuery
        await refreshSavedLibraryFromServer()
        guard !query.isEmpty else { return }
        guard savedLibraryScope == "all" || savedLibraryScope == "food" else { return }
        searchQuery = query
        await searchFoodDatabase()
    }

    private func refreshVisibleInfoPage() async {
        if selectedInfoMode == "plan" {
            await refreshSavedLibraryFromServer()
            if let nextHistory = try? await APIClient.shared.getMealPlanHistory() {
                history = nextHistory
            }
            if let nextCollections = try? await APIClient.shared.getMealPlanRecipeCollections(limit: 6) {
                recipeCollections = nextCollections
            }
        } else {
            await refreshFoodStateAfterLogging()
        }
    }

    private func syncSavedLibraryAfterMutation() {
        Task {
            await refreshSavedLibraryFromServer()
            if let nextCollections = try? await APIClient.shared.getMealPlanRecipeCollections(limit: 6) {
                recipeCollections = nextCollections
            }
        }
    }

    private func upsertSavedMeal(_ meal: SavedMealItem) {
        let normalizedTitle = meal.title.casefoldedForMealMatching
        savedMeals.removeAll { existing in
            existing.id == meal.id || (!normalizedTitle.isEmpty && existing.title.casefoldedForMealMatching == normalizedTitle)
        }
        savedMeals.insert(meal, at: 0)
    }

    private func upsertRecipeSuggestion(_ item: IngredientRecipeHistoryItem) {
        let normalizedTitle = item.recipe.title.casefoldedForMealMatching
        recipeSuggestions.removeAll { existing in
            existing.id == item.id || (!normalizedTitle.isEmpty && existing.recipe.title.casefoldedForMealMatching == normalizedTitle)
        }
        recipeSuggestions.insert(item, at: 0)
    }

    private func loadMoreSavedLibrary() async {
        guard !loadingMoreSavedLibrary else { return }
        guard canLoadMoreSavedLibrary else { return }
        loadingMoreSavedLibrary = true
        let query = normalizedSavedLibraryQuery
        let sort = savedLibrarySort
        let mealCategory = savedMealCategoryFilterForRequest
        let recipeMealType = savedRecipeMealTypeFilterForRequest
        let recipeTag = savedRecipeTagFilterForRequest
        do {
            if (savedLibraryScope == "all" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported") && hasMoreSavedRecipes {
                let moreRecipes = try await APIClient.shared.getIngredientRecipeSuggestions(
                    limit: savedLibraryPageSize,
                    query: query,
                    sort: sort,
                    offset: filteredRecipeSuggestions.count,
                    favorite: savedLibraryScope == "recipe_favorite",
                    imported: savedLibraryScope == "recipe_imported",
                    mealType: recipeMealType,
                    tag: recipeTag
                )
                recipeSuggestions = mergeUniqueRecipes(recipeSuggestions, moreRecipes)
                hasMoreSavedRecipes = moreRecipes.count >= savedLibraryPageSize
            }
            if (savedLibraryScope == "all" || savedLibraryScope == "meal" || savedLibraryScope == "meal_favorite") && hasMoreSavedMeals {
                let moreMeals = try await APIClient.shared.getSavedMeals(
                    limit: savedLibraryPageSize,
                    query: query,
                    sort: sort,
                    offset: filteredSavedMeals.count,
                    mealCategory: mealCategory,
                    favorite: savedLibraryScope == "meal_favorite"
                )
                savedMeals = mergeUniqueSavedMeals(savedMeals, moreMeals)
                hasMoreSavedMeals = moreMeals.count >= savedLibraryPageSize
            }
            if (savedLibraryScope == "all" || savedLibraryScope == "food") && hasMoreSavedFoods {
                let moreFoods = try await APIClient.shared.getSavedFoods(
                    limit: savedLibraryPageSize,
                    query: query,
                    sort: sort,
                    offset: filteredSavedFoods.count
                )
                savedFoods = mergeUniqueSavedFoods(savedFoods, moreFoods)
                hasMoreSavedFoods = moreFoods.count >= savedLibraryPageSize
            }
            resetSavedLibraryExpansion()
        } catch {
            message = infoFriendlyError(error, fallback: "加载更多失败")
        }
        loadingMoreSavedLibrary = false
    }

    private func mergeUniqueSavedFoods(_ current: [SavedFoodItem], _ incoming: [SavedFoodItem]) -> [SavedFoodItem] {
        var seen = Set(current.map(\.id))
        var merged = current
        for item in incoming where !seen.contains(item.id) {
            merged.append(item)
            seen.insert(item.id)
        }
        return sortSavedFoods(merged)
    }

    private func mergeUniqueSavedMeals(_ current: [SavedMealItem], _ incoming: [SavedMealItem]) -> [SavedMealItem] {
        var seen = Set(current.map(\.id))
        var merged = current
        for item in incoming where !seen.contains(item.id) {
            merged.append(item)
            seen.insert(item.id)
        }
        return sortSavedMeals(merged)
    }

    private func mergeUniqueRecipes(_ current: [IngredientRecipeHistoryItem], _ incoming: [IngredientRecipeHistoryItem]) -> [IngredientRecipeHistoryItem] {
        var seen = Set(current.map(\.id))
        var merged = current
        for item in incoming where !seen.contains(item.id) {
            merged.append(item)
            seen.insert(item.id)
        }
        return sortRecipeSuggestions(merged)
    }

    private func resetSavedLibraryExpansion() {
        expandedSavedFoods = false
        expandedSavedMeals = false
        expandedSavedRecipes = false
        expandedRecentIndividualFoods = false
        clearMultiAddSelections()
    }

    private func clearMultiAddSelections() {
        selectedSearchFoodIds.removeAll()
        selectedFrequentFoodIds.removeAll()
        selectedSavedFoodIds.removeAll()
        selectedSavedMealIds.removeAll()
        selectedSavedRecipeIds.removeAll()
    }

    private func applyRecipeCollectionFilter(_ collection: MealPlanRecipeCollection) {
        savedLibraryScope = "recipe"
        savedLibraryQuery = ""
        savedLibrarySort = "created"
        savedRecipeTagFilter = recipeCollectionTagFilter(collection)
        savedLibraryMealCategoryFilter = recipeCollectionMealTypeFilter(collection)
        showAllMealCategoriesInSavedLibrary = savedLibraryMealCategoryFilter == "all"
        expandedSavedRecipes = true
        clearMultiAddSelections()
        message = "已筛选\(collection.title)。"
        Task { await refreshSavedLibraryFromServer() }
    }

    private func recipeCollectionTagFilter(_ collection: MealPlanRecipeCollection) -> String {
        switch collection.id {
        case "high_protein":
            return "high_protein"
        case "low_carb":
            return "low_carb"
        case "under_500":
            return "low_calorie"
        default:
            return "all"
        }
    }

    private func recipeCollectionMealTypeFilter(_ collection: MealPlanRecipeCollection) -> String {
        switch collection.id {
        case "breakfast", "lunch", "dinner", "snack":
            return collection.id
        default:
            return "all"
        }
    }

    private func multiAddSelection(_ current: Set<String>, adding ids: Set<String>) -> Set<String> {
        let additions = Array(ids.subtracting(current))
        guard !additions.isEmpty else { return current }
        let currentGroupCount = current.count
        let selectedOutsideCurrentGroup = max(0, totalMultiAddCount - currentGroupCount)
        let remaining = maximumMultiAddItems - selectedOutsideCurrentGroup - currentGroupCount
        guard remaining > 0 else {
            message = "已达到每次项目可以添加的最大数量。"
            return current
        }
        var updated = current
        if additions.count > remaining {
            updated.formUnion(additions.prefix(remaining))
            message = "已达到每次项目可以添加的最大数量。"
        } else {
            updated.formUnion(additions)
        }
        return updated
    }

    private func clearSavedLibraryFilters() {
        savedLibraryScope = "all"
        savedLibraryQuery = ""
        savedLibraryMealCategoryFilter = "all"
        savedRecipeTagFilter = "all"
        showAllMealCategoriesInSavedLibrary = true
        savedLibrarySort = "created"
        resetSavedLibraryExpansion()
        message = "已显示最近、常用、我的食物、餐品和食谱。"
        Task { await refreshSavedLibraryFromServer() }
    }

    private func generatePlan() async {
        loading = true
        message = ""
        do {
            let generated = try await APIClient.shared.generateMealPlan(
                dailyCalories: safeInt(dailyCalories, 2000),
                days: safeInt(days, 3),
                goalType: goalType,
                mealsPerDay: safeInt(mealsPerDay, 3),
                prepTimeMinutes: safeInt(prepTime, 20),
                preferences: preferences,
                avoidIngredients: textToList(avoid)
            )
            plan = generated
            history = [generated] + history.filter { $0.displayId != generated.displayId }
            history = Array(history.prefix(3))
            message = "餐单已做好并保存。"
        } catch {
            message = infoFriendlyError(error, fallback: "餐单暂时没做好")
        }
        loading = false
    }

    private func deleteMealPlan(_ target: MealPlanPayload) async {
        guard deletingMealPlanId.isEmpty else { return }
        deletingMealPlanId = target.displayId
        message = ""
        do {
            _ = try await APIClient.shared.deleteMealPlan(planId: target.displayId)
            history.removeAll { $0.displayId == target.displayId }
            if plan?.displayId == target.displayId {
                plan = history.first
            }
            message = "已删除餐单：\(target.displayName)。"
        } catch {
            message = infoFriendlyError(error, fallback: "删除餐单失败")
        }
        deletingMealPlanId = ""
    }

    private func logMeal(_ meal: MealPlanMeal, groupTitle: String) async {
        loggingMealId = meal.id
        message = ""
        do {
            let item = foodItemFromPlanMeal(meal)
            let response = try await APIClient.shared.logFoods(
                [item],
                mealCategory: mealCategoryForPlanMeal(meal),
                groupTitle: groupTitle,
                date: activeLogDate
            )
            message = "已记录 \(response.saved ?? 1) 项：\(meal.name)。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "记录失败")
        }
        loggingMealId = ""
    }

    private func logPlanDay(_ day: MealPlanDay, groupTitle: String) async {
        guard loggingPlanDayId.isEmpty else { return }
        loggingPlanDayId = day.id
        message = ""
        var savedCount = 0
        do {
            for meal in day.meals {
                let response = try await APIClient.shared.logFoods(
                    [foodItemFromPlanMeal(meal)],
                    mealCategory: mealCategoryForPlanMeal(meal),
                    groupTitle: groupTitle,
                    date: activeLogDate
                )
                savedCount += response.saved ?? 1
            }
            message = "已记录\(day.day)餐单：\(savedCount) 项。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "记录当天餐单失败")
        }
        loggingPlanDayId = ""
    }

    private func logSavedRecipe(_ item: IngredientRecipeHistoryItem, mealCategory: String? = nil, portionMultiplier: Double = 1, date: String? = nil) async {
        guard loggingRecipeSuggestionId.isEmpty, deletingRecipeSuggestionId.isEmpty, savingRecipeAsMealId.isEmpty, duplicatingRecipeSuggestionId.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        let multiplier = max(0.05, min(20.0, portionMultiplier))
        let targetDate = (date ?? activeLogDate).trimmingCharacters(in: .whitespacesAndNewlines)
        loggingRecipeSuggestionId = item.id
        message = ""
        do {
            let response = try await APIClient.shared.logIngredientRecipe(
                id: item.id,
                portionMultiplier: multiplier,
                servingSizeLabel: recipeServingSizeLabelForLog(item.recipe, multiplier: multiplier),
                mealCategory: targetMealCategory,
                date: targetDate
            )
            let portionLabel = multiplier == 1 ? "" : " \(formatMacro(multiplier))份"
            let datePrefix = targetDate == activeLogDate ? "" : "\(displayDateLabel(targetDate)) · "
            message = "已记录食谱到\(datePrefix)\(mealCategoryTitle(targetMealCategory))：\(item.recipe.title)\(portionLabel)。"
            if response.saved == 0 {
                message = "食谱已记到今天。"
            }
            if targetDate == activeLogDate {
                selectedMealCategory = targetMealCategory
                await refreshFoodStateAfterLogging()
            }
        } catch {
            message = infoFriendlyError(error, fallback: "记录食谱失败")
        }
        loggingRecipeSuggestionId = ""
    }

    private func logSavedRecipeDates(_ item: IngredientRecipeHistoryItem, mealCategory: String? = nil, portionMultiplier: Double = 1, servingSizeLabel: String? = nil, dates: [String]) async {
        guard loggingRecipeSuggestionId.isEmpty, deletingRecipeSuggestionId.isEmpty, savingRecipeAsMealId.isEmpty, duplicatingRecipeSuggestionId.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        let multiplier = max(0.05, min(20.0, portionMultiplier))
        let labelForLog = (servingSizeLabel ?? recipeServingSizeLabelForLog(item.recipe, multiplier: multiplier)).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDates = cleanedDateSequence(dates)
        loggingRecipeSuggestionId = item.id
        message = ""
        var savedCount = 0
        do {
            for date in targetDates {
                let response = try await APIClient.shared.logIngredientRecipe(
                    id: item.id,
                    portionMultiplier: multiplier,
                    servingSizeLabel: labelForLog.isEmpty ? recipeServingSizeLabelForLog(item.recipe, multiplier: multiplier) : labelForLog,
                    mealCategory: targetMealCategory,
                    date: date
                )
                savedCount += response.saved ?? 1
            }
            message = multiDayLogMessage(
                name: item.recipe.title,
                kind: "食谱",
                mealCategory: targetMealCategory,
                portionMultiplier: multiplier,
                dates: targetDates,
                savedCount: savedCount
            )
            if targetDates.contains(activeLogDate) {
                selectedMealCategory = targetMealCategory
                await refreshFoodStateAfterLogging()
            }
        } catch {
            message = infoFriendlyError(error, fallback: "记录食谱失败")
        }
        loggingRecipeSuggestionId = ""
    }

    private func deleteSavedRecipe(_ item: IngredientRecipeHistoryItem) async {
        guard !deletingSelectedSavedRecipes, deletingRecipeSuggestionId.isEmpty, loggingRecipeSuggestionId.isEmpty, savingRecipeAsMealId.isEmpty, duplicatingRecipeSuggestionId.isEmpty else { return }
        deletingRecipeSuggestionId = item.id
        message = ""
        do {
            _ = try await APIClient.shared.deleteIngredientRecipeSuggestion(id: item.id)
            recipeSuggestions.removeAll { $0.id == item.id }
            syncSavedLibraryAfterMutation()
            message = "已删除食谱：\(item.recipe.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "删除食谱失败")
        }
        deletingRecipeSuggestionId = ""
    }

    private func toggleRecipeFavorite(_ item: IngredientRecipeHistoryItem) async {
        guard favoritingRecipeSuggestionId.isEmpty, deletingRecipeSuggestionId.isEmpty, loggingRecipeSuggestionId.isEmpty, savingRecipeAsMealId.isEmpty, duplicatingRecipeSuggestionId.isEmpty else { return }
        favoritingRecipeSuggestionId = item.id
        message = ""
        do {
            let response = try await APIClient.shared.toggleIngredientRecipeFavorite(id: item.id)
            let updated = response.item ?? IngredientRecipeHistoryItem(
                id: response.recipeId ?? item.id,
                date: item.date,
                source: item.source,
                logged: item.logged,
                createdAt: item.createdAt,
                loggedAt: item.loggedAt,
                loggedCount: item.loggedCount,
                recipe: response.recipe
            )
            upsertRecipeSuggestion(updated)
            message = (updated.recipe.favorite == true) ? "已收藏食谱：\(updated.recipe.title)。" : "已取消收藏：\(updated.recipe.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "更新收藏失败")
        }
        favoritingRecipeSuggestionId = ""
    }

    private func duplicateSavedRecipe(_ item: IngredientRecipeHistoryItem) async {
        guard duplicatingRecipeSuggestionId.isEmpty, loggingRecipeSuggestionId.isEmpty, deletingRecipeSuggestionId.isEmpty, savingRecipeAsMealId.isEmpty, favoritingRecipeSuggestionId.isEmpty else { return }
        duplicatingRecipeSuggestionId = item.id
        message = ""
        do {
            let response = try await APIClient.shared.createIngredientRecipeSuggestion(
                recipePayload: duplicatedRecipePayload(item.recipe),
                date: activeLogDate,
                source: item.recipe.source.isEmpty ? "manual" : item.recipe.source
            )
            let duplicated = response.item ?? IngredientRecipeHistoryItem(
                id: response.recipeId ?? response.recipe.id,
                date: activeLogDate,
                source: item.recipe.source,
                logged: 0,
                createdAt: nil,
                loggedAt: nil,
                loggedCount: 0,
                recipe: response.recipe
            )
            upsertRecipeSuggestion(duplicated)
            savedLibraryScope = "recipe"
            syncSavedLibraryAfterMutation()
            message = "已复制食谱：\(duplicated.recipe.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "复制食谱失败")
        }
        duplicatingRecipeSuggestionId = ""
    }

    private func duplicatedRecipePayload(_ recipe: IngredientRecipeSuggestion) -> [String: Any] {
        var ingredients: [[String: Any]] = []
        for ingredient in recipe.ingredientsBreakdown {
            var payload: [String: Any] = [
                "name": ingredient.name,
                "amount": ingredient.amount,
                "calories": ingredient.calories,
                "protein": ingredient.protein,
                "carbs": ingredient.carbs ?? 0,
                "fat": ingredient.fat ?? 0,
                "sugar": ingredient.sugar ?? 0,
            ]
            if let displayAmount = ingredient.displayAmount { payload["display_amount"] = displayAmount }
            if let servingSize = ingredient.servingSize { payload["serving_size"] = servingSize }
            if let processingLevel = ingredient.processingLevel { payload["processing_level"] = processingLevel }
            ingredients.append(payload)
        }
        var data: [String: Any] = [
            "title": "\(recipe.title) 副本",
            "servings": recipe.servings,
            "serving_size_label": recipeServingSizeLabel(recipe),
            "serving_sizes": recipeServingSizeOptionsPayload(recipeServingSizeOptions(for: recipe)),
            "calories": recipe.calories,
            "protein": recipe.protein,
            "carbs": recipe.carbs,
            "fat": recipe.fat,
            "fiber": recipe.fiber,
            "sodium": recipe.sodium,
            "sugar": recipe.sugar ?? 0,
            "prep_time_minutes": recipe.prepTimeMinutes,
            "active_time_minutes": recipe.activeTimeMinutes ?? recipe.prepTimeMinutes,
            "inactive_time_minutes": recipe.inactiveTimeMinutes ?? 0,
            "reason": recipe.reason,
            "instructions": recipe.instructions,
            "ingredients_breakdown": ingredients,
            "missing_ingredients": recipe.missingIngredients ?? [],
            "source": recipe.source,
            "tags": (recipe.tags ?? []) + ["副本"],
            "meal_types": RecipeMealType.inferredList(mealTypes: recipe.mealTypes, tags: recipe.tags)
        ]
        if let sourceURL = recipe.sourceURL, !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data["source_url"] = sourceURL
        }
        if let cookingTime = recipe.cookingTime, !cookingTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data["cooking_time"] = cookingTime
        }
        if let imageURL = recipe.imageURL, !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data["image_url"] = imageURL
        }
        data.merge(recipeExtendedNutritionPayload(recipe), uniquingKeysWith: { _, new in new })
        return data
    }

    private func saveRecipeAsMeal(_ item: IngredientRecipeHistoryItem) async {
        guard savingRecipeAsMealId.isEmpty, loggingRecipeSuggestionId.isEmpty, deletingRecipeSuggestionId.isEmpty, duplicatingRecipeSuggestionId.isEmpty else { return }
        savingRecipeAsMealId = item.id
        message = ""
        do {
            let food = foodItemFromRecipe(item.recipe)
            let recipeCover = item.recipe.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let matchingMeal = savedMeals.first { $0.title.casefoldedForMealMatching == item.recipe.title.casefoldedForMealMatching }
            let meal: SavedMealItem
            if let matchingMeal {
                let mealCover = (matchingMeal.imageUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                meal = try await APIClient.shared.updateSavedMeal(
                    id: matchingMeal.id,
                    title: matchingMeal.title,
                    foods: [food],
                    mealCategory: selectedMealCategory,
                    imageUrl: mealCover.isEmpty ? recipeCover : mealCover,
                    note: item.recipe.reason,
                    instructions: item.recipe.instructions
                )
            } else {
                meal = try await APIClient.shared.saveMealTemplate(
                    title: item.recipe.title,
                    foods: [food],
                    mealCategory: selectedMealCategory,
                    imageUrl: recipeCover,
                    note: item.recipe.reason,
                    instructions: item.recipe.instructions
                )
            }
            upsertSavedMeal(meal)
            if savedLibraryScope == "food" || savedLibraryScope == "recipe" || savedLibraryScope == "recipe_favorite" || savedLibraryScope == "recipe_imported" {
                savedLibraryScope = "meal"
            }
            syncSavedLibraryAfterMutation()
            message = matchingMeal == nil ? "已保存为我的餐品：\(meal.title)。" : "已替换同名餐品：\(meal.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存为餐品失败")
        }
        savingRecipeAsMealId = ""
    }

    private func saveSelectedRecipesAsMeals() async {
        guard !savingSelectedRecipesAsMeals else { return }
        let selected = selectedSavedRecipes
        guard !selected.isEmpty else { return }
        savingSelectedRecipesAsMeals = true
        message = ""
        var savedCount = 0
        var replacedCount = 0
        do {
            for item in selected {
                let recipeCover = item.recipe.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let matchingMeal = savedMeals.first { $0.title.casefoldedForMealMatching == item.recipe.title.casefoldedForMealMatching }
                let meal: SavedMealItem
                if let matchingMeal {
                    let mealCover = (matchingMeal.imageUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    meal = try await APIClient.shared.updateSavedMeal(
                        id: matchingMeal.id,
                        title: matchingMeal.title,
                        foods: [foodItemFromRecipe(item.recipe)],
                        mealCategory: selectedMealCategory,
                        imageUrl: mealCover.isEmpty ? recipeCover : mealCover,
                        note: item.recipe.reason,
                        instructions: item.recipe.instructions
                    )
                    replacedCount += 1
                } else {
                    meal = try await APIClient.shared.saveMealTemplate(
                        title: item.recipe.title,
                        foods: [foodItemFromRecipe(item.recipe)],
                        mealCategory: selectedMealCategory,
                        imageUrl: recipeCover,
                        note: item.recipe.reason,
                        instructions: item.recipe.instructions
                    )
                }
                upsertSavedMeal(meal)
                savedCount += 1
            }
            selectedSavedRecipeIds.removeAll()
            savedLibraryScope = "meal"
            syncSavedLibraryAfterMutation()
            message = replacedCount > 0 ? "已保存 \(savedCount) 个食谱到我的餐品，其中替换 \(replacedCount) 个同名餐品。" : "已保存 \(savedCount) 个食谱到我的餐品。"
        } catch {
            message = infoFriendlyError(error, fallback: "批量保存餐品失败")
        }
        savingSelectedRecipesAsMeals = false
    }

    private func foodItemFromRecipe(_ recipe: IngredientRecipeSuggestion) -> FoodItem {
        var item = FoodItem(
            name: recipe.title,
            calories: recipe.calories,
            protein: recipe.protein,
            carbs: recipe.carbs,
            fat: recipe.fat,
            fiber: recipe.fiber,
            sugar: recipe.sugar ?? 0,
            sodium: recipe.sodium,
            servingSize: "1份",
            processingLevel: "prepared",
            addedSugar: recipe.addedSugar ?? recipe.sugar ?? 0
        )
        item.satFat = recipe.satFat ?? 0
        item.transFat = recipe.transFat ?? 0
        item.cholesterol = recipe.cholesterol ?? 0
        item.vitaminA = recipe.vitaminA ?? 0
        item.vitaminC = recipe.vitaminC ?? 0
        item.calcium = recipe.calcium ?? 0
        item.iron = recipe.iron ?? 0
        item.potassium = recipe.potassium ?? 0
        return item
    }

    private func foodItemFromPlanMeal(_ meal: MealPlanMeal) -> FoodItem {
        var item = FoodItem(
            name: meal.name,
            calories: meal.calories,
            protein: meal.protein,
            carbs: meal.carbs,
            fat: meal.fat,
            fiber: meal.fiber ?? 0,
            sugar: meal.sugar ?? 0,
            sodium: meal.sodium ?? 0,
            servingSize: "1份",
            processingLevel: meal.source == "ai_enhanced" ? "prepared" : "whole",
            addedSugar: meal.sugar ?? 0
        )
        if !logDate.isEmpty {
            item.date = logDate
        }
        return item
    }

    private func mealCategoryForPlanMeal(_ meal: MealPlanMeal) -> String {
        let combined = [meal.mealType, meal.label].compactMap { $0 }.joined(separator: " ")
        return normalizedMealCategory(combined)
    }

    private func swapMeal(in sourcePlan: MealPlanPayload, day: MealPlanDay, meal: MealPlanMeal) async {
        guard swappingMealId.isEmpty else { return }
        swappingMealId = meal.id
        message = ""
        do {
            let response = try await APIClient.shared.swapMeal(
                planId: sourcePlan.displayId,
                day: day.day,
                meal: meal,
                dailyTargets: sourcePlan.dailyTargets,
                preferences: preferences,
                avoidIngredients: textToList(avoid)
            )
            let swapped = response.meal
            if let persistedPlan = response.plan {
                plan = persistedPlan
                history = history.map { $0.displayId == persistedPlan.displayId ? persistedPlan : $0 }
            } else {
                var updated = sourcePlan
                for dayIndex in updated.days.indices where updated.days[dayIndex].day == day.day {
                    for mealIndex in updated.days[dayIndex].meals.indices where updated.days[dayIndex].meals[mealIndex].id == meal.id {
                        updated.days[dayIndex].meals[mealIndex] = swapped
                        break
                    }
                }
                plan = updated
                history = history.map { $0.displayId == updated.displayId ? updated : $0 }
            }
            message = "已替换为：\(swapped.name)。"
        } catch {
            message = infoFriendlyError(error, fallback: "换餐失败")
        }
        swappingMealId = ""
    }

    private func searchFoodDatabase() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchingFoods = true
        message = ""
        selectedSearchFoodIds.removeAll()
        searchResultsVisibleLimit = 5
        do {
            searchResults = try await APIClient.shared.searchFoods(query: query)
            rememberSearchTerm(query)
            message = searchResults.isEmpty ? "没搜到“\(query)”。删掉品牌或口味再搜，找不到就创建食物。" : "找到 \(searchResults.count) 项食物。"
        } catch {
            searchResults = []
            rememberSearchTerm(query)
            message = infoFriendlyError(error, fallback: "搜索失败")
        }
        searchingFoods = false
    }

    private func loadRecentSearchTerms() {
        recentSearchTerms = UserDefaults.standard.stringArray(forKey: recentSearchTermsKey) ?? []
    }

    private func rememberSearchTerm(_ rawTerm: String) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        var terms = recentSearchTerms
        terms.removeAll {
            $0.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        terms.insert(term, at: 0)
        if terms.count > 8 {
            terms = Array(terms.prefix(8))
        }
        recentSearchTerms = terms
        UserDefaults.standard.set(terms, forKey: recentSearchTermsKey)
    }

    private func logDatabaseFood(_ food: FoodItem) async {
        await logFoodItem(food, groupTitle: mealCategoryTitle(selectedMealCategory))
    }

    private func toggleSearchFoodSelection(_ food: FoodItem) {
        if selectedSearchFoodIds.contains(food.id) {
            selectedSearchFoodIds.remove(food.id)
        } else {
            selectedSearchFoodIds = multiAddSelection(selectedSearchFoodIds, adding: [food.id])
        }
    }

    private func toggleFrequentFoodSelection(_ food: FrequentFood) {
        if selectedFrequentFoodIds.contains(food.id) {
            selectedFrequentFoodIds.remove(food.id)
        } else {
            selectedFrequentFoodIds = multiAddSelection(selectedFrequentFoodIds, adding: [food.id])
        }
    }

    private func logSelectedSearchFoods() async {
        guard !loggingSelectedSearchFoods else { return }
        let foods = selectedSearchFoods
        guard !foods.isEmpty else { return }
        loggingSelectedSearchFoods = true
        message = ""
        do {
            var items = foods
            for index in items.indices {
                items[index].date = activeLogDate
            }
            let response = try await APIClient.shared.logFoods(
                items,
                mealCategory: selectedMealCategory,
                groupTitle: "\(mealCategoryTitle(selectedMealCategory))批量添加",
                date: activeLogDate
            )
            message = "已加入\(mealCategoryTitle(selectedMealCategory))：\(response.saved ?? items.count) 项。"
            selectedSearchFoodIds.removeAll()
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "批量添加失败")
        }
        loggingSelectedSearchFoods = false
    }

    private func logSelectedFrequentFoods() async {
        guard !loggingSelectedFrequentFoods else { return }
        var items = selectedFrequentFoods.map(\.foodItem)
        guard !items.isEmpty else { return }
        loggingSelectedFrequentFoods = true
        message = ""
        do {
            for index in items.indices {
                items[index].date = activeLogDate
            }
            let response = try await APIClient.shared.logFoods(
                items,
                mealCategory: selectedMealCategory,
                groupTitle: "\(mealCategoryTitle(selectedMealCategory))常吃添加",
                date: activeLogDate
            )
            message = "已加入\(mealCategoryTitle(selectedMealCategory))：\(response.saved ?? items.count) 项常吃食物。"
            selectedFrequentFoodIds.removeAll()
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "批量添加常吃食物失败")
        }
        loggingSelectedFrequentFoods = false
    }

    private func saveSelectedSearchFoodsAsTemplates() async {
        guard !savingSelectedSearchFoodsAsTemplates else { return }
        let foods = selectedSearchFoods
        guard !foods.isEmpty else { return }
        savingSelectedSearchFoodsAsTemplates = true
        message = ""
        var savedCount = 0
        do {
            for food in foods {
                let saved = try await APIClient.shared.saveFoodTemplate(food)
                savedFoods.removeAll { $0.id == saved.id || $0.food.name == saved.food.name }
                savedFoods.insert(saved, at: 0)
                savedCount += 1
            }
            selectedSearchFoodIds.removeAll()
            savedLibraryScope = "food"
            selectedSavedFoodIds.removeAll()
            message = "已收藏 \(savedCount) 个食物到我的食物。"
        } catch {
            message = infoFriendlyError(error, fallback: "批量收藏失败")
        }
        savingSelectedSearchFoodsAsTemplates = false
    }

    private func logFoodItem(_ food: FoodItem, groupTitle: String, mealCategory: String? = nil) async {
        guard loggingFoodId.isEmpty else { return }
        loggingFoodId = food.id
        message = ""
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        selectedMealCategory = targetMealCategory
        do {
            var item = food
            if !logDate.isEmpty {
                item.date = logDate
            }
            let response = try await APIClient.shared.logFoods(
                [item],
                mealCategory: targetMealCategory,
                groupTitle: groupTitle,
                date: activeLogDate
            )
            message = "已记录到\(mealCategoryTitle(targetMealCategory))：\(response.saved ?? 1) 项 \(food.name)。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "记录失败")
        }
        loggingFoodId = ""
    }

    private func copyPreviousMealCategory(_ key: String, title: String) async {
        guard copyingMealCategory.isEmpty else { return }
        copyingMealCategory = key
        message = ""
        do {
            let historyRows = try await APIClient.shared.getFoods(date: activeLogDate, days: 30)
            let matchingRows = historyRows.filter { row in
                let rowDate = (row.date ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return normalizedMealCategory(row.mealCategory) == key && !rowDate.isEmpty && rowDate != activeLogDate
            }
            guard let sourceDate = matchingRows.map({ $0.date ?? "" }).max() else {
                message = "近 30 天没有可复制的\(title)记录。"
                copyingMealCategory = ""
                return
            }
            let sourceRows = matchingRows
                .filter { ($0.date ?? "") == sourceDate }
                .sorted { ($0.loggedAt ?? "") < ($1.loggedAt ?? "") }
            guard !sourceRows.isEmpty else {
                message = "近 30 天没有可复制的\(title)记录。"
                copyingMealCategory = ""
                return
            }
            var items = sourceRows.map(foodItemFromLogRow)
            for index in items.indices {
                items[index].date = activeLogDate
            }
            let response = try await APIClient.shared.logFoods(
                items,
                mealCategory: key,
                groupTitle: "复制\(displayDateLabel(sourceDate))\(title)",
                date: activeLogDate
            )
            selectedMealCategory = key
            message = "已复制\(displayDateLabel(sourceDate))\(title)：\(response.saved ?? items.count) 项。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "复制餐次失败")
        }
        copyingMealCategory = ""
    }

    private func copyMealCategory(_ key: String, title: String, to targetDate: String, targetLabel: String? = nil) async {
        guard copyingMealCategory.isEmpty else { return }
        let rows = rowsForMealCategory(key)
        guard !rows.isEmpty else {
            message = "\(title)还没有可复制的食物。"
            return
        }
        copyingMealCategory = key
        message = ""
        do {
            var items = rows.map(foodItemFromLogRow)
            for index in items.indices {
                items[index].date = targetDate
            }
            let response = try await APIClient.shared.logFoods(
                items,
                mealCategory: key,
                groupTitle: "复制\(title)",
                date: targetDate
            )
            let label = targetLabel ?? displayDateLabel(targetDate)
            message = "已把\(title)复制到\(label)：\(response.saved ?? items.count) 项。"
            if targetDate == activeLogDate {
                await refreshFoodStateAfterLogging()
            }
        } catch {
            message = infoFriendlyError(error, fallback: "复制餐食失败")
        }
        copyingMealCategory = ""
    }

    private func openMealCategorySaveSheet(_ key: String, title: String) {
        let rows = rowsForMealCategory(key)
        guard !rows.isEmpty else {
            message = "\(title)还没有食物。先拍一餐或从加号记录，再保存为常吃餐。"
            return
        }
        let names = rows.map(\.displayName).filter { !$0.isEmpty }
        let baseTitle: String
        if names.isEmpty {
            baseTitle = "我的\(title)"
        } else if names.count == 1 {
            baseTitle = names[0]
        } else {
            baseTitle = "\(names.prefix(2).joined(separator: " + "))等 \(names.count) 项"
        }
        selectedMealCategorySaveTarget = MealCategorySaveTarget(
            key: key,
            title: title,
            defaultTitle: baseTitle,
            itemCount: rows.count,
            calories: rows.reduce(0) { $0 + ($1.calories ?? 0) }
        )
    }

    private func saveMealCategoryTemplate(_ key: String, title: String, customTitle: String? = nil) async {
        guard savingMealCategory.isEmpty, savingMealCategoryAsRecipe.isEmpty else { return }
        let rows = rowsForMealCategory(key)
        guard !rows.isEmpty else {
            message = "\(title)还没有食物。先拍一餐或从加号记录，再保存为常吃餐。"
            return
        }
        savingMealCategory = key
        message = ""
        do {
            let foods = rows.map(foodItemFromLogRow)
            let cleanTitle = (customTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = try await APIClient.shared.saveMealTemplate(
                title: cleanTitle.isEmpty ? "我的\(title)" : cleanTitle,
                foods: foods,
                mealCategory: key
            )
            selectedMealCategory = key
            message = "已保存为我的餐品：\(saved.title)。"
            selectedMealCategorySaveTarget = nil
            savedMeals = try await APIClient.shared.getSavedMeals(limit: 20)
        } catch {
            message = infoFriendlyError(error, fallback: "保存餐品失败")
        }
        savingMealCategory = ""
    }

    private func saveMealCategoryAsRecipe(_ key: String, title: String, customTitle: String? = nil) async {
        guard savingMealCategory.isEmpty, savingMealCategoryAsRecipe.isEmpty else { return }
        let rows = rowsForMealCategory(key)
        guard !rows.isEmpty else {
            message = "\(title)还没有食物。先记录这餐，再保存为食谱。"
            return
        }
        savingMealCategoryAsRecipe = key
        message = ""
        do {
            let cleanTitle = (customTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let recipeTitle = cleanTitle.isEmpty ? "我的\(title)食谱" : cleanTitle
            let payload = mealCategoryRecipePayload(rows: rows, title: title, recipeTitle: recipeTitle)
            let response = try await APIClient.shared.createIngredientRecipeSuggestion(
                recipePayload: payload,
                date: activeLogDate,
                source: "ios_meal_category"
            )
            let item = response.item ?? IngredientRecipeHistoryItem(
                id: response.recipeId ?? response.recipe.id,
                date: activeLogDate,
                source: "ios_meal_category",
                logged: nil,
                createdAt: nil,
                loggedAt: nil,
                loggedCount: nil,
                recipe: response.recipe
            )
            upsertRecipeSuggestion(item)
            selectedMealCategory = key
            selectedMealCategorySaveTarget = nil
            savedLibraryScope = "recipe"
            message = "已保存为食谱：\(item.recipe.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存食谱失败")
        }
        savingMealCategoryAsRecipe = ""
    }

    private func replaceSavedRecipeWithCategory(_ key: String, title: String, savedRecipe: IngredientRecipeHistoryItem) async {
        guard replacingMealCategory.isEmpty, savingMealCategoryAsRecipe.isEmpty else { return }
        let rows = rowsForMealCategory(key)
        guard !rows.isEmpty else {
            message = "\(title)还没有可替换为食谱的食物。"
            return
        }
        replacingMealCategory = key
        message = ""
        do {
            let payload = mealCategoryRecipePayload(
                rows: rows,
                title: title,
                recipeTitle: savedRecipe.recipe.title,
                preserving: savedRecipe.recipe
            )
            let response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                id: savedRecipe.id,
                recipePayload: payload
            )
            let item = response.item ?? IngredientRecipeHistoryItem(
                id: response.recipeId ?? savedRecipe.id,
                date: savedRecipe.date,
                source: savedRecipe.source,
                logged: savedRecipe.logged,
                createdAt: savedRecipe.createdAt,
                loggedAt: savedRecipe.loggedAt,
                loggedCount: savedRecipe.loggedCount,
                recipe: response.recipe
            )
            upsertRecipeSuggestion(item)
            selectedMealCategory = key
            selectedMealCategorySaveTarget = nil
            savedLibraryScope = "recipe"
            syncSavedLibraryAfterMutation()
            message = "已替换同名食谱：\(item.recipe.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "替换食谱失败")
        }
        replacingMealCategory = ""
    }

    private func mealCategoryRecipePayload(rows: [FoodLogRow], title: String, recipeTitle: String, preserving recipe: IngredientRecipeSuggestion? = nil) -> [String: Any] {
        let foods = rows.map(foodItemFromLogRow)
        let ingredientDrafts = foods.map { RecipeIngredientDraft(food: $0) }
        let totals = ingredientDrafts.reduce(RecipeTotals()) { partial, draft in
            partial.adding(draft.totals)
        }
        var payload: [String: Any] = [
            "title": recipeTitle,
            "servings": 1,
            "serving_size_label": recipe.map(recipeServingSizeLabel) ?? "1份",
            "calories": roundToOne(totals.calories),
            "protein": roundToOne(totals.protein),
            "carbs": roundToOne(totals.carbs),
            "fat": roundToOne(totals.fat),
            "fiber": roundToOne(totals.fiber),
            "sodium": roundToOne(totals.sodium),
            "sugar": roundToOne(totals.sugar),
            "prep_time_minutes": 0,
            "active_time_minutes": 0,
            "inactive_time_minutes": 0,
            "reason": "由\(title)创建",
            "instructions": ["按当前餐次食物组合制作。", "记录时可按实际食用份量调整。"],
            "ingredients_breakdown": ingredientDrafts.map { $0.payload },
            "missing_ingredients": [],
            "source": "ios_meal_category",
            "tags": [title, "餐次保存"],
            "meal_types": RecipeMealType.normalized(title).map { [$0] } ?? []
        ]
        if let mealTypes = recipe?.mealTypes, !mealTypes.isEmpty {
            payload["meal_types"] = RecipeMealType.inferredList(mealTypes: mealTypes, tags: recipe?.tags)
        }
        if let tags = recipe?.tags, !tags.isEmpty {
            var mergedTags = tags
            for tag in [title, "餐次保存"] where !mergedTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                mergedTags.append(tag)
            }
            payload["tags"] = mergedTags
        }
        if let sourceURL = recipe?.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceURL.isEmpty {
            payload["source_url"] = sourceURL
        }
        if let cookingTime = recipe?.cookingTime?.trimmingCharacters(in: .whitespacesAndNewlines), !cookingTime.isEmpty {
            payload["cooking_time"] = cookingTime
        }
        if let imageURL = recipe?.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
            payload["image_url"] = imageURL
        }
        return payload
    }

    private func replaceSavedMealWithCategory(_ key: String, title: String, savedMeal: SavedMealItem) async {
        guard replacingMealCategory.isEmpty, savingMealCategoryAsRecipe.isEmpty else { return }
        let rows = rowsForMealCategory(key)
        guard !rows.isEmpty else {
            message = "\(title)还没有可替换的食物。"
            return
        }
        replacingMealCategory = key
        message = ""
        do {
            let updated = try await APIClient.shared.updateSavedMeal(
                id: savedMeal.id,
                title: savedMeal.title,
                foods: rows.map(foodItemFromLogRow),
                mealCategory: key,
                imageUrl: savedMeal.imageUrl ?? "",
                note: savedMeal.note,
                instructions: savedMeal.instructions
            )
            upsertSavedMeal(updated)
            selectedMealCategory = key
            selectedMealCategorySaveTarget = nil
            savedLibraryScope = "meal"
            message = "已用\(title)替换餐品：\(updated.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "替换餐品失败")
        }
        replacingMealCategory = ""
    }

    private func roundToOne(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func offsetDateString(_ dateString: String, days: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: dateString) ?? Date()
        let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        return formatter.string(from: shifted)
    }

    private func dateFromString(_ dateString: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString) ?? Date()
    }

    private func displayDateLabel(_ dateString: String) -> String {
        let date = dateFromString(dateString)
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInTomorrow(date) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func cleanedDateSequence(_ dates: [String]) -> [String] {
        var seen: Set<String> = []
        let cleaned = dates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { date in
                if seen.contains(date) { return false }
                seen.insert(date)
                return true
            }
        return cleaned.isEmpty ? [activeLogDate] : cleaned
    }

    private func multiDayLogMessage(
        name: String,
        kind: String,
        mealCategory: String,
        portionMultiplier: Double,
        dates: [String],
        savedCount: Int
    ) -> String {
        let portionLabel = abs(portionMultiplier - 1) < 0.001 ? "" : " \(formatPortionMultiplier(portionMultiplier))"
        if dates.count <= 1, let date = dates.first {
            let datePrefix = date == activeLogDate ? "" : "\(displayDateLabel(date)) · "
            return "已记录\(kind)到\(datePrefix)\(mealCategoryTitle(mealCategory))：\(name)\(portionLabel) \(max(savedCount, 1)) 项。"
        }
        let firstDate = dates.first.map(displayDateLabel) ?? "今天"
        return "已从\(firstDate)起连续 \(dates.count) 天记录\(kind)到\(mealCategoryTitle(mealCategory))：\(name)\(portionLabel) \(max(savedCount, 1)) 项。"
    }

    private func saveFoodAsTemplate(_ food: FoodItem) async {
        guard savingFoodTemplateId.isEmpty else { return }
        savingFoodTemplateId = food.id
        message = ""
        do {
            let saved = try await APIClient.shared.saveFoodTemplate(food)
            savedFoods.removeAll { $0.id == saved.id || $0.food.name == saved.food.name }
            savedFoods.insert(saved, at: 0)
            message = "已保存到我的食物：\(saved.name)。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存食物失败")
        }
        savingFoodTemplateId = ""
    }

    private func logSavedFood(_ item: SavedFoodItem, mealCategory: String? = nil, portionMultiplier: Double = 1, date: String? = nil) async {
        guard loggingSavedFoodId.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        let targetDate = (date ?? activeLogDate).trimmingCharacters(in: .whitespacesAndNewlines)
        loggingSavedFoodId = item.id
        message = ""
        do {
            let response = try await APIClient.shared.logSavedFood(
                id: item.id,
                mealCategory: targetMealCategory,
                date: targetDate,
                portionMultiplier: portionMultiplier
            )
            let portionText = abs(portionMultiplier - 1) < 0.001 ? "" : " ×\(formatPortionMultiplier(portionMultiplier))"
            let datePrefix = targetDate == activeLogDate ? "" : "\(displayDateLabel(targetDate)) · "
            message = "已记录到\(datePrefix)\(mealCategoryTitle(targetMealCategory))：\(item.name)\(portionText) \(response.saved ?? 1) 项。"
            if targetDate == activeLogDate {
                selectedMealCategory = targetMealCategory
                await refreshFoodStateAfterLogging()
            }
        } catch {
            message = infoFriendlyError(error, fallback: "记录食物失败")
        }
        loggingSavedFoodId = ""
    }

    private func logSavedFoodDates(_ item: SavedFoodItem, mealCategory: String? = nil, portionMultiplier: Double = 1, dates: [String]) async {
        guard loggingSavedFoodId.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        let multiplier = max(0.05, min(20.0, portionMultiplier))
        let targetDates = cleanedDateSequence(dates)
        loggingSavedFoodId = item.id
        message = ""
        var savedCount = 0
        do {
            for date in targetDates {
                let response = try await APIClient.shared.logSavedFood(
                    id: item.id,
                    mealCategory: targetMealCategory,
                    date: date,
                    portionMultiplier: multiplier
                )
                savedCount += response.saved ?? 1
            }
            message = multiDayLogMessage(
                name: item.name,
                kind: "食物",
                mealCategory: targetMealCategory,
                portionMultiplier: multiplier,
                dates: targetDates,
                savedCount: savedCount
            )
            if targetDates.contains(activeLogDate) {
                selectedMealCategory = targetMealCategory
                await refreshFoodStateAfterLogging()
            }
        } catch {
            message = infoFriendlyError(error, fallback: "记录食物失败")
        }
        loggingSavedFoodId = ""
    }

    private func toggleSavedFoodSelection(_ item: SavedFoodItem) {
        if selectedSavedFoodIds.contains(item.id) {
            selectedSavedFoodIds.remove(item.id)
        } else {
            selectedSavedFoodIds = multiAddSelection(selectedSavedFoodIds, adding: [item.id])
        }
    }

    private func toggleSavedFoodSelection(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedSavedFoodIds) {
            selectedSavedFoodIds.subtract(ids)
        } else {
            selectedSavedFoodIds = multiAddSelection(selectedSavedFoodIds, adding: ids)
        }
    }

    private func logSelectedSavedFoods(mealCategory: String? = nil) async {
        guard !loggingSelectedSavedFoods else { return }
        let selected = selectedSavedFoods
        guard !selected.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        loggingSelectedSavedFoods = true
        message = ""
        var savedCount = 0
        do {
            for item in selected {
                let response = try await APIClient.shared.logSavedFood(
                    id: item.id,
                    mealCategory: targetMealCategory,
                    date: activeLogDate
                )
                savedCount += response.saved ?? 1
            }
            selectedMealCategory = targetMealCategory
            selectedSavedFoodIds.removeAll()
            message = "已记录到\(mealCategoryTitle(targetMealCategory))：\(savedCount) 项食物。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "批量记录食物失败")
        }
        loggingSelectedSavedFoods = false
    }

    private func deleteSelectedSavedFoods() async {
        guard !deletingSelectedSavedFoods else { return }
        let selected = selectedSavedFoods
        guard !selected.isEmpty else { return }
        deletingSelectedSavedFoods = true
        message = ""
        var deletedIds: Set<String> = []
        do {
            for item in selected {
                _ = try await APIClient.shared.deleteSavedFood(id: item.id)
                deletedIds.insert(item.id)
            }
            savedFoods.removeAll { deletedIds.contains($0.id) }
            selectedSavedFoodIds.removeAll()
            syncSavedLibraryAfterMutation()
            message = "已删除 \(deletedIds.count) 个食物。"
        } catch {
            message = infoFriendlyError(error, fallback: "批量删除食物失败")
        }
        deletingSelectedSavedFoods = false
    }

    private func toggleSavedMealSelection(_ meal: SavedMealItem) {
        if selectedSavedMealIds.contains(meal.id) {
            selectedSavedMealIds.remove(meal.id)
        } else {
            selectedSavedMealIds = multiAddSelection(selectedSavedMealIds, adding: [meal.id])
        }
    }

    private func toggleSavedMealSelection(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedSavedMealIds) {
            selectedSavedMealIds.subtract(ids)
        } else {
            selectedSavedMealIds = multiAddSelection(selectedSavedMealIds, adding: ids)
        }
    }

    private func logSelectedSavedMeals(mealCategory: String? = nil) async {
        guard !loggingSelectedSavedMeals else { return }
        let selected = selectedSavedMeals
        guard !selected.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        loggingSelectedSavedMeals = true
        message = ""
        var savedCount = 0
        do {
            for meal in selected {
                let response = try await APIClient.shared.logSavedMeal(
                    id: meal.id,
                    mealCategory: targetMealCategory,
                    date: activeLogDate
                )
                savedCount += response.saved ?? meal.foods.count
            }
            selectedMealCategory = targetMealCategory
            selectedSavedMealIds.removeAll()
            message = "已记录到\(mealCategoryTitle(targetMealCategory))：\(savedCount) 项餐品食物。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "批量记录餐品失败")
        }
        loggingSelectedSavedMeals = false
    }

    private func deleteSelectedSavedMeals() async {
        guard !deletingSelectedSavedMeals else { return }
        let selected = selectedSavedMeals
        guard !selected.isEmpty else { return }
        deletingSelectedSavedMeals = true
        message = ""
        var deletedIds: Set<String> = []
        do {
            for meal in selected {
                _ = try await APIClient.shared.deleteSavedMeal(id: meal.id)
                deletedIds.insert(meal.id)
            }
            savedMeals.removeAll { deletedIds.contains($0.id) }
            selectedSavedMealIds.removeAll()
            syncSavedLibraryAfterMutation()
            message = "已删除 \(deletedIds.count) 个餐品。"
        } catch {
            message = infoFriendlyError(error, fallback: "批量删除餐品失败")
        }
        deletingSelectedSavedMeals = false
    }

    private func toggleSavedRecipeSelection(_ item: IngredientRecipeHistoryItem) {
        if selectedSavedRecipeIds.contains(item.id) {
            selectedSavedRecipeIds.remove(item.id)
        } else {
            selectedSavedRecipeIds = multiAddSelection(selectedSavedRecipeIds, adding: [item.id])
        }
    }

    private func toggleSavedRecipeSelection(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedSavedRecipeIds) {
            selectedSavedRecipeIds.subtract(ids)
        } else {
            selectedSavedRecipeIds = multiAddSelection(selectedSavedRecipeIds, adding: ids)
        }
    }

    private func logSelectedSavedRecipes(mealCategory: String? = nil) async {
        guard !loggingSelectedSavedRecipes else { return }
        let selected = selectedSavedRecipes
        guard !selected.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        loggingSelectedSavedRecipes = true
        message = ""
        var savedCount = 0
        do {
            for item in selected {
                let response = try await APIClient.shared.logIngredientRecipe(
                    id: item.id,
                    portionMultiplier: 1,
                    servingSizeLabel: recipeServingSizeLabelForLog(item.recipe, multiplier: 1),
                    mealCategory: targetMealCategory,
                    date: activeLogDate
                )
                savedCount += response.saved ?? 1
            }
            selectedMealCategory = targetMealCategory
            selectedSavedRecipeIds.removeAll()
            message = "已记录到\(mealCategoryTitle(targetMealCategory))：\(savedCount) 个食谱。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "批量记录食谱失败")
        }
        loggingSelectedSavedRecipes = false
    }

    private func deleteSelectedSavedRecipes() async {
        guard !deletingSelectedSavedRecipes else { return }
        let selected = selectedSavedRecipes
        guard !selected.isEmpty else { return }
        deletingSelectedSavedRecipes = true
        message = ""
        var deletedIds: Set<String> = []
        do {
            for item in selected {
                _ = try await APIClient.shared.deleteIngredientRecipeSuggestion(id: item.id)
                deletedIds.insert(item.id)
            }
            recipeSuggestions.removeAll { deletedIds.contains($0.id) }
            selectedSavedRecipeIds.removeAll()
            syncSavedLibraryAfterMutation()
            message = "已删除 \(deletedIds.count) 个食谱。"
        } catch {
            message = infoFriendlyError(error, fallback: "批量删除食谱失败")
        }
        deletingSelectedSavedRecipes = false
    }

    private func deleteSavedFood(_ item: SavedFoodItem) async {
        guard !deletingSelectedSavedFoods, deletingSavedFoodId.isEmpty else { return }
        deletingSavedFoodId = item.id
        message = ""
        do {
            _ = try await APIClient.shared.deleteSavedFood(id: item.id)
            savedFoods.removeAll { $0.id == item.id }
            syncSavedLibraryAfterMutation()
            message = "已删除食物：\(item.name)。"
        } catch {
            message = infoFriendlyError(error, fallback: "删除食物失败")
        }
        deletingSavedFoodId = ""
    }

    private func deleteDiaryFood(_ row: FoodLogRow) async {
        guard deletingFoodLogId == 0, adjustingFoodLogId == 0, movingFoodLogId == 0, clearingMealCategory.isEmpty, let id = row.id else { return }
        deletingFoodLogId = id
        message = ""
        do {
            _ = try await APIClient.shared.deleteFoodLogs(ids: [id])
            message = "已从\(mealCategoryTitle(normalizedMealCategory(row.mealCategory)))删除：\(row.displayName)。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "删除失败")
        }
        deletingFoodLogId = 0
    }

    private func clearMealCategory(_ key: String, title: String) async {
        guard clearingMealCategory.isEmpty, deletingFoodLogId == 0, adjustingFoodLogId == 0, movingFoodLogId == 0 else { return }
        let rows = rowsForMealCategory(key)
        let ids = rows.compactMap(\.id)
        guard !ids.isEmpty else {
            message = "\(title)还没有可清空的食物。"
            return
        }
        clearingMealCategory = key
        message = ""
        do {
            _ = try await APIClient.shared.deleteFoodLogs(ids: ids)
            selectedMealCategory = key
            message = "已清空\(title)：删除 \(ids.count) 项食物。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "清空\(title)失败")
        }
        clearingMealCategory = ""
    }

    private func adjustDiaryFoodPortion(_ row: FoodLogRow, ratio: Double) async {
        guard adjustingFoodLogId == 0, deletingFoodLogId == 0, movingFoodLogId == 0, clearingMealCategory.isEmpty, let id = row.id else { return }
        adjustingFoodLogId = id
        message = ""
        do {
            let date = logDate.isEmpty ? (row.date ?? "") : logDate
            _ = try await APIClient.shared.adjustFoodLogPortion(id: id, consumedRatio: ratio, date: date)
            let percent = Int(round(ratio * 100))
            message = "已把\(row.displayName)调整为 \(percent)% 份量。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "份量调整失败")
        }
        adjustingFoodLogId = 0
    }

    private func moveDiaryFood(_ row: FoodLogRow, to mealCategory: String) async {
        guard movingFoodLogId == 0, deletingFoodLogId == 0, adjustingFoodLogId == 0, clearingMealCategory.isEmpty, let id = row.id else { return }
        movingFoodLogId = id
        message = ""
        do {
            let date = logDate.isEmpty ? (row.date ?? "") : logDate
            _ = try await APIClient.shared.moveFoodLog(id: id, mealCategory: mealCategory, date: date)
            selectedMealCategory = mealCategory
            message = "已移动到\(mealCategoryTitle(mealCategory))：\(row.displayName)。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "移动餐次失败")
        }
        movingFoodLogId = 0
    }

    private func deleteRecentMealGroup(_ group: MealHistoryGroup) async {
        guard deletingRecentGroupId.isEmpty else { return }
        deletingRecentGroupId = group.id
        message = ""
        do {
            let uploadGroupId = group.id.hasPrefix("single-") ? "" : group.id
            let ids = uploadGroupId.isEmpty ? group.foods.compactMap { $0.id } : []
            _ = try await APIClient.shared.deleteFoodLogs(ids: ids, uploadGroupId: uploadGroupId)
            if expandedRecentGroupId == group.id {
                expandedRecentGroupId = ""
            }
            message = "已删除餐食：\(group.title)。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "删除餐食失败")
        }
        deletingRecentGroupId = ""
    }

    private func saveRecentMealAsTemplate(_ group: MealHistoryGroup) async {
        guard savingRecentMealId.isEmpty else { return }
        let items = group.foods.map(foodItemFromLogRow)
        guard !items.isEmpty else { return }
        savingRecentMealId = group.id
        message = ""
        do {
            let title = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = title.casefoldedForMealMatching
            let matchingMeal = normalizedTitle.isEmpty ? nil : savedMeals.first { $0.title.casefoldedForMealMatching == normalizedTitle }
            let meal: SavedMealItem
            if let matchingMeal {
                meal = try await APIClient.shared.updateSavedMeal(
                    id: matchingMeal.id,
                    title: matchingMeal.title,
                    foods: items,
                    mealCategory: normalizedMealCategory(group.foods.first?.mealCategory),
                    imageUrl: matchingMeal.imageUrl ?? group.foods.first?.imageUrl ?? "",
                    note: matchingMeal.note,
                    instructions: matchingMeal.instructions,
                    favorite: matchingMeal.favorite
                )
            } else {
                meal = try await APIClient.shared.saveMealTemplate(
                    title: group.title,
                    foods: items,
                    mealCategory: normalizedMealCategory(group.foods.first?.mealCategory),
                    imageUrl: group.foods.first?.imageUrl ?? ""
                )
            }
            upsertSavedMeal(meal)
            syncSavedLibraryAfterMutation()
            message = matchingMeal == nil ? "已保存到我的餐品：\(meal.title)。" : "已替换同名餐品：\(meal.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存餐品失败")
        }
        savingRecentMealId = ""
    }

    private func duplicateSavedMeal(_ meal: SavedMealItem) async {
        guard duplicatingSavedMealId.isEmpty, loggingSavedMealId.isEmpty, deletingSavedMealId.isEmpty, favoritingSavedMealId.isEmpty, !meal.foods.isEmpty else { return }
        duplicatingSavedMealId = meal.id
        message = ""
        do {
            let baseTitle = meal.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = baseTitle.isEmpty ? "餐品副本" : "\(baseTitle) 副本"
            let duplicated = try await APIClient.shared.saveMealTemplate(
                title: title,
                foods: meal.foods,
                mealCategory: meal.mealCategory ?? selectedMealCategory,
                imageUrl: meal.imageUrl ?? "",
                note: meal.note,
                instructions: meal.instructions
            )
            upsertSavedMeal(duplicated)
            if savedLibraryScope == "food" {
                savedLibraryScope = "meal"
            }
            syncSavedLibraryAfterMutation()
            message = "已复制餐品：\(duplicated.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "复制餐品失败")
        }
        duplicatingSavedMealId = ""
    }

    private func toggleSavedMealFavorite(_ meal: SavedMealItem) async {
        guard favoritingSavedMealId.isEmpty, loggingSavedMealId.isEmpty, deletingSavedMealId.isEmpty, duplicatingSavedMealId.isEmpty else { return }
        favoritingSavedMealId = meal.id
        message = ""
        do {
            let response = try await APIClient.shared.toggleSavedMealFavorite(id: meal.id)
            if let updated = response.meal {
                upsertSavedMeal(updated)
                message = (updated.favorite == true) ? "已收藏餐品：\(updated.title)。" : "已取消收藏：\(updated.title)。"
            } else {
                message = "餐品收藏状态已更新。"
            }
            syncSavedLibraryAfterMutation()
        } catch {
            message = infoFriendlyError(error, fallback: "更新餐品收藏失败")
        }
        favoritingSavedMealId = ""
    }

    private func logSavedMeal(_ meal: SavedMealItem, mealCategory: String? = nil, portionMultiplier: Double = 1, date: String? = nil) async {
        guard loggingSavedMealId.isEmpty, deletingSavedMealId.isEmpty, duplicatingSavedMealId.isEmpty, favoritingSavedMealId.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? meal.mealCategory ?? selectedMealCategory)
        let multiplier = max(0.05, min(20.0, portionMultiplier))
        let targetDate = (date ?? activeLogDate).trimmingCharacters(in: .whitespacesAndNewlines)
        loggingSavedMealId = meal.id
        message = ""
        do {
            let response = try await APIClient.shared.logSavedMeal(
                id: meal.id,
                mealCategory: targetMealCategory,
                date: targetDate,
                portionMultiplier: multiplier
            )
            let portionLabel = multiplier == 1 ? "" : " \(formatMacro(multiplier))份"
            let datePrefix = targetDate == activeLogDate ? "" : "\(displayDateLabel(targetDate)) · "
            message = "已记录到\(datePrefix)\(mealCategoryTitle(targetMealCategory))：\(meal.title)\(portionLabel) \(response.saved ?? meal.foods.count) 项。"
            if targetDate == activeLogDate {
                selectedMealCategory = targetMealCategory
                await refreshFoodStateAfterLogging()
            }
        } catch {
            message = infoFriendlyError(error, fallback: "记录餐品失败")
        }
        loggingSavedMealId = ""
    }

    private func logSavedMealDates(_ meal: SavedMealItem, mealCategory: String? = nil, portionMultiplier: Double = 1, dates: [String]) async {
        guard loggingSavedMealId.isEmpty, deletingSavedMealId.isEmpty, duplicatingSavedMealId.isEmpty, favoritingSavedMealId.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? meal.mealCategory ?? selectedMealCategory)
        let multiplier = max(0.05, min(20.0, portionMultiplier))
        let targetDates = cleanedDateSequence(dates)
        loggingSavedMealId = meal.id
        message = ""
        var savedCount = 0
        do {
            for date in targetDates {
                let response = try await APIClient.shared.logSavedMeal(
                    id: meal.id,
                    mealCategory: targetMealCategory,
                    date: date,
                    portionMultiplier: multiplier
                )
                savedCount += response.saved ?? meal.foods.count
            }
            message = multiDayLogMessage(
                name: meal.title,
                kind: "餐品",
                mealCategory: targetMealCategory,
                portionMultiplier: multiplier,
                dates: targetDates,
                savedCount: savedCount
            )
            if targetDates.contains(activeLogDate) {
                selectedMealCategory = targetMealCategory
                await refreshFoodStateAfterLogging()
            }
        } catch {
            message = infoFriendlyError(error, fallback: "记录餐品失败")
        }
        loggingSavedMealId = ""
    }

    private func deleteSavedMeal(_ meal: SavedMealItem) async {
        guard !deletingSelectedSavedMeals, deletingSavedMealId.isEmpty, loggingSavedMealId.isEmpty, duplicatingSavedMealId.isEmpty, favoritingSavedMealId.isEmpty else { return }
        deletingSavedMealId = meal.id
        message = ""
        do {
            _ = try await APIClient.shared.deleteSavedMeal(id: meal.id)
            savedMeals.removeAll { $0.id == meal.id }
            syncSavedLibraryAfterMutation()
            message = "已删除餐品：\(meal.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "删除餐品失败")
        }
        deletingSavedMealId = ""
    }

    private func logRecentMealGroup(_ group: MealHistoryGroup, mealCategory: String? = nil) async {
        guard loggingRecentGroupId.isEmpty else { return }
        let items = group.foods.map(foodItemFromLogRow)
        guard !items.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(mealCategory ?? selectedMealCategory)
        loggingRecentGroupId = group.id
        message = ""
        do {
            var datedItems = items
            if !logDate.isEmpty {
                for index in datedItems.indices {
                    datedItems[index].date = logDate
                }
            }
            let response = try await APIClient.shared.logFoods(
                datedItems,
                mealCategory: targetMealCategory,
                groupTitle: "\(mealCategoryTitle(targetMealCategory))同款",
                date: activeLogDate
            )
            selectedMealCategory = targetMealCategory
            message = "已记录到\(mealCategoryTitle(targetMealCategory))：同款 \(response.saved ?? datedItems.count) 项。"
            await refreshFoodStateAfterLogging()
        } catch {
            message = infoFriendlyError(error, fallback: "群组记录失败")
        }
        loggingRecentGroupId = ""
    }

    private func copyRecentMealGroup(_ group: MealHistoryGroup, to targetDate: String, label: String) async {
        guard loggingRecentGroupId.isEmpty else { return }
        let cleanDate = targetDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = group.foods.map(foodItemFromLogRow)
        guard !items.isEmpty, !cleanDate.isEmpty else { return }
        let targetMealCategory = normalizedMealCategory(group.foods.first?.mealCategory ?? selectedMealCategory)
        loggingRecentGroupId = group.id
        message = ""
        do {
            var datedItems = items
            for index in datedItems.indices {
                datedItems[index].date = cleanDate
            }
            let response = try await APIClient.shared.logFoods(
                datedItems,
                mealCategory: targetMealCategory,
                groupTitle: "复制\(group.title)",
                imageBase64: "",
                date: cleanDate
            )
            if cleanDate == activeLogDate || (cleanDate == todayDateString && logDate.isEmpty) {
                selectedMealCategory = targetMealCategory
                await refreshFoodStateAfterLogging()
            }
            message = "已复制到\(label)：\(response.saved ?? datedItems.count) 项。"
        } catch {
            message = infoFriendlyError(error, fallback: "复制餐食失败")
        }
        loggingRecentGroupId = ""
    }

    private func foodItemFromLogRow(_ row: FoodLogRow) -> FoodItem {
        let stableId = row.id.map { "log_\($0)" } ?? "recent_\(row.displayName)_\(row.displayServingSize)"
            .replacingOccurrences(of: " ", with: "_")
        var item = FoodItem(
            name: row.displayName,
            calories: row.calories ?? 0,
            protein: row.protein ?? 0,
            carbs: row.carbs ?? 0,
            fat: row.fat ?? 0,
            fiber: row.fiber ?? 0,
            sugar: row.sugar ?? 0,
            sodium: row.sodium ?? 0,
            servingSize: row.displayServingSize,
            processingLevel: "whole",
            addedSugar: row.sugar ?? 0
        )
        item.id = stableId
        return item
    }

    private func copyGroceryList(_ plan: MealPlanPayload) {
        UIPasteboard.general.string = groceryListText(plan)
        copiedGroceryPlanId = plan.displayId
        message = "购物清单已复制。"

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedGroceryPlanId == plan.displayId {
                copiedGroceryPlanId = ""
            }
        }
    }

    private func groceryListText(_ plan: MealPlanPayload) -> String {
        var sections = ["\(plan.displayName) 购物清单"]
        for group in plan.groceryList {
            guard !group.items.isEmpty else { continue }
            let items = group.items.map { "- \($0)" }.joined(separator: "\n")
            sections.append("\(group.category)\n\(items)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func groceryItemKey(category: String, item: String) -> String {
        "\(category.trimmingCharacters(in: .whitespacesAndNewlines))::\(item.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func groceryCheckedCount(_ plan: MealPlanPayload) -> Int {
        let available = Set(plan.groceryList.flatMap { group in
            group.items.map { groceryItemKey(category: group.category, item: $0) }
        })
        return (plan.groceryCheckedItems ?? []).filter { available.contains($0) }.count
    }

    private func clearGroceryChecked(_ sourcePlan: MealPlanPayload) async {
        guard updatingGroceryItemKey.isEmpty else { return }
        updatingGroceryItemKey = "__clear__"
        message = ""
        do {
            let updated = try await APIClient.shared.updateMealPlanGroceryChecked(
                planId: sourcePlan.displayId,
                checkedItems: []
            )
            applyUpdatedMealPlan(updated)
            message = "购物清单勾选已清空。"
        } catch {
            message = infoFriendlyError(error, fallback: "清空购物清单失败")
        }
        updatingGroceryItemKey = ""
    }

    private func toggleGroceryItem(plan sourcePlan: MealPlanPayload, category: String, item: String) async {
        let key = groceryItemKey(category: category, item: item)
        guard updatingGroceryItemKey.isEmpty else { return }
        updatingGroceryItemKey = key
        message = ""

        var checked = sourcePlan.groceryCheckedItems ?? []
        if checked.contains(key) {
            checked.removeAll { $0 == key }
        } else {
            checked.append(key)
        }

        do {
            let updated = try await APIClient.shared.updateMealPlanGroceryChecked(
                planId: sourcePlan.displayId,
                checkedItems: checked
            )
            applyUpdatedMealPlan(updated)
            message = checked.contains(key) ? "已勾选：\(item)。" : "已取消勾选：\(item)。"
        } catch {
            message = infoFriendlyError(error, fallback: "更新购物清单失败")
        }

        updatingGroceryItemKey = ""
    }

    private func applyUpdatedMealPlan(_ updated: MealPlanPayload) {
        if plan?.displayId == updated.displayId {
            plan = updated
        }
        history = history.map { $0.displayId == updated.displayId ? updated : $0 }
        if plan == nil, history.first?.displayId == updated.displayId {
            plan = updated
        }
    }

    private func safeInt(_ text: String, _ fallback: Int) -> Int {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }

    private func formatMacro(_ value: Double?) -> String {
        let number = max(0, value ?? 0)
        if abs(number.rounded() - number) < 0.05 {
            return "\(Int(round(number)))"
        }
        return String(format: "%.1f", number)
    }

    private func textToList(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: ",", with: "，")
            .split(separator: "，")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    var casefoldedForMealMatching: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}

private func infoFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackText = infoFriendlyFallback(fallback)
    guard !raw.isEmpty else { return fallbackText }

    let lowercased = raw.lowercased()
    if lowercased.contains("could not connect")
        || lowercased.contains("connection")
        || lowercased.contains("timed out")
        || lowercased.contains("offline")
        || raw.contains("连接不到")
        || raw.contains("无法连接")
        || raw.contains("网络") {
        return "现在没连上，这次操作还没保存；检查网络后再点刚才的按钮。"
    }

    if lowercased.contains("not found") || raw.contains("404") {
        return "这条内容暂时找不到，返回后刷新列表。"
    }

    if lowercased.contains("cancel") || raw.contains("取消") {
        return "刚才的操作已取消，没有改动记录。"
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

private func infoFriendlyInlineMessage(_ message: String) -> String {
    let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return raw }
    let lowercased = raw.lowercased()

    if raw.hasPrefix("{") || raw.hasPrefix("[") || lowercased.contains("json") {
        return "这次没有处理成功，内容还在，换个入口或再点刚才的按钮。"
    }

    if raw.contains("失败")
        || raw.contains("错误")
        || raw.contains("异常")
        || lowercased.contains("failed")
        || lowercased.contains("error")
        || lowercased.contains("exception") {
        return "这次没有处理成功，内容还在，换个入口或再点刚才的按钮。"
    }

    if raw.count > 120 {
        if lowercased.contains("could not connect")
            || lowercased.contains("connection")
            || lowercased.contains("timed out")
            || raw.contains("连接不到")
            || raw.contains("无法连接") {
            return "现在没连上，这次操作还没保存；检查网络后再点刚才的按钮。"
        }
        return String(raw.prefix(110)) + "..."
    }

    return raw
}

private func infoFriendlyFallback(_ fallback: String) -> String {
    if fallback.contains("搜索") {
        return "这次还没搜出来，换个更短的关键词再搜。"
    }
    if fallback.contains("加载更多") {
        return "更多内容暂时没加载出来，停一下再往下拉。"
    }
    if fallback.contains("生成") || fallback.contains("换餐") {
        return "这份推荐暂时没整理好，检查网络后再点生成。"
    }
    if fallback.contains("记录") || fallback.contains("添加") || fallback.contains("导入") {
        return "这次还没记上，内容还在，检查网络后再点记录。"
    }
    if fallback.contains("保存") || fallback.contains("另存") || fallback.contains("收藏") || fallback.contains("更新") {
        return "这次还没保存上，内容还在，检查网络后再点保存。"
    }
    if fallback.contains("删除") || fallback.contains("清空") {
        return "这次还没删掉，检查网络后再点删除。"
    }
    if fallback.contains("复制") {
        return "这次还没复制成功，检查网络后再点复制。"
    }
    if fallback.contains("移动") || fallback.contains("替换") || fallback.contains("调整") {
        return "这次还没改成功，内容还在，检查网络后再点保存修改。"
    }
    return fallback
}

private func infoMessageNeedsAttention(_ message: String) -> Bool {
    message.contains("失败")
        || message.contains("错误")
        || message.contains("连接不到")
        || message.contains("连不上")
        || message.contains("无法")
        || message.contains("暂时")
        || message.contains("还没")
        || message.contains("找不到")
        || message.contains("没有")
}

private struct SavedLibraryAddItemsSheetView: View {
    let mealTitle: String
    let onClose: () -> Void
    let onScanFood: () -> Void
    let onSearchFood: () -> Void
    let onQuickAdd: () -> Void
    let onBarcode: () -> Void
    let onCreateFood: () -> Void
    let onCreateMeal: () -> Void
    let onCreateRecipe: () -> Void
    let onVoiceLog: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("添加项目")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("选择要加入\(mealTitle)的方式。")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "8A93A3"))
                    }

                    VStack(spacing: 10) {
                        addItemPrimaryButton(
                            icon: "camera.viewfinder",
                            title: "扫描食物",
                            subtitle: "扫描餐食并记录到\(mealTitle)",
                            action: onScanFood
                        )
                        addItemPrimaryButton(
                            icon: "magnifyingglass",
                            title: "搜索食物",
                            subtitle: "搜索食品、品牌、口味和保存库",
                            action: onSearchFood
                        )
                        addItemPrimaryButton(
                            icon: "plus.app.fill",
                            title: "手动记一项",
                            subtitle: "只输入卡路里或简单营养",
                            action: onQuickAdd
                        )
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        addItemTile(icon: "barcode.viewfinder", title: "条形码", subtitle: "包装食品", action: onBarcode)
                        addItemTile(icon: "waveform", title: "语音日志", subtitle: "说出食物", action: onVoiceLog)
                        addItemTile(icon: "doc.text.magnifyingglass", title: "创建食物", subtitle: "营养标签", action: onCreateFood)
                        addItemTile(icon: "rectangle.stack.badge.plus", title: "创建餐食", subtitle: "常吃组合", action: onCreateMeal)
                        addItemTile(icon: "book.closed.fill", title: "创建食谱", subtitle: "配料营养", action: onCreateRecipe)
                    }
                }
                .padding(20)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 34, height: 34)
                            .background(.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭添加项目")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func addItemPrimaryButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8A93A3"))
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "A0A7B3"))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func addItemTile(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "8A93A3"))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct SavedLibrarySortFilterSheetView: View {
    @Binding var scope: String
    @Binding var mealCategoryFilter: String
    @Binding var sort: String

    let scopes: [(String, String)]
    let mealCategoryOptions: [(String, String, String)]
    let sortOptions: [(String, String)]
    let resultSummary: String
    let onReset: () -> Void
    let onClose: () -> Void

    private var usesSavedSort: Bool {
        scope != "recent" && scope != "frequent"
    }

    private var fixedOrderLabel: String {
        scope == "recent" ? "按最近记录" : "按记录次数"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("排序和筛选")
                            .font(.system(size: 26, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text(resultSummary)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "8A93A3"))
                    }

                    filterSection(title: "显示范围", subtitle: "选择要添加到日记的项目来源") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(scopes, id: \.0) { option in
                                filterChoiceButton(
                                    title: option.1,
                                    selected: scope == option.0
                                ) {
                                    scope = option.0
                                }
                            }
                        }
                    }

                    filterSection(title: "餐次", subtitle: "餐品可以按早餐、午餐、晚餐或加餐筛选") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterPillButton(title: "全部餐次", icon: "tray.full.fill", selected: mealCategoryFilter == "all") {
                                    mealCategoryFilter = "all"
                                }
                                ForEach(mealCategoryOptions, id: \.0) { option in
                                    filterPillButton(title: option.1, icon: option.2, selected: mealCategoryFilter == option.0) {
                                        mealCategoryFilter = option.0
                                    }
                                }
                            }
                        }
                    }

                    filterSection(title: "排序", subtitle: usesSavedSort ? "保存库按创建时间、名称或热量排序" : "\(scope == "recent" ? "最近的" : "常用")列表固定\(fixedOrderLabel)") {
                        if usesSavedSort {
                            VStack(spacing: 10) {
                                ForEach(sortOptions, id: \.0) { option in
                                    filterRowButton(
                                        title: option.1,
                                        selected: sort == option.0
                                    ) {
                                        sort = option.0
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: scope == "recent" ? "clock.arrow.circlepath" : "clock.badge.checkmark")
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .accessibilityHidden(true)
                                Text(fixedOrderLabel)
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                Spacer()
                            }
                            .padding(14)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: onReset) {
                            Text("重置")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: onClose) {
                            Text("应用")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 34, height: 34)
                            .background(.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭排序和筛选")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func filterSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text(subtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8A93A3"))
            }
            content()
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func filterChoiceButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .black))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? .white : Color(hex: "111318"))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(selected ? Color.black : Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func filterPillButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .black))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .white : Color(hex: "111318"))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? Color.black : Color(hex: "F7F8FA"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func filterRowButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(selected ? Color.black : Color(hex: "C7CDD6"))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SelectedSavedFoodsMealSaveSheetView: View {
    let foods: [FoodItem]
    let logDate: String
    let mealCategory: String
    let mealCategoryOptions: [(String, String, String)]
    let savedMeals: [SavedMealItem]
    let onClose: () -> Void
    let onSaved: (SavedMealItem, Bool) -> Void
    let onLogged: () -> Void

    @State private var title: String
    @State private var selectedMealCategory: String
    @State private var saving = false
    @State private var logging = false
    @State private var message = ""

    init(
        foods: [FoodItem],
        logDate: String,
        mealCategory: String,
        mealCategoryOptions: [(String, String, String)],
        savedMeals: [SavedMealItem],
        onClose: @escaping () -> Void,
        onSaved: @escaping (SavedMealItem, Bool) -> Void,
        onLogged: @escaping () -> Void
    ) {
        self.foods = foods
        self.logDate = logDate
        self.mealCategory = mealCategory
        self.mealCategoryOptions = mealCategoryOptions
        self.savedMeals = savedMeals
        self.onClose = onClose
        self.onSaved = onSaved
        self.onLogged = onLogged
        _title = State(initialValue: SelectedSavedFoodsMealSaveSheetView.defaultTitle(for: foods))
        _selectedMealCategory = State(initialValue: mealCategory)
    }

    private var calories: Double {
        foods.reduce(0) { $0 + $1.calories }
    }

    private var protein: Double {
        foods.reduce(0) { $0 + $1.protein }
    }

    private var carbs: Double {
        foods.reduce(0) { $0 + $1.carbs }
    }

    private var fat: Double {
        foods.reduce(0) { $0 + $1.fat }
    }

    private var matchingSavedMeal: SavedMealItem? {
        let normalizedTitle = cleanTitle.casefoldedForMealMatching
        guard !normalizedTitle.isEmpty else { return nil }
        return savedMeals.first { $0.title.casefoldedForMealMatching == normalizedTitle }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("保存为餐品")
                            .font(.system(size: 26, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("把选中的常用食物组合成一整餐，下次可一键记录。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        TextField("餐品名称", text: $title)
                            .font(.system(size: 20, weight: .black))
                            .textInputAutocapitalization(.never)
                            .padding(14)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        if let matchingSavedMeal {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "2563EB"))
                                    .accessibilityHidden(true)
                                Text("将替换已有餐品“\(matchingSavedMeal.title)”，避免重复保存。")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(hex: "2563EB"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .background(Color(hex: "EFF6FF"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("默认餐次")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        HStack(spacing: 8) {
                            ForEach(mealCategoryOptions, id: \.0) { option in
                                Button {
                                    selectedMealCategory = option.0
                                } label: {
                                    Text(option.1)
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(selectedMealCategory == option.0 ? .white : Color(hex: "111318"))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 34)
                                        .background(selectedMealCategory == option.0 ? Color.black : Color(hex: "F7F8FA"))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("食物")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Spacer()
                            Text("\(foods.count) 项")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                        }
                        ForEach(foods) { item in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                        .lineLimit(1)
                                    Text(item.servingSize)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(Int(round(item.calories))) 千卡")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                            }
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    HStack(spacing: 10) {
                        mealTotalMetric("热量", "\(Int(round(calories)))千卡")
                        mealTotalMetric("蛋白", "\(Int(round(protein)))克")
                        mealTotalMetric("碳水", "\(Int(round(carbs)))克")
                        mealTotalMetric("脂肪", "\(Int(round(fat)))克")
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(infoMessageNeedsAttention(message) ? Color(hex: "EF4444") : Color(hex: "2563EB"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(18)
                .padding(.bottom, 84)
            }
            .background(Color(hex: "F4F7F6"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveMeal() }
                    } label: {
                        if saving {
                            ProgressView()
                                .tint(Color(hex: "111318"))
                        } else {
                            Text("保存餐品")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .disabled(saving || logging || foods.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        Task { await saveMeal() }
                    } label: {
                        Text(saving ? "保存中" : (matchingSavedMeal == nil ? "保存餐品" : "替换餐品"))
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || foods.isEmpty)

                    Button {
                        Task { await saveAndLogMeal() }
                    } label: {
                        HStack(spacing: 8) {
                            if logging {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(logging ? "记录中" : "保存并记录")
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || foods.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func mealTotalMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func saveMeal() async {
        guard !saving, !logging else { return }
        guard !foods.isEmpty else { return }
        saving = true
        message = ""
        do {
            let matchingMeal = matchingSavedMeal
            let saved: SavedMealItem
            if let matchingMeal {
                saved = try await APIClient.shared.updateSavedMeal(
                    id: matchingMeal.id,
                    title: matchingMeal.title,
                    foods: foods,
                    mealCategory: selectedMealCategory,
                    imageUrl: matchingMeal.imageUrl ?? ""
                )
            } else {
                saved = try await APIClient.shared.saveMealTemplate(
                    title: cleanTitle,
                    foods: foods,
                    mealCategory: selectedMealCategory
                )
            }
            onSaved(saved, matchingMeal != nil)
        } catch {
            message = infoFriendlyError(error, fallback: "保存餐品失败")
        }
        saving = false
    }

    private func saveAndLogMeal() async {
        guard !saving, !logging else { return }
        guard !foods.isEmpty else { return }
        logging = true
        message = ""
        do {
            let matchingMeal = matchingSavedMeal
            let saved: SavedMealItem
            if let matchingMeal {
                saved = try await APIClient.shared.updateSavedMeal(
                    id: matchingMeal.id,
                    title: matchingMeal.title,
                    foods: foods,
                    mealCategory: selectedMealCategory,
                    imageUrl: matchingMeal.imageUrl ?? ""
                )
            } else {
                saved = try await APIClient.shared.saveMealTemplate(
                    title: cleanTitle,
                    foods: foods,
                    mealCategory: selectedMealCategory
                )
            }
            _ = try await APIClient.shared.logSavedMeal(
                id: saved.id,
                mealCategory: selectedMealCategory,
                date: logDate
            )
            onSaved(saved, matchingMeal != nil)
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "保存并记录失败")
        }
        logging = false
    }

    private var cleanTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Self.defaultTitle(for: foods) : text
    }

    private static func defaultTitle(for foods: [FoodItem]) -> String {
        let names = foods.prefix(2).map(\.name).joined(separator: " + ")
        guard !names.isEmpty else { return "我的餐品" }
        return foods.count > 2 ? "\(names)等 \(foods.count) 项" : names
    }
}

private struct SelectedFoodsRecipeSaveSheetView: View {
    let foods: [FoodItem]
    let logDate: String
    let mealCategory: String
    let mealCategoryOptions: [(String, String, String)]
    let savedRecipes: [IngredientRecipeHistoryItem]
    let onClose: () -> Void
    let onSaved: (IngredientRecipeHistoryItem, Bool) -> Void
    let onLogged: () -> Void

    @State private var title: String
    @State private var selectedMealCategory: String
    @State private var servingsText = "1"
    @State private var servingSizeLabelText = "1份"
    @State private var prepTimeText = "0"
    @State private var instructionsText = "按常规方式处理食材。\n根据口味少油少盐烹调。"
    @State private var drafts: [RecipeIngredientDraft]
    @State private var saving = false
    @State private var logging = false
    @State private var message = ""

    init(
        foods: [FoodItem],
        logDate: String,
        mealCategory: String,
        mealCategoryOptions: [(String, String, String)],
        savedRecipes: [IngredientRecipeHistoryItem],
        onClose: @escaping () -> Void,
        onSaved: @escaping (IngredientRecipeHistoryItem, Bool) -> Void,
        onLogged: @escaping () -> Void
    ) {
        self.foods = foods
        self.logDate = logDate
        self.mealCategory = mealCategory
        self.mealCategoryOptions = mealCategoryOptions
        self.savedRecipes = savedRecipes
        self.onClose = onClose
        self.onSaved = onSaved
        self.onLogged = onLogged
        _title = State(initialValue: SelectedFoodsRecipeSaveSheetView.defaultTitle(for: foods))
        _selectedMealCategory = State(initialValue: mealCategory)
        _drafts = State(initialValue: foods.map { RecipeIngredientDraft(food: $0) })
    }

    private var servingsCount: Int {
        max(1, min(12, Int(servingsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1))
    }

    private var servingSizeLabel: String {
        let label = servingSizeLabelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "1份" : label
    }

    private var prepTimeMinutes: Int {
        max(0, min(480, Int(prepTimeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0))
    }

    private var recipeTotalNutrition: RecipeTotals {
        drafts.reduce(RecipeTotals()) { partial, draft in
            partial.adding(draft.totals)
        }
    }

    private var perServingNutrition: RecipeTotals {
        recipeTotalNutrition.scaled(by: 1.0 / Double(servingsCount))
    }

    private var editedInstructions: [String] {
        instructionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var matchingSavedRecipe: IngredientRecipeHistoryItem? {
        let normalizedTitle = cleanTitle.casefoldedForMealMatching
        guard !normalizedTitle.isEmpty else { return nil }
        return savedRecipes.first { $0.recipe.title.casefoldedForMealMatching == normalizedTitle }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("保存为食谱")
                            .font(.system(size: 26, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("把选中的食物变成可复用食谱，之后可按份数记录或另存餐品。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        TextField("食谱名称", text: $title)
                            .font(.system(size: 20, weight: .black))
                            .textInputAutocapitalization(.never)
                            .padding(14)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        if let matchingSavedRecipe {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "2563EB"))
                                    .accessibilityHidden(true)
                                Text("将替换已有食谱“\(matchingSavedRecipe.recipe.title)”，避免我的食谱里出现重复。")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(hex: "2563EB"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .background(Color(hex: "EFF6FF"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    HStack(spacing: 10) {
                        recipeMetric("每份热量", "\(Int(round(perServingNutrition.calories)))千卡")
                        recipeMetric("蛋白", "\(formatNumber(perServingNutrition.protein))克")
                        recipeMetric("碳水", "\(formatNumber(perServingNutrition.carbs))克")
                        recipeMetric("脂肪", "\(formatNumber(perServingNutrition.fat))克")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("食谱设置")
                                .font(.system(size: 17, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Spacer()
                            compactNumberField(label: "份", text: $servingsText)
                            compactNumberField(label: "分钟", text: $prepTimeText)
                        }
                        HStack(spacing: 8) {
                            Text("每份份量")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(.secondary)
                            TextField("例如：1碗 / 1块 / 250克", text: $servingSizeLabelText)
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 14, weight: .black))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                        Text("总份数会影响每份营养；食材克数按整份食谱计算。")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("记录到")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        HStack(spacing: 8) {
                            ForEach(mealCategoryOptions, id: \.0) { option in
                                Button {
                                    selectedMealCategory = option.0
                                } label: {
                                    Text(option.1)
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(selectedMealCategory == option.0 ? .white : Color(hex: "111318"))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 34)
                                        .background(selectedMealCategory == option.0 ? Color.black : Color(hex: "F7F8FA"))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("食材")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Spacer()
                            Text("\(drafts.count) 项")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                        }
                        ForEach(Array(drafts.indices), id: \.self) { index in
                            recipeIngredientRow($drafts[index], canRemove: drafts.count > 1) {
                                if drafts.indices.contains(index) {
                                    drafts.remove(at: index)
                                }
                            }
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("做法")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        TextEditor(text: $instructionsText)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "4B5563"))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .padding(10)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(infoMessageNeedsAttention(message) ? Color(hex: "EF4444") : Color(hex: "2563EB"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(18)
                .padding(.bottom, 84)
            }
            .background(Color(hex: "F4F7F6"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveRecipe() }
                    } label: {
                        if saving {
                            ProgressView()
                                .tint(Color(hex: "111318"))
                        } else {
                            Text("保存食谱")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .disabled(saving || logging || drafts.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        Task { await saveRecipe() }
                    } label: {
                        Text(saving ? "保存中" : (matchingSavedRecipe == nil ? "保存食谱" : "替换食谱"))
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || drafts.isEmpty)

                    Button {
                        Task { await saveAndLogRecipe() }
                    } label: {
                        HStack(spacing: 8) {
                            if logging {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(logging ? "记录中" : "保存并记录")
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || drafts.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func recipeMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func compactNumberField(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField(label, text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 16, weight: .black))
                .frame(width: 44)
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private func recipeIngredientRow(_ draft: Binding<RecipeIngredientDraft>, canRemove: Bool, onRemove: @escaping () -> Void) -> some View {
        let totals = draft.wrappedValue.totals
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.wrappedValue.name)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(Int(round(totals.calories))) 千卡 · 蛋白 \(formatNumber(totals.protein))克")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("克", text: draft.gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .black))
                    .frame(width: 54)
                Text("克")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(canRemove ? Color(hex: "EF4444") : Color(hex: "D1D5DB"))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .accessibilityLabel("移除食材 \(draft.wrappedValue.name)")
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func saveRecipe() async {
        guard !saving, !logging else { return }
        guard !drafts.isEmpty else { return }
        saving = true
        message = ""
        do {
            let matchingRecipe = matchingSavedRecipe
            let item = try await saveOrReplaceRecipe(matchingRecipe: matchingRecipe)
            onSaved(item, matchingRecipe != nil)
        } catch {
            message = infoFriendlyError(error, fallback: "保存食谱失败")
        }
        saving = false
    }

    private func saveAndLogRecipe() async {
        guard !saving, !logging else { return }
        guard !drafts.isEmpty else { return }
        logging = true
        message = ""
        do {
            let matchingRecipe = matchingSavedRecipe
            let item = try await saveOrReplaceRecipe(matchingRecipe: matchingRecipe)
            _ = try await APIClient.shared.logIngredientRecipe(
                id: item.id,
                portionMultiplier: 1,
                servingSizeLabel: recipeServingSizeLabelForLog(item.recipe, multiplier: 1),
                mealCategory: selectedMealCategory,
                date: logDate
            )
            onSaved(item, matchingRecipe != nil)
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "保存并记录失败")
        }
        logging = false
    }

    private func saveOrReplaceRecipe(matchingRecipe: IngredientRecipeHistoryItem?) async throws -> IngredientRecipeHistoryItem {
        let payload = recipePayload()
        if let matchingRecipe {
            let response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                id: matchingRecipe.id,
                recipePayload: payload
            )
            return response.item ?? IngredientRecipeHistoryItem(
                id: matchingRecipe.id,
                date: matchingRecipe.date,
                source: matchingRecipe.source,
                logged: matchingRecipe.logged,
                createdAt: matchingRecipe.createdAt,
                loggedAt: matchingRecipe.loggedAt,
                loggedCount: matchingRecipe.loggedCount,
                recipe: response.recipe
            )
        }
        let response = try await APIClient.shared.createIngredientRecipeSuggestion(
            recipePayload: payload,
            date: logDate,
            source: "ios_selected_foods"
        )
        return response.item ?? IngredientRecipeHistoryItem(
            id: response.recipeId ?? response.recipe.id,
            date: logDate,
            source: "ios_selected_foods",
            logged: nil,
            createdAt: nil,
            loggedAt: nil,
            loggedCount: nil,
            recipe: response.recipe
        )
    }

    private func recipePayload() -> [String: Any] {
        let totals = perServingNutrition
        return [
            "title": cleanTitle,
            "servings": servingsCount,
            "serving_size_label": servingSizeLabel,
            "calories": round1(totals.calories),
            "protein": round1(totals.protein),
            "carbs": round1(totals.carbs),
            "fat": round1(totals.fat),
            "fiber": round1(totals.fiber),
            "sodium": round1(totals.sodium),
            "sugar": round1(totals.sugar),
            "prep_time_minutes": prepTimeMinutes,
            "active_time_minutes": prepTimeMinutes,
            "inactive_time_minutes": 0,
            "reason": "由选中的食物创建",
            "instructions": editedInstructions.isEmpty ? ["按常规方式处理食材。"] : editedInstructions,
            "ingredients_breakdown": drafts.map { $0.payload },
            "missing_ingredients": [],
            "source": "ios_selected_foods",
            "tags": ["选中食物", "自建食谱"],
            "meal_types": [RecipeMealType.normalized(mealCategory) ?? "dinner"]
        ]
    }

    private var cleanTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Self.defaultTitle(for: foods) : text
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

    private static func defaultTitle(for foods: [FoodItem]) -> String {
        let names = foods.prefix(2).map(\.name).joined(separator: " + ")
        guard !names.isEmpty else { return "我的食谱" }
        return foods.count > 2 ? "\(names)等 \(foods.count) 项" : names
    }
}

private struct SavedLibraryPortionLogSheetView: View {
    let title: String
    let subtitle: String
    let baseCalories: Double
    let servingSizeOptions: [RecipeServingSizeOption]
    let mealCategory: String
    let mealCategoryOptions: [(String, String, String)]
    let onClose: () -> Void
    let onApply: (Double, String, [String], String?) -> Void

    @State private var portionText = "1"
    @State private var selectedMealCategory: String
    @State private var selectedDate = Date()
    @State private var dayCount = 1

    init(
        title: String,
        subtitle: String,
        baseCalories: Double,
        servingSizeOptions: [RecipeServingSizeOption] = [],
        mealCategory: String,
        mealCategoryOptions: [(String, String, String)],
        onClose: @escaping () -> Void,
        onApply: @escaping (Double, String, [String], String?) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.baseCalories = baseCalories
        self.servingSizeOptions = servingSizeOptions
        self.mealCategory = mealCategory
        self.mealCategoryOptions = mealCategoryOptions
        self.onClose = onClose
        self.onApply = onApply
        _selectedMealCategory = State(initialValue: mealCategory)
    }

    private var portionMultiplier: Double {
        let normalized = portionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
        return max(0.05, min(20.0, Double(normalized) ?? 1))
    }

    private var estimatedCalories: Double {
        baseCalories * portionMultiplier
    }

    private var portionOptions: [RecipeServingSizeOption] {
        if !servingSizeOptions.isEmpty { return servingSizeOptions }
        return [
            RecipeServingSizeOption(value: 0.5, nutritionMultiplier: 0.5, label: "1/2份"),
            RecipeServingSizeOption(value: 1, nutritionMultiplier: 1, label: "1份"),
            RecipeServingSizeOption(value: 1.5, nutritionMultiplier: 1.5, label: "1.5份"),
            RecipeServingSizeOption(value: 2, nutritionMultiplier: 2, label: "2份"),
        ]
    }

    private var selectedServingSizeLabel: String? {
        portionOptions.first { abs($0.nutritionMultiplier - portionMultiplier) < 0.01 }?.displayLabel
    }

    private var estimatedTotalCalories: Double {
        estimatedCalories * Double(dayCount)
    }

    private var targetDateLabel: String {
        if Calendar.current.isDateInToday(selectedDate) { return "今天" }
        if Calendar.current.isDateInTomorrow(selectedDate) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: selectedDate)
    }

    private var targetDateStrings: [String] {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: selectedDate) else { return nil }
            return formatter.string(from: date)
        }
    }

    private var dateRangeLabel: String {
        guard dayCount > 1,
              let lastDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: dayCount - 1, to: selectedDate) else {
            return targetDateLabel
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(targetDateLabel) - \(formatter.string(from: lastDate))"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("记录份数")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        HStack(spacing: 10) {
                            TextField("份", text: $portionText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 28, weight: .black))
                                .frame(height: 56)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(Capsule())
                            Text("份")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                            ForEach(portionOptions) { option in
                                quickPortionButton(option.nutritionMultiplier, option.displayLabel)
                            }
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("加入餐次")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(mealCategoryOptions, id: \.0) { option in
                                Button {
                                    selectedMealCategory = option.0
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: option.2)
                                            .font(.system(size: 12, weight: .black))
                                            .accessibilityHidden(true)
                                        Text(option.1)
                                            .font(.system(size: 13, weight: .black))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(selectedMealCategory == option.0 ? .white : Color(hex: "111318"))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(selectedMealCategory == option.0 ? Color.black : Color(hex: "F7F8FA"))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("记录日期")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        DatePicker("目标日期", selection: $selectedDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("可预先记录未来餐食，之后在对应日期继续调整份量。")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("连续记录")
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                Text(dayCount == 1 ? "只记录选中日期" : "\(dateRangeLabel) · 共 \(dayCount) 天")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Stepper("", value: $dayCount, in: 1...7)
                                .labelsHidden()
                        }
                        Text("适合固定早餐、咖啡或常吃餐品；我会逐天写入真实饮食记录。")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: "6B7280"))
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("预计记录")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.secondary)
                            Text("\(Int(round(estimatedTotalCalories))) 千卡")
                                .font(.system(size: 28, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("\(dateRangeLabel) · \(mealCategoryOptions.first { $0.0 == selectedMealCategory }?.1 ?? "加餐")")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(Color(hex: "6B7280"))
                        }
                        Spacer()
                        Button {
                            onApply(portionMultiplier, selectedMealCategory, targetDateStrings, selectedServingSizeLabel)
                        } label: {
                            Text(dayCount == 1 ? "加入" : "加入\(dayCount)天")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 118, height: 52)
                                .background(Color.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(18)
                    .background(Color(hex: "EEF7FF"))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(20)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onClose)
                        .font(.system(size: 15, weight: .black))
                }
            }
        }
    }

    private func quickPortionButton(_ value: Double, _ label: String) -> some View {
        Button {
            portionText = value == floor(value) ? "\(Int(value))" : String(format: "%.1f", value)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(abs(portionMultiplier - value) < 0.01 ? .white : Color(hex: "111318"))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(abs(portionMultiplier - value) < 0.01 ? Color.black : Color(hex: "F7F8FA"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SmallPlanMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .black))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MealPlanRecipeCollectionCard: View {
    let collection: MealPlanRecipeCollection
    let onSelect: () -> Void

    private var imageURL: URL? {
        guard let imageURL = collection.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty else {
            return nil
        }
        return URL(string: imageURL)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    collectionImage
                    VStack(alignment: .leading, spacing: 4) {
                        Text(collection.title)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        Text(collection.description)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: "6B7280"))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    collectionBadge("\(collection.recipeCount)个食谱", color: Color(hex: "111318"))
                    if let calorieRange = collection.calorieRange?.trimmingCharacters(in: .whitespacesAndNewlines), !calorieRange.isEmpty {
                        collectionBadge(calorieRange, color: Color(hex: "F59E0B"))
                    }
                }

                VStack(spacing: 6) {
                    ForEach(collection.recipes.prefix(2)) { recipe in
                        MealPlanCollectionRecipePill(recipe: recipe)
                    }
                }
            }
            .padding(12)
            .frame(width: 238, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(collection.title)")
    }

    private var collectionImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "EEF2FF"))
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "fork.knife")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(hex: "6366F1"))
                    }
                }
            } else {
                Image(systemName: "fork.knife")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "6366F1"))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func collectionBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(hex: "F7F8FA"))
            .clipShape(Capsule())
    }
}

private struct MealPlanCollectionRecipePill: View {
    let recipe: MealPlanRecipeCollectionRecipe

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(Int(round(recipe.calories)))千卡 · 蛋白\(Int(round(recipe.protein)))克")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "9CA3AF"))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if recipe.favorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "EF4444"))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct FrequentFood: Identifiable {
    let id: String
    let name: String
    let count: Int
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let sugar: Double
    let sodium: Double
    let servingSize: String

    init(
        id: String,
        name: String,
        count: Int,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        fiber: Double,
        sugar: Double,
        sodium: Double,
        servingSize: String
    ) {
        self.id = id
        self.name = name
        self.count = count
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
        self.servingSize = servingSize
    }

    init?(item: FrequentFoodItem) {
        let cleanName = (item.foodName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        let cleanServingSize = (item.servingSize ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: item.id ?? "frequent-\(cleanName)",
            name: cleanName,
            count: max(1, item.logCount ?? 1),
            calories: item.calories ?? 0,
            protein: item.protein ?? 0,
            carbs: item.carbs ?? 0,
            fat: item.fat ?? 0,
            fiber: item.fiber ?? 0,
            sugar: item.sugar ?? 0,
            sodium: item.sodium ?? 0,
            servingSize: cleanServingSize.isEmpty ? "估算份量" : cleanServingSize
        )
    }

    var foodItem: FoodItem {
        FoodItem(
            id: id,
            name: name,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            fiber: fiber,
            sugar: sugar,
            sodium: sodium,
            servingSize: servingSize,
            processingLevel: "whole",
            addedSugar: sugar
        )
    }
}

private struct MealPlanDayProgress: View {
    let day: MealPlanDay
    let targets: MealPlanTargets?

    private var calories: Double { day.meals.reduce(0) { $0 + $1.calories } }
    private var protein: Double { day.meals.reduce(0) { $0 + $1.protein } }
    private var carbs: Double { day.meals.reduce(0) { $0 + $1.carbs } }
    private var fat: Double { day.meals.reduce(0) { $0 + $1.fat } }

    var body: some View {
        VStack(spacing: 8) {
            dayMetric(label: "热量", value: calories, target: targets?.calories ?? calories, unit: "千卡", color: Color(hex: "111318"))
            dayMetric(label: "蛋白", value: protein, target: targets?.protein ?? protein, unit: "克", color: Color(hex: "F87171"))
            dayMetric(label: "碳水", value: carbs, target: targets?.carbs ?? carbs, unit: "克", color: Color(hex: "F59E0B"))
            dayMetric(label: "脂肪", value: fat, target: targets?.fat ?? fat, unit: "克", color: Color(hex: "60A5FA"))
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func dayMetric(label: String, value: Double, target: Double, unit: String, color: Color) -> some View {
        let safeTarget = max(target, 1)
        let progress = min(max(value / safeTarget, 0), 1.25)
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "4B5563"))
                    .frame(width: 34, alignment: .leading)
                Text("\(Int(round(value)))/\(Int(round(safeTarget)))\(unit)")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(progress > 1.05 ? "偏高" : "合适")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(progress > 1.05 ? Color(hex: "EF4444") : Color(hex: "16A34A"))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "E9ECF1"))
                    Capsule()
                        .fill(progress > 1.05 ? Color(hex: "EF4444") : color)
                        .frame(width: proxy.size.width * min(progress, 1))
                }
            }
            .frame(height: 6)
        }
    }
}

private struct NutritionLabelFoodSheetView: View {
    let logDate: String
    let mealCategory: String
    let onClose: () -> Void
    let onSaved: (SavedFoodItem) -> Void
    let onLogged: () -> Void

    @State private var name = ""
    @State private var brand = ""
    @State private var servingSize = "1份"
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var fiber = ""
    @State private var sugar = ""
    @State private var sodium = ""
    @State private var saving = false
    @State private var logging = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("营养表")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("按包装营养成分表录入每份数据，可保存到我的食物。")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "4B5563"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        labelInput("食物名称", placeholder: "例如：高蛋白牛奶", text: $name)
                        labelInput("品牌", placeholder: "可选", text: $brand)
                        labelInput("每份份量", placeholder: "例如：250毫升 / 40克", text: $servingSize)
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("每份营养")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            numberInput("热量", unit: "千卡", text: $calories)
                            numberInput("蛋白", unit: "克", text: $protein)
                            numberInput("碳水", unit: "克", text: $carbs)
                            numberInput("脂肪", unit: "克", text: $fat)
                            numberInput("纤维", unit: "克", text: $fiber)
                            numberInput("糖", unit: "克", text: $sugar)
                            numberInput("钠", unit: "毫克", text: $sodium)
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Text("关闭")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(.white)
                            .foregroundStyle(Color(hex: "111318"))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await saveLabelFood(logAfterSave: false) }
                    } label: {
                        Text(saving ? "保存中" : "保存")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || !canSubmit)
                    .opacity(canSubmit ? 1 : 0.45)

                    Button {
                        Task { await saveLabelFood(logAfterSave: true) }
                    } label: {
                        Text(logging ? "记录中" : "记录")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(hex: "6FD19A"))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || !canSubmit)
                    .opacity(canSubmit ? 1 : 0.45)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && numeric(calories) > 0
    }

    private var foodItem: FoodItem {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanBrand.isEmpty ? cleanName : "\(cleanBrand) \(cleanName)"
        return FoodItem(
            name: displayName,
            calories: numeric(calories),
            protein: numeric(protein),
            carbs: numeric(carbs),
            fat: numeric(fat),
            fiber: numeric(fiber),
            sugar: numeric(sugar),
            sodium: numeric(sodium),
            servingSize: servingSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1份" : servingSize.trimmingCharacters(in: .whitespacesAndNewlines),
            processingLevel: "processed",
            addedSugar: numeric(sugar)
        )
    }

    private func saveLabelFood(logAfterSave: Bool) async {
        guard !saving, !logging, canSubmit else { return }
        saving = !logAfterSave
        logging = logAfterSave
        message = ""
        do {
            let saved = try await APIClient.shared.saveFoodTemplate(foodItem)
            onSaved(saved)
            if logAfterSave {
                _ = try await APIClient.shared.logSavedFood(id: saved.id, mealCategory: mealCategory, date: logDate)
                onLogged()
            } else {
                message = "已保存到我的食物。"
            }
        } catch {
            message = infoFriendlyError(error, fallback: "保存标签食物失败")
        }
        saving = false
        logging = false
    }

    private func labelInput(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(.system(size: 15, weight: .black))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func numberInput(_ label: String, unit: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(label, text: text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 17, weight: .black))
                Text(unit)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

private func numeric(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}

private struct BarcodeLookupSheetView: View {
    let onClose: () -> Void
    let onFoodFound: (FoodItem) -> Void

    @State private var barcode = ""
    @State private var loading = false
    @State private var result: DescribeMealResponse?
    @State private var message = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("条形码")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("输入包装食品条码，查询后可确认份数并记录到当前餐次。")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "barcode.viewfinder")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(width: 44, height: 44)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .accessibilityHidden(true)
                            TextField("输入包装条码", text: $barcode)
                                .keyboardType(.numberPad)
                                .font(.system(size: 20, weight: .black))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(12)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button {
                            Task { await lookup() }
                        } label: {
                            HStack(spacing: 8) {
                                if loading {
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(0.82)
                                } else {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 13, weight: .black))
                                        .accessibilityHidden(true)
                                }
                                Text(loading ? "查询中" : "查询条形码")
                                    .font(.system(size: 15, weight: .black))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.black)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(loading || validBarcode == nil)
                        .opacity(loading || validBarcode == nil ? 0.45 : 1)

                        if !barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validBarcode == nil {
                            Text("请输入 8–14 位数字条形码。")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: "D93025"))
                        }
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(infoMessageNeedsAttention(message) ? Color(hex: "DC2626") : Color(hex: "4B5563"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    if let food = result?.foods.first {
                        barcodeFoodCard(food)
                    }
                }
                .padding(20)
                .padding(.bottom, 82)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Text("关闭")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(.white)
                            .foregroundStyle(Color(hex: "111318"))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let food = result?.foods.first {
                            onFoodFound(food)
                        }
                    } label: {
                        Text("确认份数")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(result?.foods.first == nil ? Color(hex: "D1D5DB") : Color.black)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(result?.foods.first == nil)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var normalizedBarcode: String {
        barcode
            .filter { $0.isNumber }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validBarcode: String? {
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...14).contains(code.count), code.allSatisfy(\.isNumber) else { return nil }
        return code
    }

    private func barcodeFoodCard(_ food: FoodItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(hex: "2563EB"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(food.name)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(3)
                    Text(food.servingSize)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(food.calories)))")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                barcodeMacroPill("蛋白", value: food.protein, unit: "克")
                barcodeMacroPill("碳水", value: food.carbs, unit: "克")
                barcodeMacroPill("脂肪", value: food.fat, unit: "克")
            }
            HStack(spacing: 8) {
                barcodeMacroPill("纤维", value: food.fiber, unit: "克")
                barcodeMacroPill("糖", value: food.sugar, unit: "克")
                barcodeMacroPill("钠", value: food.sodium, unit: "毫克")
            }

            Button {
                onFoodFound(food)
            } label: {
                Text("确认份数并记录")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func barcodeMacroPill(_ label: String, value: Double, unit: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            Text("\(Self.numberText(value))\(unit)")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func lookup() async {
        guard !loading else { return }
        guard let code = validBarcode else {
            message = "请输入 8–14 位数字条形码。"
            result = nil
            return
        }
        loading = true
        message = ""
        result = nil
        defer { loading = false }
        do {
            let response = try await APIClient.shared.lookupBarcode(code)
            guard let first = response.foods.first else {
                message = response.description ?? "这个条形码还没有对应食品，可以拍营养成分表或手动创建。"
                return
            }
            result = response
            message = "已找到：\(first.name)"
        } catch {
            message = infoFriendlyError(error, fallback: "条形码查询失败")
        }
    }

    private static func numberText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }
}

private struct DatabaseFoodDetailSheetView: View {
    let food: FoodItem
    let logDate: String
    let mealCategory: String
    let onClose: () -> Void
    let onSaved: (SavedFoodItem) -> Void
    let onLogged: () -> Void

    @State private var portionMultiplierText = "1"
    @State private var saving = false
    @State private var logging = false
    @State private var message = ""

    private var portionMultiplier: Double {
        let normalized = portionMultiplierText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return max(0.05, min(20.0, Double(normalized) ?? 1))
    }

    private var scaledFood: FoodItem {
        let multiplier = portionMultiplier
        let serving: String
        if abs(multiplier - 1) < 0.001 {
            serving = food.servingSize
        } else {
            serving = "\(Self.numberText(multiplier))份 × \(food.servingSize)"
        }
        return FoodItem(
            id: food.id,
            name: food.name,
            calories: food.calories * multiplier,
            protein: food.protein * multiplier,
            carbs: food.carbs * multiplier,
            fat: food.fat * multiplier,
            fiber: food.fiber * multiplier,
            sugar: food.sugar * multiplier,
            sodium: food.sodium * multiplier,
            servingSize: serving,
            processingLevel: food.processingLevel,
            addedSugar: food.addedSugar * multiplier
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "4B5563"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(food.name)
                            .font(.system(size: 26, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(3)
                        Text(food.servingSize)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            nutritionMetric("热量", "\(Int(round(food.calories)))千卡")
                            nutritionMetric("蛋白", "\(Self.numberText(food.protein))克")
                            nutritionMetric("碳水", "\(Self.numberText(food.carbs))克")
                            nutritionMetric("脂肪", "\(Self.numberText(food.fat))克")
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                    portionCard

                    VStack(alignment: .leading, spacing: 10) {
                        Text("本次记录")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        HStack(spacing: 10) {
                            nutritionMetric("热量", "\(Int(round(scaledFood.calories)))千卡")
                            nutritionMetric("蛋白", "\(Self.numberText(scaledFood.protein))克")
                            nutritionMetric("碳水", "\(Self.numberText(scaledFood.carbs))克")
                            nutritionMetric("脂肪", "\(Self.numberText(scaledFood.fat))克")
                        }
                        HStack(spacing: 10) {
                            nutritionMetric("纤维", "\(Self.numberText(scaledFood.fiber))克")
                            nutritionMetric("糖", "\(Self.numberText(scaledFood.sugar))克")
                            nutritionMetric("钠", "\(Int(round(scaledFood.sodium)))毫克")
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Text("关闭")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(.white)
                            .foregroundStyle(Color(hex: "111318"))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await saveFood() }
                    } label: {
                        Text(saving ? "保存中" : "收藏")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging)

                    Button {
                        Task { await logFood() }
                    } label: {
                        Text(logging ? "记录中" : "记录")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(hex: "6FD19A"))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var portionCard: some View {
        let multiplier = portionMultiplier
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记录份数")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("先确认份数，再加入\(mealCategoryTitle(mealCategory))。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("份", text: $portionMultiplierText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 17, weight: .black))
                        .frame(width: 54)
                    Text("份")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            }

            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                    Button {
                        portionMultiplierText = value == floor(value) ? "\(Int(value))" : String(format: "%.1f", value)
                    } label: {
                        Text(value == floor(value) ? "\(Int(value))份" : "\(Self.numberText(value))份")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(abs(multiplier - value) < 0.01 ? .white : Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(abs(multiplier - value) < 0.01 ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func nutritionMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func saveFood() async {
        guard !saving else { return }
        saving = true
        message = ""
        do {
            let saved = try await APIClient.shared.saveFoodTemplate(food)
            onSaved(saved)
            message = "已保存到我的食物。"
        } catch {
            message = infoFriendlyError(error, fallback: "收藏失败")
        }
        saving = false
    }

    private func logFood() async {
        guard !logging else { return }
        logging = true
        message = ""
        do {
            var item = scaledFood
            item.date = logDate
            _ = try await APIClient.shared.logFoods(
                [item],
                mealCategory: mealCategory,
                groupTitle: mealCategoryTitle(mealCategory),
                date: logDate
            )
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "记录失败")
        }
        logging = false
    }

    private func mealCategoryTitle(_ key: String) -> String {
        switch key {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        default: return "加餐"
        }
    }

    private static func numberText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }
}

private struct SavedFoodDetailSheetView: View {
    let item: SavedFoodItem
    let logDate: String
    let mealCategory: String
    let onClose: () -> Void
    let onUpdated: (SavedFoodItem) -> Void
    let onCreated: (SavedFoodItem) -> Void
    let onLogged: () -> Void

    @State private var name: String
    @State private var servingSize: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var fiber: String
    @State private var sugar: String
    @State private var sodium: String
    @State private var portionMultiplierText = "1"
    @State private var selectedMealCategory: String
    @State private var saving = false
    @State private var duplicating = false
    @State private var logging = false
    @State private var message = ""

    private let mealCategoryOptions = [
        ("breakfast", "早餐", "sunrise.fill"),
        ("lunch", "午餐", "sun.max.fill"),
        ("dinner", "晚餐", "moon.stars.fill"),
        ("snack", "加餐", "leaf.fill"),
    ]

    init(
        item: SavedFoodItem,
        logDate: String,
        mealCategory: String,
        onClose: @escaping () -> Void,
        onUpdated: @escaping (SavedFoodItem) -> Void,
        onCreated: @escaping (SavedFoodItem) -> Void,
        onLogged: @escaping () -> Void
    ) {
        self.item = item
        self.logDate = logDate
        self.mealCategory = mealCategory
        self.onClose = onClose
        self.onUpdated = onUpdated
        self.onCreated = onCreated
        self.onLogged = onLogged
        _name = State(initialValue: item.name)
        _servingSize = State(initialValue: item.food.servingSize)
        _calories = State(initialValue: SavedFoodDetailSheetView.numberText(item.food.calories))
        _protein = State(initialValue: SavedFoodDetailSheetView.numberText(item.food.protein))
        _carbs = State(initialValue: SavedFoodDetailSheetView.numberText(item.food.carbs))
        _fat = State(initialValue: SavedFoodDetailSheetView.numberText(item.food.fat))
        _fiber = State(initialValue: SavedFoodDetailSheetView.numberText(item.food.fiber))
        _sugar = State(initialValue: SavedFoodDetailSheetView.numberText(item.food.sugar))
        _sodium = State(initialValue: SavedFoodDetailSheetView.numberText(item.food.sodium))
        _selectedMealCategory = State(initialValue: SavedFoodDetailSheetView.normalizedMealCategory(mealCategory))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "4B5563"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("基础信息")
                            .font(.system(size: 15, weight: .black))
                        TextField("食物名称", text: $name)
                            .font(.system(size: 17, weight: .black))
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        TextField("份量，例如 100克", text: $servingSize)
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("营养")
                            .font(.system(size: 15, weight: .black))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            nutrientField("热量", unit: "千卡", text: $calories)
                            nutrientField("蛋白", unit: "克", text: $protein)
                            nutrientField("碳水", unit: "克", text: $carbs)
                            nutrientField("脂肪", unit: "克", text: $fat)
                            nutrientField("纤维", unit: "克", text: $fiber)
                            nutrientField("糖", unit: "克", text: $sugar)
                            nutrientField("钠", unit: "毫克", text: $sodium)
                        }
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                    foodPortionCard
                    foodDefaultCategoryCard
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Text("关闭")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(.white)
                            .foregroundStyle(Color(hex: "111318"))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await saveFood() }
                    } label: {
                        Text(saving ? "保存中" : "保存")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || duplicating)

                    Button {
                        Task { await logEditedFood() }
                    } label: {
                        Text(logging ? "记录中" : "记录")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(hex: "6FD19A"))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || logging || duplicating)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func nutrientField(_ label: String, unit: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(label, text: text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 17, weight: .black))
                Text(unit)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var foodDefaultCategoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记录到")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("选择这次要加入的餐次，保存食物本身不会改变历史记录。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(mealCategoryTitle(selectedMealCategory))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                ForEach(mealCategoryOptions, id: \.0) { option in
                    Button {
                        selectedMealCategory = option.0
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: option.2)
                                .font(.system(size: 11, weight: .black))
                                .accessibilityHidden(true)
                            Text(option.1)
                                .font(.system(size: 11, weight: .black))
                        }
                        .foregroundStyle(selectedMealCategory == option.0 ? .white : Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(selectedMealCategory == option.0 ? Color.black : Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录到\(option.1)")
                }
            }

            Button {
                Task { await duplicateFood() }
            } label: {
                HStack(spacing: 8) {
                    if duplicating {
                        ProgressView()
                            .tint(Color(hex: "111318"))
                            .scaleEffect(0.82)
                    } else {
                        Image(systemName: "plus.square.on.square")
                            .font(.system(size: 13, weight: .black))
                            .accessibilityHidden(true)
                    }
                    Text(duplicating ? "另存中" : "另存为新食物")
                        .font(.system(size: 13, weight: .black))
                }
                .foregroundStyle(Color(hex: "111318"))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(saving || logging || duplicating)
            .accessibilityLabel("把当前编辑内容另存为新食物")
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var editedFood: FoodItem {
        FoodItem(
            id: item.food.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.name : name.trimmingCharacters(in: .whitespacesAndNewlines),
            calories: numeric(calories),
            protein: numeric(protein),
            carbs: numeric(carbs),
            fat: numeric(fat),
            fiber: numeric(fiber),
            sugar: numeric(sugar),
            sodium: numeric(sodium),
            servingSize: servingSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.food.servingSize : servingSize.trimmingCharacters(in: .whitespacesAndNewlines),
            processingLevel: item.food.processingLevel,
            addedSugar: numeric(sugar)
        )
    }

    private var portionMultiplier: Double {
        let normalized = portionMultiplierText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return max(0.05, min(20.0, Double(normalized) ?? 1))
    }

    private var foodPortionCard: some View {
        let multiplier = portionMultiplier
        let food = editedFood
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记录份数")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存的是基础份量，记录时按这里换算。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("份", text: $portionMultiplierText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 17, weight: .black))
                        .frame(width: 54)
                    Text("份")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            }

            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                    Button {
                        portionMultiplierText = value == floor(value) ? "\(Int(value))" : String(format: "%.1f", value)
                    } label: {
                        Text(value == floor(value) ? "\(Int(value))份" : "\(Self.numberText(value))份")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(abs(multiplier - value) < 0.01 ? .white : Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(abs(multiplier - value) < 0.01 ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录\(Self.numberText(value))份\(food.name)")
                }
            }

            HStack(spacing: 10) {
                foodLogMetric("本次热量", "\(Int(round(food.calories * multiplier)))千卡")
                foodLogMetric("蛋白", "\(Self.numberText(food.protein * multiplier))克")
                foodLogMetric("碳水", "\(Self.numberText(food.carbs * multiplier))克")
                foodLogMetric("脂肪", "\(Self.numberText(food.fat * multiplier))克")
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func foodLogMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func saveFood() async {
        guard !saving else { return }
        saving = true
        message = ""
        do {
            let updated = try await APIClient.shared.updateSavedFood(id: item.id, food: editedFood)
            onUpdated(updated)
            message = "已保存修改。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存失败")
        }
        saving = false
    }

    private func duplicateFood() async {
        guard !duplicating else { return }
        duplicating = true
        message = ""
        do {
            let created = try await APIClient.shared.saveFoodTemplate(editedFood)
            onCreated(created)
            message = "已另存为新食物。"
        } catch {
            message = infoFriendlyError(error, fallback: "另存失败")
        }
        duplicating = false
    }

    private func logEditedFood() async {
        guard !logging else { return }
        logging = true
        message = ""
        do {
            let updated = try await APIClient.shared.updateSavedFood(id: item.id, food: editedFood)
            onUpdated(updated)
            _ = try await APIClient.shared.logSavedFood(
                id: item.id,
                mealCategory: selectedMealCategory,
                date: logDate,
                portionMultiplier: portionMultiplier
            )
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "记录失败")
        }
        logging = false
    }

    private func mealCategoryTitle(_ key: String) -> String {
        mealCategoryOptions.first { $0.0 == key }?.1 ?? "加餐"
    }

    private static func normalizedMealCategory(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("breakfast") || text.contains("早餐") { return "breakfast" }
        if text.contains("lunch") || text.contains("午餐") { return "lunch" }
        if text.contains("dinner") || text.contains("晚餐") { return "dinner" }
        if text.contains("snack") || text.contains("加餐") || text.contains("零食") { return "snack" }
        return "snack"
    }

    private func numeric(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func numberText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }
}

private struct CreateManualRecipeSheetView: View {
    let logDate: String
    let mealCategory: String
    let savedRecipes: [IngredientRecipeHistoryItem]
    let onClose: () -> Void
    let onSaved: (IngredientRecipeHistoryItem, Bool) -> Void
    let onLogged: () -> Void

    @State private var title = ""
    @State private var servingsText = "1"
    @State private var servingSizeLabelText = "1份"
    @State private var activeTimeText = "20"
    @State private var inactiveTimeText = "0"
    @State private var tagsText = ""
    @State private var selectedRecipeMealTypes: Set<String> = []
    @State private var instructionsText = ""
    @State private var drafts: [RecipeIngredientDraft] = []
    @State private var searchQuery = ""
    @State private var searchResults: [FoodItem] = []
    @State private var searching = false
    @State private var bulkIngredientText = ""
    @State private var importingBulkIngredients = false
    @State private var replacingIngredientDraftId: String?
    @State private var saving = false
    @State private var logging = false
    @State private var message = ""

    private var servingsCount: Int {
        max(1, min(24, Int(servingsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1))
    }

    private var servingSizeLabel: String {
        let label = servingSizeLabelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "1份" : label
    }

    private var prepTimeMinutes: Int {
        min(480, activeTimeMinutes + inactiveTimeMinutes)
    }

    private var activeTimeMinutes: Int {
        max(0, min(480, Int(activeTimeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0))
    }

    private var inactiveTimeMinutes: Int {
        max(0, min(480, Int(inactiveTimeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0))
    }

    private var totalNutrition: RecipeTotals {
        drafts.reduce(RecipeTotals()) { partial, draft in
            partial.adding(draft.totals)
        }
    }

    private var perServingNutrition: RecipeTotals {
        totalNutrition.scaled(by: 1.0 / Double(servingsCount))
    }

    private var matchingSavedRecipe: IngredientRecipeHistoryItem? {
        let normalizedTitle = cleanTitle.casefoldedForMealMatching
        guard !normalizedTitle.isEmpty else { return nil }
        return savedRecipes.first { $0.recipe.title.casefoldedForMealMatching == normalizedTitle }
    }

    private var replacingIngredientName: String? {
        guard let replacingIngredientDraftId else { return nil }
        return drafts.first { $0.id == replacingIngredientDraftId }?.name
    }

    private var ingredientsNeedingMatch: [RecipeIngredientDraft] {
        drafts.filter { draft in
            let totals = draft.totals
            return totals.calories <= 0.05
                && totals.protein <= 0.05
                && totals.carbs <= 0.05
                && totals.fat <= 0.05
        }
    }

    private var matchedIngredients: [RecipeIngredientDraft] {
        drafts.filter { draft in
            !ingredientsNeedingMatch.contains { $0.id == draft.id }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("食谱名称，例如：番茄炒蛋", text: $title)
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .textInputAutocapitalization(.never)
                        Text("手动添加食材和克数，保存后可作为常用食谱反复记录。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        if let matchingSavedRecipe {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "16A34A"))
                                    .accessibilityHidden(true)
                                Text("将替换已有食谱“\(matchingSavedRecipe.recipe.title)”，避免我的食谱里出现重复。")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(hex: "16A34A"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(hex: "ECFDF5"))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        recipeMetaField("总份数", text: $servingsText, suffix: "份")
                        recipeTextMetaField("每份份量", text: $servingSizeLabelText, placeholder: "例如：1碗 / 1块 / 250克")
                        Text("有多少人份？总份数会决定每份营养，食材克数按整份食谱计算。")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            recipeMetaField("主动时间", text: $activeTimeText, suffix: "分")
                            recipeMetaField("等待时间", text: $inactiveTimeText, suffix: "分")
                        }
                        recipeTagField
                        recipeMealTypeField
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    recipeCreateGuideCard
                    nutritionSummaryCard

                    VStack(alignment: .leading, spacing: 12) {
                        Text("食材")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        bulkIngredientPasteCard
                        if !matchedIngredients.isEmpty {
                            ingredientMatchedSummaryCard
                        }
                        if !ingredientsNeedingMatch.isEmpty {
                            ingredientMatchNoticeCard
                        }
                        if drafts.isEmpty {
                            Text("先搜索并加入至少 1 个食材。")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            ForEach(Array(drafts.indices), id: \.self) { index in
                                ingredientEditorRow($drafts[index]) {
                                    if drafts.indices.contains(index) {
                                        drafts.remove(at: index)
                                    }
                                }
                            }
                        }
                        ingredientSearchCard
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    recipeDetailsCreateCard

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(infoMessageNeedsAttention(message) ? Color(hex: "EF4444") : Color(hex: "16A34A"))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveRecipe() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("保存食谱")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .disabled(saving || logging || drafts.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        Task { await saveRecipe() }
                    } label: {
                        Text(saving ? "保存中" : (matchingSavedRecipe == nil ? "保存食谱" : "替换食谱"))
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .disabled(saving || logging || drafts.isEmpty)

                    Button {
                        Task { await saveAndLogRecipe() }
                    } label: {
                        HStack(spacing: 8) {
                            if logging {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(logging ? "记录中" : "保存并记录")
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                    }
                    .disabled(saving || logging || drafts.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var recipeCreateGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "ECFDF5"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("创建我的食谱")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("适合家常菜、烘焙、一次做多份的配方；按份数换算营养。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                recipeGuideChip("结构", "食材+克数", "list.bullet.rectangle")
                recipeGuideChip("份数", "\(servingsCount)份", "divide.circle.fill")
                recipeGuideChip("每份", servingSizeLabel, "scalemass.fill")
                recipeGuideChip("用途", "按份记录", "plus.circle.fill")
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color(hex: "F8FFFB"), .white], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "DCFCE7"), lineWidth: 1))
    }

    private func recipeGuideChip(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "16A34A"))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func recipeMetaField(_ label: String, text: Binding<String>, suffix: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .black))
            Text(suffix)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private func recipeTextMetaField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 14, weight: .black))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var nutritionSummaryCard: some View {
        let totals = perServingNutrition
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每份营养")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.secondary)
                    Text("\(Int(round(totals.calories)))")
                        .font(.system(size: 42, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(servingsCount) 份")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color(hex: "EFF6FF"))
                        .clipShape(Capsule())
                    Text("每份 \(servingSizeLabel)")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                    Text("整份 \(Int(round(totalNutrition.calories))) 千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                macroPill("蛋白质", totals.protein, "克", Color(hex: "F87171"))
                macroPill("碳水", totals.carbs, "克", Color(hex: "F59E0B"))
                macroPill("脂肪", totals.fat, "克", Color(hex: "60A5FA"))
                macroPill("纤维", totals.fiber, "克", Color(hex: "22C55E"))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func macroPill(_ label: String, _ value: Double, _ unit: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(numberText(value))\(unit)")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var ingredientSearchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let replacingIngredientName {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .accessibilityHidden(true)
                    Text("正在匹配：\(replacingIngredientName)")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Spacer()
                    Button("取消") {
                        replacingIngredientDraftId = nil
                        searchResults = []
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color(hex: "EFF6FF"))
                .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(replacingIngredientDraftId == nil ? "搜索食材加入食谱" : "搜索食物并替换当前原料", text: $searchQuery)
                    .font(.system(size: 14, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await searchFoods() }
                    }
                Button {
                    Task { await searchFoods() }
                } label: {
                    if searching {
                        ProgressView()
                            .scaleEffect(0.72)
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
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            if !searchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(searchResults.prefix(6))) { food in
                        Button {
                            applyIngredientSearchResult(food)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(food.name)
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                        .lineLimit(1)
                                    Text("\(Int(round(food.calories))) 千卡 · 蛋白 \(numberText(food.protein))克 · \(food.servingSize)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: replacingIngredientDraftId == nil ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .accessibilityHidden(true)
                            }
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(replacingIngredientDraftId == nil ? "加入食材 \(food.name)" : "替换为食材 \(food.name)")
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var recipeDetailsCreateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("食谱细节")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存做法后，下次打开食谱或保存为餐品时可以继续查看。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("共\(prepTimeMinutes)")
                        .font(.system(size: 13, weight: .black))
                    Text("分钟")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            }

            TextEditor(text: $instructionsText)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "4B5563"))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 112)
                .padding(10)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            Text("每行一个步骤，例如：煮熟主食；少油炒熟蛋白和蔬菜；按份装盘。")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var ingredientMatchNoticeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "F59E0B"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("不匹配的配料")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("这些原料暂时没有完整营养值。点“匹配”后选择常见食物，会保留你输入的克数。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(ingredientsNeedingMatch.prefix(6)) { draft in
                Button {
                    beginReplacingIngredient(draft)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.name)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .lineLimit(1)
                            Text("该食谱需要“\(draft.name)”")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("匹配")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(hex: "2563EB"))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .background(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("匹配原料 \(draft.name)")
            }
        }
        .padding(12)
        .background(Color(hex: "FFFBEB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "FDE68A"), lineWidth: 1))
    }

    private var ingredientMatchedSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("匹配的配料")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("这些匹配项是否正确？不准确的可以点每行的替换按钮。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(matchedIngredients.count)项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "ECFDF5"))
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(matchedIngredients.prefix(6))) { draft in
                    Text("\(draft.name) · \(draft.gramsText)克")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.white)
                        .clipShape(Capsule())
                }
                if matchedIngredients.count > 6 {
                    Text("+\(matchedIngredients.count - 6)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F0FDF4"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "BBF7D0"), lineWidth: 1))
    }

    private var bulkIngredientPasteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .frame(width: 34, height: 34)
                    .background(Color(hex: "ECFDF5"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("粘贴原料")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("每行一种原料，例如：鸡胸肉 200克。会先匹配常见食物，未匹配的保留为待匹配原料。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextEditor(text: $bulkIngredientText)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "111318"))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 86)
                .padding(10)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            Button {
                Task { await importBulkIngredients() }
            } label: {
                HStack(spacing: 8) {
                    if importingBulkIngredients {
                        ProgressView()
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .accessibilityHidden(true)
                    }
                    Text(importingBulkIngredients ? "匹配中" : "解析并加入")
                }
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(importingBulkIngredients || bulkIngredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func ingredientEditorRow(_ draft: Binding<RecipeIngredientDraft>, onRemove: @escaping () -> Void) -> some View {
        let totals = draft.wrappedValue.totals
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.wrappedValue.name)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(Int(round(totals.calories))) 千卡 · 蛋白 \(numberText(totals.protein))克")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("克", text: draft.gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 58)
                Text("克")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            Button {
                beginReplacingIngredient(draft.wrappedValue)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 34, height: 34)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("匹配食材 \(draft.wrappedValue.name)")

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "EF4444"))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除食材 \(draft.wrappedValue.name)")
        }
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func searchFoods() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true
        message = ""
        do {
            searchResults = try await APIClient.shared.searchFoods(query: query)
        } catch {
            message = infoFriendlyError(error, fallback: "搜索食材失败")
        }
        searching = false
    }

    private func addFoodAsIngredient(_ food: FoodItem) {
        drafts.append(RecipeIngredientDraft(food: food))
        searchQuery = ""
        searchResults = []
        message = "已加入食材：\(food.name)。"
    }

    private func beginReplacingIngredient(_ draft: RecipeIngredientDraft) {
        replacingIngredientDraftId = draft.id
        searchQuery = draft.name
        searchResults = []
        message = "搜索并选择一个食物来匹配：\(draft.name)。"
        Task { await searchFoods() }
    }

    private func applyIngredientSearchResult(_ food: FoodItem) {
        if let replacingIngredientDraftId {
            replaceIngredient(id: replacingIngredientDraftId, with: food)
        } else {
            addFoodAsIngredient(food)
        }
    }

    private func replaceIngredient(id: String, with food: FoodItem) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            replacingIngredientDraftId = nil
            addFoodAsIngredient(food)
            return
        }
        let oldName = drafts[index].name
        let oldGramsText = drafts[index].gramsText
        var replacement = RecipeIngredientDraft(food: food)
        replacement.gramsText = oldGramsText
        drafts[index] = replacement
        replacingIngredientDraftId = nil
        searchQuery = ""
        searchResults = []
        message = "已用 \(food.name) 匹配 \(oldName)，克数已保留为 \(oldGramsText)克。"
    }

    private func importBulkIngredients() async {
        guard !importingBulkIngredients else { return }
        let parsedLines = parsedBulkIngredientLines(from: bulkIngredientText)
        guard !parsedLines.isEmpty else { return }
        importingBulkIngredients = true
        message = ""

        var importedDrafts: [RecipeIngredientDraft] = []
        var matchedCount = 0
        var unmatchedCount = 0

        for parsed in parsedLines.prefix(24) {
            do {
                let results = try await APIClient.shared.searchFoods(query: parsed.name)
                if let food = results.first {
                    var draft = RecipeIngredientDraft(food: food)
                    if let grams = parsed.grams, grams > 0 {
                        draft.gramsText = numberText(grams)
                    }
                    importedDrafts.append(draft)
                    matchedCount += 1
                } else {
                    importedDrafts.append(RecipeIngredientDraft(name: parsed.name, grams: parsed.grams))
                    unmatchedCount += 1
                }
            } catch {
                importedDrafts.append(RecipeIngredientDraft(name: parsed.name, grams: parsed.grams))
                unmatchedCount += 1
            }
        }

        drafts.append(contentsOf: importedDrafts)
        bulkIngredientText = ""
        importingBulkIngredients = false
        message = unmatchedCount == 0
            ? "已解析并匹配 \(matchedCount) 个原料。"
            : "已加入 \(matchedCount + unmatchedCount) 个原料，其中 \(unmatchedCount) 个需要手动匹配。"
    }

    private func saveRecipe() async {
        guard !saving, !drafts.isEmpty else { return }
        saving = true
        message = ""
        do {
            let matchingRecipe = matchingSavedRecipe
            let item = try await saveOrReplaceRecipe(matchingRecipe: matchingRecipe)
            onSaved(item, matchingRecipe != nil)
            message = matchingRecipe == nil ? "已保存食谱。" : "已替换同名食谱。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存食谱失败")
        }
        saving = false
    }

    private func saveAndLogRecipe() async {
        guard !logging, !drafts.isEmpty else { return }
        logging = true
        message = ""
        do {
            let matchingRecipe = matchingSavedRecipe
            let item = try await saveOrReplaceRecipe(matchingRecipe: matchingRecipe)
            onSaved(item, matchingRecipe != nil)
            _ = try await APIClient.shared.logIngredientRecipe(
                id: item.id,
                portionMultiplier: 1,
                servingSizeLabel: recipeServingSizeLabelForLog(item.recipe, multiplier: 1),
                mealCategory: mealCategory,
                date: logDate
            )
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "保存并记录失败")
        }
        logging = false
    }

    private func saveOrReplaceRecipe(matchingRecipe: IngredientRecipeHistoryItem?) async throws -> IngredientRecipeHistoryItem {
        let payload = recipePayload()
        if let matchingRecipe {
            let response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                id: matchingRecipe.id,
                recipePayload: payload
            )
            return response.item ?? IngredientRecipeHistoryItem(
                id: matchingRecipe.id,
                date: matchingRecipe.date,
                source: matchingRecipe.source,
                logged: matchingRecipe.logged,
                createdAt: matchingRecipe.createdAt,
                loggedAt: matchingRecipe.loggedAt,
                loggedCount: matchingRecipe.loggedCount,
                recipe: response.recipe
            )
        }
        let response = try await APIClient.shared.createIngredientRecipeSuggestion(
            recipePayload: payload,
            date: logDate,
            source: "manual"
        )
        return response.item ?? IngredientRecipeHistoryItem(
            id: response.recipeId ?? response.recipe.id,
            date: logDate,
            source: "manual",
            logged: 0,
            createdAt: nil,
            loggedAt: nil,
            loggedCount: 0,
            recipe: response.recipe
        )
    }

    private func recipePayload() -> [String: Any] {
        let totals = perServingNutrition
        return [
            "title": cleanTitle,
            "servings": servingsCount,
            "serving_size_label": servingSizeLabel,
            "calories": round1(totals.calories),
            "protein": round1(totals.protein),
            "carbs": round1(totals.carbs),
            "fat": round1(totals.fat),
            "fiber": round1(totals.fiber),
            "sodium": round1(totals.sodium),
            "sugar": round1(totals.sugar),
            "prep_time_minutes": prepTimeMinutes,
            "active_time_minutes": activeTimeMinutes,
            "inactive_time_minutes": inactiveTimeMinutes,
            "reason": "手动创建",
            "instructions": cleanInstructions,
            "ingredients_breakdown": drafts.map { $0.payload },
            "missing_ingredients": ingredientsNeedingMatch.map(\.name),
            "source": "manual",
            "tags": cleanTags.isEmpty ? ["手动食谱"] : cleanTags,
            "meal_types": cleanMealTypes
        ]
    }

    private var cleanTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let generated = drafts.prefix(2).map(\.name).joined(separator: " + ")
        return generated.isEmpty ? "我的食谱" : generated
    }

    private var cleanInstructions: [String] {
        let steps = instructionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return steps.isEmpty ? ["按个人口味烹饪并记录实际食用份数。"] : steps
    }

    private var cleanTags: [String] {
        tagsText
            .components(separatedBy: CharacterSet(charactersIn: ",，、# "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, tag in
                if !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    result.append(tag)
                }
            }
    }

    private var cleanMealTypes: [String] {
        let selected = RecipeMealType.all.map(\.id).filter { selectedRecipeMealTypes.contains($0) }
        if !selected.isEmpty {
            return selected
        }
        return [RecipeMealType.normalized(mealCategory) ?? "dinner"]
    }

    private var recipeTagField: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "2563EB"))
                .accessibilityHidden(true)
            TextField("标签，例如：家常、高蛋白、早餐", text: $tagsText)
                .font(.system(size: 13, weight: .bold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var recipeMealTypeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .accessibilityHidden(true)
                Text("适用餐次")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                Text("影响餐单放在哪一餐")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "9CA3AF"))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(RecipeMealType.all) { option in
                    let selected = cleanMealTypes.contains(option.id)
                    Button {
                        if selectedRecipeMealTypes.contains(option.id) {
                            selectedRecipeMealTypes.remove(option.id)
                        } else {
                            selectedRecipeMealTypes.insert(option.id)
                        }
                    } label: {
                        Label(option.title, systemImage: option.icon)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(selected ? .white : Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(selected ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(selected ? "取消" : "选择")食谱适用\(option.title)")
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func numberText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }

    private func parsedBulkIngredientLines(from text: String) -> [ParsedBulkIngredientLine] {
        text
            .components(separatedBy: .newlines)
            .map { ParsedBulkIngredientLine(raw: $0) }
            .compactMap { $0 }
    }

    private struct ParsedBulkIngredientLine {
        let name: String
        let grams: Double?

        init?(raw: String) {
            let cleaned = raw
                .replacingOccurrences(of: "，", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }

            var parsedGrams: Double?
            var nameText = cleaned
            if let amountRange = cleaned.range(
                of: #"(\d+(?:[.,]\d+)?)\s*(克|g|G|毫升|ml|mL|ML)"#,
                options: .regularExpression
            ) {
                let amountText = String(cleaned[amountRange])
                let numberText = amountText
                    .replacingOccurrences(of: ",", with: ".")
                    .filter { $0.isNumber || $0 == "." }
                parsedGrams = Double(numberText)
                nameText.removeSubrange(amountRange)
            }

            let trimmedName = nameText
                .trimmingCharacters(in: CharacterSet(charactersIn: " -—–_:：*×xX，,、；;").union(.whitespacesAndNewlines))
            name = trimmedName.isEmpty ? cleaned : trimmedName
            grams = parsedGrams
        }
    }
}

private struct CreateSavedMealSheetView: View {
    let logDate: String
    let mealCategory: String
    let savedMeals: [SavedMealItem]
    let onClose: () -> Void
    let onSaved: (SavedMealItem, Bool) -> Void
    let onLogged: () -> Void

    @State private var title = ""
    @State private var note = ""
    @State private var instructionsText = ""
    @State private var drafts: [SavedMealFoodDraft] = []
    @State private var searchQuery = ""
    @State private var searchResults: [FoodItem] = []
    @State private var searching = false
    @State private var saving = false
    @State private var logging = false
    @State private var message = ""

    private var editedFoods: [FoodItem] {
        drafts.map(\.foodItem)
    }

    private var calories: Double { editedFoods.reduce(0) { $0 + $1.calories } }
    private var protein: Double { editedFoods.reduce(0) { $0 + $1.protein } }
    private var carbs: Double { editedFoods.reduce(0) { $0 + $1.carbs } }
    private var fat: Double { editedFoods.reduce(0) { $0 + $1.fat } }
    private var fiber: Double { editedFoods.reduce(0) { $0 + $1.fiber } }
    private var sugar: Double { editedFoods.reduce(0) { $0 + $1.sugar } }
    private var sodium: Double { editedFoods.reduce(0) { $0 + $1.sodium } }
    private var addedSugar: Double { editedFoods.reduce(0) { $0 + $1.addedSugar } }
    private var satFat: Double { editedFoods.reduce(0) { $0 + $1.satFat } }
    private var transFat: Double { editedFoods.reduce(0) { $0 + $1.transFat } }
    private var cholesterol: Double { editedFoods.reduce(0) { $0 + $1.cholesterol } }
    private var vitaminA: Double { editedFoods.reduce(0) { $0 + $1.vitaminA } }
    private var vitaminC: Double { editedFoods.reduce(0) { $0 + $1.vitaminC } }
    private var calcium: Double { editedFoods.reduce(0) { $0 + $1.calcium } }
    private var iron: Double { editedFoods.reduce(0) { $0 + $1.iron } }
    private var potassium: Double { editedFoods.reduce(0) { $0 + $1.potassium } }

    private var matchingSavedMeal: SavedMealItem? {
        let normalizedTitle = cleanTitle.casefoldedForMealMatching
        guard !normalizedTitle.isEmpty else { return nil }
        return savedMeals.first { $0.title.casefoldedForMealMatching == normalizedTitle }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("餐品名称，例如：高蛋白早餐", text: $title)
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .textInputAutocapitalization(.never)
                        Text("从常见食物添加，组合成常吃餐品后可反复记录。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        if let matchingSavedMeal {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "2563EB"))
                                    .accessibilityHidden(true)
                                Text("将替换已有餐品“\(matchingSavedMeal.title)”，避免我的餐品里出现重复。")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(hex: "2563EB"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(hex: "EFF6FF"))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    mealCreateGuideCard
                    mealNotesCard
                    mealSummaryCard

                    VStack(alignment: .leading, spacing: 12) {
                        Text("食物")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        if drafts.isEmpty {
                            Text("先搜索并加入至少 1 个食物。")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            ForEach(Array(drafts.indices), id: \.self) { index in
                                foodEditorRow($drafts[index]) {
                                    if drafts.indices.contains(index) {
                                        drafts.remove(at: index)
                                    }
                                }
                            }
                        }
                        searchCard
                    }
                    .padding(18)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(infoMessageNeedsAttention(message) ? Color(hex: "EF4444") : Color(hex: "16A34A"))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveMeal() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("保存餐品")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .disabled(saving || logging || drafts.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        Task { await saveMeal() }
                    } label: {
                        Text(saving ? "保存中" : (matchingSavedMeal == nil ? "保存餐品" : "替换餐品"))
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .disabled(saving || logging || drafts.isEmpty)

                    Button {
                        Task { await saveAndLogMeal() }
                    } label: {
                        HStack(spacing: 8) {
                            if logging {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(logging ? "记录中" : "保存并记录")
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                    }
                    .disabled(saving || logging || drafts.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var mealCreateGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("创建我的餐品")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("适合早餐套餐、工作餐、固定便当这类整餐模板。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                mealGuideChip("默认餐次", mealCategoryLabel, "tray.full.fill")
                mealGuideChip("添加方式", "搜索食物", "magnifyingglass")
                mealGuideChip("记录方式", "一键复用", "plus.circle.fill")
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color(hex: "F8FBFF"), .white], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "E6EEF8"), lineWidth: 1))
    }

    private var mealNotesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("餐品说明")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("可保存做法、口味、搭配或备餐提示。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            TextField("备注，例如：少油，适合训练后", text: $note, axis: .vertical)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1...3)
                .padding(12)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            TextField("制作说明，例如：鸡胸肉提前煎好，米饭分装", text: $instructionsText, axis: .vertical)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2...5)
                .padding(12)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var mealCategoryLabel: String {
        switch mealCategory {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        case "snack": return "加餐"
        default: return "餐次"
        }
    }

    private func mealGuideChip(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var mealSummaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("餐品营养")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.secondary)
                    Text("\(Int(round(calories)))")
                        .font(.system(size: 42, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(drafts.count) 项食物")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                macroPill("蛋白质", protein, Color(hex: "F87171"))
                macroPill("碳水", carbs, Color(hex: "F59E0B"))
                macroPill("脂肪", fat, Color(hex: "60A5FA"))
                macroPill("热量", calories, Color(hex: "111318"), unit: "千卡")
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func macroPill(_ label: String, _ value: Double, _ color: Color, unit: String = "克") -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(numberText(value))\(unit)")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索食物加入餐品", text: $searchQuery)
                    .font(.system(size: 14, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await searchFoods() }
                    }
                Button {
                    Task { await searchFoods() }
                } label: {
                    if searching {
                        ProgressView()
                            .scaleEffect(0.72)
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
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            if !searchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(searchResults.prefix(6))) { food in
                        Button {
                            addFood(food)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(food.name)
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                        .lineLimit(1)
                                    Text("\(Int(round(food.calories))) 千卡 · 蛋白 \(numberText(food.protein))克 · \(food.servingSize)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
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
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func foodEditorRow(_ draft: Binding<SavedMealFoodDraft>, onRemove: @escaping () -> Void) -> some View {
        let food = draft.wrappedValue.foodItem
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(food.name)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(Int(round(food.calories))) 千卡 · 蛋白 \(numberText(food.protein))克")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("克", text: draft.gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 58)
                Text("克")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "EF4444"))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除食物 \(food.name)")
        }
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func searchFoods() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true
        message = ""
        do {
            searchResults = try await APIClient.shared.searchFoods(query: query)
        } catch {
            message = infoFriendlyError(error, fallback: "搜索食物失败")
        }
        searching = false
    }

    private func addFood(_ food: FoodItem) {
        drafts.append(SavedMealFoodDraft(food: food))
        searchQuery = ""
        searchResults = []
        message = "已加入食物：\(food.name)。"
    }

    private func saveMeal() async {
        guard !saving, !drafts.isEmpty else { return }
        saving = true
        message = ""
        do {
            let matchingMeal = matchingSavedMeal
            let meal = try await saveOrReplaceMeal(matchingMeal: matchingMeal)
            onSaved(meal, matchingMeal != nil)
            message = matchingMeal == nil ? "已保存餐品。" : "已替换同名餐品。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存餐品失败")
        }
        saving = false
    }

    private func saveAndLogMeal() async {
        guard !logging, !drafts.isEmpty else { return }
        logging = true
        message = ""
        do {
            let matchingMeal = matchingSavedMeal
            let meal = try await saveOrReplaceMeal(matchingMeal: matchingMeal)
            onSaved(meal, matchingMeal != nil)
            _ = try await APIClient.shared.logSavedMeal(
                id: meal.id,
                mealCategory: mealCategory,
                date: logDate
            )
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "保存并记录失败")
        }
        logging = false
    }

    private func saveOrReplaceMeal(matchingMeal: SavedMealItem?) async throws -> SavedMealItem {
        if let matchingMeal {
            return try await APIClient.shared.updateSavedMeal(
                id: matchingMeal.id,
                title: cleanTitle,
                foods: editedFoods,
                mealCategory: mealCategory,
                imageUrl: matchingMeal.imageUrl ?? "",
                note: cleanNote,
                instructions: cleanInstructions,
                favorite: matchingMeal.favorite
            )
        }
        return try await APIClient.shared.saveMealTemplate(
            title: cleanTitle,
            foods: editedFoods,
            mealCategory: mealCategory,
            note: cleanNote,
            instructions: cleanInstructions
        )
    }

    private var cleanTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return editedFoods.prefix(2).map(\.name).joined(separator: " + ").isEmpty ? "我的餐品" : editedFoods.prefix(2).map(\.name).joined(separator: " + ")
    }

    private var cleanNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanInstructions: [String] {
        instructionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func numberText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }
}

private struct SavedMealDetailSheetView: View {
    let meal: SavedMealItem
    let logDate: String
    let mealCategory: String
    let onClose: () -> Void
    let onUpdated: (SavedMealItem) -> Void
    let onCreated: (SavedMealItem) -> Void
    let onFoodSaved: (SavedFoodItem) -> Void
    let onRecipeCreated: (IngredientRecipeHistoryItem) -> Void
    let onDeleted: (SavedMealItem) -> Void
    let onLogged: () -> Void

    @State private var title: String
    @State private var note: String
    @State private var instructionsText: String
    @State private var drafts: [SavedMealFoodDraft]
    @State private var searchQuery = ""
    @State private var searchResults: [FoodItem] = []
    @State private var searching = false
    @State private var portionMultiplierText = "1"
    @State private var selectedMealCategory: String
    @State private var saving = false
    @State private var duplicating = false
    @State private var logging = false
    @State private var savingAsRecipe = false
    @State private var deletingMeal = false
    @State private var showingDeleteConfirmation = false
    @State private var savingFoodTemplateDraftId = ""
    @State private var message = ""
    @State private var showingMealEditor = false
    @State private var isFavorite: Bool
    @State private var favoritingMeal = false

    private let mealCategoryOptions = [
        ("breakfast", "早餐", "sunrise.fill"),
        ("lunch", "午餐", "sun.max.fill"),
        ("dinner", "晚餐", "moon.stars.fill"),
        ("snack", "加餐", "leaf.fill"),
    ]

    init(
        meal: SavedMealItem,
        logDate: String,
        mealCategory: String,
        onClose: @escaping () -> Void,
        onUpdated: @escaping (SavedMealItem) -> Void,
        onCreated: @escaping (SavedMealItem) -> Void,
        onFoodSaved: @escaping (SavedFoodItem) -> Void,
        onRecipeCreated: @escaping (IngredientRecipeHistoryItem) -> Void,
        onDeleted: @escaping (SavedMealItem) -> Void,
        onLogged: @escaping () -> Void
    ) {
        self.meal = meal
        self.logDate = logDate
        self.mealCategory = mealCategory
        self.onClose = onClose
        self.onUpdated = onUpdated
        self.onCreated = onCreated
        self.onFoodSaved = onFoodSaved
        self.onRecipeCreated = onRecipeCreated
        self.onDeleted = onDeleted
        self.onLogged = onLogged
        _title = State(initialValue: meal.title)
        _note = State(initialValue: meal.note ?? "")
        _instructionsText = State(initialValue: (meal.instructions ?? []).joined(separator: "\n"))
        _drafts = State(initialValue: meal.foods.map { SavedMealFoodDraft(food: $0) })
        _selectedMealCategory = State(initialValue: SavedMealDetailSheetView.normalizedMealCategory(meal.mealCategory ?? mealCategory))
        _isFavorite = State(initialValue: meal.favorite == true)
    }

    private var editedFoods: [FoodItem] {
        drafts.map(\.foodItem)
    }

    private var calories: Double { editedFoods.reduce(0) { $0 + $1.calories } }
    private var protein: Double { editedFoods.reduce(0) { $0 + $1.protein } }
    private var carbs: Double { editedFoods.reduce(0) { $0 + $1.carbs } }
    private var fat: Double { editedFoods.reduce(0) { $0 + $1.fat } }
    private var fiber: Double { editedFoods.reduce(0) { $0 + $1.fiber } }
    private var sugar: Double { editedFoods.reduce(0) { $0 + $1.sugar } }
    private var sodium: Double { editedFoods.reduce(0) { $0 + $1.sodium } }
    private var addedSugar: Double { editedFoods.reduce(0) { $0 + $1.addedSugar } }
    private var satFat: Double { editedFoods.reduce(0) { $0 + $1.satFat } }
    private var transFat: Double { editedFoods.reduce(0) { $0 + $1.transFat } }
    private var cholesterol: Double { editedFoods.reduce(0) { $0 + $1.cholesterol } }
    private var vitaminA: Double { editedFoods.reduce(0) { $0 + $1.vitaminA } }
    private var vitaminC: Double { editedFoods.reduce(0) { $0 + $1.vitaminC } }
    private var calcium: Double { editedFoods.reduce(0) { $0 + $1.calcium } }
    private var iron: Double { editedFoods.reduce(0) { $0 + $1.iron } }
    private var potassium: Double { editedFoods.reduce(0) { $0 + $1.potassium } }

    private var portionMultiplier: Double {
        let normalized = portionMultiplierText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return max(0.05, min(20.0, Double(normalized) ?? 1))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let coverURL = mealCoverURL {
                        mealCoverHero(coverURL)
                    }

                    mealDetailModeSwitch

                    if showingMealEditor {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("餐品名称", text: $title)
                                .font(.system(size: 24, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .textInputAutocapitalization(.never)
                            Text("编辑这组常吃餐品，保存后下次可以一键记录。")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                        mealLibraryStatusCard
                        mealNotesCard
                        mealSummaryCard
                        if !mealExtendedNutritionRows.isEmpty {
                            mealExtendedNutritionCard
                        }
                        mealDefaultCategoryCard
                        mealPortionCard

                        VStack(alignment: .leading, spacing: 12) {
                            Text("食物")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            ForEach(Array(drafts.indices), id: \.self) { index in
                                foodEditorRow($drafts[index], canRemove: drafts.count > 1) {
                                    if drafts.indices.contains(index) {
                                        drafts.remove(at: index)
                                    }
                                }
                            }
                            searchCard
                        }
                        .padding(18)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        mealOverviewHeaderCard
                        mealSummaryCard
                        if !mealExtendedNutritionRows.isEmpty {
                            mealExtendedNutritionCard
                        }
                        mealOverviewFoodsCard
                        mealOverviewNotesCard
                        mealPortionCard
                        mealDefaultCategoryCard
                        mealLibraryStatusCard
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(infoMessageNeedsAttention(message) ? Color(hex: "EF4444") : Color(hex: "16A34A"))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveMeal() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("保存修改")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .disabled(saving || logging || duplicating || savingAsRecipe || deletingMeal || favoritingMeal || !savingFoodTemplateDraftId.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            Task { await saveMeal() }
                        } label: {
                            Label("保存修改", systemImage: "checkmark.circle.fill")
                        }
                        Button {
                            Task { await duplicateMealFromEdits() }
                        } label: {
                            Label("另存为新餐品", systemImage: "plus.square.on.square")
                        }
                        Button {
                            Task { await saveEditedMealAsRecipe() }
                        } label: {
                            Label("保存为食谱", systemImage: "book.closed")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除餐品", systemImage: "trash")
                        }
                    } label: {
                        ZStack {
                            if saving || duplicating || savingAsRecipe || deletingMeal || favoritingMeal {
                                ProgressView()
                                    .tint(Color(hex: "111318"))
                                    .scaleEffect(0.78)
                            } else {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .black))
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 52)
                        .frame(height: 52)
                        .background(.white)
                        .clipShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .disabled(saving || logging || duplicating || savingAsRecipe || deletingMeal || favoritingMeal || !savingFoodTemplateDraftId.isEmpty)
                    .accessibilityLabel("更多餐品操作")

                    Button {
                        Task { await logMeal() }
                    } label: {
                        HStack(spacing: 8) {
                            if logging {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(logging ? "记录中" : "保存并记录")
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                    }
                    .disabled(saving || logging || duplicating || savingAsRecipe || deletingMeal || favoritingMeal || !savingFoodTemplateDraftId.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .confirmationDialog(
                "删除餐品？",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除“\(meal.title)”", role: .destructive) {
                    Task { await deleteMeal() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后会从我的餐品中移除，已记录到日记里的历史餐食不会被删除。")
            }
        }
    }

    private var mealCoverURL: URL? {
        guard let raw = meal.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private var mealDetailModeSwitch: some View {
        HStack(spacing: 8) {
            Button {
                showingMealEditor = false
            } label: {
                Text("概览")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(!showingMealEditor ? .white : Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(!showingMealEditor ? Color.black : Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                showingMealEditor = true
            } label: {
                Text("编辑")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(showingMealEditor ? .white : Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(showingMealEditor ? Color.black : Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private func mealCoverHero(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(hex: "F7F8FA"))
                    .frame(height: 190)

                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .clipped()
                case .failure:
                    Image(systemName: "fork.knife")
                        .font(.system(size: 32, weight: .black))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                @unknown default:
                    EmptyView()
                }

                Text("餐品封面")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.58))
                    .clipShape(Capsule())
                    .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var mealOverviewHeaderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 54, height: 54)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? meal.title : title)
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                    Text("\(drafts.count) 项食物 · \(mealCategoryTitle(selectedMealCategory)) · \(mealSourceLabel)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Button {
                        Task { await toggleFavoriteFromDetail() }
                    } label: {
                        ZStack {
                            if favoritingMeal {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(Color(hex: "F59E0B"))
                            } else {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.system(size: 15, weight: .black))
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(isFavorite ? Color(hex: "F59E0B") : Color(hex: "6B7280"))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(favoritingMeal || saving || logging || duplicating || savingAsRecipe || deletingMeal)
                    .accessibilityLabel(isFavorite ? "取消收藏餐品" : "收藏餐品")

                    Text("\(Int(round(calories)))")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                mealOverviewChip("默认\(mealCategoryTitle(selectedMealCategory))", systemImage: "clock.fill")
                mealOverviewChip("记录 \(meal.loggedCount ?? 0) 次", systemImage: "checkmark.circle.fill")
                mealOverviewChip(isFavorite ? "已收藏" : "可按份记录", systemImage: isFavorite ? "star.fill" : "plusminus")
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func mealOverviewChip(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .black))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .black))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(Color(hex: "111318"))
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var mealOverviewFoodsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("食物明细")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text("\(drafts.count)项")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            ForEach(Array(editedFoods.enumerated()), id: \.element.id) { index, food in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(food.name)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        Text("\(food.servingSize) · 蛋白 \(formatNumber(food.protein))克 · 碳水 \(formatNumber(food.carbs))克 · 脂肪 \(formatNumber(food.fat))克")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    Spacer()

                    Text("\(Int(round(food.calories)))")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Text("千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var mealOverviewNotesCard: some View {
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstructions = instructionsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 12) {
            Text("餐品说明")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "111318"))

            if cleanNote.isEmpty && cleanInstructions.isEmpty {
                Text("还没写说明，点编辑可以补充口味、备餐方式或适合场景。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                if !cleanNote.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("备注")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(cleanNote)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "111318"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !cleanInstructions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("做法")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                        ForEach(Array(cleanInstructions.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Color.black)
                                    .clipShape(Circle())
                                Text(step)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var mealSummaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("餐品营养")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.secondary)
                    Text("\(Int(round(calories)))")
                        .font(.system(size: 42, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text("\(drafts.count) 项食物")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color(hex: "EFF6FF"))
                        .clipShape(Capsule())

                    Text("可按份记录")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "16A34A"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color(hex: "ECFDF5"))
                        .clipShape(Capsule())
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                macroPill("蛋白质", protein, Color(hex: "F87171"))
                macroPill("碳水", carbs, Color(hex: "F59E0B"))
                macroPill("脂肪", fat, Color(hex: "60A5FA"))
                macroPill("热量", calories, Color(hex: "111318"), unit: "千卡")
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var mealLibraryStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的餐品模板")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存整餐组合，可编辑后记录或另存。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(mealSourceLabel)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                mealStatusMetric("已用", "\(meal.loggedCount ?? 0)次")
                mealStatusMetric("最近记录", compactDateLabel(meal.loggedAt))
                mealStatusMetric("创建", compactDateLabel(meal.createdAt))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var mealExtendedNutritionRows: [(label: String, icon: String, value: Double, unit: String)] {
        var rows: [(String, String, Double, String)] = []
        if fiber > 0 { rows.append(("纤维", "leaf.fill", fiber, "克")) }
        if sugar > 0 { rows.append(("糖", "cube.fill", sugar, "克")) }
        if sodium > 0 { rows.append(("钠", "drop.fill", sodium, "mg")) }
        if addedSugar > 0 { rows.append(("添加糖", "sparkles", addedSugar, "克")) }
        if satFat > 0 { rows.append(("饱和脂肪", "circle.lefthalf.filled", satFat, "克")) }
        if transFat > 0 { rows.append(("反式脂肪", "arrow.triangle.2.circlepath", transFat, "克")) }
        if cholesterol > 0 { rows.append(("胆固醇", "heart.text.square.fill", cholesterol, "mg")) }
        if potassium > 0 { rows.append(("钾", "bolt.heart.fill", potassium, "mg")) }
        if calcium > 0 { rows.append(("钙", "seal.fill", calcium, "mg")) }
        if iron > 0 { rows.append(("铁", "circle.grid.cross.fill", iron, "mg")) }
        if vitaminA > 0 { rows.append(("维生素A", "eye.fill", vitaminA, "IU")) }
        if vitaminC > 0 { rows.append(("维生素C", "leaf.circle.fill", vitaminC, "mg")) }
        return rows
    }

    private var mealExtendedNutritionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("更多营养")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("由餐品内所有食物汇总，克数微调后同步变化。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(mealExtendedNutritionRows.count)项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(mealExtendedNutritionRows, id: \.label) { row in
                    mealExtendedNutritionMetric(row.label, row.icon, row.value, row.unit)
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func mealExtendedNutritionMetric(_ label: String, _ icon: String, _ value: Double, _ unit: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "6B7280"))
                .frame(width: 22, height: 22)
                .background(Color(hex: "F3F4F6"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text("\(formatNumber(value))\(unit)")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mealNotesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("餐品说明")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存做法、口味、备餐提示；下次打开餐品仍会保留。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            TextField("备注，例如：少油，适合训练后", text: $note, axis: .vertical)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1...3)
                .padding(12)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            TextField("制作说明，每行一步", text: $instructionsText, axis: .vertical)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2...5)
                .padding(12)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }


    private var mealSourceLabel: String {
        switch (meal.source ?? "").lowercased() {
        case "ios_manual", "manual", "manually":
            return "手动餐品"
        case "ios_meal_category":
            return "从餐次保存"
        case "ios_meal_template":
            return "从餐品保存"
        case "ios_recipe":
            return "从食谱保存"
        case "photo_analysis":
            return "拍照整理"
        case "ai_enhanced", "ai_swap":
            return "更贴合今天"
        case "rules", "rules_fallback":
            return "基础规则"
        default:
            return "我的餐品"
        }
    }

    private func mealStatusMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func macroPill(_ label: String, _ value: Double, _ color: Color, unit: String = "克") -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(formatNumber(value))\(unit)")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var mealDefaultCategoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("默认餐次")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存餐品时记住默认餐次，记录时会优先加入这里。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(mealCategoryTitle(selectedMealCategory))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                ForEach(mealCategoryOptions, id: \.0) { option in
                    Button {
                        selectedMealCategory = option.0
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.2)
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                            Text(option.1)
                                .font(.system(size: 12, weight: .black))
                        }
                        .foregroundStyle(selectedMealCategory == option.0 ? .white : Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(selectedMealCategory == option.0 ? Color.black : Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置默认餐次为\(option.1)")
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var mealPortionCard: some View {
        let multiplier = portionMultiplier
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记录份数")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存的是餐品模板，记录时按这里的份数换算。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("份", text: $portionMultiplierText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 18, weight: .black))
                        .frame(width: 54)
                    Text("份")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            }

            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                    Button {
                        portionMultiplierText = value == floor(value) ? "\(Int(value))" : String(format: "%.1f", value)
                    } label: {
                        Text(value == floor(value) ? "\(Int(value))份" : "\(formatNumber(value))份")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(abs(multiplier - value) < 0.01 ? .white : Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(abs(multiplier - value) < 0.01 ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录\(formatNumber(value))份餐品")
                }
            }

            HStack(spacing: 10) {
                mealLogMetric("本次热量", "\(Int(round(calories * multiplier)))千卡")
                mealLogMetric("蛋白", "\(formatNumber(protein * multiplier))克")
                mealLogMetric("碳水", "\(formatNumber(carbs * multiplier))克")
                mealLogMetric("脂肪", "\(formatNumber(fat * multiplier))克")
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func mealLogMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索食物加入餐品", text: $searchQuery)
                    .font(.system(size: 14, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await searchFoods() }
                    }
                Button {
                    Task { await searchFoods() }
                } label: {
                    if searching {
                        ProgressView()
                            .scaleEffect(0.72)
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
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            if !searchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(searchResults.prefix(5))) { food in
                        Button {
                            addFood(food)
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
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
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
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func foodEditorRow(_ draft: Binding<SavedMealFoodDraft>, canRemove: Bool, onRemove: @escaping () -> Void) -> some View {
        let food = draft.wrappedValue.foodItem
        let draftId = draft.wrappedValue.id
        let savingDraft = savingFoodTemplateDraftId == draftId
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(food.name)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                Text("\(Int(round(food.calories))) 千卡 · 蛋白 \(formatNumber(food.protein))克")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("克", text: draft.gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 58)
                Text("克")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            Button {
                Task { await saveFoodTemplateFromDraft(draft.wrappedValue) }
            } label: {
                ZStack {
                    if savingDraft {
                        ProgressView()
                            .scaleEffect(0.66)
                            .tint(Color(hex: "2563EB"))
                    } else {
                        Image(systemName: "bookmark")
                            .font(.system(size: 14, weight: .black))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(Color(hex: "2563EB"))
                .frame(width: 34, height: 34)
                .background(Color(hex: "EFF6FF"))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(saving || logging || duplicating || savingAsRecipe || deletingMeal || (!savingFoodTemplateDraftId.isEmpty && !savingDraft))
            .accessibilityLabel("保存食物 \(food.name) 到我的食物")

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(canRemove ? Color(hex: "EF4444") : Color(hex: "D1D5DB"))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove || saving || logging || duplicating || savingAsRecipe || deletingMeal || !savingFoodTemplateDraftId.isEmpty)
            .accessibilityLabel("移除食物 \(food.name)")
        }
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func searchFoods() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true
        message = ""
        do {
            searchResults = try await APIClient.shared.searchFoods(query: query)
        } catch {
            message = infoFriendlyError(error, fallback: "搜索食物失败")
        }
        searching = false
    }

    private func addFood(_ food: FoodItem) {
        drafts.append(SavedMealFoodDraft(food: food))
        searchQuery = ""
        searchResults = []
        message = "已加入食物：\(food.name)。"
    }

    private func saveFoodTemplateFromDraft(_ draft: SavedMealFoodDraft) async {
        guard savingFoodTemplateDraftId.isEmpty else { return }
        savingFoodTemplateDraftId = draft.id
        message = ""
        do {
            let saved = try await APIClient.shared.saveFoodTemplate(draft.foodItem)
            onFoodSaved(saved)
            message = "已保存到我的食物：\(saved.name)。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存食物失败")
        }
        savingFoodTemplateDraftId = ""
    }

    private func toggleFavoriteFromDetail() async {
        guard !favoritingMeal, !saving, !logging, !duplicating, !savingAsRecipe, !deletingMeal else { return }
        favoritingMeal = true
        message = ""
        do {
            let response = try await APIClient.shared.toggleSavedMealFavorite(id: meal.id)
            if let updated = response.meal {
                isFavorite = updated.favorite == true
                onUpdated(updated)
                message = isFavorite ? "已收藏餐品：\(updated.title)。" : "已取消收藏：\(updated.title)。"
            } else {
                isFavorite.toggle()
                message = isFavorite ? "已收藏餐品。" : "已取消收藏。"
            }
        } catch {
            message = infoFriendlyError(error, fallback: "更新餐品收藏失败")
        }
        favoritingMeal = false
    }

    private func saveMeal() async {
        guard !saving, !logging, !duplicating, !savingAsRecipe, !favoritingMeal, savingFoodTemplateDraftId.isEmpty else { return }
        saving = true
        message = ""
        do {
            let updated = try await APIClient.shared.updateSavedMeal(
                id: meal.id,
                title: cleanTitle,
                foods: editedFoods,
                mealCategory: selectedMealCategory,
                imageUrl: meal.imageUrl ?? "",
                note: cleanNote,
                instructions: cleanInstructions,
                favorite: isFavorite
            )
            onUpdated(updated)
            message = "已保存修改。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存失败")
        }
        saving = false
    }

    private func duplicateMealFromEdits() async {
        guard !saving, !logging, !duplicating, !savingAsRecipe, !favoritingMeal, savingFoodTemplateDraftId.isEmpty else { return }
        duplicating = true
        message = ""
        do {
            let duplicateTitle = "\(cleanTitle) 副本"
            let created = try await APIClient.shared.saveMealTemplate(
                title: duplicateTitle,
                foods: editedFoods,
                mealCategory: selectedMealCategory,
                imageUrl: meal.imageUrl ?? "",
                note: cleanNote,
                instructions: cleanInstructions,
                favorite: isFavorite
            )
            onCreated(created)
            message = "已另存为新餐品。"
        } catch {
            message = infoFriendlyError(error, fallback: "另存失败")
        }
        duplicating = false
    }

    private func logMeal() async {
        guard !saving, !logging, !duplicating, !savingAsRecipe, !favoritingMeal, savingFoodTemplateDraftId.isEmpty else { return }
        logging = true
        message = ""
        do {
            let updated = try await APIClient.shared.updateSavedMeal(
                id: meal.id,
                title: cleanTitle,
                foods: editedFoods,
                mealCategory: selectedMealCategory,
                imageUrl: meal.imageUrl ?? "",
                note: cleanNote,
                instructions: cleanInstructions,
                favorite: isFavorite
            )
            onUpdated(updated)
            _ = try await APIClient.shared.logSavedMeal(
                id: meal.id,
                mealCategory: selectedMealCategory,
                date: logDate,
                portionMultiplier: portionMultiplier
            )
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "记录失败")
        }
        logging = false
    }

    private func saveEditedMealAsRecipe() async {
        guard !saving, !logging, !duplicating, !savingAsRecipe, !favoritingMeal, savingFoodTemplateDraftId.isEmpty, !drafts.isEmpty else { return }
        savingAsRecipe = true
        message = ""
        do {
            let response = try await APIClient.shared.createIngredientRecipeSuggestion(
                recipePayload: recipePayloadFromEditedMeal(),
                date: logDate,
                source: "ios_meal_template"
            )
            let created = response.item ?? IngredientRecipeHistoryItem(
                id: response.recipeId ?? response.recipe.id,
                date: logDate,
                source: "ios_meal_template",
                logged: nil,
                createdAt: nil,
                loggedAt: nil,
                loggedCount: nil,
                recipe: response.recipe
            )
            onRecipeCreated(created)
            message = "已保存为食谱。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存食谱失败")
        }
        savingAsRecipe = false
    }

    private func deleteMeal() async {
        guard !saving, !logging, !duplicating, !savingAsRecipe, !deletingMeal, !favoritingMeal, savingFoodTemplateDraftId.isEmpty else { return }
        deletingMeal = true
        message = ""
        do {
            _ = try await APIClient.shared.deleteSavedMeal(id: meal.id)
            onDeleted(meal)
        } catch {
            message = infoFriendlyError(error, fallback: "删除餐品失败")
        }
        deletingMeal = false
    }

    private func recipePayloadFromEditedMeal() -> [String: Any] {
        let ingredientDrafts = editedFoods.map { RecipeIngredientDraft(food: $0) }
        let totals = ingredientDrafts.reduce(RecipeTotals()) { partial, draft in
            partial.adding(draft.totals)
        }
        let recipeReason = cleanNote.isEmpty ? "由餐品创建" : cleanNote
        let recipeInstructions = cleanInstructions.isEmpty
            ? ["按常规方式处理食材。", "根据口味少油少盐烹调。"]
            : cleanInstructions
        var payload: [String: Any] = [
            "title": cleanTitle,
            "servings": 1,
            "serving_size_label": "1份",
            "calories": round1(totals.calories),
            "protein": round1(totals.protein),
            "carbs": round1(totals.carbs),
            "fat": round1(totals.fat),
            "fiber": round1(totals.fiber),
            "sodium": round1(totals.sodium),
            "sugar": round1(totals.sugar),
            "prep_time_minutes": 0,
            "active_time_minutes": 0,
            "inactive_time_minutes": 0,
            "reason": recipeReason,
            "instructions": recipeInstructions,
            "ingredients_breakdown": ingredientDrafts.map { $0.payload },
            "missing_ingredients": [],
            "source": "ios_meal_template",
            "tags": ["餐品转换", meal.mealCategory.flatMap { $0.isEmpty ? nil : mealCategoryTitle($0) } ?? "我的餐品"],
            "meal_types": meal.mealCategory.flatMap { RecipeMealType.normalized($0).map { [$0] } } ?? []
        ]
        if let imageURL = meal.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
            payload["image_url"] = imageURL
        }
        return payload
    }

    private var cleanTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? meal.title : text
    }

    private var cleanNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanInstructions: [String] {
        instructionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func mealCategoryTitle(_ key: String) -> String {
        mealCategoryOptions.first { $0.0 == key }?.1 ?? "加餐"
    }

    private static func normalizedMealCategory(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("breakfast") || text.contains("早餐") { return "breakfast" }
        if text.contains("lunch") || text.contains("午餐") { return "lunch" }
        if text.contains("dinner") || text.contains("晚餐") { return "dinner" }
        if text.contains("snack") || text.contains("加餐") || text.contains("零食") { return "snack" }
        return "snack"
    }

    private func formatNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }

    private func compactDateLabel(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "未记录" }
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let datePart = normalized.split(separator: " ").first.map(String.init) ?? normalized
        if datePart.count >= 10 {
            let start = datePart.index(datePart.startIndex, offsetBy: 5)
            return String(datePart[start...])
        }
        return datePart
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}

private struct SavedMealFoodDraft: Identifiable {
    let id = UUID().uuidString
    let source: FoodItem
    let baseGrams: Double
    var gramsText: String

    init(food: FoodItem) {
        source = food
        let parsed = SavedMealFoodDraft.parseGrams(food.servingSize)
        baseGrams = parsed > 0 ? parsed : 100
        gramsText = "\(Int(round(baseGrams)))"
    }

    private var grams: Double {
        let normalized = gramsText.replacingOccurrences(of: ",", with: ".")
        return max(0, Double(normalized) ?? baseGrams)
    }

    private var scale: Double {
        baseGrams <= 0 ? 1 : grams / baseGrams
    }

    var foodItem: FoodItem {
        FoodItem(
            id: source.id,
            name: source.name,
            calories: round1(source.calories * scale),
            protein: round1(source.protein * scale),
            carbs: round1(source.carbs * scale),
            fat: round1(source.fat * scale),
            fiber: round1(source.fiber * scale),
            sugar: round1(source.sugar * scale),
            sodium: round1(source.sodium * scale),
            servingSize: "\(Int(round(grams)))克",
            processingLevel: source.processingLevel,
            addedSugar: round1(source.addedSugar * scale),
            satFat: round1(source.satFat * scale),
            transFat: round1(source.transFat * scale),
            cholesterol: round1(source.cholesterol * scale),
            vitaminA: round1(source.vitaminA * scale),
            vitaminC: round1(source.vitaminC * scale),
            calcium: round1(source.calcium * scale),
            iron: round1(source.iron * scale),
            potassium: round1(source.potassium * scale)
        )
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func parseGrams(_ text: String) -> Double {
        let normalized = text
            .replacingOccurrences(of: "ｇ", with: "g")
            .replacingOccurrences(of: "克", with: "g")
        var number = ""
        for char in normalized {
            if char.isNumber || char == "." {
                number.append(char)
            } else if !number.isEmpty {
                break
            }
        }
        return Double(number) ?? 0
    }
}

private struct SavedRecipeDetailSheetView: View {
    let item: IngredientRecipeHistoryItem
    let logDate: String
    let mealCategory: String
    let savedMeals: [SavedMealItem]
    let onClose: () -> Void
    let onUpdated: (IngredientRecipeHistoryItem) -> Void
    let onMealCreated: (SavedMealItem) -> Void
    let onMealUpdated: (SavedMealItem) -> Void
    let onRecipeCreated: (IngredientRecipeHistoryItem) -> Void
    let onDeleted: (IngredientRecipeHistoryItem) -> Void
    let onFoodSaved: (SavedFoodItem) -> Void
    let onLogged: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var title: String
    @State private var drafts: [RecipeIngredientDraft]
    @State private var servingsText: String
    @State private var servingSizeLabelText: String
    @State private var prepTimeText: String
    @State private var activeTimeText: String
    @State private var inactiveTimeText: String
    @State private var instructionsText: String
    @State private var selectedRecipeMealTypes: Set<String>
    @State private var ingredientSearchQuery = ""
    @State private var ingredientSearchResults: [FoodItem] = []
    @State private var searchingIngredients = false
    @State private var bulkIngredientText = ""
    @State private var importingBulkIngredients = false
    @State private var replacingIngredientDraftId: String?
    @State private var portionMultiplierText = "1"
    @State private var selectedMealCategory: String
    @State private var saving = false
    @State private var savingAsMeal = false
    @State private var duplicatingRecipe = false
    @State private var deletingRecipe = false
    @State private var showingDeleteConfirmation = false
    @State private var logging = false
    @State private var savingFoodTemplateDraftId = ""
    @State private var message = ""
    @State private var showingRecipeEditor = false
    @State private var isFavorite: Bool
    @State private var favoritingRecipe = false

    private let mealCategoryOptions = [
        ("breakfast", "早餐", "sunrise.fill"),
        ("lunch", "午餐", "sun.max.fill"),
        ("dinner", "晚餐", "moon.stars.fill"),
        ("snack", "加餐", "leaf.fill"),
    ]

    init(
        item: IngredientRecipeHistoryItem,
        logDate: String,
        mealCategory: String,
        savedMeals: [SavedMealItem],
        onClose: @escaping () -> Void,
        onUpdated: @escaping (IngredientRecipeHistoryItem) -> Void,
        onMealCreated: @escaping (SavedMealItem) -> Void,
        onMealUpdated: @escaping (SavedMealItem) -> Void,
        onRecipeCreated: @escaping (IngredientRecipeHistoryItem) -> Void,
        onDeleted: @escaping (IngredientRecipeHistoryItem) -> Void,
        onFoodSaved: @escaping (SavedFoodItem) -> Void,
        onLogged: @escaping () -> Void
    ) {
        self.item = item
        self.logDate = logDate
        self.mealCategory = mealCategory
        self.savedMeals = savedMeals
        self.onClose = onClose
        self.onUpdated = onUpdated
        self.onMealCreated = onMealCreated
        self.onMealUpdated = onMealUpdated
        self.onRecipeCreated = onRecipeCreated
        self.onDeleted = onDeleted
        self.onFoodSaved = onFoodSaved
        self.onLogged = onLogged
        _title = State(initialValue: item.recipe.title)
        _drafts = State(initialValue: item.recipe.ingredientsBreakdown.map { RecipeIngredientDraft(item: $0) })
        _servingsText = State(initialValue: "\(max(1, item.recipe.servings))")
        _servingSizeLabelText = State(initialValue: recipeServingSizeLabel(item.recipe))
        _prepTimeText = State(initialValue: "\(max(0, item.recipe.prepTimeMinutes))")
        _activeTimeText = State(initialValue: "\(max(0, item.recipe.activeTimeMinutes ?? item.recipe.prepTimeMinutes))")
        _inactiveTimeText = State(initialValue: "\(max(0, item.recipe.inactiveTimeMinutes ?? 0))")
        _instructionsText = State(initialValue: item.recipe.instructions.joined(separator: "\n"))
        _selectedRecipeMealTypes = State(initialValue: Set(RecipeMealType.inferredList(mealTypes: item.recipe.mealTypes, tags: item.recipe.tags)))
        _selectedMealCategory = State(initialValue: SavedRecipeDetailSheetView.normalizedMealCategory(mealCategory))
        _isFavorite = State(initialValue: item.recipe.favorite == true)
    }

    private var recipeTotalNutrition: RecipeTotals {
        drafts.reduce(RecipeTotals()) { partial, draft in
            partial.adding(draft.totals)
        }
    }

    private var servingsCount: Int {
        max(1, min(12, Int(servingsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? item.recipe.servings))
    }

    private var servingSizeLabel: String {
        let label = servingSizeLabelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "1份" : label
    }

    private var prepTimeMinutes: Int {
        min(480, activeTimeMinutes + inactiveTimeMinutes)
    }

    private var activeTimeMinutes: Int {
        max(0, min(480, Int(activeTimeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? (item.recipe.activeTimeMinutes ?? item.recipe.prepTimeMinutes)))
    }

    private var inactiveTimeMinutes: Int {
        max(0, min(480, Int(inactiveTimeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? (item.recipe.inactiveTimeMinutes ?? 0)))
    }

    private var editedInstructions: [String] {
        instructionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var editedTotals: RecipeTotals {
        recipeTotalNutrition.scaled(by: 1.0 / Double(servingsCount))
    }

    private var portionMultiplier: Double {
        let normalized = portionMultiplierText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return max(0.05, min(20.0, Double(normalized) ?? 1))
    }

    private var loggingTotals: RecipeTotals {
        editedTotals.scaled(by: portionMultiplier)
    }

    private var servingSizeOptions: [RecipeServingSizeOption] {
        recipeServingSizeOptions(for: item.recipe, fallbackLabel: servingSizeLabel)
    }

    private var selectedServingSizeLabelForLog: String {
        if let matched = servingSizeOptions.first(where: { abs($0.nutritionMultiplier - portionMultiplier) < 0.01 }) {
            return matched.displayLabel
        }
        if abs(portionMultiplier - 1.0) < 0.01 {
            return servingSizeLabel
        }
        return "\(formatNumber(portionMultiplier))份 × \(servingSizeLabel)"
    }

    private var cleanMealTypes: [String] {
        RecipeMealType.all.map(\.id).filter { selectedRecipeMealTypes.contains($0) }
    }

    private var hasRecipeMetaInfo: Bool {
        item.recipe.source == "recipe_url_import"
        || !(item.recipe.sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !(item.recipe.cookingTime ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || activeTimeMinutes > 0
        || inactiveTimeMinutes > 0
    }

    private var sourceHostLabel: String {
        let source = (item.recipe.sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: source), let host = url.host, !host.isEmpty else {
            return source.isEmpty ? "本地食谱" : source
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private var recipeSourceLabel: String {
        switch item.recipe.source {
        case "recipe_url_import":
            return "链接导入"
        case "ingredient_ai":
            return "食材整理"
        case "ios_meal_template", "ios_meal_category":
            return "从餐品保存"
        case "manual", "ios_manual", "manually":
            return "手动食谱"
        case "ai_enhanced":
            return "更贴合今天"
        case "rules", "rules_fallback":
            return "基础规则"
        case "text":
            return "文字整理"
        case "photo_analysis":
            return "拍照整理"
        default:
            return item.recipe.source.isEmpty ? "食谱" : item.recipe.source
        }
    }

    private var replacingIngredientName: String? {
        guard let replacingIngredientDraftId else { return nil }
        return drafts.first { $0.id == replacingIngredientDraftId }?.name
    }

    private var ingredientsNeedingMatch: [RecipeIngredientDraft] {
        drafts.filter { draft in
            let totals = draft.totals
            return totals.calories <= 0.05
                && totals.protein <= 0.05
                && totals.carbs <= 0.05
                && totals.fat <= 0.05
        }
    }

    private var matchedIngredients: [RecipeIngredientDraft] {
        drafts.filter { draft in
            !ingredientsNeedingMatch.contains { $0.id == draft.id }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let coverURL = recipeImageURL(item.recipe) {
                        recipeCoverHero(coverURL)
                    }

                    recipeDetailModeSwitch

                    if showingRecipeEditor {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("食谱名称", text: $title)
                                .font(.system(size: 24, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .textInputAutocapitalization(.never)
                            Text("食材克数代表整份菜谱，我会按总份数换算每份营养。")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Text("总份数")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(.secondary)
                                TextField("份", text: $servingsText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(.system(size: 16, weight: .black))
                                Text("份")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                            HStack(spacing: 10) {
                                Text("每份份量")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(.secondary)
                                TextField("例如：1碗 / 1块 / 250克", text: $servingSizeLabelText)
                                    .textInputAutocapitalization(.never)
                                    .multilineTextAlignment(.trailing)
                                    .font(.system(size: 15, weight: .black))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                            Text("有多少人份？总份数会决定每份营养，食材克数按整份食谱计算。")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                recipeDetailMetaField("主动时间", text: $activeTimeText, suffix: "分")
                                recipeDetailMetaField("等待时间", text: $inactiveTimeText, suffix: "分")
                            }
                            recipeMealTypeEditField
                        }
                        .padding(18)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                        recipeLibraryStatusCard
                        if hasRecipeMetaInfo {
                            recipeMetaInfoCard
                        }

                        macroSummary
                        if !recipeExtendedNutritionRows.isEmpty {
                            recipeExtendedNutritionCard
                        }
                        portionControlCard
                        recipeDefaultCategoryCard

                        VStack(alignment: .leading, spacing: 12) {
                            Text("食材")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            bulkIngredientPasteCard
                            if !matchedIngredients.isEmpty {
                                ingredientMatchedSummaryCard
                            }
                            if !ingredientsNeedingMatch.isEmpty {
                                ingredientMatchNoticeCard
                            }
                            ForEach(Array(drafts.indices), id: \.self) { index in
                                ingredientEditorRow($drafts[index], canRemove: drafts.count > 1) {
                                    if drafts.indices.contains(index) {
                                        drafts.remove(at: index)
                                    }
                                }
                            }
                            ingredientSearchCard
                        }
                        .padding(18)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                        recipeDetailsEditCard
                    } else {
                        recipeOverviewHeaderCard
                        macroSummary
                        if !recipeExtendedNutritionRows.isEmpty {
                            recipeExtendedNutritionCard
                        }
                        recipeOverviewIngredientsCard
                        recipeOverviewDirectionsCard
                        portionControlCard
                        recipeDefaultCategoryCard
                        if hasRecipeMetaInfo {
                            recipeMetaInfoCard
                        }
                        recipeLibraryStatusCard
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(infoMessageNeedsAttention(message) ? Color(hex: "EF4444") : Color(hex: "16A34A"))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveRecipe() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("保存食谱")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .disabled(saving || logging)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            Task { await duplicateEditedRecipe() }
                        } label: {
                            Label("另存为新食谱", systemImage: "doc.on.doc")
                        }
                        Button {
                            Task { await saveEditedRecipeAsMeal() }
                        } label: {
                            Label("保存为餐品", systemImage: "tray.and.arrow.down.fill")
                        }
                        Button {
                            Task { await saveRecipe() }
                        } label: {
                            Label("保存修改", systemImage: "checkmark.circle.fill")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除食谱", systemImage: "trash")
                        }
                    } label: {
                        ZStack {
                            if saving || savingAsMeal || duplicatingRecipe || deletingRecipe || favoritingRecipe {
                                ProgressView()
                                    .tint(Color(hex: "111318"))
                                    .scaleEffect(0.78)
                            } else {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .black))
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 52)
                        .frame(height: 52)
                        .background(.white)
                        .clipShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .disabled(saving || logging || savingAsMeal || duplicatingRecipe || deletingRecipe || favoritingRecipe || !savingFoodTemplateDraftId.isEmpty)
                    .accessibilityLabel("更多食谱操作")

                    Button {
                        Task { await logEditedRecipe() }
                    } label: {
                        HStack(spacing: 8) {
                            if logging {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(logging ? "记录中" : "保存并记录")
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                    }
                    .disabled(saving || logging || savingAsMeal || duplicatingRecipe || deletingRecipe || favoritingRecipe || !savingFoodTemplateDraftId.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .confirmationDialog(
                "删除食谱？",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除“\(item.recipe.title)”", role: .destructive) {
                    Task { await deleteRecipe() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后会从我的食谱中移除，已记录到日记里的历史餐食不会被删除。")
            }
        }
    }

    private var recipeDetailModeSwitch: some View {
        HStack(spacing: 6) {
            Button {
                showingRecipeEditor = false
            } label: {
                Label("概览", systemImage: "book.closed.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(showingRecipeEditor ? Color(hex: "6B7280") : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(showingRecipeEditor ? Color(hex: "F3F4F6") : Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                showingRecipeEditor = true
            } label: {
                Label("编辑", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(showingRecipeEditor ? .white : Color(hex: "6B7280"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(showingRecipeEditor ? Color.black : Color(hex: "F3F4F6"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(.white)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(hex: "EEF0F4"), lineWidth: 1))
    }

    private var recipeOverviewHeaderCard: some View {
        let mealTypes = RecipeMealType.inferredList(mealTypes: item.recipe.mealTypes, tags: item.recipe.tags)
        let tags = (item.recipe.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && RecipeMealType.normalized($0) == nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(editedRecipeTitle)
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.recipe.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(item.recipe.reason)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Button {
                        Task { await toggleFavoriteFromDetail() }
                    } label: {
                        ZStack {
                            if favoritingRecipe {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(Color(hex: "F59E0B"))
                            } else {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.system(size: 15, weight: .black))
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(isFavorite ? Color(hex: "F59E0B") : Color(hex: "6B7280"))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(favoritingRecipe || saving || logging || savingAsMeal || duplicatingRecipe || deletingRecipe)
                    .accessibilityLabel(isFavorite ? "取消收藏食谱" : "收藏食谱")

                    Text("\(Int(round(editedTotals.calories)))")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡/份")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                recipeOverviewChip("总份数", "\(servingsCount)份", "person.2.fill")
                recipeOverviewChip("每份", servingSizeLabel, "scalemass.fill")
                recipeOverviewChip("主动", "\(activeTimeMinutes)分", "timer")
                recipeOverviewChip("等待", "\(inactiveTimeMinutes)分", "hourglass")
            }

            if !mealTypes.isEmpty || !tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !mealTypes.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(mealTypes, id: \.self) { mealType in
                                recipeOverviewMiniChip("适用\(RecipeMealType.title(for: mealType))", icon: "fork.knife")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(tags.prefix(4)), id: \.self) { tag in
                                recipeOverviewMiniChip(tag, icon: "number")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func recipeOverviewMiniChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .black))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 10, weight: .black))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .foregroundStyle(Color(hex: "6B7280"))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(hex: "F3F4F6"))
        .clipShape(Capsule())
    }

    private func recipeOverviewChip(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "16A34A"))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var recipeOverviewIngredientsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("食材")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text("\(drafts.count) 项")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            if drafts.isEmpty {
                Text("先添加主要食材，我会自动汇总营养。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                        let totals = draft.totals
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.name)
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .lineLimit(1)
                                Text("\(draft.gramsText)克 · \(Int(round(totals.calories)))千卡")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("蛋白 \(formatNumber(totals.protein))克")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color(hex: "6B7280"))
                                .lineLimit(1)
                        }
                        .padding(12)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var recipeOverviewDirectionsCard: some View {
        let steps = editedInstructions
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("做法")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text("\(steps.count) 步")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            if steps.isEmpty {
                Text("还没写做法，补 1-2 步就能当成常用餐保存。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Color(hex: "16A34A"))
                                .clipShape(Circle())
                            Text(step)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(hex: "374151"))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(14)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func recipeCoverHero(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            ZStack(alignment: .bottomLeading) {
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    LinearGradient(
                        colors: [Color(hex: "EAF7F1"), Color(hex: "F8FAFC")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "photo")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(Color(hex: "94A3B8"))
                }

                HStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 11, weight: .black))
                        .accessibilityHidden(true)
                    Text("食谱封面")
                        .font(.system(size: 12, weight: .black))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.black.opacity(0.56))
                .clipShape(Capsule())
                .padding(12)
            }
        }
        .frame(height: 168)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "EEF0F4"), lineWidth: 1))
    }

    private func recipeDetailMetaField(_ label: String, text: Binding<String>, suffix: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .black))
            Text(suffix)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var recipeMealTypeEditField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .accessibilityHidden(true)
                Text("适用餐次")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                Text(cleanMealTypes.isEmpty ? "不参与餐次限定" : "用于餐单安排")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(hex: "9CA3AF"))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(RecipeMealType.all) { option in
                    let selected = selectedRecipeMealTypes.contains(option.id)
                    Button {
                        if selected {
                            selectedRecipeMealTypes.remove(option.id)
                        } else {
                            selectedRecipeMealTypes.insert(option.id)
                        }
                    } label: {
                        Label(option.title, systemImage: option.icon)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(selected ? .white : Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(selected ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(selected ? "取消" : "选择")食谱适用\(option.title)")
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var recipeMetaInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("食谱来源")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(recipeSourceLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let cookingTime = item.recipe.cookingTime, !cookingTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(cookingTime)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "16A34A"))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color(hex: "ECFDF3"))
                        .clipShape(Capsule())
                } else if prepTimeMinutes > 0 {
                    Text("\(prepTimeMinutes)分钟")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "16A34A"))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color(hex: "ECFDF3"))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 8) {
                recipeTimeChip("主动", "\(activeTimeMinutes)分", "timer")
                recipeTimeChip("等待", "\(inactiveTimeMinutes)分", "hourglass")
            }

            if let sourceURL = item.recipe.sourceURL, !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sourceHostLabel)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        Text("已保存来源链接，方便回看原做法。")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if let url = URL(string: sourceURL), url.scheme?.hasPrefix("http") == true {
                            Button {
                                openURL(url)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "safari")
                                        .font(.system(size: 11, weight: .black))
                                        .accessibilityHidden(true)
                                    Text("打开")
                                        .font(.system(size: 12, weight: .black))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(Color.black)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("打开食谱原网页")
                        }
                        Button {
                            UIPasteboard.general.string = sourceURL
                            message = "已复制食谱来源链接。"
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .black))
                                    .accessibilityHidden(true)
                                Text("复制")
                                    .font(.system(size: 12, weight: .black))
                            }
                            .foregroundStyle(Color(hex: "2563EB"))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Color(hex: "EFF6FF"))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("复制食谱来源链接")
                    }
                }
                .padding(12)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func recipeTimeChip(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "16A34A"))
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var recipeLibraryStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "ECFDF5"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的食谱")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("保存配料、份数和做法；可记录到日记，也可转换成餐品。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(recipeSourceLabel)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color(hex: "ECFDF5"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                recipeStatusMetric("已用", "\(item.loggedCount ?? item.logged ?? 0)次")
                recipeStatusMetric("最近记录", compactDateLabel(item.loggedAt))
                recipeStatusMetric("创建", compactDateLabel(item.createdAt))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func recipeStatusMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var macroSummary: some View {
        let totals = editedTotals
        let totalNutrition = recipeTotalNutrition
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每份营养")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.secondary)
                    Text("\(Int(round(totals.calories)))")
                        .font(.system(size: 42, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(servingsCount) 份")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color(hex: "EFF6FF"))
                        .clipShape(Capsule())
                    Text("每份 \(servingSizeLabel)")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                    Text("整份 \(Int(round(totalNutrition.calories))) 千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                macroPill("蛋白质", totals.protein, "克", Color(hex: "F87171"))
                macroPill("碳水", totals.carbs, "克", Color(hex: "F59E0B"))
                macroPill("脂肪", totals.fat, "克", Color(hex: "60A5FA"))
                macroPill("纤维", totals.fiber, "克", Color(hex: "22C55E"))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var recipeExtendedNutritionRows: [(label: String, icon: String, value: Double, unit: String)] {
        var rows: [(String, String, Double, String)] = []
        if let sugar = item.recipe.sugar {
            rows.append(("糖", "cube.fill", sugar, "克"))
        }
        if item.recipe.sodium > 0 {
            rows.append(("钠", "drop.fill", item.recipe.sodium, "mg"))
        }
        if let value = item.recipe.addedSugar { rows.append(("添加糖", "sparkles", value, "克")) }
        if let value = item.recipe.satFat { rows.append(("饱和脂肪", "circle.lefthalf.filled", value, "克")) }
        if let value = item.recipe.transFat { rows.append(("反式脂肪", "arrow.triangle.2.circlepath", value, "克")) }
        if let value = item.recipe.monounsaturatedFat { rows.append(("单不饱和脂肪", "drop.triangle.fill", value, "克")) }
        if let value = item.recipe.polyunsaturatedFat { rows.append(("多不饱和脂肪", "drop.degreesign.fill", value, "克")) }
        if let value = item.recipe.cholesterol { rows.append(("胆固醇", "heart.text.square.fill", value, "mg")) }
        if let value = item.recipe.potassium { rows.append(("钾", "bolt.heart.fill", value, "mg")) }
        if let value = item.recipe.calcium { rows.append(("钙", "seal.fill", value, "mg")) }
        if let value = item.recipe.iron { rows.append(("铁", "circle.grid.cross.fill", value, "mg")) }
        if let value = item.recipe.vitaminA { rows.append(("维生素A", "eye.fill", value, "IU")) }
        if let value = item.recipe.vitaminC { rows.append(("维生素C", "leaf.fill", value, "mg")) }
        return rows
    }

    private var recipeExtendedNutritionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("更多营养")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("按每份展示，记录时会随份数同步换算。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(recipeExtendedNutritionRows.count)项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(recipeExtendedNutritionRows, id: \.label) { row in
                    recipeExtendedNutritionMetric(row.label, row.icon, row.value, row.unit)
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func recipeExtendedNutritionMetric(_ label: String, _ icon: String, _ value: Double, _ unit: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "6B7280"))
                .frame(width: 22, height: 22)
                .background(Color(hex: "F3F4F6"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text("\(formatNumber(value))\(unit)")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var portionControlCard: some View {
        let totals = loggingTotals
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记录份数")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("记录的是每份营养 × 食用份数。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("当前每份：\(servingSizeLabel)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("份", text: $portionMultiplierText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 18, weight: .black))
                        .frame(width: 54)
                    Text("份")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(servingSizeOptions.prefix(8)) { option in
                    Button {
                        let value = option.nutritionMultiplier
                        portionMultiplierText = value == floor(value) ? "\(Int(value))" : String(format: "%.2f", value)
                    } label: {
                        Text(option.displayLabel)
                            .font(.system(size: 12, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .foregroundStyle(abs(portionMultiplier - option.nutritionMultiplier) < 0.01 ? .white : Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(abs(portionMultiplier - option.nutritionMultiplier) < 0.01 ? Color.black : Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录\(option.displayLabel)")
                }
            }

            HStack(spacing: 10) {
                recipeLogMetric("本次热量", "\(Int(round(totals.calories)))千卡")
                recipeLogMetric("蛋白", "\(formatNumber(totals.protein))克")
                recipeLogMetric("碳水", "\(formatNumber(totals.carbs))克")
                recipeLogMetric("脂肪", "\(formatNumber(totals.fat))克")
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func recipeLogMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func macroPill(_ label: String, _ value: Double, _ unit: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(formatNumber(value))\(unit)")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(hex: "F7F8FA"))
        .clipShape(Capsule())
    }

    private var recipeDefaultCategoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记录到")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("选择这次食谱要加入的餐次，记录时按上面的份数换算。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(mealCategoryTitle(selectedMealCategory))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "2563EB"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                ForEach(mealCategoryOptions, id: \.0) { option in
                    Button {
                        selectedMealCategory = option.0
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.2)
                                .font(.system(size: 10, weight: .black))
                                .accessibilityHidden(true)
                            Text(option.1)
                                .font(.system(size: 12, weight: .black))
                        }
                        .foregroundStyle(selectedMealCategory == option.0 ? .white : Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(selectedMealCategory == option.0 ? Color.black : Color(hex: "F7F8FA"))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录食谱到\(option.1)")
                }
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var recipeDetailsEditCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("食谱细节")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("准备时间和做法会随食谱一起保存。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("分钟", text: $prepTimeText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 16, weight: .black))
                        .frame(width: 52)
                    Text("分钟")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
            }

            TextEditor(text: $instructionsText)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "4B5563"))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 116)
                .padding(10)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: "E5E7EB"), lineWidth: 1)
                )

            Text("每行一个步骤，例如：煮熟面条；加入鸡蛋和青菜；少油翻炒。")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var ingredientSearchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let replacingIngredientName {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .accessibilityHidden(true)
                    Text("正在替换：\(replacingIngredientName)")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Spacer()
                    Button("取消") {
                        replacingIngredientDraftId = nil
                        ingredientSearchResults = []
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color(hex: "EFF6FF"))
                .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(replacingIngredientDraftId == nil ? "搜索食材加入食谱" : "搜索食物并替换当前食材", text: $ingredientSearchQuery)
                    .font(.system(size: 14, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await searchIngredientCandidates() }
                    }
                Button {
                    Task { await searchIngredientCandidates() }
                } label: {
                    if searchingIngredients {
                        ProgressView()
                            .scaleEffect(0.72)
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
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            if !ingredientSearchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(ingredientSearchResults.prefix(5))) { food in
                        Button {
                            applyIngredientSearchResult(food)
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
                                }
                                Spacer()
                                Image(systemName: replacingIngredientDraftId == nil ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .accessibilityHidden(true)
                            }
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(replacingIngredientDraftId == nil ? "加入食材 \(food.name)" : "替换为食材 \(food.name)")
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var bulkIngredientPasteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .frame(width: 34, height: 34)
                    .background(Color(hex: "ECFDF5"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("粘贴原料")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("每行一种原料，适合从网页或备忘录补充食谱；我会先匹配常见食物，未匹配的可继续点“匹配”。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextEditor(text: $bulkIngredientText)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "111318"))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 82)
                .padding(10)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "E5E7EB"), lineWidth: 1))

            Button {
                Task { await importBulkIngredients() }
            } label: {
                HStack(spacing: 8) {
                    if importingBulkIngredients {
                        ProgressView()
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .accessibilityHidden(true)
                    }
                    Text(importingBulkIngredients ? "匹配中" : "解析并加入")
                }
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(
                saving || logging || savingAsMeal || duplicatingRecipe || deletingRecipe
                    || importingBulkIngredients
                    || bulkIngredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var ingredientMatchNoticeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "F59E0B"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("有食材需要匹配")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("这些食材来自链接或手动输入，暂时没有完整营养值。请选择常见食物替换。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(ingredientsNeedingMatch.prefix(4)) { draft in
                Button {
                    beginReplacingIngredient(draft)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.name)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .lineLimit(1)
                            Text("该食谱需要“\(draft.name)”")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("匹配")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(hex: "2563EB"))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .background(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("匹配食材 \(draft.name)")
            }
        }
        .padding(12)
        .background(Color(hex: "FFFBEB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hex: "FDE68A"), lineWidth: 1)
        )
    }

    private var ingredientMatchedSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("匹配的配料")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("这些匹配项是否正确？不准确的可以点每行的替换按钮。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(matchedIngredients.count)项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "16A34A"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "ECFDF5"))
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(matchedIngredients.prefix(6))) { draft in
                    Text("\(draft.name) · \(draft.gramsText)克")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.white)
                        .clipShape(Capsule())
                }
                if matchedIngredients.count > 6 {
                    Text("+\(matchedIngredients.count - 6)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F0FDF4"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hex: "BBF7D0"), lineWidth: 1)
        )
    }

    private func ingredientEditorRow(_ draft: Binding<RecipeIngredientDraft>, canRemove: Bool, onRemove: @escaping () -> Void) -> some View {
        let totals = draft.wrappedValue.totals
        let draftId = draft.wrappedValue.id
        let savingDraft = savingFoodTemplateDraftId == draftId
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.wrappedValue.name)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Text("\(Int(round(totals.calories))) 千卡 · 蛋白 \(formatNumber(totals.protein))克")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("克", text: draft.gramsText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 16, weight: .black))
                        .frame(width: 58)
                    Text("克")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "E5E7EB"), lineWidth: 1))

                Button {
                    Task { await saveIngredientAsFood(draft.wrappedValue) }
                } label: {
                    ZStack {
                        if savingDraft {
                            ProgressView()
                                .scaleEffect(0.66)
                                .tint(Color(hex: "2563EB"))
                        } else {
                            Image(systemName: "bookmark")
                                .font(.system(size: 14, weight: .black))
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(Color(hex: "2563EB"))
                    .frame(width: 34, height: 34)
                    .background(Color(hex: "EFF6FF"))
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(saving || logging || savingAsMeal || duplicatingRecipe || deletingRecipe || (!savingFoodTemplateDraftId.isEmpty && !savingDraft))
                .accessibilityLabel("保存食材 \(draft.wrappedValue.name) 到我的食物")

                Button {
                    beginReplacingIngredient(draft.wrappedValue)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 34, height: 34)
                        .background(.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(saving || logging || savingAsMeal || duplicatingRecipe || deletingRecipe || !savingFoodTemplateDraftId.isEmpty)
                .accessibilityLabel("替换食材 \(draft.wrappedValue.name)")

                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(canRemove ? Color(hex: "EF4444") : Color(hex: "D1D5DB"))
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(!canRemove || saving || logging || savingAsMeal || duplicatingRecipe || deletingRecipe || !savingFoodTemplateDraftId.isEmpty)
                .accessibilityLabel("移除食材 \(draft.wrappedValue.name)")
            }
        }
        .padding(14)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func searchIngredientCandidates() async {
        let query = ingredientSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchingIngredients = true
        message = ""
        do {
            ingredientSearchResults = try await APIClient.shared.searchFoods(query: query)
        } catch {
            message = infoFriendlyError(error, fallback: "搜索食材失败")
        }
        searchingIngredients = false
    }

    private func addFoodAsIngredient(_ food: FoodItem) {
        drafts.append(RecipeIngredientDraft(food: food))
        ingredientSearchQuery = ""
        ingredientSearchResults = []
        message = "已加入食材：\(food.name)。"
    }

    private func importBulkIngredients() async {
        guard !importingBulkIngredients else { return }
        let parsedLines = parsedBulkIngredientLines(from: bulkIngredientText)
        guard !parsedLines.isEmpty else { return }
        importingBulkIngredients = true
        message = ""

        var importedDrafts: [RecipeIngredientDraft] = []
        var matchedCount = 0
        var unmatchedCount = 0

        for parsed in parsedLines.prefix(24) {
            do {
                let results = try await APIClient.shared.searchFoods(query: parsed.name)
                if let food = results.first {
                    var draft = RecipeIngredientDraft(food: food)
                    if let grams = parsed.grams, grams > 0 {
                        draft.gramsText = formatNumber(grams)
                    }
                    importedDrafts.append(draft)
                    matchedCount += 1
                } else {
                    importedDrafts.append(RecipeIngredientDraft(name: parsed.name, grams: parsed.grams))
                    unmatchedCount += 1
                }
            } catch {
                importedDrafts.append(RecipeIngredientDraft(name: parsed.name, grams: parsed.grams))
                unmatchedCount += 1
            }
        }

        drafts.append(contentsOf: importedDrafts)
        bulkIngredientText = ""
        importingBulkIngredients = false
        message = unmatchedCount == 0
            ? "已解析并匹配 \(matchedCount) 个原料。"
            : "已加入 \(matchedCount + unmatchedCount) 个原料，其中 \(unmatchedCount) 个需要手动匹配。"
    }

    private func beginReplacingIngredient(_ draft: RecipeIngredientDraft) {
        replacingIngredientDraftId = draft.id
        ingredientSearchQuery = draft.name
        ingredientSearchResults = []
        message = "搜索并选择一个食物来替换：\(draft.name)。"
        Task { await searchIngredientCandidates() }
    }

    private func applyIngredientSearchResult(_ food: FoodItem) {
        if let replacingIngredientDraftId {
            replaceIngredient(id: replacingIngredientDraftId, with: food)
        } else {
            addFoodAsIngredient(food)
        }
    }

    private func replaceIngredient(id: String, with food: FoodItem) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            replacingIngredientDraftId = nil
            addFoodAsIngredient(food)
            return
        }
        let oldName = drafts[index].name
        let oldGramsText = drafts[index].gramsText
        var replacement = RecipeIngredientDraft(food: food)
        replacement.gramsText = oldGramsText
        drafts[index] = replacement
        replacingIngredientDraftId = nil
        ingredientSearchQuery = ""
        ingredientSearchResults = []
        message = "已用 \(food.name) 替换 \(oldName)，克数已保留为 \(oldGramsText)克。"
    }

    private func saveIngredientAsFood(_ draft: RecipeIngredientDraft) async {
        guard savingFoodTemplateDraftId.isEmpty else { return }
        savingFoodTemplateDraftId = draft.id
        message = ""
        do {
            let saved = try await APIClient.shared.saveFoodTemplate(draft.foodItem)
            onFoodSaved(saved)
            message = "已保存到我的食物：\(saved.name)。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存食材失败")
        }
        savingFoodTemplateDraftId = ""
    }

    private func toggleFavoriteFromDetail() async {
        guard !favoritingRecipe, !saving, !logging, !savingAsMeal, !duplicatingRecipe, !deletingRecipe else { return }
        favoritingRecipe = true
        message = ""
        do {
            let response = try await APIClient.shared.toggleIngredientRecipeFavorite(id: item.id)
            let updated = response.item ?? IngredientRecipeHistoryItem(
                id: response.recipeId ?? item.id,
                date: item.date,
                source: item.source,
                logged: item.logged,
                createdAt: item.createdAt,
                loggedAt: item.loggedAt,
                loggedCount: item.loggedCount,
                recipe: response.recipe
            )
            isFavorite = updated.recipe.favorite == true
            onUpdated(updated)
            message = isFavorite ? "已收藏食谱：\(updated.recipe.title)。" : "已取消收藏：\(updated.recipe.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "更新收藏失败")
        }
        favoritingRecipe = false
    }

    private func saveRecipe() async {
        guard !saving, !favoritingRecipe else { return }
        saving = true
        message = ""
        do {
            let response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                id: item.id,
                recipePayload: recipePayload()
            )
            let updated = response.item ?? IngredientRecipeHistoryItem(
                id: item.id,
                date: item.date,
                source: item.source,
                logged: item.logged,
                createdAt: item.createdAt,
                loggedAt: item.loggedAt,
                loggedCount: item.loggedCount,
                recipe: response.recipe
            )
            onUpdated(updated)
            message = "已保存修改。"
        } catch {
            message = infoFriendlyError(error, fallback: "保存失败")
        }
        saving = false
    }

    private func duplicateEditedRecipe() async {
        guard !saving, !logging, !savingAsMeal, !duplicatingRecipe, !favoritingRecipe, savingFoodTemplateDraftId.isEmpty else { return }
        duplicatingRecipe = true
        message = ""
        do {
            let response = try await APIClient.shared.createIngredientRecipeSuggestion(
                recipePayload: duplicatedRecipePayloadFromEdits(),
                date: logDate,
                source: item.recipe.source.isEmpty ? "ios_recipe_duplicate" : item.recipe.source
            )
            let created = response.item ?? IngredientRecipeHistoryItem(
                id: response.recipeId ?? response.recipe.id,
                date: logDate,
                source: item.recipe.source.isEmpty ? "ios_recipe_duplicate" : item.recipe.source,
                logged: nil,
                createdAt: nil,
                loggedAt: nil,
                loggedCount: nil,
                recipe: response.recipe
            )
            onRecipeCreated(created)
            message = "已另存为新食谱：\(created.recipe.title)。"
        } catch {
            message = infoFriendlyError(error, fallback: "另存食谱失败")
        }
        duplicatingRecipe = false
    }

    private func deleteRecipe() async {
        guard !saving, !logging, !savingAsMeal, !duplicatingRecipe, !deletingRecipe, !favoritingRecipe, savingFoodTemplateDraftId.isEmpty else { return }
        deletingRecipe = true
        message = ""
        do {
            _ = try await APIClient.shared.deleteIngredientRecipeSuggestion(id: item.id)
            onDeleted(item)
        } catch {
            message = infoFriendlyError(error, fallback: "删除食谱失败")
        }
        deletingRecipe = false
    }

    private func saveEditedRecipeAsMeal() async {
        guard !savingAsMeal, !favoritingRecipe else { return }
        savingAsMeal = true
        message = ""
        do {
            let response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                id: item.id,
                recipePayload: recipePayload()
            )
            let updated = response.item ?? IngredientRecipeHistoryItem(
                id: item.id,
                date: item.date,
                source: item.source,
                logged: item.logged,
                createdAt: item.createdAt,
                loggedAt: item.loggedAt,
                loggedCount: item.loggedCount,
                recipe: response.recipe
            )
            onUpdated(updated)

            let matchingMeal = savedMeals.first { $0.title.casefoldedForMealMatching == editedRecipeTitle.casefoldedForMealMatching }
            let recipeCover = response.recipe.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let meal: SavedMealItem
            if let matchingMeal {
                let mealCover = (matchingMeal.imageUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                meal = try await APIClient.shared.updateSavedMeal(
                    id: matchingMeal.id,
                    title: matchingMeal.title,
                    foods: [editedRecipeFoodItem],
                    mealCategory: selectedMealCategory,
                    imageUrl: mealCover.isEmpty ? recipeCover : mealCover,
                    note: response.recipe.reason,
                    instructions: response.recipe.instructions
                )
                onMealUpdated(meal)
                message = "已替换同名餐品：\(meal.title)。"
            } else {
                meal = try await APIClient.shared.saveMealTemplate(
                    title: editedRecipeTitle,
                    foods: [editedRecipeFoodItem],
                    mealCategory: selectedMealCategory,
                    imageUrl: recipeCover,
                    note: response.recipe.reason,
                    instructions: response.recipe.instructions
                )
                onMealCreated(meal)
                message = "已保存为餐品：\(meal.title)。"
            }
        } catch {
            message = infoFriendlyError(error, fallback: "保存为餐品失败")
        }
        savingAsMeal = false
    }

    private func logEditedRecipe() async {
        guard !logging, !favoritingRecipe else { return }
        logging = true
        message = ""
        do {
            let response = try await APIClient.shared.updateIngredientRecipeSuggestion(
                id: item.id,
                recipePayload: recipePayload()
            )
            let updated = response.item ?? IngredientRecipeHistoryItem(
                id: item.id,
                date: item.date,
                source: item.source,
                logged: item.logged,
                createdAt: item.createdAt,
                loggedAt: item.loggedAt,
                loggedCount: item.loggedCount,
                recipe: response.recipe
            )
            onUpdated(updated)
            _ = try await APIClient.shared.logIngredientRecipe(
                id: item.id,
                portionMultiplier: portionMultiplier,
                servingSizeLabel: selectedServingSizeLabelForLog,
                mealCategory: selectedMealCategory,
                date: logDate
            )
            onLogged()
        } catch {
            message = infoFriendlyError(error, fallback: "记录失败")
        }
        logging = false
    }

    private var editedRecipeTitle: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanTitle.isEmpty ? item.recipe.title : cleanTitle
    }

    private var editedRecipeFoodItem: FoodItem {
        let totals = editedTotals
        var foodItem = FoodItem(
            name: editedRecipeTitle,
            calories: round1(totals.calories),
            protein: round1(totals.protein),
            carbs: round1(totals.carbs),
            fat: round1(totals.fat),
            fiber: round1(totals.fiber),
            sugar: round1(totals.sugar),
            sodium: round1(totals.sodium),
            servingSize: servingSizeLabel,
            processingLevel: "prepared",
            addedSugar: item.recipe.addedSugar ?? round1(totals.sugar)
        )
        foodItem.satFat = item.recipe.satFat ?? 0
        foodItem.transFat = item.recipe.transFat ?? 0
        foodItem.cholesterol = item.recipe.cholesterol ?? 0
        foodItem.vitaminA = item.recipe.vitaminA ?? 0
        foodItem.vitaminC = item.recipe.vitaminC ?? 0
        foodItem.calcium = item.recipe.calcium ?? 0
        foodItem.iron = item.recipe.iron ?? 0
        foodItem.potassium = item.recipe.potassium ?? 0
        return foodItem
    }

    private func recipePayload() -> [String: Any] {
        let totals = editedTotals
        var data: [String: Any] = [
            "id": item.recipe.id,
            "title": editedRecipeTitle,
            "servings": servingsCount,
            "serving_size_label": servingSizeLabel,
            "serving_sizes": recipeServingSizeOptionsPayload(servingSizeOptions),
            "calories": round1(totals.calories),
            "protein": round1(totals.protein),
            "carbs": round1(totals.carbs),
            "fat": round1(totals.fat),
            "fiber": round1(totals.fiber),
            "sodium": round1(totals.sodium),
            "sugar": round1(totals.sugar),
            "prep_time_minutes": prepTimeMinutes,
            "active_time_minutes": activeTimeMinutes,
            "inactive_time_minutes": inactiveTimeMinutes,
            "reason": item.recipe.reason,
            "instructions": editedInstructions,
            "ingredients_breakdown": drafts.map { $0.payload },
            "missing_ingredients": ingredientsNeedingMatch.map(\.name),
            "source": item.recipe.source,
            "tags": item.recipe.tags ?? [],
            "meal_types": cleanMealTypes,
            "favorite": isFavorite
        ]
        if let sourceURL = item.recipe.sourceURL, !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data["source_url"] = sourceURL
        }
        if let cookingTime = item.recipe.cookingTime, !cookingTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data["cooking_time"] = cookingTime
        }
        if let imageURL = item.recipe.imageURL, !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data["image_url"] = imageURL
        }
        data.merge(recipeExtendedNutritionPayload(item.recipe), uniquingKeysWith: { _, new in new })
        return data
    }

    private func duplicatedRecipePayloadFromEdits() -> [String: Any] {
        var payload = recipePayload()
        payload.removeValue(forKey: "id")
        payload["title"] = "\(editedRecipeTitle) 副本"
        payload["reason"] = "由\(editedRecipeTitle)另存"
        payload["source"] = item.recipe.source.isEmpty ? "ios_recipe_duplicate" : item.recipe.source
        payload["tags"] = (item.recipe.tags ?? []) + ["副本"]
        payload["meal_types"] = cleanMealTypes
        return payload
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func parsedBulkIngredientLines(from text: String) -> [ParsedBulkIngredientLine] {
        text
            .components(separatedBy: .newlines)
            .map { ParsedBulkIngredientLine(raw: $0) }
            .compactMap { $0 }
    }

    private struct ParsedBulkIngredientLine {
        let name: String
        let grams: Double?

        init?(raw: String) {
            let cleaned = raw
                .replacingOccurrences(of: "，", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }

            var parsedGrams: Double?
            var nameText = cleaned
            if let amountRange = cleaned.range(
                of: #"(\d+(?:[.,]\d+)?)\s*(克|g|G|毫升|ml|mL|ML)"#,
                options: .regularExpression
            ) {
                let amountText = String(cleaned[amountRange])
                let numberText = amountText
                    .replacingOccurrences(of: ",", with: ".")
                    .filter { $0.isNumber || $0 == "." }
                parsedGrams = Double(numberText)
                nameText.removeSubrange(amountRange)
            }

            let trimmedName = nameText
                .trimmingCharacters(in: CharacterSet(charactersIn: " -—–_:：*×xX，,、；;").union(.whitespacesAndNewlines))
            name = trimmedName.isEmpty ? cleaned : trimmedName
            grams = parsedGrams
        }
    }

    private func mealCategoryTitle(_ key: String) -> String {
        mealCategoryOptions.first { $0.0 == key }?.1 ?? "加餐"
    }

    private static func normalizedMealCategory(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("breakfast") || text.contains("早餐") { return "breakfast" }
        if text.contains("lunch") || text.contains("午餐") { return "lunch" }
        if text.contains("dinner") || text.contains("晚餐") { return "dinner" }
        if text.contains("snack") || text.contains("加餐") || text.contains("零食") { return "snack" }
        return "snack"
    }

    private func formatNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(round(value)))"
        }
        return String(format: "%.1f", value)
    }

    private func compactDateLabel(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "未记录" }
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let datePart = normalized.split(separator: " ").first.map(String.init) ?? normalized
        if datePart.count >= 10 {
            let start = datePart.index(datePart.startIndex, offsetBy: 5)
            return String(datePart[start...])
        }
        return datePart
    }
}

private struct RecipeIngredientDraft: Identifiable {
    let id = UUID().uuidString
    let name: String
    let baseGrams: Double
    let baseCalories: Double
    let baseProtein: Double
    let baseCarbs: Double
    let baseFat: Double
    let baseFiber: Double
    let baseSodium: Double
    let baseSugar: Double
    let processingLevel: String?
    var gramsText: String

    init(item: IngredientBreakdownItem) {
        name = item.name
        let parsed = RecipeIngredientDraft.parseGrams(item.displayAmount ?? item.amount)
        baseGrams = parsed > 0 ? parsed : 100
        baseCalories = item.calories
        baseProtein = item.protein
        baseCarbs = item.carbs ?? 0
        baseFat = item.fat ?? 0
        baseFiber = 0
        baseSodium = 0
        baseSugar = item.sugar ?? 0
        processingLevel = item.processingLevel
        gramsText = "\(Int(round(baseGrams)))"
    }

    init(food: FoodItem) {
        name = food.name
        let parsed = RecipeIngredientDraft.parseGrams(food.servingSize)
        baseGrams = parsed > 0 ? parsed : 100
        baseCalories = food.calories
        baseProtein = food.protein
        baseCarbs = food.carbs
        baseFat = food.fat
        baseFiber = food.fiber
        baseSodium = food.sodium
        baseSugar = food.sugar
        processingLevel = food.processingLevel
        gramsText = "\(Int(round(baseGrams)))"
    }

    init(name rawName: String, grams: Double?) {
        name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未匹配原料" : rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        baseGrams = max(1, grams ?? 100)
        baseCalories = 0
        baseProtein = 0
        baseCarbs = 0
        baseFat = 0
        baseFiber = 0
        baseSodium = 0
        baseSugar = 0
        processingLevel = "unmatched"
        gramsText = "\(Int(round(baseGrams)))"
    }

    private var grams: Double {
        let normalized = gramsText.replacingOccurrences(of: ",", with: ".")
        return max(0, Double(normalized) ?? baseGrams)
    }

    private var scale: Double {
        baseGrams <= 0 ? 1 : grams / baseGrams
    }

    var totals: RecipeTotals {
        RecipeTotals(
            calories: baseCalories * scale,
            protein: baseProtein * scale,
            carbs: baseCarbs * scale,
            fat: baseFat * scale,
            fiber: baseFiber * scale,
            sodium: baseSodium * scale,
            sugar: baseSugar * scale
        )
    }

    var foodItem: FoodItem {
        let t = totals
        let roundedGrams = Int(round(grams))
        return FoodItem(
            name: name,
            calories: round1(t.calories),
            protein: round1(t.protein),
            carbs: round1(t.carbs),
            fat: round1(t.fat),
            fiber: round1(t.fiber),
            sugar: round1(t.sugar),
            sodium: round1(t.sodium),
            servingSize: "\(roundedGrams)克",
            processingLevel: processingLevel ?? "ingredient",
            addedSugar: round1(t.sugar)
        )
    }

    var payload: [String: Any] {
        let t = totals
        let roundedGrams = Int(round(grams))
        var data: [String: Any] = [
            "name": name,
            "amount": "\(roundedGrams)克",
            "display_amount": "\(roundedGrams)克",
            "calories": round1(t.calories),
            "protein": round1(t.protein),
            "carbs": round1(t.carbs),
            "fat": round1(t.fat),
            "fiber": round1(t.fiber),
            "sodium": round1(t.sodium),
            "sugar": round1(t.sugar),
            "serving_size": "\(roundedGrams)克"
        ]
        if let level = processingLevel {
            data["processing_level"] = level
        }
        return data
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func parseGrams(_ text: String) -> Double {
        let normalized = text
            .replacingOccurrences(of: "ｇ", with: "g")
            .replacingOccurrences(of: "克", with: "g")
        var number = ""
        for char in normalized {
            if char.isNumber || char == "." {
                number.append(char)
            } else if !number.isEmpty {
                break
            }
        }
        return Double(number) ?? 0
    }
}

private struct RecipeTotals {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var sodium: Double = 0
    var sugar: Double = 0

    func adding(_ other: RecipeTotals) -> RecipeTotals {
        RecipeTotals(
            calories: calories + other.calories,
            protein: protein + other.protein,
            carbs: carbs + other.carbs,
            fat: fat + other.fat,
            fiber: fiber + other.fiber,
            sodium: sodium + other.sodium,
            sugar: sugar + other.sugar
        )
    }

    func scaled(by multiplier: Double) -> RecipeTotals {
        RecipeTotals(
            calories: calories * multiplier,
            protein: protein * multiplier,
            carbs: carbs * multiplier,
            fat: fat * multiplier,
            fiber: fiber * multiplier,
            sodium: sodium * multiplier,
            sugar: sugar * multiplier
        )
    }
}

private struct DiaryFoodPortionEditTarget: Identifiable {
    let row: FoodLogRow

    var id: Int {
        row.id ?? -1
    }
}

private struct MealCategoryCopyTarget: Identifiable {
    let key: String
    let title: String
    let sourceDate: String
    let initialDate: Date

    var id: String {
        "\(key)-\(sourceDate)"
    }
}

private struct MealCategoryDetailTarget: Identifiable {
    let key: String
    let title: String
    let icon: String

    var id: String { key }
}

private struct MealCategorySaveTarget: Identifiable {
    let key: String
    let title: String
    let defaultTitle: String
    let itemCount: Int
    let calories: Double

    var id: String { key }
}

private struct MealCategorySaveSheetView: View {
    let target: MealCategorySaveTarget
    let saving: Bool
    let savingRecipe: Bool
    let replacing: Bool
    let savedMeals: [SavedMealItem]
    let savedRecipes: [IngredientRecipeHistoryItem]
    let onClose: () -> Void
    let onSave: (String) -> Void
    let onSaveRecipe: (String) -> Void
    let onReplace: (SavedMealItem) -> Void
    let onReplaceRecipe: (IngredientRecipeHistoryItem) -> Void

    @State private var titleText: String

    private var busy: Bool {
        saving || savingRecipe || replacing
    }

    init(
        target: MealCategorySaveTarget,
        saving: Bool,
        savingRecipe: Bool,
        replacing: Bool,
        savedMeals: [SavedMealItem],
        savedRecipes: [IngredientRecipeHistoryItem],
        onClose: @escaping () -> Void,
        onSave: @escaping (String) -> Void,
        onSaveRecipe: @escaping (String) -> Void,
        onReplace: @escaping (SavedMealItem) -> Void,
        onReplaceRecipe: @escaping (IngredientRecipeHistoryItem) -> Void
    ) {
        self.target = target
        self.saving = saving
        self.savingRecipe = savingRecipe
        self.replacing = replacing
        self.savedMeals = savedMeals
        self.savedRecipes = savedRecipes
        self.onClose = onClose
        self.onSave = onSave
        self.onSaveRecipe = onSaveRecipe
        self.onReplace = onReplace
        self.onReplaceRecipe = onReplaceRecipe
        _titleText = State(initialValue: target.defaultTitle)
    }

    private var cleanTitle: String {
        titleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingSavedMeal: SavedMealItem? {
        let normalizedTitle = cleanTitle.casefoldedForMealMatching
        guard !normalizedTitle.isEmpty else { return nil }
        return savedMeals.first { $0.title.casefoldedForMealMatching == normalizedTitle }
    }

    private var matchingSavedRecipe: IngredientRecipeHistoryItem? {
        let normalizedTitle = cleanTitle.casefoldedForMealMatching
        guard !normalizedTitle.isEmpty else { return nil }
        return savedRecipes.first { $0.recipe.title.casefoldedForMealMatching == normalizedTitle }
    }

    private var primaryMealSaveButtonTitle: String {
        if saving { return "保存中" }
        if replacing { return "替换中" }
        return matchingSavedMeal == nil ? "保存餐品" : "替换同名餐品"
    }

    private var primaryRecipeSaveButtonTitle: String {
        if savingRecipe { return "保存中" }
        if replacing { return "替换中" }
        return matchingSavedRecipe == nil ? "保存食谱" : "替换同名食谱"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("保存此餐食")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("\(target.title) · \(target.itemCount) 项 · \(Int(round(target.calories))) 千卡")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("餐品名称")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                    TextField("例如：工作日午餐、鸡胸肉便当", text: $titleText)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Text("可以保存为“餐品”一键复用，也可以保存为“食谱”保留配料结构。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "F8FAFC"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let matchingSavedMeal {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "B45309"))
                            .frame(width: 34, height: 34)
                            .background(Color(hex: "FEF3C7"))
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("已有同名餐品")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("保存会替换“\(matchingSavedMeal.title)”，避免我的餐品里出现重复。")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(hex: "FFFBEB"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "FDE68A"), lineWidth: 1))
                }

                if let matchingSavedRecipe {
                    HStack(spacing: 10) {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "047857"))
                            .frame(width: 34, height: 34)
                            .background(Color(hex: "ECFDF5"))
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("已有同名食谱")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("保存为食谱会替换“\(matchingSavedRecipe.recipe.title)”，避免我的食谱里出现重复。")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(hex: "F0FDF4"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "BBF7D0"), lineWidth: 1))
                }

                if !savedMeals.isEmpty {
                    Menu {
                        ForEach(Array(savedMeals.prefix(16))) { meal in
                            Button {
                                onReplace(meal)
                            } label: {
                                Label(meal.title, systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: replacing ? "hourglass" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(Color(hex: "2563EB"))
                                .frame(width: 34, height: 34)
                                .background(Color(hex: "EEF7FF"))
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(replacing ? "替换中" : "替换已有餐品")
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                Text("用当前\(target.title)覆盖一个餐品模板。")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(Color(hex: "A0A7B3"))
                                .accessibilityHidden(true)
                        }
                        .padding(12)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel("替换已有餐品")
                }

                Spacer()

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        saveModeButton(
                            title: primaryMealSaveButtonTitle,
                            icon: matchingSavedMeal == nil ? "tray.and.arrow.down.fill" : "arrow.triangle.2.circlepath",
                            busy: saving || replacing,
                            disabled: cleanTitle.isEmpty || busy,
                            foreground: .white,
                            background: cleanTitle.isEmpty || busy ? Color(hex: "A0A7B3") : Color.black
                        ) {
                            if let matchingSavedMeal {
                                onReplace(matchingSavedMeal)
                            } else {
                                onSave(cleanTitle)
                            }
                        }

                        saveModeButton(
                            title: primaryRecipeSaveButtonTitle,
                            icon: matchingSavedRecipe == nil ? "book.closed.fill" : "arrow.triangle.2.circlepath",
                            busy: savingRecipe || replacing,
                            disabled: cleanTitle.isEmpty || busy,
                            foreground: Color(hex: "111318"),
                            background: cleanTitle.isEmpty || busy ? Color(hex: "E5E7EB") : Color(hex: "ECFDF5")
                        ) {
                            if let matchingSavedRecipe {
                                onReplaceRecipe(matchingSavedRecipe)
                            } else {
                                onSaveRecipe(cleanTitle)
                            }
                        }
                    }

                    Button(action: onClose) {
                        Text("取消")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .padding(20)
            .background(AppShellBackground())
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func saveModeButton(
        title: String,
        icon: String,
        busy: Bool,
        disabled: Bool,
        foreground: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .tint(foreground)
                        .scaleEffect(0.74)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .black))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 14, weight: .black))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(background)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct MealCategoryDetailSheetView: View {
    let target: MealCategoryDetailTarget
    let rows: [FoodLogRow]
    let calorieTarget: Double
    let proteinTarget: Double
    let carbsTarget: Double
    let fatTarget: Double
    let saving: Bool
    let copying: Bool
    let clearing: Bool
    let onClose: () -> Void
    let onQuickAdd: () -> Void
    let onOpenLibrary: () -> Void
    let onSaveMeal: () -> Void
    let onCopyPrevious: () -> Void
    let onCopyTomorrow: () -> Void
    let onCopyDate: () -> Void
    let onClear: () -> Void
    let onEditFood: (FoodLogRow) -> Void

    private var calories: Double { rows.reduce(0) { $0 + ($1.calories ?? 0) } }
    private var protein: Double { rows.reduce(0) { $0 + ($1.protein ?? 0) } }
    private var carbs: Double { rows.reduce(0) { $0 + ($1.carbs ?? 0) } }
    private var fat: Double { rows.reduce(0) { $0 + ($1.fat ?? 0) } }
    private var remaining: Double { calorieTarget - calories }
    private var busy: Bool { saving || copying || clearing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    toolsCard
                    foodsCard
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 36, height: 36)
                            .background(.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭本餐详情")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: target.icon)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(target.title)详情")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(rows.isEmpty ? "先记录这餐，详情会自动汇总。" : "\(rows.count) 项食物 · \(Int(round(calories))) 千卡")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(calories)))")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("千卡")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(remaining >= 0 ? "剩余 \(Int(round(remaining))) 千卡" : "超出 \(Int(round(abs(remaining)))) 千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(remaining >= 0 ? Color(hex: "2563EB") : Color(hex: "EF4444"))
                    Spacer()
                    Text("目标 \(Int(round(calorieTarget)))")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(max(calories / max(calorieTarget, 1), 0), 1))
                    .tint(remaining >= 0 ? Color.black : Color(hex: "EF4444"))
            }

            HStack(spacing: 8) {
                detailMacroPill("蛋白", value: protein, goal: proteinTarget, tint: Color(hex: "EF4444"))
                detailMacroPill("碳水", value: carbs, goal: carbsTarget, tint: Color(hex: "F59E0B"))
                detailMacroPill("脂肪", value: fat, goal: fatTarget, tint: Color(hex: "2563EB"))
            }
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 10)
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("餐食工具")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color(hex: "111318"))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                detailToolButton("手动记", icon: "plus.app.fill", disabled: busy, action: onQuickAdd)
                detailToolButton("从库添加", icon: "tray.full.fill", disabled: busy, action: onOpenLibrary)
                detailToolButton(saving ? "保存中" : "保存此餐食", icon: "tray.and.arrow.down.fill", disabled: rows.isEmpty || busy, action: onSaveMeal)
                detailToolButton(copying ? "复制中" : "复制之前", icon: "arrow.uturn.backward", disabled: busy, action: onCopyPrevious)
                detailToolButton(copying ? "复制中" : "复制到明天", icon: "calendar.badge.plus", disabled: rows.isEmpty || busy, action: onCopyTomorrow)
                detailToolButton("复制到日期", icon: "calendar", disabled: rows.isEmpty || busy, action: onCopyDate)
                detailToolButton(clearing ? "清空中" : "清空本餐", icon: "trash", roleColor: Color(hex: "EF4444"), disabled: rows.isEmpty || busy, action: onClear)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var foodsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本餐食物")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text("\(rows.count)项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }

            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "fork.knife.circle")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Color(hex: "A0A7B3"))
                    Text("先手动记一个食物，或从餐品、食谱、找食物里选择。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                VStack(spacing: 9) {
                    ForEach(rows) { row in
                        Button { onEditFood(row) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.displayName)
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                        .lineLimit(1)
                                    Text(foodDetailSubtitle(row))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Int(round(row.calories ?? 0)))")
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                    Text("千卡")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("调整\(row.displayName)份量")
                    }
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func detailMacroPill(_ title: String, value: Double, goal: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            Text("\(formatMacro(value))/\(formatMacro(goal))克")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            ProgressView(value: min(max(value / max(goal, 1), 0), 1))
                .tint(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detailToolButton(_ title: String, icon: String, roleColor: Color = Color(hex: "111318"), disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Spacer()
            }
            .foregroundStyle(disabled ? Color(hex: "A0A7B3") : roleColor)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func foodDetailSubtitle(_ row: FoodLogRow) -> String {
        var parts = [row.displayServingSize]
        let quantity = row.displayQuantity
        if !quantity.isEmpty { parts.append(quantity) }
        parts.append("蛋 \(formatMacro(row.protein ?? 0))")
        parts.append("碳 \(formatMacro(row.carbs ?? 0))")
        parts.append("脂 \(formatMacro(row.fat ?? 0))")
        return parts.joined(separator: " · ")
    }

    private func formatMacro(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }
}

private struct MealCategoryCopyDateSheetView: View {
    let target: MealCategoryCopyTarget
    let onClose: () -> Void
    let onCopy: (String) -> Void

    @State private var selectedDate: Date

    init(target: MealCategoryCopyTarget, onClose: @escaping () -> Void, onCopy: @escaping (String) -> Void) {
        self.target = target
        self.onClose = onClose
        self.onCopy = onCopy
        _selectedDate = State(initialValue: target.initialDate)
    }

    private var targetDateString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: selectedDate)
    }

    private var targetDateLabel: String {
        if Calendar.current.isDateInToday(selectedDate) { return "今天" }
        if Calendar.current.isDateInTomorrow(selectedDate) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: selectedDate)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("复制\(target.title)")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("把当前\(target.title)的所有食物复制到另一日期的同一餐次。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                DatePicker("目标日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "2563EB"))
                        .frame(width: 40, height: 40)
                        .background(Color(hex: "EFF6FF"))
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("将复制到\(targetDateLabel)")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("保存后可在该日期的\(target.title)中继续编辑份量。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Spacer()

                Button {
                    onCopy(targetDateString)
                } label: {
                    Text("复制到\(targetDateLabel)")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct RecentMealCopyDateSheetView: View {
    let group: MealHistoryGroup
    let onClose: () -> Void
    let onCopy: (String, String) -> Void

    @State private var selectedDate: Date

    init(group: MealHistoryGroup, onClose: @escaping () -> Void, onCopy: @escaping (String, String) -> Void) {
        self.group = group
        self.onClose = onClose
        self.onCopy = onCopy
        _selectedDate = State(initialValue: Date())
    }

    private var targetDateString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: selectedDate)
    }

    private var targetDateLabel: String {
        if Calendar.current.isDateInToday(selectedDate) { return "今天" }
        if Calendar.current.isDateInTomorrow(selectedDate) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: selectedDate)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("复制餐食")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("把这份历史餐食复制到另一日期，复制后仍可在日记里调整份量。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "fork.knife.circle.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.title)
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(2)
                        Text("\(group.count) 项 · \(Int(round(group.calories))) 千卡")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(group.names.prefix(4).joined(separator: "、"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: "9CA3AF"))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                DatePicker("目标日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                Spacer()

                Button {
                    onCopy(targetDateString, targetDateLabel)
                } label: {
                    Text("复制到\(targetDateLabel)")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onClose)
                        .font(.system(size: 14, weight: .black))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct DiaryFoodPortionSheetView: View {
    let row: FoodLogRow
    let onClose: () -> Void
    let onApply: (Double) -> Void

    @State private var ratioText: String

    init(row: FoodLogRow, onClose: @escaping () -> Void, onApply: @escaping (Double) -> Void) {
        self.row = row
        self.onClose = onClose
        self.onApply = onApply
        _ratioText = State(initialValue: Self.initialRatioText(row.consumedRatioValue))
    }

    private var parsedRatio: Double? {
        let normalized = ratioText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return max(0.05, min(20.0, value))
    }

    private var estimatedCalories: Double {
        let base = row.originalCalorieValue > 0 ? row.originalCalorieValue : (row.calories ?? 0)
        return base * (parsedRatio ?? row.consumedRatioValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.displayName)
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(2)
                        Text(row.displayServingSize)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("记录份数")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            TextField("例如 1.25", text: $ratioText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 28, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .padding(.horizontal, 16)
                                .frame(height: 58)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Text("倍")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                        Text("可输入 0.05 到 20 倍，保存后会重新计算这项食物和今日总摄入。")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        quickRatioButton(0.25, "1/4")
                        quickRatioButton(0.5, "一半")
                        quickRatioButton(1.0, "原份")
                        quickRatioButton(1.5, "1.5 倍")
                        quickRatioButton(2.0, "2 倍")
                        quickRatioButton(3.0, "3 倍")
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("预计热量")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.secondary)
                            Text("\(Int(round(estimatedCalories))) 千卡")
                                .font(.system(size: 26, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("当前")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.secondary)
                            Text(row.consumedPortionLabel)
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(Color(hex: "2563EB"))
                        }
                    }
                    .padding(16)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Button {
                        if let parsedRatio {
                            onApply(parsedRatio)
                        }
                    } label: {
                        Text("应用份数")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(parsedRatio == nil ? Color(hex: "A0A7B3") : Color.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(parsedRatio == nil)
                }
                .padding(20)
            }
            .background(AppShellBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onClose)
                        .font(.system(size: 15, weight: .black))
                }
            }
        }
    }

    private func quickRatioButton(_ ratio: Double, _ label: String) -> some View {
        Button {
            ratioText = Self.initialRatioText(ratio)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color(hex: "F7F8FA"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private static func initialRatioText(_ ratio: Double) -> String {
        if ratio.rounded() == ratio {
            return "\(Int(ratio))"
        }
        return String(format: "%.2f", ratio).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

private struct MealPlanMealRow: View {
    let meal: MealPlanMeal
    let isLogging: Bool
    let isSwapping: Bool
    let onLog: () -> Void
    let onSwap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(meal.name)
                        .font(.system(size: 16, weight: .black))
                        .lineLimit(2)
                    Text("蛋白 \(Int(round(meal.protein)))克 · 碳水 \(Int(round(meal.carbs)))克 · 脂肪 \(Int(round(meal.fat)))克")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(meal.calories)))")
                        .font(.system(size: 20, weight: .black))
                    Text("千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }
            if !meal.ingredients.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(meal.ingredients.prefix(6)), id: \.self) { tag in
                        Text(tag)
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
            HStack(spacing: 10) {
                Button(action: onSwap) {
                    HStack(spacing: 6) {
                        if isSwapping {
                            ProgressView()
                                .tint(Color(hex: "111318"))
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .accessibilityHidden(true)
                        }
                        Text(isSwapping ? "替换中" : "换一餐")
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
                }
                .disabled(isLogging || isSwapping)

                Button(action: onLog) {
                    HStack(spacing: 8) {
                        if isLogging {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .accessibilityHidden(true)
                        }
                        Text(isLogging ? "记录中" : "记录这一餐")
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.black)
                    .clipShape(Capsule())
                }
                .disabled(isLogging || isSwapping)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }
}
