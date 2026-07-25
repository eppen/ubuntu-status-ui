import SwiftUI

@main
struct ServerStatusApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        AppBootstrap.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 640)
                #endif
                .onAppear {
                    AppBootstrap.configure()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
