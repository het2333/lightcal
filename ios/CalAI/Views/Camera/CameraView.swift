import SwiftUI
import AVFoundation
import UIKit
import ImageIO

struct CameraView: View {
    let source: String
    let onCapture: (MealCapture) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var showQwenSettings = false
    @State private var showPicker = false
    @State private var showAuxiliaryPicker = false
    @State private var activeSource: String
    @State private var pendingCapture: MealCapture?
    @StateObject private var camera = FoodCameraModel()

    init(source: String = "image_scan", onCapture: @escaping (MealCapture) -> Void) {
        self.source = source
        self.onCapture = onCapture
        _activeSource = State(initialValue: source)
    }

    private var frameText: String {
        switch activeSource {
        case "label_scan": return "把营养表放进框里"
        case "barcode_camera": return "把条码放进框里"
        default: return "把整盘放进框里"
        }
    }

    private var subtitleText: String {
        switch activeSource {
        case "label_scan": return "拍完直接读营养表"
        case "barcode_camera": return "对准后自动识别"
        default: return "拍完会算热量和份量"
        }
    }

    private var centerIcon: String {
        switch activeSource {
        case "label_scan": return "list.clipboard"
        case "barcode_camera": return "barcode.viewfinder"
        default: return "camera.viewfinder"
        }
    }

    private var guidanceText: String {
        switch activeSource {
        case "label_scan": return "字要清楚，四角尽量完整"
        case "barcode_camera": return "保持一秒，别晃动"
        default: return "看得到碗盘边缘，份量更稳"
        }
    }

    private var captureAccessibilityLabel: String {
        activeSource == "label_scan" ? "拍摄营养标签" : "拍摄食物"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(camera.isConfigured ? 0 : 0.55))

