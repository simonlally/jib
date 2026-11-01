import SwiftUI

struct BulbListView: View {
    @Environment(BulbStore.self) private var store
    @State private var isAdding = false
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            Group {
                if store.bulbs.isEmpty { emptyState } else { list }
            }
            .navigationTitle("Jib")
            .navigationDestination(for: Bulb.self) { bulb in
                BulbDetailView(bulbID: bulb.id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.bulbs.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { isScanning = true } label: { Label("Scan Network", systemImage: "wifi.router") }
                        Button { isAdding = true } label: { Label("Add by Address", systemImage: "keyboard") }
                        Button { store.addDemoBulb() } label: { Label("Add Demo Bulb", systemImage: "sparkles") }
                            .disabled(store.hasDemoBulb)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { await store.refreshAll() }
            .task { await store.refreshAll() }
            .sheet(isPresented: $isAdding) { BulbFormView(mode: .add) }
            .sheet(isPresented: $isScanning) { DiscoveryView() }
        }
    }

    private var list: some View {
        List {
            ForEach(store.bulbs) { bulb in
                BulbRow(bulb: bulb)
            }
            .onDelete { store.remove(atOffsets: $0) }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Bulbs Yet", systemImage: "lightbulb.slash")
        } description: {
            Text("Jib controls your smart bulbs directly over Wi‑Fi. Scan your network to find them, or add one by IP address. No bulbs? Try the demo bulb, which runs inside the app.")
        } actions: {
            Button("Scan Network") { isScanning = true }
                .buttonStyle(.borderedProminent)
            Button("Add by Address") { isAdding = true }
            Button("Try a Demo Bulb") { store.addDemoBulb() }
        }
    }
}

struct BulbRow: View {
    @Environment(BulbStore.self) private var store
    let bulb: Bulb

    /// The toggle sits beside, not inside, the navigation link: a control nested in a
    /// `NavigationLink` label doesn't receive taps.
    var body: some View {
        let info = store.infos[bulb.id]
        let error = store.errors[bulb.id]
        HStack(spacing: 14) {
            BulbGlyph(state: info?.state, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bulb.name).font(.headline)
                    if bulb.isDemo { DemoBadge() }
                }
                Text(error ?? info?.state.statusText ?? bulb.host)
                    .font(.subheadline)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.busy.contains(bulb.id) {
                ProgressView().controlSize(.small)
            }
            Toggle("Power", isOn: Binding(
                get: { info?.state.isOn ?? false },
                set: { on in Task { await store.perform(.power(on), on: bulb) } }
            ))
            .labelsHidden()
            .disabled(info == nil && error == nil)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(NavigationLink(value: bulb) { EmptyView() }.opacity(0))
    }
}
