import SwiftUI

struct PreferencesPageView: View {
    let onClose: () -> Void

    private struct PreferencePreset: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let dietType: String
        let budgetLevel: String
        let prepTimeMinutes: Int
        let tastes: [String]
        let cuisines: [String]
        let avoid: [String]
    }

    @State private var prefs = UserPreferences()
    @State private var allergies = ""
    @State private var avoid = ""
    @State private var cuisines = ""
    @State private var tastes = ""
    @State private var loading = true
    @State private var saving = false
    @State private var message = ""

    private let dietTypes = [
        ("balanced", "均衡"),
        ("high_protein", "高蛋白"),
        ("vegetarian", "素食"),
        ("vegan", "纯素"),
    ]
    private let budgets = [
        ("low", "省钱"),
        ("medium", "适中"),
        ("high", "宽松"),
    ]
    private let quickPresets: [PreferencePreset] = [
        PreferencePreset(
            id: "fat_loss_easy",
            title: "减脂少油",
            subtitle: "少油少糖，优先蔬菜和蛋白",
            icon: "leaf.fill",
            dietType: "balanced",
            budgetLevel: "medium",
            prepTimeMinutes: 15,
            tastes: ["清淡", "少油", "少糖", "高蛋白"],
            cuisines: ["中式", "家常", "轻食"],
            avoid: ["油炸", "奶茶", "甜点"]
        ),
        PreferencePreset(
            id: "high_protein_fast",
            title: "高蛋白省事",
            subtitle: "适合健身、忙的时候少纠结",
            icon: "bolt.fill",
            dietType: "high_protein",
            budgetLevel: "medium",
            prepTimeMinutes: 10,
            tastes: ["高蛋白", "饱腹", "少油"],
            cuisines: ["中式", "便利店", "轻食"],
            avoid: ["含糖饮料", "甜点"]
        ),
        PreferencePreset(
            id: "home_light",
            title: "清淡家常",
            subtitle: "更像日常饭，不走极端",
            icon: "house.fill",
            dietType: "balanced",
            budgetLevel: "medium",
            prepTimeMinutes: 25,
            tastes: ["清淡", "家常", "少油"],
            cuisines: ["中式", "家常"],
            avoid: ["重油", "过辣"]
        ),
        PreferencePreset(
            id: "budget",
            title: "预算友好",
            subtitle: "便宜、好买、能长期坚持",
            icon: "yensign.circle.fill",
            dietType: "balanced",
            budgetLevel: "low",
            prepTimeMinutes: 15,
            tastes: ["省钱", "饱腹", "高蛋白"],
            cuisines: ["中式", "便利店", "家常"],
            avoid: ["高价轻食", "奶茶"]
        ),
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if loading {
                            loadingCard
                        } else {
                            preferenceHero
                            quickPresetCard
                            dietCard
                            textFieldsCard
                            budgetCard
                            if !message.isEmpty { messageCard }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 108)
                }
                .background(AppShellBackground())
                saveBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await load() }
        }
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
            .accessibilityLabel("返回")
            VStack(alignment: .leading, spacing: 3) {
                Text("让推荐更合口")
                    .font(.system(size: 24, weight: .black))
                Text("先选一个方向，下一餐少踩雷。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var loadingCard: some View {
        CalLoadingCard(
            title: "正在读取你的口味",
            subtitle: "马上可以修改推荐方向",
            systemImage: "fork.knife"
        )
    }

    private var preferenceHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前推荐方向")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(dietLabel(prefs.dietType))
                        .font(.system(size: 32, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("下一餐建议会优先避开忌口")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Spacer()
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 10) {
                preferenceHeroPill(title: "花费", value: budgetLabel(prefs.budgetLevel))
                preferenceHeroPill(title: "做饭", value: "\(prefs.prepTimeMinutes)分钟")
                preferenceHeroPill(title: "忌口", value: "\(prefs.avoidIngredients.count)项")
            }
        }
        .padding(20)
        .background(
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color(hex: "111318"), Color(hex: "20242B")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(hex: "73D1A3").opacity(0.25))
                    .frame(width: 150, height: 150)
                    .offset(x: 56, y: -70)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 28, x: 0, y: 16)
    }

    private func preferenceHeroPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var quickPresetCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
            Text("先选一个方向")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                    Text("不想细填，点一下就能开始。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8B919B"))
                }
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(quickPresets) { preset in
                    Button {
                        applyPreset(preset)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(width: 30, height: 30)
                                .background(Color(hex: "F1F2F4"))
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.title)
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .lineLimit(1)
                                Text(preset.subtitle)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color(hex: "7B828C"))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.82)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                        .background(Color(hex: "F8F9FB"))
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                }
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private var dietCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("目标吃法")
                .font(.system(size: 15, weight: .black))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(dietTypes, id: \.0) { item in
                    Button {
                        prefs.dietType = item.0
                    } label: {
                        HStack(spacing: 6) {
                            if prefs.dietType == item.0 {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                            Text(item.1)
                        }
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(prefs.dietType == item.0 ? .white : Color(hex: "6B7280"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(prefs.dietType == item.0 ? Color.black : Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private var textFieldsCard: some View {
        VStack(spacing: 14) {
            preferenceField(label: "不能吃", placeholder: "花生，乳糖", text: $allergies)
            preferenceField(label: "不想吃", placeholder: "香菜，猪肉", text: $avoid)
            preferenceField(label: "常吃菜系", placeholder: "中式，日式，轻食", text: $cuisines)
            preferenceField(label: "喜欢口味", placeholder: "清淡，辣，高蛋白", text: $tastes)
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("花费偏好")
                    .font(.system(size: 15, weight: .black))
                HStack(spacing: 8) {
                    ForEach(budgets, id: \.0) { item in
                        Button {
                            prefs.budgetLevel = item.0
                        } label: {
                            Text(item.1)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(prefs.budgetLevel == item.0 ? .white : Color(hex: "6B7280"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(prefs.budgetLevel == item.0 ? Color.black : Color(hex: "F7F8FA"))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("愿意花多久准备")
                        .font(.system(size: 15, weight: .black))
                    Spacer()
                    Text("\(prefs.prepTimeMinutes) 分钟")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(prefs.prepTimeMinutes) },
                    set: { prefs.prepTimeMinutes = Int($0.rounded() / 5) * 5 }
                ), in: 5...60, step: 5)
                .tint(Color.black)
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private var messageCard: some View {
        Text(message)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(hex: "4B5563"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .softCard(radius: 20)
    }

    private var saveBar: some View {
        VStack {
            Button { Task { await save() } } label: {
                HStack(spacing: 8) {
                    if saving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .accessibilityHidden(true)
                    }
                    Text(saving ? "正在保存" : "保存，下次推荐照这个来")
                }
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .disabled(loading || saving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func preferenceField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .black))
            TextField(placeholder, text: text)
                .font(.system(size: 14, weight: .semibold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            prefs = try await APIClient.shared.getUserPreferences()
            syncTextFields()
        } catch {
            syncTextFields()
            message = "暂时读取不到偏好，已先用默认值；你可以直接保存新的。"
        }
    }

    private func save() async {
        saving = true
        message = ""
        prefs.allergies = textToList(allergies)
        prefs.avoidIngredients = textToList(avoid)
        prefs.favoriteCuisines = textToList(cuisines)
        prefs.tasteTags = textToList(tastes)
        do {
            prefs = try await APIClient.shared.saveUserPreferences(prefs)
            syncTextFields()
            message = "已保存。下一餐会按这些偏好来。"
        } catch {
            message = friendlyPreferenceError(error, fallback: "这次偏好还没保存成功，检查网络后再点保存。")
        }
        saving = false
    }

    private func friendlyPreferenceError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnectionFailureMessage(raw) {
            return "现在没连上，偏好还没保存；检查网络后再点保存。"
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "这次偏好没保存成，检查网络后再点保存。"
        }
        return fallback
    }

    private func applyPreset(_ preset: PreferencePreset) {
        prefs.dietType = preset.dietType
        prefs.budgetLevel = preset.budgetLevel
        prefs.prepTimeMinutes = preset.prepTimeMinutes
        prefs.tasteTags = unique(preset.tastes)
        prefs.favoriteCuisines = unique(preset.cuisines)
        prefs.avoidIngredients = unique(preset.avoid + textToList(avoid))
        syncTextFields()
        message = "已套用“\(preset.title)”，不合适的地方可以继续改。"
    }

    private func syncTextFields() {
        allergies = listToText(prefs.allergies)
        avoid = listToText(prefs.avoidIngredients)
        cuisines = listToText(prefs.favoriteCuisines)
        tastes = listToText(prefs.tasteTags)
    }

    private func listToText(_ items: [String]) -> String {
        items.joined(separator: "，")
    }

    private func dietLabel(_ key: String) -> String {
        dietTypes.first(where: { $0.0 == key })?.1 ?? "均衡"
    }

    private func budgetLabel(_ key: String) -> String {
        budgets.first(where: { $0.0 == key })?.1 ?? "适中"
    }

    private func textToList(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: ",", with: "，")
            .split(separator: "，")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for item in items {
            let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !seen.contains(clean) else { continue }
            seen.insert(clean)
            output.append(clean)
        }
        return output
    }
}
