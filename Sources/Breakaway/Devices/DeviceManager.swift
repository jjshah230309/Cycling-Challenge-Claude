import BreakawayCore
import CoreBluetooth
import Foundation

enum DeviceRole: String, CaseIterable, Identifiable, Codable {
    case trainer, powerMeter, heartRate, cadence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trainer: return "Smart Trainer"
        case .powerMeter: return "Power Meter"
        case .heartRate: return "Heart Rate"
        case .cadence: return "Cadence"
        }
    }

    var symbol: String {
        switch self {
        case .trainer: return "bicycle"
        case .powerMeter: return "bolt.fill"
        case .heartRate: return "heart.fill"
        case .cadence: return "arrow.triangle.2.circlepath"
        }
    }

    var services: [CBUUID] {
        switch self {
        case .trainer: return [CBUUID(string: GATT.fitnessMachineService), CBUUID(string: GATT.cyclingPowerService)]
        case .powerMeter: return [CBUUID(string: GATT.cyclingPowerService)]
        case .heartRate: return [CBUUID(string: GATT.heartRateService)]
        case .cadence: return [CBUUID(string: GATT.cyclingSpeedCadenceService), CBUUID(string: GATT.cyclingPowerService)]
        }
    }
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var roles: Set<DeviceRole>
    let peripheral: CBPeripheral
}

enum ConnectionState: String {
    case disconnected = "Disconnected", connecting = "Connecting…", connected = "Connected", ready = "Ready"
}

struct PairedDevice {
    var id: UUID
    var name: String
    var state: ConnectionState
    var battery: Int?
}

/// Latest values from sensors, each with the time it arrived.
struct LiveMetrics {
    var trainerPower: Double?
    var trainerCadence: Double?
    var trainerSpeedKmh: Double?
    var trainerUpdated: Date?
    var meterPower: Double?
    var meterCadence: Double?
    var meterUpdated: Date?
    var heartRate: Double?
    var heartRateUpdated: Date?
    var sensorCadence: Double?
    var sensorUpdated: Date?
}

