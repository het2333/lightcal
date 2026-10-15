import SwiftUI

struct SleepLogSheetView: View {
    let summary: SleepSummary
    let logDate: String
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var durationHours = 7.5
    @State private var quality = 4
    @State private var note = ""
    @State private var saving = false
    @State private var loadingLogs = false
    @State private var logs: [SleepLog] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppShellBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        grabber
                        header
                        sleepHero

                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                            Text("睡眠时长")
                                    .font(.system(size: 15, weight: .black))
                                Spacer()
                                Text(formatHours(durationHours))
                                    .font(.system(size: 21, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                            }
                            Slider(value: $durationHours, in: 0...12, step: 0.25)
                                .tint(Color(hex: "111318"))
                            HStack {
                                ForEach([6, 7, 7.5, 8, 9], id: \.self) { value in
                                    Button {
                                        durationHours = value
                                    } label: {
                                        Text(formatHours(value))
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundStyle(durationHours == value ? .white : Color(hex: "6D7480"))
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 34)
                                            .background(durationHours == value ? Color(hex: "111318") : Color(hex: "F7F8FA"))
                                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    }
                                }
                            }
                        }
                        .softCard(radius: 24)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("睡眠质量")
                                    .font(.system(size: 15, weight: .black))
                                Spacer()
                                Text("\(quality)/5")
                                    .font(.system(size: 15, weight: .black))
                            }
                            HStack(spacing: 8) {
                                ForEach(1...5, id: \.self) { value in
                                    Button {
                                        quality = value
                                    } label: {
                                        Text("\(value)")
                                            .font(.system(size: 15, weight: .black))
                                            .foregroundStyle(quality == value ? .white : Color(hex: "6D7480"))
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 44)
                                            .background(quality == value ? Color(hex: "111318") : Color(hex: "F7F8FA"))
                                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                }
                            }
                        }
                        .softCard(radius: 24)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("备注")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(Color(hex: "6D7480"))
                            TextField("例如：半夜醒了一次", text: $note, axis: .vertical)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(3, reservesSpace: true)
                                .padding(14)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                        }

                        sleepLogsCard

                        if let errorMessage {
                            sleepErrorCard(errorMessage)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 104)
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveButton
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task { await loadLogs() }
        .onAppear {
            durationHours = summary.durationHours > 0 ? summary.durationHours : 7.5
            quality = summary.quality > 0 ? summary.quality : 4
        }
    }

    private var sleepHero: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(.white.opacity(0.14))
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("补昨晚睡眠")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white.opacity(0.58))
                Text(formatHours(durationHours))
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("质量 \(quality)/5 · 目标 \(formatHours(summary.goalHours))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text("保存后更新今日状态分")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer()
        }
        .padding(18)
        .background(
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color(hex: "111318"), Color(hex: "23262D")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(hex: "7B7CFF").opacity(0.26))
                    .frame(width: 140, height: 140)
                    .offset(x: 58, y: -70)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: 14)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color(hex: "DEDEE5"))
            .frame(width: 44, height: 5)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill")
                        .accessibilityHidden(true)
                    Text("记昨晚睡眠")
                }
                .font(.system(size: 25, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                Text(summary.logsCount > 0 ? "已记录 \(formatHours(summary.durationHours))，还可以微调。" : "不知道准确时间也没关系，先选个大概。")
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
            .accessibilityLabel("关闭睡眠记录")
        }
    }

    private var saveButton: some View {
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
                Text(saving ? "正在更新今天" : "记入今天状态")
                Text(formatHours(durationHours))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .font(.system(size: 16, weight: .black))
            .foregroundStyle(.white)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(durationHours <= 0 ? Color.gray : Color(hex: "111318"))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
        .disabled(saving || durationHours <= 0)
    }

    private var sleepLogsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今天状态里的睡眠")
                        .font(.system(size: 16, weight: .black))
                    Text(logs.isEmpty ? "保存后这里会显示" : "已记录 \(logs.count) 条")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if loadingLogs {
                    ProgressView()
                        .tint(Color(hex: "111318"))
                } else {
                    Button {
                        Task { await loadLogs() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 30, height: 30)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("刷新睡眠记录")
                }
            }
            if logs.isEmpty {
                Text("先按上面的时长保存一条睡眠。")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(logs.prefix(5)) { item in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: item.source == "healthkit" ? "heart.text.square.fill" : "moon.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(width: 34, height: 34)
                            .background(Color(hex: "F7F8FA"))
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(formatHours(item.durationHours)) · 质量 \(item.quality)/5")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text(item.note.isEmpty ? sourceLabel(item.source) : item.note)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(16)
        .softCard(radius: 22)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        do {
            _ = try await APIClient.shared.addSleep(durationHours: durationHours, quality: quality, note: note, date: logDate)
            await loadLogs()
            onSaved()
            onClose()
        } catch {
            errorMessage = friendlySleepError(error, fallback: "这条睡眠暂时没保存成功，检查网络后再点保存。")
        }
        saving = false
    }

    private func loadLogs() async {
        loadingLogs = true
        do {
            logs = try await APIClient.shared.getSleep(date: logDate)
        } catch {
            if errorMessage == nil {
                errorMessage = friendlySleepError(error, fallback: "睡眠明细暂时没加载出来，不影响你先保存。")
            }
        }
        loadingLogs = false
    }

    private func sleepErrorCard(_ message: String) -> some View {
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

    private func friendlySleepError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnectionFailureMessage(raw) {
            return "现在没连上，睡眠还没有保存；你选的时长还在，检查网络后再点保存。"
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "这次睡眠没保存成，检查网络后再点保存。"
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

    private func formatHours(_ hours: Double) -> String {
        let rounded = (hours * 10).rounded() / 10
        return rounded.rounded() == rounded ? "\(Int(rounded))小时" : String(format: "%.1f小时", rounded)
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "healthkit": return "来自苹果健康"
        case "ios_swiftui": return "来自手机手动记录"
        case "manual": return "手动记录"
        default: return "同步记录"
        }
    }
}
