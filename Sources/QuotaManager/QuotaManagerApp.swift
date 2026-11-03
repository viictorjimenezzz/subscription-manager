import AppKit
import SwiftUI

struct QuotaManagerApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPopoverView(store: store)
        } label: {
            Image(nsImage: menuBarIcon)
                .accessibilityLabel("Quota Manager")
        }
        .menuBarExtraStyle(.window)
    }

    /// The logo as a template image, so macOS draws it white on a dark menu
    /// bar and black on a light one. `logo-black.png` has the same shape and
    /// can be swapped in if a non-template icon is ever needed.
    private var menuBarIcon: NSImage {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Assets/logo-white.png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Quota Manager") ?? NSImage()
    }
}

@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CommandLineTool.shouldHandle(arguments) {
            exit(CommandLineTool.run(arguments))
        }
        QuotaManagerApp.main()
    }
}
