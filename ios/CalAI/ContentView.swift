import SwiftUI
import UserNotifications
import Vision
import UniformTypeIdentifiers
import PhotosUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var showCamera = false
    @State private var cameraSource = "image_scan"
    @State private var showActionMenu = false
    @State private var showManualLog = false
    @State private var showFoodSearch = false
    @State private var showQuickSavedFoods = false
    @State private var showBarcodeEntry = false
    @State private var barcodeDraft = ""
    @State private var showExerciseLog = false
    @State private var voiceInitialText = ""
    @State private var voiceEntryMode: VoiceLogEntryMode?
    @State private var showFasting = false
    @State private var showHydration = false
    @State private var showRecordOverview = false
    @State private var showSleepLog = false
    @State private var showBadges = false
    @State private var showPreferences = false
    @State private var showOnboarding = false
    @State private var showCoach = false
    @State private var showChefMenu = false
    @State private var showRecommendations = false
    @State private var showIngredientRecipe = false
    @State private var recommendationsDeliveryMode = false
    @State private var recommendationsDeliveryTypes: [String] = ["正餐"]
    @State private var showResult: PendingMealResult?
    @State private var packagedPortionDraft: PackagedPortionDraft?
    @State private var resultAwaitingPortionSheetDismissal: PendingMealResult?
    @State private var showSettings = false
    @State private var selectedMealGroup: MealHistoryGroup?
    @State private var isAnalyzingMeal = false
    @State private var analysisMessage = "正在准备结果，出来后可以直接修改"
    @State private var analysisError: String?
    @State private var analysisRecovery = AnalysisRecoveryContext.meal
    @State private var statusMessage: String?
    @State private var hydrationUndo: HydrationLog?
    @State private var isRecordingHydration = false
    @State private var analysisJobs: [MealAnalysisJob] = []
    @State private var homeScrollToTopToken = 0
    @State private var isOpeningQuickAction = false
    @StateObject private var homeVM = HomeViewModel()

    var body: some View {
        ZStack {
            ZStack {
                HomePageView(
                    vm: homeVM,
                    scrollToTopToken: homeScrollToTopToken,
                    analysisJobs: analysisJobs,
                    onOpenSettings: { showSettings = true },
                    onOpenFasting: { showFasting = true },
                    onOpenHydration: { showHydration = true },
                    onQuickAddWater: { date in
                        recordHydration(amountMl: 250, date: date)
                    },
                    onOpenSleep: { showSleepLog = true },
                    onOpenRecordOverview: { showRecordOverview = true },
                    onScanFood: {
                        cameraSource = "image_scan"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            showCamera = true
                        }
                    },
                    onManualLog: {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            showManualLog = true
                        }
                    },
                    onOpenRecommendations: {
                        recommendationsDeliveryMode = false
                        recommendationsDeliveryTypes = ["正餐"]
                        showRecommendations = true
                    },
                    onOpenMeal: { selectedMealGroup = $0 },
                    onDismissAnalysisJob: { removeAnalysisJob($0) },
                    onRetryAnalysisJob: { retryAnalysisJob($0) },
                    onOpenAnalysisJob: { openCompletedAnalysisJob($0) },
                    onShareDailyCheckin: {
                        _ = try await APIClient.shared.shareDailyCheckin(caption: "今日状态打卡")
                        await MainActor.run {
                            homeVM.refresh(date: homeVM.selectedDate)
                        }
                    }
                )
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)

                if selectedTab == 1 {
                    HistoryPageView(
                        onScanFood: {
                            cameraSource = "image_scan"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                showCamera = true
                            }
                        }
                    )
                }

                if selectedTab == 2 {
                    CoachDrawerView(onClose: { selectedTab = 0 }, onChanged: { homeVM.refresh() })
                        .padding(.bottom, 96)
                }

                if selectedTab == 3 {
                    LazyInfoPageHost(
                            logDate: homeVM.selectedDate,
                            onChanged: {
                                homeVM.refresh(date: homeVM.selectedDate)
                            },
                            onScanFood: {
                                cameraSource = "image_scan"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    showCamera = true
                                }
                            },
                            onManualLog: {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    showManualLog = true
                                }
                            },
                            onSearchFood: {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    showFoodSearch = true
                                }
                            },
                            onBarcode: {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    showBarcodeEntry = true
                                }
                            },
                            onLabel: {
                                cameraSource = "label_scan"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    showCamera = true
                                }
                            },
                            onVoiceLog: {
                                voiceInitialText = ""
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    voiceEntryMode = .voice
                                }
                            },
                            onOpenHydration: {
                                showHydration = true
                            },
                            onOpenFasting: {
                                showFasting = true
                            },
                            onOpenBadges: {
                                showBadges = true
                            },
                            onOpenSettings: {
                                showSettings = true
                            }
                    )
                }
            }

            PremiumBottomNav(
                selectedTab: $selectedTab,
                onTabTap: { tab in
                    if tab == 0 {
                        homeScrollToTopToken += 1
                    }
                }
            ) {
                showActionMenu = true
            }

            ChefMenuSheetView(
                isOpen: showChefMenu,
                summary: homeVM.summary,
                decisionContext: homeVM.decisionContext,
                onClose: { showChefMenu = false },
                onSelect: handleChefAction
            )

            if isAnalyzingMeal {
                MealAnalysisOverlay(message: analysisMessage)
                    .transition(.opacity)
            }

            if let statusMessage {
                StatusMessageToast(message: statusMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 108)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let hydrationUndo {
                HydrationUndoToast(amountMl: hydrationUndo.amountMl) {
                    undoHydration(hydrationUndo)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 108)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(101)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
        .sheet(isPresented: $showActionMenu) {
            QuickActionSheetView(
                onClose: { showActionMenu = false },
                onScan: {
                    openQuickAction {
                        cameraSource = "image_scan"
                        showCamera = true
                    }
                },
                onManual: {
                    openQuickAction {
                        showManualLog = true
                    }
                },
                onVoice: {
                    openQuickAction {
                        voiceInitialText = ""
                        voiceEntryMode = .voice
                    }
                },
                onText: {
                    openQuickAction {
                        voiceInitialText = ""
                        voiceEntryMode = .text
                    }
                },
                onBarcode: {
                    openQuickAction {
                        showBarcodeEntry = true
                    }
                },
                onLabel: {
                    openQuickAction {
                        cameraSource = "label_scan"
                        showCamera = true
                    }
                },
                onSearch: {
                    openQuickAction {
                        showFoodSearch = true
                    }
                },
                onFrequent: {
                    openQuickAction {
                        showQuickSavedFoods = true
                    }
                },
                onExercise: {
                    openQuickAction {
                        showExerciseLog = true
                    }
                },
                onDrink: { amountMl in
                    openQuickAction {
                        recordHydration(amountMl: amountMl, date: homeVM.selectedDate)
                    }
                },
                onFasting: {
                    openQuickAction {
                        showFasting = true
                    }
                },
                onCoach: {
                    openQuickAction {
                        showCoach = true
                    }
                }
            )
            .presentationDetents([.height(550), .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showRecordOverview) {
            RecordOverviewPageView(
                onClose: {
                    showRecordOverview = false
                },
                onStartRecord: {
                    showRecordOverview = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showActionMenu = true
                    }
                }
            )
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(source: cameraSource) { capture in
                showCamera = false
                let source = (capture.captureMetadata["source"] as? String) ?? ""
                if source == "barcode_scan" {
                    let barcode = String(describing: capture.captureMetadata["barcode"] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    barcodeDraft = barcode
                    Task {
                        isAnalyzingMeal = true
                        analysisError = nil
                        analysisMessage = "正在查条码，通常几秒"
                        defer {
                            isAnalyzingMeal = false
                            analysisMessage = "正在准备结果，出来后可以直接修改"
                        }
                        do {
                            guard !barcode.isEmpty else {
                                throw APIError.server("没有读取到条形码，请重新扫描或手动输入。")
                            }
                            let result = try await APIClient.shared.lookupBarcode(barcode)
                            guard !result.foods.isEmpty else {
                                throw APIError.server(result.description ?? "没有找到这个条形码对应的食品")
                            }
                            packagedPortionDraft = PackagedPortionDraft(result: result, imageBase64: nil, sourceLabel: "条码")
                        } catch {
                            analysisRecovery = .barcode
                            analysisError = friendlyContentError(error, fallback: "这个条码暂时没查到，可以手动输入或搜索食品名。")
                        }
                    }
                    return
                }
                if source == "image_scan" || source == "library" {
                    selectedTab = 0
                    startBackgroundMealAnalysis(capture)
                    return
                }
                if source == "label_scan" {
                    handleNutritionLabelScan(capture)
                    return
                }
                analysisRecovery = .menu
                analysisError = "这个入口还没准备好。现在可以先用扫描食物、条形码扫描器、食物数据库或手动记录。"
            }
        }
        .sheet(isPresented: $showBarcodeEntry) {
            BarcodeEntrySheetView(
                barcode: $barcodeDraft,
                onClose: {
                    showBarcodeEntry = false
                },
                onCamera: {
                    showBarcodeEntry = false
                    cameraSource = "barcode_camera"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showCamera = true
                    }
                },
                onResult: { result in
                    showBarcodeEntry = false
                    barcodeDraft = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        packagedPortionDraft = PackagedPortionDraft(result: result, imageBase64: nil, sourceLabel: "条码")
                    }
                },
                onError: { message in
                    analysisRecovery = .barcode
                    analysisError = message
                }
            )
        }
        .sheet(item: $packagedPortionDraft, onDismiss: presentResultAfterPortionSheetDismissal) { draft in
            PackagedPortionConfirmSheet(
                draft: draft,
                onCancel: {
                    packagedPortionDraft = nil
                },
                onConfirm: { adjustedResult in
                    let imageBase64 = draft.imageBase64
                    resultAwaitingPortionSheetDismissal = PendingMealResult(
                        result: adjustedResult,
                        imageBase64: imageBase64
                    )
                    packagedPortionDraft = nil
                }
            )
            .presentationDetents([.height(430), .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $showResult) { pending in
            ResultPageView(
                result: pending.result,
                imageBase64: pending.imageBase64,
                logDate: homeVM.selectedDate,
                onSaved: { message in
                    homeVM.refresh(date: homeVM.selectedDate)
                    showStatusMessage(message)
                }
            ) {
                showResult = nil
                homeVM.refresh(date: homeVM.selectedDate)
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsPageView(
                onClose: {
                    showSettings = false
                },
                onOpenPreferences: {
                    showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showPreferences = true
                    }
                },
                onOpenOnboarding: {
                    showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showOnboarding = true
                    }
                },
                onOpenFasting: {
                    showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showFasting = true
                    }
                },
                onOpenBadges: {
                    showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showBadges = true
                    }
                },
                onOpenFriends: {
                    showSettings = false
                    selectedTab = 2
                },
                onOpenWeightHistory: {
                    showSettings = false
                    selectedTab = 1
                },
                onHealthSynced: {
                    homeVM.refresh()
                }
            )
        }
        .fullScreenCover(isPresented: $showFasting) {
            FastingPageView(
                onBack: { showFasting = false },
                onStatusChanged: { homeVM.refresh(date: homeVM.selectedDate) }
            )
        }
        .fullScreenCover(isPresented: $showHydration) {
            HydrationPageView(
                logDate: homeVM.selectedDate,
                onClose: { showHydration = false },
                onChanged: { homeVM.refresh(date: homeVM.selectedDate) }
            )
        }
        .fullScreenCover(isPresented: $showPreferences) {
            PreferencesPageView {
                showPreferences = false
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
                homeVM.refresh()
            }
        }
        .fullScreenCover(isPresented: $showCoach) {
            CoachDrawerView(
                onClose: { showCoach = false },
                onChanged: { homeVM.refresh() }
            )
        }
        .fullScreenCover(isPresented: $showRecommendations) {
            CoachDrawerView(onClose: { showRecommendations = false }, onChanged: { homeVM.refresh() })
        }
        .sheet(isPresented: $showIngredientRecipe) {
            CoachDrawerView(onClose: { showIngredientRecipe = false }, onChanged: { homeVM.refresh() })
        }
        .sheet(isPresented: $showManualLog) {
            ManualLogSheetView(
                logDate: homeVM.selectedDate,
                onClose: {
                    showManualLog = false
                },
                onLogged: {
                    homeVM.refresh(date: homeVM.selectedDate)
                }
            )
        }
        .sheet(isPresented: $showFoodSearch) {
            FoodSearchSheetView(
                logDate: homeVM.selectedDate,
                onClose: {
                    showFoodSearch = false
                },
                onLogged: {
                    homeVM.refresh(date: homeVM.selectedDate)
                },
                onEstimated: { result in
                    showFoodSearch = false
                    showResult = PendingMealResult(result: result, imageBase64: nil)
                    homeVM.refresh(date: homeVM.selectedDate)
                },
                onManual: {
                    showManualLog = true
                }
            )
        }
        .sheet(isPresented: $showQuickSavedFoods) {
            QuickSavedFoodSheetView(
                logDate: homeVM.selectedDate,
                onClose: {
                    showQuickSavedFoods = false
                },
                onLogged: { message in
                    homeVM.refresh(date: homeVM.selectedDate)
                    showStatusMessage(message)
                },
                onSearch: {
                    showQuickSavedFoods = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        showFoodSearch = true
                    }
                }
            )
        }
        .sheet(isPresented: $showExerciseLog) {
            ExerciseLogSheetView(
                logDate: homeVM.selectedDate,
                onClose: {
                    showExerciseLog = false
                },
                onLogged: {
                    homeVM.refresh(date: homeVM.selectedDate)
                }
            )
        }
        .sheet(item: $voiceEntryMode) { entryMode in
            VoiceLogSheetView(
                initialText: voiceInitialText,
                entryMode: entryMode,
                logDate: homeVM.selectedDate,
                onClose: {
                    voiceEntryMode = nil
                    voiceInitialText = ""
                },
                onApplied: {
                    homeVM.refresh(date: homeVM.selectedDate)
                }
            )
        }
        .sheet(isPresented: $showSleepLog) {
            SleepLogSheetView(
                summary: homeVM.sleepSummary,
                logDate: homeVM.selectedDate,
                onClose: {
                    showSleepLog = false
                },
                onSaved: {
                    homeVM.refresh(date: homeVM.selectedDate)
                }
            )
        }
        .fullScreenCover(isPresented: $showBadges) {
            BadgesPageView(
                summary: homeVM.summary,
                streak: homeVM.streak,
                onScanFood: {
                    showBadges = false
                    openQuickAction(delay: 0.22) {
                        cameraSource = "image_scan"
                        showCamera = true
                    }
                },
                onClose: {
                    showBadges = false
                }
            )
        }
        .fullScreenCover(item: $selectedMealGroup) { meal in
            MealGroupDetailPageView(group: meal) {
                selectedMealGroup = nil
                homeVM.refresh(date: homeVM.selectedDate)
            } onChanged: { message in
                homeVM.refresh(date: homeVM.selectedDate)
                showStatusMessage(message)
            }
        }
        .alert("这餐还没算出来", isPresented: Binding(
            get: { analysisError != nil },
            set: { if !$0 { analysisError = nil } }
        )) {
            Button(analysisRecovery.primaryTitle) {
                performPrimaryAnalysisRecovery()
            }
            Button(analysisRecovery.secondaryTitle) {
                performSecondaryAnalysisRecovery()
            }
            Button("先放着", role: .cancel) {
                analysisError = nil
            }
        } message: {
            Text(analysisError ?? "这次还没算出来，可以重拍，或先手动补记。")
        }
    }

    private func handleNutritionLabelScan(_ capture: MealCapture) {
        Task {
            isAnalyzingMeal = true
            analysisError = nil
            analysisMessage = "正在读取标签，通常几秒"
            defer {
                isAnalyzingMeal = false
                analysisMessage = "正在准备结果，出来后可以直接修改"
            }
            do {
                let label = try await NutritionLabelOCR.analyze(imageBase64: capture.imageBase64)
                analysisMessage = "正在判断适不适合今天吃"
                let decision = try? await APIClient.shared.scoreProductDecision(
                    nutrition: label.nutrition,
                    names: [label.displayName],
                    date: homeVM.selectedDate,
                    persist: false
                )
                let food = FoodItem(
                    name: label.displayName,
                    calories: label.nutrition["calories"] ?? 0,
                    protein: label.nutrition["protein"] ?? 0,
                    carbs: label.nutrition["carbs"] ?? 0,
                    fat: label.nutrition["fat"] ?? 0,
                    fiber: label.nutrition["fiber"] ?? 0,
                    sugar: label.nutrition["sugar"] ?? 0,
                    sodium: label.nutrition["sodium"] ?? 0,
                    servingSize: label.servingSize,
                    processingLevel: "packaged",
                    addedSugar: label.nutrition["added_sugar"] ?? 0,
                    date: homeVM.selectedDate.isEmpty ? nil : homeVM.selectedDate
                )
                packagedPortionDraft = PackagedPortionDraft(
                    result: DescribeMealResponse(
                        foods: [food],
                        healthScore: nil,
                        description: label.summary,
                        decision: decision
                    ),
                    imageBase64: capture.imageBase64,
                    sourceLabel: "营养表"
                )
            } catch {
                analysisRecovery = .label
                analysisError = friendlyContentError(error, fallback: "这张营养标签没读清楚，请让营养成分表完整入镜再拍一次。")
            }
        }
    }

    private func startBackgroundMealAnalysis(_ capture: MealCapture) {
        let hasDepth = capture.hasDepthCaptureBundle
        let jobId = "analysis_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))"
        analysisJobs.insert(
            MealAnalysisJob(
                id: jobId,
                imageBase64: capture.imageBase64,
                capture: capture,
                progress: 5,
                status: .running,
                message: hasDepth ? "正在分析这餐，算好后先检查。" : "正在估算这餐，算好后先检查。"
            ),
            at: 0
        )
        analysisError = nil
        showStatusMessage(hasDepth ? "已在后台分析，可继续使用首页" : "已在后台估算，可继续使用首页")

        Task {
            await animateAnalysisJob(jobId)
        }

        Task {
            do {
                let result = try await APIClient.shared.describeMealStream(capture: capture) { event in
                    Task { @MainActor in
                        updateAnalysisJob(
                            jobId,
                            progress: progressForStreamEvent(event),
                            message: streamMessage(for: event)
                        )
                    }
                }
                guard !result.foods.isEmpty else {
                    let reason = result.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    throw APIError.server(reason.isEmpty ? "没有识别到可保存的食物" : reason)
                }
                updateAnalysisJob(
                    jobId,
                    progress: 100,
                    status: .ready,
                    message: "识别出 \(result.foods.count) 项，检查后再保存。",
                    result: result
                )
                await MainActor.run {
                    showStatusMessage("这餐识别好了，检查后再保存")
                }
            } catch {
                updateAnalysisJob(
                    jobId,
                    progress: 100,
                    status: .failed,
                    message: friendlyContentError(error, fallback: "这张没算出来。重新拍整盘会更准。")
                )
            }
        }
    }

    private func recordHydration(amountMl: Double, date: String) {
        guard !isRecordingHydration else { return }
        isRecordingHydration = true
        Task {
            defer { isRecordingHydration = false }
            do {
                let log = try await APIClient.shared.addHydration(
                    amountMl: amountMl,
                    drinkType: "water",
                    date: date
                )
                homeVM.refresh(date: date)
                offerHydrationUndo(log)
            } catch {
                showStatusMessage(friendlyContentError(error, fallback: "这杯水还没记上，稍后再点一次。"))
            }
        }
    }

    private func presentResultAfterPortionSheetDismissal() {
        guard let pending = resultAwaitingPortionSheetDismissal else { return }
        resultAwaitingPortionSheetDismissal = nil
        showResult = pending
    }

    @MainActor
    private func openQuickAction(delay: Double = 0.16, _ action: @escaping () -> Void) {
        guard !isOpeningQuickAction else { return }
        isOpeningQuickAction = true
        showActionMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                isOpeningQuickAction = false
            }
        }
    }

    @MainActor
    private func showStatusMessage(_ message: String?) {
        let clean = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            statusMessage = clean
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if statusMessage == clean {
                withAnimation(.easeOut(duration: 0.2)) {
                    statusMessage = nil
                }
            }
        }
    }

    @MainActor
    private func offerHydrationUndo(_ log: HydrationLog) {
        statusMessage = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            hydrationUndo = log
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if hydrationUndo?.id == log.id {
                withAnimation(.easeOut(duration: 0.2)) {
                    hydrationUndo = nil
                }
            }
        }
    }

    @MainActor
    private func undoHydration(_ log: HydrationLog) {
        hydrationUndo = nil
        Task {
            do {
                _ = try await APIClient.shared.deleteHydration(ids: [log.id], date: homeVM.selectedDate)
                await MainActor.run {
                    homeVM.refresh(date: homeVM.selectedDate)
                    showStatusMessage("已撤销 \(Int(round(log.amountMl))) 毫升饮水")
                }
            } catch {
                await MainActor.run {
                    showStatusMessage(friendlyContentError(error, fallback: "这次没撤销成功，饮水记录仍保留。"))
                }
            }
        }
    }

    private func animateAnalysisJob(_ id: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let shouldContinue = await MainActor.run { () -> Bool in
                guard let job = analysisJobs.first(where: { $0.id == id }) else { return false }
                if case .failed = job.status { return false }
                guard job.progress < 92 else { return false }
                let next = min(92, job.progress + max(3, round((92 - job.progress) * 0.18)))
                updateAnalysisJob(id, progress: next)
                return true
            }
            if !shouldContinue { break }
        }
    }

    @MainActor
    private func updateAnalysisJob(
        _ id: String,
        progress: Double? = nil,
        status: MealAnalysisJob.Status? = nil,
        message: String? = nil,
        result: DescribeMealResponse? = nil
    ) {
        analysisJobs = analysisJobs.map { job in
            guard job.id == id else { return job }
            var next = job
            if let progress {
                next.progress = max(next.progress, min(100, max(0, progress)))
            }
            if let status {
                next.status = status
            }
            if let message, !message.isEmpty {
                next.message = message
            }
            if let result {
                next.result = result
            }
            return next
        }
    }

    @MainActor
    private func removeAnalysisJob(_ id: String) {
        analysisJobs.removeAll { $0.id == id }
    }

    @MainActor
    private func retryAnalysisJob(_ id: String) {
        guard let capture = analysisJobs.first(where: { $0.id == id })?.capture else {
            analysisRecovery = .meal
            analysisError = "这张照片不能重试，重新拍一张会更稳。"
            return
        }
        removeAnalysisJob(id)
        startBackgroundMealAnalysis(capture)
    }

    @MainActor
    private func openCompletedAnalysisJob(_ id: String) {
        guard let job = analysisJobs.first(where: { $0.id == id }), let result = job.result else {
            return
        }
        selectedTab = 0
        showResult = PendingMealResult(result: result, imageBase64: job.imageBase64)
        removeAnalysisJob(id)
    }

    private func performPrimaryAnalysisRecovery() {
        analysisError = nil
        switch analysisRecovery {
        case .meal:
            cameraSource = "image_scan"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showCamera = true
            }
        case .barcode:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showBarcodeEntry = true
            }
        case .label:
            cameraSource = "label_scan"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showCamera = true
            }
        case .menu:
            showActionMenu = true
        }
    }

    private func performSecondaryAnalysisRecovery() {
        analysisError = nil
        switch analysisRecovery {
        case .barcode:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showFoodSearch = true
            }
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showManualLog = true
            }
        }
    }

    private func progressForStreamEvent(_ event: [String: Any]) -> Double {
        let stage = String(describing: event["stage"] ?? "")
        switch stage {
        case "uploading_depth":
            return 18
        case "analyzing_depth":
            return 35
        case "queued":
            return 45
        case "completed":
            return 96
        case "vision_started":
            return 12
        case "vision_items":
            return 42
        case "database_candidate":
            let completed = eventInt(event["completed"])
            let total = max(1, eventInt(event["total"]))
            return min(64, 42 + Double(completed) / Double(total) * 22)
        case "database_candidates":
            return 66
        case "nutrition_review_started":
            return 82
        case "final":
            return 96
        default:
            return 5
        }
    }

    private func streamMessage(for event: [String: Any]) -> String {
        let stage = String(describing: event["stage"] ?? "")
        switch stage {
        case "uploading_depth":
            return "已拍到，正在上传照片。"
        case "analyzing_depth":
            return "正在按照片算份量，复杂拼盘会多等几秒。"
        case "queued":
            return "正在排队，别锁屏，排到后会自动继续。"
        case "completed":
            return "算好了，正在保存到今天。"
        case "vision_started":
            return "正在找出画面里的食物。"
        case "vision_items":
            let names = ((event["items"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["name"] ?? $0["name_zh"]).map { String(describing: $0) } }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if names.isEmpty { return "已找到食物，继续算热量。" }
            let preview = names.prefix(4).joined(separator: "、")
            return names.count > 4 ? "已找到：\(preview) 等 \(names.count) 项" : "已找到：\(preview)"
        case "database_candidate":
            let completed = eventInt(event["completed"])
            let total = eventInt(event["total"])
            let item = event["item"] as? [String: Any]
            let name = String(describing: item?["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, total > 0 {
                return "正在核对热量：\(name) \(completed)/\(total)"
            }
            return total > 0 ? "正在核对热量 \(completed)/\(total)" : "正在核对热量。"
        case "database_candidates":
            let items = (event["items"] as? [[String: Any]]) ?? []
            let matched = items.filter { item in
                if let count = item["candidate_count"] as? Int { return count > 0 }
                if let count = item["candidate_count"] as? Double { return count > 0 }
                return false
            }.count
            return items.isEmpty ? "正在检查结果。" : "已核对 \(matched)/\(items.count) 项"
        case "nutrition_review_started":
            return "正在检查有没有明显偏高或偏低。"
        case "final":
            return "正在整理可修改结果。"
        default:
            return "正在分析，简单餐几秒，复杂拼盘会久一点。"
        }
    }

    private func eventInt(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        return 0
    }

    private func handleChefAction(_ action: ChefMenuAction) {
        showChefMenu = false
        switch action {
        case .mealPlan:
            showCoach = true
        case .delivery:
            recommendationsDeliveryMode = true
            recommendationsDeliveryTypes = ["正餐"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showRecommendations = true
            }
        case .cook:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showIngredientRecipe = true
            }
        case .menuScan:
            cameraSource = "image_scan"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showCamera = true
            }
        case .convenience:
            recommendationsDeliveryMode = true
            recommendationsDeliveryTypes = ["便利店"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showRecommendations = true
            }
        case .coach:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showCoach = true
            }
        }
    }
}

