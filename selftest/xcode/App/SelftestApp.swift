import Kit
import SwiftUI

@main
struct SelftestApp: App {
    var body: some Scene {
        WindowGroup {
            Text(Greeting.text(for: "selftest"))
        }
    }
}
