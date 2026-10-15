import SwiftUI

struct ManualLogSheetView: View {
    let logDate: String
    let onClose: () -> Void
    let onLogged: () -> Void

    @State private var mealCategory: String
    @State private var form = ManualFoodForm.blank
    @State private var portionReference = ManualFoodForm.blank
    @State private var pendingFoods: [FoodItem] = []
    @State private var recentRows: [FoodLogRow] = []
    @State private var saving = false
    @State private var error = ""
    @State private var showMoreNutrition = false

    private let mealOptions = [
        ("breakfast", "早餐"),
        ("lunch", "午餐"),
        ("dinner", "晚餐"),
        ("snack", "加餐"),
    ]

    private let presets: [ManualFoodPreset] = [
        .init(kind: .egg, name: "鸡蛋", calories: 78, protein: 6, carbs: 1, fat: 5, fiber: 0, sugar: 0, sodium: 62, serving: "1个"),
        .init(kind: .rice, name: "米饭", calories: 210, protein: 4, carbs: 46, fat: 1, fiber: 1, sugar: 0, sodium: 5, serving: "1碗"),
        .init(kind: .chicken, name: "鸡胸肉", calories: 240, protein: 42, carbs: 0, fat: 6, fiber: 0, sugar: 0, sodium: 180, serving: "150g"),
        .init(kind: .banana, name: "香蕉", calories: 105, protein: 1, carbs: 27, fat: 0, fiber: 3, sugar: 14, sodium: 1, serving: "1根"),
        .init(kind: .yogurt, name: "原味酸奶", calories: 120, protein: 10, carbs: 12, fat: 3, fiber: 0, sugar: 8, sodium: 80, serving: "180g"),
        .init(kind: .custom, name: "自定义食物", calories: 300, protein: 15, carbs: 35, fat: 10, fiber: 3, sugar: 4, sodium: 400, serving: "1份"),
    ]

    init(
        logDate: String,
        initialMealCategory: String = "",
        onClose: @escaping () -> Void,
        onLogged: @escaping () -> Void
    ) {
        self.logDate = logDate
        self.onClose = onClose
        self.onLogged = onLogged

        let supportedCategories = ["breakfast", "lunch", "dinner", "snack"]
        let defaultCategory = ManualLogSheetView.defaultMealCategory()
        let category = supportedCategories.contains(initialMealCategory) ? initialMealCategory : defaultCategory
        _mealCategory = State(initialValue: category)
    }

    private var macroTotal: Double {
        max(form.protein + form.carbs + form.fat, 1)
    }

    private var currentFood: FoodItem? {
        makeFood(from: form)
    }

    private var validationMessage: String? {
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nutrition = [
            form.calories, form.protein, form.carbs, form.fat,
            form.fiber, form.sugar, form.sodium,
        ]
        let hasNutritionInput = nutrition.contains { $0 != 0 }
        if name.isEmpty {
            return hasNutritionInput ? "请填写当前食物的名称。" : nil
        }
        if nutrition.contains(where: { !$0.isFinite || $0 < 0 }) {
            return "\(name)的营养数值不能小于 0。"
        }
        return nil
    }

    private var foodsToSave: [FoodItem] {
        pendingFoods + (currentFood.map { [$0] } ?? [])
    }