private enum AnalysisRecoveryContext {
    case meal
    case barcode
    case label
    case menu

    var primaryTitle: String {
        switch self {
        case .meal:
            return "重新拍一餐"
        case .barcode:
            return "重新输入条码"
        case .label:
            return "重新拍标签"
        case .menu:
            return "回到加号"
        }
    }

    var secondaryTitle: String {
        switch self {
        case .barcode:
            return "搜索食品名"
        default:
            return "手动补记"
        }
    }
}

private func friendlyContentError(_ error: Error, fallback: String) -> String {
    if let qwenError = error as? QwenError { return qwenError.localizedDescription }
    let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return fallback }
    let lower = raw.lowercased()
    if lower.contains("could not connect")
        || lower.contains("connection")
        || lower.contains("timed out")
        || lower.contains("network")
        || lower.contains("urlsession")
        || raw.contains("连接不到")
        || raw.contains("无法连接") {
        return "现在没连上，这次没保存。检查网络后重试，或先手动补记。"
    }
    if lower.contains("not found") || lower.contains("404") {
        return "这项还没开好。换个入口试试，或先手动补记。"
    }
    if lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("401") || lower.contains("403") {
        return "这次暂时不能拍照。检查连接后再试，或先手动补记。"
    }
    if lower.contains("unprocessable") || lower.contains("validation") || lower.contains("422") || lower.contains("missing field") {
        return "这次信息不完整。重新拍一张，或先手动补记。"
    }
    if raw.contains("没有识别到可保存的食物") || raw.contains("没有识别到食物") {
        return "这张图没看清食物，重新拍近一点、让餐盘完整入镜会更准。"
    }
    if lower.contains("depth") || lower.contains("lidar") || raw.contains("深度") {
        return "这次照片信息不完整。点拍新照片会更稳。"
    }
    if lower.contains("glm")
        || lower.contains("qwen")
        || lower.contains("mimo")
        || lower.contains("sam2")
        || lower.contains("grounding")
        || raw.contains("图片模型")
        || raw.contains("模型连接失败") {
        return "扫描食物暂时没连上。稍后重拍，或先手动补记。"
    }
    if lower.contains("metadata")
        || lower.contains("capture_pipeline")
        || lower.contains("image_scan")
        || lower.contains("has_depth")
        || lower.contains("api")
        || lower.contains("pipeline")
        || lower.contains("endpoint")
        || lower.contains("input/output")
        || lower.contains("errno")
        || lower.contains("traceback")
        || lower.contains("http://")
        || lower.contains("https://") {
        return "这次照片没算出来。重拍通常可以，赶时间先手动补记。"
    }
    if lower.contains("barcode") || raw.contains("条形码") {
        return raw
    }
    if lower.contains("cancelled") || raw.contains("取消") {
        return "刚才的操作已取消，没有保存新记录。"
    }
    if raw.count > 80 || raw.contains("{") || raw.contains("}") {
        return fallback
    }
    return raw
}

