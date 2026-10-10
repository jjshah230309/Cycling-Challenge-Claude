import BreakawayCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            if let ride = model.activeRide {
                RideView(controller: ride)
                    .transition(.opacity)
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .panelBackground()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.activeRide != nil)
        .fileImporter(isPresented: $model.presentGPXImporter, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
            if case let .success(url) = result { model.importGPX(from: url) }
        }
        .background(EmptyView().fileImporter(isPresented: $model.presentZWOImporter,
                                             allowedContentTypes: [UTType(filenameExtension: "zwo") ?? .xml, .xml]) { result in
            if case let .success(url) = result { model.importZWO(from: url) }
        })
        .alert("Breakaway", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .ride: RideSetupView()
        case .routes: RoutesView()
        case .workouts: WorkoutsView()
        case .garage: GarageView()
        case .devices: DevicesView()
        case .profile: ProfileView()
        case .history: HistoryView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bicycle.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                Text("BREAKAWAY").font(.system(size: 18, weight: .black, design: .rounded)).tracking(1.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 18)

            List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
                ForEach(SidebarSection.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.profile.name).font(.headline)
                    Spacer()
                    Text("Lv \(model.profile.level)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                }
                ProgressView(value: model.profile.levelProgress).tint(Theme.accent)
                HStack(spacing: 6) {
                    ForEach(DeviceRole.allCases) { role in
                        Image(systemName: role.symbol)
                            .foregroundStyle(devices.paired[role]?.state == .ready ? Theme.good : Color.white.opacity(0.25))
                            .help("\(role.title): \(devices.paired[role]?.name ?? "not paired")")
                    }
                    Spacer()
                    if devices.virtualPowerEnabled {
                        Text("Virtual power").font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
                .font(.caption)
            }
            .padding(16)
        }
    }
}