    private var totalCalories: Double {
        foodsToSave.reduce(0) { $0 + $1.calories }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    grabber
                    header
                    nutritionPreview
                    recentAndCopySection
                    if !pendingFoods.isEmpty {
                        pendingFoodSection
                    }
                    presetGrid
                    mealSelector
                    formCard
                    if let validationMessage {
                        manualErrorCard(validationMessage)
                    } else if !error.isEmpty {
                        manualErrorCard(error)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .background(AppShellBackground())
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 8) {
                        if saving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                        Text(saving ? "正在保存本餐" : "保存本餐（\(foodsToSave.count)项）")
                        Text("约 \(Int(totalCalories.rounded())) 千卡")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(foodsToSave.isEmpty || validationMessage != nil ? Color.gray : Color(hex: "111318"))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .background(.ultraThinMaterial)
                }
                .disabled(saving || foodsToSave.isEmpty || validationMessage != nil)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { await loadRecentFoods() }
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
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                    Text("手动添加食物")
                }
                .font(.system(size: 23, weight: .black))
                Text("可以连续加入多项，最后一次保存为整餐。")
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
            .accessibilityLabel("关闭手动补记")
        }
    }

    private var recentAndCopySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近吃过")
                    .font(.system(size: 14, weight: .black))
                Spacer()
                Button {
                    copyPreviousMeal()
                } label: {
                    Label("复制上一餐", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                }
                .buttonStyle(.plain)
                .disabled(recentRows.isEmpty)
                .opacity(recentRows.isEmpty ? 0.4 : 1)
            }

            if recentRows.isEmpty {
                Text("保存过食物后，会在这里快速复用。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(uniqueRecentRows.prefix(8).enumerated()), id: \.offset) { _, row in
                            Button {
                                applyRecent(row)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.displayName)
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                        .lineLimit(1)
                                    Text("\(Int(round(row.calories ?? 0))) 千卡 · \(row.displayServingSize)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 52)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var pendingFoodSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("本餐已加入")
                    .font(.system(size: 14, weight: .black))
                Spacer()
                Text("\(pendingFoods.count) 项")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(pendingFoods.enumerated()), id: \.element.id) { index, food in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: "21B95B"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(food.name)
                            .font(.system(size: 13, weight: .black))
                        Text("\(food.servingSize) · \(Int(round(food.calories))) 千卡")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        pendingFoods.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(hex: "F3F4F6"))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("移除\(food.name)")
                }
            }
        }
        .padding(14)
        .background(Color(hex: "F1FBF5"))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var nutritionPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(form.serving.isEmpty ? "可先保存" : "\(form.serving) · 可修改")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名食物" : form.name)
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(form.calories.rounded()))")
                        .font(.system(size: 42, weight: .black))
                        .foregroundStyle(.white)
                    Text("千卡")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            HStack(spacing: 10) {
                previewMacro(title: "蛋白", value: form.protein, color: Color(hex: "FF6B6B"))
                previewMacro(title: "碳水", value: form.carbs, color: Color(hex: "F5A63B"))
                previewMacro(title: "脂肪", value: form.fat, color: Color(hex: "159BFF"))
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "73D39B"))
                    .accessibilityHidden(true)
                Text("保存后记到今天，不准还能改。")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: "20252B"), Color(hex: "111318")], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [Color(hex: "73D39B").opacity(0.22), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 22, x: 0, y: 12)
    }

    private func previewMacro(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.56))
            Text("\(Int(value.rounded()))克")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * min(max(value / macroTotal, 0), 1))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最快模板")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("先选最像的")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "9A9AA0"))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(presets) { preset in
                    let active = form.kind == preset.kind
                    Button {
                        let selected = ManualFoodForm.preset(preset.kind)
                        form = selected
                        portionReference = selected
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Image(systemName: presetIcon(preset.kind))
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(active ? .white : Color(hex: "111318"))
                                .frame(width: 30, height: 30)
                                .background(active ? .white.opacity(0.16) : Color(hex: "F7F8FA"))
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                            Text(preset.name)
                                .font(.system(size: 13, weight: .black))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Text("\(Int(preset.calories)) 千卡")
                                .font(.system(size: 11, weight: .bold))
                                .opacity(0.64)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 98)
                        .padding(.horizontal, 10)
                        .background(active ? Color(hex: "111318") : .white.opacity(0.92))
                        .foregroundStyle(active ? .white : Color(hex: "111318"))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(active ? Color(hex: "111318") : Color(hex: "F0F0F3"), lineWidth: 1))
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

    private var mealSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("餐次")
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

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("先记关键项")
                        .font(.system(size: 15, weight: .black))
                    Text("先填食物名和热量，其他可以不动。")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "9AA0AA"))
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showMoreNutrition.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showMoreNutrition ? "chevron.up" : "slider.horizontal.3")
                            .font(.system(size: 11, weight: .black))
                            .accessibilityHidden(true)
                        Text(showMoreNutrition ? "收起" : "更多")
                            .font(.system(size: 12, weight: .black))
                    }
                    .foregroundStyle(Color(hex: "111318"))
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            textField(label: "食物名", text: $form.name)
            textField(label: "份量", text: $form.serving)
            HStack(spacing: 8) {
                portionButton("小份", scale: 0.75)
                portionButton("标准", scale: 1)
                portionButton("大份", scale: 1.5)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                numberField("热量", value: $form.calories, unit: "千卡")
                numberField("蛋白质", value: $form.protein, unit: "克")
                numberField("碳水", value: $form.carbs, unit: "克")
                numberField("脂肪", value: $form.fat, unit: "克")
            }

            if showMoreNutrition {
                VStack(alignment: .leading, spacing: 10) {
                    Text("补充营养")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "8B94A3"))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        numberField("纤维", value: $form.fiber, unit: "克")
                        numberField("糖", value: $form.sugar, unit: "克")
                        numberField("钠", value: $form.sodium, unit: "毫克")
                    }
                }
                .padding(12)
                .background(Color(hex: "F7F8FA").opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showMoreNutrition = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .black))
                            .accessibilityHidden(true)
                        Text("有包装数据？展开纤维、糖、钠")
                            .font(.system(size: 12, weight: .black))
                        Spacer()
                    }
                    .foregroundStyle(Color(hex: "6B7280"))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                addCurrentFoodAndContinue()
            } label: {
                Label("加入本餐，继续添加", systemImage: "plus.circle.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color(hex: "EAF9F0"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(currentFood == nil || validationMessage != nil)
            .opacity(currentFood == nil || validationMessage != nil ? 0.45 : 1)
        }
        .padding(16)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func textField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .font(.system(size: 15, weight: .black))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        }
    }

    private func numberField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField(label, value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 15, weight: .black))
                Text(unit)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private func portionButton(_ title: String, scale: Double) -> some View {
        Button {
            applyPortion(scale)
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

    private func save() async {
        guard !saving else { return }
        saving = true
        error = ""
        defer { saving = false }
        do {
            let foods = foodsToSave
            guard !foods.isEmpty else { return }
            let groupTitle = foods.prefix(3).map(\.name).joined(separator: "、") + (foods.count > 3 ? "等\(foods.count)项" : "")
            _ = try await APIClient.shared.logFoods(foods, mealCategory: mealCategory, groupTitle: groupTitle, date: logDate)
            onLogged()
            onClose()
        } catch {
            self.error = friendlyManualError(error)
        }
    }

    private var uniqueRecentRows: [FoodLogRow] {
        var seen = Set<String>()
        return recentRows.filter { row in
            let key = row.displayName.lowercased()
            return seen.insert(key).inserted
        }
    }

    private func makeFood(from form: ManualFoodForm) -> FoodItem? {
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, validationMessage == nil else { return nil }
        return FoodItem(
            name: name,
            calories: form.calories,
            protein: form.protein,
            carbs: form.carbs,
            fat: form.fat,
            fiber: form.fiber,
            sugar: form.sugar,
            sodium: form.sodium,
            servingSize: form.serving.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1份" : form.serving,
            processingLevel: "whole",
            addedSugar: 0,
            date: logDate.isEmpty ? nil : logDate
        )
    }

    private func foodFromRow(_ row: FoodLogRow) -> FoodItem {
        FoodItem(
            name: row.displayName,
            calories: row.calories ?? 0,
            protein: row.protein ?? 0,
            carbs: row.carbs ?? 0,
            fat: row.fat ?? 0,
            fiber: row.fiber ?? 0,
            sugar: row.sugar ?? 0,
            sodium: row.sodium ?? 0,
            servingSize: row.displayServingSize,
            date: logDate.isEmpty ? nil : logDate
        )
    }

    private func formFromRow(_ row: FoodLogRow) -> ManualFoodForm {
        .init(
            kind: .custom,
            name: row.displayName,
            calories: row.calories ?? 0,
            protein: row.protein ?? 0,
            carbs: row.carbs ?? 0,
            fat: row.fat ?? 0,
            fiber: row.fiber ?? 0,
            sugar: row.sugar ?? 0,
            sodium: row.sodium ?? 0,
            serving: row.displayServingSize
        )
    }

    private func applyRecent(_ row: FoodLogRow) {
        let selected = formFromRow(row)
        form = selected
        portionReference = selected
    }

    private func applyPortion(_ scale: Double) {
        let base = portionReference.name.isEmpty ? form : portionReference
        form.name = base.name
        form.calories = base.calories * scale
        form.protein = base.protein * scale
        form.carbs = base.carbs * scale
        form.fat = base.fat * scale
        form.fiber = base.fiber * scale
        form.sugar = base.sugar * scale
        form.sodium = base.sodium * scale
        let label = scale == 0.75 ? "小份" : scale == 1.5 ? "大份" : "标准份"
        form.serving = label
    }

    private func addCurrentFoodAndContinue() {
        guard let food = currentFood else { return }
        pendingFoods.append(food)
        form = .blank
        portionReference = .blank
        showMoreNutrition = false
    }

    private func copyPreviousMeal() {
        guard let first = recentRows.first else { return }
        let groupId = first.uploadGroupId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rows = groupId.isEmpty
            ? [first]
            : recentRows.filter { ($0.uploadGroupId ?? "") == groupId }
        pendingFoods = rows.map(foodFromRow)
        form = .blank
        portionReference = .blank
    }

    private func loadRecentFoods() async {
        do {
            recentRows = try await APIClient.shared.getFoods(date: logDate, days: 30)
        } catch {
            recentRows = []
        }
    }

    private func manualErrorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "D93025"))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "9B1C1C"))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: "FFF1F0"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func friendlyManualError(_ error: Error) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnectionFailureMessage(raw) {
            return "现在没连上，这项还没保存；你填的内容还在，检查网络后再点保存。"
        }
        if raw.isEmpty || raw.hasPrefix("{") || raw.hasPrefix("[") || raw.count > 120 || raw.lowercased().contains("json") {
            return "这项暂时没保存成功，内容还在，检查网络后再点保存。"
        }
        let lower = raw.lowercased()
        if raw.contains("失败")
            || raw.contains("错误")
            || raw.contains("异常")
            || raw.contains("无法")
            || lower.contains("failed")
            || lower.contains("error")
            || lower.contains("exception")
            || lower.contains("server")
            || lower.contains("api") {
            return "这项暂时没保存成功，内容还在，检查网络后再点保存。"
        }
        return raw
    }

    private func presetIcon(_ kind: ManualFoodKind) -> String {
        switch kind {
        case .egg:
            return "circle.hexagongrid.fill"
        case .rice:
            return "leaf.fill"
        case .chicken:
            return "fork.knife"
        case .banana:
            return "moon.fill"
        case .yogurt:
            return "cup.and.saucer.fill"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    private static func defaultMealCategory() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 10 { return "breakfast" }
        if hour < 15 { return "lunch" }
        if hour < 21 { return "dinner" }
        return "snack"
    }
}