private struct NutritionLabelAnalysis {
    let displayName: String
    let servingSize: String
    let nutrition: [String: Double]
    let summary: String
}

private enum NutritionLabelOCRError: LocalizedError {
    case invalidImage
    case noText
    case noNutrition

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "没有读取到可识别的标签照片，请重新拍摄。"
        case .noText:
            return "没有识别到营养标签文字，请让营养成分表更清晰、更完整地入镜。"
        case .noNutrition:
            return "没有解析到关键营养值。请确认画面包含热量、蛋白质、碳水、脂肪等营养成分表。"
        }
    }
}

private enum NutritionLabelOCR {
    static func analyze(imageBase64: String) async throws -> NutritionLabelAnalysis {
        let payload = imageBase64.split(separator: ",", maxSplits: 1).last.map(String.init) ?? imageBase64
        guard let data = Data(base64Encoded: payload) else {
            throw NutritionLabelOCRError.invalidImage
        }
        let text = try await recognizeText(from: data)
        let nutrition = parseNutrition(from: text)
        guard !nutrition.isEmpty else {
            throw NutritionLabelOCRError.noNutrition
        }
        let name = inferName(from: text)
        let serving = inferServingSize(from: text)
        let summary = "营养标签识别：\(name)，\(serving)。"
        return NutritionLabelAnalysis(
            displayName: name,
            servingSize: serving,
            nutrition: nutrition,
            summary: summary
        )
    }

