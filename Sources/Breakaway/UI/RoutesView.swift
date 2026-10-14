import BreakawayCore
import Charts
import MapKit
import SwiftUI

struct RoutesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            List(selection: Binding(get: { model.selectedRouteID }, set: { if let id = $0 { model.selectedRouteID = id } })) {
                ForEach(RouteRecord.Category.allCases, id: \.self) { cat in
                    let recs = model.allRouteRecords.filter { $0.category == cat }
                    if !recs.isEmpty {
                        Section(cat.displayName) {
                            ForEach(recs, id: \.id) { rec in
                                HStack {
                                    Text(rec.flag)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(rec.name).lineLimit(1)
                                        Text(rec.event).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                                    }
                                }
                                .tag(rec.id)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.presentGPXImporter = true
                } label: {
                    Label("Import GPX route…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
                .padding(12)
            }

            if let route = model.selectedRoute {
                RouteDetailView(route: route)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a route").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RouteDetailView: View {
    @EnvironmentObject var model: AppModel
    let route: Route

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(route.record.flag).font(.title)
                            Text(route.record.event.uppercased()).font(.caption.bold()).foregroundStyle(Theme.accent)
                            QualityBadge(quality: route.record.quality)
                        }
                        Text(route.name).font(.system(size: 30, weight: .heavy, design: .rounded))
                        Text(route.record.location).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            model.section = .ride
                        } label: { Label("Ride this route", systemImage: "play.fill") }
                            .buttonStyle(PillButtonStyle())
                        HStack {
                            Button("Export GPX") { model.exportRouteGPX(route) }.buttonStyle(PillButtonStyle(prominent: false))
                            if route.record.category == .imported {
                                Button("Delete") { model.deleteImportedRoute(route) }.buttonStyle(PillButtonStyle(color: .red, prominent: false))
                            }
                        }
                    }
                }
                Text(route.record.summary).fixedSize(horizontal: false, vertical: true)
                RouteStatsRow(route: route)
                if let off = route.record.official {
                    officialComparison(off)
                }

                Card(padding: 0) {
                    RouteMapView(route: route).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Elevation profile").font(.headline)
                        ElevationChart(route: route, units: model.profile.units)
                            .frame(height: 220)
                    }
                }
                if !route.climbs.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Timed climbs").font(.headline)
                            ForEach(route.climbs) { c in
                                ClimbRow(route: route, climb: c)
                            }
                        }
                    }
                }
                if !route.record.surfaces.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cobbled sectors").font(.headline)
                            ForEach(Array(route.record.surfaces.enumerated()), id: \.offset) { _, s in
                                HStack {
                                    Image(systemName: "square.grid.3x3.fill").foregroundStyle(.brown)
                                    Text(s.name)
                                    Spacer()
                                    Text(String(format: "km %.1f – %.1f · %.0f m", s.startMeters / 1000, s.endMeters / 1000, s.endMeters - s.startMeters))
                                        .foregroundStyle(Theme.secondaryText).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                if !route.record.streets.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Roads followed").font(.headline)
                            Text(route.record.streets.joined(separator: " → ")).font(.callout).foregroundStyle(Theme.secondaryText)
                            Text("Road geometry © OpenStreetMap contributors (ODbL). Elevation: Copernicus EU-DEM / NASA SRTM.")
                                .font(.caption2).foregroundStyle(Theme.secondaryText.opacity(0.7))
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func officialComparison(_ off: RouteRecord.OfficialStats) -> some View {
        var parts: [String] = []
        if let km = off.distanceKm { parts.append(String(format: "%.1f km", km)) }
        if let m = off.elevationGainM { parts.append("\(Int(m)) m climbing") }
        if let g = off.averageGradePercent { parts.append(String(format: "%.1f%% average", g)) }
        let text = "Race-book figures: \(parts.joined(separator: " · ")) — this route: \(String(format: "%.2f km", route.length / 1000))"
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.seal").foregroundStyle(Theme.good)
            Text(text).font(.callout).foregroundStyle(Theme.secondaryText)
        }
    }
}

struct ClimbRow: View {
    @EnvironmentObject var model: AppModel
    let route: Route
    let climb: Climb

    var body: some View {
        HStack(spacing: 14) {
            Text(climb.category.label)
                .font(.system(size: 11, weight: .heavy))
                .frame(width: 48)
                .padding(.vertical, 4)
                .background(climb.category <= .cat2 ? Theme.kom : Theme.panelRaised, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(climb.name).font(.headline)
                Text(String(format: "km %.1f · %.1f km at %.1f%% · max %.0f%% · %d → %d m", climb.startDistance / 1000, climb.length / 1000,
                            climb.averageGrade * 100, climb.maxGrade * 100, Int(climb.startElevation), Int(climb.topElevation)))
                    .font(.caption).foregroundStyle(Theme.secondaryText).monospacedDigit()
            }
            Spacer()
            if let pb = model.personalBest(routeID: route.id, climb: climb.name) {
                VStack(alignment: .trailing) {
                    Text("PB").font(.caption2.bold()).foregroundStyle(Theme.secondaryText)
                    Text(Units.clock(pb)).font(.system(.body, design: .rounded).bold()).foregroundStyle(Theme.good).monospacedDigit()
                }
            }
        }
    }
}

struct ElevationChart: View {
    let route: Route
    let units: UnitSystem

    struct Point: Identifiable {
        let id: Int
        let km: Double
        let elevation: Double
        let grade: Double
    }

    var body: some View {
        let pts = route.profile(samples: 240).enumerated().map { i, p in
            Point(id: i, km: Units.distance(p.distance, units).value, elevation: Units.elevation(p.elevation, units).value,
                  grade: route.grade(at: p.distance))
        }
        let lo = (pts.map(\.elevation).min() ?? 0)
        let hi = (pts.map(\.elevation).max() ?? 1)
        Chart {
            ForEach(route.climbs) { c in
                RectangleMark(xStart: .value("Start", Units.distance(c.startDistance, units).value),
                              xEnd: .value("End", Units.distance(c.endDistance, units).value))
                    .foregroundStyle(Theme.kom.opacity(0.10))
            }
            ForEach(pts) { p in
                AreaMark(x: .value("Distance", p.km), yStart: .value("Base", lo - (hi - lo) * 0.05), yEnd: .value("Elevation", p.elevation))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Distance", p.km), y: .value("Elevation", p.elevation))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartYScale(domain: (lo - (hi - lo) * 0.05)...(hi + (hi - lo) * 0.08 + 1))
        .chartXAxisLabel(Units.distance(0, units).unit)
        .chartYAxisLabel(Units.elevation(0, units).unit)
    }
}

/// Apple Maps view of the real route.
struct RouteMapView: NSViewRepresentable {
    let route: Route

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .hybridFlyover
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        guard context.coordinator.routeID != route.id else { return }
        context.coordinator.routeID = route.id
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        var coords = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let line = MKPolyline(coordinates: &coords, count: coords.count)
        map.addOverlay(line)
        if let first = coords.first {
            let a = MKPointAnnotation()
            a.coordinate = first
            a.title = route.isLoop ? "Start / Finish" : "Start"
            map.addAnnotation(a)
        }
        if !route.isLoop, let last = coords.last {
            let a = MKPointAnnotation()
            a.coordinate = last
            a.title = "Finish"
            map.addAnnotation(a)
        }
        map.setVisibleMapRect(line.boundingMapRect, edgePadding: NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30), animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var routeID: String?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = NSColor(srgbRed: 1, green: 0.42, blue: 0.1, alpha: 1)
            r.lineWidth = 4
            return r
        }
    }
}
