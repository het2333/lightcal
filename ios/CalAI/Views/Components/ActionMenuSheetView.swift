import SwiftUI

struct ActionMenuSheetView: View {
    let isOpen: Bool
    let waterMl: Double
    let waterGoalMl: Double
    let logDate: String
    let activeChallengeTitle: String?
    let activeChallengeProgress: Double?
    let onClose: () -> Void
    let onScan: () -> Void
    let onBarcode: () -> Void
    let onLabel: () -> Void
    let onManual: () -> Void
    let onSearch: () -> Void
    let onExercise: () -> Void
    let onAddDrink: (Double, String) -> Void
    let onHydrationChanged: () -> Void
    let onVoice: (String) -> Void

    @State private var showDrinkDetails = false
    @State private var showMoreFoodTools = false
    @State private var busyDrink = ""
    @State private var voiceText = ""
    @State private var drinkPresets: [DrinkPreset] = []
    @State private var hydrationLogs: [HydrationLog] = []
    @State private var hydrationSummary: HydrationSummary?
    @State private var hydrationGoalOverrideMl: Double?
    @State private var isLoadingHydration = false
    @State private var deletingHydrationId = ""
    @State private var isClearingHydration = false
    @State private var hydrationError: String?
    @State private var showGoalEditor = false
    @State private var hydrationGoalDraft = ""
    @State private var isSavingHydrationGoal = false
    @State private var showPresetEditor = false
    @State private var customPresetName = ""
    @State private var customPresetAmount = "250"
    @State private var customPresetFactor = "1.0"
    @State private var customPresetCaffeine = "0"
    @State private var customPresetSugar = "0"
    @State private var customPresetCalories = "0"

    private var effectiveWaterMl: Double {
        hydrationSummary?.hydrationEffectiveMl ?? waterMl
    }

    private var effectiveWaterGoalMl: Double {
        hydrationGoalOverrideMl ?? hydrationSummary?.hydrationGoalMl ?? waterGoalMl
    }

    private var hydrationPercent: Int {
        let pct = effectiveWaterMl / max(1, effectiveWaterGoalMl) * 100
        return max(0, min(100, Int(round(pct))))
    }

    private var hydrationDateKey: String {
        HydrationRuntimeCache.normalizedDateKey(logDate)
    }