    private static func recognizeText(from data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let lines = (request.results as? [VNRecognizedTextObservation])?
                        .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty } ?? []
                    if lines.isEmpty {
                        continuation.resume(throwing: NutritionLabelOCRError.noText)
                    } else {
                        continuation.resume(returning: lines.joined(separator: "\n"))
                    }
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

                do {
                    try VNImageRequestHandler(data: data, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func parseNutrition(from text: String) -> [String: Double] {
        var result: [String: Double] = [:]
        let normalized = normalize(text)
        if let calories = firstValue(in: normalized, labels: ["能量", "热量", "calories", "calorie", "energy"]) {
            result["calories"] = calories.unit.lowercased().contains("kj") || calories.unit.contains("千焦")
                ? round(calories.value / 4.184)
                : calories.value
        }
        if let protein = firstValue(in: normalized, labels: ["蛋白质", "protein"]) {
            result["protein"] = gramsValue(protein)
        }
        if let carbs = firstValue(in: normalized, labels: ["碳水化合物", "碳水", "carbohydrate", "carbs"]) {
            result["carbs"] = gramsValue(carbs)
        }
        if let fat = firstValue(in: normalized, labels: ["脂肪", "total fat", "fat"]) {
            result["fat"] = gramsValue(fat)
        }
        if let fiber = firstValue(in: normalized, labels: ["膳食纤维", "纤维", "fiber", "fibre"]) {
            result["fiber"] = gramsValue(fiber)
        }
        if let sugar = firstValue(in: normalized, labels: ["糖", "sugars", "sugar"]) {
            result["sugar"] = gramsValue(sugar)
        }
        if let sodium = firstValue(in: normalized, labels: ["钠", "sodium"]) {
            result["sodium"] = sodium.unit.lowercased().contains("mg") || sodium.unit.contains("毫克")
                ? sodium.value
                : gramsValue(sodium) * 1000
        }

        if result["calories"] == nil {
            let protein = result["protein"] ?? 0
            let carbs = result["carbs"] ?? 0
            let fat = result["fat"] ?? 0
            let estimated = protein * 4 + carbs * 4 + fat * 9
            if estimated > 0 {
                result["calories"] = round(estimated)
            }
        }

        return result.filter { _, value in value.isFinite && value >= 0 }
    }

    private static func firstValue(in text: String, labels: [String]) -> (value: Double, unit: String)? {
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard labels.contains(where: { lower.contains($0.lowercased()) }) else {
                continue
            }
            let joined = ([line] + lines.dropFirst(index + 1).prefix(1)).joined(separator: " ")
            if let value = numericValue(in: joined) {
                return value
            }
        }
        return nil
    }

    private static func numericValue(in text: String) -> (value: Double, unit: String)? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(千焦|千卡|大卡|kJ|KJ|kj|kcal|KCAL|毫升|克|毫克|ml|ML|mL|mg|MG|g|G)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Double(text[valueRange])
        else {
            return nil
        }
        let unit: String
        if match.numberOfRanges > 2, let unitRange = Range(match.range(at: 2), in: text) {
            unit = String(text[unitRange])
        } else {
            unit = ""
        }
        return (value, unit)
    }

    private static func gramsValue(_ value: (value: Double, unit: String)) -> Double {
        value.unit.lowercased().contains("mg") || value.unit.contains("毫克")
            ? value.value / 1000
            : value.value
    }

    private static func inferServingSize(from text: String) -> String {
        let normalized = normalize(text)
        let labels = ["每份", "每100克", "每 100 克", "每100g", "每100毫升", "每 100 毫升", "每100ml", "per serving", "per 100g", "per 100ml"]
        for line in normalized.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if labels.contains(where: { lower.contains($0.lowercased()) }) {
                if lower.contains("100g") || lower.contains("100克") {
                    return "每100克"
                }
                if lower.contains("100ml") || lower.contains("100毫升") {
                    return "每100毫升"
                }
                if let value = numericValue(in: line), value.unit.lowercased().contains("g") || value.unit.contains("克") {
                    return "每份 \(Int(round(value.value)))克"
                }
                if let value = numericValue(in: line), value.unit.lowercased().contains("ml") || value.unit.contains("毫升") {
                    return "每份 \(Int(round(value.value)))毫升"
                }
                return "每份"
            }
        }
        return "营养标签"
    }

    private static func inferName(from text: String) -> String {
        let excluded = ["营养", "能量", "热量", "蛋白", "脂肪", "碳水", "钠", "配料", "nutrition", "energy", "protein", "fat", "carb", "sodium"]
        for raw in text.components(separatedBy: .newlines).prefix(6) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            guard line.count >= 2, line.count <= 24 else { continue }
            if excluded.contains(where: { lower.contains($0) }) { continue }
            return line
        }
        return "营养标签食品"
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "０", with: "0")
            .replacingOccurrences(of: "１", with: "1")
            .replacingOccurrences(of: "２", with: "2")
            .replacingOccurrences(of: "３", with: "3")
            .replacingOccurrences(of: "４", with: "4")
            .replacingOccurrences(of: "５", with: "5")
            .replacingOccurrences(of: "６", with: "6")
            .replacingOccurrences(of: "７", with: "7")
            .replacingOccurrences(of: "８", with: "8")
            .replacingOccurrences(of: "９", with: "9")
    }
}

private struct PendingMealResult: Identifiable {
    let id = UUID().uuidString
    let result: DescribeMealResponse
    let imageBase64: String?
}

private struct PackagedPortionDraft: Identifiable {
    let id = UUID().uuidString
    let result: DescribeMealResponse
    let imageBase64: String?
    let sourceLabel: String
}

private struct PackagedPortionConfirmSheet: View {
    let draft: PackagedPortionDraft
    let onCancel: () -> Void
    let onConfirm: (DescribeMealResponse) -> Void
    @State private var gramsPerServing: String
    @State private var servings = "1"

    init(
        draft: PackagedPortionDraft,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (DescribeMealResponse) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let grams = Self.gramsFromServing(draft.result.foods.first?.servingSize ?? "")
        _gramsPerServing = State(initialValue: "\(Int(round(grams)))")
    }

    private var parsedGrams: Double {
        max(1, Double(gramsPerServing.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    private var parsedServings: Double {
        max(0.1, Double(servings.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    private var valid: Bool {
        (Double(gramsPerServing) ?? 0) > 0 && (Double(servings) ?? 0) > 0
    }

    private var adjustedResult: DescribeMealResponse {
        let foods = draft.result.foods.map { food -> FoodItem in
            var item = food
            let baseGrams = Self.gramsFromServing(food.servingSize)
            let factor = parsedGrams / max(1, baseGrams) * parsedServings
            item.scaleNutrition(from: food, factor: factor)
            item.servingSize = "\(Int(round(parsedGrams)))克 × \(parsedServings.formatted(.number.precision(.fractionLength(0...1))))份"
            item.gramsPerUnit = parsedGrams
            item.quantityCount = parsedServings
            item.quantityUnit = "份"
            item.quantityDescription = item.servingSize
            return item
        }
        return DescribeMealResponse(
            foods: foods,
            healthScore: draft.result.healthScore,
            description: draft.result.description,
            decision: draft.result.decision
        )
    }

    private var adjustedCalories: Int {
        Int(round(adjustedResult.foods.reduce(0) { $0 + $1.calories }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("先确认包装份量")
                        .font(.system(size: 24, weight: .black))
                    Text("\(draft.sourceLabel)只提供营养基准，实际吃多少由你确认。")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "6D7480"))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "F3F4F6"))
                        .clipShape(Circle())
                }
                .accessibilityLabel("关闭份量确认")
            }

            Text(draft.result.foods.first?.name ?? "包装食品")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(hex: "111318"))

            HStack(spacing: 10) {
                packagedNumberField(title: "每份多少克", text: $gramsPerServing, unit: "克")
                packagedNumberField(title: "实际吃了几份", text: $servings, unit: "份")
            }

            HStack {
                Text("本次将记录")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valid ? "\(adjustedCalories) 千卡" : "--")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
            }
            .padding(14)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                onConfirm(adjustedResult)
            } label: {
                Text("确认份量，检查后再保存")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(valid ? Color(hex: "111318") : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!valid)
        }
        .padding(22)
        .background(Color.white)
    }

    private func packagedNumberField(title: String, text: Binding<String>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField("0", text: text)
                    .font(.system(size: 20, weight: .black))
                    .keyboardType(.decimalPad)
                Text(unit)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static func gramsFromServing(_ text: String) -> Double {
        let normalized = text.replacingOccurrences(of: "克", with: "g")
        let range = NSRange(normalized.startIndex..., in: normalized)
        if let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*g"#, options: .caseInsensitive),
           let match = regex.matches(in: normalized, range: range).last,
           let valueRange = Range(match.range(at: 1), in: normalized),
           let value = Double(normalized[valueRange]), value > 0 {
            return value
        }
        return 100
    }
}

