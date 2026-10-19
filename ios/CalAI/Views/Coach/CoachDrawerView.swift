import SwiftUI

struct CoachDrawerView: View {
    let onClose: () -> Void
    let onChanged: () -> Void

    @State private var messages: [CoachMessage] = [
        CoachMessage(
            id: "welcome",
            role: "assistant",
            content: "我是千问饮食助手。你可以问下一餐怎么吃，也可以在千问设置中开启结合本机记录。建议仅供参考，不能替代医疗建议。",
            payload: nil
        )
    ]
    @State private var input = ""
    @State private var showQwenSettings = false
    @State private var loading = false
    @State private var error = ""
    @State private var loggingId = ""
    @State private var applyingId = ""
    @State private var latestTools: [String] = []

    private let prompts = ["晚餐怎么吃不超？", "蛋白还差什么？", "最近7天饮食怎么样？", "最近7天体重和运动怎么样？"]

    private var primaryCoachPrompt: String {
        if latestRecommendations.isEmpty && latestActions.isEmpty {
            return "下一餐怎么吃不超？"
        }
        return "再给我一个更简单的方案"
    }

    private var latestRecommendations: [MealRecommendation] {
        messages.reversed().flatMap { $0.payload?.recommendations ?? [] }.prefix(3).map { $0 }
    }

