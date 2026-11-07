import SwiftUI
import AcmeKit
import AcmeCore

@main
struct AcmeApp: App {
    var body: some Scene {
        WindowGroup { Text(AcmeKit.greeting + AcmeCore.version + String(LegacyAnswer())) }
    }
}
