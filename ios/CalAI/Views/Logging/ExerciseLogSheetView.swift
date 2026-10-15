import SwiftUI

struct ExerciseLogSheetView: View {
    let logDate: String
    let onClose: () -> Void
    let onLogged: () -> Void

    @State private var catalog: [ExerciseCatalogItem] = []
    @State private var selected: ExerciseCatalogItem?
    @State private var query = ""
    @State private var category = "all"
    @State private var duration = 30
    @State private var intensity = "moderate"
    @State private var customName = ""
    @State private var manualCalories = ""
    @State private var notes = ""
    @State private var estimatedCalories: Double = 0
    @State private var loading = true
    @State private var estimating = false
    @State private var saving = false
    @State private var error = ""

    private let categories = [
        ("all", "全部"),
        ("cardio", "有氧"),
        ("strength", "力量"),
        ("mobility", "拉伸"),
        ("sports", "球类"),
        ("daily", "日常"),
    ]

    private let intensities = [
        ("light", "低强度", "轻松"),
        ("moderate", "中等", "出汗"),
        ("vigorous", "高强度", "吃力"),
    ]

    private var selectedTitle: String {
        effectiveExerciseName
    }

    private var effectiveExerciseName: String {
        if let selected { return selected.name }
        let custom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("自定义运动")
    }

    private var filtered: [ExerciseCatalogItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.filter { item in
            let matchesCategory = category == "all" || item.category == category
            let haystack = ([item.name, item.description ?? ""] + (item.aliases ?? [])).joined(separator: " ").lowercased()
            return matchesCategory && (text.isEmpty || haystack.contains(text))
        }
    }

