import SwiftUI

struct WatchBulbListView: View {
    @Environment(WatchStore.self) private var store
    @State private var detailBulb: Bulb?

    var body: some View {
        List {
            if store.bulbs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No bulbs").font(.headline)
                    Text("Add bulbs in Jib on your iPhone. They sync here automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(store.bulbs) { bulb in
                WatchBulbRow(bulb: bulb)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            detailBulb = bulb
                        } label: {
                            Label("Adjust", systemImage: "slider.horizontal.3")
                        }
                        .tint(.orange)
                    }
            }
            if !store.isPhoneReachable {
                Label("iPhone not reachable", systemImage: "iphone.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Jib")
        .navigationDestination(item: $detailBulb) { bulb in
            WatchBulbDetailView(bulbID: bulb.id)
        }
        .task { await store.refreshAll() }
    }
}

struct WatchBulbRow: View {
    @Environment(WatchStore.self) private var store
    let bulb: Bulb

    var body: some View {
        let info = store.infos[bulb.id]
        let error = store.errors[bulb.id]
        Toggle(isOn: Binding(
            get: { info?.state.isOn ?? false },
            set: { on in Task { await store.perform(.power(on), on: bulb) } }
        )) {
            HStack(spacing: 8) {
                BulbGlyph(state: info?.state, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bulb.name).lineLimit(1)
                    Text(error ?? info?.state.statusText ?? "…")
                        .font(.caption2)
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                        .lineLimit(1)
                }
            }
        }
    }
}
