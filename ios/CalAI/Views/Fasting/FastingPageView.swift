import SwiftUI
import UserNotifications

struct FastingPageView: View {
    let onBack: () -> Void
    let onStatusChanged: () -> Void

    private static var cachedStatus: FastingStatus?
    private static var cachedHistory: FastingHistory?
    private static var cachedPrefs: FastingPreferences?
    private static var cachedBreakFastRecommendations: [MealRecommendation] = []
    private static var lastLoadedAt: Date?
    private static var lastHistoryLoadedAt: Date?
    private static var lastRecommendationsLoadedAt: Date?
    private static let cacheFreshSeconds: TimeInterval = 30

    @State private var status: FastingStatus?
    @State private var history: FastingHistory?
    @State private var prefs = FastingPreferences()
    @State private var selectedMethod = "16:8"
    @State private var loading = false
    @State private var refreshing = false
    @State private var busy = false
    @State private var loggingRecommendationId = ""
    @State private var reminders: [ReminderItem] = []
    @State private var breakFastRecommendations: [MealRecommendation] = []
    @State private var message = ""
    @State private var now = Date()
    @State private var fastingNotes = ""
    @State private var selectedStageDetail: FastingStage?
    @State private var showPlanEditor = false
    @State private var showHistorySheet = false
    @State private var showManualFastSheet = false
    @State private var showNotesEditor = false
    @State private var showCancelConfirmation = false

    init(onBack: @escaping () -> Void, onStatusChanged: @escaping () -> Void) {
        self.onBack = onBack
        self.onStatusChanged = onStatusChanged
        let initialPrefs = Self.cachedPrefs ?? FastingPreferences()
        _status = State(initialValue: Self.cachedStatus)
        _history = State(initialValue: Self.cachedHistory)
        _prefs = State(initialValue: initialPrefs)
        _selectedMethod = State(initialValue: initialPrefs.method)
        _breakFastRecommendations = State(initialValue: Self.cachedBreakFastRecommendations)
        _loading = State(initialValue: false)
    }

    private let presets: [(String, String)] = [
        ("14:10", "温和"),
        ("16:8", "常用"),
        ("18:6", "进阶"),
        ("20:4", "严格"),
    ]

    private var completedCount: Int {
        history?.summary?.completedSessions
            ?? (history?.sessions ?? status?.recentSessions ?? []).filter { $0.status == "completed" }.count
    }

    private var totalCount: Int {
        history?.summary?.totalSessions
            ?? (history?.sessions ?? status?.recentSessions ?? []).count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                fastingPageBackground

                ScrollView {
                    VStack(spacing: 0) {
                        header
                            .padding(.bottom, 20)
                        if loading {
                            CalLoadingCard(
                                title: "正在同步断食状态",
                                subtitle: "马上告诉你现在该开始还是结束",
                                systemImage: "timer"
                            )
                            .padding(.vertical, 72)
                        } else {
                            VStack(spacing: 18) {
                                if !message.isEmpty {
                                    fastingMessageCard(message)
                                }
                                if let active = status?.activeSession {
                                    activeFirstScreen(active)
                                } else {
                                    idleFirstScreen
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 42)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadIfStale() }
            .sheet(isPresented: $showPlanEditor) {
                FastingPlanEditorSheet(
                    prefs: $prefs,
                    selectedMethod: $selectedMethod,
                    presets: presets,
                    busy: busy,
                    onSave: {
                        await savePrefs()
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showManualFastSheet) {
                ManualFastAddSheet(
                    selectedMethod: selectedMethod,
                    defaultHours: prefs.fastingHours,
                    presets: presets,
                    onSaved: { savedHistory in
                        history = savedHistory
                        Self.cachedHistory = savedHistory
                        Self.lastHistoryLoadedAt = Date()
                        Task {
                            await load(silent: true)
                            onStatusChanged()
                        }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showNotesEditor) {
                FastingNotesSheet(notes: $fastingNotes)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.hidden)
            }
            .confirmationDialog("放弃本次断食？", isPresented: $showCancelConfirmation, titleVisibility: .visible) {
                Button("放弃本次断食", role: .destructive) {
                    Task { await cancelFasting() }
                }
                Button("继续断食", role: .cancel) {}
            } message: {
                Text("放弃后不会计入完成记录，今天仍可重新开始。")
            }
            .fullScreenCover(isPresented: $showHistorySheet) {
                FastingHistoryDetailsSheet(
                    history: history,
                    activeSession: status?.activeSession,
                    now: now,
                    targetHours: prefs.fastingHours,
                    onClose: {
                        showHistorySheet = false
                    },
                    onAddFast: {
                        presentManualFastSheet()
                    },
                    onRefresh: {
                        Task { await refreshHistory() }
                    }
                )
            }
            .sheet(item: $selectedStageDetail) { stage in
                FastingStageDetailSheet(stage: stage)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
                now = value
            }
        }
    }

    private var idleFirstScreen: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Text("断食方案")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(prefs.method)
                            .font(.system(size: 36, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("断食 \(Int(round(prefs.fastingHours))) 小时 · 进食 \(Int(round(prefs.eatingHours))) 小时")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showPlanEditor = true
                    } label: {
                        Label("更换", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .padding(.horizontal, 13)
                            .frame(height: 38)
                            .background(Color(hex: "F3F4F6"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .background(.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "EEF0F3"), lineWidth: 1))

            Button {
                Task { await startFasting() }
            } label: {
                HStack(spacing: 9) {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .accessibilityHidden(true)
                    }
                    Text(busy ? "正在开始" : "开始 \(prefs.method) 轻断食")
                }
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(Color(hex: "111318"))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    private func activeFirstScreen(_ active: FastingSession) -> some View {
        let timing = activeTiming(active)
        let progress = min(1, max(0, Double(timing.elapsed) / Double(max(1, timing.target))))
        let stage = status?.currentStage ?? active.stage

        return VStack(spacing: 18) {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(timing.remaining > 0 ? "还剩" : "目标已达成")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.secondary)
                    Text(timing.remaining > 0 ? formatCountdown(timing.remaining) : "00:00:00")
                        .font(.system(size: 46, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .minimumScaleFactor(0.65)
                        .monospacedDigit()
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(hex: "E7F5EC"))
                            Capsule()
                                .fill(Color(hex: "35C86F"))
                                .frame(width: proxy.size.width * progress)
                        }
                    }
                    .frame(height: 9)
                }

                HStack(spacing: 12) {
                    Image(systemName: stage.map { stageIconName($0, index: 0) } ?? "timer")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "16B75B"))
                        .frame(width: 46, height: 46)
                        .background(Color(hex: "E8F8EE"))
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前阶段")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(stage?.label ?? "断食进行中")
                            .font(.system(size: 19, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                    }
                    Spacer()
                    Text("\(Int(round(progress * 100)))%")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(hex: "16B75B"))
                }
            }
            .padding(22)
            .background(.white.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "EEF0F3"), lineWidth: 1))

            Button {
                Task { await endFasting() }
            } label: {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text("结束并记录")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color(hex: "111318"))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    private var fastingPageBackground: some View {
        AppShellBackground()
    }

    private var header: some View {
        CalPageHeader(
            title: "轻断食",
            subtitle: fastingHeaderSubtitle,
            systemImage: "timer"
        ) {
            HStack(spacing: 10) {
                if status?.activeSession == nil {
                    Button {
                        prefs.remindersEnabled.toggle()
                        Task { _ = await savePrefs() }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: prefs.remindersEnabled ? "bell.fill" : "bell")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                                .frame(width: 42, height: 42)
                                .background(.white.opacity(0.86))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 6)
                            if prefs.remindersEnabled {
                                Circle()
                                    .fill(Color(hex: "35C86F"))
                                    .frame(width: 9, height: 9)
                                    .clipShape(Circle())
                                    .offset(x: -1, y: 3)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(prefs.remindersEnabled ? "关闭断食提醒" : "开启断食提醒")
                }

                Button(action: onBack) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.86))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭轻断食")
            }
        }
    }

    private var fastingHeaderSubtitle: String {
        if let active = status?.activeSession {
            let timing = activeTiming(active)
            let progress = Int(round(min(1, max(0, Double(timing.elapsed) / Double(max(1, timing.target)))) * 100))
            return "\(active.method ?? prefs.method) · 进行中 \(progress)%"
        }
        if completedCount > 0 {
            return "已完成 \(completedCount) 次 · 连续 \(max(0, history?.summary?.currentStreak ?? 0)) 天"
        }
        return "\(prefs.method) · 可从今天开始"
    }

