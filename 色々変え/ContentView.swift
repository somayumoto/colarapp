import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraCapture()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("colorMode") private var modeID = ColorMode.redAsBlue.rawValue
    @AppStorage("conversionIntensity") private var intensity = 1.0
    @AppStorage("captureResolution") private var resolutionID = CaptureResolution.hd.rawValue
    @AppStorage("captureFrameRate") private var frameRate = 30
    @AppStorage("showEntireFrame") private var showEntireFrame = false
    @State private var usesDemo: Bool
    @State private var showsSettings = false
    @State private var rendererError: String?
    @State private var rendererGeneration = 0

    private let accent = Color(red: 0.16, green: 0.36, blue: 0.85)
    private var mode: ColorMode { ColorMode(rawValue: modeID) ?? .redAsBlue }
    private var resolution: CaptureResolution { CaptureResolution(rawValue: resolutionID) ?? .hd }
    private var requestedSettings: CaptureSettings {
        CaptureSettings(resolution: resolution, frameRate: frameRate)
    }

    init(demo: Bool? = nil) {
        #if targetEnvironment(simulator)
        let defaultDemo = true
        #else
        let defaultDemo = false
        #endif
        _usesDemo = State(initialValue: demo ?? (defaultDemo || ProcessInfo.processInfo.arguments.contains("--demo")))
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 500
            VStack(spacing: compact ? 10 : 16) {
                header(compact: compact)
                if compact {
                    HStack(spacing: 18) {
                        preview
                        controls.frame(width: min(300, geometry.size.width * 0.39))
                    }
                } else {
                    preview
                    controls
                }
            }
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.top, compact ? 8 : 12)
            .padding(.bottom, compact ? 8 : 12)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .tint(accent)
        .sheet(isPresented: $showsSettings) { settingsSheet }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--settings") { showsSettings = true }
            synchronizeCamera()
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, _ in synchronizeCamera() }
        .onChange(of: usesDemo) { _, _ in
            synchronizeCamera()
        }
        .onChange(of: requestedSettings) { _, settings in camera.update(settings: settings) }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("色々変え")
                    .font(.system(size: compact ? 22 : 27, weight: .bold, design: .rounded))
                if !compact {
                    Text("色を変えて、並べて見る")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                usesDemo.toggle()
            } label: {
                Label(usesDemo ? "カメラへ" : "色見本", systemImage: usesDemo ? "camera" : "square.grid.3x3")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("sourceToggle")
            .buttonStyle(.bordered)
            Button { showsSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3).frame(width: 40, height: 40)
            }
            .accessibilityLabel("撮影設定")
            .accessibilityIdentifier("captureSettings")
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.055, green: 0.07, blue: 0.10)
                CameraMetalView(
                    frames: camera.frames,
                    mode: mode,
                    intensity: Float(intensity),
                    demo: usesDemo,
                    fill: !showEntireFrame,
                    onFailure: { rendererError = $0 }
                )
                .id(rendererGeneration)
                .accessibilityHidden(true)
                VStack(spacing: 0) {
                    panelLabel("変換後", detail: mode.title, systemImage: "circle.lefthalf.filled")
                        .frame(height: geometry.size.height / 2, alignment: .topLeading)
                    panelLabel("元の映像", detail: usesDemo ? "色見本" : "背面カメラ", systemImage: "camera")
                        .frame(height: geometry.size.height / 2, alignment: .topLeading)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                Rectangle().fill(.white.opacity(0.35)).frame(height: 1)
                if let error = rendererError {
                    messageOverlay(title: "映像を表示できません", message: error, symbol: "exclamationmark.triangle") {
                        Button("もう一度表示") {
                            rendererError = nil
                            rendererGeneration += 1
                        }
                    }
                } else if !usesDemo {
                    cameraStatusOverlay
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usesDemo ? "色見本の上下比較。上は\(mode.title)、下は元の色" : "カメラの上下比較。上は\(mode.title)、下は元の映像")
    }

    private func panelLabel(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title).fontWeight(.bold)
            Text(detail).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(.white)
        .background(.black.opacity(0.65), in: Capsule())
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("色の変え方").font(.subheadline.weight(.semibold))
                Spacer()
                Text(usesDemo ? "色見本でプレビュー中" : camera.actualFormat)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Picker("色の変え方", selection: $modeID) {
                ForEach(ColorMode.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("colorModePicker")
            Text(mode.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Text("強度").font(.subheadline)
                Slider(value: $intensity, in: 0...1)
                    .disabled(mode == .original)
                    .accessibilityLabel("色変換の強度")
                    .accessibilityValue("\(Int(intensity * 100))パーセント")
                    .accessibilityIdentifier("intensitySlider")
                Text("\(Int(intensity * 100))%")
                    .font(.subheadline.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
            Text(usesDemo ? "赤・緑・青・白などを、上下で見比べられます。" : "上下は同じ瞬間・同じ範囲の映像です。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cameraStatusOverlay: some View {
        switch camera.state {
        case .running:
            EmptyView()
        case .idle, .requesting:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(camera.state == .requesting ? "カメラの使用を確認しています" : "カメラを準備しています")
                    .font(.subheadline)
            }
            .foregroundStyle(.white)
        case .denied:
            messageOverlay(title: "カメラの使用を許可してください", message: "設定アプリでカメラを許可すると、映像を色変換できます。", symbol: "camera.fill") {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .unavailable:
            messageOverlay(title: "カメラを利用できません", message: "実機の背面カメラを使ってください。色見本でも変換を試せます。", symbol: "camera.badge.ellipsis") {
                Button("色見本を表示") { usesDemo = true }
            }
        case .failed(let message):
            messageOverlay(title: "カメラが停止しています", message: message, symbol: "camera.badge.ellipsis") {
                Button("もう一度試す") { synchronizeCamera() }
            }
        }
    }

    private func messageOverlay(title: String, message: String, symbol: String) -> some View {
        messageOverlay(title: title, message: message, symbol: symbol) { EmptyView() }
    }

    private func messageOverlay<Action: View>(title: String, message: String, symbol: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.largeTitle)
            Text(title).font(.headline)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            action().buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 340)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("解像度", selection: $resolutionID) {
                        ForEach(CaptureResolution.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                                .disabled(!camera.supportedResolutions.isEmpty && !camera.supportedResolutions.contains(option))
                        }
                    }
                    .accessibilityIdentifier("resolutionPicker")
                    Picker("フレームレート", selection: $frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                            .disabled(!camera.supportedFrameRates.isEmpty && !camera.supportedFrameRates.contains(60))
                    }
                    .accessibilityIdentifier("frameRatePicker")
                } header: {
                    Text("撮影画質")
                } footer: {
                    Text("初期設定は720p・30 fpsです。高解像度や60 fpsは、発熱・電池消費が増えることがあります。端末に対応する組み合わせで撮影します。")
                }
                Section("表示") {
                    Toggle("映像全体を表示", isOn: $showEntireFrame)
                        .accessibilityIdentifier("showEntireFrameToggle")
                    Text(showEntireFrame ? "映像全体が収まるように表示します。余白ができることがあります。" : "画面に合わせて中央を切り取ります。上下の範囲は同じです。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("現在の状態") {
                    LabeledContent("映像", value: usesDemo ? "色見本" : "背面カメラ")
                    LabeledContent("選択中", value: "\(resolution.title) / \(frameRate) fps")
                    if !camera.actualFormat.isEmpty && !usesDemo {
                        LabeledContent("撮影中", value: camera.actualFormat)
                    }
                    if let notice = camera.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                    if usesDemo {
                        Text("撮影画質は、カメラに切り替えたときに適用します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("見え方を比べるための試作アプリです。赤の強さを青にする方式では、白や黄色も青くなります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("撮影設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showsSettings = false }
                        .accessibilityIdentifier("settingsDone")
                }
            }
        }
    }

    private func synchronizeCamera() {
        if !usesDemo && scenePhase == .active {
            camera.update(settings: requestedSettings)
            camera.start()
        } else {
            camera.stop()
        }
    }
}

#Preview {
    ContentView(demo: true)
}
