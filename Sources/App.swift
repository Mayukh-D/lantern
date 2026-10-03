import SwiftUI
import ScreenCaptureKit

@main
struct LanternApp: App {
    private let light: Light
    private let sync: ScreenSync
    private let controls = Controls()
    private let effects = Effects()
    init() {
        light = Light(); sync = ScreenSync(); sync.light = light; effects.light = light
    }
    var body: some Scene {
        MenuBarExtra {
            Panel(light: light, sync: sync)
        } label: {
            MenuIcon(light: light, sync: sync)
        }
        .menuBarExtraStyle(.window)

        Window("Lantern", id: "main") {
            MainWindow(light: light, sync: sync, c: controls, fx: effects)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Calibrate", id: "calibrate") {
            CalibrateView(light: light, sync: sync, fx: effects)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuIcon: View {
    @ObservedObject var light: Light
    @ObservedObject var sync: ScreenSync
    var body: some View {
        Image(systemName: sync.running ? "sparkles" : (light.isOn ? "lightbulb.fill" : "lightbulb"))
    }
}

struct Panel: View {
    @ObservedObject var light: Light
    @ObservedObject var sync: ScreenSync
    @Environment(\.openWindow) private var openWindow
    @State private var picked = Color.white

    private let presets: [(String, Color)] = [
        ("Warm", Color(red: 1, green: 0.78, blue: 0.55)), ("White", .white),
        ("Red", .red), ("Green", .green), ("Blue", .blue), ("Purple", Color(red: 0.6, green: 0.2, blue: 1))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // header
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(light.isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)).frame(width: 34, height: 34)
                    Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb").foregroundStyle(light.isOn ? Color.accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(light.connected ? .green : .orange).frame(width: 6, height: 6)
                        Text(light.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { light.isOn }, set: { light.setPower($0) }))
                    .toggleStyle(.switch).labelsHidden().disabled(!light.connected)
            }

            Divider()

            // colour
            VStack(alignment: .leading, spacing: 8) {
                Label("Colour", systemImage: "paintpalette").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { p in
                        Button { apply(p.1) } label: {
                            Circle().fill(p.1).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                        }.buttonStyle(.plain).help(p.0)
                    }
                    Spacer()
                    ColorPicker("", selection: $picked, supportsOpacity: false).labelsHidden()
                        .onChange(of: picked) { _, c in apply(c) }
                }
                .disabled(sync.running || !light.connected)
                .opacity(sync.running ? 0.4 : 1)
            }

            // brightness
            VStack(alignment: .leading, spacing: 6) {
                Label("Brightness", systemImage: "sun.max").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { light.brightness }, set: { light.setBrightness($0) }), in: 5...100)
                    Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }.disabled(!light.connected)
            }

            Divider()

            // screen sync
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Screen Sync", systemImage: "display").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(get: { sync.running }, set: { _ in sync.toggle() }))
                        .toggleStyle(.switch).labelsHidden().disabled(!light.connected)
                }
                Text("Matches the light to the strongest colour on your screen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                if sync.displays.count > 1 {
                    Picker("Display", selection: $sync.displayID) {
                        ForEach(sync.displays, id: \.displayID) { d in
                            Text(d.displayID == CGMainDisplayID() ? "Built-in / main (\(d.width)×\(d.height))" : "Display \(d.width)×\(d.height)").tag(d.displayID)
                        }
                    }
                    .font(.system(size: 11))
                    .onChange(of: sync.displayID) { _, _ in sync.restartIfRunning() }
                }

                HStack {
                    Text("Snappy").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $sync.smoothing, in: 0...1)
                    Text("Smooth").font(.system(size: 10)).foregroundStyle(.secondary)
                }

                // always takes the same space, so the panel doesn't jump when sync starts
                HStack(spacing: 6) {
                    Text("On the light").font(.system(size: 11)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 5).fill(sync.running ? sync.nowShowing : Color.secondary.opacity(0.15))
                        .frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
                }
                .frame(height: 22)
                if let e = sync.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            HStack {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Lantern…", systemImage: "macwindow").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Spacer()
                Button("Quit") { sync.stop(); NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
        .task { await sync.refreshDisplays() }
    }

    private func apply(_ c: Color) {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return }
        light.setColor(r: n.redComponent * 255, g: n.greenComponent * 255, b: n.blueComponent * 255)
    }
}