            if let configurationError = camera.configurationError {
                CameraErrorView(
                    message: configurationError,
                    showUpload: activeSource != "barcode_camera",
                    onClose: {
                        dismiss()
                    },
                    onRetry: {
                        camera.requestAccessAndConfigure(
                            barcodeMode: activeSource == "barcode_camera",
                            depthCaptureMode: false
                        )
                    },
                    onUpload: {
                        showPicker = true
                    }
                )
                .padding(.horizontal, 24)
            } else {
                VStack {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .black))
                                .foregroundColor(.white)
                                .frame(width: 48, height: 48)
                                .background(Color.black.opacity(0.38))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("关闭相机")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(activeSource == "barcode_camera" ? "条形码扫描器" : activeSource == "label_scan" ? "营养标签扫描器" : "扫描食物")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(.white)
                            Text(subtitleText)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.66))
                        }

                        Spacer()

                        Button { showQwenSettings = true } label: {
                            Image(systemName: "key.fill").foregroundStyle(.white).padding(12).background(.black.opacity(0.4)).clipShape(Circle())
                        }.accessibilityLabel("千问设置")
                        topModeBadge
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                Spacer()

                    ZStack {
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .strokeBorder(.white.opacity(0.28), style: StrokeStyle(lineWidth: 2, dash: [9, 5]))
                            .frame(width: 278, height: 278)
                            .overlay(alignment: .topLeading) { cornerMark.rotationEffect(.degrees(0)) }
                            .overlay(alignment: .topTrailing) { cornerMark.rotationEffect(.degrees(90)) }
                            .overlay(alignment: .bottomTrailing) { cornerMark.rotationEffect(.degrees(180)) }
                            .overlay(alignment: .bottomLeading) { cornerMark.rotationEffect(.degrees(270)) }

                        scanCallouts

                        VStack(spacing: 9) {
                            Image(systemName: centerIcon)
                                .font(.system(size: 30, weight: .black))
                                .foregroundStyle(.white.opacity(0.9))
                                .accessibilityHidden(true)
                            Text(frameText)
                                .font(.system(size: 14, weight: .black))
                                .foregroundColor(.white)
                            Text(guidanceText)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.58))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(Color.black.opacity(0.26))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .overlay(alignment: .bottom) {
                        scanModePill
                            .offset(y: 54)
                    }

                Spacer()

                // Controls
                VStack(spacing: 18) {
                    cameraModeSelector

                    HStack(spacing: 40) {
                    // Photo fallback for simulator, camera issues, and saved labels/meals.
                    if activeSource == "barcode_camera" {
                        Spacer()
                            .frame(width: 48, height: 48)
                    } else {
                        Button {
                            showPicker = true
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 20, weight: .bold))
                                    .accessibilityHidden(true)
                                Text("选照片")
                                    .font(.system(size: 10, weight: .black))
                            }
                            .foregroundColor(.white)
                            .frame(width: 54, height: 54)
                            .background(Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .accessibilityLabel("从相册选择照片")
	                    }

                    // Capture
                    if activeSource == "barcode_camera" {
                        VStack(spacing: 6) {
	                            Image(systemName: "barcode.viewfinder")
	                                .font(.system(size: 28, weight: .bold))
	                                .accessibilityHidden(true)
	                            Text("自动扫描")
                                .font(.system(size: 11, weight: .black))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 76)
                        .background(Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        Button {
                            camera.capture()
                        } label: {
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 4)
                                .frame(width: 76, height: 76)
                                .overlay(
                                    Circle()
                                        .fill(camera.isCapturing ? Color.gray : Color.white)
                                        .frame(width: 62, height: 62)
                                )
                        }
	                        .disabled(!camera.isConfigured || camera.isCapturing)
	                        .accessibilityLabel(camera.isCapturing ? "正在拍摄" : captureAccessibilityLabel)
	                    }

                    // Close
                    Button {
                        dismiss()
                    } label: {
	                        Image(systemName: "xmark")
	                            .font(.title2)
	                            .foregroundColor(.white)
	                            .frame(width: 48, height: 48)
		                    }
		                    .accessibilityLabel("关闭相机")
		                }
                }
                .padding(.bottom, 50)
                }
            }

            if camera.isCapturing {
                CaptureProgressOverlay(source: activeSource)
                    .padding(.horizontal, 30)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }

            if let pendingCapture, let image = previewImage(for: pendingCapture) {
                CaptureReviewOverlay(
                    image: image,
                    hasDepth: pendingCapture.hasDepthCaptureBundle,
                    auxiliaryCount: pendingCapture.auxiliaryImagesBase64.count,
                    onRetake: retakePhoto,
                    onAddAuxiliary: { showAuxiliaryPicker = true },
                    onUsePhoto: { usePendingCapture(pendingCapture) }
                )
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: camera.isCapturing)
        .sheet(isPresented: $showPicker) {
            ImagePicker { image in
                if let data = image.jpegData(compressionQuality: 0.92) {
                    prepareCapture(
                        MealCapture(
                            imageBase64: data.base64EncodedString(),
                            depthMetadata: nil,
                            captureMetadata: [
                                "source": activeSource == "image_scan" ? "library" : activeSource,
                                "has_depth": false,
                                "image_bytes": data.count,
                                "image_width": Int(image.size.width * image.scale),
                                "image_height": Int(image.size.height * image.scale),
                                "photo_quality": "library_original_jpeg_0.92"
                            ]
                        )
                    )
                }
            }
        }
        .sheet(isPresented: $showAuxiliaryPicker) {
            ImagePicker { image in
                guard let data = image.jpegData(compressionQuality: 0.88), var capture = pendingCapture else { return }
                if capture.auxiliaryImagesBase64.count < 4 {
                    capture.auxiliaryImagesBase64.append(data.base64EncodedString())
                    pendingCapture = capture
                }
            }
        }
        .sheet(isPresented: $showQwenSettings) { QwenSettingsView() }
        .onAppear {
            camera.onCapture = { capture in
                var metadata = capture.captureMetadata
                metadata["source"] = activeSource
                DispatchQueue.main.async {
                    prepareCapture(
                        MealCapture(
                            imageBase64: capture.imageBase64,
                            depthMetadata: capture.depthMetadata,
                            captureMetadata: metadata,
                            auxiliaryImagesBase64: capture.auxiliaryImagesBase64,
                            depthBundle: capture.depthBundle
                        )
                    )
                }
            }
            camera.onBarcode = { code in
                onCapture(
                    MealCapture(
                        imageBase64: "",
                        depthMetadata: nil,
                        captureMetadata: [
                            "source": "barcode_scan",
                            "barcode": code,
                            "has_depth": false,
                            "photo_quality": "barcode_metadata"
                        ]
                    )
                )
            }
            camera.requestAccessAndConfigure(
                barcodeMode: activeSource == "barcode_camera",
                depthCaptureMode: false
            )
        }
        .onChange(of: activeSource) { _, newSource in
            camera.requestAccessAndConfigure(
                barcodeMode: newSource == "barcode_camera",
                depthCaptureMode: false
            )
        }
        .onDisappear {
            camera.stop()
        }
    }

    private var cornerMark: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 24))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 24, y: 0))
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        .frame(width: 34, height: 34)
        .padding(18)
    }

    @ViewBuilder
    private var topModeBadge: some View {
        if activeSource == "image_scan" {
            CameraModeBadge(icon: "viewfinder", title: camera.isCapturing ? "正在拍" : "整盘入镜")
        } else if activeSource == "label_scan" {
            CameraModeBadge(icon: "text.viewfinder", title: "拍营养表")
        } else {
            CameraModeBadge(icon: "barcode.viewfinder", title: "条码识别")
        }
    }

    @ViewBuilder
    private var scanCallouts: some View {
        if activeSource == "barcode_camera" {
            scanBubble("条形码", icon: "barcode.viewfinder")
                .offset(x: 0, y: -126)
            scanBubble("包装食品", icon: "shippingbox.fill")
                .offset(x: 112, y: 54)
        } else if activeSource == "label_scan" {
            scanBubble("营养表", icon: "list.clipboard")
                .offset(x: -112, y: -92)
            scanBubble("每份含量", icon: "number")
                .offset(x: 112, y: 72)
        } else {
            scanBubble("食物完整", icon: "fork.knife")
                .offset(x: -118, y: -96)
            scanBubble("碗盘边缘", icon: "circle.dashed")
                .offset(x: 116, y: -58)
            scanBubble("别太近", icon: "viewfinder")
                .offset(x: 0, y: 132)
        }
    }

    private var scanModePill: some View {
        HStack(spacing: 6) {
            Image(systemName: activeSource == "barcode_camera" ? "barcode.viewfinder" : activeSource == "label_scan" ? "list.clipboard" : "viewfinder")
                .font(.system(size: 11, weight: .black))
                .accessibilityHidden(true)
            Text(activeSource == "barcode_camera" ? "对准条码" : activeSource == "label_scan" ? "拍营养表" : "千问识别 · 请确认估算份量")
                .font(.system(size: 11, weight: .black))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.black.opacity(0.40))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private var cameraModeSelector: some View {
        HStack(spacing: 8) {
            cameraModeButton(id: "image_scan", title: "拍餐", icon: "camera.viewfinder")
            cameraModeButton(id: "barcode_camera", title: "条码", icon: "barcode.viewfinder")
            cameraModeButton(id: "label_scan", title: "营养表", icon: "list.clipboard")
        }
        .padding(6)
        .background(.black.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .padding(.horizontal, 28)
    }

    private func cameraModeButton(id: String, title: String, icon: String) -> some View {
        let active = activeSource == id
        return Button {
            guard activeSource != id else { return }
            activeSource = id
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .black))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .foregroundStyle(active ? Color(hex: "111318") : .white.opacity(0.78))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(active ? .white.opacity(0.96) : .white.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换到\(title)")
    }

    private func friendlyDepthStatus(_ text: String, supported: Bool, captured: Bool) -> String {
        if captured { return "已拍清楚" }
        if text.contains("拍摄") || text.contains("捕获") || text.contains("拍清楚") { return "正在拍清楚" }
        if supported { return "整盘入镜更准" }
        return "拍完整一点"
    }

    private func prepareCapture(_ capture: MealCapture) {
        camera.stop()
        pendingCapture = capture
    }

    private func retakePhoto() {
        pendingCapture = nil
        camera.requestAccessAndConfigure(
            barcodeMode: activeSource == "barcode_camera",
            depthCaptureMode: false
        )
    }

    private func usePendingCapture(_ capture: MealCapture) {
        pendingCapture = nil
        onCapture(capture)
    }

    private func previewImage(for capture: MealCapture) -> UIImage? {
        let payload = capture.imageBase64.split(separator: ",").last.map(String.init) ?? capture.imageBase64
        guard let data = Data(base64Encoded: payload) else { return nil }
        return UIImage(data: data)
    }

    private func scanBubble(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .black))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: .black))
        }
        .foregroundStyle(Color(hex: "111318"))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.white.opacity(0.94))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.74), lineWidth: 1))
        .shadow(color: .black.opacity(0.20), radius: 14, x: 0, y: 8)
    }
}

