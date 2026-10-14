import BreakawayCore
import SwiftUI

struct WorkoutsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionHeader(title: "Workouts", subtitle: "Structured training with ERG control. Import any Zwift .zwo file.")
                    Button {
                        model.presentZWOImporter = true
                    } label: { Label("Import .zwo", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
                ForEach(WorkoutCategory.allCases, id: \.self) { cat in
                    let items = model.allWorkouts.filter { $0.category == cat }
                    if !items.isEmpty {
                        Text(cat.displayName.uppercased()).font(.caption.bold()).foregroundStyle(Theme.secondaryText).padding(.top, 6)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                            ForEach(items) { w in WorkoutCard(workout: w) }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct WorkoutCard: View {
    @EnvironmentObject var model: AppModel
    let workout: Workout

    var body: some View {
        let selected = model.selectedWorkoutID == workout.id
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(workout.name).font(.headline)
                Spacer()
                Text("\(Int(workout.duration / 60)) min").font(.caption.bold()).foregroundStyle(Theme.secondaryText)
            }
            WorkoutBlocks(workout: workout, ftp: model.profile.ftp).frame(height: 56)
            Text(workout.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
            HStack {
                Text("TSS ≈ \(Int(workout.estimatedTSS.rounded()))").font(.caption.bold())
                Text("Peak \(Int(workout.maxPower * model.profile.ftp)) W").font(.caption).foregroundStyle(Theme.secondaryText)
                Spacer()
                Menu {
                    Button("Export .zwo") { model.exportWorkout(workout) }
                    if workout.category == .custom {
                        Button("Delete", role: .destructive) { model.deleteImportedWorkout(workout) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                Button(selected ? "Selected" : "Ride it") {
                    model.selectedWorkoutID = workout.id
                    model.mode = .workout
                    model.section = .ride
                }
                .buttonStyle(PillButtonStyle(prominent: !selected))
            }
        }
        .padding(14)
        .background(selected ? Theme.accentSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent : Theme.stroke))
    }
}

/// Zone-coloured block chart of a workout, optionally with a progress cursor.
struct WorkoutBlocks: View {
    let workout: Workout
    let ftp: Double
    var elapsed: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let total = max(workout.duration, 1)
            let top = max(1.3, workout.maxPower * 1.05)
            for s in workout.segments {
                let x0 = s.start / total * size.width, x1 = s.end / total * size.width
                if let a = s.startPower, let b = s.endPower {
                    var p = Path()
                    p.move(to: CGPoint(x: x0, y: size.height))
                    p.addLine(to: CGPoint(x: x0, y: size.height * (1 - a / top)))
                    p.addLine(to: CGPoint(x: x1, y: size.height * (1 - b / top)))
                    p.addLine(to: CGPoint(x: x1, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(Theme.zone((a + b) / 2 * ftp, ftp: ftp).opacity(elapsed.map { s.end < $0 ? 0.45 : 0.95 } ?? 0.9)))
                } else {
                    let r = CGRect(x: x0, y: size.height * 0.45, width: x1 - x0, height: size.height * 0.55)
                    ctx.fill(Path(r), with: .color(Color.gray.opacity(0.35)))
                }
            }
            // FTP line.
            let fy = size.height * (1 - 1 / top)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: fy)); p.addLine(to: CGPoint(x: size.width, y: fy)) },
                       with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let e = elapsed {
                let x = min(e / total, 1) * size.width
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
    }
}
