import Foundation

nonisolated enum ColorMode: Int, CaseIterable, Identifiable, Sendable {
    case redAsBlue = 0
    case swapRedBlue = 1
    case highlightRed = 2
    case original = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .redAsBlue: "赤の強さを青に"
        case .swapRedBlue: "赤と青を交換"
        case .highlightRed: "赤い部分を強調"
        case .original: "変換なし"
        }
    }

    var detail: String {
        switch self {
        case .redAsBlue: "R成分を青の濃淡で表示します。白や黄色も青くなります。"
        case .swapRedBlue: "RとBを入れ替えます。白と灰色は保たれます。"
        case .highlightRed: "無彩色の映像で、赤が優勢な部分を青く強調します。"
        case .original: "上下とも元の映像を表示します。"
        }
    }

    var symbol: String {
        switch self {
        case .redAsBlue: "drop.fill"
        case .swapRedBlue: "arrow.left.arrow.right"
        case .highlightRed: "viewfinder"
        case .original: "circle.lefthalf.filled"
        }
    }
}

nonisolated enum CaptureResolution: Int, CaseIterable, Identifiable, Sendable {
    case vga = 480
    case hd = 720
    case fullHD = 1080
    case uhd = 2160

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .vga: "480p"
        case .hd: "720p"
        case .fullHD: "1080p"
        case .uhd: "4K"
        }
    }

    var width: Int32 {
        switch self {
        case .vga: 640
        case .hd: 1280
        case .fullHD: 1920
        case .uhd: 3840
        }
    }

    var height: Int32 { Int32(rawValue) }
    var dimensions: String { "\(width) × \(height)" }
}

nonisolated struct CaptureSettings: Equatable, Sendable {
    var resolution: CaptureResolution = .hd
    var frameRate: Int = 30
}

nonisolated enum CameraState: Equatable, Sendable {
    case idle
    case requesting
    case running
    case denied
    case unavailable
    case failed(String)
}
