import Foundation
import SwiftUI

struct HouseholdResourcesView: View {
    @ObservedObject var household: HouseholdStore
    @State private var editing: HouseholdResource?
    @State private var error: String?

    private var resources: [HouseholdResource] { household.snapshot.resources ?? [] }

    var body: some View {
        List {
            Section {
                if let shortest = HouseholdResource.shortest(in: resources), let days = shortest.estimatedDays {
                    LabeledContent("Shortest estimate", value: HouseholdResource.formatDays(days))
                    Text(shortest.name)
                } else {
                    Text("No estimates yet").foregroundStyle(.secondary)
                }
                if resources.contains(where: { $0.estimatedDays == nil }) {
                    Text("Some supplies have no estimate. Check their amounts, daily use, and units.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Runway")
            } footer: {
                Text("Estimates cover the supplies you enter, using the quantities and daily use you save. Update amounts as supplies change.")
            }
            Section("Supplies") {
                ForEach(resources) { resource in
                    Button { editing = resource } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(resource.name)
                                Text(resource.category.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(resource.estimatedDays.map(HouseholdResource.formatDays) ?? "Unknown")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            do { try household.removeResource(resource.id) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Button("Add supply", systemImage: "plus") {
                    editing = HouseholdResource(name: "", category: .water, quantity: nil, quantityUnit: .gallons,
                                                dailyUse: nil, dailyUseUnit: .gallons)
                }
                .disabled(resources.count >= HouseholdSnapshot.maxResources)
            }
        }
        .navigationTitle("Supplies and runway")
        .sheet(item: $editing) { resource in
            HouseholdResourceEditor(resource: resource, onSave: household.saveResource)
        }
        .alert("Could not delete supply", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

private struct HouseholdResourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State var resource: HouseholdResource
    let onSave: (HouseholdResource) throws -> Void
    @State private var quantityText = ""
    @State private var useText = ""
    @State private var loadedAmounts = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Supply name", text: $resource.name)
                    Picker("Category", selection: $resource.category) {
                        ForEach(HouseholdResource.Category.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                }
                Section("Amount on hand") {
                    TextField("Amount on hand", text: $quantityText)
                        .keyboardType(.decimalPad)
                    unitPicker(selection: $resource.quantityUnit)
                }
                Section {
                    TextField("Used per day", text: $useText)
                        .keyboardType(.decimalPad)
                    unitPicker(selection: $resource.dailyUseUnit)
                } header: {
                    Text("Household use per day")
                } footer: {
                    Text("Enter numbers without thousands separators. Leave unknown amounts blank. For medication, enter the daily use you already follow.")
                }
                if let updatedResource, let days = updatedResource.estimatedDays {
                    LabeledContent("Estimated runway", value: HouseholdResource.formatDays(days))
                } else {
                    LabeledContent("Estimated runway", value: "Unknown")
                }
            }
            .navigationTitle("Supply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let updatedResource else { return }
                        do {
                            try onSave(updatedResource)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(updatedResource == nil)
                }
            }
            .onAppear {
                guard !loadedAmounts else { return }
                quantityText = editText(resource.quantity)
                useText = editText(resource.dailyUse)
                loadedAmounts = true
            }
            .onChange(of: resource.category) {
                guard let unit = resource.category.units.first else { return }
                resource.quantityUnit = unit
                resource.dailyUseUnit = unit
                quantityText = ""
                useText = ""
            }
            .alert("Could not save supply", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func unitPicker(selection: Binding<HouseholdResource.Unit>) -> some View {
        Picker("Unit", selection: selection) {
            ForEach(resource.category.units) { unit in
                Text(unit.title).tag(unit)
            }
        }
    }

    private var updatedResource: HouseholdResource? {
        guard loadedAmounts else { return nil }
        let amount = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        let use = useText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = resource
        result.name = resource.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.quantity = HouseholdResource.parseAmount(amount, locale: locale)
        result.dailyUse = HouseholdResource.parseAmount(use, locale: locale)
        guard amount.isEmpty || result.quantity != nil, use.isEmpty || result.dailyUse != nil,
              result.isValid else { return nil }
        return result
    }

    private func editText(_ value: Double?) -> String {
        guard let value else { return "" }
        let text = String(value)
        if text.hasSuffix(".0") { return String(text.dropLast(2)) }
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