private struct ManualFoodPreset: Identifiable {
    let kind: ManualFoodKind
    let name: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let sugar: Double
    let sodium: Double
    let serving: String
    var id: ManualFoodKind { kind }
}

private enum ManualFoodKind: String {
    case egg
    case rice
    case chicken
    case banana
    case yogurt
    case custom
}

private struct ManualFoodForm {
    var kind: ManualFoodKind
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var sugar: Double
    var sodium: Double
    var serving: String

    static var blank: ManualFoodForm {
        .init(kind: .custom, name: "", calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0, sodium: 0, serving: "1份")
    }

    static func preset(_ kind: ManualFoodKind) -> ManualFoodForm {
        switch kind {
        case .egg:
            return .init(kind: kind, name: "鸡蛋", calories: 78, protein: 6, carbs: 1, fat: 5, fiber: 0, sugar: 0, sodium: 62, serving: "1个")
        case .rice:
            return .init(kind: kind, name: "米饭", calories: 210, protein: 4, carbs: 46, fat: 1, fiber: 1, sugar: 0, sodium: 5, serving: "1碗")
        case .chicken:
            return .init(kind: kind, name: "鸡胸肉", calories: 240, protein: 42, carbs: 0, fat: 6, fiber: 0, sugar: 0, sodium: 180, serving: "150g")
        case .banana:
            return .init(kind: kind, name: "香蕉", calories: 105, protein: 1, carbs: 27, fat: 0, fiber: 3, sugar: 14, sodium: 1, serving: "1根")
        case .yogurt:
            return .init(kind: kind, name: "原味酸奶", calories: 120, protein: 10, carbs: 12, fat: 3, fiber: 0, sugar: 8, sodium: 80, serving: "180g")
        case .custom:
            return .init(kind: kind, name: "自定义食物", calories: 300, protein: 15, carbs: 35, fat: 10, fiber: 3, sugar: 4, sodium: 400, serving: "1份")
        }
    }
}
