import Foundation
import CoreGraphics
import QuartzCore
import UIKit
@preconcurrency import FigCraftKit

/// A Sendable pixel buffer that crosses actors (never a `CGImage`).
struct PixelFrame: Sendable {
    let width: Int
    let height: Int
    let rgba: Data

    init?(_ image: RenderedImage) {
        let w = Int(image.width), h = Int(image.height)
        guard w > 0, h > 0, image.rgba.count >= w * h * 4 else { return nil }
        width = w
        height = h
        rgba = Data(image.rgba)
    }

    /// Premultiplied RGBA to a `CGImage`. Call on any actor (the result stays where it was made).
    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Wraps the bridge `Presenter` (prototype playback). Ticks at 30 Hz only while ticking is on.
@MainActor @Observable
final class PresentModel {
    var state: PresentState
    var image: CGImage?
    /// Hotspots (prototype points) flashed after a tap where nothing reacted; cleared after a moment.
    var flashedHotspots: [Rect] = []

    @ObservationIgnored private let presenter: Presenter
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderPending = false
    @ObservationIgnored private var lastSize = CGSize.zero
    @ObservationIgnored private var lastScale: CGFloat = 2
    @ObservationIgnored private let startTime = CACurrentMediaTime()

    init(presenter: Presenter) {
        self.presenter = presenter
        state = presenter.state()
        startTicking()
    }

    /// Stops the 30 Hz driver (call when presenting ends).
    func stop() {
        tickTask?.cancel()
        tickTask = nil
        flashTask?.cancel()
    }

    func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                self.tick()
            }
        }
    }

    // MARK: Input

    /// Maps a point of the on-screen picture (aspect-fit in `size`) to prototype points.
    func prototypePoint(_ point: CGPoint, in size: CGSize) -> CGPoint? {
        let w = state.width, h = state.height
        guard w > 0, h > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = min(size.width / w, size.height / h)
        guard scale.isFinite, scale > 0 else { return nil }
        let ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2
        let x = (point.x - ox) / scale, y = (point.y - oy) / scale
        guard x >= 0, y >= 0, x <= w, y <= h else { return nil }
        return CGPoint(x: x, y: y)
    }

    func tap(at point: CGPoint, in size: CGSize) {
        guard let p = prototypePoint(point, in: size) else { return }
        let reacted = presenter.tap(x: p.x, y: p.y)
        if !reacted { flashHotspots() }
        changed()
    }

    func press(at point: CGPoint, in size: CGSize, down: Bool) {
        guard let p = prototypePoint(point, in: size) else { return }
        if presenter.press(x: p.x, y: p.y, down: down) { changed() }
    }

    func drag(dx: Double, dy: Double) {
        if presenter.drag(dx: dx.finite(), dy: dy.finite()) { changed() }
    }

    func key(_ key: String) {
        if presenter.key(key: key) { changed() }
    }

    func back() {
        if presenter.back() { changed() }
    }

    func restart(from start: UInt64? = nil) {
        presenter.restart(start: start)
        changed()
    }

    /// Advances `afterDelay` timers; renders when the picture changed.
    func tick() {
        let now = (CACurrentMediaTime() - startTime) * 1000
        if presenter.tick(nowMs: now) { changed() }
    }

    func flashHotspots() {
        flashedHotspots = presenter.hotspots()
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { self?.flashedHotspots = [] }
        }
    }

    // MARK: Rendering

    /// Renders the current frame fit to `size` (points) at `scale` pixels per point, off the main actor.
    func render(size: CGSize, scale: CGFloat) {
        guard size.width > 1, size.height > 1 else { return }
        lastSize = size
        lastScale = max(1, scale)
        guard renderTask == nil else {
            renderPending = true
            return
        }
        let wPx = UInt32(min(4096, max(1, (size.width * lastScale).rounded(.up))))
        let hPx = UInt32(min(4096, max(1, (size.height * lastScale).rounded(.up))))
        let presenter = presenter
        renderTask = Task { @MainActor [weak self] in
            let frame = await Task.detached(priority: .userInitiated) { () -> PixelFrame? in
                guard let image = try? presenter.render(widthPx: wPx, heightPx: hPx) else { return nil }
                return PixelFrame(image)
            }.value
            guard let self else { return }
            if let frame { self.image = frame.makeCGImage() }
            self.renderTask = nil
            if self.renderPending {
                self.renderPending = false
                self.render(size: self.lastSize, scale: self.lastScale)
            }
        }
    }

    private func changed() {
        state = presenter.state()
        if let text = state.openUrl, let url = URL(string: text), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        }
        if lastSize.width > 1 { render(size: lastSize, scale: lastScale) }
    }
}
