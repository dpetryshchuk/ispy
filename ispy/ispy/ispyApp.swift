import SwiftUI

@main
struct ispyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Color(hue: 0.72, saturation: 0.5, brightness: 0.95))
        }
    }
}