    private func fastingHeaderPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(Color(hex: "24395F"))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 64, height: 54)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var heroCard: some View {
        let active = status?.activeSession
        let isActive = active != nil
        let timing = activeTiming(active)
        let progress = min(1, max(0, Double(timing.elapsed) / Double(max(1, timing.target))))
        let stages = status?.stagePlan ?? []
        let ringSize = min(318.0, max(292.0, UIScreen.main.bounds.width - 82.0))
        let primaryButtonWidth = min(244.0, max(216.0, UIScreen.main.bounds.width * 0.60))
        let fastStart = plannedStartDate(active: active)
        let currentStage = status?.currentStage ?? active?.stage
        let fastingGreen = Color(hex: "72D3A2")
        let fastingMint = Color(hex: "BFEFD9")
        return VStack(spacing: 12) {
            Button {
                showPlanEditor = true
            } label: {
                planPill(method: active?.method ?? prefs.method)
            }
            .buttonStyle(.plain)

            fastingDecisionBanner(
                title: fastingDecisionTitle(isActive: isActive, timing: timing, plannedStart: fastStart),
                subtitle: fastingDecisionSubtitle(isActive: isActive, timing: timing)
            )
            .padding(.horizontal, 4)

            ZStack {
                Circle()
                    .stroke(fastingMint, lineWidth: 26)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(fastingGreen, style: StrokeStyle(lineWidth: 26, lineCap: progress >= 0.995 ? .butt : .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.7), value: progress)

                ForEach(Array(fastingRingMarkers(stages: stages).enumerated()), id: \.offset) { index, marker in
                    Button {
                        if let stage = marker.stage {
                            selectedStageDetail = stage
                        }
                    } label: {
                        Image(systemName: marker.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(marker.color)
                            .frame(width: 38, height: 38)
                            .background(.white)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(fastingGreen.opacity(0.68), lineWidth: 1.4)
                            )
                            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(marker.stage?.label ?? "查看断食阶段")
                    .offset(markerOffset(index, ringSize: ringSize))
                }

                VStack(spacing: 10) {
                    Text(isActive ? (timing.remaining > 0 ? "还剩" : "已达成") : "计划开始")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    Text(isActive ? (timing.remaining > 0 ? formatCountdown(timing.remaining) : "已达成") : fastingDateLabel(fastStart))
                        .font(.system(size: isActive ? 42 : 33, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .minimumScaleFactor(0.64)
                    HStack(spacing: 8) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: "87B9FF"))
                            .accessibilityHidden(true)
                        Text(isActive ? "\(Int(round(progress * 100)))" : "0")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                    }
                    .frame(minWidth: 80, minHeight: 38)
                    .padding(.horizontal, 12)
                    .background(Color(hex: "EEF5FF"))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(hex: "BFD7FF"), lineWidth: 1.3))
                }
                .padding(.horizontal, 24)
            }
            .frame(width: ringSize, height: ringSize)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

            fastingSummaryStrip(isActive: isActive, progress: progress, stage: currentStage)
                .padding(.horizontal, 4)

            Button {
                Task {
                    if isActive {
                        await endFasting()
                    } else {
                        await startFasting()
                    }
                }
            } label: {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text(isActive ? "结束并记录" : "开始这次断食")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: primaryButtonWidth, height: 56)
            .background(fastingGreen)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: fastingGreen.opacity(0.28), radius: 18, x: 0, y: 10)
            .disabled(busy)
            .padding(.top, 0)

            if isActive {
                activeFastingControlPanel(active: active, timing: timing)
                    .padding(.top, 2)
            }

            scheduleCard(active: active)
                .padding(.top, 4)
        }
        .opacity(busy ? 0.62 : 1)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func fastingDecisionTitle(isActive: Bool, timing: (elapsed: Int, remaining: Int, target: Int), plannedStart: Date) -> String {
        if isActive {
            return timing.remaining > 0 ? "继续断食，还剩 \(formatCountdown(timing.remaining))" : "目标到了，可以结束并记录"
        }
        return "\(datePlanLabel(plannedStart)) 开始断食"
    }

    private func fastingDecisionSubtitle(isActive: Bool, timing: (elapsed: Int, remaining: Int, target: Int)) -> String {
        if isActive {
            return "现在先补水，别喝含糖饮料；不舒服就提前结束。"
        }
        return "到点点开始，我会帮你记进度和提醒。"
    }

    private func fastingDecisionBanner(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status?.activeSession == nil ? "clock.badge.checkmark" : "drop.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(status?.activeSession == nil ? Color(hex: "72D3A2") : Color(hex: "159BFF"))
                .frame(width: 32, height: 32)
                .background(Color.white)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func activeFastingControlPanel(active: FastingSession?, timing: (elapsed: Int, remaining: Int, target: Int)) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本次进度")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "A9ADC2"))
                Text("\(formatDuration(timing.elapsed)) / \(formatDuration(timing.target))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 6)
            Button {
                showNotesEditor = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: fastingNotes.isEmpty ? "note.text" : "note.text.badge.plus")
                        .accessibilityHidden(true)
                    Text(fastingNotes.isEmpty ? "写备注" : "已备注")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "111318"))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)

            Button {
                showCancelConfirmation = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .accessibilityHidden(true)
                    Text("放弃")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "111318"))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color(hex: "F2F4F7"))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(hex: "F8FAFF"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hex: "E8ECF5"), lineWidth: 1)
        )
        .padding(.horizontal, 4)
    }

    private func fastingSummaryStrip(isActive: Bool, progress: Double, stage: FastingStage?) -> some View {
        HStack(spacing: 8) {
            compactStatusPill(
                icon: isActive ? "timer" : "play.fill",
                title: isActive ? "进行中" : "未开始",
                value: isActive ? "\(Int(round(progress * 100)))%" : "\(Int(prefs.fastingHours))小时",
                color: Color(hex: "111318")
            )
            compactStatusPill(
                icon: stage.map { stageIconName($0, index: 0) } ?? "sparkles",
                title: "身体状态",
                value: stage?.label ?? "待开始",
                color: stage.map { stageColor($0, index: 0) } ?? Color(hex: "8E949E")
            )
            compactStatusPill(
                icon: "drop.fill",
                title: "断食期间",
                value: "补水",
                color: Color(hex: "159BFF")
            )
        }
    }

    private func compactStatusPill(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.12))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color(hex: "9AA0AA"))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var fastingGuidanceCard: some View {
        let active = status?.activeSession
        let isActive = active != nil
        let timing = activeTiming(active)
        let progress = isActive ? min(1, max(0, Double(timing.elapsed) / Double(max(1, timing.target)))) : 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("断食陪伴")
                        .font(.system(size: 18, weight: .black))
                    Text(isActive ? "当前阶段优先稳住节奏，不被小零食打断。" : "开始后会同步展示身体状态和提醒。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(isActive ? "\(Int(progress * 100))%" : "准备")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(isActive ? Color(hex: "111318") : Color(hex: "6D7480"))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color(hex: "F3F4F6"))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                guidanceTile(icon: "drop.fill", title: "可以喝", value: "水 / 无糖茶 / 黑咖啡", color: Color(hex: "159BFF"))
                guidanceTile(icon: "nosign", title: "避免", value: "奶茶 / 果汁 / 零食", color: Color(hex: "8E949E"))
            }
            HStack(spacing: 8) {
                guidanceTile(icon: "fork.knife", title: "破斋建议", value: "蛋白质 + 蔬菜，少油少糖", color: Color(hex: "111318"))
                guidanceTile(icon: "bell.fill", title: "提醒", value: prefs.remindersEnabled ? "已开启" : "未开启", color: Color(hex: "111318"))
            }

            weekCompletionStrip
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private func guidanceTile(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.12))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: "6D7480"))
                .lineLimit(2)
                .minimumScaleFactor(0.74)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var weekCompletionStrip: some View {
        let sessions = history?.sessions ?? status?.recentSessions ?? []
        let localCompletedDays = Set(sessions.compactMap { session -> String? in
            guard session.status == "completed", let start = parseDate(session.startAt) else { return nil }
            return dayKey(start)
        })
        let completedDays = Set((history?.summary?.weekCompletedDates ?? []).isEmpty ? Array(localCompletedDays) : (history?.summary?.weekCompletedDates ?? []))
        let calendar = Calendar.current
        let days = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: -6 + offset, to: now)
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("本周连续感")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Text("完成 \(history?.summary?.weekCompletedDays ?? completedDays.count) 天")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                ForEach(days, id: \.self) { day in
                    let done = completedDays.contains(dayKey(day))
                    VStack(spacing: 4) {
                        Text(shortWeekday(day))
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "9AA0AA"))
                        Image(systemName: done ? "checkmark" : "circle.fill")
                            .font(.system(size: done ? 12 : 5, weight: .black))
                            .foregroundStyle(done ? .white : Color(hex: "D1D5DB"))
                            .frame(width: 27, height: 27)
                            .background(done ? Color(hex: "111318") : Color(hex: "F0F2F5"))
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func headerPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 66, height: 54)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func planPill(method: String) -> some View {
        HStack(spacing: 14) {
            Text("我的断食计划")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .layoutPriority(1)
            Rectangle()
                .fill(Color(hex: "DCE4E5"))
                .frame(width: 1, height: 34)
            Text(method)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "72D3A2"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            Image(systemName: "pencil")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color(hex: "111318"))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .frame(maxWidth: min(330, UIScreen.main.bounds.width - 112))
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 16, x: 0, y: 8)
    }

    private func scheduleCard(active: FastingSession?) -> some View {
        let start = plannedStartDate(active: active)
        let end = plannedEndDate(active: active, start: start)
        let startLabel = datePlanLabel(start)
        let endLabel = datePlanLabel(end)
        return HStack(spacing: 0) {
            scheduleColumn(label: "开始断食", value: startLabel)
            Rectangle()
                .fill(Color(hex: "E5E7EB"))
                .frame(width: 1, height: 48)
                .padding(.horizontal, 12)
            scheduleColumn(label: "结束断食", value: endLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "72D3A2").opacity(0.55), lineWidth: 1.4))
    }

    private func scheduleColumn(label: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "A7ADC0"))
            HStack(spacing: 7) {
                Text(value)
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .layoutPriority(1)
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "111318"))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var fastingStatisticsSection: some View {
        let summary = history?.summary
        let sessions = history?.sessions ?? status?.recentSessions ?? []
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                Text("断食统计")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color(hex: "24395F"))
                Spacer()
                Button {
                    showHistorySheet = true
                    Task { await refreshHistoryIfStale() }
                } label: {
                    HStack(spacing: 8) {
                        Text("查看详情")
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(hex: "72D3A2"))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                fastingStatTile(
                    value: "\(Int(round(summary?.averageHours ?? 0)))小时",
                    label: "平均",
                    sublabel: fastingDateRangeLabel()
                )
                fastingStatTile(
                    value: "\(summary?.completionRate ?? 0)%",
                    label: "完成率",
                    sublabel: "完成 \(summary?.completedSessions ?? sessions.filter { $0.status == "completed" }.count)/\(summary?.totalSessions ?? sessions.count)"
                )
                fastingStatTile(
                    value: "\(summary?.currentStreak ?? currentCompletedStreak())天",
                    label: "连续",
                    sublabel: "最长 \(summary?.longestStreak ?? 0) 天"
                )
            }

            fastingMiniChart
            recentFastingSummaryRow(sessions: sessions)

            HStack(spacing: 12) {
                Button {
                    presentManualFastSheet()
                } label: {
                    HStack(spacing: 10) {
                        Text("补记断食")
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .regular))
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color(hex: "72D3A2"))
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showHistorySheet = true
                    Task { await refreshHistory() }
                } label: {
                    HStack(spacing: 10) {
                        Text("历史")
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(hex: "24395F"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(Color(hex: "72D3A2"), lineWidth: 1.4)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .softCard(radius: 28)
    }

    private func fastingStatTile(value: String, label: String, sublabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(hex: "24395F"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color(hex: "111318"))
            Text(sublabel)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color(hex: "A5A8BA"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var fastingMiniChart: some View {
        let sessions = history?.sessions ?? status?.recentSessions ?? []
        let calendar = Calendar.current
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: -6 + $0, to: now) }
        let targetHours = max(1, prefs.fastingHours)
        return VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                GeometryReader { proxy in
                    let chartHeight = max(1, proxy.size.height - 36)
                    let targetY = max(0, min(chartHeight, chartHeight - CGFloat(targetHours / 24) * chartHeight))
                    ZStack(alignment: .bottomLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color(hex: "F0F1F4"))
                                    .frame(height: 1)
                                Spacer()
                            }
                        }
                        Rectangle()
                            .fill(Color(hex: "72D3A2").opacity(0.38))
                            .frame(height: 1.5)
                            .offset(y: targetY)
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(days, id: \.self) { day in
                                let hours = fastingHoursForDay(day, sessions: sessions)
                                let hasRecord = hours > 0
                                let reachedGoal = hours >= targetHours
                                let barHours = hasRecord ? hours : min(targetHours, 24)
                                VStack(spacing: 7) {
                                    Spacer()
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(hasRecord ? (reachedGoal ? Color(hex: "72D3A2") : Color(hex: "BFEFD9")) : Color(hex: "F8F8F8"))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                                .stroke(hasRecord ? Color(hex: "72D3A2").opacity(0.35) : Color(hex: "DFDFE2"), lineWidth: 1.2)
                                        )
                                        .frame(width: 34, height: max(18, min(chartHeight, CGFloat(barHours / 24) * chartHeight)))
                                    Text(shortWeekdayLabel(day))
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(Color(hex: "A8AABE"))
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(height: 180)

                VStack(alignment: .trailing, spacing: 0) {
                    ForEach([24, 20, 16, 12, 8, 4, 0], id: \.self) { hour in
                        Text("\(hour)小时")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color(hex: "A8AABE"))
                        if hour != 0 {
                            Spacer()
                        }
                    }
                }
                .frame(width: 36, height: 180)
            }

            HStack(spacing: 16) {
                chartLegend(color: Color(hex: "72D3A2"), text: "已达标")
                chartLegend(color: Color(hex: "BFEFD9"), text: "未达标")
                chartLegend(color: Color(hex: "72D3A2").opacity(0.38), text: "目标线")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            chartLegend(color: Color(hex: "F4F4F4"), text: "计划断食")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recentFastingSummaryRow(sessions: [FastingSession]) -> some View {
        let latest = sessions.sorted { ($0.startAt ?? "") > ($1.startAt ?? "") }.first
        let isActive = status?.activeSession != nil
        let active = status?.activeSession
        let duration = isActive ? formatDuration(activeTiming(active).elapsed) : formatDuration(latest?.elapsedSeconds ?? 0)
        let method = (isActive ? active?.method : latest?.method) ?? prefs.method
        let statusLabel = isActive ? "进行中" : statusText(latest?.status)
        let startLabel: String = {
            if isActive {
                return datePlanLabel(planDate(active?.startAt, fallback: now))
            }
            guard let start = parseDate(latest?.startAt) else { return "还没有开始过" }
            return datePlanLabel(start)
        }()
        return HStack(spacing: 12) {
            Image(systemName: isActive ? "timer" : "checkmark")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(isActive ? Color(hex: "72D3A2") : Color(hex: "24395F"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(latest == nil && !isActive ? "点开始断食，记录会在这里显示" : "\(method) · \(statusLabel)")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "24395F"))
                    .lineLimit(1)
                Text(latest == nil && !isActive ? "也可以补记上一段断食。" : "\(startLabel) · \(duration)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            Spacer()
            Text("\(Int(prefs.fastingHours))小时")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "72D3A2"))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color(hex: "EAFBF2"))
                .clipShape(Capsule())
        }
        .padding(12)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var breakFastRecommendationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日破斋怎么吃")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Spacer()
                Button {
                    Task { await loadBreakFastRecommendations(force: true) }
                } label: {
                    HStack(spacing: 7) {
                        Text("换一组")
                        Image(systemName: refreshing ? "arrow.triangle.2.circlepath" : "arrow.right")
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "72D3A2"))
                }
                .buttonStyle(.plain)
            }

            if breakFastRecommendations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("先按轻负担原则破斋")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("优先高蛋白、足量蔬菜、少油少糖；加载后会显示可直接记录的推荐餐。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(hex: "F8F9FB"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(breakFastRecommendations.prefix(4)) { recommendation in
                            breakFastRecommendationCard(recommendation)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, 12)
        .task {
            await loadBreakFastRecommendationsIfStale()
        }
    }

    private func breakFastRecommendationCard(_ recommendation: MealRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            fastBreakerVisual(recommendation)

            VStack(alignment: .leading, spacing: 6) {
                Text(localizedRecommendationText(recommendation.title))
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(recommendationFoodsLine(recommendation))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Label("\(recommendation.prepTimeMinutes)分钟", systemImage: "clock")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "6D7480"))
                Text("\(Int(round(recommendation.calories)))千卡")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "6D7480"))
                Spacer()
                Button {
                    Task { await logBreakFastRecommendation(recommendation) }
                } label: {
                    if loggingRecommendationId == recommendation.id {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                            .frame(width: 54, height: 30)
                    } else {
                        Text("记录")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 30)
                    }
                }
                .background(Color(hex: "72D3A2"))
                .clipShape(Capsule())
                .disabled(!loggingRecommendationId.isEmpty)
            }
        }
        .padding(10)
        .frame(width: 224, height: 206, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.055), radius: 18, x: 0, y: 10)
    }

    private func recommendationMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "9AA0AA"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func fastBreakerVisual(_ recommendation: MealRecommendation) -> some View {
        let foods = Array(recommendation.foods.prefix(4))
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(hex: "EAF8F1"),
                        Color(hex: "FFF5DE"),
                        Color(hex: "F2F8FF")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Circle()
                .fill(.white.opacity(0.86))
                .frame(width: 94, height: 94)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3))
                .shadow(color: .black.opacity(0.055), radius: 14, x: 0, y: 8)

            ForEach(Array(foods.enumerated()), id: \.element.id) { index, food in
                foodPreviewDot(food: food, index: index, total: max(foods.count, 1))
            }

            if foods.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color(hex: "72D3A2"))
                        .accessibilityHidden(true)
                    Text("轻负担")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "24395F"))
                }
            }

            VStack {
                Spacer()
                HStack(spacing: 5) {
                    Text("\(Int(round(recommendation.protein)))克 蛋白")
                    Text("·")
                    Text("\(Int(round(recommendation.carbs)))克 碳水")
                }
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "24395F"))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(.white.opacity(0.86))
                .clipShape(Capsule())
                .padding(.bottom, 8)
            }
        }
        .frame(height: 102)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func foodPreviewDot(food: RecommendationFood, index: Int, total: Int) -> some View {
        let angle = Double(index) / Double(max(total, 1)) * 360.0 - 90.0
        let radius: CGFloat = total <= 1 ? 0 : 34
        let x = CGFloat(cos(angle * .pi / 180.0)) * radius
        let y = CGFloat(sin(angle * .pi / 180.0)) * radius
        return VStack(spacing: 2) {
            Circle()
                .fill(foodPreviewColor(food))
                .frame(width: index == 0 ? 34 : 28, height: index == 0 ? 34 : 28)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            Text(shortFoodName(food.name))
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(Color(hex: "24395F"))
                .lineLimit(1)
                .frame(width: 48)
        }
        .offset(x: x, y: y)
        .accessibilityElement(children: .combine)
    }

    private func foodPreviewColor(_ food: RecommendationFood) -> Color {
        let text = food.name
        if text.contains("菜") || text.contains("蔬") || text.contains("豆") || text.contains("瓜") {
            return Color(hex: "72D3A2")
        }
        if text.contains("鸡") || text.contains("鱼") || text.contains("虾") || text.contains("肉") || text.contains("蛋") {
            return Color(hex: "F47B55")
        }
        if text.contains("饭") || text.contains("面") || text.contains("薯") || text.contains("麦") || text.contains("粥") {
            return Color(hex: "F2C46D")
        }
        return Color(hex: "A7C3FF")
    }

    private func shortFoodName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 4 { return trimmed }
        return String(trimmed.prefix(4))
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("断食方案")
                    .font(.system(size: 18, weight: .black))
                Spacer()
                Text(prefs.remindersEnabled ? "提醒开" : "提醒关")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { prefs.enabled },
                set: { value in
                    prefs.enabled = value
                    Task { _ = await savePrefs() }
                    }
                ))
                .labelsHidden()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(presets, id: \.0) { item in
                    Button {
                        selectedMethod = item.0
                        let hours = methodHours(item.0)
                        prefs.method = item.0
                        prefs.fastingHours = hours.fasting
                        prefs.eatingHours = hours.eating
                        Task { _ = await savePrefs() }
                    } label: {
                        VStack(spacing: 4) {
                            Text(item.0)
                                .font(.system(size: 16, weight: .black))
                            Text(item.1)
                                .font(.system(size: 11, weight: .bold))
                                .opacity(0.72)
                        }
                        .foregroundStyle(selectedMethod == item.0 ? .white : Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(selectedMethod == item.0 ? Color(hex: "72D3A2") : Color(hex: "F5F6F8"))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(selectedMethod == item.0 ? Color(hex: "72D3A2") : Color(hex: "EBEEF2"), lineWidth: 1)
                        )
                        .shadow(color: selectedMethod == item.0 ? Color(hex: "72D3A2").opacity(0.22) : .clear, radius: 12, x: 0, y: 7)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自定义断食时长")
                            .font(.system(size: 13, weight: .black))
                        Text("保存后首页同步轻断食状态")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(prefs.fastingHours)) 小时")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                }
                Slider(value: Binding(
                    get: { prefs.fastingHours },
                    set: { value in
                        let rounded = min(24, max(12, value.rounded()))
                        prefs.fastingHours = rounded
                        prefs.eatingHours = max(1, 24 - rounded)
                        prefs.method = "\(Int(rounded)):\(Int(prefs.eatingHours))"
                        selectedMethod = prefs.method
                    }
                ), in: 12...24, step: 1)
                .tint(Color(hex: "111318"))

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("进食窗口开始")
                            .font(.system(size: 13, weight: .black))
                        Text("格式如 12:00")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("12:00", text: $prefs.eatingWindowStart)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 86, height: 40)
                        .background(Color(hex: "F5F6F8"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("提醒")
                            .font(.system(size: 13, weight: .black))
                        Text("进食窗口、断食开始和结束前提醒")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $prefs.remindersEnabled)
                        .labelsHidden()
                }

                Button {
                    Task { _ = await savePrefs() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: busy ? "hourglass" : "square.and.arrow.down")
                            .accessibilityHidden(true)
                        Text("保存设置")
                    }
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color(hex: "F2F2F7"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(busy)
            }
            .padding(12)
            .background(Color.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private var stageCard: some View {
        let current = status?.currentStage ?? status?.activeSession?.stage
        let stages = status?.stagePlan ?? []
        let currentProgress = min(100, max(0, current?.progressPct ?? status?.activeSession?.progressPct ?? 0))
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                bodyStatusGlyph(stage: current)
                    .frame(width: 92, height: 118)

                VStack(alignment: .leading, spacing: 7) {
                    Text("身体状态")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(hex: "24395F"))
                    Text(current?.label ?? "等待开始")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(current?.description ?? "开始断食后，这里会展示血糖、脂肪燃烧、酮体和自噬等阶段变化。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)

                    HStack(spacing: 8) {
                        Text("\(Int(round(currentProgress)))%")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "72D3A2"))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color(hex: "EAFBF2"))
                            .clipShape(Capsule())
                        if let next = current?.nextLabel, !next.isEmpty {
                            Text("下阶段 \(next)")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Color(hex: "8E949E"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if let advice = current?.advice, !advice.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "72D3A2"))
                        .accessibilityHidden(true)
                    Text(advice)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "24395F"))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "F3FBF7"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            stageTimeline(stages: stages)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                ForEach(stages) { stage in
                    Button {
                        selectedStageDetail = stage
                    } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Image(systemName: stageIconName(stage, index: 0))
                                        .font(.system(size: 15, weight: .black))
                                        .foregroundStyle(stageColor(stage, index: 0))
                                        .frame(width: 32, height: 32)
                                        .background(.white)
                                        .clipShape(Circle())
                                    Spacer()
                                    if stage.active ?? false {
                                        Circle()
                                            .fill(Color(hex: "111318"))
                                            .frame(width: 8, height: 8)
                                    }
                                }
                                Text(stage.label ?? stage.id)
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .lineLimit(1)
                                Text(stage.windowLabel ?? "阶段")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(hex: "8D94A8"))
                                    .lineLimit(1)
                        }
                            .padding(13)
                            .frame(width: 138, height: 108, alignment: .leading)
                            .background((stage.active ?? false) ? Color(hex: "F2F4F7") : Color(hex: "F8F9FB"))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke((stage.active ?? false) ? Color(hex: "111318").opacity(0.18) : Color(hex: "EEF0F3"), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                }
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private func stageTimeline(stages: [FastingStage]) -> some View {
        let active = status?.activeSession
        let isActive = active != nil
        let elapsedHours = Double(activeTiming(active).elapsed) / 3600.0
        let visibleStages = Array(stages.prefix(6))
        let current = status?.currentStage ?? active?.stage
        let nextLabel = current?.nextLabel ?? ""
        let nextSeconds = current?.nextInSeconds ?? 0
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("身体阶段时间轴")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "24395F"))
                    Text(isActive ? "按当前断食时长自动推进" : "开始断食后会点亮各阶段")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
                if isActive, !nextLabel.isEmpty, nextSeconds > 0 {
                    Text("距\(nextLabel) \(formatDuration(nextSeconds))")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(hex: "72D3A2"))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color(hex: "EAFBF2"))
                        .clipShape(Capsule())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            ZStack {
                Capsule()
                    .fill(Color(hex: "E8F6EE"))
                    .frame(height: 4)
                    .padding(.horizontal, 22)
                    .offset(y: -18)

                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(visibleStages.enumerated()), id: \.element.id) { index, stage in
                        let startHour = stage.startsAtHours ?? 0
                        let reached = isActive && elapsedHours >= startHour
                        let activeStage = stage.active ?? false
                        VStack(spacing: 7) {
                            Button {
                                selectedStageDetail = stage
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(activeStage ? Color(hex: "24395F") : (reached ? Color(hex: "72D3A2") : Color.white))
                                        .frame(width: activeStage ? 32 : 26, height: activeStage ? 32 : 26)
                                        .overlay(
                                            Circle()
                                                .stroke(reached || activeStage ? Color(hex: "72D3A2") : Color(hex: "DCE4E5"), lineWidth: 1.4)
                                        )
                                    Image(systemName: activeStage ? "flame.fill" : (reached ? "checkmark" : stageIconName(stage, index: index)))
                                        .font(.system(size: activeStage ? 13 : 11, weight: .black))
                                        .foregroundStyle(activeStage ? .white : (reached ? .white : stageColor(stage, index: index)))
                                        .accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(stage.label ?? "断食阶段")

                            Text("\(Int(round(startHour)))小时")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(reached || activeStage ? Color(hex: "24395F") : Color(hex: "A7ADC0"))
                                .monospacedDigit()
                            Text(stage.label ?? stage.id)
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(Color(hex: "8E949E"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(minHeight: 72)
        }
        .padding(12)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func bodyStatusGlyph(stage: FastingStage?) -> some View {
        let progress = min(1, max(0, (stage?.progressPct ?? status?.activeSession?.progressPct ?? 0) / 100))
        return ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: "F6FFFA"), Color(hex: "EEF8F3")],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color(hex: "D8F3E5"), lineWidth: 1.2)
                )

            VStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: "24395F"))
                    .frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(hex: "72D3A2").opacity(0.82))
                    .frame(width: 42, height: 52)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.34))
                            .frame(width: 28, height: 9)
                            .padding(.top, 8)
                    }
                HStack(spacing: 7) {
                    Capsule()
                        .fill(Color(hex: "72D3A2").opacity(0.68))
                        .frame(width: 12, height: 30)
                    Capsule()
                        .fill(Color(hex: "72D3A2").opacity(0.68))
                        .frame(width: 12, height: 30)
                }
            }
            .accessibilityHidden(true)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(hex: "72D3A2"), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(-90))
                .offset(y: -2)

            Image(systemName: stage.map { stageIconName($0, index: 0) } ?? "sparkles")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(stage.map { stageColor($0, index: 0) } ?? Color(hex: "72D3A2"))
                .frame(width: 32, height: 32)
                .background(.white)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
                .offset(x: 30, y: -44)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("身体状态 \(stage?.label ?? "等待开始")")
    }

    private var historyCard: some View {
        let summary = history?.summary
        let sessions = history?.sessions ?? status?.recentSessions ?? []
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近记录")
                    .font(.system(size: 18, weight: .black))
                Spacer()
                Text("完成 \(summary?.completedSessions ?? sessions.filter { $0.status == "completed" }.count)/\(summary?.totalSessions ?? sessions.count)")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                metric("完成率", "\(summary?.completionRate ?? 0)%")
                metric("平均", "\(String(format: "%.1f", summary?.averageHours ?? 0))小时")
            }
            HStack(spacing: 10) {
                metric("连续", "\(summary?.currentStreak ?? currentCompletedStreak())天")
                metric("最长", "\(summary?.longestStreak ?? 0)天")
                metric("本周", "\(summary?.weekCompletedDays ?? weekCompletedCount())/7")
            }
            if sessions.isEmpty {
                Text("先开始一次断食")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(sessions.prefix(5)) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.method ?? "断食")
                                .font(.system(size: 14, weight: .black))
                            Text(statusText(session.status))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(session.elapsedSeconds ?? 0))
                            .font(.system(size: 13, weight: .black))
                    }
                    .padding(12)
                    .background(Color(hex: "F8F9FB"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(18)
        .softCard(radius: 24)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .black))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func chartLegend(color: Color, text: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color(hex: "A5A8BA"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func fastingRingMarkers(stages: [FastingStage]) -> [(icon: String, color: Color, stage: FastingStage?)] {
        let fallback: [(String, Color)] = [
            ("flame.fill", Color(hex: "111318")),
            ("bolt.fill", Color(hex: "8E949E")),
            ("dna", Color(hex: "8E949E")),
            ("drop.fill", Color(hex: "159BFF")),
            ("takeoutbag.and.cup.and.straw.fill", Color(hex: "8E949E")),
            ("checkmark", Color(hex: "111318"))
        ]
        if stages.isEmpty {
            return fallback.map { (icon: $0.0, color: $0.1, stage: nil) }
        }
        var result = stages.prefix(6).enumerated().map { index, stage in
            (
                icon: stageIconName(stage, index: index),
                color: stageColor(stage, index: index),
                stage: Optional(stage)
            )
        }
        while result.count < 6 {
            let item = fallback[result.count]
            result.append((icon: item.0, color: item.1, stage: nil))
        }
        return result
    }

    private func plannedStartDate(active: FastingSession?) -> Date {
        if let active {
            return planDate(active.startAt, fallback: now)
        }
        guard let eatingStart = nextDateForClock(prefs.eatingWindowStart),
              let fastingStart = Calendar.current.date(byAdding: .minute, value: Int(max(1, prefs.eatingHours) * 60), to: eatingStart) else {
            return now
        }
        if fastingStart > now {
            return fastingStart
        }
        return Calendar.current.date(byAdding: .day, value: 1, to: fastingStart) ?? fastingStart
    }

    private func plannedEndDate(active: FastingSession?, start: Date) -> Date {
        if let active {
            return planDate(active.targetEndAt, fallback: Calendar.current.date(byAdding: .minute, value: Int(prefs.fastingHours * 60), to: start) ?? start)
        }
        return Calendar.current.date(byAdding: .minute, value: Int(prefs.fastingHours * 60), to: start) ?? start
    }

    private func fastingDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "今天"
        } else if calendar.isDateInTomorrow(date) {
            day = "明天"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            day = formatter.string(from: date)
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US")
        timeFormatter.dateFormat = "HH:mm"
        return "\(day) \(timeFormatter.string(from: date))"
    }

    private func fastingDateRangeLabel() -> String {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: start)) - \(formatter.string(from: now))"
    }

    private func shortWeekdayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    private func fastingHoursForDay(_ date: Date, sessions: [FastingSession]) -> Double {
        let key = dayKey(date)
        if let match = sessions.first(where: { session in
            guard let start = parseDate(session.startAt) else { return false }
            return dayKey(start) == key
        }) {
            return Double(match.elapsedSeconds ?? 0) / 3600.0
        }
        if Calendar.current.isDateInToday(date), let active = status?.activeSession {
            return Double(activeTiming(active).elapsed) / 3600.0
        }
        return 0
    }

    private func currentCompletedStreak() -> Int {
        let sessions = history?.sessions ?? status?.recentSessions ?? []
        let completedDays = Set(sessions.compactMap { session -> String? in
            guard session.status == "completed", let start = parseDate(session.startAt) else { return nil }
            return dayKey(start)
        })
        let calendar = Calendar.current
        let todayKey = dayKey(now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        var cursor = completedDays.contains(todayKey) ? now : yesterday
        var count = 0
        while completedDays.contains(dayKey(cursor)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private func weekCompletedCount() -> Int {
        let serverDays = history?.summary?.weekCompletedDates ?? []
        if !serverDays.isEmpty { return serverDays.count }
        let sessions = history?.sessions ?? status?.recentSessions ?? []
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return Set(sessions.compactMap { session -> String? in
            guard session.status == "completed", let start = parseDate(session.startAt), start >= weekStart, start <= now else { return nil }
            return dayKey(start)
        }).count
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(.white)
            } else {
                Image(systemName: icon)
            }
            Text(title)
        }
        .font(.system(size: 15, weight: .black))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Color(hex: "72D3A2"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func fastingMessageCard(_ text: String) -> some View {
        let success = text.hasPrefix("已")
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(success ? Color(hex: "72D3A2") : Color(hex: "DC2626"))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(success ? Color(hex: "426D54") : Color(hex: "9B1C1C"))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(success ? Color(hex: "EAFBF2") : Color(hex: "FFF1F2"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func friendlyFastingError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return fallback }
        if isConnectionFailureMessage(raw) {
            return "现在没连上，这次没保存。检查网络后再点保存。"
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "断食状态暂时没同步，稍后会自动刷新。"
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
            || lower.contains("api")
            || raw.hasPrefix("{")
            || raw.hasPrefix("[")
            || raw.count > 120 {
            return fallback
        }
        return raw
    }

    private func load(silent: Bool = false) async {
        if !silent {
            loading = status == nil && history == nil
        }
        refreshing = true
        message = ""
        defer {
            loading = false
            refreshing = false
        }
        do {
            async let nextStatus = APIClient.shared.getFastingStatus()
            async let nextHistory = APIClient.shared.getFastingHistory(days: 30)
            async let nextPrefs = APIClient.shared.getFastingPreferences()
            async let nextReminders = APIClient.shared.getReminders()
            let loadedStatus = try await nextStatus
            let loadedHistory = try? await nextHistory
            let loadedPrefs = try? await nextPrefs
            let loadedReminders = try? await nextReminders
            if let loadedPrefs {
                prefs = loadedPrefs
                selectedMethod = loadedPrefs.method
                Self.cachedPrefs = loadedPrefs
            }
            if let loadedReminders {
                reminders = loadedReminders
            }
            applyStatus(loadedStatus)
            history = loadedHistory
            Self.cachedStatus = loadedStatus
            Self.cachedHistory = loadedHistory
            Self.lastLoadedAt = Date()
            Self.lastHistoryLoadedAt = loadedHistory == nil ? Self.lastHistoryLoadedAt : Date()
        } catch {
            message = friendlyFastingError(error, fallback: "断食状态暂时没同步，稍后会自动刷新。")
        }
    }

    private func loadIfStale() async {
        if hasFreshPageCache {
            return
        }
        await load(silent: true)
    }

    private var hasFreshPageCache: Bool {
        guard status != nil || history != nil || Self.cachedStatus != nil || Self.cachedHistory != nil else {
            return false
        }
        guard let lastLoadedAt = Self.lastLoadedAt else {
            return false
        }
        return Date().timeIntervalSince(lastLoadedAt) < Self.cacheFreshSeconds
    }

    private func loadBreakFastRecommendations(force: Bool) async {
        if !force && hasFreshBreakFastRecommendations {
            return
        }
        refreshing = true
        defer { refreshing = false }
        do {
            let response = try await APIClient.shared.getTodayRecommendations(mealType: "dinner", prepTimeMinutes: 20, limit: 4, useAI: false)
            breakFastRecommendations = response.recommendations
            Self.cachedBreakFastRecommendations = response.recommendations
            Self.lastRecommendationsLoadedAt = Date()
        } catch {
            if force {
                message = friendlyFastingError(error, fallback: "破斋推荐暂时没加载出来，先按高蛋白、够蔬菜、少油少糖来吃。")
            }
        }
    }

    private func loadBreakFastRecommendationsIfStale() async {
        if hasFreshBreakFastRecommendations {
            return
        }
        await loadBreakFastRecommendations(force: false)
    }

    private var hasFreshBreakFastRecommendations: Bool {
        guard !breakFastRecommendations.isEmpty || !Self.cachedBreakFastRecommendations.isEmpty else {
            return false
        }
        guard let lastRecommendationsLoadedAt = Self.lastRecommendationsLoadedAt else {
            return false
        }
        return Date().timeIntervalSince(lastRecommendationsLoadedAt) < Self.cacheFreshSeconds
    }

    private func logBreakFastRecommendation(_ recommendation: MealRecommendation) async {
        guard loggingRecommendationId.isEmpty else { return }
        loggingRecommendationId = recommendation.id
        defer { loggingRecommendationId = "" }
        do {
            let response = try await APIClient.shared.logRecommendation(
                id: recommendation.id,
                portionMultiplier: recommendation.portionMultiplier ?? 1,
                mealCategory: "dinner"
            )
            message = response.alreadyLogged == true
                ? "这餐已经记录过了。"
                : "已记录：\(localizedRecommendationText(recommendation.title))"
            onStatusChanged()
        } catch {
            message = friendlyFastingError(error, fallback: "这份推荐还没记上，检查网络后再点记录。")
        }
    }

    private func savePrefs() async -> String? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let savedPrefs = try await APIClient.shared.saveFastingPreferences(prefs)
            prefs = savedPrefs
            selectedMethod = savedPrefs.method
            Self.cachedPrefs = savedPrefs
            let loaded = try await APIClient.shared.getFastingStatus()
            applyStatus(loaded)
            Self.cachedStatus = loaded
            Self.lastLoadedAt = Date()
            await refreshLocalFastingReminders(active: loaded.activeSession)
            return nil
        } catch {
            message = friendlyFastingError(error, fallback: "计划还没保存，检查网络后再点保存计划。")
            return message
        }
    }

    private func startFasting() async {
        busy = true
        defer { busy = false }
        do {
            let hours = methodHours(selectedMethod)
            let loaded = try await APIClient.shared.startFasting(method: selectedMethod, fastingHours: hours.fasting)
            applyStatus(loaded)
            await refreshHistory()
            Self.cachedStatus = loaded
            Self.lastLoadedAt = Date()
            await refreshLocalFastingReminders(active: loaded.activeSession)
            onStatusChanged()
        } catch {
            message = friendlyFastingError(error, fallback: "现在没开始成功，检查网络后再点开始断食。")
        }
    }

    private func endFasting() async {
        busy = true
        defer { busy = false }
        do {
            let loaded = try await APIClient.shared.endFasting(notes: fastingNotes)
            fastingNotes = ""
            applyStatus(loaded)
            await refreshHistory()
            Self.cachedStatus = loaded
            Self.lastLoadedAt = Date()
            await refreshLocalFastingReminders(active: loaded.activeSession)
            onStatusChanged()
        } catch {
            message = friendlyFastingError(error, fallback: "这次结束还没保存，检查网络后再点结束断食。")
        }
    }

    private func cancelFasting() async {
        busy = true
        defer { busy = false }
        do {
            let loaded = try await APIClient.shared.cancelFasting()
            applyStatus(loaded)
            await refreshHistory()
            Self.cachedStatus = loaded
            Self.lastLoadedAt = Date()
            await refreshLocalFastingReminders(active: loaded.activeSession)
            onStatusChanged()
        } catch {
            message = friendlyFastingError(error, fallback: "这次还没放弃成功，检查网络后再点放弃。")
        }
    }

    private func refreshHistory() async {
        history = try? await APIClient.shared.getFastingHistory(days: 30)
        Self.cachedHistory = history
        Self.lastHistoryLoadedAt = history == nil ? Self.lastHistoryLoadedAt : Date()
    }

    private func refreshHistoryIfStale() async {
        guard !hasFreshHistoryCache else { return }
        await refreshHistory()
    }

    private var hasFreshHistoryCache: Bool {
        guard history != nil || Self.cachedHistory != nil else { return false }
        guard let lastHistoryLoadedAt = Self.lastHistoryLoadedAt else { return false }
        return Date().timeIntervalSince(lastHistoryLoadedAt) < Self.cacheFreshSeconds
    }

    private func applyStatus(_ loaded: FastingStatus) {
        status = loaded
        if let loadedPrefs = loaded.preferences {
            prefs = loadedPrefs
            selectedMethod = loadedPrefs.method
            Self.cachedPrefs = loadedPrefs
        }
    }

    private func activeTiming(_ session: FastingSession?) -> (elapsed: Int, remaining: Int, target: Int) {
        guard let session else { return (0, 0, Int(prefs.fastingHours * 3600)) }
        let target = session.targetSeconds ?? Int((session.fastingHours ?? prefs.fastingHours) * 3600)
        if let startAt = parseDate(session.startAt), let targetEnd = parseDate(session.targetEndAt) {
            let elapsed = max(0, Int(now.timeIntervalSince(startAt)))
            let remaining = max(0, Int(targetEnd.timeIntervalSince(now)))
            return (elapsed, remaining, max(1, target))
        }
        return (session.elapsedSeconds ?? 0, session.remainingSeconds ?? 0, max(1, target))
    }

    private func recommendationFoodsLine(_ recommendation: MealRecommendation) -> String {
        let names = recommendation.foods.prefix(3).map { localizedRecommendationText($0.name) }
        if names.isEmpty {
            return localizedRecommendationText(recommendation.reason)
        }
        if recommendation.foods.count > 3 {
            return names.joined(separator: "、") + "等"
        }
        return names.joined(separator: "、")
    }

    private func localizedRecommendationText(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return output }
        let mealPrefixes: [(String, String)] = [
            ("breakfast:", "早餐："),
            ("lunch:", "午餐："),
            ("dinner:", "晚餐："),
            ("snack:", "加餐：")
        ]
        for prefix in mealPrefixes where output.lowercased().hasPrefix(prefix.0) {
            output = prefix.1 + String(output.dropFirst(prefix.0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let aliases: [(String, String)] = [
            ("chicken breast", "鸡胸肉"),
            ("fried chicken", "炸鸡"),
            ("grilled chicken", "烤鸡"),
            ("chicken", "鸡肉"),
            ("beef", "牛肉"),
            ("pork", "猪肉"),
            ("salmon", "三文鱼"),
            ("shrimp", "虾仁"),
            ("fish", "鱼肉"),
            ("tofu", "豆腐"),
            ("egg", "鸡蛋"),
            ("yogurt", "酸奶"),
            ("milk", "牛奶"),
            ("white rice", "白米饭"),
            ("brown rice", "糙米饭"),
            ("rice", "米饭"),
            ("noodle", "面条"),
            ("oat", "燕麦"),
            ("bread", "面包"),
            ("potato", "土豆"),
            ("sweet potato", "红薯"),
            ("corn", "玉米"),
            ("broccoli", "西兰花"),
            ("spinach", "菠菜"),
            ("salad", "沙拉"),
            ("lettuce", "生菜"),
            ("tomato", "番茄"),
            ("mushroom", "蘑菇"),
            ("carrot", "胡萝卜"),
            ("apple", "苹果"),
            ("banana", "香蕉"),
            ("orange", "橙子"),
            ("fruit", "水果"),
            ("nuts", "坚果"),
            ("almond", "杏仁")
        ]
        for alias in aliases {
            output = output.replacingOccurrences(of: alias.0, with: alias.1, options: [.caseInsensitive])
        }
        output = output.replacingOccurrences(of: "kcal", with: "千卡", options: [.caseInsensitive])
        output = output.replacingOccurrences(of: " + ", with: " + ")
        return output
    }

    private func methodHours(_ method: String) -> (fasting: Double, eating: Double) {
        let parts = method.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (16, 8)
    }

    private func parseDate(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if !text.contains("Z") && !text.contains("+") {
            text += "+08:00"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func formatCountdown(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let secs = value % 60
        return [hours, minutes, secs].map { String(format: "%02d", $0) }.joined(separator: ":")
    }

    private func formatDuration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        if hours <= 0 { return "\(minutes) 分钟" }
        return "\(hours) 小时 \(minutes) 分"
    }

    private func formatHeroDuration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return "\(value / 3600) 小时 \((value % 3600) / 60) 分"
    }

    private func statusText(_ status: String?) -> String {
        switch status {
        case "completed": return "已完成"
        case "ended_early": return "提前结束"
        case "canceled": return "已取消"
        case "active": return "进行中"
        default: return "已记录"
        }
    }

    private func planDate(_ text: String?, fallback: Date) -> Date {
        parseDate(text) ?? fallback
    }

    private func datePlanLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "今天"
        } else if calendar.isDateInTomorrow(date) {
            day = "明天"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            day = formatter.string(from: date)
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US")
        timeFormatter.dateFormat = "HH:mm"
        return "\(day) \(timeFormatter.string(from: date))"
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    private func refreshLocalFastingReminders(active: FastingSession?) async {
        if let error = await syncRemoteFastingReminders(), message.isEmpty {
            message = error
        }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [
            "lightcal.fasting.window_start",
            "lightcal.fasting.window_end",
            "lightcal.fasting.target_end"
        ])
        guard prefs.enabled, prefs.remindersEnabled else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }

        if let active, let targetEnd = parseDate(active.targetEndAt) {
            await scheduleLocalNotification(
                id: "lightcal.fasting.target_end",
                title: "轻断食快完成了",
                body: "先补水，破斋时优先蛋白质和蔬菜。",
                date: targetEnd
            )
            return
        }

        if let eatingStart = nextDateForClock(prefs.eatingWindowStart) {
            await scheduleDailyNotification(
                id: "lightcal.fasting.window_start",
                title: "进食窗口开始",
                body: "今天优先高蛋白、够蔬菜，少油少糖。",
                date: eatingStart
            )
            if let fastingStart = Calendar.current.date(byAdding: .hour, value: Int(max(1, prefs.eatingHours.rounded())), to: eatingStart) {
                await scheduleDailyNotification(
                    id: "lightcal.fasting.window_end",
                    title: "准备进入断食",
                    body: "结束进食窗口后，水、无糖茶和黑咖啡更稳。",
                    date: fastingStart
                )
            }
        }
    }

    private func syncRemoteFastingReminders() async -> String? {
        let current: [ReminderItem]
        if reminders.isEmpty {
            do {
                current = try await APIClient.shared.getReminders()
            } catch {
                return friendlyFastingError(error, fallback: "计划已保存，提醒稍后会再同步。")
            }
        } else {
            current = reminders
        }
        let preserved = current.filter { item in
            item.category != "fasting" && item.mealType != "fasting"
        }
        let times = fastingReminderTimes()
        let enabled = prefs.enabled && prefs.remindersEnabled
        let fastingReminders = [
            ReminderItem(
                id: "fasting_window_start",
                mealType: "fasting",
                time: times.eatingStart,
                enabled: enabled,
                category: "fasting",
                title: "进食窗口开始",
                targetId: "fasting_window_start",
                daysOfWeek: "1,2,3,4,5,6,7"
            ),
            ReminderItem(
                id: "fasting_window_end",
                mealType: "fasting",
                time: times.fastingStart,
                enabled: enabled,
                category: "fasting",
                title: "准备进入断食",
                targetId: "fasting_window_end",
                daysOfWeek: "1,2,3,4,5,6,7"
            ),
        ]
        do {
            let saved = try await APIClient.shared.saveReminders(preserved + fastingReminders)
            reminders = saved
            return nil
        } catch {
            return friendlyFastingError(error, fallback: "计划已保存，提醒稍后会再同步。")
        }
    }

    private func fastingReminderTimes() -> (eatingStart: String, fastingStart: String) {
        let eatingStart = normalizedClock(prefs.eatingWindowStart, fallback: "12:00")
        guard let eatingStartDate = nextDateForClock(eatingStart),
              let fastingStartDate = Calendar.current.date(byAdding: .hour, value: Int(max(1, prefs.eatingHours.rounded())), to: eatingStartDate)
        else {
            return (eatingStart, "20:00")
        }
        return (formatClock(eatingStartDate), formatClock(fastingStartDate))
    }

    private func normalizedClock(_ text: String, fallback: String) -> String {
        let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return fallback }
        let hour = min(23, max(0, parts[0]))
        let minute = min(59, max(0, parts[1]))
        return String(format: "%02d:%02d", hour, minute)
    }

    private func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func scheduleLocalNotification(id: String, title: String, body: String, date: Date) async {
        guard date.timeIntervalSinceNow > 60 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func scheduleDailyNotification(id: String, title: String, body: String, date: Date) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func nextDateForClock(_ text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return nil }
        let hour = min(23, max(0, parts[0]))
        let minute = min(59, max(0, parts[1]))
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        guard let today = calendar.date(from: components) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private func markerOffset(_ index: Int, ringSize: Double) -> CGSize {
        let high = ringSize * 0.37
        let low = ringSize * 0.37
        let side = ringSize * 0.45
        let x = ringSize * 0.31
        switch index {
        case 0: return CGSize(width: -x, height: -high)
        case 1: return CGSize(width: x, height: -high)
        case 2: return CGSize(width: side, height: -ringSize * 0.08)
        case 3: return CGSize(width: x, height: low)
        case 4: return CGSize(width: -x, height: low)
        default: return CGSize(width: -side, height: -ringSize * 0.08)
        }
    }

    private func stageIconName(_ stage: FastingStage, index: Int) -> String {
        switch stage.id {
        case "blood_sugar_rises": return "flame.fill"
        case "blood_sugar_drops": return "bolt.fill"
        case "fat_burning": return "flame.fill"
        case "ketosis": return "sparkles"
        case "autophagy": return "leaf.fill"
        default:
            let fallback = ["sparkles", "bolt.fill", "flame.fill", "drop.fill", "moon.fill"]
            return fallback[min(index, fallback.count - 1)]
        }
    }

    private func stageColor(_ stage: FastingStage, index: Int) -> Color {
        let fallback = ["111318", "8E949E", "111318", "159BFF", "6D7480"]
        return Color(hex: fallback[min(index, fallback.count - 1)])
    }

    private func presentManualFastSheet() {
        showHistorySheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            showManualFastSheet = true
        }
    }
}

private struct FastingPlanEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var prefs: FastingPreferences
    @Binding var selectedMethod: String

    let presets: [(String, String)]
    let busy: Bool
    let onSave: () async -> String?

    @State private var isSaving = false
    @State private var saveError = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                planEditorHeader
                planEditorPreview

                methodPresetStrip

                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("断食时长")
                                .font(.system(size: 17, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("绿色圆环按这个目标计算。")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(hex: "A4A9BB"))
                        }
                        Spacer()
                        Text("\(Int(prefs.fastingHours)) 小时")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                    }

                    fastingWindowPreview

                    Slider(value: Binding(
                        get: { prefs.fastingHours },
                        set: { value in
                            let rounded = min(24, max(12, value.rounded()))
                            prefs.fastingHours = rounded
                            prefs.eatingHours = max(1, 24 - rounded)
                            prefs.method = "\(Int(rounded)):\(Int(prefs.eatingHours))"
                            selectedMethod = prefs.method
                        }
                    ), in: 12...24, step: 1)
                    .tint(Color(hex: "72D3A2"))

                    eatingWindowRow
                    toggleRow(title: "提醒", subtitle: "开始、结束和进度提醒。", icon: "bell.fill", isOn: $prefs.remindersEnabled)
                    toggleRow(title: "显示断食状态", subtitle: "首页卡片和今日状态分会使用此设置。", icon: "timer", isOn: $prefs.enabled)
                }
                .padding(18)
                .softCard(radius: 24)

                Button {
                    Task {
                        guard !isSaving else { return }
                        isSaving = true
                        saveError = ""
                        let error = await onSave()
                        isSaving = false
                        if let error, !error.isEmpty {
                            saveError = error
                        } else {
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if busy || isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                        Text("保存计划")
                    }
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(Color(hex: "72D3A2"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color(hex: "72D3A2").opacity(0.28), radius: 18, x: 0, y: 10)
                }
                .buttonStyle(.plain)
                .disabled(busy || isSaving)

                if !saveError.isEmpty {
                    Text(saveError)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "DC2626"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(hex: "FFF1F2"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(24)
            .padding(.bottom, 26)
        }
        .background(AppShellBackground())
    }

    private var planEditorHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("我的断食计划")
                .font(.system(size: 29, weight: .black))
                .foregroundStyle(Color(hex: "24395F"))
            Text("选择圆环上显示的断食窗口，保存后首页同步轻断食状态。")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "9EA3B8"))
                .lineLimit(2)
        }
    }

    private var planEditorPreview: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color(hex: "BFEFD9"), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: min(1, max(0, prefs.fastingHours / 24)))
                    .stroke(Color(hex: "72D3A2"), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(Int(prefs.fastingHours))")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(Color(hex: "24395F"))
                    Text("小时")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "9EA3B8"))
                }
            }
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("计划")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "9EA3B8"))
                    Text(selectedMethod)
                        .font(.system(size: 21, weight: .black))
                        .foregroundStyle(Color(hex: "72D3A2"))
                }
                Text("进食 \(Int(prefs.eatingHours)) 小时 · 从 \(prefs.eatingWindowStart) 开始")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "24395F"))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    planChip("提醒", prefs.remindersEnabled ? "开" : "关")
                    planChip("首页", prefs.enabled ? "显示" : "隐藏")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color(hex: "EDF0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 18, x: 0, y: 10)
    }

    private var methodPresetStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("断食方案")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "24395F"))
                Spacer()
                Text(selectedMethod)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "72D3A2"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "EAFBF2"))
                    .clipShape(Capsule())
            }
            HStack(spacing: 10) {
                ForEach(presets, id: \.0) { item in
                    planMethodButton(method: item.0, label: item.1)
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "EDF0F3"), lineWidth: 1))
    }

    private func planMethodButton(method: String, label: String) -> some View {
        let selected = selectedMethod == method
        return Button {
            selectedMethod = method
            let hours = methodHours(method)
            prefs.method = method
            prefs.fastingHours = hours.fasting
            prefs.eatingHours = hours.eating
        } label: {
            VStack(spacing: 4) {
                Text(method)
                    .font(.system(size: 17, weight: .black))
                Text(label)
                    .font(.system(size: 11, weight: .black))
                    .opacity(selected ? 0.86 : 0.62)
            }
            .foregroundStyle(selected ? .white : Color(hex: "24395F"))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(selected ? Color(hex: "111318") : Color(hex: "F8F9FB"))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Color(hex: "111318") : Color(hex: "EEF0F3"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var fastingWindowPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                planTimelineEndpoint(title: "开始断食", value: plannedFastingStartLabel)
                Rectangle()
                    .fill(Color(hex: "72D3A2"))
                    .frame(width: 1, height: 42)
                    .padding(.horizontal, 3)
                planTimelineEndpoint(title: "结束断食", value: plannedFastingEndLabel)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: "EEF0F3"))
                    Capsule()
                        .fill(Color(hex: "BFEFD9"))
                        .frame(width: proxy.size.width * CGFloat(min(1, max(0, prefs.fastingHours / 24))))
                    Circle()
                        .fill(Color(hex: "72D3A2"))
                        .frame(width: 16, height: 16)
                        .offset(x: max(0, proxy.size.width * CGFloat(min(1, max(0, prefs.fastingHours / 24))) - 8))
                }
            }
            .frame(height: 8)
        }
        .padding(13)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func planTimelineEndpoint(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "A4A9BB"))
            Text(value)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "24395F"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eatingWindowRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Color(hex: "72D3A2"))
                .frame(width: 40, height: 40)
                .background(Color(hex: "EAFBF2"))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("进食窗口开始")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("格式如 12:00，保存后同步计划")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "A4A9BB"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer()
            TextField("12:00", text: $prefs.eatingWindowStart)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .frame(width: 92, height: 42)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
        }
        .padding(12)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func toggleRow(title: String, subtitle: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "72D3A2"))
                    .frame(width: 40, height: 40)
                    .background(Color(hex: "EAFBF2"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "A4A9BB"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .tint(Color(hex: "72D3A2"))
        .padding(12)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var plannedFastingStartLabel: String {
        guard let eatingStart = clockDate(prefs.eatingWindowStart),
              let fastingStart = Calendar.current.date(byAdding: .minute, value: Int(max(1, prefs.eatingHours) * 60), to: eatingStart) else {
            return "今天 --:--"
        }
        return planDateLabel(fastingStart)
    }

    private var plannedFastingEndLabel: String {
        guard let eatingStart = clockDate(prefs.eatingWindowStart),
              let fastingStart = Calendar.current.date(byAdding: .minute, value: Int(max(1, prefs.eatingHours) * 60), to: eatingStart),
              let fastingEnd = Calendar.current.date(byAdding: .minute, value: Int(max(1, prefs.fastingHours) * 60), to: fastingStart) else {
            return "明天 --:--"
        }
        return planDateLabel(fastingEnd)
    }

    private func clockDate(_ text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = min(23, max(0, parts[0]))
        comps.minute = min(59, max(0, parts[1]))
        return Calendar.current.date(from: comps)
    }

    private func planDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "今天"
        } else if calendar.isDateInTomorrow(date) {
            day = "明天"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            day = formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return "\(day) \(formatter.string(from: date))"
    }

    private func planChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "A4A9BB"))
            Text(value)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "24395F"))
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func methodHours(_ method: String) -> (fasting: Double, eating: Double) {
        let parts = method.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (16, 8)
    }
}

