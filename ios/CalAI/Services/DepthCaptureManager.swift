import ARKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UIKit

struct MealCaptureBundle {
    let captureId: String
    let rgbPath: String
    let depthPath: String
    let confidencePath: String
    let metadataPath: String
    let depthSource: String
    let rgbWidth: Int
    let rgbHeight: Int
    let depthWidth: Int
    let depthHeight: Int

    var metadata: [String: Any] {
        [
            "capture_id": captureId,
            "rgb_path": rgbPath,
            "depth_path": depthPath,
            "confidence_path": confidencePath,
            "metadata_path": metadataPath,
            "depth_source": depthSource,
            "rgb_width": rgbWidth,
            "rgb_height": rgbHeight,
            "depth_width": depthWidth,
            "depth_height": depthHeight,
            "has_depth": true
        ]
    }
}

enum DepthCaptureError: LocalizedError {
    case depthNotSupported
    case noFrame
    case noDepth
    case cannotCreateImage
    case cannotWriteFile

    var errorDescription: String? {
        switch self {
        case .depthNotSupported:
            return "当前设备不支持实时估重拍摄。"
        case .noFrame:
            return "还没有可用的实时相机画面。"
        case .noDepth:
            return "相机已启动，但还没有拍到可计算的餐盘画面。"
        case .cannotCreateImage:
            return "无法生成照片。"
        case .cannotWriteFile:
            return "无法保存这次拍照估重文件。"
        }
    }
}

final class DepthCaptureManager: NSObject, ARSessionDelegate {
    static var isSceneDepthSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    private let session = ARSession()
    private let lock = NSLock()
    private var latestFrame: ARFrame?
    private let ciContext = CIContext()
    private(set) var isRunning = false

    static func capturePhotoDepthBundle(
        depthData: AVDepthData,
        rgbJPEGData: Data,
        source: String = "avcapture_photo_depth"
    ) throws -> MealCaptureBundle {
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepth.depthDataMap
        let captureId = UUID().uuidString
        let directory = try Self.captureDirectory(captureId: captureId)

        let rgbPath = directory.appendingPathComponent("rgb.jpg")
        try rgbJPEGData.write(to: rgbPath, options: [.atomic])

        let rgbSize = Self.imageSize(fromJPEGData: rgbJPEGData) ?? (width: 0, height: 0)
        let depthSize = Self.pixelBufferSize(depthMap)

        let depthPath = directory.appendingPathComponent("depth.bin")
        let confidencePath = directory.appendingPathComponent("confidence.bin")
        try Self.writeFloat32DepthMap(depthMap, to: depthPath)
        try Self.writeConstantConfidenceMap(size: depthSize, value: 192, to: confidencePath)

        let metadataPath = directory.appendingPathComponent("metadata.json")
        let metadata = Self.buildPhotoDepthMetadata(
            captureId: captureId,
            depthData: convertedDepth,
            rgbSize: rgbSize,
            depthSize: depthSize,
            source: source
        )
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: metadataPath, options: [.atomic])

