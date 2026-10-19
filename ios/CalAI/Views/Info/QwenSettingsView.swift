import SwiftUI

struct QwenSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var savedKey = ""
    @State private var region: QwenRegion = .china
    @State private var consent = false
    @State private var shareRecords = false
    @State private var persistedConsent = false
    @State private var persistedShareRecords = false
    @State private var saving = false
    @State private var message = ""
    @State private var isError = false
    @State private var showDelete = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("图片识别和聊天均使用通义千问", systemImage: "sparkles")
                    Text("填写你自己的阿里云百炼 API Key，费用由你的百炼账户按用量结算。无需部署服务器。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("连接千问") {
                    Picker("Key 所属地域", selection: $region) {
                        ForEach(QwenRegion.allCases) { Text($0.title).tag($0) }
                    }
                    SecureField(savedKey.isEmpty ? "粘贴 API Key" : "已保存，输入新 Key 可更换", text: $keyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("qwen.apiKey")
                    Link("打开百炼控制台", destination: URL(string: "https://bailian.console.aliyun.com/")!)
                    Text("聊天：qwen-plus · 图片：qwen3-vl-plus。请先在所选地域开通模型服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("你决定发送哪些内容") {
                    Toggle("同意将照片和聊天内容发送给千问", isOn: $consent)
                        .accessibilityIdentifier("qwen.consent")
                    Text("识别时发送所选照片及辅助图；聊天时发送你的问题和最近对话；文字记录会发送输入的食物描述或语音转写。接收方为阿里云百炼，可能按其政策留存调用数据；仅在你主动识别、发送或验证时调用。密钥仅保存在本机钥匙串并用于向百炼鉴权。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("聊天时结合我的记录", isOn: $shareRecords)
                    Text("可选：将最近 7 天的饮食、饮水、体重、运动和饮食偏好发送给千问，用于个性化建议。关闭后只发送聊天内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("查看百炼数据隐私说明", destination: URL(string: "https://help.aliyun.com/zh/model-studio/privacy-notice")!)
                    Link("LightCal 隐私政策", destination: URL(string: "https://github.com/het2333/lightcal/blob/main/docs/privacy.md")!)
                }
                Section {
                    Button {
                        saveTask = Task { await verifyAndSave() }
                    } label: {
                        HStack {
                            Text(saving ? "正在验证两个模型…" : "验证并保存")
                            Spacer()
                            if saving { ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("qwen.save")
                    .disabled(saving || !consent || (keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && savedKey.isEmpty))
                    if !savedKey.isEmpty {
                        Button("删除密钥并撤回授权", role: .destructive) { showDelete = true }
                            .accessibilityIdentifier("qwen.delete")
                    }
                    Text("验证会向两个模型各发送一句测试文字，可能产生少量费用。营养和份量为估算，请确认后保存；饮食建议不能替代医疗建议。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(isError ? Color.red : Color.green).accessibilityIdentifier("qwen.feedback") }
                }
            }
            .disabled(saving)
            .navigationTitle("千问设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(saving) } }
            .task { load() }
            .onChange(of: consent) { _, allowed in
                if !allowed { reducePrivacyConsent(revokeAll: true) }
            }
            .onChange(of: shareRecords) { _, allowed in
                if !allowed { reducePrivacyConsent(revokeAll: false) }
            }
            .onDisappear { saveTask?.cancel() }
            .confirmationDialog("删除后，图片识别和聊天需要重新填写密钥。", isPresented: $showDelete, titleVisibility: .visible) {
                Button("删除密钥并撤回授权", role: .destructive) {
                    do {
                        try QwenCredentials.delete()
                        savedKey = ""; keyText = ""; consent = false; shareRecords = false
                        message = "密钥和千问授权已从本机删除。"; isError = false
                    } catch { show(error) }
                }
            }
        }
    }

    private func load() {
        do {
            if let config = try QwenCredentials.load() {
                savedKey = config.apiKey; region = config.region
                consent = config.consentGranted; shareRecords = config.shareNutritionContext
                persistedConsent = consent; persistedShareRecords = shareRecords
            }
        } catch { show(error) }
    }

    private func reducePrivacyConsent(revokeAll: Bool) {
        do {
            guard var config = try QwenCredentials.load() else { return }
            if revokeAll { config.consentGranted = false; shareRecords = false }
            config.shareNutritionContext = false
            try QwenCredentials.save(config)
            persistedConsent = config.consentGranted; persistedShareRecords = config.shareNutritionContext
            message = revokeAll ? "已立即撤回千问授权。重新开启后需验证并保存。" : "已关闭记录发送，之后聊天仅发送对话内容。"
            isError = false
        } catch {
            consent = persistedConsent; shareRecords = persistedShareRecords
            show(error)
        }
    }

    @MainActor private func verifyAndSave() async {
        saving = true; message = ""
        defer { saving = false }
        let clean = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = QwenConfiguration(apiKey: clean.isEmpty ? savedKey : clean, region: region, consentGranted: consent, shareNutritionContext: shareRecords)
        do {
            try await QwenService(configuration: config).verify()
            try Task.checkCancellation()
            try QwenCredentials.save(config)
            savedKey = config.apiKey; keyText = ""
            persistedConsent = config.consentGranted; persistedShareRecords = config.shareNutritionContext
            message = "已验证并安全保存，图片识别和聊天均可使用。"; isError = false
        } catch is CancellationError { }
        catch { show(error) }
    }

    private func show(_ error: Error) { isError = true; message = error.localizedDescription }
}