private struct ManualFastAddSheet: View {
    let presets: [(String, String)]
    let onSaved: (FastingHistory) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var method: String
    @State private var fastingHours: Double
    @State private var startAt: Date
    @State private var endedAt: Date
    @State private var notes = ""
    @State private var saving = false
    @State private var errorMessage = ""

    init(
        selectedMethod: String,
        defaultHours: Double,
        presets: [(String, String)],
        onSaved: @escaping (FastingHistory) -> Void
    ) {
        self.presets = presets
        self.onSaved = onSaved
        let cleanHours = max(1, defaultHours)
        _method = State(initialValue: selectedMethod)
        _fastingHours = State(initialValue: cleanHours)
        _endedAt = State(initialValue: Date())
        _startAt = State(initialValue: Calendar.current.date(byAdding: .hour, value: -Int(round(cleanHours)), to: Date()) ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    headerCard
                    methodPicker
                    timeCard
                    notesCard
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "8E949E"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 110)
            }
            .background(AppShellBackground())
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 10) {
                        if saving {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(saving ? "正在保存" : "保存并计入历史")
                    }
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color(hex: "72D3A2"))
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.92))
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Color(hex: "111318"))
                }
                ToolbarItem(placement: .principal) {
                    Text("补记断食")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(hex: "111318"))
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: goalReached ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(goalReached ? Color(hex: "16A34A") : Color(hex: "F97316"))
                    .frame(width: 54, height: 54)
                    .background((goalReached ? Color(hex: "DCFCE7") : Color(hex: "FFF7ED")))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(fastResultTitle)
                        .font(.system(size: 29, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(fastResultBody)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: "8F94A8"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                fastSummaryPill(icon: "timer", title: "已断食", value: durationLabel)
                fastSummaryPill(icon: "target", title: "目标", value: "\(Int(round(fastingHours)))小时")
            }

            Text("保存后会更新连续天数、完成率和首页轻断食状态。")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "4B5563"))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "F7F8FB"))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard(radius: 28)
    }

    private var actualFastingHours: Double {
        max(0, endedAt.timeIntervalSince(startAt) / 3600)
    }

    private var goalReached: Bool {
        actualFastingHours + 0.01 >= fastingHours
    }

    private var fastResultTitle: String {
        goalReached ? "这段可以计入完成" : "这段还差一点"
    }

    private var fastResultBody: String {
        if goalReached {
            return "\(durationLabel) 已达到 \(method) 目标，保存后会进断食历史。"
        }
        let missing = max(0, fastingHours - actualFastingHours)
        return "当前 \(durationLabel)，离目标还差约 \(formatMissingHours(missing))。"
    }

    private func formatMissingHours(_ hours: Double) -> String {
        if hours < 1 {
            return "\(max(1, Int(round(hours * 60))))分钟"
        }
        let rounded = (hours * 10).rounded() / 10
        return rounded.rounded() == rounded ? "\(Int(rounded))小时" : String(format: "%.1f小时", rounded)
    }

    private func fastSummaryPill(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(goalReached ? Color(hex: "16A34A") : Color(hex: "F97316"))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "A0A6B8"))
                Text(value)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hex: "ECEEF2"), lineWidth: 1)
        )
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("计划")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: "111318"))
            HStack(spacing: 10) {
                ForEach(presets, id: \.0) { item in
                    Button {
                        method = item.0
                        let hours = methodHours(item.0)
                        fastingHours = hours.fasting
                    } label: {
                        VStack(spacing: 4) {
                            Text(item.0)
                                .font(.system(size: 17, weight: .semibold))
                            Text(item.1)
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(method == item.0 ? .white : Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                        .background(method == item.0 ? Color(hex: "72D3A2") : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(method == item.0 ? Color(hex: "72D3A2") : Color(hex: "ECEEF2"), lineWidth: 1)
                        )
                        .shadow(color: method == item.0 ? Color(hex: "72D3A2").opacity(0.2) : .clear, radius: 12, x: 0, y: 7)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("改开始和结束时间")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            DatePicker("开始断食", selection: $startAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            Divider()
            DatePicker("结束断食", selection: $endedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color(hex: "111318"))
        .padding(20)
        .softCard(radius: 24)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("备注")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: "111318"))
            TextField("比如：昨晚 18:00 到今天 10:20", text: $notes, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .font(.system(size: 15, weight: .regular))
                .padding(14)
                .background(Color(hex: "F7F7F7"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(20)
        .softCard(radius: 24)
    }

    private var durationLabel: String {
        let seconds = max(0, endedAt.timeIntervalSince(startAt))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours)小时 \(minutes)分"
    }

    private func save() async {
        errorMessage = ""
        guard endedAt > startAt else {
            errorMessage = "结束时间必须晚于开始时间"
            return
        }
        saving = true
        defer { saving = false }
        do {
            let saved = try await APIClient.shared.addManualFasting(
                startAt: startAt,
                endedAt: endedAt,
                method: method,
                fastingHours: fastingHours,
                notes: notes
            )
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = manualFastingFriendlyError(error, fallback: "这段还没保存，检查网络后再点保存这段。")
        }
    }

    private func methodHours(_ method: String) -> (fasting: Double, eating: Double) {
        let parts = method.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (16, 8)
    }
}

private func manualFastingFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lowercased = raw.lowercased()
    if lowercased.contains("could not connect")
        || lowercased.contains("connection")
        || lowercased.contains("timed out")
        || raw.contains("连接不到")
        || raw.contains("无法连接")
        || raw.contains("网络") {
        return "现在没连上，这段还没保存。检查网络后再点保存这段。"
    }
    if lowercased.contains("not found") || raw.contains("404") {
        return "这段记录暂时没找到，返回后刷新列表。"
    }
    if raw.hasPrefix("{") || raw.hasPrefix("[") || raw.count > 120 || lowercased.contains("json") {
        return fallback
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
        return fallback
    }
    return raw
}

private struct FastingNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var notes: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(Color(hex: "DDE2EA"))
                .frame(width: 46, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            HStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(hex: "72D3A2"))
                    .frame(width: 54, height: 54)
                    .background(Color(hex: "EAFBF2"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("本次备注")
                        .font(.system(size: 27, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("结束断食时会一起保存")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "A9ADC2"))
                }
                Spacer()
            }

            TextEditor(text: $draft)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color(hex: "111318"))
                .padding(12)
                .frame(minHeight: 128)
                .scrollContentBackground(.hidden)
                .background(Color(hex: "F7F8FB"))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(hex: "E4E8F0"), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("例如：今天喝了黑咖啡，晚上有点饿。")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: "B0B6C5"))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                Button {
                    draft = ""
                    notes = ""
                    dismiss()
                } label: {
                    Text("清空")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "8D95A6"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(hex: "F4F5F8"))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    notes = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                } label: {
                    Text("保存备注")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(hex: "72D3A2"))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .onAppear { draft = notes }
    }
}

