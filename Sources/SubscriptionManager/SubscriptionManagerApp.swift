import AppKit
import SwiftUI

struct SubscriptionManagerApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPopoverView(store: store)
        } label: {
            Image(nsImage: menuBarIcon)
                .accessibilityLabel("Subscription Manager")
        }
        .menuBarExtraStyle(.window)
    }

    /// The white Codex logo as a template image, so macOS draws it white on
    /// a dark menu bar and black on a light one.
    private var menuBarIcon: NSImage {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Assets/codex-mono-light.png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Subscription Manager") ?? NSImage()
    }
}

@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CommandLineTool.shouldHandle(arguments) {
            exit(CommandLineTool.run(arguments))
        }
        SubscriptionManagerApp.main()
    }
}
