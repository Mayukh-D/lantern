import ScreenCaptureKit
import SwiftUI

/// Watches a tiny downscaled copy of a display and drives the light with its dominant vivid colour.
/// Nothing is stored or sent anywhere: each frame is reduced to three colours and dropped.
final class ScreenSync: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var running = false
    @Published var error: String?
    @Published var needsPermission = false
    @Published var frames = 0                     // frames received since start, for diagnosis
    @Published var swatches: [Color] = []
    @Published var displays: [SCDisplay] = []
    @Published var displayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var smoothing: Double = 0.15       // 0 = instant, 1 = very smooth
    enum Style: String, CaseIterable { case main = "Main colour", flow = "Flow" }
    /// Main colour: the light shows the colour covering the most pixels. Flow: it cycles through the top ten.
    @Published var style: Style = .main

    weak var light: Light?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "lantern.frames")
    private var current: (Double, Double, Double) = (255, 255, 255)

    func refreshDisplays() async {
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        await MainActor.run { self.displays = content?.displays ?? [] }
    }

    func toggle() { if running { stop() } else { Task { await start() } } }

    func start() async {
        // Screen Recording is granted per build; ask macOS first instead of failing silently
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            await MainActor.run {
                self.needsPermission = true
                self.error = "Lantern needs Screen Recording. Turn it on in Settings, then quit and reopen Lantern."
            }
            return
        }
        await MainActor.run { self.needsPermission = false; self.frames = 0 }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw NSError(domain: "Lantern", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
            }
            let cfg = SCStreamConfiguration()
            cfg.width = 96; cfg.height = 54                     // tiny: colour, not detail
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // quick: 30 reads a second
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.queueDepth = 3
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            await MainActor.run { self.stream = s; self.running = true; self.error = nil; self.displays = content.displays }
        } catch {
            await MainActor.run {
                self.running = false
                self.error = "Couldn't start screen capture: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        running = false
        swatches = []; palette = []; smoothed = [:]
        timer?.invalidate(); timer = nil
    }

    func restartIfRunning() { if running { stop(); Task { await start() } } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.running = false; self.error = error.localizedDescription }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        let p = base.assumingMemoryBound(to: UInt8.self)

        // 24 hue buckets x 2 brightness bands; neutrals (greys, whites, blacks) counted separately
        var count = [Double](repeating: 0, count: Self.buckets)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: Self.buckets)
        var total = 0.0, dark = 0.0, light = 0.0, lightSum = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let o = y * row + x * 4
                let b = Double(p[o]), g = Double(p[o + 1]), r = Double(p[o + 2])
                total += 1
                let mx = max(r, g, b), mn = min(r, g, b)
                let v = mx / 255, sat = mx > 0 ? (mx - mn) / mx : 0
                if v <= 0.05 { dark += 1; continue }                          // only near-true black counts as black
                guard sat > 0.2 else { light += 1; lightSum += v; continue }     // greys and whites (dim colours like navy stay colours)
                var hue: Double
                if mx == r { hue = (g - b) / (mx - mn) } else if mx == g { hue = 2 + (b - r) / (mx - mn) } else { hue = 4 + (r - g) / (mx - mn) }
                hue = (hue < 0 ? hue + 6 : hue) / 6
                let k = min(23, Int(hue * 24)) * 2 + (v > 0.55 ? 1 : 0)
                count[k] += 1
                sums[k].0 += r; sums[k].1 += g; sums[k].2 += b
            }
        }
        var frame: [Swatch] = []
        for k in 0..<Self.buckets where count[k] > 0 {
            let c = (sums[k].0 / count[k], sums[k].1 / count[k], sums[k].2 / count[k])
            frame.append(Swatch(bucket: k, rgb: c, share: count[k] / max(total, 1)))
        }
        let darkShare = dark / max(total, 1), lightShare = light / max(total, 1)
        let lightLevel = light > 0 ? lightSum / light : 0
        DispatchQueue.main.async {
            self.frames += 1
            self.darkShare += (darkShare - self.darkShare) * 0.7
            self.lightShare += (lightShare - self.lightShare) * 0.7
            self.lightLevel = lightLevel
            self.absorb(frame)
        }
    }

    // MARK: palette

    struct Swatch: Identifiable {
        let bucket: Int
        var rgb: (Double, Double, Double)
        var share: Double                 // fraction of the whole screen
        var id: Int { bucket }
        var color: Color { Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255) }
        var hue: Double { Double(bucket / 2) / 24 }
    }
    static let buckets = 48

    /// Top ten colours on screen, ordered around the colour wheel, with their share of the screen.
    @Published var palette: [Swatch] = []
    /// Seconds for one pass through the whole palette.
    @Published var cycleSeconds: Double = 16
    private var smoothed: [Int: Swatch] = [:]
    private var timer: Timer?
    private var started = Date()

    private func absorb(_ frame: [Swatch]) {
        // ease shares between frames so the palette doesn't jitter
        let a = style == .main ? 0.7 : 0.35       // main colour reacts fast; flow keeps a steadier palette
        var next: [Int: Swatch] = [:]
        for f in frame { var s = smoothed[f.bucket] ?? Swatch(bucket: f.bucket, rgb: f.rgb, share: 0)
            s.share += (f.share - s.share) * a
            s.rgb = (s.rgb.0 + (f.rgb.0 - s.rgb.0) * a, s.rgb.1 + (f.rgb.1 - s.rgb.1) * a, s.rgb.2 + (f.rgb.2 - s.rgb.2) * a)
            next[f.bucket] = s }
        for (k, var s) in smoothed where next[k] == nil { s.share *= 1 - a; if s.share > 0.002 { next[k] = s } }
        smoothed = next
        palette = Array(smoothed.values.sorted { $0.share > $1.share }.prefix(10)).sorted { $0.bucket < $1.bucket }
        swatches = palette.sorted { $0.share > $1.share }.prefix(3).map { $0.color }
        if timer == nil { startTimer() }
    }

    private func startTimer() {
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Flow through every palette colour; each one holds for a time proportional to its share,
    /// then crossfades into the next, so the light carries the whole screen's mix over a cycle.
    private var ticks = 0
    private func tick() {
        guard running else { return }
        let pal = palette
        guard !pal.isEmpty else {
            if darkShare > lightShare { light?.setRaw(r: 0, g: 0, b: 0); nowShowing = .black }
            else { let l = 255 * (0.25 + 0.75 * lightLevel); light?.setColor(r: l, g: l, b: l); nowShowing = Color(white: l / 255) }
            return
        }
        if style == .main, let top = pal.max(by: { $0.share < $1.share }) {
            // colour vs greys vs black, by how much of the screen each covers in total. Colours are
            // split over many hue buckets, so they compete as a group; the biggest one is shown.
            let colourShare = pal.reduce(0) { $0 + $1.share }
            if darkShare > colourShare && darkShare > lightShare {
                target = top.share >= prominence ? vivid(top.rgb) : (0, 0, 0)    // a strong colour beats black
            }
            else if lightShare > colourShare { let l = 255 * (0.25 + 0.75 * lightLevel); target = (l, l, l) }
            else { target = vivid(top.rgb) }
            let k = 1 - smoothing * 0.85
            current.0 += (target.0 - current.0) * k
            current.1 += (target.1 - current.1) * k
            current.2 += (target.2 - current.2) * k
            light?.setColor(r: current.0, g: current.1, b: current.2)
            nowShowing = Color(red: current.0 / 255, green: current.1 / 255, blue: current.2 / 255)
            return
        }
        let total = pal.reduce(0) { $0 + $1.share }
        let phase = Date().timeIntervalSince(started).truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
        var acc = 0.0, i = 0
        for (j, s) in pal.enumerated() { let f = s.share / total; if phase < acc + f { i = j; break }; acc += f; i = j }
        let f = pal[i].share / total, local = f > 0 ? (phase - acc) / f : 1
        let a = vivid(pal[i].rgb), b = vivid(pal[(i + 1) % pal.count].rgb)
        let t = local < 0.6 ? 0 : (local - 0.6) / 0.4            // hold, then crossfade over the last 40%
        let e = t * t * (3 - 2 * t)
        target = (a.0 + (b.0 - a.0) * e, a.1 + (b.1 - a.1) * e, a.2 + (b.2 - a.2) * e)
        let k = 1 - smoothing * 0.85
        current.0 += (target.0 - current.0) * k
        current.1 += (target.1 - current.1) * k
        current.2 += (target.2 - current.2) * k
        light?.setColor(r: current.0, g: current.1, b: current.2)
        nowShowing = Color(red: current.0 / 255, green: current.1 / 255, blue: current.2 / 255)
    }
    @Published var nowShowing: Color = .gray
    /// Share of the screen that is black or nearly so; in Main colour mode, black can win.
    @Published var darkShare = 0.0
    /// If black wins but one colour covers at least this share of the screen, show that colour.
    @Published var prominence: Double = UserDefaults.standard.object(forKey: "sync.prominence") as? Double ?? 0.10 {
        didSet { UserDefaults.standard.set(prominence, forKey: "sync.prominence") }
    }
    /// Share that is grey or white, and how bright those pixels are on average.
    @Published var lightShare = 0.0
    var lightLevel = 0.0
    private var target: (Double, Double, Double) = (255, 255, 255)
    /// Lift a screen colour toward full brightness but keep some of its depth: navy stays a
    /// deeper, dimmer blue than sky blue (brightness mapped into 40...100%).
    private func vivid(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let m = max(c.0, c.1, c.2, 1), level = 0.4 + 0.6 * (m / 255)
        return (c.0 / m * 255 * level, c.1 / m * 255 * level, c.2 / m * 255 * level)
    }
}
