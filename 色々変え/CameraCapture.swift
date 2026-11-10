@preconcurrency import AVFoundation
import Combine
import CoreVideo
import Foundation

/// The only retained input frame. Replacing it never creates a processing queue.
nonisolated struct CameraFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let id: UInt64
}

nonisolated final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CameraFrame?
    private var nextID: UInt64 = 0
    private var onFrame: (@Sendable () -> Void)?

    func snapshot() -> CameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func setOnFrame(_ callback: (@Sendable () -> Void)?) {
        lock.lock()
        onFrame = callback
        lock.unlock()
    }

    fileprivate func store(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        nextID &+= 1
        latest = CameraFrame(pixelBuffer: pixelBuffer, id: nextID)
        let callback = onFrame
        lock.unlock()
        callback?()
    }

    func clear() {
        lock.lock()
        latest = nil
        let callback = onFrame
        lock.unlock()
        callback?()
    }
}

@MainActor
final class CameraCapture: ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var actualFormat = "カメラを準備中"
    @Published private(set) var notice: String?
    @Published private(set) var supportedResolutions: [CaptureResolution] = []
    @Published private(set) var supportedFrameRates: [Int] = []
    @Published private(set) var settings = CaptureSettings()

    let frames: LatestFrameStore
    private let worker: CameraWorker
    private var wantsRunning = false

    init() {
        let store = LatestFrameStore()
        frames = store
        worker = CameraWorker(frames: store)
        worker.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
    }

    deinit {
        worker.stop()
    }

    func start() {
        if wantsRunning && (state == .running || state == .requesting) { return }
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            state = .requesting
            worker.start(settings: settings)
        case .notDetermined:
            guard state != .requesting else { return }
            state = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if granted {
                        self.worker.start(settings: self.settings)
                    } else {
                        self.state = .denied
                    }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed("カメラのアクセス状態を確認できませんでした。")
        }
    }

    func stop() {
        wantsRunning = false
        state = .idle
        worker.stop()
        frames.clear()
    }

    func update(settings: CaptureSettings) {
        let requested = CaptureSettings(
            resolution: settings.resolution,
            frameRate: settings.frameRate == 60 ? 60 : 30
        )
        guard self.settings != requested else { return }
        self.settings = requested
        worker.update(settings: requested)
    }

    private func receive(_ event: CameraEvent) {
        guard wantsRunning else { return }
        switch event {
        case .state(let state):
            self.state = state
        case .configuration(let value):
            settings = value.settings
            supportedResolutions = value.resolutions
            supportedFrameRates = value.frameRates
            actualFormat = "\(value.settings.resolution.dimensions) · \(value.settings.frameRate) fps"
            notice = value.notice
        case .outputDimensions(let width, let height, let frameRate):
            actualFormat = "\(width) × \(height) · \(frameRate) fps"
        }
    }
}

private nonisolated struct CameraConfiguration: Sendable {
    let settings: CaptureSettings
    let resolutions: [CaptureResolution]
    let frameRates: [Int]
    let notice: String?
}

private nonisolated enum CameraEvent: Sendable {
    case state(CameraState)
    case configuration(CameraConfiguration)
    case outputDimensions(width: Int, height: Int, frameRate: Int)
}

