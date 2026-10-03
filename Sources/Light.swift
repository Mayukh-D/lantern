import CoreBluetooth
import SwiftUI

/// A MELK / ELK-BLEDOM Bluetooth light (the kind the Magic Lantern app drives).
/// Protocol: service FFF0, write characteristic FFF3, 9-byte frames 7E … EF.
final class Light: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Searching…"
    @Published var name = "Light"
    @Published var connected = false
    @Published var isOn = true
    @Published var brightness: Double = 100

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var lastRGB: (UInt8, UInt8, UInt8)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: calibration (screen colour -> what the LEDs need), saved between launches
    @Published var saturation: Double = UserDefaults.standard.object(forKey: "cal2.sat") as? Double ?? 1.0 { didSet { save() } }
    @Published var gamma: Double = UserDefaults.standard.object(forKey: "cal2.gamma") as? Double ?? 3.5 { didSet { save() } }
    @Published var gainR: Double = UserDefaults.standard.object(forKey: "cal2.r") as? Double ?? 1 { didSet { save() } }
    @Published var gainG: Double = UserDefaults.standard.object(forKey: "cal2.g") as? Double ?? 0.85 { didSet { save() } }
    @Published var gainB: Double = UserDefaults.standard.object(forKey: "cal2.b") as? Double ?? 0.45 { didSet { save() } }
    private func save() {
        let d = UserDefaults.standard
        d.set(saturation, forKey: "cal2.sat"); d.set(gamma, forKey: "cal2.gamma")
        d.set(gainR, forKey: "cal2.r"); d.set(gainG, forKey: "cal2.g"); d.set(gainB, forKey: "cal2.b")
        lastRGB = nil
    }
    // tuned by eye on the MELK-OA10 bar, 2026-10-04
    func resetCalibration() { saturation = 1.0; gamma = 3.5; gainR = 1; gainG = 0.85; gainB = 0.45 }

    /// Screen colours look pastel on LEDs: push saturation up, then apply gamma so the weaker
    /// channels drop away, then per-channel balance.
    func calibrated(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let n = NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        n.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let s2 = 1 - pow(1 - Double(s), saturation)              // 1 = unchanged, higher = more vivid
        let m = NSColor(hue: h, saturation: CGFloat(s2), brightness: v, alpha: 1)
        let lin = { (x: CGFloat) in pow(Double(x), self.gamma) }
        var c = (lin(m.redComponent) * gainR, lin(m.greenComponent) * gainG, lin(m.blueComponent) * gainB)
        // gamma also dims; restore the original brightness so only the purity changes
        let peak = max(c.0, c.1, c.2), want = Double(v)
        if peak > 0 { let k = want / peak; c = (c.0 * k, c.1 * k, c.2 * k) }
        return (c.0 * 255, c.1 * 255, c.2 * 255)
    }

    // MARK: commands
    /// A colour from the screen or the colour wheel: goes through calibration.
    func setColor(r: Double, g: Double, b: Double) {
        let c = calibrated(r, g, b); setRaw(r: c.0, g: c.1, b: c.2)
    }
    /// Exact LED values (whites use their own tuned table).
    func setRaw(r: Double, g: Double, b: Double) {
        let c = (UInt8(max(0, min(255, r))), UInt8(max(0, min(255, g))), UInt8(max(0, min(255, b))))
        if let l = lastRGB, l == c { return }
        lastRGB = c
        send([0x7E, 0x07, 0x05, 0x03, c.0, c.1, c.2, 0x10, 0xEF])
    }
    /// A pattern built into the bar's controller (0x01 rainbow one way, 0x02 the other).
    func setEffect(_ code: UInt8) {
        lastRGB = nil
        send([0x7E, 0x00, 0x03, code, 0x03, 0x00, 0x00, 0x00, 0xEF])
    }
    /// Speed for built-in effects, 0...100.
    func setEffectSpeed(_ v: Double) {
        send([0x7E, 0x00, 0x02, UInt8(max(0, min(100, v))), 0x00, 0x00, 0x00, 0x00, 0xEF])
    }
    func setPower(_ on: Bool) {
        isOn = on
        send(on ? [0x7E, 0x04, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]
                : [0x7E, 0x04, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF])
    }
    func setBrightness(_ v: Double) {
        brightness = v
        send([0x7E, 0x04, 0x01, UInt8(max(1, min(100, v))), 0xFF, 0xFF, 0xFF, 0x00, 0xEF])
    }
    // Writes without response are dropped silently when the light's buffer is full, so a fast
    // colour stream holds the newest frame until the light says it is ready for more.
    private var pending: [UInt8]?
    private(set) var sent = 0, deferred = 0
    private func send(_ bytes: [UInt8]) {
        guard let p = peripheral, let w = writer else { return }
        if p.canSendWriteWithoutResponse {
            p.writeValue(Data(bytes), for: w, type: .withoutResponse); sent += 1
        } else {
            pending = bytes; deferred += 1
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if let b = pending, let w = writer { pending = nil; p.writeValue(Data(b), for: w, type: .withoutResponse); sent += 1 }
    }

    // MARK: Bluetooth
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: scan()
        case .unauthorized: status = "Allow Bluetooth in System Settings"
        case .poweredOff: status = "Bluetooth is off"
        default: status = "Bluetooth unavailable"
        }
    }
    private func scan() {
        status = "Searching…"
        central.scanForPeripherals(withServices: nil)
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData a: [String: Any], rssi: NSNumber) {
        let n = (p.name ?? (a[CBAdvertisementDataLocalNameKey] as? String) ?? "")
        guard n.hasPrefix("MELK") || n.hasPrefix("ELK-") else { return }
        c.stopScan()
        name = n.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? n
        status = "Connecting…"
        peripheral = p
        p.delegate = self
        c.connect(p)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([CBUUID(string: "FFF0")])
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Couldn't connect. Is the phone app using it?"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.scan() }
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected = false; writer = nil; lastRGB = nil
        status = "Reconnecting…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.scan() }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics([CBUUID(string: "FFF3")], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let w = s.characteristics?.first(where: { $0.uuid == CBUUID(string: "FFF3") }) else { return }
        writer = w; connected = true; status = "Connected"
        setPower(true)
    }
}
