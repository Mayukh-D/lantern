import AppKit
import ScreenCaptureKit

/// Click-anywhere colour grab: a transparent crosshair layer over every screen; the clicked
/// pixel is read with ScreenCaptureKit (Lantern already has Screen Recording). Esc cancels.
@MainActor
final class Grabber {
    static let shared = Grabber()
    private var windows: [NSWindow] = []
    private var done: ((NSColor) -> Void)?
    private var keyMonitor: Any?

    func grab(_ completion: @escaping (NSColor) -> Void) {
        cancel()
        done = completion
        for screen in NSScreen.screens {
            let w = GrabWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = NSColor.black.withAlphaComponent(0.001)
            w.ignoresMouseEvents = false; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = GrabView(frame: NSRect(origin: .zero, size: screen.frame.size)); v.onClick = { [weak self] in self?.pick() }
            w.contentView = v
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel(); return nil }; return e
        }
    }

    func cancel() {
        windows.forEach { $0.orderOut(nil) }; windows = []
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }

    private func pick() {
        let p = NSEvent.mouseLocation
        let cb = done
        cancel()
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let local = CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
        Task {
            // let the crosshair layer leave the screen before reading the pixel
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == num.uint32Value }) else { return }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: local.x - 1, y: local.y - 1, width: 2, height: 2)
            cfg.width = 2; cfg.height = 2; cfg.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg) else { return }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))     // averages the 2×2 sample
            let c = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
            await MainActor.run { cb?(c) }
        }
    }
}

private final class GrabWindow: NSWindow { override var canBecomeKey: Bool { true } }
private final class GrabView: NSView {
    var onClick: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
