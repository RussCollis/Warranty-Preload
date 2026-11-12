import SwiftUI

@main struct PurchaseInformationSyncApp: App {
    var body: some Scene {
        Window("Purchase Information Sync", id: "main") {
            ContentView()
                // The branding pane already shows the app name; hide the title-bar text so it
                // doesn't crowd the traffic lights over the sidebar.
                .toolbar(removing: .title)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
