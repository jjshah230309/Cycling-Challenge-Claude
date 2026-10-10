import BreakawayCore
import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var devices: DeviceManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Devices", subtitle: devices.bluetoothStatusText)
                HStack(spacing: 14) {
                    ForEach(DeviceRole.allCases) { role in PairedCard(role: role) }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Nearby sensors").font(.headline)
                            Spacer()
                            if devices.isScanning { ProgressView().controlSize(.small) }
                            Button(devices.isScanning ? "Stop" : "Scan") {
                                devices.isScanning ? devices.stopScan() : devices.startScan()
                            }
                            .buttonStyle(PillButtonStyle(prominent: !devices.isScanning))
                            .disabled(!devices.isBluetoothReady)
                        }
                        if devices.discovered.isEmpty {
                            Text(devices.isScanning ? "Searching… wake your trainer by pedalling, and put on your heart-rate strap."
                                 : "Press Scan to find FTMS smart trainers (Wahoo KICKR, Tacx NEO, Elite, Saris, JetBlack, Zwift Hub…), power meters, heart-rate straps and cadence sensors.")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(devices.discovered.sorted { $0.rssi > $1.rssi }) { d in
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                VStack(alignment: .leading) {
                                    Text(d.name).font(.headline)
                                    Text("\(d.roles.map(\.title).sorted().joined(separator: ", ")) · \(d.rssi) dBm")
                                        .font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                ForEach(DeviceRole.allCases.filter { d.roles.contains($0) }) { role in
                                    Button("Use as \(role.title)") { devices.connect(d, as: role) }
                                        .buttonStyle(PillButtonStyle(prominent: false))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Power source").font(.headline)
                        Toggle("Prefer the power meter over the trainer's power when both are paired", isOn: $devices.preferPowerMeter)
                        Toggle("Virtual power when no trainer or power meter is sending data", isOn: $devices.virtualPowerEnabled)
                        HStack {
                            Text("Virtual power")
                            Slider(value: $devices.virtualPower, in: 0...600, step: 5)
                            Text("\(Int(devices.virtualPower)) W").monospacedDigit().frame(width: 60)
                        }
                        Text("During a ride: ↑/↓ change virtual power by 10 W (⇧ for 50 W) · E toggles ERG · [ ] trainer difficulty · 1–7 cameras · Space pause · H hides the HUD.")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                if !devices.lastCommand.isEmpty {
                    Text("Trainer: \(devices.lastCommand)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(28)
        }
    }
}

struct PairedCard: View {
    @EnvironmentObject var devices: DeviceManager
    let role: DeviceRole

    var body: some View {
        let paired = devices.paired[role]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: role.symbol).font(.title2)
                    .foregroundStyle(paired?.state == .ready ? Theme.good : Theme.secondaryText)
                Spacer()
                if let b = paired?.battery {
                    Label("\(b)%", systemImage: b > 20 ? "battery.75" : "battery.25").font(.caption)
                }
            }
            Text(role.title.uppercased()).font(.caption.bold()).foregroundStyle(Theme.secondaryText)
            Text(paired?.name ?? "Not paired").font(.headline).lineLimit(1)
            Text(paired?.state.rawValue ?? "—").font(.caption).foregroundStyle(Theme.secondaryText)
            Text(liveValue).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            if paired != nil {
                Button("Forget") { devices.disconnect(role) }.buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
    }

    private var liveValue: String {
        let l = devices.live
        switch role {
        case .trainer:
            return l.trainerPower.map { "\(Int($0)) W" } ?? "— W"
        case .powerMeter:
            return l.meterPower.map { "\(Int($0)) W" } ?? "— W"
        case .heartRate:
            return l.heartRate.map { "\(Int($0)) bpm" } ?? "— bpm"
        case .cadence:
            return (l.sensorCadence ?? l.meterCadence ?? l.trainerCadence).map { "\(Int($0)) rpm" } ?? "— rpm"
        }
    }
}
