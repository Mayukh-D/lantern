import SwiftUI

/// Effects: the bar's own rainbow patterns, plus Spectrum (the whole bar gliding around the
/// colour wheel), which Lantern drives itself so it stays perfectly smooth.
final class Effects: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case rainbowForward = "Rainbow →", rainbowBack = "Rainbow ←", spectrum = "Spectrum"
        var id: String { rawValue }
        var blurb: String {
            switch self {
            case .rainbowForward: return "A rainbow flowing along the bar."
            case .rainbowBack: return "The same rainbow, flowing the other way."
            case .spectrum: return "The whole bar as one colour, gliding around the colour wheel."
            }
        }
    }
    @Published var active: Kind?
    @Published var speed: Double = 50 {            // 0...100, shared by all effects
        didSet { if let a = active { apply(a, restart: false) } }
    }
    @Published var nowShowing: Color = .gray
    weak var light: Light?
    private var timer: Timer?
    private var hue = 0.0

    func start(_ k: Kind) { active = k; apply(k, restart: true) }
    func stop() { timer?.invalidate(); timer = nil; active = nil }

    private func apply(_ k: Kind, restart: Bool) {
        switch k {
        case .rainbowForward, .rainbowBack:
            timer?.invalidate(); timer = nil
            if restart { light?.setEffect(k == .rainbowForward ? 0x01 : 0x02) }
            light?.setEffectSpeed(speed)
        case .spectrum:
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        // speed 0 -> one lap a minute, 100 -> one lap every 3 seconds
        let lap = 60 * pow(3.0 / 60, speed / 100)
        hue = (hue + 1 / (lap * 30)).truncatingRemainder(dividingBy: 1)
        let c = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
        light?.setColor(r: c.redComponent * 255, g: c.greenComponent * 255, b: c.blueComponent * 255)
        nowShowing = Color(hue: hue, saturation: 1, brightness: 1)
    }
}
