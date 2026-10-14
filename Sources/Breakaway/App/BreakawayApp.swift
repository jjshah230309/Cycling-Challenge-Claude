import AppKit
import BreakawayCore
import SwiftUI

@main
struct BreakawayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // `Breakaway --snapshot <dir> [routes]` renders the 3D world headlessly and exits.
        if CommandLine.arguments.contains("--snapshot"), #available(macOS 14.0, *) {
            MainActor.assumeIsolated { SnapshotTool.runIfRequested() }
        }
    }

    var body: some Scene {
        WindowGroup("Breakaway") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.devices)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Ride") {
                Button("Start Ride") { model.startRide() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.activeRide != nil)
                Button("End Ride") { model.activeRide?.finish() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.activeRide == nil)
                Divider()
                Button("Import GPX Route…") { model.presentGPXImporter = true }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Import Zwift Workout (.zwo)…") { model.presentZWOImporter = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.devices)
                .frame(width: 520, height: 420)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