private enum ChefMenuAction {
    case mealPlan
    case delivery
    case cook
    case menuScan
    case convenience
    case coach
}

private struct ChefMenuSheetView: View {
    let isOpen: Bool
    let summary: DailySummary?
    let decisionContext: DecisionContext?
    let onClose: () -> Void
    let onSelect: (ChefMenuAction) -> Void

    private var remainingCalories: Int {
        Int(round(decisionContext?.remaining.calories ?? max(0, (summary?.caloriesGoal ?? 2000) - (summary?.caloriesConsumed ?? 0))))
    }

    private var proteinGap: Int {
        Int(round(decisionContext?.remaining.protein ?? max(0, (summary?.proteinGoal ?? 80) - (summary?.protein ?? 0))))
    }

    private var windowLabel: String {
        let label = decisionContext?.eatingWindow.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "按轻断食设置" : label
    }

    private var nextMealAdvice: String {
        let text = decisionContext?.suggestedNextMeal.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        if remainingCalories < 350 { return "高蛋白、低油、小份量" }
        if proteinGap > 25 { return "高蛋白、低油、适量碳水" }
        return "清淡、蔬菜优先、适量主食"
    }

    private var notRecommended: String {
        let text = decisionContext?.notRecommended.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        return remainingCalories < 350 ? "炸鸡、奶茶、甜点、大份主食" : "炸鸡、奶茶、甜点"
    }

    private let actions: [(ChefMenuAction, String, String, String)] = [
        (.delivery, "现在点外卖", "按今天剩余热量，直接挑能吃的一份。", "bag.fill"),
        (.cook, "用现有食材配一餐", "输入家里有什么，给你一份稳的搭配。", "takeoutbag.and.cup.and.straw.fill"),
        (.menuScan, "拍菜单帮我选", "菜单或外卖截图都可以，先告诉你选哪份。", "camera.fill"),
        (.convenience, "便利店买什么", "饭团、鸡蛋、酸奶、鸡胸肉，组合给你。", "storefront.fill"),
        (.mealPlan, "安排接下来几天", "做餐单和购物清单，少想几顿饭。", "calendar"),
        (.coach, "问一句怎么吃", "聚餐、奶茶、断食后第一餐都能问。", "message.fill"),
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isOpen {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture(perform: onClose)

                VStack {
                    Spacer()
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            statusCard
                            ForEach(actions, id: \.1) { action in
                                chefAction(action)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: UIScreen.main.bounds.height - 168)
                    .background(.white.opacity(0.93))
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 32).stroke(.white.opacity(0.76), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 34, x: 0, y: 20)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 116)
                }
                .transition(.scale(scale: 0.95, anchor: .bottom).combined(with: .opacity).combined(with: .move(edge: .bottom)))

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(LinearGradient(colors: [Color(hex: "1D2026"), Color(hex: "0E1115")], startPoint: .top, endPoint: .bottom))
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 14)
                }
                .accessibilityLabel("关闭快捷入口")
                .padding(.trailing, 24)
                .padding(.bottom, 18)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isOpen)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chef.hat.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text("下一餐怎么吃？")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(.white)
                    HStack(spacing: 12) {
                        chefMetric("今日还可吃", "\(remainingCalories)", "千卡")
                        chefMetric("蛋白质还差", "\(proteinGap)", "g")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("当前进食窗口：\(windowLabel)")
                Text("建议下一餐：\(nextMealAdvice)")
                Text("不建议：\(notRecommended)")
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(18)
        .background(LinearGradient(colors: [Color(hex: "171A20"), Color(hex: "2A3038")], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func chefMetric(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white.opacity(0.44))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 27, weight: .black))
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white.opacity(0.56))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chefAction(_ item: (ChefMenuAction, String, String, String)) -> some View {
        Button {
            onSelect(item.0)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: item.3)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(LinearGradient(colors: [Color(hex: "242832"), Color(hex: "0E1115")], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.1)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(item.2)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }
}

private struct MealAnalysisOverlay: View {
    let message: String

