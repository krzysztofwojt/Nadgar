import SwiftUI

@main
struct WristAssistApp: App {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.start()
                }
        }
    }
}