        return MealCaptureBundle(
            captureId: captureId,
            rgbPath: rgbPath.path,
            depthPath: depthPath.path,
            confidencePath: confidencePath.path,
            metadataPath: metadataPath.path,
            depthSource: "ios_avfoundation_photo_depth",
            rgbWidth: rgbSize.width,
            rgbHeight: rgbSize.height,
            depthWidth: depthSize.width,
            depthHeight: depthSize.height
        )
    }

    func startSession() throws {
        guard Self.isSceneDepthSupported else {
            throw DepthCaptureError.depthNotSupported
        }

        lock.lock()
        latestFrame = nil
        lock.unlock()

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stopSession() {
        session.pause()
        isRunning = false
        lock.lock()
        latestFrame = nil
        lock.unlock()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock()
        latestFrame = frame
        lock.unlock()
    }

    func captureMealFrame(rgbJPEGData: Data? = nil, source: String = "ios_lidar_scene_depth") throws -> MealCaptureBundle {
        let frame = waitForDepthFrame(timeout: 6.0)
        guard let frame else { throw DepthCaptureError.noFrame }
        guard let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth else {
            throw DepthCaptureError.noDepth
        }

        let captureId = UUID().uuidString
        let directory = try Self.captureDirectory(captureId: captureId)

        let rgbData = try rgbJPEGData ?? jpegData(from: frame.capturedImage)
        let rgbPath = directory.appendingPathComponent("rgb.jpg")
        try rgbData.write(to: rgbPath, options: [.atomic])

        let rgbSize = Self.imageSize(fromJPEGData: rgbData) ?? Self.pixelBufferSize(frame.capturedImage)
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        let depthSize = Self.pixelBufferSize(depthMap)

        let depthPath = directory.appendingPathComponent("depth.bin")
        let confidencePath = directory.appendingPathComponent("confidence.bin")
        try Self.writeFloat32DepthMap(depthMap, to: depthPath)
        try Self.writeConfidenceMap(confidenceMap, size: depthSize, to: confidencePath)

        let metadataPath = directory.appendingPathComponent("metadata.json")
        let metadata = buildMetadata(
            captureId: captureId,
            frame: frame,
            depthData: depthData,
            rgbSize: rgbSize,
            depthSize: depthSize,
            source: source
        )
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: metadataPath, options: [.atomic])

        return MealCaptureBundle(
            captureId: captureId,
            rgbPath: rgbPath.path,
            depthPath: depthPath.path,
            confidencePath: confidencePath.path,
            metadataPath: metadataPath.path,
            depthSource: String(describing: metadata["depth_source"] ?? source),
            rgbWidth: rgbSize.width,
            rgbHeight: rgbSize.height,
            depthWidth: depthSize.width,
            depthHeight: depthSize.height
        )
    }

    private func waitForDepthFrame(timeout: TimeInterval) -> ARFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let frame = latestFrame
            lock.unlock()
            if let frame, frame.sceneDepth != nil || frame.smoothedSceneDepth != nil {
                return frame
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        let frame = latestFrame
        lock.unlock()
        return frame
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = ciImage.oriented(.right)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(
                of: oriented,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
              ) else {
            throw DepthCaptureError.cannotCreateImage
        }
        return data
    }

    private func buildMetadata(
        captureId: String,
        frame: ARFrame,
        depthData: ARDepthData,
        rgbSize: (width: Int, height: Int),
        depthSize: (width: Int, height: Int),
        source: String
    ) -> [String: Any] {
        let depthSource = frame.sceneDepth != nil ? "ios_lidar_scene_depth" : "ios_lidar_smoothed_scene_depth"
        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        let intrinsicsReferenceSize = Self.cameraIntrinsicsReferenceSize(frame.camera.imageResolution, fallback: rgbSize)
        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)

        return [
            "capture_id": captureId,
            "platform": "ios",
            "device_model": Self.deviceModel(),
            "depth_source": depthSource,
            "timestamp_ms": timestampMs,
            "rgb_depth_alignment": "nearest_ar_frame",
            "capture_source": source,
            "rgb": [
                "width": rgbSize.width,
                "height": rgbSize.height,
                "orientation": "portrait",
                "file": "rgb.jpg"
            ],
            "depth": [
                "width": depthSize.width,
                "height": depthSize.height,
                "unit": "meter",
                "dtype": "float32",
                "file": "depth.bin",
                "confidence_file": "confidence.bin",
                "confidence_dtype": "uint8"
            ],
            "camera": [
                "intrinsics": Self.matrix3x3ToArray(intrinsics),
                "intrinsics_reference_dimensions": [
                    "width": intrinsicsReferenceSize.width,
                    "height": intrinsicsReferenceSize.height
                ],
                "intrinsics_reference_source": "ARCamera.imageResolution",
                "camera_pose_world": Self.matrix4x4ToArray(transform)
            ],
            "intrinsicMatrixReferenceDimensions": [
                "width": intrinsicsReferenceSize.width,
                "height": intrinsicsReferenceSize.height
            ],
            "depth_quality": Self.depthQuality(depthData: depthData),
            "user_context": [
                "meal_type": NSNull(),
                "container_hint": NSNull(),
                "notes": NSNull()
            ]
        ]
    }

    private static func buildPhotoDepthMetadata(
        captureId: String,
        depthData: AVDepthData,
        rgbSize: (width: Int, height: Int),
        depthSize: (width: Int, height: Int),
        source: String
    ) -> [String: Any] {
        let calibration = depthData.cameraCalibrationData
        let intrinsics = calibration?.intrinsicMatrix ?? Self.fallbackIntrinsics(size: rgbSize)
        let referenceDimensions = calibration?.intrinsicMatrixReferenceDimensions
        let referenceSize = cameraIntrinsicsReferenceSize(
            referenceDimensions ?? CGSize(width: rgbSize.width, height: rgbSize.height),
            fallback: rgbSize
        )
        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)

        return [
            "capture_id": captureId,
            "platform": "ios",
            "device_model": Self.deviceModel(),
            "depth_source": "ios_avfoundation_photo_depth",
            "timestamp_ms": timestampMs,
            "rgb_depth_alignment": "avfoundation_photo_depth",
            "capture_source": source,
            "rgb": [
                "width": rgbSize.width,
                "height": rgbSize.height,
                "orientation": "portrait",
                "file": "rgb.jpg"
            ],
            "depth": [
                "width": depthSize.width,
                "height": depthSize.height,
                "unit": "meter",
                "dtype": "float32",
                "file": "depth.bin",
                "confidence_file": "confidence.bin",
                "confidence_dtype": "uint8"
            ],
            "camera": [
                "intrinsics": Self.matrix3x3ToArray(intrinsics),
                "intrinsics_reference_dimensions": [
                    "width": referenceSize.width,
                    "height": referenceSize.height
                ],
                "intrinsics_reference_source": calibration == nil ? "fallback_rgb_center" : "AVCameraCalibrationData.intrinsicMatrixReferenceDimensions",
                "camera_pose_world": Self.identity4x4Array()
            ],
            "intrinsicMatrixReferenceDimensions": [
                "width": referenceSize.width,
                "height": referenceSize.height
            ],
            "depth_quality": Self.photoDepthQuality(depthData: depthData),
            "user_context": [
                "meal_type": NSNull(),
                "container_hint": NSNull(),
                "notes": NSNull()
            ]
        ]
    }

    private static func captureDirectory(captureId: String) throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MealCaptures", isDirectory: true)
            .appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func writeFloat32DepthMap(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DepthCaptureError.cannotWriteFile
        }

        var data = Data(capacity: width * height * MemoryLayout<Float32>.size)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            data.append(UnsafeBufferPointer(start: row, count: width))
        }
        try data.write(to: url, options: [.atomic])
    }

    private static func writeConfidenceMap(_ pixelBuffer: CVPixelBuffer?, size: (width: Int, height: Int), to url: URL) throws {
        guard let pixelBuffer else {
            try Data(repeating: 192, count: size.width * size.height).write(to: url, options: [.atomic])
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DepthCaptureError.cannotWriteFile
        }

        var data = Data(capacity: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let value = row[x]
                let scaled: UInt8
                switch value {
                case 2...255:
                    scaled = 255
                case 1:
                    scaled = 127
                default:
                    scaled = 0
                }
                data.append(scaled)
            }
        }
        try data.write(to: url, options: [.atomic])
    }

    private static func writeConstantConfidenceMap(size: (width: Int, height: Int), value: UInt8, to url: URL) throws {
        try Data(repeating: value, count: size.width * size.height).write(to: url, options: [.atomic])
    }

    private static func depthQuality(depthData: ARDepthData) -> [String: Any] {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return ["available": false]
        }

        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let sampleStep = max(1, width / 64)
        var valid = 0
        var highConfidence = 0
        var sumDepth: Float = 0
        var minDepth: Float = .greatestFiniteMagnitude
        var maxDepth: Float = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            let depthRow = depthBase.advanced(by: y * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confRow = confidenceBase?.advanced(by: y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: sampleStep) {
                let depth = depthRow[x]
                if depth.isFinite && depth > 0.05 && depth < 5.0 {
                    valid += 1
                    sumDepth += depth
                    minDepth = min(minDepth, depth)
                    maxDepth = max(maxDepth, depth)
                    if (confRow?[x] ?? 0) >= 2 {
                        highConfidence += 1
                    }
                }
            }
        }

        guard valid > 0 else {
            return [
                "available": true,
                "width": width,
                "height": height,
                "valid_sample_count": 0
            ]
        }

        return [
            "available": true,
            "width": width,
            "height": height,
            "sample_step_px": sampleStep,
            "valid_sample_count": valid,
            "mean_depth_m": Double(sumDepth / Float(valid)),
            "min_depth_m": Double(minDepth),
            "max_depth_m": Double(maxDepth),
            "high_confidence_ratio": Double(highConfidence) / Double(valid)
        ]
    }

    private static func photoDepthQuality(depthData: AVDepthData) -> [String: Any] {
        let depthMap = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            return ["available": false]
        }

        let sampleStep = max(1, width / 64)
        var valid = 0
        var sumDepth: Float = 0
        var minDepth: Float = .greatestFiniteMagnitude
        var maxDepth: Float = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: width, by: sampleStep) {
                let depth = row[x]
                if depth.isFinite && depth > 0.05 && depth < 5.0 {
                    valid += 1
                    sumDepth += depth
                    minDepth = min(minDepth, depth)
                    maxDepth = max(maxDepth, depth)
                }
            }
        }

        guard valid > 0 else {
            return [
                "available": true,
                "width": width,
                "height": height,
                "valid_sample_count": 0
            ]
        }

        return [
            "available": true,
            "width": width,
            "height": height,
            "sample_step_px": sampleStep,
            "valid_sample_count": valid,
            "mean_depth_m": Double(sumDepth / Float(valid)),
            "min_depth_m": Double(minDepth),
            "max_depth_m": Double(maxDepth),
            "high_confidence_ratio": 0.75
        ]
    }

    private static func pixelBufferSize(_ pixelBuffer: CVPixelBuffer) -> (width: Int, height: Int) {
        (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
    }

    private static func imageSize(fromJPEGData data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func cameraIntrinsicsReferenceSize(_ imageResolution: CGSize, fallback: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let width = Int(round(imageResolution.width))
        let height = Int(round(imageResolution.height))
        if width > 0, height > 0 {
            return (width, height)
        }
        return fallback
    }

    private static func matrix3x3ToArray(_ m: simd_float3x3) -> [[Float]] {
        [
            [m.columns.0.x, m.columns.1.x, m.columns.2.x],
            [m.columns.0.y, m.columns.1.y, m.columns.2.y],
            [m.columns.0.z, m.columns.1.z, m.columns.2.z]
        ]
    }

    private static func matrix4x4ToArray(_ m: simd_float4x4) -> [[Float]] {
        [
            [m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x],
            [m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y],
            [m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z],
            [m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w]
        ]
    }

    private static func identity4x4Array() -> [[Float]] {
        [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ]
    }

    private static func fallbackIntrinsics(size: (width: Int, height: Int)) -> simd_float3x3 {
        let width = Float(max(size.width, 1))
        let height = Float(max(size.height, 1))
        let focal = max(width, height)
        return simd_float3x3(
            SIMD3<Float>(focal, 0, 0),
            SIMD3<Float>(0, focal, 0),
            SIMD3<Float>(width / 2, height / 2, 1)
        )
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? UIDevice.current.model
            }
        }
    }
}
