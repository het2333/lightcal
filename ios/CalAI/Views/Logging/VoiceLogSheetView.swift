import SwiftUI
import Speech
import AVFoundation

enum VoiceLogEntryMode: String, Identifiable {
    case voice
    case text

    var id: String { rawValue }
}

@MainActor
final class MealSpeechInputController: NSObject, ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var statusMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func start() async {
        guard !isListening else { return }
        statusMessage = nil

        let authorization = await speechAuthorization()
        guard authorization == .authorized else {
            statusMessage = authorization == .denied
                ? "语音识别权限已关闭，可以在系统设置中允许“食光”使用语音识别。"
                : "现在不能使用语音识别，也可以直接输入文字。"
            return
        }

        let microphoneAllowed = await microphoneAuthorization()
        guard microphoneAllowed else {
            statusMessage = "麦克风权限已关闭，可以在系统设置中允许“食光”使用麦克风。"
            return
        }

        guard recognizer?.isAvailable == true else {
            statusMessage = "语音识别暂时不可用，写下来也能继续记录。"
            return
        }

        do {
            stopAudioSession(cancelTask: true)
            transcript = ""

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = false
            recognitionRequest = request

            guard let recognizer else {
                statusMessage = "语音识别暂时不可用。"
                return
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self.stopAudioSession(cancelTask: false)
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            stopAudioSession(cancelTask: true)
            statusMessage = "麦克风没有启动成功，可以再点一次或直接输入文字。"
        }
    }

    func stop() {
        stopAudioSession(cancelTask: true)
    }

    private func stopAudioSession(cancelTask: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func microphoneAuthorization() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        @unknown default:
            return false
        }
    }
}

struct VoiceLogSheetView: View {
    let initialText: String
    let entryMode: VoiceLogEntryMode
    let logDate: String
    let onClose: () -> Void
    let onApplied: () -> Void

    @State private var text: String
    @State private var mealCategory = ""
    @State private var foods: [VoiceParsedFood] = []
    @State private var hydration: [VoiceParsedDrink] = []
    @State private var confidence: Double?
    @State private var loading = false
    @State private var applying = false
    @State private var errorMessage: String?
    @State private var speechBaseText = ""
    @StateObject private var speech = MealSpeechInputController()

    private let meals = [
        ("", "自动"),
        ("breakfast", "早餐"),
        ("lunch", "午餐"),
        ("dinner", "晚餐"),
        ("snack", "加餐"),
    ]

    init(
        initialText: String = "",
        entryMode: VoiceLogEntryMode = .text,
        logDate: String = "",
        onClose: @escaping () -> Void,
        onApplied: @escaping () -> Void
    ) {
        self.initialText = initialText
        self.entryMode = entryMode
        self.logDate = logDate
        self.onClose = onClose
        self.onApplied = onApplied
        _text = State(initialValue: initialText)
    }

    private var foodCalories: Double {
        foods.reduce(0) { $0 + $1.calories }
    }

    private var drinkCalories: Double {
        hydration.reduce(0) { $0 + $1.calories }
    }

    private var parsedCalories: Double {
        foodCalories + drinkCalories
    }

    private var parsedWaterMl: Double {
        hydration.reduce(0) { $0 + $1.amountMl }
    }

    private var parsedItemsCount: Int {
        foods.count + hydration.count
    }

