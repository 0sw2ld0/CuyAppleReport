import AppKit
import ImageIO
import SwiftUI

extension Feedback {
    /// Capturas en el orden en que las envió el tester (los archivos se llaman `0.jpg`, `1.jpg`…).
    var orderedScreenshotPaths: [String] {
        screenshotPaths.sorted { lhs, rhs in
            let l = Int(URL(fileURLWithPath: lhs).deletingPathExtension().lastPathComponent) ?? .max
            let r = Int(URL(fileURLWithPath: rhs).deletingPathExtension().lastPathComponent) ?? .max
            return l == r ? lhs < rhs : l < r
        }
    }
}

/// Miniaturas generadas con ImageIO fuera del hilo principal y guardadas en caché.
enum ThumbnailCache {
    private final class Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    static func cached(_ path: String, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(path, maxPixel))?.image
    }

    static func load(_ path: String, maxPixel: Int) async -> CGImage? {
        if let image = cached(path, maxPixel: maxPixel) { return image }
        let box = await Task.detached(priority: .userInitiated) { () -> Box? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Box.init)
        }.value
        if let box { cache.setObject(box, forKey: key(path, maxPixel)) }
        return box?.image
    }

    private static func key(_ path: String, _ maxPixel: Int) -> NSString { "\(maxPixel)|\(path)" as NSString }
}

/// Imagen local que se carga como miniatura, con un placeholder animado mientras tanto.
struct ScreenshotImage: View {
    let path: String
    var maxPixel = 600
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                ShimmerPlaceholder()
            }
        }
        .task(id: "\(maxPixel)|\(path)") {
            if let cached = ThumbnailCache.cached(path, maxPixel: maxPixel) {
                image = cached
                return
            }
            let loaded = await ThumbnailCache.load(path, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}

private struct ShimmerPlaceholder: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            GeometryReader { proxy in
                Rectangle().fill(.quaternary)
                    .overlay(
                        LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: (phase * 1.6 - 0.3) * proxy.size.width)
                    )
                    .clipped()
            }
        }
    }
}

/// Visor del inspector: imagen grande, flechas, contador y tira de miniaturas.
struct ScreenshotGallery: View {
    let paths: [String]
    @State private var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let current = paths[min(index, paths.count - 1)]
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.25))
                ScreenshotImage(path: current, maxPixel: 1600, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                    .id(current)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: current)) }
                    .help("Doble clic para abrir en Vista Previa")
            }
            .frame(height: 380)
            .overlay(alignment: .topTrailing) {
                if paths.count > 1 {
                    Text("\(index + 1) / \(paths.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .overlay {
                if paths.count > 1 {
                    HStack {
                        arrow("chevron.left", enabled: index > 0) { index -= 1 }
                        Spacer()
                        arrow("chevron.right", enabled: index < paths.count - 1) { index += 1 }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: index)

            if paths.count > 1 {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(paths.enumerated()), id: \.offset) { offset, path in
                                ScreenshotImage(path: path, maxPixel: 240)
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(offset == index ? Color.accentColor : Color.clear, lineWidth: 2.5))
                                    .opacity(offset == index ? 1 : 0.65)
                                    .scaleEffect(offset == index ? 1 : 0.94)
                                    .onTapGesture { index = offset }
                                    .id(offset)
                            }
                        }
                        .padding(.vertical, 3)
                        .animation(.spring(duration: 0.25), value: index)
                    }
                    .onChange(of: index) { _, value in withAnimation { reader.scrollTo(value, anchor: .center) } }
                }
            }

            HStack {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: current)) } label: {
                    Label("Abrir", systemImage: "arrow.up.forward.app")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
                } label: {
                    Label("Mostrar en Finder", systemImage: "folder")
                }
                Spacer()
                Text(paths.count == 1 ? "1 captura" : "\(paths.count) capturas")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .onKeyPress(.leftArrow) { if index > 0 { index -= 1 }; return .handled }
        .onKeyPress(.rightArrow) { if index < paths.count - 1 { index += 1 }; return .handled }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }
}

/// Portada de la tarjeta de galería: primera captura grande y tira con el resto.
struct ScreenshotCardPreview: View {
    let paths: [String]

    var body: some View {
        VStack(spacing: 6) {
            ScreenshotImage(path: paths[0], maxPixel: 700)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topTrailing) {
                    if paths.count > 1 {
                        Label("\(paths.count)", systemImage: "photo.stack")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(7)
                    }
                }
            if paths.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(paths.dropFirst().prefix(4).enumerated()), id: \.offset) { offset, path in
                        ScreenshotImage(path: path, maxPixel: 200)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                if offset == 3, paths.count > 5 {
                                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.55))
                                    Text("+\(paths.count - 5)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                    }
                }
            }
        }
    }
}
