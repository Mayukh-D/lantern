import SwiftUI

/// Dial in how screen colours look on the LEDs: pick a test colour, compare the bar with the
/// swatch, adjust. Settings persist and apply to Screen Sync, the colour wheel and Spectrum.
struct CalibrateView: View {
    @ObservedObject var light: Light
    var sync: ScreenSync
    var fx: Effects
    @State private var pick = 0
    @State private var hue = 0.0
    @State private var sat = 1.0
    @State private var rgb: (Double, Double, Double) = (230, 40, 40)

    private let tests: [(String, Color, (Double, Double, Double))] = [
        ("Red", .red, (230, 40, 40)), ("Orange", .orange, (240, 140, 40)), ("Yellow", .yellow, (240, 210, 50)),
        ("Green", .green, (60, 200, 80)), ("Teal", .teal, (40, 180, 180)), ("Blue", .blue, (50, 100, 230)),
        ("Purple", .purple, (140, 70, 220)), ("Pink", .pink, (230, 80, 160)), ("Muted", Color(red: 0.35, green: 0.55, blue: 0.75), (90, 140, 190))]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate colours").font(.system(size: 15, weight: .semibold))
            Text("Pick a colour, then adjust until the bar matches the swatch.").font(.system(size: 12)).foregroundStyle(.secondary)

            HStack(spacing: 16) {
                ColorWheel(hue: $hue, saturation: $sat) { pick = -1; fromWheel(); send() }
                    .frame(width: 170, height: 170)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255))
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
                    Text("On screen: what the bar should look like").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(String(format: "RGB %.0f · %.0f · %.0f", rgb.0, rgb.1, rgb.2)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    Button { grab() } label: { Label("Grab from screen", systemImage: "eyedropper") }
                        .controlSize(.small)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 9), spacing: 8) {
                ForEach(tests.indices, id: \.self) { i in
                    Button { pick = i; rgb = tests[i].2; send() } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: tests[i].2.0 / 255, green: tests[i].2.1 / 255, blue: tests[i].2.2 / 255))
                            .frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(i == pick ? Color.primary : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).help(tests[i].0)
                }
            }

            Divider()
            row("Saturation", "Pastel", "Vivid", $light.saturation, 1...5)
            row("Gamma", "Softer", "Purer", $light.gamma, 1...3.5)
            Divider()
            row("Red", "Less", "More", $light.gainR, 0.4...1)
            row("Green", "Less", "More", $light.gainG, 0.4...1)
            row("Blue", "Less", "More", $light.gainB, 0.4...1)

            HStack {
                Button("Reset to defaults") { light.resetCalibration(); send() }
                Spacer()
                Text("Saved automatically").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { sync.stop(); fx.stop(); send() }
    }

    private func row(_ name: String, _ lo: String, _ hi: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium)).frame(width: 74, alignment: .leading)
            Text(lo).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
            Slider(value: v, in: r).onChange(of: v.wrappedValue) { _, _ in send() }
            Text(hi).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 40, alignment: .leading)
            Text(String(format: "%.2f", v.wrappedValue)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 36)
        }
    }

    /// macOS's colour loupe: click any pixel on any screen.
    private func grab() {
        Grabber.shared.grab { n in
            do {
                pick = -1
                rgb = (n.redComponent * 255, n.greenComponent * 255, n.blueComponent * 255)
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                n.getHue(&h, saturation: &s, brightness: &v, alpha: &a); hue = h; sat = s
                send()
            }
        }
    }
    private func fromWheel() {
        let n = NSColor(hue: hue, saturation: sat, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
        rgb = (n.redComponent * 255, n.greenComponent * 255, n.blueComponent * 255)
    }
    private func send() { light.setColor(r: rgb.0, g: rgb.1, b: rgb.2) }
}