private struct CaptureReviewOverlay: View {
    let image: UIImage
    let hasDepth: Bool
    let auxiliaryCount: Int
    let onRetake: () -> Void
    let onAddAuxiliary: () -> Void
    let onUsePhoto: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("照片已拍好")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(.white)
                        Text(hasDepth ? "已包含深度信息，份量估算会更稳" : "检查食物和碗盘是否完整入镜")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    if hasDepth {
                        Label("有深度", systemImage: "viewfinder.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(hex: "20C05C"))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(.white.opacity(0.94))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 62)

                Spacer()

                Button(action: onAddAuxiliary) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.stack")
                            .accessibilityHidden(true)
                        Text(auxiliaryCount == 0 ? "添加包装、营养表、秤读数或其他角度" : "已添加 \(auxiliaryCount) 张辅助图，可继续添加")
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.black.opacity(0.48))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(auxiliaryCount >= 4)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)

                HStack(spacing: 12) {
                    Button(action: onRetake) {
                        Label("重拍", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(.white.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onUsePhoto) {
                        Label("使用这张", systemImage: "checkmark")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 34)
            }
        }
    }
}

private struct CaptureProgressOverlay: View {
    let source: String

    private var title: String {
        switch source {
        case "label_scan":
            return "正在拍清楚标签"
        case "barcode_camera":
            return "正在识别条码"
        default:
            return "正在拍清楚这餐"
        }
    }

