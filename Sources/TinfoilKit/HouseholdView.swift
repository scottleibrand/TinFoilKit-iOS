import SwiftUI

struct HouseholdView: View {
    @ObservedObject var household: HouseholdStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: String?
    @State private var editing: HouseholdPlace?
    @State private var error: String?

    private var printableSnapshot: HouseholdSnapshot {
        var snapshot = household.snapshot
        if let draft { snapshot.notes = draft }
        return snapshot
    }

    var body: some View {
        NavigationStack {
            Form {
                if let loadError = household.loadError {
                    Section {
                        Label(loadError.localizedDescription, systemImage: "exclamationmark.triangle")
                    } header: { Text("Household data unavailable") }
                }
                Section {
                    TextEditor(text: Binding(
                        get: { draft ?? household.snapshot.notes },
                        set: { draft = $0 }
                    ))
                    .frame(minHeight: 140)
                    .accessibilityLabel("Household notes")
                    .disabled(household.loadError != nil)
                } header: { Text("Notes") }
                Section {
                    if let home = household.snapshot.home {
                        LabeledContent(home.name, value: home.coordinateText)
                        Button("Clear home", role: .destructive) {
                            perform { try household.setHome(nil) }
                        }
                    } else {
                        Text("Set your home from the Map tab.").foregroundStyle(.secondary)
                    }
                } header: { Text("Home") }
                Section {
                    if household.snapshot.pins.isEmpty {
                        Text("Drop a pin from the Map tab.").foregroundStyle(.secondary)
                    }
                    ForEach(household.snapshot.pins) { pin in
                        Button { editing = pin } label: {
                            VStack(alignment: .leading) {
                                Text(pin.name)
                                Text(pin.coordinateText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                perform { try household.removePin(pin.id) }
                            }
                        }
                    }
                } header: { Text("Pins") }
                Section {
                    NavigationLink {
                        HouseholdPrintView(snapshot: printableSnapshot)
                    } label: {
                        Label("Print the essentials", systemImage: "printer")
                    }
                    NavigationLink {
                        HouseholdShareView(snapshot: printableSnapshot)
                    } label: {
                        Label("Share on local network", systemImage: "person.2")
                    }
                }
            }
            .navigationTitle("Household")
            .task(id: draft) {
                guard draft != nil else { return }
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
                saveNotes()
            }
            .onDisappear(perform: saveNotes)
            .onChange(of: scenePhase) {
                if scenePhase != .active { saveNotes() }
            }
            .sheet(item: $editing) { pin in
                HouseholdPinEditor(place: pin, onSave: household.savePin)
            }
            .alert("Household error", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func saveNotes() {
        guard let draft else { return }
        perform {
            try household.saveNotes(draft)
            self.draft = nil
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { self.error = error.localizedDescription }
    }
}

struct HouseholdPinEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var place: HouseholdPlace
    let onSave: (HouseholdPlace) throws -> Void
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $place.name)
                TextField("Note", text: $place.note, axis: .vertical)
                Text(place.coordinateText).foregroundStyle(.secondary)
            }
            .navigationTitle("Map pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        place.name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try onSave(place)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(!place.isValid)
                }
            }
            .alert("Could not save pin", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
}
