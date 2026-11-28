import SwiftUI
import AppKit

@main
struct PadRelayReceiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ReceiverModel()

    var body: some Scene {
        WindowGroup("PadRelay") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 760)
        }
        .defaultSize(width: 1120, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