/// CoreBluetooth central for smart trainers (FTMS), power meters (CPS),
/// heart-rate monitors (HRS) and cadence sensors (CSC). Sends ERG targets and
/// gradient simulation through the FTMS control point.
final class DeviceManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var paired: [DeviceRole: PairedDevice] = [:]
    @Published private(set) var live = LiveMetrics()
    @Published private(set) var controlGranted = false
    @Published private(set) var lastCommand: String = ""

    /// Keyboard / slider driven power for riding without hardware.
    @Published var virtualPowerEnabled: Bool { didSet { UserDefaults.standard.set(virtualPowerEnabled, forKey: "virtualPowerEnabled") } }
    @Published var virtualPower: Double = 200
    @Published var preferPowerMeter: Bool { didSet { UserDefaults.standard.set(preferPowerMeter, forKey: "preferPowerMeter") } }

    private var central: CBCentralManager!
    private var peripherals: [DeviceRole: CBPeripheral] = [:]
    private var controlPoint: CBCharacteristic?
    private var crankCalc = CadenceCalculator()
    private var cscCalc = CadenceCalculator()
    private var lastSent: TrainerTarget = .none
    private var lastSentAt = Date.distantPast
    private var reconnectWork: [UUID: DispatchWorkItem] = [:]

    override init() {
        virtualPowerEnabled = UserDefaults.standard.object(forKey: "virtualPowerEnabled") as? Bool ?? true
        preferPowerMeter = UserDefaults.standard.object(forKey: "preferPowerMeter") as? Bool ?? true
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    var isBluetoothReady: Bool { bluetoothState == .poweredOn }

    var bluetoothStatusText: String {
        switch bluetoothState {
        case .poweredOn: return "Bluetooth ready"
        case .poweredOff: return "Bluetooth is turned off"
        case .unauthorized: return "Bluetooth permission denied — enable it in System Settings › Privacy & Security › Bluetooth"
        case .unsupported: return "Bluetooth LE is not supported on this Mac"
        case .resetting: return "Bluetooth is resetting…"
        default: return "Starting Bluetooth…"
        }
    }

    func startScan() {
        guard isBluetoothReady else { return }
        discovered.removeAll()
        let services = Set(DeviceRole.allCases.flatMap(\.services))
        central.scanForPeripherals(withServices: Array(services), options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.stopScan() }
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredDevice, as role: DeviceRole) {
        disconnect(role)
        peripherals[role] = device.peripheral
        device.peripheral.delegate = self
        paired[role] = PairedDevice(id: device.id, name: device.name, state: .connecting, battery: nil)
        UserDefaults.standard.set(device.id.uuidString, forKey: "paired.\(role.rawValue)")
        UserDefaults.standard.set(device.name, forKey: "paired.\(role.rawValue).name")
        if device.peripheral.state == .connected {
            device.peripheral.discoverServices(nil)
        } else {
            central.connect(device.peripheral, options: nil)
        }
        if role == .trainer || role == .powerMeter { virtualPowerEnabled = false }
    }

    func disconnect(_ role: DeviceRole) {
        guard let p = peripherals.removeValue(forKey: role) else { return }
        paired[role] = nil
        UserDefaults.standard.removeObject(forKey: "paired.\(role.rawValue)")
        if role == .trainer {
            controlPoint = nil
            controlGranted = false
        }
        // Keep the link if another role still uses the same peripheral.
        if !peripherals.values.contains(where: { $0 === p }) {
            central.cancelPeripheralConnection(p)
        }
    }

    /// The rider's current power / cadence / HR, merged from the best available source.
    func currentInput(now: Date = Date()) -> PlayerInput {
        func fresh(_ d: Date?, _ limit: TimeInterval = 3) -> Bool { d.map { now.timeIntervalSince($0) < limit } ?? false }
        var power: Double = 0
        var cadence: Double = 0
        if preferPowerMeter, fresh(live.meterUpdated), let p = live.meterPower {
            power = p
        } else if fresh(live.trainerUpdated), let p = live.trainerPower {
            power = p
        } else if fresh(live.meterUpdated), let p = live.meterPower {
            power = p
        } else if virtualPowerEnabled {
            power = virtualPower
        }
        if fresh(live.trainerUpdated), let c = live.trainerCadence, c > 0 {
            cadence = c
        } else if fresh(live.meterUpdated), let c = live.meterCadence, c > 0 {
            cadence = c
        } else if fresh(live.sensorUpdated), let c = live.sensorCadence {
            cadence = c
        } else if virtualPowerEnabled, power > 0 {
            cadence = 88
        }
        let hr = fresh(live.heartRateUpdated, 5) ? live.heartRate : nil
        return PlayerInput(power: power, cadence: cadence, heartRate: hr)
    }

    var hasHardwarePower: Bool {
        let now = Date()
        return [live.trainerUpdated, live.meterUpdated].contains { $0.map { now.timeIntervalSince($0) < 3 } ?? false }
    }

    var canControlTrainer: Bool { controlPoint != nil }

    /// Pushes ERG / simulation targets to the trainer, rate-limited to what trainers handle well.
    func apply(_ target: TrainerTarget) {
        guard let cp = controlPoint, let p = peripherals[.trainer] else { return }
        if !controlGranted {
            if Date().timeIntervalSince(lastSentAt) > 2 {
                write(.requestControl, to: cp, on: p)
                lastSentAt = Date()
            }
            return
        }
        let since = Date().timeIntervalSince(lastSentAt)
        switch target {
        case .none:
            return
        case let .erg(watts):
            if case let .erg(prev) = lastSent, abs(prev - watts) < 1, since < 10 { return }
            guard since >= 0.8 else { return }
            write(.setTargetPower(watts: Int(watts.rounded())), to: cp, on: p)
        case let .simulation(grade, crr, wind, cw):
            if case let .simulation(prevGrade, _, _, _) = lastSent, abs(prevGrade - grade) < 0.1, since < 5 { return }
            guard since >= 1.0 else { return }
            write(.setSimulation(windSpeed: wind, gradePercent: grade, crr: crr, windResistance: cw), to: cp, on: p)
        }
        lastSent = target
        lastSentAt = Date()
    }

    /// Releases ERG so the trainer coasts freely after a ride.
    func resetTrainer() {
        guard let cp = controlPoint, let p = peripherals[.trainer], controlGranted else { return }
        write(.setSimulation(windSpeed: 0, gradePercent: 0, crr: 0.004, windResistance: 0.51), to: cp, on: p)
        lastSent = .none
    }

    private func write(_ command: FTMSCommand, to c: CBCharacteristic, on p: CBPeripheral) {
        p.writeValue(Data(command.bytes), for: c, type: .withResponse)
        switch command {
        case let .setTargetPower(w): lastCommand = "ERG \(w) W"
        case let .setSimulation(_, g, _, _): lastCommand = String(format: "SIM %.1f%%", g)
        case .requestControl: lastCommand = "Requesting control…"
        default: break
        }
    }

    private func roles(of p: CBPeripheral) -> [DeviceRole] {
        peripherals.filter { $0.value === p }.map(\.key)
    }

    private func reconnectSaved() {
        for role in DeviceRole.allCases {
            guard peripherals[role] == nil,
                  let s = UserDefaults.standard.string(forKey: "paired.\(role.rawValue)"),
                  let uuid = UUID(uuidString: s),
                  let p = central.retrievePeripherals(withIdentifiers: [uuid]).first else { continue }
            p.delegate = self
            peripherals[role] = p
            let name = UserDefaults.standard.string(forKey: "paired.\(role.rawValue).name") ?? p.name ?? role.title
            paired[role] = PairedDevice(id: uuid, name: name, state: .connecting, battery: nil)
            central.connect(p, options: nil)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn { reconnectSaved() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        var roles = Set<DeviceRole>()
        if services.contains(CBUUID(string: GATT.fitnessMachineService)) { roles.insert(.trainer) }
        if services.contains(CBUUID(string: GATT.cyclingPowerService)) { roles.formUnion([.powerMeter, .cadence]) }
        if services.contains(CBUUID(string: GATT.heartRateService)) { roles.insert(.heartRate) }
        if services.contains(CBUUID(string: GATT.cyclingSpeedCadenceService)) { roles.insert(.cadence) }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown sensor"
        if let i = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[i].rssi = RSSI.intValue
            discovered[i].roles.formUnion(roles)
        } else {
            discovered.append(DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, roles: roles, peripheral: peripheral))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        for r in roles(of: peripheral) { paired[r]?.state = .connected }
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        scheduleReconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if roles(of: peripheral).contains(.trainer) {
            controlPoint = nil
            controlGranted = false
        }
        scheduleReconnect(peripheral)
    }

    private func scheduleReconnect(_ peripheral: CBPeripheral) {
        let rs = roles(of: peripheral)
        guard !rs.isEmpty else { return }
        for r in rs { paired[r]?.state = .disconnected }
        reconnectWork[peripheral.identifier]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.roles(of: peripheral).isEmpty else { return }
            for r in self.roles(of: peripheral) { self.paired[r]?.state = .connecting }
            self.central.connect(peripheral, options: nil)
        }
        reconnectWork[peripheral.identifier] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let rs = Set(roles(of: peripheral))
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case CBUUID(string: GATT.indoorBikeData) where rs.contains(.trainer):
                peripheral.setNotifyValue(true, for: c)
            case CBUUID(string: GATT.fitnessMachineControlPoint) where rs.contains(.trainer):
                controlPoint = c
                peripheral.setNotifyValue(true, for: c)   // indications carry the responses
            case CBUUID(string: GATT.cyclingPowerMeasurement) where !rs.isDisjoint(with: [.trainer, .powerMeter, .cadence]):
                peripheral.setNotifyValue(true, for: c)
            case CBUUID(string: GATT.heartRateMeasurement) where rs.contains(.heartRate):
                peripheral.setNotifyValue(true, for: c)
            case CBUUID(string: GATT.cscMeasurement) where rs.contains(.cadence):
                peripheral.setNotifyValue(true, for: c)
            case CBUUID(string: GATT.batteryLevel):
                peripheral.readValue(for: c)
            default:
                break
            }
        }
        for r in rs { paired[r]?.state = .ready }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == CBUUID(string: GATT.fitnessMachineControlPoint), characteristic.isNotifying {
            write(.requestControl, to: characteristic, on: peripheral)
            lastSentAt = Date()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let rs = Set(roles(of: peripheral))
        let now = Date()
        switch characteristic.uuid {
        case CBUUID(string: GATT.indoorBikeData):
            guard let d = IndoorBikeData.parse(data) else { return }
            if let p = d.powerWatts { live.trainerPower = max(0, p) }
            if let c = d.cadenceRpm { live.trainerCadence = c }
            if let s = d.speedKmh { live.trainerSpeedKmh = s }
            if let hr = d.heartRate, hr > 0, paired[.heartRate] == nil {
                live.heartRate = hr
                live.heartRateUpdated = now
            }
            live.trainerUpdated = now

        case CBUUID(string: GATT.cyclingPowerMeasurement):
            guard let m = CyclingPowerMeasurement.parse(data) else { return }
            var cadence: Double?
            if let revs = m.crankRevolutions, let t = m.crankEventTime {
                cadence = crankCalc.update(revolutions: revs, eventTime: t, now: now.timeIntervalSinceReferenceDate)
            }
            if rs.contains(.powerMeter) {
                live.meterPower = max(0, m.powerWatts)
                live.meterCadence = cadence
                live.meterUpdated = now
            }
            // Trainers without FTMS bike data report power via CPS only.
            if rs.contains(.trainer), live.trainerUpdated.map({ now.timeIntervalSince($0) > 2 }) ?? true {
                live.trainerPower = max(0, m.powerWatts)
                live.trainerCadence = cadence
                live.trainerUpdated = now
            }
            if rs.contains(.cadence), let cadence {
                live.sensorCadence = cadence
                live.sensorUpdated = now
            }

        case CBUUID(string: GATT.heartRateMeasurement):
            if let hr = HeartRateMeasurement.parse(data) {
                live.heartRate = hr.bpm
                live.heartRateUpdated = now
            }

        case CBUUID(string: GATT.cscMeasurement):
            if let m = CSCMeasurement.parse(data), let revs = m.crankRevolutions, let t = m.crankEventTime {
                live.sensorCadence = cscCalc.update(revolutions: revs, eventTime: t, now: now.timeIntervalSinceReferenceDate)
                live.sensorUpdated = now
            }

        case CBUUID(string: GATT.fitnessMachineControlPoint):
            guard let r = FTMSResponse.parse([UInt8](data)) else { return }
            if r.requestOpcode == FTMSCommand.requestControl.opcode {
                controlGranted = r.result == .success
                lastCommand = controlGranted ? "Trainer control granted" : "Trainer refused control"
                if controlGranted, let cp = controlPoint {
                    write(.startOrResume, to: cp, on: peripheral)
                }
            } else if r.result == .controlNotPermitted {
                controlGranted = false
            }

        case CBUUID(string: GATT.batteryLevel):
            if let level = data.first {
                for r in rs { paired[r]?.battery = Int(level) }
            }

        default:
            break
        }
    }
}
