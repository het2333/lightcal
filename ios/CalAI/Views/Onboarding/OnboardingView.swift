import SwiftUI

struct OnboardingView: View {
    var onClose: (() -> Void)?

    @State private var step = 0
    @State private var goal = "lose"
    @State private var gender = "male"
    @State private var weight = "70"
    @State private var height = "170"
    @State private var age = "30"
    @State private var goalWeight = "65"
    @State private var activity = "moderate"
    @State private var dietType = "balanced"
    @State private var avoidIngredients = ""
    @State private var favoriteCuisines = "中式，家常"
    @State private var prepTime = 20.0
    @State private var plan: PlanPreview?
    @State private var loading = true
    @State private var saving = false
    @State private var error = ""
    @State private var formNotice = ""
    @AppStorage("cal_height") private var savedHeight = ""
    @AppStorage("cal_gender") private var savedGender = ""
    @AppStorage("cal_age") private var savedAge = ""
    @AppStorage("onboarded") private var onboarded = false

    private let activities = [
        ("sedentary", "久坐", "几乎不运动"),
        ("light", "轻度", "每周 1-3 天"),
        ("moderate", "中度", "每周 3-5 天"),
        ("active", "活跃", "每周 6-7 天"),
        ("very_active", "高强度", "每日训练"),
    ]