private struct FastingHistoryDetailsSheet: View {
    let history: FastingHistory?
    let activeSession: FastingSession?
    let now: Date
    let targetHours: Double
    let onClose: () -> Void
    let onAddFast: () -> Void
    let onRefresh: () -> Void

    @State private var detailMode = "overview"

    private var sessions: [FastingSession] { history?.sessions ?? [] }
    private var summary: FastingHistorySummary? { history?.summary }

    var body: some View {
        ZStack {
            AppShellBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader
                    historyHeroCard
                    chartCard
                    actionRow
                    if detailMode == "overview" {
                        summaryGrid
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        summaryGrid
                        sessionList
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 52)
            }
        }
    }

    private var historyHeroCard: some View {
        let completed = summary?.completedSessions ?? sessions.filter { $0.status == "completed" }.count
        let total = summary?.totalSessions ?? sessions.count
        let average = summary?.averageHours ?? 0
        let streak = summary?.currentStreak ?? 0
        let completionRate = summary?.completionRate ?? 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color(hex: "DDF6E9"), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: min(1, Double(completionRate) / 100))
                        .stroke(Color(hex: "72D3A2"), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(completionRate)%")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "24395F"))
                            .monospacedDigit()
                        Text("达成")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "A5A8BA"))
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 8) {
                    Text("本周断食节奏")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Color(hex: "24395F"))
                    Text("\(fastingDateRangeLabel()) · 目标 \(Int(round(targetHours))) 小时")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "A5A8BA"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                    HStack(spacing: 8) {
                        historyHeroPill("平均", "\(String(format: "%.1f", average))小时")
                        historyHeroPill("连续", "\(streak)天")
                        historyHeroPill("记录", "\(completed)/\(max(total, completed))")
                    }
                }
            }

            if let activeSession {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color(hex: "72D3A2"))
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前断食进行中")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "24395F"))
                        Text("\(dateLine(activeSession)) · 已 \(formatDuration(activeSession.elapsedSeconds ?? 0))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: "8E949E"))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(activeSession.method ?? "断食")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "72D3A2"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color(hex: "EAFBF2"))
                        .clipShape(Capsule())
                }
                .padding(12)
                .background(Color(hex: "F6FCF9"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(18)
        .softCard(radius: 28)
    }

    private func historyHeroPill(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "24395F"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color(hex: "A5A8BA"))
        }
        .padding(.horizontal, 9)
        .frame(height: 42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "F8F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detailHeader: some View {
        CalPageHeader(
            title: "断食统计",
            subtitle: "连续、平均和历史记录",
            systemImage: "chart.bar.fill"
        ) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.78))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭断食统计")
        }
    }

    private func detailHeaderPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 66, height: 54)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var chartCard: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { index in
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(Color(hex: "EDEEF2"))
                                    .frame(height: 1)
                                Text("\((6 - index) * 4)小时")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(Color(hex: "A5A8BA"))
                                    .frame(width: 42, alignment: .trailing)
                            }
                            if index < 6 { Spacer() }
                        }
                    }
                    .padding(.bottom, 30)

                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(lastSevenDays(), id: \.self) { day in
                            let hours = fastingHours(for: day)
                            let displayHours = min(24.0, max(0, hours))
                            let hourLabel = hours > 24 ? "24小时+" : (hours > 0 ? "\(Int(round(hours)))小时" : "")
                            VStack(spacing: 8) {
                                Spacer()
                                Text(hourLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hex: "A5A8BA"))
                                    .frame(height: 16)
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(hours >= targetHours ? Color(hex: "111318") : (hours > 0 ? Color(hex: "AEB6C2") : Color(hex: "F8F8F8")))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .stroke(Color(hex: "DFDFE2"), lineWidth: hours > 0 ? 0 : 1.2)
                                    )
                                    .frame(width: 38, height: max(18, min(proxy.size.height - 60, CGFloat(displayHours / 24.0) * (proxy.size.height - 62))))
                                Text(shortWeekday(day))
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(Color(hex: "A8AABE"))
                                    .frame(height: 18)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.trailing, 34)
                }
            }
            .frame(height: 204)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    chartLegend(color: Color(hex: "111318"), text: "已达标")
                    chartLegend(color: Color(hex: "AEB6C2"), text: "未达标")
                    chartLegend(color: Color(hex: "E5E7EB"), text: "轻松日")
                }
                chartLegend(color: Color(hex: "F4F4F4"), text: "计划断食")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .softCard(radius: 26)
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            Button(action: onAddFast) {
                HStack(spacing: 12) {
                    Text("补记断食")
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(Color(hex: "72D3A2"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    detailMode = "history"
                }
                onRefresh()
            } label: {
                HStack(spacing: 12) {
                    Text("历史")
                    Image(systemName: "pencil")
                        .accessibilityHidden(true)
                }
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(detailMode == "history" ? .white : Color(hex: "111318"))
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(detailMode == "history" ? Color(hex: "72D3A2") : .white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(detailMode == "history" ? Color(hex: "72D3A2") : Color(hex: "E6E8EE"), lineWidth: 1.5))
                .shadow(color: detailMode == "history" ? Color(hex: "72D3A2").opacity(0.18) : .clear, radius: 12, x: 0, y: 7)
            }
            .buttonStyle(.plain)
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            statTile("平均", "\(String(format: "%.1f", summary?.averageHours ?? 0))小时")
            statTile("完成次数", "\(summary?.completedSessions ?? sessions.filter { $0.status == "completed" }.count)")
            statTile("当前连续", "\(summary?.currentStreak ?? 0)天")
            statTile("最长连续", "\(summary?.longestStreak ?? 0)天")
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近断食")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(Color(hex: "24395F"))
                Spacer()
                Text("\(sessions.count + (activeSession == nil ? 0 : 1)) 条")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "A5A8BA"))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Capsule())
            }
            if sessions.isEmpty && activeSession == nil {
                Text("先开始一次断食")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: "A5A8BA"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                if let activeSession {
                    sessionRow(activeSession, isActive: true)
                }
                ForEach(sessions.prefix(12)) { session in
                    sessionRow(session, isActive: false)
                }
            }
        }
    }

    private func sessionRow(_ session: FastingSession, isActive: Bool) -> some View {
        let targetSeconds = max(1, session.targetSeconds ?? Int(targetHours * 3600))
        let elapsedSeconds = max(0, session.elapsedSeconds ?? 0)
        let progress = min(1, Double(elapsedSeconds) / Double(targetSeconds))
        let accent = isActive || session.status == "completed" ? Color(hex: "72D3A2") : Color(hex: "A5A8BA")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    Circle()
                        .stroke(accent.opacity(0.16), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: isActive ? "timer" : (session.status == "completed" ? "checkmark" : "clock"))
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(isActive ? "当前断食" : (session.method ?? "断食"))
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color(hex: "24395F"))
                            .lineLimit(1)
                        Text(isActive ? "进行中" : statusText(session.status))
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(isActive || session.status == "completed" ? Color(hex: "72D3A2") : Color(hex: "8E949E"))
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background((isActive || session.status == "completed" ? Color(hex: "EAFBF2") : Color(hex: "F4F5F7")))
                            .clipShape(Capsule())
                    }
                    Text(dateLine(session))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                    Text(sessionTimeRange(session))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "A5A8BA"))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(formatDuration(elapsedSeconds))
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "24395F"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)
                    Text("\(Int(round(progress * 100)))%")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "F0F2F5"))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(8, proxy.size.width * CGFloat(progress)))
                }
            }
            .frame(height: 7)
        }
        .padding(15)
        .softCard(radius: 22)
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 26, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "A5A8BA"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .softCard(radius: 22)
    }

    private func chartLegend(color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "A5A8BA"))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
    }

    private func lastSevenDays() -> [Date] {
        let calendar = Calendar.current
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: -6 + $0, to: now) }
    }

    private func fastingHours(for day: Date) -> Double {
        let key = dayKey(day)
        if let match = sessions.first(where: { session in
            guard let start = parseDate(session.startAt) else { return false }
            return dayKey(start) == key
        }) {
            return Double(match.elapsedSeconds ?? 0) / 3600.0
        }
        if Calendar.current.isDateInToday(day), let activeSession {
            if let start = parseDate(activeSession.startAt) {
                return max(0, now.timeIntervalSince(start)) / 3600.0
            }
            return Double(activeSession.elapsedSeconds ?? 0) / 3600.0
        }
        return 0
    }

    private func dateLine(_ session: FastingSession) -> String {
        guard let start = parseDate(session.startAt) else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 E"
        return formatter.string(from: start)
    }

    private func sessionTimeRange(_ session: FastingSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        let startText = parseDate(session.startAt).map { formatter.string(from: $0) } ?? "--:--"
        let endDate = parseDate(session.endedAt) ?? parseDate(session.targetEndAt)
        let endText = endDate.map { formatter.string(from: $0) } ?? "--:--"
        return "\(startText) - \(endText)"
    }

    private func fastingDateRangeLabel() -> String {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: start)) - \(formatter.string(from: now))"
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    private func parseDate(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if !text.contains("Z") && !text.contains("+") {
            text += "+08:00"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        if hours <= 0 { return "\(minutes)分" }
        return "\(hours)小时 \(minutes)分"
    }

    private func statusText(_ status: String?) -> String {
        switch status {
        case "completed": return "已完成"
        case "ended_early": return "提前结束"
        case "canceled": return "已取消"
        case "active": return "进行中"
        default: return "已保存"
        }
    }
}