    private var cleanMessage: String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "正在识别内容，结果出来后可以直接修改。"
        }
        let lower = text.lowercased()
        if text.count > 70
            || text.contains("{")
            || text.contains("}")
            || lower.contains("api")
            || lower.contains("server")
            || lower.contains("pipeline")
            || lower.contains("metadata")
            || lower.contains("endpoint")
            || lower.contains("traceback")
            || lower.contains("errno")
            || lower.contains("http") {
            return "正在处理照片，结果出来后可以直接修改。"
        }
        return text
    }

    private var helperText: String {
        if cleanMessage.contains("条形码") || cleanMessage.contains("条码") {
            return "没查到也可以直接搜索食品名。"
        }
        if cleanMessage.contains("标签") || cleanMessage.contains("评分") {
            return "读不清时重新拍完整营养表会更准。"
        }
        return "结果不准也没关系，下一页能改食物、克重和吃了多少。"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "F2F7FF"))
                            .frame(width: 54, height: 54)
                        ProgressView()
                            .tint(Color(hex: "111318"))
                            .scaleEffect(1.05)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("正在算这餐")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                        Text("简单餐几秒，复杂拼盘会久一点")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color(hex: "8B94A3"))
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 10) {
                    analysisStep(title: cleanMessage, active: true)
                    analysisStep(title: "整理成可修改的食物明细", active: false)
                    analysisStep(title: "不准可以马上改克重和食物名", active: false)
                }

                Text(helperText)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "6B7280"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .background(.white.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 16)
            .padding(.horizontal, 34)
        }
    }

    private func analysisStep(title: String, active: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(active ? Color(hex: "111318") : Color(hex: "D8DEE8"))
                .frame(width: active ? 9 : 7, height: active ? 9 : 7)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(active ? Color(hex: "111318") : Color(hex: "8B94A3"))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct BarcodeEntrySheetView: View {
    @Binding var barcode: String
    let onClose: () -> Void
    let onCamera: () -> Void
    let onResult: (DescribeMealResponse) -> Void
    let onError: (String) -> Void

    @State private var loading = false
    @State private var saving = false
    @State private var result: DescribeMealResponse?
    @State private var savedMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(Color(hex: "DEDEE5"))
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("条形码")
                        .font(.system(size: 24, weight: .black))
                    Text("输入包装食品条码，或拍照读取条码。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
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
                .accessibilityLabel("关闭条形码查询")
            }

            TextField("例如 049000000443", text: $barcode)
                .keyboardType(.numberPad)
                .font(.system(size: 20, weight: .black))
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if !barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validBarcode == nil {
                Text("请输入 8–14 位数字条形码。")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "D93025"))
            }

            Button {
                Task { await lookup() }
            } label: {
                HStack {
                    if loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "barcode.viewfinder")
                    }
                    Text("查询条形码")
                }
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .disabled(loading || validBarcode == nil)
            .opacity(loading || validBarcode == nil ? 0.45 : 1)

            if let result, let food = result.foods.first {
                barcodeResultCard(result: result, food: food)
            } else if !savedMessage.isEmpty {
                messageCard(savedMessage)
            }

            Button(action: onCamera) {
                HStack {
                    Image(systemName: "camera.fill")
                    Text("拍摄条形码")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .padding(16)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
            .buttonStyle(.plain)
            }
            .padding(22)
        }
        .presentationDetents([.height(result == nil ? 390 : 620), .large])
        .presentationDragIndicator(.hidden)
    }

    private func barcodeResultCard(result: DescribeMealResponse, food: FoodItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color(hex: "2563EB"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(food.name)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .lineLimit(2)
                    Text("\(food.servingSize) · 记录前需确认")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(round(food.calories)))")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("千卡")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                macroPill("蛋白", value: food.protein)
                macroPill("碳水", value: food.carbs)
                macroPill("脂肪", value: food.fat)
            }

            if !savedMessage.isEmpty {
                messageCard(savedMessage)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await saveFirstFood(food) }
                } label: {
                    HStack(spacing: 6) {
                        if saving {
                            ProgressView()
                                .tint(Color(hex: "111318"))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "star.fill")
                                .accessibilityHidden(true)
                        }
                        Text(saving ? "保存中" : "保存食物")
                    }
                    .font(.system(size: 13, weight: .black))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color(hex: "F7F8FA"))
                    .foregroundStyle(Color(hex: "111318"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(saving)

                Button {
                    onResult(result)
                } label: {
                    Text("确认份量")
                        .font(.system(size: 13, weight: .black))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
    }

    private func macroPill(_ label: String, value: Double) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            Text("\(Int(round(value)))克")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(hex: "F7F8FA"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func messageCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color(hex: "4B5563"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(hex: "F7F8FA"))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func lookup() async {
        guard !loading else { return }
        guard let code = validBarcode else {
            savedMessage = "请输入 8–14 位数字条形码。"
            result = nil
            return
        }
        loading = true
        savedMessage = ""
        defer { loading = false }
        do {
            let response = try await APIClient.shared.lookupBarcode(code)
            guard !response.foods.isEmpty else {
                let message = response.description ?? "没有找到这个条形码对应的食品"
                savedMessage = "\(message)。可以用食品标签手动录入后保存。"
                onError(message)
                return
            }
            result = response
            savedMessage = "已找到条码食品，请确认每份克数和实际份数。"
        } catch {
            let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if isConnectionFailureMessage(raw) {
                onError("现在没连上，条码还没有查到；号码已经保留，检查网络后重试。")
            } else {
                onError(friendlyContentError(error, fallback: "这个条码暂时没查到，可以手动输入或搜索食品名。"))
            }
        }
    }

    private var validBarcode: String? {
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...14).contains(code.count), code.allSatisfy(\.isNumber) else { return nil }
        return code
    }

    private func saveFirstFood(_ food: FoodItem) async {
        guard !saving else { return }
        saving = true
        savedMessage = ""
        defer { saving = false }
        do {
            let saved = try await APIClient.shared.saveFoodTemplate(food)
            savedMessage = "已保存到我的食物：\(saved.name)。"
        } catch {
            savedMessage = friendlyContentError(error, fallback: "这个食品暂时没保存上，稍后再点一次。")
        }
    }
}

enum ReminderNotificationScheduler {
    private static let identifierPrefix = "calai.reminder."

    static func sync(reminders: [ReminderItem]) async -> String {
        await removeExistingRequests()
        let enabled = reminders.filter { $0.enabled }
        guard !enabled.isEmpty else {
            return "已保存提醒，并已关闭本地通知。"
        }

        let center = UNUserNotificationCenter.current()
        let authorized = await ensureAuthorization(center: center)
        guard authorized else {
            return "已保存提醒；本地通知未开启，请到系统设置允许通知。"
        }

        var scheduledCount = 0
        for reminder in enabled {
            scheduledCount += await schedule(reminder: reminder, center: center)
        }
        if scheduledCount == 0 {
            return "已保存提醒；没有可用的提醒时间，请检查时间格式。"
        }
        return "已保存提醒，并已安排 \(scheduledCount) 个本地通知。"
    }

    private static func ensureAuthorization(center: UNUserNotificationCenter) async -> Bool {
        let settings = await notificationSettings(center: center)
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await requestAuthorization(center: center)) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func schedule(reminder: ReminderItem, center: UNUserNotificationCenter) async -> Int {
        guard let time = parseTime(reminder.time) else { return 0 }
        let days = parseWeekdays(reminder.daysOfWeek)
        let content = UNMutableNotificationContent()
        content.title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "记录提醒" : reminder.title
        content.body = bodyText(for: reminder)
        content.sound = .default

        if days.isEmpty {
            var components = DateComponents()
            components.hour = time.hour
            components.minute = time.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            await addRequest(center: center, identifier: identifier(for: reminder), content: content, trigger: trigger)
            return 1
        }

        var count = 0
        for weekday in days {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = time.hour
            components.minute = time.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            await addRequest(center: center, identifier: "\(identifier(for: reminder)).\(weekday)", content: content, trigger: trigger)
            count += 1
        }
        return count
    }

    private static func identifier(for reminder: ReminderItem) -> String {
        let raw = reminder.id.isEmpty ? "\(reminder.mealType)-\(reminder.time)" : reminder.id
        let safe = raw.replacingOccurrences(of: " ", with: "-")
        return identifierPrefix + safe
    }

    private static func bodyText(for reminder: ReminderItem) -> String {
        switch reminder.category {
        case "meal": return "拍照或手动记录这一餐，今日状态分会自动更新。"
        case "hydration": return "补一杯水，保持有效补水进度。"
        case "fasting": return "检查轻断食进度，别忘了记录进食窗口。"
        default: return "打开食光，完成今天的健康记录。"
        }
    }

    private static func parseTime(_ value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func parseWeekdays(_ value: String) -> [Int] {
        value
            .split { ",，;； ".contains($0) }
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .compactMap { day -> Int? in
                if (1...7).contains(day) {
                    return day == 7 ? 1 : day + 1
                }
                return nil
            }
    }

    private static func removeExistingRequests() async {
        let center = UNUserNotificationCenter.current()
        let requests = await pendingRequests(center: center)
        let ids = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private static func pendingRequests(center: UNUserNotificationCenter) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private static func notificationSettings(center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static func requestAuthorization(center: UNUserNotificationCenter) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func addRequest(
        center: UNUserNotificationCenter,
        identifier: String,
        content: UNNotificationContent,
        trigger: UNNotificationTrigger
    ) async {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

struct SettingsPageView: View {
    let onClose: () -> Void
    let onOpenPreferences: () -> Void
    let onOpenOnboarding: () -> Void
    let onOpenFasting: () -> Void
    let onOpenBadges: () -> Void
    let onOpenFriends: () -> Void
    let onOpenWeightHistory: () -> Void
    let onHealthSynced: () -> Void
    @StateObject private var healthService = HealthKitSyncService()
    @State private var showHealthSync = false
    @State private var showQwenSettings = false
    @State private var showReminderSettings = false
    @State private var showPrivacySettings = false
    @State private var showDeleteAccount = false
    @State private var reminders: [ReminderItem] = []
    @State private var remindersLoading = false
    @State private var remindersMessage = ""
    @State private var accountMessage = ""
    @State private var exportDocument: AccountExportDocument?
    @State private var showExporter = false
    @AppStorage("cal_health_connected") private var healthConnected = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                SettingsSection(title: "本机与千问") {
                    SettingsRow(icon: "person.crop.circle", label: "个人资料与目标", action: onOpenOnboarding)
                    SettingsRow(icon: "fork.knife", label: "饮食偏好", action: onOpenPreferences)
                    SettingsRow(icon: "sparkles", label: "千问 API Key", value: "图片与聊天", isLast: true) { showQwenSettings = true }
                }
                SettingsSection(title: "同步与授权") {
                    SettingsRow(icon: "heart", label: "苹果健康", value: healthConnected ? "已同步" : "待同步") {
                        showHealthSync = true
                    }
                    SettingsRow(icon: "hand.raised.fill", label: "隐私授权", value: "默认最少") {
                        showPrivacySettings = true
                    }
                    SettingsRow(icon: "bell", label: "记录提醒", value: reminderValue) {
                        remindersMessage = ""
                        showReminderSettings = true
                        Task { await loadReminders() }
                    }
                    SettingsRow(icon: "timer", label: "轻断食", value: "可选", isLast: true, action: onOpenFasting)
                }
                SettingsSection(title: "数据") {
                    SettingsRow(icon: "clock.arrow.circlepath", label: "体重记录", action: onOpenWeightHistory)
                    SettingsRow(icon: "square.and.arrow.up", label: "导出我的数据", value: "JSON") {
                        Task { await exportAccountData() }
                    }
                    SettingsRow(icon: "trash", label: "删除本机记录", value: "不可恢复", isLast: true) {
                        showDeleteAccount = true
                    }
                }
                if !accountMessage.isEmpty {
                    Text(accountMessage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accountMessage.contains("失败") ? Color(hex: "DC2626") : Color(hex: "159BFF"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Link("LightCal 隐私政策", destination: URL(string: "https://github.com/het2333/lightcal/blob/main/docs/privacy.md")!)
                    .font(.footnote)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .background(AppShellBackground())
        .sheet(isPresented: $showQwenSettings) { QwenSettingsView() }
        .sheet(isPresented: $showHealthSync) {
            HealthSyncSheetView(
                service: healthService,
                onClose: {
                    showHealthSync = false
                },
                onSynced: {
                    healthConnected = true
                    onHealthSynced()
                }
            )
        }
        .sheet(isPresented: $showReminderSettings) {
            ReminderSettingsSheet(
                reminders: $reminders,
                loading: remindersLoading,
                message: remindersMessage,
                onClose: { showReminderSettings = false },
                onReload: { Task { await loadReminders(forceDefaults: false) } },
                onSave: { Task { await saveReminders() } }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showPrivacySettings) {
            PrivacyAuthorizationSheet(
                healthConnected: healthConnected,
                onConnectHealth: {
                    showPrivacySettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showHealthSync = true
                    }
                },
                onClose: { showPrivacySettings = false }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountSheet(
                onCancel: { showDeleteAccount = false },
                onDelete: { Task { await deleteAccountData() } }
            )
            .presentationDetents([.height(360)])
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "食光数据导出"
        ) { result in
            if case .failure = result {
                accountMessage = "数据导出失败，请再试一次。"
            }
        }
        .task {
            await loadReminders(forceDefaults: false)
        }
    }

    private var reminderValue: String {
        guard !reminders.isEmpty else { return "未设置" }
        return reminders.contains { $0.enabled } ? "已开启" : "已关闭"
    }

    private func loadReminders(forceDefaults: Bool = true) async {
        guard !remindersLoading else { return }
        remindersLoading = true
        defer { remindersLoading = false }
        do {
            let fetched = try await APIClient.shared.getReminders()
            reminders = fetched.isEmpty && forceDefaults ? Self.defaultReminders : fetched
        } catch {
            remindersMessage = friendlyContentError(error, fallback: "提醒暂时没加载出来，稍后再打开一次。")
            if reminders.isEmpty && forceDefaults {
                reminders = Self.defaultReminders
            }
        }
    }

    private func saveReminders() async {
        guard !remindersLoading else { return }
        remindersLoading = true
        remindersMessage = ""
        defer { remindersLoading = false }
        do {
            reminders = try await APIClient.shared.saveReminders(reminders)
            remindersMessage = await ReminderNotificationScheduler.sync(reminders: reminders)
        } catch {
            remindersMessage = friendlyContentError(error, fallback: "提醒暂时没保存上，稍后再点一次。")
        }
    }

    @MainActor
    private func exportAccountData() async {
        accountMessage = "正在整理你的数据…"
        do {
            let raw = try await APIClient.shared.exportAccountData()
            let object = try JSONSerialization.jsonObject(with: raw)
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            exportDocument = AccountExportDocument(data: pretty)
            accountMessage = "数据已整理好，请选择保存位置。"
            showExporter = true
        } catch {
            accountMessage = friendlyContentError(error, fallback: "数据导出失败，请稍后重试。")
        }
    }

    @MainActor
    private func deleteAccountData() async {
        do {
            _ = try await APIClient.shared.deleteAccountData()
            try QwenCredentials.delete()
            UserDefaults.standard.removeObject(forKey: "onboarded")
            UserDefaults.standard.removeObject(forKey: "profile_avatar_base64")
            accountMessage = "本机记录和千问密钥已删除。重新设置目标后可以继续使用。"
            showDeleteAccount = false
            onOpenOnboarding()
        } catch {
            accountMessage = friendlyContentError(error, fallback: "账户记录删除失败，请稍后重试。")
            showDeleteAccount = false
        }
    }

    private static let defaultReminders: [ReminderItem] = [
        ReminderItem(mealType: "breakfast", time: "08:00", enabled: true, category: "meal", title: "记录早餐"),
        ReminderItem(mealType: "lunch", time: "12:30", enabled: true, category: "meal", title: "记录午餐"),
        ReminderItem(mealType: "dinner", time: "18:30", enabled: true, category: "meal", title: "记录晚餐"),
        ReminderItem(mealType: "hydration", time: "15:00", enabled: true, category: "hydration", title: "补充饮水"),
        ReminderItem(mealType: "fasting", time: "20:30", enabled: false, category: "fasting", title: "轻断食提醒"),
    ]

    private var header: some View {
        CalPageHeader(
            title: "设置",
            subtitle: "目标、提醒和账户",
            systemImage: "slider.horizontal.3"
        ) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            }
            .accessibilityLabel("关闭设置")
        }
    }

}

private struct AccountExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data = Data("{}".utf8)) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data("{}".utf8)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PrivacyAuthorizationSheet: View {
    let healthConnected: Bool
    let onConnectHealth: () -> Void
    let onClose: () -> Void
    @AppStorage("cal_personalization_allowed") private var personalizationAllowed = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                permissionRow(
                    icon: "heart.fill",
                    title: "Apple 健康",
                    detail: healthConnected ? "已连接，可在系统健康设置中随时撤销" : "仅在你主动连接时请求读取权限",
                    trailing: healthConnected ? "已连接" : "去连接",
                    action: healthConnected ? nil : onConnectHealth
                )
                Toggle(isOn: $personalizationAllowed) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("用于个性化建议")
                            .font(.system(size: 15, weight: .black))
                        Text("记录仅保存在本机。是否将记录发送给千问，请在千问设置中单独选择")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color(hex: "20B85A"))
                .padding(15)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                permissionRow(
                    icon: "person.2.slash.fill",
                    title: "公开分享",
                    detail: "本机版不提供好友动态或公开发布。你可通过系统分享自行导出。",
                    trailing: "已关闭",
                    action: nil
                )
                Spacer()
            }
            .padding(20)
            .background(AppShellBackground())
            .navigationTitle("隐私授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onClose).fontWeight(.bold)
                }
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, trailing: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "20B85A"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "EAF8EF"))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .black))
                    Text(detail)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Text(trailing)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(action == nil ? Color.secondary : Color(hex: "20B85A"))
            }
            .padding(15)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