    private var subtitle: String {
        switch source {
        case "label_scan":
            return "保持一下，马上读营养表。"
        case "barcode_camera":
            return "保持条码在框里。"
        default:
            return "保持一下，马上开始分析。"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.18)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 14)
        .accessibilityElement(children: .combine)
    }
}

private struct CameraErrorView: View {
    let message: String
    var showUpload: Bool = false
    let onClose: () -> Void
    let onRetry: () -> Void
    let onUpload: () -> Void

    private var title: String {
        if isPermissionError { return "先开启相机权限" }
        if isNoCameraError { return "没连上后置相机" }
        if isEstimationInfoError { return "这张不够完整" }
        return "相机暂时被占用"
    }

    private var subtitle: String {
        if showUpload {
            return "先试试重新打开相机；赶时间也可以手动记。"
        }
        if isPermissionError {
            return "开启后回到这里，就能继续拍这餐。"
        }
        if isNoCameraError {
            return "关闭其他正在用相机的 App，再重新打开相机。"
        }
        if isEstimationInfoError {
            return "让食物和碗盘边缘都入镜，手机别贴太近。"
        }
        return "关闭其他正在用相机的 App，再重新打开相机。"
    }

    private var recoveryTip: String {
        if showUpload { return "手动记也能先保存，后面还能改食物和份量。" }
        if isPermissionError { return "只需要相机权限，用来拍下这餐并保存记录。" }
        if isNoCameraError { return "先重试相机；赶时间就回到加号手动记。" }
        if isEstimationInfoError { return "小提示：拍完整一盘，比拍局部特写更准。" }
        return "如果仍然失败，先回到加号手动记，别让记录断掉。"
    }

