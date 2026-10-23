import UIKit
@preconcurrency import FigCraftKit

/// The UIKit canvas: the engine render (a layer), the overlay, the gesture recognizers and the text-input
/// responder. Touches are handled in `touches*` (not recognizers) so a tap is one down/up pair and a second
/// finger can cancel the single-finger interaction; pinch, two-finger pan, scroll and the double taps are
/// recognizers that do not cancel touches.
@MainActor
final class CanvasHostView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    private let model: EditorModel
    private let imageLayer = CALayer()
    private let overlayView = CanvasOverlayView()

    private var tool = "move"
    private var editingText = false
    private var lastViewport = CGSize.zero
    private var lastRevision = -1

    // Rendering: one render in flight, newer requests coalesce into one follow-up.
    private var rendering = false
    private var renderPending = false

    // Single-pointer tracking.
    private var liveTouches = Set<UITouch>()
    private var primary: UITouch?
    private var multiTouch = false
    private var downSent = false
    private var panning = false
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastPencil = Date.distantPast
    private var deferTask: Task<Void, Never>?
    private var pinchStartZoom = 1.0

    /// Pixels a finger must move before a deferred "down" is sent (so a second finger can still claim the touch).
    private let slop: CGFloat = 4
    private let deferDelay: Duration = .milliseconds(120)

    // UITextInputTraits: no autocorrect on design text edits.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .secondarySystemBackground
        clipsToBounds = true
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Canvas"
        accessibilityTraits = .allowsDirectInteraction
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        layer.addSublayer(imageLayer)
        addSubview(overlayView)
        installRecognizers()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Model updates

    func apply(revision: Int, overlay: Overlay, editingText editing: Bool, tool newTool: String) {
        tool = newTool
        overlayView.overlay = overlay
        if editing != editingText {
            editingText = editing
            Task { @MainActor [weak self] in
                guard let self else { return }
                if editing { _ = self.becomeFirstResponder() } else if self.isFirstResponder { _ = self.resignFirstResponder() }
            }
        }
        if revision != lastRevision {
            lastRevision = revision
            requestRender()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        overlayView.frame = bounds
        CATransaction.commit()
        let size = bounds.size
        if size.width >= 1, size.height >= 1, size != lastViewport {
            lastViewport = size
            // Not inside the layout pass: the model publishes state changes.
            Task { @MainActor [weak self] in
                guard let self, self.bounds.size == size else { return }
                self.model.setViewport(size)
            }
        }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        overlayView.tintColor = tintColor
        overlayView.setNeedsDisplay()
    }

    // MARK: Rendering

    private func requestRender() {
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        if rendering {
            renderPending = true
            return
        }
        rendering = true
        let scale = max(1, traitCollection.displayScale)
        let size = bounds.size
        let wPx = UInt32(min(8192, max(1, (size.width * scale).rounded(.up))))
        let hPx = UInt32(min(8192, max(1, (size.height * scale).rounded(.up))))
        let handle = model.handle
        Task { @MainActor [weak self] in
            let frame = await Task.detached(priority: .userInitiated) { () -> PixelFrame? in
                guard let image = try? handle.render(widthPx: wPx, heightPx: hPx, scale: Double(scale)) else { return nil }
                return PixelFrame(image)
            }.value
            guard let self else { return }
            self.rendering = false
            var again = self.renderPending
            self.renderPending = false
            if let frame {
                if self.bounds.size == size, let cgImage = frame.makeCGImage() {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.imageLayer.contentsScale = scale
                    self.imageLayer.contents = cgImage
                    CATransaction.commit()
                } else {
                    again = true  // stale size: render again at the current one
                }
            }
            if again { self.requestRender() }
        }
    }

    // MARK: Recognizers

    private func installRecognizers() {
        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.allowedScrollTypesMask = []

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedTouchTypes = []
        scroll.allowedScrollTypesMask = [.all]

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1

        let fitTap = UITapGestureRecognizer(target: self, action: #selector(handleFitTap(_:)))
        fitTap.numberOfTapsRequired = 2
        fitTap.numberOfTouchesRequired = 2

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))

        for recognizer in [twoFinger, scroll, pinch, doubleTap, fitTap, hover] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed || g.state == .ended else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        model.panView(dx: t.x, dy: t.y)
    }

    @objc private func handleScroll(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        model.panView(dx: t.x, dy: t.y)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartZoom = model.state.zoom
        case .changed:
            let scale = g.scale
            guard scale.isFinite, scale > 0 else { return }
            model.zoomView(to: pinchStartZoom * Double(scale), at: g.location(in: self))
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        model.pointer("double", at: g.location(in: self))
    }

    @objc private func handleFitTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        model.fitView()
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed, primary == nil else { return }
        model.pointer("hover", at: g.location(in: self))
    }

    // MARK: Touches

    private func modifiers(_ event: UIEvent?) -> (shift: Bool, alt: Bool, cmd: Bool, ctrl: Bool) {
        let flags = event?.modifierFlags ?? []
        return (flags.contains(.shift), flags.contains(.alternate), flags.contains(.command), flags.contains(.control))
    }

    private func pressure(_ touch: UITouch) -> Double? {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return nil }
        let value = Double(touch.force / touch.maximumPossibleForce)
        return value.isFinite ? min(1, max(0, value)) : nil
    }

    /// A finger pans instead of acting with the Hand tool, and while a Pencil is in use with a drawing tool.
    private func fingerPans(_ touch: UITouch) -> Bool {
        if touch.type == .pencil { return false }
        if tool == "hand" { return true }
        let drawing = tool == "pen" || tool == "pencil"
        return drawing && touch.type == .direct && Date().timeIntervalSince(lastPencil) < 5
    }

    private func send(_ kind: String, _ touch: UITouch, at point: CGPoint, _ event: UIEvent?) {
        let m = modifiers(event)
        model.pointer(kind, at: point, pressure: pressure(touch), shift: m.shift, alt: m.alt, cmd: m.cmd, ctrl: m.ctrl)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .pencil }) { lastPencil = Date() }
        liveTouches.formUnion(touches)
        if liveTouches.count >= 2 {
            cancelSingle(event)
            multiTouch = true
            return
        }
        guard !multiTouch, let touch = touches.first else { return }
        primary = touch
        startPoint = touch.location(in: self)
        lastPoint = startPoint
        downSent = false
        panning = fingerPans(touch)
        if panning { return }
        if touch.type == .direct {
            deferTask?.cancel()
            deferTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.deferDelay ?? .milliseconds(120))
                guard !Task.isCancelled, let self, let touch = self.primary, !self.downSent, !self.multiTouch else { return }
                self.sendDown(touch, event)
            }
        } else {
            sendDown(touch, event)
        }
    }

    private func sendDown(_ touch: UITouch, _ event: UIEvent?) {
        guard !downSent else { return }
        downSent = true
        send("down", touch, at: startPoint, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = primary, touches.contains(touch), !multiTouch else { return }
        let samples = (touch.type == .pencil ? event?.coalescedTouches(for: touch) : nil) ?? [touch]
        for sample in samples {
            let point = sample.location(in: self)
            if panning {
                model.panView(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
            } else {
                if !downSent {
                    guard hypot(point.x - startPoint.x, point.y - startPoint.y) > slop else { continue }
                    deferTask?.cancel()
                    sendDown(touch, event)
                }
                send("move", sample, at: point, event)
            }
            lastPoint = point
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent?, cancelled: Bool) {
        liveTouches.subtract(touches)
        defer { if liveTouches.isEmpty { multiTouch = false } }
        guard let touch = primary, touches.contains(touch) else { return }
        deferTask?.cancel()
        let point = cancelled ? lastPoint : touch.location(in: self)
        if !panning && !multiTouch {
            if !downSent {
                if cancelled {
                    primary = nil
                    return
                }
                startPoint = point  // a tap: down and up at the same place
                sendDown(touch, event)
            }
            send("up", touch, at: point, event)
        }
        primary = nil
        panning = false
        downSent = false
    }

    /// A second finger arrived: end a started single-pointer interaction where it is and ignore the rest.
    private func cancelSingle(_ event: UIEvent?) {
        deferTask?.cancel()
        if let touch = primary, downSent, !panning { send("up", touch, at: lastPoint, event) }
        primary = nil
        panning = false
        downSent = false
    }

    // MARK: Text input (software and hardware keyboard while editing text)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) { model.insertText(text) }
    func deleteBackward() { model.key("Backspace") }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard editingText else {
            super.pressesBegan(presses, with: event)
            return
        }
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let name = Self.keyName(key.keyCode), !key.modifierFlags.contains(.command) else {
                unhandled.insert(press)
                continue
            }
            let flags = key.modifierFlags
            if !model.key(name, shift: flags.contains(.shift), alt: flags.contains(.alternate), cmd: false) {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private static func keyName(_ code: UIKeyboardHIDUsage) -> String? {
        switch code {
        case .keyboardLeftArrow: "Left"
        case .keyboardRightArrow: "Right"
        case .keyboardUpArrow: "Up"
        case .keyboardDownArrow: "Down"
        case .keyboardDeleteOrBackspace: "Backspace"
        case .keyboardDeleteForward: "Delete"
        case .keyboardReturnOrEnter, .keypadEnter: "Enter"
        case .keyboardEscape: "Escape"
        case .keyboardTab: "Tab"
        case .keyboardHome: "Home"
        case .keyboardEnd: "End"
        default: nil
        }
    }
}
