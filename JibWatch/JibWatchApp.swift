import SwiftUI

@main
struct JibWatchApp: App {
    @State private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchBulbListView()
            }
            .environment(store)
            // The complication opens the app with jib://toggle/<id>; the app relays the toggle.
            .onOpenURL { store.handle($0) }
        }
    }
}
