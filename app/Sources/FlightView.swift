import MetalKit

/// Metal view that forwards keyboard and mouse input to its renderer.
final class FlightView: MTKView {
    var renderer: Renderer?

    /// Takes keyboard focus when set, e.g., once the parameter panel closes.
    var flightFocus = false {
        didSet { if flightFocus, !oldValue { takeFocus() } }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if flightFocus { takeFocus() }
    }

    private func takeFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        renderer?.look(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report points; mouse wheels report lines.
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        renderer?.zoom(Float(event.scrollingDeltaY) * scale)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased(),
              renderer?.keyDown(key, repeated: event.isARepeat) == true
        else { return super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        renderer?.keyUp(key)
    }

    override func flagsChanged(with event: NSEvent) {
        renderer?.boost = event.modifierFlags.contains(.shift)
    }
}
