import SwiftUI

@main
struct JibApp: App {
    @State private var store: BulbStore

    init() {
        let store = BulbStore()
        _store = State(initialValue: store)
        // Must happen at launch: iOS wakes the app in the background to answer watch messages.
        PhoneSessionManager.shared.activate(store: store)
    }

    var body: some Scene {
        WindowGroup {
            BulbListView()
                .environment(store)
        }
    }
}
