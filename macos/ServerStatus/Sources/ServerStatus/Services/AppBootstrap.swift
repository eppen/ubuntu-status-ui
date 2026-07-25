import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum AppBootstrap {
    static func configure() {
        #if os(macOS)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        #endif
    }

    static func focusKeyWindow() {
        #if os(macOS)
        DispatchQueue.main.async {
            let app = NSApplication.shared
            app.activate(ignoringOtherApps: true)
            if let sheet = app.windows.first(where: { $0.isSheet && $0.isVisible }) {
                sheet.makeKeyAndOrderFront(nil)
            } else {
                app.keyWindow?.makeKeyAndOrderFront(nil)
                app.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
            }
        }
        #endif
    }
}