private struct DeleteAccountSheet: View {
    let onCancel: () -> Void
    let onDelete: () -> Void
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 38, height: 5).frame(maxWidth: .infinity)
            Text("删除账户与全部记录")
                .font(.system(size: 22, weight: .black))
            Text("饮食、体重、饮水、运动、目标和进度照片会永久删除，公共食物数据库不会受影响。输入“删除”确认。")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
            TextField("输入：删除", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("永久删除", role: .destructive, action: onDelete)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "DC2626"))
                    .frame(maxWidth: .infinity)
                    .disabled(confirmation != "删除")
            }
            .font(.system(size: 15, weight: .black))
            Spacer()
        }
        .padding(20)
        .background(AppShellBackground())
    }
}

struct ReminderSettingsSheet: View {
    @Binding var reminders: [ReminderItem]
    let loading: Bool
    let message: String
    let onClose: () -> Void
    let onReload: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("打开后，我会按这些时间提醒你记录饮食、喝水或开始轻断食。首次保存会请求通知权限。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .padding(.horizontal, 2)

                    if loading && reminders.isEmpty {
                        CalLoadingCard(
                            title: "正在准备提醒",
                            subtitle: "饮食、饮水和轻断食都会一起带上",
                            systemImage: "bell.badge"
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach($reminders) { $item in
                                reminderRow($item)
                            }
                        }
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(message.contains("失败") || message.contains("错误") ? Color(hex: "DC2626") : Color(hex: "159BFF"))
                            .padding(.horizontal, 2)
                    }

                    Button {
                        reminders.append(ReminderItem(mealType: "custom", time: "09:00", enabled: true, category: "logging", title: "记录提醒"))
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("加一个提醒")
                            Spacer()
                        }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .padding(15)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .padding(.bottom, 88)
            }
            .background(AppShellBackground())
            .navigationTitle("记录提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose)
                        .font(.system(size: 15, weight: .bold))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onReload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Text("先不保存")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
                    }
                    Button(action: onSave) {
                        HStack(spacing: 8) {
                            if loading {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.78)
                            }
                            Text("保存提醒")
                                .font(.system(size: 15, weight: .black))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .disabled(loading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func reminderRow(_ item: Binding<ReminderItem>) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: item.wrappedValue.category))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 38, height: 38)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 5) {
                    TextField("提醒标题", text: item.title)
                        .font(.system(size: 15, weight: .black))
                        .textInputAutocapitalization(.never)
                    Text(categoryLabel(item.wrappedValue.category))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: item.enabled)
                    .labelsHidden()
                    .tint(Color.black)
            }

            HStack(spacing: 8) {
                field("类型", text: item.mealType)
                field("时间", text: item.time, keyboard: .numbersAndPunctuation)
                field("分类", text: item.category)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 18, x: 0, y: 10)
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color(hex: "F7F8FA"))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func iconName(for category: String) -> String {
        switch category {
        case "hydration": return "drop.fill"
        case "fasting": return "timer"
        case "challenge": return "flag.fill"
        default: return "bell.fill"
        }
    }

    private func categoryLabel(_ category: String) -> String {
        switch category {
        case "hydration": return "饮水"
        case "fasting": return "轻断食"
        case "challenge": return "挑战"
        case "meal": return "餐食"
        default: return "记录"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                content
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "F0F0F3"), lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 18, x: 0, y: 10)
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let label: String
    var value: String = ""
    var isLast: Bool = false
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { action?() }) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(width: 34, height: 34)
                        .background(Color(hex: "F7F8FA"))
                        .clipShape(Circle())
                    Text(label)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: "111318"))
                    Spacer()
                    if !value.isEmpty {
                        Text(value)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    if action != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "C0C4CB"))
                    }
                }
                .frame(height: 56)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(action != nil)
            if !isLast {
                Rectangle()
                    .fill(Color(hex: "F0F0F3"))
                    .frame(height: 1)
                    .padding(.leading, 62)
            }
        }
    }
}

private struct StatusMessageToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color(hex: "159BFF"))
            Text(message)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "1F2937"))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "E5E7EB"), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 22, x: 0, y: 12)
    }
}

private struct HydrationUndoToast: View {
    let amountMl: Double
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "drop.fill")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color(hex: "159BFF"))
            Text("已加 \(Int(round(amountMl))) ml")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "1F2937"))
            Spacer()
            Button("撤销", action: onUndo)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(hex: "159BFF"))
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Color(hex: "EAF4FF"))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "DDEBFA"), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 22, x: 0, y: 12)
    }
}

private struct LazyInfoPageHost: View {
    let logDate: String
    let onChanged: () -> Void
    let onScanFood: () -> Void
    let onManualLog: () -> Void
    let onSearchFood: () -> Void
    let onBarcode: () -> Void
    let onLabel: () -> Void
    let onVoiceLog: () -> Void
    let onOpenHydration: () -> Void
    let onOpenFasting: () -> Void
    let onOpenBadges: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        LightweightProfilePageView(
            onScanFood: onScanFood,
            onManualLog: onManualLog,
            onSearchFood: onSearchFood,
            onBarcode: onBarcode,
            onLabel: onLabel,
            onVoiceLog: onVoiceLog,
            onOpenHydration: onOpenHydration,
            onOpenFasting: onOpenFasting,
            onOpenBadges: onOpenBadges,
            onOpenSettings: onOpenSettings
        )
        .onDisappear {
            onChanged()
        }
    }
}

private struct LightweightProfilePageView: View {
    let onScanFood: () -> Void
    let onManualLog: () -> Void
    let onSearchFood: () -> Void
    let onBarcode: () -> Void
    let onLabel: () -> Void
    let onVoiceLog: () -> Void
    let onOpenHydration: () -> Void
    let onOpenFasting: () -> Void
    let onOpenBadges: () -> Void
    let onOpenSettings: () -> Void
    @State private var goalPlan: GoalPlan?
    @State private var latestWeightKg: Double?
    @State private var avatarSelection: PhotosPickerItem?
    @State private var showIdentityEditor = false
    @AppStorage("profile_display_name") private var displayName = "我的账户"
    @AppStorage("profile_avatar_base64") private var avatarBase64 = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                profileHeader
                    .padding(.top, 24)

                profileCard

                profileSection(title: "账户与目标") {
                    profileRow(icon: "person.crop.circle", title: "个人资料", subtitle: "头像和账户名称", tint: Color(hex: "159BFF")) {
                        showIdentityEditor = true
                    }
                    profileRow(icon: "target", title: "个人资料与目标", subtitle: "身体数据、每日目标和饮食偏好", tint: Color(hex: "21B95B"), action: onOpenSettings)
                }

                profileSection(title: "数据与隐私") {
                    profileRow(icon: "heart.fill", title: "健康同步", subtitle: "需要同步时再授权 Apple 健康", tint: Color(hex: "FF5B6B"), action: onOpenSettings)
                    profileRow(icon: "hand.raised.fill", title: "数据隐私", subtitle: "本机存储、健康授权与千问数据发送", tint: Color(hex: "7C5CFC"), action: onOpenSettings)
                    profileRow(icon: "square.and.arrow.up", title: "导出我的数据", subtitle: "下载饮食、体重、饮水和目标记录", tint: Color(hex: "159BFF"), action: onOpenSettings)
                    profileRow(icon: "gearshape.fill", title: "设置", subtitle: "千问 API Key、提醒和本机数据", action: onOpenSettings)
                }

