import SwiftUI

struct HealthSyncSheetView: View {
    @ObservedObject var service: HealthKitSyncService
    let onClose: () -> Void
    let onSynced: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(Color(hex: "DEDEE5"))
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("补齐今天状态")
                        .font(.system(size: 24, weight: .black))
                    Text("授权后少手填，首页状态会更准。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "F4F5F7"))
                        .clipShape(Circle())
                }
                .accessibilityLabel("关闭健康同步")
            }

            statusCard

            Button {
                Task {
                    await service.syncRecent(days: 7)
                    if case .done = service.state {
                        onSynced()
                    }
                }
            } label: {
                HStack {
                    if isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "heart.text.square.fill")
                            .accessibilityHidden(true)
                    }
                Text(buttonTitle)
                }
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .disabled(isBusy)
            .opacity(isBusy ? 0.68 : 1)

            if !service.preview.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近同步")
                        .font(.system(size: 15, weight: .black))
                    ForEach(Array(service.preview.prefix(5).enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(recordLabel(item.recordType))
                                .font(.system(size: 12, weight: .black))
                            Spacer()
                            Text("\(formatNumber(item.value)) \(item.unit)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(item.date)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

            Text("只使用你允许的数据；步数、睡眠、体重和饮水会读入食光，已保存餐食的营养会同步到苹果健康。")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(22)
        .presentationDetents([.height(520), .large])
        .presentationDragIndicator(.hidden)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(statusColor)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(size: 18, weight: .black))
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                syncTypePill("步数", "figure.walk")
                syncTypePill("睡眠", "moon.fill")
                syncTypePill("体重", "scalemass.fill")
                syncTypePill("饮水", "drop.fill")
                syncTypePill("餐食", "fork.knife")
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 10)
    }

    private func syncTypePill(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var isBusy: Bool {
        if case .authorizing = service.state { return true }
        if case .syncing = service.state { return true }
        return false
    }

    private var buttonTitle: String {
        isBusy ? "正在更新首页" : "补最近7天"
    }

    private var statusIcon: String {
        switch service.state {
        case .done:
            return "checkmark.circle.fill"
        case .failed, .unavailable:
            return "exclamationmark.triangle.fill"
        case .authorizing, .syncing:
            return "arrow.triangle.2.circlepath"
        case .idle:
            return "heart.fill"
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .done:
            return Color(hex: "111318")
        case .failed, .unavailable:
            return Color(hex: "DC2626")
        case .authorizing, .syncing:
            return Color(hex: "159BFF")
        case .idle:
            return Color(hex: "111318")
        }
    }

    private var statusTitle: String {
        switch service.state {
        case .idle:
            return "点一下就能补齐"
        case .unavailable:
            return "暂时不能自动读取"
        case .authorizing:
            return "等你点允许"
        case .syncing:
            return "正在更新首页"
        case .done:
            return "首页已更新"
        case .failed:
            return "这次没同步成"
        }
    }

    private var statusMessage: String {
        switch service.state {
        case .idle:
            return "授权后会把最近数据补进首页，不用一项项手填。"
        case .unavailable(let message):
            return message.isEmpty ? "你仍然可以手动记录睡眠、饮水和运动。" : "\(message) 也可以先手动记录。"
        case .authorizing:
            return "在弹窗里允许读取后，我会继续同步。"
        case .syncing:
            return "正在补最近 7 天，马上回来。"
        case .done(let imported, let skipped):
            return "已更新 \(imported) 条数据，重复的 \(skipped) 条已自动跳过。"
        case .failed(let message):
            return friendlyHealthSyncMessage(message)
        }
    }

    private func friendlyHealthSyncMessage(_ message: String) -> String {
        let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnectionFailureMessage(raw) {
            return "现在没连上，数据还没同步；检查网络后再点同步，或先手动记录。"
        }
        if raw.contains("denied") || raw.contains("not authorized") || raw.contains("未授权") {
            return "还没拿到权限。在系统设置允许后，再回来同步。"
        }
        let lower = raw.lowercased()
        if raw.hasPrefix("{")
            || raw.hasPrefix("[")
            || raw.count > 120
            || raw.contains("失败")
            || raw.contains("错误")
            || raw.contains("异常")
            || raw.contains("无法")
            || lower.contains("json")
            || lower.contains("failed")
            || lower.contains("error")
            || lower.contains("exception")
            || lower.contains("server")
            || lower.contains("api") {
            return "这次没同步成，检查网络后再点同步；也可以先手动记录。"
        }
        return raw.isEmpty ? "这次没同步成，检查网络后再点同步；也可以先手动记录。" : raw
    }

    private func recordLabel(_ type: String) -> String {
        switch type {
        case "steps": return "步数"
        case "sleep_duration": return "睡眠"
        case "weight": return "体重"
        case "dietary_water": return "饮水"
        case "active_energy": return "活动热量"
        default: return "其他健康数据"
        }
    }

    private func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
