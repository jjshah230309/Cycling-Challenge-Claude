import BreakawayCore
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeader(title: "Profile", subtitle: "Weight, height and FTP drive the physics, W/kg, zones and AI rider pace.")
                    Card {
                        Form {
                            TextField("Name", text: $model.profile.name)
                            TextField("Nation (ISO code)", text: $model.profile.nationCode)
                            Picker("Units", selection: $model.profile.units) {
                                Text("Metric").tag(UnitSystem.metric)
                                Text("Imperial").tag(UnitSystem.imperial)
                            }
                            .pickerStyle(.segmented)
                            Stepper(value: $model.profile.weightKg, in: 35...150, step: 0.5) {
                                Text("Weight: \(String(format: "%.1f", model.profile.weightKg)) kg")
                            }
                            Stepper(value: $model.profile.heightCm, in: 140...215, step: 1) {
                                Text("Height: \(Int(model.profile.heightCm)) cm")
                            }
                            Stepper(value: $model.profile.ftp, in: 80...550, step: 5) {
                                Text("FTP: \(Int(model.profile.ftp)) W  (\(String(format: "%.2f", model.profile.wattsPerKg)) W/kg)")
                            }
                            Stepper(value: $model.profile.maxHeartRate, in: 120...225, step: 1) {
                                Text("Max heart rate: \(Int(model.profile.maxHeartRate)) bpm")
                            }
                            Picker("Build", selection: $model.profile.build) {
                                Text("Climber").tag(AvatarBuild.slim)
                                Text("All-rounder").tag(AvatarBuild.regular)
                                Text("Sprinter").tag(AvatarBuild.sprinter)
                            }
                        }
                        .formStyle(.grouped)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kit").font(.headline)
                            HStack {
                                ForEach(Array(Kit.presets.enumerated()), id: \.offset) { _, preset in
                                    Button(preset.name) { model.profile.kit = preset.kit }
                                        .buttonStyle(PillButtonStyle(color: Theme.color(preset.kit.jersey), prominent: false))
                                }
                            }
                            ColorPicker("Jersey", selection: colorBinding(\.kit.jersey))
                            ColorPicker("Jersey accent", selection: colorBinding(\.kit.jerseyAccent))
                            ColorPicker("Shorts", selection: colorBinding(\.kit.shorts))
                            ColorPicker("Helmet", selection: colorBinding(\.kit.helmet))
                            ColorPicker("Skin tone", selection: colorBinding(\.kit.skin))
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Power zones").font(.headline)
                            ForEach(PowerZone.allCases, id: \.self) { z in
                                HStack {
                                    RoundedRectangle(cornerRadius: 3).fill(Theme.color(z.color)).frame(width: 14, height: 14)
                                    Text("Z\(z.rawValue) \(z.name)")
                                    Spacer()
                                    Text(zoneRange(z)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                                }
                            }
                        }
                    }
                }
                .padding(28)
            }
            VStack(spacing: 14) {
                BikePreview(profile: model.profile).frame(maxHeight: .infinity)
                careerCard.padding(16)
            }
            .frame(width: 380)
            .background(Theme.panel.opacity(0.4))
        }
    }

    private var careerCard: some View {
        let u = model.profile.units
        let d = Units.distance(model.profile.totalDistanceMeters, u)
        let e = Units.elevation(model.profile.totalClimbMeters, u)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Level \(model.profile.level)").font(.title2.bold())
                    Spacer()
                    Text("\(model.profile.xp) XP").foregroundStyle(Theme.accent).bold()
                }
                ProgressView(value: model.profile.levelProgress).tint(Theme.accent)
                HStack(spacing: 22) {
                    StatBlock(label: "Ridden", value: String(format: "%.0f", d.value), unit: d.unit)
                    StatBlock(label: "Climbed", value: "\(Int(e.value))", unit: e.unit)
                    StatBlock(label: "Time", value: Units.clock(model.profile.totalRideSeconds))
                }
            }
        }
    }

    private func zoneRange(_ z: PowerZone) -> String {
        let bounds: [Double] = [0, 0.56, 0.76, 0.91, 1.06, 1.21, 1.51]
        let i = z.rawValue - 1
        let lo = Int(bounds[i] * model.profile.ftp)
        if i == 6 { return "\(lo)+ W" }
        return "\(lo)–\(Int(bounds[i + 1] * model.profile.ftp) - 1) W"
    }

    private func colorBinding(_ path: WritableKeyPath<RiderProfile, RGBColor>) -> Binding<Color> {
        Binding(get: { Theme.color(model.profile[keyPath: path]) },
                set: { model.profile[keyPath: path] = RGBColor($0) })
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceManager

    var body: some View {
        Form {
            Section("Rider") {
                Stepper(value: $model.profile.ftp, in: 80...550, step: 5) { Text("FTP: \(Int(model.profile.ftp)) W") }
                Stepper(value: $model.profile.weightKg, in: 35...150, step: 0.5) { Text("Weight: \(String(format: "%.1f", model.profile.weightKg)) kg") }
            }
            Section("Power") {
                Toggle("Virtual power without hardware", isOn: $devices.virtualPowerEnabled)
                Toggle("Prefer power meter", isOn: $devices.preferPowerMeter)
            }
            Section("Data") {
                Button("Reveal data folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Storage.directory]) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