    private var validationMessage: String? {
        if let index = hydration.firstIndex(where: { !$0.amountMl.isFinite || $0.amountMl <= 0 }) {
            return "第 \(index + 1) 项饮品的毫升数必须大于 0。"
        }
        if let index = foods.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "请填写第 \(index + 1) 项食物的名称。"
        }
        if let food = foods.first(where: {
            [$0.calories, $0.protein, $0.carbs, $0.fat, $0.fiber, $0.sugar, $0.sodium]
                .contains(where: { !$0.isFinite || $0 < 0 })
        }) {
            return "\(food.name.isEmpty ? "食物" : food.name)的营养数值不能小于 0。"
        }
        return nil
    }

    private var hasParsedContent: Bool {
        parsedItemsCount > 0 || confidence != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppShellBackground()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 16) {
                            grabber
                            header
                            inputCard
                            mealPicker
                            if hasParsedContent {
                                quickSummaryCard
                                foodSection
                                hydrationSection
                            } else {
                                voiceTipCard
                            }
                            if let errorMessage {
                                voiceErrorCard(errorMessage)
                            }
                            if let validationMessage {
                                validationErrorCard(validationMessage)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 96)
                    }

                    footer
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await parse()
                } else if entryMode == .voice {
                    try? await Task.sleep(nanoseconds: 260_000_000)
                    await beginSpeechInput()
                }
            }
            .onChange(of: speech.transcript) { _, transcript in
                let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTranscript.isEmpty else { return }
                let cleanBase = speechBaseText.trimmingCharacters(in: .whitespacesAndNewlines)
                text = cleanBase.isEmpty ? cleanTranscript : "\(cleanBase)，\(cleanTranscript)"
            }
            .onChange(of: speech.statusMessage) { _, message in
                if let message, !message.isEmpty {
                    errorMessage = message
                }
            }
            .onDisappear {
                speech.stop()
            }
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: entryMode == .voice ? "mic.fill" : "text.bubble.fill")
                        .accessibilityHidden(true)
                    Text(entryMode == .voice ? "语音记录" : "文字描述")
                }
                .font(.system(size: 25, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                Text(entryMode == .voice ? "说出吃了什么，听写和营养结果都能修改。" : "写下吃了什么，整理成可修改的营养记录。")
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
            .accessibilityLabel("关闭文字记录")
        }
    }

    private var quickSummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("整理结果")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(parsedItemsCount > 0 ? (validationMessage == nil ? "\(parsedItemsCount) 项可保存" : "有 1 项需修改") : "先说一句")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color(hex: "73D39B"))
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }

            HStack(spacing: 10) {
                quickMetric(title: "热量", value: "\(Int(parsedCalories.rounded()))", unit: "千卡", icon: "flame.fill")
                quickMetric(title: "饮水", value: "\(Int(parsedWaterMl.rounded()))", unit: "毫升", icon: "drop.fill")
                quickMetric(title: "状态", value: confidence == nil ? "待" : "可", unit: confidence == nil ? "整理" : "修改", icon: "checkmark.seal.fill")
            }
        }
        .padding(18)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: "20252B"), Color(hex: "111318")], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [Color(hex: "159BFF").opacity(0.24), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 22, x: 0, y: 12)
    }

    private func quickMetric(title: String, value: String, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "73D39B"))
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(unit)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entryMode == .voice ? "说出这一餐" : "写下这一餐")
                    .font(.system(size: 15, weight: .black))
                Spacer()
                Text("保存前可改")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color(hex: "EAF4FF"))
                    .clipShape(Capsule())
            }
            TextEditor(text: $text)
                .font(.system(size: 15, weight: .semibold))
                .frame(minHeight: 106)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(entryMode == .voice ? "正在等你说话，例如：午餐一碗米饭、半份鸡胸肉" : "例：午餐一碗米饭、半份鸡胸肉，喝了300毫升水")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: "A8ADB7"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                    }
                }
            if speech.isListening {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: "E5484D"))
                        .frame(width: 8, height: 8)
                    Text("正在听，停顿时也会继续记录")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "E5484D"))
                    Spacer()
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { await toggleSpeechInput() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                            .accessibilityHidden(true)
                        Text(speech.isListening ? "停止" : "开始说")
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(speech.isListening ? .white : Color(hex: "159BFF"))
                    .padding(.horizontal, 13)
                    .frame(height: 48)
                    .background(speech.isListening ? Color(hex: "E5484D") : Color(hex: "EAF4FF"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    Task { await parse() }
                } label: {
                    HStack(spacing: 8) {
                        if loading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .accessibilityHidden(true)
                        }
                        Text(loading ? "正在整理" : "整理记录")
                    }
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: "111318"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)

                if let confidence {
                    VStack(spacing: 2) {
                        Text("\(Int((confidence * 100).rounded()))%")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("可改")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: "9AA0AA"))
                    }
                    .frame(width: 62, height: 48)
                    .background(Color(hex: "F1F2F4"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .softCard(radius: 24)
    }

    private var voiceTipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "159BFF"))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: "EAF4FF"))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("不会说？点一个例子")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("选一个例子改几个字，整理好后保存前都能改。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "8B919B"))
                        .lineLimit(2)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                voiceExampleChip("早餐两个鸡蛋，一杯牛奶")
                voiceExampleChip("午餐一碗米饭，鸡胸肉")
                voiceExampleChip("喝了500毫升水")
                voiceExampleChip("晚餐半碗面，几口青菜")
            }
        }
        .padding(14)
        .background(.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private func voiceExampleChip(_ example: String) -> some View {
        Button {
            text = example
        } label: {
            Text(example)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(loading || applying)
    }

    private var mealPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("记录到")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(hex: "6D7480"))
                Spacer()
                Text(mealCategory.isEmpty ? "自动判断" : meals.first(where: { $0.0 == mealCategory })?.1 ?? "已选择")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "9AA0AA"))
            }
            HStack(spacing: 8) {
                ForEach(meals, id: \.0) { meal in
                    Button {
                        mealCategory = meal.0
                    } label: {
                        Text(meal.1)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(mealCategory == meal.0 ? .white : Color(hex: "6D7480"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(mealCategory == meal.0 ? Color(hex: "111318") : Color.white.opacity(0.88))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                    }
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private var foodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("食物")
                        .font(.system(size: 15, weight: .black))
                    Text(foods.isEmpty ? "整理后可编辑" : "\(foods.count) 项 · \(Int(foodCalories.rounded())) 千卡")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "9AA0AA"))
                }
                Spacer()
                Button {
                    foods.append(VoiceParsedFood())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 34, height: 34)
                        .background(.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                }
                .accessibilityLabel("添加食物")
            }

            if foods.isEmpty {
                emptyCard("还没有食物，写一句后点“整理成可保存记录”。")
            } else {
                ForEach($foods) { $food in
                    foodCard(food: $food)
                }
            }
        }
    }

    private var hydrationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("饮品")
                        .font(.system(size: 15, weight: .black))
                    Text(hydration.isEmpty ? "饮水会同步到今日" : hydrationSummaryText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "9AA0AA"))
                }
                Spacer()
                Button {
                    hydration.append(VoiceParsedDrink())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 34, height: 34)
                        .background(.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                }
                .accessibilityLabel("添加饮品")
            }

            if hydration.isEmpty {
                emptyCard("没有饮品也没关系，需要时点右上角添加。")
            } else {
                ForEach($hydration) { $drink in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "drop.fill")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(Color(hex: "159BFF"))
                                .frame(width: 38, height: 42)
                                .background(Color(hex: "EAF4FF"))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .accessibilityHidden(true)
                            Menu {
                                ForEach(drinkTypes, id: \.0) { type in
                                    Button(type.1) {
                                        drink.drinkType = type.0
                                        updateDrinkNutrition(&drink, type: type.0)
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("类型")
                                        .font(.system(size: 10, weight: .black))
                                        .foregroundStyle(Color(hex: "9AA0AA"))
                                    HStack(spacing: 4) {
                                        Text(drinkName(drink.drinkType))
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color(hex: "111318"))
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 9, weight: .black))
                                            .foregroundStyle(Color(hex: "9AA0AA"))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .background(Color(hex: "F7F8FA"))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            compactNumberField("毫升", value: $drink.amountMl)
                            Button {
                                hydration.removeAll { $0.id == drink.id }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(Color(hex: "E5484D"))
                                    .frame(width: 38, height: 42)
                                    .background(Color(hex: "FFF1F1"))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .accessibilityLabel("删除饮品")
                        }
                        if drink.calories > 0 {
                            Text("约 \(Int(drink.calories.rounded())) 千卡 · 蛋白 \(oneDecimal(drink.protein))克 · 碳水 \(oneDecimal(drink.carbs))克 · 脂肪 \(oneDecimal(drink.fat))克")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: "6D7480"))
                                .padding(.leading, 46)
                        }
                    }
                    .padding(12)
                    .background(.white.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
                    .onChange(of: drink.amountMl) { _, _ in
                        updateDrinkNutrition(&drink, type: drink.drinkType)
                        if validationMessage == nil {
                            errorMessage = nil
                        }
                    }
                }
            }
        }
    }

    private var drinkTypes: [(String, String)] {
        [("water", "水"), ("sparkling_water", "气泡水"), ("coffee", "咖啡"),
         ("latte", "拿铁"), ("tea", "茶"), ("milk", "牛奶"),
         ("milk_tea", "奶茶"), ("juice", "果汁"),
         ("energy_drink", "能量饮料"), ("alcohol", "酒精饮品")]
    }

    private var hydrationSummaryText: String {
        let volume = "\(hydration.count) 项 · \(Int(parsedWaterMl.rounded())) 毫升"
        return drinkCalories > 0 ? "\(volume) · \(Int(drinkCalories.rounded())) 千卡" : volume
    }

    private func drinkName(_ type: String) -> String {
        drinkTypes.first(where: { $0.0 == type })?.1 ?? type
    }

    private func updateDrinkNutrition(_ drink: inout VoiceParsedDrink, type: String) {
        let defaults: [String: (Double, Double, Double, Double, Double, Double)] = [
            "latte": (350, 160, 8, 18, 6, 8),
            "milk": (240, 120, 8, 12, 4.5, 12),
            "milk_tea": (350, 230, 4, 38, 7, 32),
            "juice": (240, 110, 1, 26, 0.2, 22),
            "energy_drink": (250, 120, 0, 29, 0, 27),
            "alcohol": (150, 125, 0, 3, 0, 2),
        ]
        guard let preset = defaults[type] else {
            drink.calories = 0
            drink.protein = 0
            drink.carbs = 0
            drink.fat = 0
            drink.sugar = 0
            return
        }
        let scale = max(0, drink.amountMl) / preset.0
        drink.calories = preset.1 * scale
        drink.protein = preset.2 * scale
        drink.carbs = preset.3 * scale
        drink.fat = preset.4 * scale
        drink.sugar = preset.5 * scale
    }

    private func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private var footer: some View {
        VStack {
            Button {
                Task {
                    if parsedItemsCount > 0 {
                        await apply()
                    } else {
                        await parse()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                        if applying || loading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: parsedItemsCount > 0 ? "checkmark" : "wand.and.stars")
                                .accessibilityHidden(true)
                        }
                    Text(voiceFooterTitle)
                    if parsedItemsCount > 0 {
                        Text("\(parsedItemsCount)项")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .background(Color(hex: "111318"))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .disabled(
                applying || loading || validationMessage != nil ||
                (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedItemsCount == 0)
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
    }

    private var voiceFooterTitle: String {
        if applying {
            return "正在记到今天"
        }
        if loading {
            return "正在整理记录"
        }
        return parsedItemsCount > 0 ? "保存这些记录" : "先整理记录"
    }

    private func parse() async {
        if speech.isListening {
            speech.stop()
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !loading else { return }
        loading = true
        errorMessage = nil
        do {
            let response = try await APIClient.shared.parseVoiceLog(text: clean, date: logDate)
            foods = response.foods
            hydration = response.hydration
            mealCategory = response.mealCategory ?? ""
            confidence = response.confidence
        } catch {
            errorMessage = friendlyVoiceError(error, fallback: "这句话暂时没识别出来，换成“食物 + 份量”再试。")
        }
        loading = false
    }

    private func apply() async {
        if speech.isListening {
            speech.stop()
        }
        guard !applying else { return }
        if let validationMessage {
            errorMessage = validationMessage
            return
        }
        applying = true
        errorMessage = nil
        do {
            _ = try await APIClient.shared.applyVoiceLog(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                date: logDate,
                mealCategory: mealCategory,
                foods: foods.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                hydration: hydration.filter { $0.amountMl > 0 }
            )
            onApplied()
            onClose()
        } catch {
            errorMessage = friendlyVoiceError(error, fallback: "这条记录暂时没保存成功，检查网络后再点保存。")
        }
        applying = false
    }

    private func beginSpeechInput() async {
        speechBaseText = text
        errorMessage = nil
        await speech.start()
    }

    private func toggleSpeechInput() async {
        if speech.isListening {
            speech.stop()
        } else {
            await beginSpeechInput()
        }
    }

    private func voiceErrorCard(_ message: String) -> some View {
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
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await parse() }
                } label: {
                    Text("重新整理")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color(hex: "9B1C1C"))
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(.white.opacity(0.82))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(loading || applying)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: "FFF1F0"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func validationErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: "D93025"))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "9B1C1C"))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: "FFF1F0"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("记录有误，\(message)")
    }

    private func friendlyVoiceError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnectionFailureMessage(raw) {
            return "现在没连上，这条还没有保存；你写的内容还在，检查网络后再点保存。"
        }
        if raw.contains("Not Found") || raw.contains("404") {
            return "这次没记上，可以先改短一点再试。"
        }
        return fallback
    }

    private func foodCard(food: Binding<VoiceParsedFood>) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 42)
                    .background(Color(hex: "F1F2F4"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                compactTextField("食物名", text: food.name)
                compactTextField("份量", text: food.servingSize)
                Button {
                    foods.removeAll { $0.id == food.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "E5484D"))
                        .frame(width: 38, height: 42)
                        .background(Color(hex: "FFF1F1"))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityLabel("删除食物")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                compactNumberField("千卡", value: food.calories)
                compactNumberField("蛋白", value: food.protein)
                compactNumberField("碳水", value: food.carbs)
                compactNumberField("脂肪", value: food.fat)
                compactNumberField("纤维", value: food.fiber)
                compactNumberField("糖", value: food.sugar)
                compactNumberField("钠", value: food.sodium)
            }
        }
        .padding(12)
        .background(.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }

    private func compactTextField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "9AA0AA"))
            TextField(label, text: text)
                .font(.system(size: 13, weight: .bold))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func compactNumberField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "9AA0AA"))
            TextField(label, value: value, format: .number)
                .font(.system(size: 13, weight: .bold))
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(hex: "9AA0AA"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "EEF0F3"), lineWidth: 1))
    }
}
