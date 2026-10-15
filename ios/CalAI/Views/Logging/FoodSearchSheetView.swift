import SwiftUI

struct FoodSearchSheetView: View {
    let logDate: String
    let onClose: () -> Void
    let onLogged: () -> Void
    let onEstimated: (DescribeMealResponse) -> Void
    let onManual: () -> Void

    @State private var query = ""
    @State private var mealCategory = FoodSearchSheetView.defaultMealCategory()
    @State private var results: [FoodItem] = []
    @State private var loading = false
    @State private var estimating = false
    @State private var savingId = ""
    @State private var searched = false
    @State private var error = ""
    @State private var selectedFood: FoodItem?

    private let mealOptions = [
        ("breakfast", "早餐"),
        ("lunch", "午餐"),
        ("dinner", "晚餐"),
        ("snack", "加餐"),
    ]
    private let popularTerms = ["米饭", "鸡蛋", "鸡胸肉", "苹果", "拿铁", "酸奶"]

    private var resultCalories: Double {
        results.reduce(0) { $0 + $1.calories }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    grabber
                    header
                    searchCard
                    mealSelector
                    if loading || searched || !results.isEmpty {
                        resultSection
                    } else {
                        quickStartCard
                    }
                    if !error.isEmpty {
                        errorCard
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 42)
            }
            .background(AppShellBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .sheet(item: $selectedFood) { food in
            SearchPortionConfirmSheet(food: food) { adjustedFood in
                selectedFood = nil
                Task { await log(adjustedFood) }
            }
            .presentationDetents([.height(390)])
            .presentationDragIndicator(.visible)
        }
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
                    Image(systemName: "magnifyingglass")
                        .accessibilityHidden(true)
                    Text("找食物记录")
                }
                .font(.system(size: 25, weight: .black))
                Text("先选食品，再确认克数或份数。")
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
            .accessibilityLabel("关闭搜索食物")
        }
    }

    private var searchSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "常吃食物" : query)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    Text(results.isEmpty ? "输入食物名" : "找到 \(results.count) 项")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color(hex: "73D39B"))
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }

            HStack(spacing: 10) {
                searchMetric(title: "匹配", value: "\(results.count)", unit: "项", icon: "list.bullet")
                searchMetric(title: "均值", value: results.isEmpty ? "--" : "\(Int((resultCalories / Double(results.count)).rounded()))", unit: "千卡", icon: "flame.fill")
                searchMetric(title: "记录", value: estimating ? "估" : "点", unit: estimating ? "算中" : "一下", icon: "sparkles")
            }
        }
        .padding(18)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: "20252B"), Color(hex: "111318")], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [Color(hex: "73D39B").opacity(0.24), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 22, x: 0, y: 12)
    }

    private func searchMetric(title: String, value: String, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "73D39B"))
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(unit)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("先找常吃的")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("选中食品后，用一行份量选择器确认。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "8B919B"))
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("鸡蛋、米饭、拿铁、品牌食品", text: $query)
                    .font(.system(size: 15, weight: .bold))
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await search() }
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color(hex: "F0F0F3"), lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(popularTerms, id: \.self) { term in
                        Button {
                            query = term
                            Task { await search() }
                        } label: {
                            Text(term)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(query == term ? Color(hex: "F1FBF5") : .white)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(query == term ? Color(hex: "73D39B") : Color(hex: "F0F0F3"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(loading || estimating)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await search() }
                } label: {
                    HStack(spacing: 8) {
                        if loading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                                .accessibilityHidden(true)
                        }
                        Text(loading ? "正在找食物" : "查找食物")
                        Spacer()
                        Text("更准")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                }
                .frame(height: 48)
                .frame(maxWidth: .infinity)
                .background(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color(hex: "111318"))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .disabled(loading || estimating || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await estimateWithAI() }
                } label: {
                    HStack(spacing: 7) {
                        if estimating {
                            ProgressView().tint(Color(hex: "111318"))
                        } else {
                            Image(systemName: "sparkles")
                                .accessibilityHidden(true)
                        }
                        Text(estimating ? "正在按描述估一份" : "没找到？按描述估")
                        Spacer()
                        Text("可改")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "9AA0AA"))
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 13)
                }
                .frame(height: 42)
                .frame(maxWidth: .infinity)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(hex: "E5E7EB"), lineWidth: 1))
                .disabled(loading || estimating || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var mealSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("记录到")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(mealOptions.first(where: { $0.0 == mealCategory })?.1 ?? "自动")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "9AA0AA"))
            }
            HStack(spacing: 8) {
                ForEach(mealOptions, id: \.0) { item in
                    Button {
                        mealCategory = item.0
                    } label: {
                        Text(item.1)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(mealCategory == item.0 ? .white : Color(hex: "6B7280"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(mealCategory == item.0 ? Color(hex: "111318") : .white.opacity(0.92))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var quickStartCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "73D39B"))
                .frame(width: 34, height: 34)
                .background(Color(hex: "F1FBF5"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("赶时间也能记")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("知道大概吃了什么，直接手动记一条。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8B919B"))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                onClose()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    onManual()
                }
            } label: {
                Text("手动补记")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    @ViewBuilder
    private var resultSection: some View {
        if loading {
            CalLoadingCard(
                title: "正在找食物",
                subtitle: "找到后点“记录”就会写入今天",
                systemImage: "magnifyingglass"
            )
            .padding(.vertical, 8)
        } else if results.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("找到这些")
                            .font(.system(size: 18, weight: .black))
                        Text("先选食品，再确认克数或份数")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: "9AA0AA"))
                    }
                    Spacer()
                    Text("\(results.count) 项")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(hex: "F3F4F6"))
                        .clipShape(Capsule())
                }
                ForEach(results) { food in
                    resultRow(food)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: searched ? "tray" : "magnifyingglass")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color(hex: "111318"))
                .accessibilityHidden(true)
            Text(searched ? "没找到，直接估一份" : "输入一个食物名")
                .font(.system(size: 18, weight: .black))
            Text(searched ? "按描述生成记录，保存后还能改份量。" : "例如米饭、鸡蛋、拿铁，找到后点记上。")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if searched {
                VStack(spacing: 8) {
                    emptyActionButton(
                        title: estimating ? "正在估算" : "按描述估一份",
                        icon: "sparkles",
                        filled: true
                    ) {
                        Task { await estimateWithAI() }
                    }
                    emptyActionButton(
                        title: "手动补记",
                        icon: "square.and.pencil",
                        filled: false
                    ) {
                        onClose()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            onManual()
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var errorCard: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "D93025"))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(error)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "9B1C1C"))
                .lineLimit(3)
            Spacer(minLength: 0)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await estimateWithAI() }
                } label: {
                    Text("按描述估")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "9B1C1C"))
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(.white.opacity(0.82))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(loading || estimating)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: "FFF1F0"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func resultRow(_ food: FoodItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: "F7F8FA"))
                    .frame(width: 46, height: 46)
                Image(systemName: "fork.knife")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(food.name)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                HStack(spacing: 6) {
                    pill("\(Int(round(food.calories))) 千卡")
                    pill(food.servingSize)
                    if food.protein > 0 {
                        pill("蛋 \(format(food.protein))克")
                    }
                }
                .lineLimit(1)
                Text("碳 \(format(food.carbs))克 · 脂 \(format(food.fat))克 · 纤维 \(format(food.fiber))克 · 钠 \(Int(round(food.sodium)))毫克")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Spacer(minLength: 8)
            Button {
                selectedFood = food
            } label: {
                if savingId == food.id {
                    ProgressView().tint(.white)
                } else {
                    Text("选份量")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 68, height: 40)
            .background(Color(hex: "111318"))
            .clipShape(Capsule())
            .disabled(!savingId.isEmpty)
            .accessibilityLabel("选择\(food.name)并确认份量")
        }
        .padding(12)
        .background(.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 8)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(Color(hex: "5F6673"))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: "F3F4F6"))
            .clipShape(Capsule())
    }

    private func emptyActionButton(title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(filled ? .white : Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(filled ? Color(hex: "111318") : .white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "E5E7EB"), lineWidth: filled ? 0 : 1))
        }
        .buttonStyle(.plain)
        .disabled(loading || estimating)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !loading else { return }
        loading = true
        searched = true
        error = ""
        defer { loading = false }
        do {
            results = try await APIClient.shared.searchFoods(query: text)
        } catch {
            results = []
            self.error = friendlySearchError(error, fallback: "现在暂时搜不了，换个关键词，或点“按描述估一份”。")
        }
    }

    private func estimateWithAI() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !estimating else { return }
        estimating = true
        error = ""
        defer { estimating = false }
        do {
            let response = try await APIClient.shared.describeTextMeal(text)
            guard !response.foods.isEmpty else {
                error = response.description ?? "这句没估出来。换成“食物名 + 份量”，比如“米饭一碗”。"
                return
            }
            onEstimated(response)
            onClose()
        } catch {
            self.error = friendlySearchError(error, fallback: "现在暂时估不了，可以换个更简单的描述再试。")
        }
    }

    private func log(_ food: FoodItem) async {
        guard savingId.isEmpty else { return }
        savingId = food.id
        error = ""
        defer { savingId = "" }
        do {
            var datedFood = food
            if !logDate.isEmpty {
                datedFood.date = logDate
            }
            _ = try await APIClient.shared.logFoods([datedFood], mealCategory: mealCategory, groupTitle: datedFood.name, date: logDate)
            onLogged()
            onClose()
        } catch {
            self.error = friendlySearchError(error, fallback: "这项暂时没保存成功，检查网络后再点记录。")
        }
    }

    private func friendlySearchError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnectionFailureMessage(raw) {
            return "现在没连上，这项还没有保存；检查网络后再点记录。"
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "没找到这个名字，换个常见叫法试试。"
        }
        if raw.isEmpty {
            return fallback
        }
        return fallback
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    private static func defaultMealCategory() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 10 { return "breakfast" }
        if hour < 15 { return "lunch" }
        if hour < 21 { return "dinner" }
        return "snack"
    }
}