    private var manualCaloriesValidationMessage: String? {
        let text = manualCalories.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = Double(text), value.isFinite, value > 0 else {
            return "手动消耗必须是大于 0 的数字。"
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    grabber
                    header
                    exerciseHero
                    detailCard
                    searchBox
                    categorySelector
                    if loading {
                        CalLoadingCard(
                            title: "正在准备常用运动",
                            subtitle: "马上可以选择并保存",
                            systemImage: "figure.run"
                        )
                        .padding(.vertical, 8)
                    } else {
                        catalogList
                    }
                    if !error.isEmpty {
                        exerciseErrorCard(error)
                    }
                    if let manualCaloriesValidationMessage {
                        exerciseErrorCard(manualCaloriesValidationMessage)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 104)
            }
            .background(AppShellBackground())
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 10) {
                        if saving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                        Text(saving ? "正在保存运动" : "保存 \(duration) 分钟运动")
                        Text(manualCalories.isEmpty ? "消耗为估算" : "消耗为手动值")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(manualCaloriesValidationMessage == nil ? Color(hex: "111318") : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .background(.ultraThinMaterial)
                }
                .disabled(saving || manualCaloriesValidationMessage != nil)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadCatalog() }
            .onChange(of: selected?.id) { _, _ in Task { await estimate() } }
            .onChange(of: query) { _, newValue in
                let text = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, selected != nil {
                    selected = nil
                    customName = text
                } else if selected == nil {
                    customName = text
                }
            }
            .onChange(of: duration) { _, _ in Task { await estimate() } }
            .onChange(of: intensity) { _, _ in Task { await estimate() } }
            .onChange(of: customName) { _, _ in Task { await estimate() } }
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
                    Image(systemName: "figure.run")
                        .accessibilityHidden(true)
                    Text("记一项运动")
                }
                .font(.system(size: 26, weight: .black))
                Text("先记录时长和强度；消耗热量只作为估算参考。")
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
            .accessibilityLabel("关闭运动记录")
        }
    }

    private var quickEntry: some View {
        HStack(spacing: 10) {
            Button {
                selected = nil
                customName = "自定义运动"
                manualCalories = ""
                estimatedCalories = 0
            } label: {
                quickButton(icon: "square.and.pencil", title: "写运动", subtitle: "知道做了什么", dark: true)
            }
            Button {
                selected = nil
                customName = "手动运动"
                manualCalories = "120"
                estimatedCalories = 120
            } label: {
                quickButton(icon: "flame.fill", title: "只记热量", subtitle: "知道消耗时用", dark: false)
            }
        }
    }

    private var exerciseHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedTitle)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    Text("\(duration)")
                        .font(.system(size: 44, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("分钟 · \(intensityLabel(intensity))")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("≈ \(Int(round(displayCalories)))")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(.white)
                    Text(manualCalories.isEmpty ? "千卡 · 估算" : "千卡 · 手动")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            HStack(spacing: 10) {
                heroChip(title: "时长", value: "\(duration)分钟", icon: "clock.fill")
                heroChip(title: "强度", value: intensityLabel(intensity), icon: "bolt.fill")
                heroChip(title: "消耗", value: manualCalories.isEmpty ? "估算值" : "手动值", icon: "flame.fill")
            }
        }
        .padding(18)
        .background(
            ZStack {
                LinearGradient(
                    colors: [Color(hex: "20252B"), Color(hex: "111318")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                LinearGradient(colors: [Color(hex: "73D39B").opacity(0.24), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: 14)
    }

    private func heroChip(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "73D39B"))
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func quickButton(icon: String, title: String, subtitle: String, dark: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .black))
                Text(subtitle).font(.system(size: 11, weight: .bold)).opacity(0.66)
            }
            Spacer()
        }
        .foregroundStyle(dark ? .white : Color(hex: "111318"))
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(dark ? Color(hex: "111318") : Color.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(dark ? Color(hex: "111318") : Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var searchBox: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索运动", text: $query)
                .font(.system(size: 15, weight: .bold))
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.0) { item in
                    Button {
                        category = item.0
                    } label: {
                        Text(item.1)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(category == item.0 ? .white : Color(hex: "111318"))
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(category == item.0 ? Color(hex: "111318") : .white.opacity(0.92))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var catalogList: some View {
        VStack(spacing: 10) {
            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("直接按这个名称记录")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("先记时长，热量不准也能改。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                    Button {
                        selected = nil
                        customName = query.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("自定义运动")
                        manualCalories = ""
                    } label: {
                        Text("用这个名称记录")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Color(hex: "111318"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(hex: "F8F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            ForEach(filtered.prefix(8)) { item in
                let active = selected?.id == item.id
                Button {
                    selected = item
                    duration = item.suggestedMinutes ?? 30
                    intensity = item.defaultIntensity ?? "moderate"
                    customName = ""
                    manualCalories = ""
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: iconName(for: item))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(active ? .white : Color(hex: "111318"))
                            .frame(width: 46, height: 46)
                            .background(active ? Color(hex: "111318") : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text(item.description ?? "")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(item.suggestedMinutes ?? 30) 分钟")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(active ? Color(hex: "F1FBF5") : Color.white.opacity(0.86))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(active ? Color(hex: "73D39B") : Color(hex: "EEF0F3"), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected?.name ?? customName.ifEmpty("自定义运动"))
                        .font(.system(size: 22, weight: .black))
                    Text(estimating ? "正在估算消耗" : "时长和强度是主要记录")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("≈ \(Int(round(displayCalories)))")
                        .font(.system(size: 28, weight: .black))
                    Text(manualCalories.isEmpty ? "千卡 · 估算" : "千卡 · 手动")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if selected == nil {
                labeledText("名称", text: $customName, placeholder: "例如：腿部训练")
            }

            HStack(spacing: 8) {
                ForEach(intensities, id: \.0) { item in
                    Button {
                        intensity = item.0
                    } label: {
                        VStack(spacing: 2) {
                            Text(item.1)
                                .font(.system(size: 13, weight: .black))
                            Text(item.2)
                                .font(.system(size: 10, weight: .bold))
                                .opacity(0.68)
                        }
                        .foregroundStyle(intensity == item.0 ? .white : Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(intensity == item.0 ? Color(hex: "111318") : Color(hex: "F8F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("时长")
                    .font(.system(size: 13, weight: .black))
                HStack(spacing: 8) {
                    ForEach([10, 15, 30, 45, 60, 90], id: \.self) { value in
                        Button {
                            duration = value
                        } label: {
                            Text("\(value)")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(duration == value ? .white : Color(hex: "111318"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(duration == value ? Color(hex: "111318") : Color(hex: "F8F8FA"))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Stepper("\(duration) 分钟", value: $duration, in: 1...240, step: 5)
                    .font(.system(size: 14, weight: .black))
            }

            Text("热量会根据运动、时长和强度估算，不代表设备实测。")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "8E949E"))
            labeledText("可选：手动填写消耗", text: $manualCalories, placeholder: "不填则使用估算值", keyboard: .decimalPad)
            labeledText("备注", text: $notes, placeholder: "例如：深蹲 5 组")
        }
        .padding(18)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private var displayCalories: Double {
        guard manualCaloriesValidationMessage == nil else { return estimatedCalories }
        return Double(manualCalories) ?? estimatedCalories
    }

    private func labeledText(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(.system(size: 15, weight: .black))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(hex: "F8F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        }
    }

    private func loadCatalog() async {
        loading = true
        do {
            catalog = try await APIClient.shared.getExerciseCatalog()
            selected = catalog.first
            duration = selected?.suggestedMinutes ?? 30
            intensity = selected?.defaultIntensity ?? "moderate"
            await estimate()
        } catch {
            self.error = friendlyExerciseError(
                error,
                fallback: "常用运动暂时没加载出来，可以点“自己写”先记上。",
                connectionFallback: "现在没连上，常用运动暂时没加载出来；你仍可以填写名称、时长和强度，连上后再保存。"
            )
        }
        loading = false
    }

    private func estimate() async {
        let name = effectiveExerciseName
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let manual = Double(manualCalories), manual > 0 {
            estimatedCalories = manual
            return
        }
        estimating = true
        defer { estimating = false }
        do {
            let estimate = try await APIClient.shared.estimateExercise(
                exerciseId: selected?.id,
                name: name,
                durationMinutes: max(1, duration),
                intensity: intensity
            )
            estimatedCalories = estimate.caloriesBurned
        } catch {
            self.error = friendlyExerciseError(
                error,
                fallback: "这次消耗暂时估不出来，你可以手动填一个热量再保存。",
                connectionFallback: "现在没连上，消耗热量暂时估不出来；可以先填时长和强度，或手动填写热量。"
            )
        }
    }

    private func save() async {
        guard !saving else { return }
        if let manualCaloriesValidationMessage {
            error = manualCaloriesValidationMessage
            return
        }
        saving = true
        error = ""
        defer { saving = false }
        do {
            let name = effectiveExerciseName
            let calories = displayCalories
            if calories <= 0 {
                await estimate()
            }
            try await APIClient.shared.addExercise(
                name: name,
                durationMinutes: max(1, duration),
                intensity: intensity,
                caloriesBurned: max(0, displayCalories),
                exerciseId: selected?.id,
                notes: notes,
                date: logDate
            )
            onLogged()
            onClose()
        } catch {
            self.error = friendlyExerciseError(
                error,
                fallback: "这次运动还没保存成功，检查网络后再点保存。",
                connectionFallback: "现在没连上，运动还没有保存；你填的内容还在，检查网络后再点保存。"
            )
        }
    }

    private func exerciseErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "D93025"))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
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

    private func friendlyExerciseError(
        _ error: Error,
        fallback: String,
        connectionFallback: String
    ) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnectionFailureMessage(raw) {
            return connectionFallback
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "这次运动没保存成，可以先手动填写。"
        }
        if raw.contains("失败")
            || raw.contains("错误")
            || raw.contains("异常")
            || raw.contains("无法")
            || raw.lowercased().contains("failed")
            || raw.lowercased().contains("error")
            || raw.lowercased().contains("exception") {
            return fallback
        }
        return raw.isEmpty ? fallback : raw
    }

    private func iconName(for item: ExerciseCatalogItem) -> String {
        switch item.category {
        case "strength": return "dumbbell.fill"
        case "mobility": return "heart.fill"
        case "sports": return "sportscourt.fill"
        case "daily": return "sparkles"
        default:
            if item.id.contains("cycling") { return "bicycle" }
            if item.id.contains("swimming") { return "figure.pool.swim" }
            return "figure.walk"
        }
    }

    private func intensityLabel(_ key: String) -> String {
        intensities.first(where: { $0.0 == key })?.1 ?? "中等"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }
}
