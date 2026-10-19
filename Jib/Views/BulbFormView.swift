import SwiftUI

/// Add a bulb by address, or edit an existing one.
struct BulbFormView: View {
    enum Mode {
        case add
        case edit(Bulb)
    }

    @Environment(BulbStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var name = ""
    @State private var host = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var confirmingRemove = false

    private var isAdd: Bool { if case .add = mode { return true } else { return false } }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("IP address", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Find the address in your router’s client list or the bulb’s own app. Give the bulb a fixed address in your router so it doesn’t change.")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(trimmedHost.isEmpty || testing)

                    if let testMessage {
                        Label(testMessage, systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(testSucceeded ? Color.green : Color.red)
                    }
                }

                if case .edit = mode {
                    Section {
                        Button("Remove Bulb", role: .destructive) { confirmingRemove = true }
                    }
                }
            }
            .navigationTitle(isAdd ? "Add Bulb" : "Edit Bulb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdd ? "Add" : "Save") { save() }
                        .disabled(trimmedHost.isEmpty)
                }
            }
            .confirmationDialog("Remove this bulb from Jib?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if case .edit(let bulb) = mode { store.remove(bulb) }
                    dismiss()
                }
            }
            .onAppear {
                if case .edit(let bulb) = mode {
                    name = bulb.name
                    host = bulb.host
                }
            }
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let info = try await BulbCommands.sysInfo(host: trimmedHost)
            testSucceeded = true
            testMessage = "Found “\(info.alias)” (\(info.model))"
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = info.alias }
        } catch {
            testSucceeded = false
            testMessage = error.localizedDescription
        }
    }

    private func save() {
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedHost : name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .add:
            store.add(Bulb(name: finalName, host: trimmedHost))
        case .edit(var bulb):
            bulb.name = finalName
            bulb.host = trimmedHost
            store.update(bulb)
        }
        dismiss()
    }
}
