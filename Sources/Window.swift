import SwiftUI

/// Colour temperature in Kelvin -> sRGB for the on-screen preview (Tanner Helland's fit).
func kelvinToRGB(_ k: Double) -> (Double, Double, Double) {
    let t = k / 100
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
    let c = { (v: Double) in max(0, min(255, v)) }
    return (c(r), c(g), c(b))
}

/// Kelvin -> what to send to an RGB LED strip. LED green and blue are much stronger than a
/// screen's, so a screen formula reads cool and green on the light; this table pulls them down.
/// `tint` (-1...1) shifts green against magenta to match the light by eye.
func kelvinToLED(_ k: Double, tint: Double) -> (Double, Double, Double) {
    let table: [(Double, Double, Double, Double)] = [
        (2700, 255, 92, 12), (3000, 255, 112, 22), (3500, 255, 138, 42),
        (4000, 255, 160, 66), (5000, 255, 192, 112), (5800, 255, 212, 150), (6500, 248, 222, 182)]
    let kk = max(2700, min(6500, k))
    var i = 0; while i < table.count - 2 && kk > table[i + 1].0 { i += 1 }
    let a = table[i], b = table[i + 1], f = (kk - a.0) / (b.0 - a.0)
    var r = a.1 + (b.1 - a.1) * f, g = a.2 + (b.2 - a.2) * f, bl = a.3 + (b.3 - a.3) * f
    g *= 1 + tint * 0.25; r *= 1 - max(0, tint) * 0.05; bl *= 1 - tint * 0.15
    let c = { (v: Double) in max(0, min(255, v)) }
    return (c(r), c(g), c(bl))
}

/// The warmth bar: a gradient track you can click or drag anywhere on.
struct WarmthBar: View {
    @Binding var kelvin: Double
    var onChange: () -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, x = 15 + (w - 30) * (kelvin - 2700) / 3800
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: stride(from: 2700.0, through: 6500, by: 380).map { k in
                    let v = kelvinToRGB(k); return Color(red: v.0 / 255, green: v.1 / 255, blue: v.2 / 255) }, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
                Circle().fill(.white).frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .position(x: x, y: g.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = max(0, min(1, (v.location.x - 15) / (w - 30)))
                kelvin = 2700 + (f * 3800 / 50).rounded() * 50
                onChange()
            })
        }
        .frame(height: 28)
    }
}

/// Shared state for the window, so it survives closing and reopening.
final class Controls: ObservableObject {
    enum Mode: String, CaseIterable { case colour = "Colour", white = "White", effects = "Effects", sync = "Screen Sync" }
    @Published var mode: Mode = .colour
    @Published var hue: Double = 0.58        // 0...1
    @Published var saturation: Double = 0.8  // 0...1
    @Published var kelvin: Double = 3200
    @Published var tint: Double = 0
}

struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    var onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height), r = size / 2
            let angle = hue * 2 * .pi
            let knob = CGPoint(x: r + cos(angle) * saturation * r, y: r - sin(angle) * saturation * r)
            ZStack {
                // SwiftUI angles run clockwise; the knob maths runs anticlockwise, so the hues go in reverse
                Circle().fill(AngularGradient(gradient: Gradient(colors: (0...24).map {
                    Color(hue: Double((24 - $0) % 24) / 24, saturation: 1, brightness: 1) }), center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().strokeBorder(.primary.opacity(0.12))
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: 1))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(knob)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = v.location.x - r, dy = r - v.location.y
                var a = atan2(dy, dx); if a < 0 { a += 2 * .pi }
                hue = a / (2 * .pi)
                saturation = min(1, hypot(dx, dy) / r)
                onChange()
            })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct MainWindow: View {
    @ObservedObject var light: Light
    let sync: ScreenSync          // not observed here: see SyncPane
    @ObservedObject var c: Controls
    let fx: Effects               // not observed here: see EffectsPane
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 18) {
            // header
            HStack(spacing: 12) {
                PreviewTile(light: light, c: c, sync: sync, fx: fx)
                VStack(alignment: .leading, spacing: 2) {
                    Text(light.name).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(light.connected ? .green : .orange).frame(width: 7, height: 7)
                        Text(light.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { openWindow(id: "calibrate") } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("Calibrate colours")
                Toggle("Power", isOn: Binding(get: { light.isOn }, set: { light.setPower($0) }))
                    .toggleStyle(.switch).labelsHidden().disabled(!light.connected)
            }

            Picker("", selection: Binding(get: { c.mode }, set: { switchMode($0) })) {
                ForEach(Controls.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: .infinity)

            // one fixed height for every tab (fits the tallest, Screen Sync with two displays),
            // so switching tabs never resizes the window
            Group {
                switch c.mode {
                case .colour: colourPane
                case .white: whitePane
                case .effects: EffectsPane(fx: fx)
                case .sync: SyncPane(sync: sync)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 410, alignment: .top)
            .clipped()
            .disabled(!light.connected)

            // brightness, all modes
            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { light.brightness }, set: { light.setBrightness($0) }), in: 5...100)
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                Text("\(Int(light.brightness))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
            .disabled(!light.connected)
        }
        .padding(22)
        .frame(width: 420)
    }

    // MARK: panes
    private var colourPane: some View {
        VStack(spacing: 14) {
            ColorWheel(hue: $c.hue, saturation: $c.saturation) { applyColour() }
                .frame(width: 240, height: 240)
            HStack(spacing: 10) {
                Button {
                    Grabber.shared.grab { n in
                        do {
                            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                            n.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                            c.hue = h; c.saturation = s; applyColour()
                        }
                    }
                } label: { Image(systemName: "eyedropper").frame(width: 20, height: 20) }
                    .buttonStyle(.borderless).help("Grab a colour from the screen")
                ForEach([0.0, 0.08, 0.16, 0.33, 0.5, 0.62, 0.78, 0.9], id: \.self) { h in
                    Button { c.hue = h; c.saturation = 1; applyColour() } label: {
                        Circle().fill(Color(hue: h, saturation: 1, brightness: 1)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var whitePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Warmth").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            WarmthBar(kelvin: $c.kelvin) { applyWhite() }
            HStack {
                Text("Warm").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(c.kelvin)) K").font(.system(size: 13, weight: .semibold).monospacedDigit())
                Spacer()
                Text("Cool").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([("Candle", 2700.0), ("Warm", 3000), ("Neutral", 4000), ("Daylight", 5500), ("Cool", 6500)], id: \.0) { p in
                    Button(p.0) { c.kelvin = p.1; applyWhite() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tint").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack {
                    Text("Magenta").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $c.tint, in: -1...1) { _ in applyWhite() }
                        .onChange(of: c.tint) { _, _ in applyWhite() }
                    Text("Green").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("LEDs vary: nudge this until the light looks like a real bulb.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 20)
    }

    // MARK: actions
    private func switchMode(_ m: Controls.Mode) {
        if c.mode == .sync && m != .sync && sync.running { sync.stop() }
        if c.mode == .effects && m != .effects { fx.stop() }
        c.mode = m
        if m == .colour { applyColour() } else if m == .white { applyWhite() }
    }
    private func applyColour() {
        let n = NSColor(hue: c.hue, saturation: c.saturation, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
        light.setColor(r: n.redComponent * 255, g: n.greenComponent * 255, b: n.blueComponent * 255)
    }
    private func applyWhite() {
        let v = kelvinToLED(c.kelvin, tint: c.tint); light.setRaw(r: v.0, g: v.1, b: v.2)
    }
}


/// Live parts of the window observe their own model, so 30-a-second updates redraw only
/// themselves and never the header or the tab bar.
struct EffectsPane: View {
    @ObservedObject var fx: Effects
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Effects.Kind.allCases) { k in
                Button { fx.active == k ? fx.stop() : fx.start(k) } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(k == .spectrum
                                  ? AnyShapeStyle(AngularGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }, center: .center))
                                  : AnyShapeStyle(LinearGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                                                                 startPoint: k == .rainbowForward ? .leading : .trailing,
                                                                 endPoint: k == .rainbowForward ? .trailing : .leading)))
                            .frame(width: 52, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.rawValue).font(.system(size: 13, weight: .semibold))
                            Text(k.blurb).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: fx.active == k ? "stop.circle.fill" : "play.circle")
                            .font(.system(size: 20)).foregroundStyle(fx.active == k ? Color.accentColor : .secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(fx.active == k ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("Speed").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Text("Slow").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: $fx.speed, in: 0...100)
                Text("Fast").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
        .padding(.top, 6)
    }
}

struct SyncPane: View {
    @ObservedObject var sync: ScreenSync
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Match the light to your screen").font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(get: { sync.running }, set: { _ in sync.toggle() })).toggleStyle(.switch).labelsHidden()
            }
            if sync.displays.count > 1 {
                Picker("Display", selection: $sync.displayID) {
                    ForEach(sync.displays, id: \.displayID) { d in
                        Text(d.displayID == CGMainDisplayID() ? "Main display (\(d.width)×\(d.height))" : "Display \(d.width)×\(d.height)").tag(d.displayID)
                    }
                }
                .onChange(of: sync.displayID) { _, _ in sync.restartIfRunning() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen palette").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                GeometryReader { g in
                    let total = max(sync.palette.reduce(0) { $0 + $1.share }, 0.0001)
                    HStack(spacing: 1.5) {
                        ForEach(sync.palette) { s in
                            Rectangle().fill(s.color).frame(width: max(3, (g.size.width - 15) * s.share / total))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(height: 26)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(sync.palette.sorted { $0.share > $1.share }) { s in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 12, height: 12)
                            Text("\(Int((s.share * 100).rounded()))%").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("On the light").font(.system(size: 11)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 5).fill(sync.nowShowing).frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
                }
            }
            .opacity(sync.running ? 1 : 0.25)
            Picker("", selection: $sync.style) {
                ForEach(ScreenSync.Style.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if sync.style == .flow {
            HStack {
                Text("Pace").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Text("Fast").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: $sync.cycleSeconds, in: 4...40)
                Text("Slow").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            }
            HStack {
                Text("Fades").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Text("Crisp").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: $sync.smoothing, in: 0...1)
                Text("Soft").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if sync.style == .main {
                HStack {
                    Text("Colour beats black at").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $sync.prominence, in: 0.02...0.4)
                    Text("\(Int((sync.prominence * 100).rounded()))% of screen").font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                }
            }
            Text(sync.style == .main ? "The light shows the colour covering the most of your screen, refreshed 30 times a second. Reads a tiny 96×54 copy; nothing is saved or sent anywhere." : "The light flows through all ten colours, each for a time in proportion to its share of the screen. Reads a tiny 96×54 copy; nothing is saved or sent anywhere.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = sync.error {
                HStack(alignment: .top) {
                    Text(e).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if sync.needsPermission {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }.controlSize(.small)
                    }
                }
            }
            if sync.running {
                Text(sync.frames == 0 ? "Waiting for the first frame… (if this stays at 0, capture is blocked)" : "frames: \(sync.frames.formatted())")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(sync.frames == 0 ? .orange : .secondary)
            }
        }
        .task { await sync.refreshDisplays() }
    }
}

struct PreviewTile: View {
    @ObservedObject var light: Light
    @ObservedObject var c: Controls
    @ObservedObject var sync: ScreenSync
    @ObservedObject var fx: Effects
    var body: some View {
        RoundedRectangle(cornerRadius: 10).fill(previewColor).frame(width: 40, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
            .shadow(color: previewColor.opacity(light.isOn ? 0.6 : 0), radius: 10)
    }
    private var previewColor: Color {
        switch c.mode {
        case .colour: return Color(hue: c.hue, saturation: c.saturation, brightness: 1)
        case .white: let v = kelvinToRGB(c.kelvin); return Color(red: v.0 / 255, green: v.1 / 255, blue: v.2 / 255)
        case .sync: return sync.nowShowing
        case .effects:
            if fx.active == .spectrum { return fx.nowShowing }
            return fx.active == nil ? .gray : Color(hue: 0.83, saturation: 0.6, brightness: 1)
        }
    }
}
