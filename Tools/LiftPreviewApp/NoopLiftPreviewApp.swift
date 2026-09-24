import SwiftUI
import ReceiptLiftFeature

@main
struct NoopLiftPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiptLiftPreviewView(screen: CommandLine.arguments.dropFirst().first ?? "hub")
        }
    }
}