    private var selectedDateLabel: String {
        let dateKey = hydrationDateKey
        if dateKey == HydrationRuntimeCache.todayDateKey() {
            return "今日"
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateKey) else {
            return "所选日期"
        }
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                if isOpen {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture(perform: onClose)

                    VStack {
                        Spacer()
                        menuSheet(maxHeight: menuMaxHeight(for: proxy.size.height, safeAreaBottom: proxy.safeAreaInsets.bottom))
                            .padding(.horizontal, 18)
                            .padding(.bottom, menuBottomPadding(for: proxy.safeAreaInsets.bottom))
                    }
                    .transition(.scale(scale: 0.95, anchor: .bottom).combined(with: .opacity).combined(with: .move(edge: .bottom)))

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(LinearGradient(colors: [Color(hex: "1D2026"), Color(hex: "0E1115")], startPoint: .top, endPoint: .bottom))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 14)
                    }
                    .accessibilityLabel("关闭快捷入口")
                    .padding(.trailing, 26)
                    .padding(.bottom, closeButtonBottomPadding(for: proxy.safeAreaInsets.bottom))
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isOpen)
        .onChange(of: isOpen) { _, isOpen in
            if isOpen && showDrinkDetails {
                Task { await loadHydrationDetails() }
            } else if !isOpen {
                showMoreFoodTools = false
            }
        }
        .alert("饮水还没保存", isPresented: Binding(
            get: { hydrationError != nil },
            set: { if !$0 { hydrationError = nil } }
        )) {
            Button("先保留，稍后再记", role: .cancel) {
                hydrationError = nil
            }
        } message: {
            Text(hydrationError ?? "这杯还没记到今天，检查网络后再点 +250毫升。")
        }
    }

    private func menuSheet(maxHeight: CGFloat) -> some View {
        Group {
            if shouldScrollMenu {
                ScrollView(showsIndicators: false) {
                    menuContent
                }
                .frame(maxHeight: maxHeight)
            } else {
                menuContent
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32).stroke(.white.opacity(0.82), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 32, x: 0, y: 18)
    }

    private func menuMaxHeight(for height: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
        max(320, min(height - safeAreaBottom - 210, height * 0.68))
    }

    private func menuBottomPadding(for safeAreaBottom: CGFloat) -> CGFloat {
        max(14, safeAreaBottom - 12)
    }

    private func closeButtonBottomPadding(for safeAreaBottom: CGFloat) -> CGFloat {
        max(10, safeAreaBottom - 22)
    }

    private var shouldScrollMenu: Bool {
        showDrinkDetails || showPresetEditor
    }

    private var menuContent: some View {
        VStack(spacing: 7) {
            scanCard
            quickActionPanel
            drinkCard
        }
        .padding(6)
    }

    private var scanCard: some View {
        Button(action: onScan) {
            HStack(spacing: 13) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [Color(hex: "1D2026"), Color(hex: "0E1115")], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("扫描食物")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .lineLimit(1)
                        Text("最推荐")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "0F7A46"))
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color(hex: "E8F8EF"))
                            .clipShape(Capsule())
                    }
                    Text("AI 分析你的食物")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
            .padding(8)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12)
        }
        .buttonStyle(.plain)
    }

    private var quickActionPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                compactAction(
                    icon: "square.and.pencil",
                    title: "手动记",
                    subtitle: "自己填",
                    action: onManual
                )
                compactAction(
                    icon: "magnifyingglass",
                    title: "搜食物",
                    subtitle: "按名称",
                    action: onSearch
                )
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showMoreFoodTools.toggle()
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .black))
                            .accessibilityHidden(true)
                        Text(showMoreFoodTools ? "收起" : "更多")
                            .font(.system(size: 11, weight: .black))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 64, height: 52)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showMoreFoodTools ? "收起其他记录方式" : "展开其他记录方式")
            }

            if showMoreFoodTools {
                HStack(spacing: 7) {
                    pillAction(icon: "barcode.viewfinder", title: "扫条码", action: onBarcode)
                    pillAction(icon: "list.clipboard", title: "拍营养表", action: onLabel)
                    pillAction(icon: "figure.run", title: "记运动", action: onExercise)
                    pillAction(icon: "mic.fill", title: "语音记", action: { onVoice("") })
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func compactAction(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func pillAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(Color(hex: "111318"))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var drinkCard: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                compactWaterLevel

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                    Text("饮水")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("\(hydrationPercent)%")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "159BFF"))
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color(hex: "EAF4FF"))
                            .clipShape(Capsule())
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(round(effectiveWaterMl)))")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("/\(Int(round(effectiveWaterGoalMl)))毫升")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                    Text(drinkCardSubtitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showDrinkDetails.toggle()
                    if showDrinkDetails {
                        Task { await loadHydrationDetails(force: true) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showDrinkDetails ? 180 : 0))
                        .frame(width: 34, height: 34)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityLabel(showDrinkDetails ? "收起饮水详情" : "展开饮水详情")
            }

            if let latest = hydrationLogs.first {
                HStack(spacing: 8) {
                    Image(systemName: symbolName(forDrinkType: latest.drinkType))
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "159BFF"))
                        .frame(width: 28, height: 28)
                        .background(Color(hex: "EAF4FF"))
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    Text("上次 \(displayName(forDrinkType: latest.drinkType)) \(Int(round(latest.amountMl)))毫升")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "555A62"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 6)
                    Button {
                        Task { await deleteHydrationLog(latest.id) }
                    } label: {
                        if deletingHydrationId == latest.id {
                            ProgressView()
                                .tint(Color(hex: "159BFF"))
                        } else {
                            Text("撤销")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(Color(hex: "159BFF"))
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(.white)
                                .clipShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!deletingHydrationId.isEmpty || isClearingHydration)
                    .accessibilityLabel("撤销上次饮品")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(hex: "F8FBFF"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            compactHydrationQuickAdd

            if showDrinkDetails {
                VStack(spacing: 12) {
                    VStack(spacing: 7) {
                        HStack(spacing: 8) {
                            hydrationMiniMetric(label: "已喝", value: "\(Int(round(hydrationSummary?.hydrationMl ?? effectiveWaterMl)))毫升")
                            hydrationMiniMetric(label: "有效补水", value: "\(Int(round(effectiveWaterMl)))毫升")
                            hydrationMiniMetric(label: "目标", value: "\(Int(round(effectiveWaterGoalMl)))毫升")
                        }

                        HStack(spacing: 10) {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(hex: "EAF4FF"))
                                    Capsule()
                                        .fill(LinearGradient(
                                            colors: [Color(hex: "159BFF"), Color(hex: "6DD4FF")],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ))
                                        .frame(width: proxy.size.width * CGFloat(hydrationPercent) / 100)
                                }
                            }
                            .frame(height: 7)
                            Text("剩余 \(Int(round(max(0, effectiveWaterGoalMl - effectiveWaterMl))))毫升")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color(hex: "159BFF"))
                                .lineLimit(1)
                        }

                        HStack(spacing: 7) {
                            ForEach([150, 250, 350, 500], id: \.self) { amount in
                                Button {
                                    Task { await logDrink(amount: Double(amount), type: "water") }
                                } label: {
                                    if busyDrink == "water" {
                                        ProgressView()
                                            .tint(Color(hex: "159BFF"))
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Text("+\(amount)")
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundStyle(amount == 250 ? .white : Color(hex: "159BFF"))
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .frame(height: 30)
                                .background(amount == 250 ? Color(hex: "159BFF") : Color(hex: "F1F8FF"))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .disabled(!busyDrink.isEmpty)
                            }
                        }
                    }
                    .padding(9)
                    .background(Color(hex: "F8FBFF"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if isLoadingHydration && drinkPresets.isEmpty {
                        ProgressView()
                            .tint(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(displayDrinkPresets) { preset in
                                drinkOption(preset: preset)
                            }
                        }
                    }

	                    hydrationRhythmCard

	                    hydrationGoalCard

	                    HStack(spacing: 8) {
	                        metricBox(label: "咖啡因", value: "\(Int(round(hydrationSummary?.caffeineMg ?? 0)))毫克")
                        metricBox(label: "酒精", value: "\(Int(round(hydrationSummary?.alcoholG ?? 0)))克")
                        metricBox(label: "饮品糖", value: "\(Int(round(hydrationSummary?.sugarG ?? 0)))克")
                    }

                    if !hydrationLogs.isEmpty {
                        VStack(spacing: 8) {
                            HStack {
                                Text("\(selectedDateLabel)饮品")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                Spacer()
                                Text("\(hydrationLogs.count) 条")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(.secondary)
                                Button {
                                    Task { await clearTodayHydration() }
                                } label: {
                                    if isClearingHydration {
                                        ProgressView()
                                            .tint(Color(hex: "DC2626"))
                                    } else {
                                        Text("清空")
                                            .font(.system(size: 11, weight: .black))
                                            .foregroundStyle(Color(hex: "DC2626"))
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isClearingHydration || !deletingHydrationId.isEmpty)
                                .accessibilityLabel("清空\(selectedDateLabel)饮品")
                            }

                            ForEach(hydrationLogs.prefix(4)) { log in
                                hydrationLogRow(log)
                            }
                        }
                        .padding(12)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    if let activeChallengeTitle, !activeChallengeTitle.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(activeChallengeTitle)
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Int(round(activeChallengeProgress ?? 0)))%")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(Color(hex: "111318"))
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(.white)
                                    Capsule()
                                        .fill(Color(hex: "111318"))
                                        .frame(width: proxy.size.width * min(100, max(0, activeChallengeProgress ?? 0)) / 100)
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(12)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showPresetEditor.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .accessibilityHidden(true)
                    Text("添加常喝饮品")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showPresetEditor ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                .accessibilityLabel(showPresetEditor ? "收起常喝饮品设置" : "展开常喝饮品设置")
                    .buttonStyle(.plain)

                    if showPresetEditor {
                        customPresetEditor
                    }

                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            TextField("喝了 500毫升水，一杯拿铁", text: $voiceText)
                                .font(.system(size: 12, weight: .bold))
                                .textInputAutocapitalization(.never)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Button {
                            let text = voiceText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            voiceText = ""
                            onVoice(text)
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color(hex: "159BFF"))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .accessibilityHidden(true)
                        }
                        .opacity(voiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                        .accessibilityLabel("发送饮水描述")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(9)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 12)
    }

    private var compactHydrationQuickAdd: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: "EAF4FF"))
                    Capsule()
                        .fill(Color(hex: "159BFF"))
                        .frame(width: proxy.size.width * CGFloat(hydrationPercent) / 100)
                }
            }
            .frame(height: 7)

            Button {
                Task { await logDrink(amount: 250, type: "water") }
            } label: {
                if busyDrink == "water" {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 92)
                } else {
                    Text("+250毫升")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 92)
                }
            }
            .frame(height: 34)
            .background(Color(hex: "159BFF"))
            .clipShape(Capsule())
            .disabled(!busyDrink.isEmpty)
            .accessibilityLabel("记录喝水250毫升")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(hex: "F8FBFF"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var compactWaterLevel: some View {
        let progress = CGFloat(hydrationPercent) / 100
        return VStack(spacing: 0) {
            Capsule()
                .fill(Color(hex: "E8F5FF"))
                .frame(width: 22, height: 7)
                .overlay(Capsule().stroke(Color(hex: "C7E8FF"), lineWidth: 1))
                .offset(y: 2)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(hex: "F2FAFF"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(hex: "D8EEFF"), lineWidth: 1.4)
                    )
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.clear)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: "159BFF"), Color(hex: "70D6FF")],
                                startPoint: .bottom,
                                endPoint: .top
                            ))
                            .frame(height: max(6, proxy.size.height * progress))
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(.white.opacity(0.34))
                                    .frame(width: 24, height: 4)
                                    .padding(.top, 6)
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(3)

                VStack(spacing: 2) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(progress > 0.52 ? .white : Color(hex: "159BFF"))
                        .accessibilityHidden(true)
                    Text("\(hydrationPercent)%")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(progress > 0.52 ? .white.opacity(0.9) : Color(hex: "159BFF"))
                }
            }
            .frame(width: 42, height: 50)
        }
        .frame(width: 44, height: 58)
        .accessibilityHidden(true)
    }

    private var drinkCardSubtitle: String {
        guard let latest = hydrationLogs.first else {
            return "点 +250 立刻记水"
        }
        let time = displayTime(latest.loggedAt)
        let name = displayName(forDrinkType: latest.drinkType)
        return time.isEmpty ? "上次 \(name) \(Int(round(latest.amountMl)))毫升" : "上次 \(time) · \(name)"
    }

    private var displayDrinkPresets: [DrinkPreset] {
        if drinkPresets.isEmpty {
            return Self.fallbackPresets
        }
        let preferred = ["water", "tea", "coffee", "latte", "milk", "juice", "sparkling_water", "energy_drink", "alcohol"]
        return drinkPresets.sorted { left, right in
            let leftIndex = preferred.firstIndex(of: left.drinkType) ?? 999
            let rightIndex = preferred.firstIndex(of: right.drinkType) ?? 999
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return left.name < right.name
        }
        .prefix(9)
        .map { $0 }
    }

    private static let fallbackPresets: [DrinkPreset] = [
        DrinkPreset(id: "water", drinkType: "water", name: "水", defaultAmountMl: 250, hydrationFactor: 1, caffeineMg: 0, alcoholG: 0, sugarG: 0, calories: 0, color: "#159BFF", icon: "drop", custom: false),
        DrinkPreset(id: "sparkling_water", drinkType: "sparkling_water", name: "气泡水", defaultAmountMl: 250, hydrationFactor: 1, caffeineMg: 0, alcoholG: 0, sugarG: 0, calories: 0, color: "#159BFF", icon: "bubbles", custom: false),
        DrinkPreset(id: "tea", drinkType: "tea", name: "茶", defaultAmountMl: 240, hydrationFactor: 0.9, caffeineMg: 35, alcoholG: 0, sugarG: 0, calories: 0, color: "#111318", icon: "leaf", custom: false),
        DrinkPreset(id: "coffee", drinkType: "coffee", name: "咖啡", defaultAmountMl: 240, hydrationFactor: 0.85, caffeineMg: 95, alcoholG: 0, sugarG: 0, calories: 0, color: "#6D7480", icon: "coffee", custom: false),
        DrinkPreset(id: "latte", drinkType: "latte", name: "拿铁", defaultAmountMl: 300, hydrationFactor: 0.85, caffeineMg: 75, alcoholG: 0, sugarG: 10, calories: 150, color: "#6D7480", icon: "coffee", custom: false),
        DrinkPreset(id: "milk", drinkType: "milk", name: "牛奶", defaultAmountMl: 250, hydrationFactor: 0.9, caffeineMg: 0, alcoholG: 0, sugarG: 12, calories: 130, color: "#B8C7D9", icon: "milk", custom: false),
        DrinkPreset(id: "juice", drinkType: "juice", name: "果汁", defaultAmountMl: 250, hydrationFactor: 0.8, caffeineMg: 0, alcoholG: 0, sugarG: 24, calories: 110, color: "#9AA3AF", icon: "juice", custom: false),
        DrinkPreset(id: "energy_drink", drinkType: "energy_drink", name: "能量饮料", defaultAmountMl: 250, hydrationFactor: 0.75, caffeineMg: 80, alcoholG: 0, sugarG: 27, calories: 115, color: "#111318", icon: "bolt", custom: false),
        DrinkPreset(id: "alcohol", drinkType: "alcohol", name: "酒精饮品", defaultAmountMl: 330, hydrationFactor: 0.45, caffeineMg: 0, alcoholG: 13, sugarG: 3, calories: 140, color: "#6D7480", icon: "wineglass", custom: false),
    ]

    private func drinkOption(preset: DrinkPreset) -> some View {
        let type = preset.drinkType
        let color = Color(hex: colorHex(forDrinkType: type))
        return Button {
            Task { await logDrink(amount: preset.defaultAmountMl, type: type) }
        } label: {
            VStack(spacing: 5) {
                if busyDrink == type {
                    ProgressView().tint(color)
                } else {
                    Image(systemName: symbolName(for: preset))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                Text(displayName(for: preset))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "555A62"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("\(Int(round(preset.defaultAmountMl)))毫升")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var hydrationRhythmCard: some View {
        let buckets = hydrationRhythmBuckets()
        let targetPerBucket = max(1, effectiveWaterGoalMl / Double(max(1, buckets.count)))
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedDateLabel)补水节奏")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(hydrationLogs.isEmpty ? "记录第一杯后会看到分时节奏。" : "按实际记录聚合有效补水。")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer()
                Text("\(hydrationLogs.count)杯")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(hex: "EAF4FF"))
                    .clipShape(Capsule())
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(buckets, id: \.label) { bucket in
                    VStack(spacing: 7) {
                        GeometryReader { proxy in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.white)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color(hex: "DDEFFF"), lineWidth: 1)
                                    )
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Color(hex: "159BFF"), Color(hex: "78D8FF")],
                                        startPoint: .bottom,
                                        endPoint: .top
                                    ))
                                    .frame(height: max(bucket.effectiveMl > 0 ? 8 : 0, proxy.size.height * CGFloat(min(1, bucket.effectiveMl / targetPerBucket))))
                            }
                        }
                        .frame(height: 58)

                        Text(bucket.label)
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "8E949E"))
                            .lineLimit(1)
                        Text("\(Int(round(bucket.effectiveMl)))")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(Color(hex: "F8FBFF"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var hydrationGoalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "target")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .frame(width: 30, height: 30)
                    .background(Color(hex: "EAF4FF"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("每日饮水目标")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("按有效补水量计算进度")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }

                Spacer()

                Text("\(Int(round(effectiveWaterGoalMl)))毫升")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .monospacedDigit()

                Button {
                    hydrationGoalDraft = "\(Int(round(effectiveWaterGoalMl)))"
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showGoalEditor.toggle()
                    }
                } label: {
                    Text(showGoalEditor ? "收起" : "调整")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "159BFF"))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color(hex: "EAF4FF"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if showGoalEditor {
                VStack(spacing: 9) {
                    HStack(spacing: 8) {
                        ForEach([1800, 2100, 2500, 3000], id: \.self) { goal in
                            Button {
                                hydrationGoalDraft = "\(goal)"
                            } label: {
                                Text("\(goal)")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(Int(Double(hydrationGoalDraft) ?? -1) == goal ? .white : Color(hex: "159BFF"))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .background(Int(Double(hydrationGoalDraft) ?? -1) == goal ? Color(hex: "159BFF") : .white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("目标毫升", text: $hydrationGoalDraft)
                            .keyboardType(.numberPad)
                            .font(.system(size: 12, weight: .black))
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                        Button {
                            Task { await saveHydrationGoal() }
                        } label: {
                            if isSavingHydrationGoal {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 74, height: 38)
                            } else {
                                Text("保存目标")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(.white)
                                    .frame(width: 82, height: 38)
                            }
                        }
                        .background(Color(hex: "111318"))
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .disabled(isSavingHydrationGoal)
                    }
                }
                .padding(10)
                .background(Color(hex: "F1F8FF"))
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color(hex: "F8FBFF"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func hydrationRhythmBuckets() -> [(label: String, effectiveMl: Double)] {
        var values: [String: Double] = [
            "上午": 0,
            "中午": 0,
            "下午": 0,
            "晚上": 0
        ]
        for log in hydrationLogs {
            let hour = hourFromLog(log.loggedAt)
            let key: String
            switch hour {
            case 5..<11:
                key = "上午"
            case 11..<15:
                key = "中午"
            case 15..<19:
                key = "下午"
            default:
                key = "晚上"
            }
            values[key, default: 0] += log.effectiveMl
        }
        return ["上午", "中午", "下午", "晚上"].map { ($0, values[$0] ?? 0) }
    }

    private func hourFromLog(_ loggedAt: String?) -> Int {
        guard let loggedAt, !loggedAt.isEmpty else { return Calendar.current.component(.hour, from: Date()) }
        let separators = CharacterSet(charactersIn: " T")
        let parts = loggedAt.components(separatedBy: separators).filter { !$0.isEmpty }
        let timePart = parts.last ?? loggedAt
        let hourText = timePart.split(separator: ":").first.map(String.init) ?? ""
        return Int(hourText) ?? Calendar.current.component(.hour, from: Date())
    }

    private func hydrationLogRow(_ log: HydrationLog) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName(forDrinkType: log.drinkType))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "159BFF"))
                .frame(width: 30, height: 30)
                .background(.white)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(forDrinkType: log.drinkType))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("有效 \(Int(round(log.effectiveMl)))毫升 · 糖 \(Int(round(log.sugarG)))克 · \(displayTime(log.loggedAt))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(Int(round(log.amountMl)))毫升")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            Button {
                Task { await deleteHydrationLog(log.id) }
            } label: {
                if deletingHydrationId == log.id {
                    ProgressView().tint(.secondary)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 30, height: 30)
            .background(.white)
            .clipShape(Circle())
            .accessibilityLabel("删除饮品记录")
        }
    }

    private var customPresetEditor: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                presetTextField("名称", text: $customPresetName)
                presetTextField("毫升", text: $customPresetAmount, keyboard: .decimalPad)
            }
            HStack(spacing: 8) {
                presetTextField("补水系数", text: $customPresetFactor, keyboard: .decimalPad)
                presetTextField("咖啡因毫克", text: $customPresetCaffeine, keyboard: .decimalPad)
            }
            HStack(spacing: 8) {
                presetTextField("糖克", text: $customPresetSugar, keyboard: .decimalPad)
                presetTextField("热量（千卡）", text: $customPresetCalories, keyboard: .decimalPad)
            }
            Button {
                Task { await saveCustomPreset() }
            } label: {
                Text("保存预设")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color(hex: "159BFF"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(customPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(customPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.42 : 1)
        }
        .padding(12)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func metricBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func hydrationMiniMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Color(hex: "8E949E"))
            Text(value)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func presetTextField(
        _ placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func logDrink(amount: Double, type: String) async {
        guard busyDrink.isEmpty else { return }
        busyDrink = type
        do {
            _ = try await APIClient.shared.addHydration(amountMl: amount, drinkType: type, date: logDate)
            onHydrationChanged()
            await loadHydrationDetails(force: true)
        } catch {
            hydrationError = actionMenuFriendlyError(error, fallback: "这杯饮品还没记上，检查网络后再点记录饮品。")
        }
        busyDrink = ""
    }

    private func loadHydrationDetails(force: Bool = false) async {
        guard !isLoadingHydration else { return }
        let dateKey = hydrationDateKey
        if !force, HydrationRuntimeCache.isFresh(dateKey: dateKey) {
            let cachedPresets = HydrationRuntimeCache.presets()
            if !cachedPresets.isEmpty {
                drinkPresets = cachedPresets
            }
            hydrationLogs = HydrationRuntimeCache.logs(dateKey: dateKey)
            hydrationSummary = HydrationRuntimeCache.summary(dateKey: dateKey) ?? hydrationSummary
            return
        }
        isLoadingHydration = true
        defer { isLoadingHydration = false }
        do {
            async let presets = APIClient.shared.getDrinkPresets()
            async let logs = APIClient.shared.getHydration(date: logDate)
            async let summary = APIClient.shared.getHydrationSummary(date: logDate)
            async let settings = APIClient.shared.getHydrationSettings()
            drinkPresets = (try? await presets) ?? drinkPresets
            hydrationLogs = (try? await logs) ?? hydrationLogs
            hydrationSummary = try? await summary
            if let loadedSettings = try? await settings {
                hydrationGoalOverrideMl = loadedSettings.hydrationGoalMl
                if hydrationGoalDraft.isEmpty {
                    hydrationGoalDraft = "\(Int(round(loadedSettings.hydrationGoalMl)))"
                }
            } else if let hydrationSummary {
                hydrationGoalOverrideMl = hydrationSummary.hydrationGoalMl
            }
            HydrationRuntimeCache.save(
                dateKey: dateKey,
                summary: hydrationSummary,
                logs: hydrationLogs,
                presets: drinkPresets
            )
        }
    }

    private func deleteHydrationLog(_ id: String) async {
        guard deletingHydrationId.isEmpty else { return }
        deletingHydrationId = id
        defer { deletingHydrationId = "" }
        do {
            let response = try await APIClient.shared.deleteHydration(ids: [id], date: logDate)
            if let summary = response.summary {
                hydrationSummary = summary
            }
            hydrationLogs.removeAll { $0.id == id }
            HydrationRuntimeCache.save(dateKey: hydrationDateKey, summary: hydrationSummary, logs: hydrationLogs)
            onHydrationChanged()
        } catch {
            hydrationError = actionMenuFriendlyError(error, fallback: "这条饮品暂时没删掉，返回后再删一次。")
        }
    }

    private func clearTodayHydration() async {
        guard !isClearingHydration else { return }
        isClearingHydration = true
        defer { isClearingHydration = false }
        do {
            let response = try await APIClient.shared.deleteHydration(
                ids: hydrationLogs.map(\.id),
                date: logDate
            )
            hydrationLogs = []
            hydrationSummary = response.summary
            HydrationRuntimeCache.save(dateKey: hydrationDateKey, summary: hydrationSummary, logs: hydrationLogs)
            onHydrationChanged()
        } catch {
            hydrationError = actionMenuFriendlyError(error, fallback: "今天的饮品暂时没清空，刷新后再清空。")
        }
    }

    private func saveHydrationGoal() async {
        guard !isSavingHydrationGoal else { return }
        let rawValue = Double(hydrationGoalDraft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? effectiveWaterGoalMl
        let goal = min(6000, max(500, rawValue.rounded()))
        hydrationGoalDraft = "\(Int(goal))"
        hydrationError = nil
        isSavingHydrationGoal = true
        defer { isSavingHydrationGoal = false }

        do {
            let settings = try await APIClient.shared.saveHydrationSettings(goalMl: goal)
            hydrationGoalOverrideMl = settings.hydrationGoalMl
            if let refreshedSummary = try? await APIClient.shared.getHydrationSummary(date: logDate) {
                hydrationSummary = refreshedSummary
                hydrationGoalOverrideMl = refreshedSummary.hydrationGoalMl
            }
            HydrationRuntimeCache.save(
                dateKey: hydrationDateKey,
                summary: hydrationSummary,
                logs: hydrationLogs,
                presets: drinkPresets
            )
            onHydrationChanged()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                showGoalEditor = false
            }
        } catch {
            hydrationError = actionMenuFriendlyError(error, fallback: "饮水目标暂时没保存，检查网络后再点保存。")
        }
    }

    private func saveCustomPreset() async {
        let name = customPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        hydrationError = nil
        do {
            let preset = try await APIClient.shared.addDrinkPreset(
                name: name,
                defaultAmountMl: Double(customPresetAmount) ?? 250,
                hydrationFactor: Double(customPresetFactor) ?? 1,
                caffeineMg: Double(customPresetCaffeine) ?? 0,
                sugarG: Double(customPresetSugar) ?? 0,
                calories: Double(customPresetCalories) ?? 0
            )
            drinkPresets.append(preset)
            HydrationRuntimeCache.save(
                dateKey: hydrationDateKey,
                summary: hydrationSummary,
                logs: hydrationLogs,
                presets: drinkPresets
            )
            customPresetName = ""
            customPresetAmount = "250"
            customPresetFactor = "1.0"
            customPresetCaffeine = "0"
            customPresetSugar = "0"
            customPresetCalories = "0"
            showPresetEditor = false
            await loadHydrationDetails(force: true)
        } catch {
            hydrationError = actionMenuFriendlyError(error, fallback: "这个常喝饮品暂时没保存，检查网络后再点保存。")
        }
    }

    private func symbolName(for preset: DrinkPreset) -> String {
        symbolName(forDrinkType: preset.drinkType)
    }

    private func symbolName(forDrinkType type: String) -> String {
        switch type {
        case "coffee", "latte":
            return "cup.and.saucer.fill"
        case "tea":
            return "leaf.fill"
        case "milk":
            return "drop.circle.fill"
        case "juice":
            return "sun.max.fill"
        case "energy_drink":
            return "bolt.fill"
        case "alcohol":
            return "wineglass.fill"
        case "sparkling_water":
            return "bubbles.and.sparkles.fill"
        default:
            return "drop.fill"
        }
    }

    private func displayName(forDrinkType type: String) -> String {
        displayName(forDrinkType: type, fallback: nil)
    }

    private func displayName(for preset: DrinkPreset) -> String {
        displayName(forDrinkType: preset.drinkType, fallback: preset.name)
    }

    private func displayName(forDrinkType type: String, fallback: String?) -> String {
        switch type {
        case "water": return "水"
        case "sparkling_water": return "气泡水"
        case "tea": return "茶"
        case "coffee": return "咖啡"
        case "latte": return "拿铁"
        case "milk": return "牛奶"
        case "juice": return "果汁"
        case "energy_drink": return "能量饮料"
        case "alcohol": return "酒精饮品"
        default:
            return fallback
                ?? drinkPresets.first { $0.drinkType == type || $0.id == type }?.name
                ?? Self.fallbackPresets.first { $0.drinkType == type || $0.id == type }?.name
                ?? "其他饮品"
        }
    }

    private func colorHex(forDrinkType type: String) -> String {
        switch type {
        case "water", "sparkling_water": return "159BFF"
        case "tea", "energy_drink": return "111318"
        case "coffee", "latte", "alcohol": return "6D7480"
        case "milk": return "B8C7D9"
        case "juice": return "9AA3AF"
        default: return "159BFF"
        }
    }

    private func displayTime(_ loggedAt: String?) -> String {
        guard let loggedAt, !loggedAt.isEmpty else { return "" }
        let parts = loggedAt.split(separator: " ")
        let timeText = parts.last.map(String.init) ?? loggedAt
        return String(timeText.prefix(5))
    }
}

private func actionMenuFriendlyError(_ error: Error, fallback: String) -> String {
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lower = raw.lowercased()
    if lower.contains("could not connect")
        || lower.contains("connection")
        || lower.contains("timed out")
        || lower.contains("network")
        || raw.contains("连接不到")
        || raw.contains("无法连接") {
        return "现在没连上，这次还没保存；检查网络后再点保存。"
    }
    if lower.contains("not found") || lower.contains("404") {
        return "这条记录暂时找不到，刷新列表。"
    }
    if lower.contains("cancelled") || raw.contains("取消") {
        return "刚才的操作已取消，没有改动记录。"
    }
    if raw.count > 80 || raw.contains("{") || raw.contains("}") {
        return fallback
    }
    if raw.contains("失败")
        || raw.contains("错误")
        || raw.contains("异常")
        || raw.contains("无法")
        || lower.contains("failed")
        || lower.contains("error")
        || lower.contains("exception") {
        return fallback
    }
    return raw
}