private struct FastingStageDetailSheet: View {
    let stage: FastingStage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: iconName)
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 54, height: 54)
                        .background(Color(hex: "F5F6F8"))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stage.label ?? "身体阶段")
                            .font(.system(size: 24, weight: .black))
                        Text(stage.windowLabel ?? "断食阶段说明")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(stage.description ?? "开始断食后，会根据当前已断食时长展示身体状态变化。")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineSpacing(5)

                if let advice = stage.advice, !advice.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("建议")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(advice)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(hex: "111318"))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "F2F4F7"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("怎么理解")
                        .font(.system(size: 16, weight: .black))
                    Text(detailText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "4B5563"))
                        .lineSpacing(5)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "F8F9FB"))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(22)
            .padding(.bottom, 24)
        }
        .background(AppShellBackground())
    }

    private var iconName: String {
        switch stage.id {
        case "blood_sugar_rises": return "chart.line.uptrend.xyaxis"
        case "blood_sugar_drops": return "arrow.down.heart"
        case "fat_burning": return "flame.fill"
        case "ketosis": return "sparkles"
        case "autophagy": return "leaf.fill"
        default: return "timer"
        }
    }

    private var detailText: String {
        switch stage.id {
        case "blood_sugar_rises":
            return "刚开始断食时，身体仍在处理上一餐带来的能量。这个阶段更适合保持轻活动和稳定饮水，避免刚开始就用高强度运动硬扛饥饿。"
        case "blood_sugar_drops":
            return "随着进食间隔变长，血糖和胰岛素通常会回落，饥饿感可能出现波动。喝水、无糖茶或散步能帮助平稳过渡。"
        case "fat_burning":
            return "当可快速利用的能量减少后，身体会更多动用脂肪供能。这个阶段要重点避免含糖饮料和零食打断断食。"
        case "ketosis":
            return "较长时间断食后，部分人会进入更明显的脂肪供能状态。若头晕、心慌或不适，应及时结束并补充正餐。"
        case "autophagy":
            return "这是更长断食窗口的理论阶段，个体差异很大。产品只作为状态提醒，不替代医学建议。"
        default:
            return "这个阶段根据你的断食开始时间、目标时长和当前进度计算。实际感受会受上一餐、睡眠、运动和压力影响。"
        }
    }
}
