import AppKit
import SwiftUI

@main
struct CodexQuotaApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPopoverView(store: store)
        } label: {
            Image(nsImage: menuBarIcon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .accessibilityLabel("Codex Weekly Quota")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: NSImage {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Assets/codex-mono-dark.png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex Weekly Quota") ?? NSImage()
    }
}
