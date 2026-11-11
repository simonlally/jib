import SwiftUI

/// A screen pushed on top of the bulb list.
enum BulbRoute: Hashable {
    case bulb(Bulb.ID)
    case schedule(Bulb.ID)
}

struct BulbListView: View {
    @Environment(BulbStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // Everything the two layouts share lives here, not inside either one: switching layout
    // rebuilds the navigation stacks, and only state held at this level survives that.
    @State private var selection: Bulb.ID?
    @State private var showsSchedule = false
    @State private var editingBulb: Bulb?
    @State private var isAdding = false
    @State private var isScanning = false
    @State private var editMode = EditMode.inactive

    /// Width of the list pane when it sits beside the detail.
    private static let listPaneWidth: CGFloat = 320

    /// Side by side needs room both ways: an unfolded iPhone Duo or an iPad. A large iPhone in
    /// landscape is regular width but compact height, and stays one column so that rotating it
    /// doesn't switch layout.
    private var sideBySide: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    /// Two panes when `sideBySide`, one push stack elsewhere. `NavigationSplitView` isn't used
    /// because at the Duo's 669 pt inner width it hides the list in an overlay rather than tiling.
    /// The `ZStack` gives the sheets and the refresh task one identity across both layouts.
    var body: some View {
        ZStack {
            if sideBySide {
                // The list goes on the trailing side, so its power toggles are under the thumb.
                HStack(spacing: 0) {
                    NavigationStack(path: detailPath) {
                        Group {
                            if let selection {
                                BulbDetailView(bulbID: selection) { editingBulb = $0 }
                            } else {
                                ContentUnavailableView("Select a Bulb", systemImage: "lightbulb")
                            }
                        }
                        .navigationDestination(for: BulbRoute.self, destination: destination)
                    }
                    .id(selection)
                    Divider().ignoresSafeArea()
                    NavigationStack { listPane }
                        .frame(width: Self.listPaneWidth)
                }
            } else {
                NavigationStack(path: fullPath) {
                    listPane
                        .navigationDestination(for: BulbRoute.self, destination: destination)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .task { await store.refreshAll() }
        .sheet(isPresented: $isAdding) { BulbFormView(mode: .add) }
        .sheet(isPresented: $isScanning) { DiscoveryView() }
        .sheet(item: $editingBulb) { BulbFormView(mode: .edit($0)) }
        .onChange(of: store.bulbs.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
                showsSchedule = false
            }
        }
    }

    /// One column: the open bulb and its schedule are both pushed on the list.
    private var fullPath: Binding<[BulbRoute]> {
        Binding {
            guard let selection else { return [] }
            return showsSchedule ? [.bulb(selection), .schedule(selection)] : [.bulb(selection)]
        } set: { path in
            if case .bulb(let id)? = path.first {
                selection = id
                showsSchedule = path.count > 1
            } else {
                selection = nil
                showsSchedule = false
            }
        }
    }

    /// Two panes: the open bulb is the detail pane's root, so only its schedule is pushed.
    private var detailPath: Binding<[BulbRoute]> {
        Binding {
            if let selection, showsSchedule { [.schedule(selection)] } else { [] }
        } set: { path in
            showsSchedule = !path.isEmpty
        }
    }

    @ViewBuilder
    private func destination(_ route: BulbRoute) -> some View {
        switch route {
        case .bulb(let id):
            BulbDetailView(bulbID: id) { editingBulb = $0 }
        case .schedule(let id):
            if let bulb = store.bulb(id: id) {
                ScheduleView(bulb: bulb)
            } else {
                ContentUnavailableView("Bulb Removed", systemImage: "lightbulb.slash")
            }
        }
    }

    /// Opens a bulb at its own screen, leaving any schedule that was showing.
    private func open(_ bulb: Bulb) {
        selection = bulb.id
        showsSchedule = false
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
        List {
            ForEach(store.bulbs) { bulb in
                let isSelected = sideBySide && selection == bulb.id
                BulbRow(bulb: bulb, isSelected: isSelected, showsChevron: !sideBySide) { open(bulb) }
                    .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
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
    @Environment(\.editMode) private var editMode
    let bulb: Bulb
    let isSelected: Bool
    let showsChevron: Bool
    let open: () -> Void

    /// The name half of the row is a button that opens the bulb, and the power toggle sits beside
    /// it as a control of its own. A button, not a `NavigationLink`, because opening a bulb means
    /// different things in the two layouts; the chevron is drawn by hand where rows push.
    var body: some View {
        let info = store.infos[bulb.id]
        let error = store.errors[bulb.id]
        let isEditing = editMode?.wrappedValue.isEditing == true
        HStack(spacing: 14) {
            Button {
                if !isEditing { open() }
            } label: {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // While the list is being edited a tap on a row must not navigate.
            .allowsHitTesting(!isEditing)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if store.busy.contains(bulb.id) {
                ProgressView().controlSize(.small)
            }
            // Hidden while editing: beside the delete badge and drag handle it leaves the name no
            // room in the narrow list pane.
            if !isEditing {
                Toggle("Power", isOn: Binding(
                    get: { info?.state.isOn ?? false },
                    set: { on in Task { await store.perform(.power(on), on: bulb) } }
                ))
                .labelsHidden()
                .disabled(info == nil && error == nil)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }
}

extension ToolbarContent {
    /// Puts a text button in the vertical bar where the system shows one, as it does on the folded
    /// iPhone Duo's outer display. Icon buttons go there by themselves and don't need this; a text
    /// button such as Edit stays beside the title unless asked, which splits a screen's actions
    /// between two bars.
    @ToolbarContentBuilder
    func prefersVerticalBar() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            axisBehavior(.verticalPreferred)
        } else {
            self
        }
    }
}