/// All AVFoundation mutations and sample callbacks use this serial queue.
private nonisolated final class CameraWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "jp.iroiro.camera", qos: .userInitiated)
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let frames: LatestFrameStore
    var onEvent: (@Sendable (CameraEvent) -> Void)?

    private var device: AVCaptureDevice?
    private var configured = false
    private var wantsRunning = false
    private var appliedSettings: CaptureSettings?
    private var lastOutputWidth = 0
    private var lastOutputHeight = 0
    private var observers: [NSObjectProtocol] = []

    init(frames: LatestFrameStore) {
        self.frames = frames
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let wasReset = error?.code == AVError.Code.mediaServicesWereReset.rawValue
            let message = error?.localizedDescription ?? "カメラでエラーが発生しました。"
            self?.queue.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                self.frames.clear()
                if wasReset {
                    self.startSession()
                } else {
                    self.onEvent?(.state(.failed(message)))
                }
            }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                self.frames.clear()
                self.onEvent?(.state(.failed("カメラが一時的に中断されました。他のカメラ使用を終了すると再開します。")))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                self.startSession()
            }
        })
        #endif
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(settings: CaptureSettings) {
        queue.async { [self] in
            wantsRunning = true
            do {
                try prepareSessionIfNeeded()
                try apply(settings: settings)
                startSession()
            } catch CameraError.noCamera {
                onEvent?(.state(.unavailable))
            } catch {
                onEvent?(.state(.failed(error.localizedDescription)))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
            frames.clear()
        }
    }

    func update(settings: CaptureSettings) {
        queue.async { [self] in
            guard configured, wantsRunning else { return }
            do {
                try apply(settings: settings)
                if !session.isRunning { startSession() }
            } catch {
                // A rejected format request leaves the previous configuration usable.
                if let appliedSettings, let device, session.isRunning {
                    let resolutions = CaptureResolution.allCases.filter {
                        !formats(device, resolution: $0, frameRate: 30).isEmpty
                    }
                    let frameRates = [30, 60].filter {
                        !formats(device, resolution: appliedSettings.resolution, frameRate: $0).isEmpty
                    }
                    onEvent?(.configuration(CameraConfiguration(
                        settings: appliedSettings,
                        resolutions: resolutions,
                        frameRates: frameRates,
                        notice: "設定を変更できなかったため、直前の設定で続けています。"
                    )))
                    onEvent?(.state(.running))
                } else {
                    onEvent?(.state(.failed(error.localizedDescription)))
                }
            }
        }
    }

    private func startSession() {
        guard wantsRunning else { return }
        if !session.isRunning { session.startRunning() }
        onEvent?(.state(session.isRunning ? .running : .failed("カメラを開始できませんでした。もう一度お試しください。")))
    }

    private func prepareSessionIfNeeded() throws {
        guard !configured else { return }
        #if os(iOS)
        let selectedDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        #else
        let selectedDevice = AVCaptureDevice.default(for: .video)
        #endif
        guard let selectedDevice else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: selectedDevice)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        #if os(iOS)
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        #endif
        guard session.canAddInput(input) else { throw CameraError.configuration }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.configuration
        }
        output.alwaysDiscardsLateVideoFrames = true
        #if os(iOS)
        // Honor the selected device format rather than automatically downscaling
        // camera data to a preview-sized proxy.
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = false
        #endif
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        let available = output.availableVideoPixelFormatTypes
        if available.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        } else if available.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        } else {
            session.removeOutput(output)
            session.removeInput(input)
            throw CameraError.pixelFormat
        }
        if let connection = output.connection(with: .video) {
            // The Metal renderer owns rotation; keep AVFoundation's buffers native.
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        device = selectedDevice
        configured = true
    }

    private func apply(settings requested: CaptureSettings) throws {
        guard let device else { throw CameraError.noCamera }
        let supported = CaptureResolution.allCases.filter { resolution in
            !formats(device, resolution: resolution, frameRate: 30).isEmpty
        }
        guard !supported.isEmpty else { throw CameraError.configuration }
        let resolution = supported.contains(requested.resolution) ? requested.resolution :
            (supported.filter { $0.rawValue <= requested.resolution.rawValue }.last ?? supported[0])
        let frameRates = [30, 60].filter { !formats(device, resolution: resolution, frameRate: $0).isEmpty }
        let frameRate = frameRates.contains(requested.frameRate) ? requested.frameRate : 30
        guard let format = formats(device, resolution: resolution, frameRate: frameRate).first else {
            throw CameraError.configuration
        }
        let actual = CaptureSettings(resolution: resolution, frameRate: frameRate)
        if appliedSettings != actual {
            // Lock first: if acquiring the device fails, no session state is changed.
            try device.lockForConfiguration()
            session.beginConfiguration()
            frames.clear()
            device.activeFormat = format
            #if os(iOS)
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
            #endif
            if format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            // Reassert the native orientation if a format change rebuilt the connection.
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            session.commitConfiguration()
            appliedSettings = actual
        }
        lastOutputWidth = 0
        lastOutputHeight = 0
        let notice = actual == requested ? nil : "このカメラでは \(requested.resolution.title)・\(requested.frameRate) fps を使用できないため、\(resolution.title)・\(frameRate) fps に変更しました。"
        onEvent?(.configuration(CameraConfiguration(settings: actual, resolutions: supported, frameRates: frameRates, notice: notice)))
    }

    private func formats(_ device: AVCaptureDevice, resolution: CaptureResolution, frameRate: Int) -> [AVCaptureDevice.Format] {
        device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let isEightBitYUV = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return dimensions.width == resolution.width && dimensions.height == resolution.height && isEightBitYUV &&
                format.supportedColorSpaces.contains(.sRGB) &&
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(frameRate) && $0.maxFrameRate >= Double(frameRate) }
        }.sorted {
            // Prefer the format with the smallest maximum rate that meets the request.
            ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) <
                ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard wantsRunning, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width != lastOutputWidth || height != lastOutputHeight {
            lastOutputWidth = width
            lastOutputHeight = height
            // Report real buffer dimensions once per configuration change.
            onEvent?(.outputDimensions(width: width, height: height, frameRate: appliedSettings?.frameRate ?? 30))
        }
        frames.store(pixelBuffer)
    }
}

private nonisolated enum CameraError: LocalizedError {
    case noCamera
    case configuration
    case pixelFormat

    var errorDescription: String? {
        switch self {
        case .noCamera: "背面カメラが見つかりません。実機でお試しください。"
        case .configuration: "このカメラの映像形式を設定できませんでした。"
        case .pixelFormat: "このカメラは対応する8 bit YCbCr形式を出力できません。"
        }
    }
}