    private let dietOptions = [
        ("balanced", "均衡"),
        ("high_protein", "高蛋白"),
        ("vegetarian", "素食"),
        ("vegan", "纯素"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if loading {
                Spacer()
                CalLoadingCard(
                    title: "正在准备今日目标",
                    subtitle: "准备好后，先拍第一餐就能看到热量和下一步。",
                    systemImage: "target"
                )
                .padding(.horizontal, 22)
                Spacer()
            } else {
                TabView(selection: $step) {
                    goalStep.tag(0)
                    bodyStep.tag(1)
                    summaryStep.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                bottomButtons
            }
        }
        .background(AppShellBackground())
        .task { await loadExisting() }
        .alert("目标还没保存上", isPresented: Binding(
            get: { !error.isEmpty },
            set: { if !$0 { error = "" } }
        )) {
            Button("重新保存") {
                error = ""
                Task { await finishOnboarding() }
            }
            Button("回去检查", role: .cancel) { error = "" }
        } message: {
            Text(error)
        }
    }

    private var topBar: some View {
        HStack {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 40, height: 40)
                        .background(.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.gray.opacity(0.16), lineWidth: 1))
                }
            } else {
                Spacer().frame(width: 40)
            }
            Spacer()
            VStack(spacing: 5) {
                Text("\(step + 1)/3  \(["目标", "身体数据", "计划结果"][step])")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "6D7480"))
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i <= step ? Color.black : Color.gray.opacity(0.2))
                            .frame(width: i <= step ? 24 : 8, height: 4)
                    }
                }
            }
            Spacer()
            Spacer().frame(width: 40)
        }
        .padding(.horizontal)
        .padding(.top, 54)
        .padding(.bottom, 8)
    }

    private var goalStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                onboardingHeader(
                    title: "先告诉我想怎么吃",
                    subtitle: "选一个方向，我先帮你算今天该吃多少，之后都能改。",
                    icon: "target",
                    accent: Color(hex: "111318")
                )
                goalButton(id: "lose", title: "减重", desc: "少想一点，先控制热量")
                goalButton(id: "maintain", title: "维持体重", desc: "保持稳定，重点记录饮食")
                goalButton(id: "gain", title: "增重", desc: "提高热量和蛋白，辅助增肌")
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
    }

    private var bodyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                onboardingHeader(
                    title: "用来估算每日目标",
                    subtitle: "填大概数就行，后面可以在「我的」里修改。",
                    icon: "scalemass.fill",
                    accent: Color(hex: "159BFF")
                )
                HStack(spacing: 10) {
                    segmentButton(id: "male", label: "男性", value: $gender)
                    segmentButton(id: "female", label: "女性", value: $gender)
                }
                InputRow(label: "身高", unit: "厘米", text: $height)
                InputRow(label: "体重", unit: "公斤", text: $weight)
                InputRow(label: "年龄", unit: "岁", text: $age)
                InputRow(label: "目标体重", unit: "公斤", text: $goalWeight)
                Menu {
                    ForEach(activities, id: \.0) { item in
                        Button {
                            activity = item.0
                        } label: {
                            Label("\(item.1) · \(item.2)", systemImage: activity == item.0 ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(hex: "21B95B"))
                            .frame(width: 40, height: 40)
                            .background(Color(hex: "EAF9F0"))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("日常活动量")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.secondary)
                            if let selected = activities.first(where: { $0.0 == activity }) {
                                Text("\(selected.1) · \(selected.2)")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.18), lineWidth: 1))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
    }

    private var summaryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                onboardingHeader(
                    title: "先拍第一餐就行",
                    subtitle: "目标已准备好，拍餐后会自动更新热量、蛋白和状态分。",
                    icon: "checkmark.seal.fill",
                    accent: Color(hex: "111318")
                )
                if let p = plan {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .bottom, spacing: 8) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(goalLabel)
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(.white.opacity(0.65))
                                Text("\(Int(p.target))")
                                    .font(.system(size: 46, weight: .black))
                                    .foregroundStyle(.white)
                            }
                            Text("千卡/天")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(.white.opacity(0.62))
                                .padding(.bottom, 10)
                            Spacer()
                            Image(systemName: "flame.fill")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(Color(hex: "73D39B"))
                                .frame(width: 54, height: 54)
                                .background(Color.white.opacity(0.10))
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                        }
                        VStack(spacing: 0) {
                            PlanRow(label: "基础代谢", value: "\(Int(p.bmr)) 千卡")
                            PlanRow(label: "每日总消耗", value: "\(Int(p.tdee)) 千卡")
                            PlanRow(label: "每周变化", value: "\(String(format: "%.1f", p.weekly)) 公斤")
                            PlanRow(label: "每日饮水", value: "\(Int(p.water)) 毫升")
                        }
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(18)
                    .background(
                        LinearGradient(colors: [Color(hex: "20252B"), Color(hex: "111318")], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 14)
                }
                Text("健康数据暂不授权。首次使用体重、步数或睡眠同步时再说明用途。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "7C8492"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
    }

    private var preferenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
                    Text("常吃和忌口")
                .font(.system(size: 16, weight: .black))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(dietOptions, id: \.0) { item in
                    Button {
                        dietType = item.0
                    } label: {
                        Text(item.1)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(dietType == item.0 ? .white : Color(hex: "555A62"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(dietType == item.0 ? Color.black : Color(hex: "F4F5F7"))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            OnboardingTextField(label: "忌口", placeholder: "如 香菜，猪肉", text: $avoidIngredients)
            OnboardingTextField(label: "常吃菜系", placeholder: "中式，家常", text: $favoriteCuisines)
            VStack(alignment: .leading, spacing: 6) {
                Text("最多愿意花 \(Int(prepTime)) 分钟做饭")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                Slider(value: $prepTime, in: 5...60, step: 5)
                    .tint(Color.black)
            }
        }
        .padding()
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.gray.opacity(0.12), lineWidth: 1))
    }

    private func onboardingHeader(title: String, subtitle: String, icon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("食光设置")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "8B94A3"))
                    Text(title)
                        .font(.system(size: 32, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(accent)
                    .frame(width: 58, height: 58)
                    .background(Color.white)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 10)
                    .accessibilityHidden(true)
            }
            Text(subtitle)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "7C8492"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(
            LinearGradient(colors: [.white.opacity(0.96), Color(hex: "F7F8FA").opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.055), radius: 20, x: 0, y: 10)
    }

    private var bottomButtons: some View {
        VStack(spacing: 8) {
            if !formNotice.isEmpty {
                Text(formNotice)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "9B1C1C"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(hex: "FFF1F0"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button(action: nextStep) {
                HStack(spacing: 8) {
                    if saving {
                        ProgressView().tint(.white)
                    }
                    Text(primaryButtonTitle)
                }
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(hex: "111318"))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .disabled(saving)
            if step == 0 {
                Button {
                    useRecommendedSetup()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .black))
                        Text("用推荐设置开始")
                    }
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "E9EBEF"), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
            if step > 0 {
                Button("返回修改") {
                    withAnimation { step -= 1 }
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .disabled(saving)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 10)
        .background(.ultraThinMaterial)
    }

    private var primaryButtonTitle: String {
        if saving { return "正在保存目标" }
        switch step {
        case 0:
            return "下一步：身体数据"
        case 1:
            return "生成计划结果"
        default:
            return "开始记录第一餐"
        }
    }

    private var goalLabel: String {
        switch goal {
        case "gain": return "增重"
        case "maintain": return "维持"
        default: return "减重"
        }
    }

    private func goalButton(id: String, title: String, desc: String) -> some View {
        Button {
            goal = id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 18, weight: .black))
                    Text(desc)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if goal == id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.black)
                }
            }
            .padding(18)
            .background(goal == id ? Color(hex: "F1FBF5") : .white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(goal == id ? Color(hex: "73D39B") : Color.gray.opacity(0.18), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func segmentButton(id: String, label: String, value: Binding<String>) -> some View {
        Button {
            value.wrappedValue = id
        } label: {
            Text(label)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(value.wrappedValue == id ? .white : Color(hex: "555A62"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(value.wrappedValue == id ? Color.black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func nextStep() {
        formNotice = ""
        if step == 1 {
            guard validateBodyInputs() else {
                return
            }
            calculatePlan()
        }
        if step == 2 {
            Task { await finishOnboarding() }
            return
        }
        withAnimation { step += 1 }
    }

    private func useRecommendedSetup() {
        formNotice = ""
        if height.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { height = "170" }
        if weight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { weight = "70" }
        if age.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { age = "30" }
        if favoriteCuisines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            favoriteCuisines = "中式，家常"
        }
        if avoidIngredients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            avoidIngredients = "油炸，奶茶，甜点"
        }
        activity = "moderate"
        dietType = goal == "gain" ? "high_protein" : "balanced"
        prepTime = 20

        let currentWeight = Double(weight) ?? 70
        switch goal {
        case "gain":
            goalWeight = formatNumber(currentWeight + 3)
        case "maintain":
            goalWeight = formatNumber(currentWeight)
        default:
            goalWeight = formatNumber(max(35, currentWeight - 5))
        }
        calculatePlan()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            step = 2
        }
    }

    private func calculatePlan() {
        let w = Double(weight) ?? 70
        let h = Double(height) ?? 170
        let a = Int(age) ?? 30
        let bmr = 10 * w + 6.25 * h - 5 * Double(a) + (gender == "female" ? -161 : 5)
        let actM: [String: Double] = ["sedentary": 1.2, "light": 1.375, "moderate": 1.55, "active": 1.725, "very_active": 1.9]
        let tdee = bmr * (actM[activity] ?? 1.55)
        let defPct = goal == "lose" ? 0.15 : goal == "gain" ? -0.10 : 0.0
        let target = tdee * (1 - defPct)
        let weekly = abs((tdee - target) * 7 / 7700)
        plan = PlanPreview(bmr: bmr, tdee: tdee, target: target, weekly: weekly, water: w * 30)
    }

    private func validateBodyInputs() -> Bool {
        guard let h = Double(height), let w = Double(weight), let a = Int(age), let target = Double(goalWeight) else {
            formNotice = "身高、体重、年龄和目标体重先填数字。"
            return false
        }
        guard (100...250).contains(h) else {
            formNotice = "身高请填写 100–250 厘米。"
            return false
        }
        guard (25...350).contains(w) else {
            formNotice = "体重请填写 25–350 公斤。"
            return false
        }
        guard (13...120).contains(a) else {
            formNotice = "年龄请填写 13–120 岁。"
            return false
        }
        guard (25...350).contains(target) else {
            formNotice = "目标体重请填写 25–350 公斤。"
            return false
        }
        return true
    }

    private func finishOnboarding() async {
        guard !saving else { return }
        formNotice = ""
        guard validateBodyInputs() else {
            withAnimation { step = 1 }
            return
        }
        saving = true
        error = ""
        defer { saving = false }
        calculatePlan()

        let currentWeight = Double(weight) ?? 70
        let targetWeight = Double(goalWeight) ?? currentWeight
        let targetCalories = plan?.target ?? 2000
        let macros = MacroGoals(
            dailyCalories: targetCalories,
            proteinG: round(currentWeight * 1.6),
            carbsG: round(targetCalories * 0.4 / 4),
            fatG: round(targetCalories * 0.3 / 9),
            fiberG: 25,
            sugarG: 50,
            sodiumMg: 2300,
            waterMl: plan?.water ?? round(currentWeight * 30)
        )
        let preferences = UserPreferences(
            dietType: dietType,
            allergies: [],
            avoidIngredients: textToList(avoidIngredients),
            favoriteCuisines: textToList(favoriteCuisines).isEmpty ? ["中式", "家常"] : textToList(favoriteCuisines),
            budgetLevel: "medium",
            prepTimeMinutes: Int(prepTime),
            tasteTags: dietType == "high_protein" ? ["高蛋白"] : ["清淡"]
        )

        do {
            try await APIClient.shared.saveGoalPlan(
                GoalPlanRequest(
                    currentWeightKg: currentWeight,
                    goalWeightKg: targetWeight,
                    heightCm: Double(height) ?? 170,
                    age: Int(age) ?? 30,
                    gender: gender,
                    activity: activity,
                    deficitPct: goal == "lose" ? 15 : goal == "gain" ? -10 : 0
                )
            )
            try await APIClient.shared.saveMacroGoals(macros)
            _ = try await APIClient.shared.saveUserPreferences(preferences)
            try await APIClient.shared.addWeight(kg: currentWeight)

            savedHeight = height
            savedGender = gender
            savedAge = age
            onboarded = true
            onClose?()
        } catch {
            self.error = onboardingFriendlyError(error)
        }
    }

    private func loadExisting() async {
        if !savedHeight.isEmpty { height = savedHeight }
        if !savedAge.isEmpty { age = savedAge }
        if !savedGender.isEmpty { gender = savedGender }
        defer {
            calculatePlan()
            loading = false
        }

        do {
            guard let existing = try await APIClient.shared.getGoalPlan() else { return }
            if let current = existing.currentWeightKg { weight = formatNumber(current) }
            if let target = existing.goalWeightKg { goalWeight = formatNumber(target) }
            if let direction = existing.direction, ["lose", "maintain", "gain"].contains(direction) {
                goal = direction
            }
            if let activityLevel = existing.activityLevel, activities.contains(where: { $0.0 == activityLevel }) {
                activity = activityLevel
            }
        } catch {
            // First run has no goal-plan yet.
        }

        do {
            let preferences = try await APIClient.shared.getUserPreferences()
            dietType = preferences.dietType
            avoidIngredients = preferences.avoidIngredients.joined(separator: "，")
            favoriteCuisines = preferences.favoriteCuisines.joined(separator: "，")
            prepTime = Double(preferences.prepTimeMinutes)
        } catch {
            // Preferences are optional during onboarding.
        }
    }

    private func textToList(_ text: String) -> [String] {
        text.replacingOccurrences(of: ",", with: "，")
            .split(separator: "，")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

private struct PlanPreview {
    let bmr: Double
    let tdee: Double
    let target: Double
    let weekly: Double
    let water: Double
}

struct InputRow: View {
    let label: String
    let unit: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            TextField(label, text: $text)
                .keyboardType(.decimalPad)
                .font(.system(size: 20, weight: .black))
                .multilineTextAlignment(.center)
            Text(unit)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding()
        .background(.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "EEF0F3"), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 6)
    }
}

private func onboardingFriendlyError(_ error: Error) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
            return "目标还没保存上，检查网络后再点重新保存。"
    }
    let lowercased = raw.lowercased()
    if lowercased.contains("could not connect")
        || lowercased.contains("connection")
        || lowercased.contains("timed out")
        || raw.contains("连接不到")
        || raw.contains("无法连接")
        || raw.contains("网络") {
        return "现在没连上，目标还没保存；连上后再点重新保存。"
    }
    if raw.hasPrefix("{") || raw.hasPrefix("[") || raw.count > 120 || lowercased.contains("json") {
        return "目标还没保存上，检查网络后再点重新保存。"
    }
    if raw.contains("失败")
        || raw.contains("错误")
        || raw.contains("异常")
        || raw.contains("无法")
        || lowercased.contains("failed")
        || lowercased.contains("error")
        || lowercased.contains("exception")
        || lowercased.contains("server")
        || lowercased.contains("api") {
        return "目标还没保存上，检查网络后再点重新保存。"
    }
    return raw
}

private struct OnboardingTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}

struct PlanRow: View {
    let label: String
    let value: String
    var highlight = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: highlight ? .black : .bold))
                .foregroundStyle(highlight ? Color(hex: "73D39B") : .white.opacity(0.92))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Divider().background(Color.white.opacity(0.10)), alignment: .bottom)
    }
}