    private var latestActions: [CoachAction] {
        messages.reversed()
            .flatMap { $0.payload?.actions ?? [] }
            .filter { $0.type != "log_recommendation" }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Button { showQwenSettings = true } label: {
                Label("千问设置 · 使用自己的 API Key", systemImage: "key.fill")
                    .font(.footnote.weight(.semibold)).padding(.vertical, 10)
            }
            .accessibilityIdentifier("coach.qwenSettings")
            coachHero
            promptScroller
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        messageBubble(message)
                    }
                    if loading {
                        loadingBubble
                    }
                    if !error.isEmpty {
                        coachErrorCard(error)
                    }
                    actionSection
                    recommendationSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            composer
        }
        .background(AppShellBackground())
        .sheet(isPresented: $showQwenSettings) { QwenSettingsView() }
    }

    private var coachHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 25, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.14))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("千问饮食助手")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(.white)
                    Text("按你的问题，给出可执行的饮食建议")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    HStack(spacing: 8) {
                        coachHeroPill("通义千问")
                        coachHeroPill(latestTools.isEmpty ? "按对话回答" : "已结合本机记录")
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                Task { await send(primaryCoachPrompt) }
            } label: {
                HStack(spacing: 8) {
                    if loading {
                        ProgressView()
                            .tint(Color(hex: "111318"))
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                            .accessibilityHidden(true)
                    }
                    Text(loading ? "正在选一份稳的" : "帮我选下一餐")
                    Spacer()
                    Text("约几秒")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "111318").opacity(0.52))
                }
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(loading)
        }
        .padding(18)
        .background(
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color(hex: "111318"), Color(hex: "22252C")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(hex: "73D1A3").opacity(0.24))
                    .frame(width: 136, height: 136)
                    .offset(x: 54, y: -70)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func coachHeroPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white.opacity(0.12))
            .clipShape(Capsule())
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "message.circle.fill")
                        .accessibilityHidden(true)
                    Text("饮食教练")
                }
                .font(.system(size: 24, weight: .black))
        Text("不确定吃什么时，先问一句。")
                    .font(.system(size: 13, weight: .bold))
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
            .accessibilityLabel("关闭饮食教练")
        }
        .padding(.horizontal, 22)
        .padding(.top, 54)
        .padding(.bottom, 12)
    }

    private var promptScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        Task { await send(prompt) }
                    } label: {
                        Text(prompt)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "111318"))
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(.white)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 6)
                    }
                    .disabled(loading)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private func messageBubble(_ message: CoachMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 42) }
            Text(message.content)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(message.role == "user" ? .white : Color(hex: "374151"))
                .lineSpacing(2)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(message.role == "user" ? Color.black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(message.role == "user" ? Color.clear : Color(hex: "F0F0F3"), lineWidth: 1)
                )
            if message.role != "user" { Spacer(minLength: 42) }
        }
    }

    private var loadingBubble: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在看今天记录，马上给你下一步")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer()
        }
    }

    private var actionSection: some View {
        Group {
            if !latestActions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("一键补救", systemImage: "checkmark.circle")
                        .font(.system(size: 15, weight: .black))
                    ForEach(latestActions, id: \.stableId) { action in
                        Button {
                            Task { await apply(action) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(action.label)
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(Color(hex: "111318"))
                                    if let description = action.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if applyingId == action.stableId {
                                    ProgressView()
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: "111318"))
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(14)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!applyingId.isEmpty)
                    }
                }
            }
        }
    }

    private var recommendationSection: some View {
        Group {
            if !latestRecommendations.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("能直接记录的餐", systemImage: "chef.hat")
                        .font(.system(size: 15, weight: .black))
                    ForEach(latestRecommendations) { rec in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                Image(systemName: "fork.knife")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .frame(width: 34, height: 34)
                                    .background(Color(hex: "F7F8FA"))
                                    .clipShape(Circle())
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rec.title)
                                        .font(.system(size: 15, weight: .black))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.78)
                                    Text("蛋白 \(Int(round(rec.protein)))克 · 碳水 \(Int(round(rec.carbs)))克 · 脂肪 \(Int(round(rec.fat)))克")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text("\(Int(round(rec.calories)))")
                                        .font(.system(size: 20, weight: .black))
                                    Text("千卡")
                                        .font(.system(size: 10, weight: .black))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                Task { await log(rec) }
                            } label: {
                                Text(loggingId == rec.id ? "正在保存" : "保存到今天")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(Color.black)
                                    .clipShape(Capsule())
                            }
                            .disabled(loggingId == rec.id)
                        }
                        .padding(12)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 8)
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("比如：晚餐吃什么不超", text: $input)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            Button {
                Task { await send(input) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black)
                    .clipShape(Circle())
            }
            .accessibilityLabel("发送问题")
            .disabled(loading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(loading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(.white.opacity(0.72))
    }

    private func send(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !loading else { return }
        input = ""
        error = ""
        messages.append(CoachMessage(id: UUID().uuidString, role: "user", content: clean, payload: nil))
        loading = true
        defer { loading = false }
        do {
            let response = try await APIClient.shared.chatCoach(message: clean, history: Array(messages.dropLast()))
            latestTools = response.toolsUsed ?? []
            if let serverMessages = response.messages, !serverMessages.isEmpty {
                messages = serverMessages
            } else {
                messages.append(
                    CoachMessage(
                        id: UUID().uuidString,
                        role: "assistant",
                        content: response.reply ?? "我结合今天的数据给你整理好了建议。",
                        payload: CoachMessagePayload(
                            recommendations: response.recommendations,
                            actions: response.actions
                        )
                    )
                )
            }
        } catch {
            self.error = friendlyCoachError(error, fallback: "现在暂时答不了，可以稍后再问一次。")
        }
    }

    private func apply(_ action: CoachAction) async {
        guard applyingId.isEmpty else { return }
        applyingId = action.stableId
        error = ""
        defer { applyingId = "" }
        do {
            let response = try await APIClient.shared.applyCoachAction(action)
            messages.append(CoachMessage(id: UUID().uuidString, role: "assistant", content: response.message ?? "已帮你改好。", payload: nil))
            onChanged()
        } catch {
            self.error = friendlyCoachError(error, fallback: "这次还没改成功，检查网络后再点应用。")
        }
    }

    private func log(_ rec: MealRecommendation) async {
        guard loggingId.isEmpty else { return }
        loggingId = rec.id
        error = ""
        defer { loggingId = "" }
        do {
            let response = try await APIClient.shared.logRecommendation(id: rec.id, portionMultiplier: 1, mealCategory: rec.mealType)
            let content = response.alreadyLogged == true ? "这餐已经记录过了。" : "\(rec.title) 已记录到今天。"
            messages.append(CoachMessage(id: UUID().uuidString, role: "assistant", content: content, payload: nil))
            onChanged()
        } catch {
            self.error = friendlyCoachError(error, fallback: "这餐还没记录成功，检查网络后再点记录。")
        }
    }

    private func coachErrorCard(_ message: String) -> some View {
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

    private func friendlyCoachError(_ error: Error, fallback: String) -> String {
        if let qwenError = error as? QwenError { return qwenError.localizedDescription }
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = raw.lowercased()
        if isConnectionFailureMessage(raw) {
            return "现在没连上，建议还没生成；检查网络后再问。"
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "问题再短一点会更稳，比如“晚餐吃什么”。"
        }
        if raw.hasPrefix("{")
            || raw.hasPrefix("[")
            || raw.count > 140
            || lowercased.contains("http")
            || lowercased.contains("json")
            || lowercased.contains("traceback")
            || lowercased.contains("internal server")
            || lowercased.contains("endpoint")
            || lowercased.contains("api")
            || lowercased.contains("failed")
            || lowercased.contains("error")
            || lowercased.contains("exception")
            || raw.contains("失败")
            || raw.contains("错误")
            || raw.contains("异常")
            || raw.contains("无法") {
            return fallback
        }
        return raw.isEmpty ? fallback : raw
    }
}
