import SwiftUI

/// Sweeps the local subnet for bulbs and lets the user add them with one tap.
struct DiscoveryView: View {
    @Environment(BulbStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var prefix = BulbDiscovery.localSubnetPrefix() ?? ""
    @State private var found: [DiscoveredBulb] = []
    @State private var scanned = 0
    @State private var scanning = false
    @State private var scanTask: Task<Void, Never>?

    private var prefixIsValid: Bool { BulbDiscovery.isValidPrefix(prefix) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("192.168.1", text: $prefix)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                        Text(".1–254").foregroundStyle(.secondary)
                    }
                    Button(scanning ? "Stop" : (scanned > 0 ? "Scan Again" : "Scan")) {
                        scanning ? stop() : start()
                    }
                    .disabled(!prefixIsValid)
                    if scanning || scanned > 0 {
                        ProgressView(value: Double(scanned), total: Double(BulbDiscovery.hostCount)) {
                            Text(scanning ? "Scanning \(prefix).\(min(scanned + 1, 254))…" : "Scanned \(scanned) addresses")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Subnet")
                } footer: {
                    Text("Jib probes every address on this subnet for a compatible bulb. If iOS asks for Local Network access, allow it and scan again.")
                }

                Section("Found") {
                    if found.isEmpty {
                        Text(scanning ? "Looking…" : "No bulbs found yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(found) { device in
                        HStack(spacing: 12) {
                            BulbGlyph(state: device.info.state, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.info.alias.isEmpty ? device.host : device.info.alias)
                                    .font(.headline)
                                Text("\(device.info.model) · \(device.host)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.hasBulb(host: device.host) {
                                Label("Added", systemImage: "checkmark")
                                    .labelStyle(.titleAndIcon)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Add") {
                                    let name = device.info.alias.isEmpty ? device.host : device.info.alias
                                    store.add(Bulb(name: name, host: device.host))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { if prefixIsValid { start() } }
            .onDisappear { stop() }
        }
    }

    private func start() {
        stop()
        found = []
        scanned = 0
        scanning = true
        let subnet = prefix
        scanTask = Task {
            for await event in BulbDiscovery.scan(prefix: subnet) {
                switch event {
                case .progress(let count, _):
                    scanned = count
                case .found(let device):
                    found.append(device)
                    found.sort { $0.lastOctet < $1.lastOctet }
                }
            }
            scanning = false
        }
    }

    private func stop() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }
}