struct QuickSavedFoodSheetView: View {
    let logDate: String
    let onClose: () -> Void
    let onLogged: (String) -> Void
    let onSearch: () -> Void

    @State private var savedMeals: [SavedMealItem] = []
    @State private var savedFoods: [SavedFoodItem] = []
    @State private var portionMultipliers: [String: Double] = [:]
    @State private var isLoading = true
    @State private var busyId = ""
    @State private var message = ""
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppShellBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        if !message.isEmpty {
                            feedbackCard(message, isError: false)
                        }
                        if !errorMessage.isEmpty {
                            feedbackCard(errorMessage, isError: true)
                        }

                        if isLoading {
                            CalLoadingCard(
                                title: "正在整理常吃内容",
                                subtitle: "收藏和经常记录的食物马上就好",
                                systemImage: "star.fill"
                            )
                        } else if savedMeals.isEmpty && savedFoods.isEmpty {
                            emptyState
                        } else {
                            if !savedMeals.isEmpty {
                                savedMealSection
                            }
                            if !savedFoods.isEmpty {
                                savedFoodSection
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 34)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadSavedContent() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(Color(hex: "DEDEE5"))
                .frame(width: 44, height: 5)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Color(hex: "F59E0B"))
                            .accessibilityHidden(true)
                        Text("常吃与收藏")
                    }
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    Text("选好份量后直接记到今天。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 40, height: 40)
                        .background(.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                }
                .accessibilityLabel("关闭常吃与收藏")
            }
        }
    }

    private var savedMealSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "常吃整餐", subtitle: "一次记下整套餐食")
            VStack(spacing: 0) {
                ForEach(Array(savedMeals.enumerated()), id: \.element.id) { index, meal in
                    savedRow(
                        id: "meal_\(meal.id)",
                        icon: meal.favorite == true ? "star.fill" : "fork.knife",
                        tint: meal.favorite == true ? Color(hex: "F59E0B") : Color(hex: "21B95B"),
                        title: meal.title,
                        subtitle: meal.names.prefix(3).joined(separator: "、"),
                        calories: meal.calories,
                        serving: "\(meal.foods.count)项"
                    ) {
                        await logMeal(meal)
                    }
                    if index < savedMeals.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(.white.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        }
    }

    private var savedFoodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "常吃单品", subtitle: "适合早餐、零食和固定搭配")
            VStack(spacing: 0) {
                ForEach(Array(savedFoods.enumerated()), id: \.element.id) { index, saved in
                    savedRow(
                        id: "food_\(saved.id)",
                        icon: "heart.fill",
                        tint: Color(hex: "FF6B6B"),
                        title: saved.name,
                        subtitle: saved.food.servingSize,
                        calories: saved.food.calories,
                        serving: saved.loggedCount.map { "记过\($0)次" } ?? "已保存"
                    ) {
                        await logFood(saved)
                    }
                    if index < savedFoods.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(.white.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Spacer()
            Text(subtitle)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "9AA0AA"))
        }
        .padding(.horizontal, 2)
    }

    private func savedRow(
        id: String,
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        calories: Double,
        serving: String,
        action: @escaping () async -> Void
    ) -> some View {
        let multiplier = portionMultipliers[id] ?? 1
        return VStack(spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.12))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                    Text(subtitle.isEmpty ? serving : "\(subtitle) · \(serving)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int((calories * multiplier).rounded()))")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(Color(hex: "9AA0AA"))
                }
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { option in
                        Button(portionTitle(option)) {
                            portionMultipliers[id] = option
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "scalemass")
                        Text(portionTitle(multiplier))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .black))
                    }
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color(hex: "F3F4F6"))
                    .clipShape(Capsule())
                }

                Button {
                    Task { await action() }
                } label: {
                    HStack(spacing: 6) {
                        if busyId == id {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text(busyId == id ? "正在记录" : "记到今天")
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!busyId.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "star.circle")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color(hex: "F59E0B"))
            Text("还没有常吃内容")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Text("先搜索并保存一个食物，或在餐食详情里把整餐加入收藏。")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "8E949E"))
                .multilineTextAlignment(.center)
            Button(action: onSearch) {
                Label("去搜索食物", systemImage: "magnifyingglass")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .background(Color(hex: "111318"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .padding(.horizontal, 24)
        .background(.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func feedbackCard(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color(hex: "D93025") : Color(hex: "21B95B"))
            Text(text)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "4B5563"))
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(isError ? Color(hex: "FFF1F0") : Color(hex: "F1FBF5"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func loadSavedContent() async {
        isLoading = true
        errorMessage = ""
        async let favoriteMealsTask = APIClient.shared.getSavedMeals(limit: 30, sort: "frequent", favorite: true)
        async let frequentMealsTask = APIClient.shared.getSavedMeals(limit: 20, sort: "frequent")
        async let foodsTask = APIClient.shared.getSavedFoods(limit: 30, sort: "frequent")

        do {
            let (favorites, frequent, foods) = try await (favoriteMealsTask, frequentMealsTask, foodsTask)
            var seen = Set<String>()
            savedMeals = (favorites + frequent).filter { seen.insert($0.id).inserted }
            savedFoods = foods
        } catch {
            errorMessage = "常吃内容暂时没加载出来，检查网络后再打开一次。"
        }
        isLoading = false
    }

    private func logMeal(_ meal: SavedMealItem) async {
        let id = "meal_\(meal.id)"
        guard busyId.isEmpty else { return }
        busyId = id
        message = ""
        errorMessage = ""
        do {
            let multiplier = portionMultipliers[id] ?? 1
            let response = try await APIClient.shared.logSavedMeal(
                id: meal.id,
                date: logDate,
                portionMultiplier: multiplier
            )
            let count = response.saved ?? meal.foods.count
            message = "已记录 \(meal.title)，共 \(count) 项。"
            onLogged(message)
        } catch {
            errorMessage = "这份常吃餐暂时没记上，内容还在，可以再点一次。"
        }
        busyId = ""
    }

    private func logFood(_ saved: SavedFoodItem) async {
        let id = "food_\(saved.id)"
        guard busyId.isEmpty else { return }
        busyId = id
        message = ""
        errorMessage = ""
        do {
            let multiplier = portionMultipliers[id] ?? 1
            _ = try await APIClient.shared.logSavedFood(
                id: saved.id,
                date: logDate,
                portionMultiplier: multiplier
            )
            message = "已记录 \(saved.name) · \(portionTitle(multiplier))。"
            onLogged(message)
        } catch {
            errorMessage = "这个常吃食物暂时没记上，内容还在，可以再点一次。"
        }
        busyId = ""
    }

    private func portionTitle(_ multiplier: Double) -> String {
        if multiplier == 0.5 { return "半份" }
        if multiplier == 1 { return "1份" }
        if multiplier == 1.5 { return "1.5份" }
        if multiplier == 2 { return "2份" }
        return "\(multiplier)份"
    }
}

private struct SearchPortionConfirmSheet: View {
    let food: FoodItem
    let onConfirm: (FoodItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "grams"
    @State private var grams: Double
    @State private var servings = 1.0

    init(food: FoodItem, onConfirm: @escaping (FoodItem) -> Void) {
        self.food = food
        self.onConfirm = onConfirm
        _grams = State(initialValue: Self.gramsFromServing(food.servingSize))
    }

    private var factor: Double {
        mode == "grams" ? grams / max(1, Self.gramsFromServing(food.servingSize)) : servings
    }

    private var adjustedFood: FoodItem {
        var item = food
        let scale = max(0.01, factor)
        item.calories = food.calories * scale
        item.protein = food.protein * scale
        item.carbs = food.carbs * scale
        item.fat = food.fat * scale
        item.fiber = food.fiber * scale
        item.sugar = food.sugar * scale
        item.sodium = food.sodium * scale
        if mode == "grams" {
            item.servingSize = "\(Int(round(grams)))克"
            item.quantityCount = grams
            item.quantityUnit = "克"
            item.quantityDescription = item.servingSize
            item.gramsPerUnit = 1
        } else {
            let servingText = servings.formatted(.number.precision(.fractionLength(0...1)))
            item.servingSize = "\(servingText)份"
            item.quantityCount = servings
            item.quantityUnit = "份"
            item.quantityDescription = "\(servingText)份（共\(Int(round(Self.gramsFromServing(food.servingSize) * servings)))克）"
            item.gramsPerUnit = Self.gramsFromServing(food.servingSize)
        }
        return item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("确认份量")
                        .font(.system(size: 24, weight: .black))
                    Text(food.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "6D7480"))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "F3F4F6"))
                        .clipShape(Circle())
                }
                .accessibilityLabel("关闭份量选择")
            }

            Picker("份量单位", selection: $mode) {
                Text("按克数").tag("grams")
                Text("按份数").tag("servings")
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                portionStepButton(delta: -1)
                VStack(spacing: 2) {
                    Text(mode == "grams" ? "\(Int(round(grams))) 克" : "\(servings.formatted(.number.precision(.fractionLength(0...1)))) 份")
                        .font(.system(size: 24, weight: .black))
                    Text("约 \(Int(round(adjustedFood.calories))) 千卡")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                portionStepButton(delta: 1)
            }
            .padding(.horizontal, 12)
            .frame(height: 74)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 8) {
                quickPortion("半份", servings: 0.5)
                quickPortion("1份", servings: 1)
                quickPortion("1.5份", servings: 1.5)
            }

            Button {
                onConfirm(adjustedFood)
            } label: {
                Text("确认并记录")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "111318"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(Color.white)
    }

    private func portionStepButton(delta: Double) -> some View {
        Button {
            if mode == "grams" {
                grams = max(1, grams + delta * 10)
            } else {
                servings = max(0.25, servings + delta * 0.25)
            }
        } label: {
            Image(systemName: delta < 0 ? "minus" : "plus")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 42, height: 42)
                .background(.white)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func quickPortion(_ title: String, servings value: Double) -> some View {
        Button {
            mode = "servings"
            servings = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color(hex: "F3F4F6"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private static func gramsFromServing(_ text: String) -> Double {
        let normalized = text.replacingOccurrences(of: "克", with: "g")
        let range = NSRange(normalized.startIndex..., in: normalized)
        if let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*g"#, options: .caseInsensitive),
           let match = regex.matches(in: normalized, range: range).last,
           let valueRange = Range(match.range(at: 1), in: normalized),
           let value = Double(normalized[valueRange]), value > 0 {
            return value
        }
        return 100
    }
}