    private var primaryActionTitle: String {
        isPermissionError ? "去开启相机权限" : "重新打开相机"
    }

    private var primaryActionIcon: String {
        isPermissionError ? "gearshape.fill" : "arrow.clockwise"
    }

    private var isPermissionError: Bool {
        message.contains("权限") || message.contains("授权")
    }

    private var isNoCameraError: Bool {
        message.contains("没有找到") || message.contains("无法访问相机") || message.contains("当前设备")
    }

    private var isEstimationInfoError: Bool {
        message.contains("估重信息") || message.contains("Depth") || message.contains("深度") || message.contains("LiDAR") || message.contains("激光雷达")
    }

    private func performPrimaryAction() {
        if isPermissionError, let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        } else {
            onRetry()
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 44, height: 5)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.96), Color.white.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 14)

	                Image(systemName: showUpload ? "photo.on.rectangle.angled" : "camera.viewfinder")
	                    .font(.system(size: 32, weight: .black))
	                    .foregroundStyle(Color(hex: "111318"))
	                    .accessibilityHidden(true)
            }

            VStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }

            Text(recoveryTip)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 12) {
                if showUpload {
                    Button(action: onUpload) {
                        Label("选择照片试一次", systemImage: "photo.on.rectangle")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(Color(hex: "111318"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                LinearGradient(
                                    colors: [.white, Color(hex: "EEF3FF")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 12)
                    }
                }

                Button(action: performPrimaryAction) {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(hex: "111318"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            LinearGradient(
                                colors: [.white, Color(hex: "EEF3FF")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 12)
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    if isPermissionError {
                        Button(action: onRetry) {
                            secondaryActionContent(title: "我已开启，重试", icon: "checkmark")
                        }
                        .buttonStyle(.plain)
                    }

                        Button(action: onClose) {
                            secondaryActionContent(title: "手动记", icon: "square.and.pencil")
                        }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 34, x: 0, y: 24)
    }

    private func secondaryActionContent(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(.white.opacity(0.84))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(.white.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            )
    }
}

struct DepthBadge: View {
    let supported: Bool
    let captured: Bool
    let statusText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: supported ? (captured ? "checkmark.viewfinder" : "viewfinder") : "viewfinder.circle")
                .accessibilityHidden(true)
            Text(displayText)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .black))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "111318").opacity(0.72))
        .clipShape(Capsule())
    }

    private var displayText: String {
        if captured { return "已拍清楚" }
        if statusText.contains("拍摄") || statusText.contains("捕获") || statusText.contains("拍清楚") { return "正在拍清楚" }
        if supported { return "整盘入镜" }
        return "拍完整一点"
    }
}

struct CameraModeBadge: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .black))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "111318").opacity(0.72))
        .clipShape(Capsule())
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

