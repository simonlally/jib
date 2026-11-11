import SwiftUI

struct BulbListView: View {
    @Environment(BulbStore.self) private var store
    @State private var isAdding = false
    @State private var isScanning = false
    @State private var selection: Bulb.ID?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Width of the list pane when it sits beside the detail.
    private static let listPaneWidth: CGFloat = 320

    /// Two panes where the window is regular width (an unfolded iPhone Duo, an iPad, a large
    /// iPhone in landscape), one push stack elsewhere. `NavigationSplitView` isn't used because
    /// at the Duo's 669 pt inner width it hides the list in an overlay rather than tiling.
    /// `selection` drives both layouts, so folding or unfolding keeps the open bulb.
    var body: some View {
        Group {
            if sizeClass == .regular {
                // The list goes on the trailing side, so its power toggles are under the thumb.
                HStack(spacing: 0) {
                    NavigationStack {
                        if let selection {
                            BulbDetailView(bulbID: selection)
                        } else {
                            ContentUnavailableView("Select a Bulb", systemImage: "lightbulb")
                        }
                    }
                    .id(selection)
                    Divider().ignoresSafeArea()
                    NavigationStack { listPane }
                        .frame(width: Self.listPaneWidth)
                }
            } else {
                NavigationStack(path: Binding(
                    get: { selection.map { [$0] } ?? [] },
                    set: { selection = $0.last }
                )) {
                    listPane
                        .navigationDestination(for: Bulb.ID.self) { BulbDetailView(bulbID: $0) }
                }
            }
        }
        .task { await store.refreshAll() }
        .sheet(isPresented: $isAdding) { BulbFormView(mode: .add) }
        .sheet(isPresented: $isScanning) { DiscoveryView() }
        .onChange(of: store.bulbs.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private var listPane: some View {
        Group {
            if store.bulbs.isEmpty { emptyState } else { list }
        }
        .navigationTitle("Jib")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !store.bulbs.isEmpty { EditButton() }
            }
            .prefersVerticalBar()
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { isScanning = true } label: { Label("Scan Network", systemImage: "wifi.router") }
                    Button { isAdding = true } label: { Label("Add by Address", systemImage: "keyboard") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable { await store.refreshAll() }
    }

    private var list: some View {
        let sideBySide = sizeClass == .regular
        return List {
            ForEach(store.bulbs) { bulb in
                BulbRow(bulb: bulb, showsChevron: !sideBySide) { selection = bulb.id }
                    .listRowBackground(sideBySide && selection == bulb.id ? Color.accentColor.opacity(0.18) : nil)
            }
            .onDelete { store.remove(atOffsets: $0) }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Bulbs Yet", systemImage: "lightbulb.slash")
        } description: {
            Text("Jib controls your smart bulbs directly over Wi‑Fi. Scan your network to find them, or add one by IP address.")
        } actions: {
            Button("Scan Network") { isScanning = true }
                .buttonStyle(.borderedProminent)
            Button("Add by Address") { isAdding = true }
        }
    }
}

struct BulbRow: View {
    @Environment(BulbStore.self) private var store
    let bulb: Bulb
    let showsChevron: Bool
    let open: () -> Void

    /// Tapping the row opens the bulb. The row isn't a `NavigationLink` because a control nested
    /// in a link's label doesn't receive taps, so the chevron is drawn by hand where rows push.
    var body: some View {
        let info = store.infos[bulb.id]
        let error = store.errors[bulb.id]
        HStack(spacing: 14) {
            BulbGlyph(state: info?.state, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(bulb.name).font(.headline).lineLimit(1)
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
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
    }
}

extension ToolbarContent {
    /// Puts the item in the vertical bar where the system shows one (the folded iPhone Duo's outer
    /// display). Icon buttons go there by themselves; text buttons such as Edit stay beside the
    /// title unless asked, which splits a screen's actions between two bars.
    @ToolbarContentBuilder
    func prefersVerticalBar() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            axisBehavior(.verticalPreferred)
        } else {
            self
        }
    }
}