                Text("食光")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "A0A6AF"))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 122)
        }
        .background(AppShellBackground())
        .task {
            async let planTask = APIClient.shared.getGoalPlan()
            async let weightsTask = APIClient.shared.getWeights(days: 30)
            goalPlan = try? await planTask
            let weights = (try? await weightsTask) ?? []
            latestWeightKg = weights.last?.weightKg
        }
        .onChange(of: avatarSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.78) {
                    await MainActor.run { avatarBase64 = jpeg.base64EncodedString() }
                }
            }
        }
        .sheet(isPresented: $showIdentityEditor) {
            ProfileIdentityEditSheet(name: $displayName, onClose: { showIdentityEditor = false })
                .presentationDetents([.height(260)])
        }
    }

    private var profileHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("我的")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("账户、目标和数据管理")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "758093"))
            }
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.95))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
    }

    private var profileCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                PhotosPicker(selection: $avatarSelection, matching: .images) {
                    avatarView
                        .frame(width: 68, height: 68)
                        .clipShape(Circle())
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color(hex: "20B85A"))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 21, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text("本机账户 · 数据可随时导出")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "758093"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                Button(action: { showIdentityEditor = true }) {
                    Text("编辑资料")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color(hex: "20B85A"))
                        .frame(width: 82, height: 38)
                        .background(Color(hex: "EAF8EF"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                profileMetric(title: "当前体重", value: weightText(latestWeightKg ?? goalPlan?.currentWeightKg), color: Color(hex: "159BFF"), icon: "scalemass.fill", action: onOpenSettings)
                profileMetric(title: "目标体重", value: weightText(goalPlan?.goalWeightKg), color: Color(hex: "21B95B"), icon: "target", action: onOpenSettings)
                profileMetric(title: "每日目标", value: calorieText, color: Color(hex: "FF9F1C"), icon: "flame.fill", action: onOpenSettings)
            }
        }
        .padding(16)
        .background(.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.75), lineWidth: 1))
        .shadow(color: Color(hex: "5E8CAA").opacity(0.12), radius: 24, x: 0, y: 14)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let data = Data(base64Encoded: avatarBase64), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(hex: "DDF4FF"), Color(hex: "E6F9EC")], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(Color(hex: "55B98B"))
            }
        }
    }

    private func weightText(_ value: Double?) -> String {
        guard let value else { return "待设置" }
        return String(format: "%.1f kg", value)
    }

    private var calorieText: String {
        guard let value = goalPlan?.dailyCalorieTarget else { return "待设置" }
        return "\(Int(round(value))) kcal"
    }

    private func profileMetric(title: String, value: String, color: Color, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "8A94A3"))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(hex: "F7FBFF"))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func profileSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(Color(hex: "111318"))
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                content()
            }
            .background(.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.72), lineWidth: 1))
            .shadow(color: Color(hex: "5E8CAA").opacity(0.08), radius: 18, x: 0, y: 10)
        }
    }

    private func profileRow(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color = Color(hex: "111318"),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(subtitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(hex: "A8B0BC"))
            }
            .padding(.horizontal, 14)
            .frame(height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileIdentityEditSheet: View {
    @Binding var name: String
    let onClose: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 38, height: 5).frame(maxWidth: .infinity)
            Text("账户名称")
                .font(.system(size: 22, weight: .black))
            TextField("你的名字", text: $draft)
                .textFieldStyle(.roundedBorder)
            Button {
                let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { name = clean }
                onClose()
            } label: {
                Text("保存")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color(hex: "20B85A"))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(20)
        .background(AppShellBackground())
        .onAppear { draft = name }
    }
}

private struct QuickActionSheetView: View {
    let onClose: () -> Void
    let onScan: () -> Void
    let onManual: () -> Void
    let onVoice: () -> Void
    let onText: () -> Void
    let onBarcode: () -> Void
    let onLabel: () -> Void
    let onSearch: () -> Void
    let onFrequent: () -> Void
    let onExercise: () -> Void
    let onDrink: (Double) -> Void
    let onFasting: () -> Void
    let onCoach: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                header
                photoAction

                HStack(spacing: 10) {
                    primaryInputTile(icon: "mic.fill", title: "语音记录", subtitle: "说一句就整理", tint: Color(hex: "159BFF"), action: onVoice)
                    primaryInputTile(icon: "text.bubble.fill", title: "文字描述", subtitle: "输入这一餐", tint: Color(hex: "8B5CF6"), action: onText)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("其他食物记录")
                    HStack(spacing: 8) {
                        compactTool(icon: "barcode.viewfinder", title: "扫条码", tint: Color(hex: "2563EB"), action: onBarcode)
                        compactTool(icon: "list.clipboard.fill", title: "营养表", tint: Color(hex: "F59E0B"), action: onLabel)
                        compactTool(icon: "magnifyingglass", title: "搜索食物", tint: Color(hex: "21B95B"), action: onSearch)
                    }
                    HStack(spacing: 8) {
                        compactTool(icon: "square.and.pencil", title: "手动添加", tint: Color(hex: "64748B"), action: onManual)
                        compactTool(icon: "star.fill", title: "常吃收藏", tint: Color(hex: "F97316"), action: onFrequent)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("生活记录")
                    HStack(spacing: 8) {
                        waterTile
                        secondaryTile(icon: "figure.run", title: "运动", subtitle: "时长与强度", tint: Color(hex: "FF8B2E"), action: onExercise)
                        secondaryTile(icon: "timer", title: "轻断食", subtitle: "开始计时", tint: Color(hex: "20C05C"), action: onFasting)
                    }
                }

                Button(action: onCoach) {
                    HStack(spacing: 12) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color(hex: "111318"))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("饮食教练")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(Color(hex: "111318"))
                            Text("聚餐、奶茶或下一餐不知道怎么吃时，先问一句")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color(hex: "9CA3AF"))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 58)
                    .background(Color(hex: "F7F8FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开饮食教练")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
        .background(Color.white)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("记下这一餐")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                Text("选你现在最顺手的方式")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "8E949E"))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "6D7480"))
                    .frame(width: 36, height: 36)
                    .background(Color(hex: "F3F4F6"))
                    .clipShape(Circle())
            }
            .accessibilityLabel("关闭记录入口")
        }
    }

    private var photoAction: some View {
        Button(action: onScan) {
            HStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 23, weight: .black))
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(0.16))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("拍照记录")
                            .font(.system(size: 18, weight: .black))
                        Text("推荐")
                            .font(.system(size: 10, weight: .black))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(.white.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    Text("整餐拍下，识别可在后台继续")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .black))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(Color(hex: "111318"))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(Color(hex: "7B828D"))
    }

    private func primaryInputTile(icon: String, title: String, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                    Text(subtitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "8E949E"))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(Color(hex: "F7F9FB"))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func compactTool(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.11))
                    .clipShape(Circle())
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(Color(hex: "F7F9FB"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var waterTile: some View {
        Button {
            onDrink(250)
        } label: {
            secondaryTileLabel(icon: "drop.fill", title: "饮水", subtitle: "+250 ml", tint: Color(hex: "159BFF"))
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach([150, 250, 350, 500], id: \.self) { amount in
                Button {
                    onDrink(Double(amount))
                } label: {
                    Label("+\(amount) ml", systemImage: amount == 250 ? "checkmark.circle.fill" : "drop")
                }
            }
        }
        .accessibilityLabel("添加 250 毫升饮水，长按选择容量")
    }

    private func secondaryTile(icon: String, title: String, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            secondaryTileLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func secondaryTileLabel(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13))
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(hex: "111318"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(subtitle)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color(hex: "8E949E"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .background(Color(hex: "F7F9FB"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PremiumBottomNav: View {
    @Binding var selectedTab: Int
    let onTabTap: (Int) -> Void
    let onAdd: () -> Void

    init(
        selectedTab: Binding<Int>,
        onTabTap: @escaping (Int) -> Void = { _ in },
        onAdd: @escaping () -> Void
    ) {
        self._selectedTab = selectedTab
        self.onTabTap = onTabTap
        self.onAdd = onAdd
    }

    private let items: [(Int, String, String)] = [
        (0, "首页", "house"),
        (1, "记录", "list.clipboard"),
        (2, "千问", "message"),
        (3, "我的", "person.crop.circle"),
    ]

    var body: some View {
        GeometryReader { proxy in
            VStack {
                Spacer()
                ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.white.opacity(0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color(hex: "EEF1F4"), lineWidth: 1)
                    )

                HStack {
                    HStack(spacing: 4) {
                        navButton(items[0])
                        navButton(items[1])
                    }
                    Spacer().frame(width: 72)
                    HStack(spacing: 4) {
                        navButton(items[2])
                        navButton(items[3])
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 64)

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(LinearGradient(colors: [Color(hex: "2DD4BF"), Color(hex: "35C86F")], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.92), lineWidth: 3))
                        .shadow(color: Color(hex: "22C55E").opacity(0.18), radius: 6, x: 0, y: 3)
                }
                .accessibilityLabel("打开快捷入口")
                .offset(y: -5)
                }
                .frame(height: 68)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            .offset(y: proxy.safeAreaInsets.bottom * 0.7)
        }
        .ignoresSafeArea(.keyboard)
    }

    private func navButton(_ item: (Int, String, String)) -> some View {
        let active = selectedTab == item.0
        return Button {
            onTabTap(item.0)
            selectedTab = item.0
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.2)
                    .font(.system(size: 21, weight: active ? .black : .semibold))
                Text(item.1)
                    .font(.system(size: 10, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Color(hex: "35C86F") : Color(hex: "66758A"))
            .frame(width: 58, height: 50)
            .background(active ? Color(hex: "ECF9F0") : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.1)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

extension DescribeMealResponse: Identifiable {
    public var id: String { UUID().uuidString }
}