final class FoodCameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "calai.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let depthManager = DepthCaptureManager()
    private var barcodeMode = false
    private var depthCaptureMode = true
    private var didEmitBarcode = false

    @Published var isConfigured = false
    @Published var isCapturing = false
    @Published var depthSupported = false
    @Published var depthStatusText = "检测相机"
    @Published var depthDiagnosticsText = ""
    @Published var lastDepthSummary: [String: Any]? = nil
    @Published var configurationError: String? = nil

    var onCapture: ((MealCapture) -> Void)?
    var onBarcode: ((String) -> Void)?

    func requestAccessAndConfigure(barcodeMode: Bool = false, depthCaptureMode: Bool = true) {
        self.barcodeMode = barcodeMode
        self.depthCaptureMode = depthCaptureMode
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configure()
                    } else {
                        self.configurationError = "先打开相机权限，才能拍这餐。"
                    }
                }
            }
        case .denied, .restricted:
            configurationError = "相机权限还没开。去设置打开后，再回来拍这餐。"
        @unknown default:
            configurationError = "现在没法打开相机。先重新打开相机。"
        }
    }

    func configure() {
        sessionQueue.async {
            guard !self.session.isRunning else {
                DispatchQueue.main.async {
                    self.updateDepthStatus(deviceName: nil)
                    self.isConfigured = true
                    self.configurationError = nil
                }
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.didEmitBarcode = false

            guard let device = Self.bestFoodCamera() else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.configurationError = "没连上后置相机。关掉其他正在用相机的 App，再重新打开相机。"
                }
                return
            }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.configurationError = "相机暂时被占用。关掉其他正在用相机的 App，再重新打开相机。"
                }
                return
            }

            guard self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.configurationError = "相机还没准备好。再重新打开相机，或重启 App。"
                }
                return
            }

            self.session.addInput(input)

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                if self.photoOutput.isDepthDataDeliverySupported {
                    self.photoOutput.isDepthDataDeliveryEnabled = true
                }
            }

            if self.barcodeMode, self.session.canAddOutput(self.metadataOutput) {
                self.session.addOutput(self.metadataOutput)
                self.metadataOutput.setMetadataObjectsDelegate(self, queue: self.sessionQueue)
                let supportedTypes = Set(self.metadataOutput.availableMetadataObjectTypes)
                let wantedTypes: [AVMetadataObject.ObjectType] = [
                    .ean8,
                    .ean13,
                    .upce,
                    .code128,
                    .code39,
                    .code39Mod43,
                    .code93,
                    .interleaved2of5,
                    .itf14,
                    .qr,
                ]
                self.metadataOutput.metadataObjectTypes = wantedTypes.filter { supportedTypes.contains($0) }
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.updateDepthStatus(deviceName: device.localizedName)
                self.isConfigured = true
                self.configurationError = nil
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.depthManager.stopSession()
            self.didEmitBarcode = false
        }
    }

    func capture() {
        guard isConfigured else { return }
        isCapturing = true
        if depthCaptureMode, !barcodeMode, DepthCaptureManager.isSceneDepthSupported {
            depthStatusText = "正在拍清楚"
            captureWithARKitDepth()
            return
        }
        depthStatusText = photoOutput.isDepthDataDeliverySupported ? "正在拍清楚" : "正在拍摄"
        captureAVFoundationDepthPhoto()
    }

    private func captureAVFoundationDepthPhoto() {
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        if depthCaptureMode && photoOutput.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = true
        }
        sessionQueue.async {
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func captureWithARKitDepth() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            do {
                try self.depthManager.startSession()
                let depthBundle = try self.depthManager.captureMealFrame(source: "arkit_scene_depth_direct")
                self.depthManager.stopSession()
                let imageData = try Data(contentsOf: URL(fileURLWithPath: depthBundle.rgbPath))
                let imageInfo = Self.imageInfo(from: imageData)
                var depthSummary = depthBundle.metadata
                depthSummary["source"] = "arkit_scene_depth_direct_bundle"
                let captureMetadata: [String: Any] = [
                    "source": "image_scan",
                    "capture_pipeline": "arkit_scene_depth_direct_v2",
                    "has_depth": true,
                    "has_depth_bundle": true,
                    "depth_sensor_supported": true,
                    "image_bytes": imageData.count,
                    "image_width": imageInfo.width,
                    "image_height": imageInfo.height,
                    "photo_quality": "arkit_scene_depth_direct"
                ]
                DispatchQueue.main.async {
                    self.lastDepthSummary = depthSummary
                    self.isCapturing = false
                    self.configurationError = nil
                    self.onCapture?(
                        MealCapture(
                            imageBase64: imageData.base64EncodedString(),
                            depthMetadata: depthSummary,
                            captureMetadata: captureMetadata,
                            depthBundle: depthBundle
                        )
                    )
                }
            } catch {
                self.depthManager.stopSession()
                self.session.startRunning()
                if self.photoOutput.isDepthDataDeliverySupported {
                    DispatchQueue.main.async {
                        self.depthStatusText = "正在拍清楚"
                    }
                    self.captureAVFoundationDepthPhoto()
                } else {
                    DispatchQueue.main.async {
                        self.isCapturing = false
                        self.updateDepthStatus(deviceName: nil)
                self.configurationError = "这次没拍清楚。让食物和碗盘边缘完整入镜，手机别贴太近，再拍一次。"
                    }
                }
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer {
            DispatchQueue.main.async { self.isCapturing = false }
        }
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.configurationError = "这次没有拍成功。稳住手机再拍；赶时间也可以手动记。"
            }
            return
        }

        if !depthCaptureMode {
            DispatchQueue.main.async {
                self.lastDepthSummary = nil
                self.depthStatusText = "千问图片识别"
                self.onCapture?(MealCapture(imageBase64: data.base64EncodedString(), depthMetadata: nil,
                    captureMetadata: ["source": "image_scan", "has_depth": false, "capture_pipeline": "qwen_direct"]))
            }
            return
        }

        var depthSummary = Self.depthSummary(from: photo.depthData)
        var depthBundle: MealCaptureBundle?
        if DepthCaptureManager.isSceneDepthSupported {
            do {
                depthBundle = try depthManager.captureMealFrame(
                    rgbJPEGData: data,
                    source: "avcapture_photo_with_arkit_depth"
                )
                var bundleMetadata = depthBundle?.metadata ?? [:]
                bundleMetadata["source"] = "arkit_scene_depth_bundle"
                if var summary = depthSummary {
                    summary["arkit_bundle"] = bundleMetadata
                    depthSummary = summary
                } else {
                    depthSummary = bundleMetadata
                }
            } catch {
                // Fall back to photo depth data below when ARKit scene depth is not available.
            }
        }
        if depthBundle == nil, let photoDepthData = photo.depthData {
            do {
                depthBundle = try DepthCaptureManager.capturePhotoDepthBundle(
                    depthData: photoDepthData,
                    rgbJPEGData: data,
                    source: "avcapture_photo_depth"
                )
                var bundleMetadata = depthBundle?.metadata ?? [:]
                bundleMetadata["source"] = "avfoundation_photo_depth_bundle"
                if var summary = depthSummary {
                    summary["photo_depth_bundle"] = bundleMetadata
                    depthSummary = summary
                } else {
                    depthSummary = bundleMetadata
                }
            } catch {
                // The user-facing error below explains that this capture did not include depth.
            }
        }
        guard let depthBundle else {
            DispatchQueue.main.async {
                self.lastDepthSummary = depthSummary
                self.updateDepthStatus(deviceName: nil)
                self.configurationError = "这次没拍清楚。请从相机里直接拍，并让碗盘边缘完整入镜。"
            }
            return
        }
        let imageInfo = Self.imageInfo(from: data)
        let captureMetadata: [String: Any] = [
            "source": "image_scan",
            "capture_pipeline": "avcapture_photo_depth_v2",
            "has_depth": true,
            "has_depth_bundle": true,
            "depth_sensor_supported": output.isDepthDataDeliverySupported || DepthCaptureManager.isSceneDepthSupported,
            "image_bytes": data.count,
            "image_width": imageInfo.width,
            "image_height": imageInfo.height,
            "photo_quality": "quality"
        ]

        DispatchQueue.main.async {
            self.lastDepthSummary = depthSummary
            self.depthStatusText = "已拍清楚"
            self.onCapture?(
                MealCapture(
                    imageBase64: data.base64EncodedString(),
                    depthMetadata: depthSummary,
                    captureMetadata: captureMetadata,
                    depthBundle: depthBundle
                )
            )
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard barcodeMode, !didEmitBarcode else { return }
        guard let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }
        didEmitBarcode = true
        session.stopRunning()
        DispatchQueue.main.async {
            self.onBarcode?(value)
        }
    }

    private func updateDepthStatus(deviceName: String?) {
        let arDepthSupported = DepthCaptureManager.isSceneDepthSupported
        let photoDepthSupported = photoOutput.isDepthDataDeliverySupported
        depthSupported = arDepthSupported || photoDepthSupported
        if depthSupported {
            if arDepthSupported {
                depthStatusText = "可以拍这餐"
            } else {
                depthStatusText = "可以拍这餐"
            }
        } else {
            depthStatusText = "先检测相机"
        }
        let cameraName = deviceName?.isEmpty == false ? deviceName! : "当前后置相机"
        depthDiagnosticsText = "诊断：\(cameraName)，实时估重 \(arDepthSupported ? "可用" : "不可用")，照片估重 \(photoDepthSupported ? "可用" : "不可用")。"
    }

    private static func bestFoodCamera() -> AVCaptureDevice? {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]

        if #available(iOS 15.4, *) {
            deviceTypes.insert(.builtInLiDARDepthCamera, at: 0)
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )
        if let best = discovery.devices.first {
            return best
        }

        let fallbackTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        for type in fallbackTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    private static func imageInfo(from data: Data) -> (width: Int, height: Int) {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return (0, 0)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    private static func percentile(_ values: [Float], _ p: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(round(Float(sorted.count - 1) * p))))
        return sorted[index]
    }

    private static func depthSummary(from depthData: AVDepthData?) -> [String: Any]? {
        guard let depthData else { return nil }
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let sampleStep = max(1, width / 64)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var allDepths: [Float] = []
        var roiDepths: [Float] = []

        let roiMinX = width / 6
        let roiMaxX = width - roiMinX
        let roiMinY = height / 6
        let roiMaxY = height - roiMinY

        for y in stride(from: 0, to: height, by: sampleStep) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: width, by: sampleStep) {
                let value = row[x]
                if value.isFinite && value > 0.05 && value < 5.0 {
                    allDepths.append(value)
                    if x >= roiMinX && x <= roiMaxX && y >= roiMinY && y <= roiMaxY {
                        roiDepths.append(value)
                    }
                }
            }
        }

        guard !allDepths.isEmpty else {
            return [
                "available": true,
                "valid_sample_count": 0,
                "width": width,
                "height": height
            ]
        }

        let roi = roiDepths.isEmpty ? allDepths : roiDepths
        let minValue = allDepths.min() ?? 0
        let maxValue = allDepths.max() ?? 0
        let mean = allDepths.reduce(0, +) / Float(allDepths.count)
        let roiMean = roi.reduce(0, +) / Float(roi.count)
        let backgroundDepth = percentile(allDepths, 0.80) ?? maxValue
        let nearThreshold = max(0.05, backgroundDepth - 0.035)
        let foregroundHeights = roi
            .filter { $0 < nearThreshold }
            .map { max(0, backgroundDepth - $0) }
        let foregroundCount = foregroundHeights.count
        let foregroundAreaRatio = roi.isEmpty ? 0 : Double(foregroundCount) / Double(roi.count)
        let meanHeight = foregroundHeights.isEmpty ? 0 : foregroundHeights.reduce(0, +) / Float(foregroundHeights.count)
        let maxHeight = foregroundHeights.max() ?? 0
        let relativeVolumeProxy = foregroundHeights.reduce(0, +) * Float(sampleStep * sampleStep)

        return [
            "available": true,
            "unit": "meters",
            "width": width,
            "height": height,
            "sample_step_px": sampleStep,
            "valid_sample_count": allDepths.count,
            "roi_sample_count": roi.count,
            "mean_depth_m": Double(mean),
            "min_depth_m": Double(minValue),
            "max_depth_m": Double(maxValue),
            "roi_mean_depth_m": Double(roiMean),
            "roi_p10_depth_m": Double(percentile(roi, 0.10) ?? roiMean),
            "roi_p50_depth_m": Double(percentile(roi, 0.50) ?? roiMean),
            "roi_p90_depth_m": Double(percentile(roi, 0.90) ?? roiMean),
            "background_depth_m": Double(backgroundDepth),
            "foreground_sample_count": foregroundCount,
            "foreground_area_ratio": foregroundAreaRatio,
            "mean_foreground_height_m": Double(meanHeight),
            "max_foreground_height_m": Double(maxHeight),
            "relative_volume_proxy": Double(relativeVolumeProxy),
            "volume_method": "center_roi_depth_foreground_proxy"
        ]
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController(); p.sourceType = .photoLibrary; p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiVC: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onPick(img) }
            picker.dismiss(animated: true)
        }
    }
}
