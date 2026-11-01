import StarshipCore
import StarshipSearch
import SwiftUI

/// One filter window with tabs. Cancel restores what was there; Apply searches and stays open.
struct FilterWindow<Filter: SearchFilter>: View {
    @Binding var filter: Filter
    let options: SearchOptions
    let onSearch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: Filter?
    @State private var tab = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Filter.tabOrder, id: \.self) { Text($0 + (filter.isActive(tab: $0) ? " ●" : "")).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(filter.visibleSections(inTab: tab)) { section in
                        GroupBox(section.title) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(section.fields, id: \.id) { field(section: section, $0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()
            HStack {
                Button("Reset tab") { filter.reset(tab: tab) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if let original { filter = original }
                    onSearch()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Filter") { onSearch() }
                Button("OK") {
                    onSearch()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 640)
        .onAppear {
            original = filter
            tab = Filter.tabOrder.first ?? ""
        }
    }

    @ViewBuilder
    private func field(section: FilterSection<Filter>, _ field: FilterField<Filter>) -> some View {
        let disabled = field.needsGame && !Filter.interestEnabled
        switch field.kind {
        case .text(let path):
            row(field) { TextField(field.placeholder.text, text: $filter[dynamicMember: path]) }
        case .range(let low, let high):
            row(field) {
                HStack {
                    TextField("", text: $filter[dynamicMember: low]).frame(width: 90)
                    Text("to").foregroundStyle(.secondary)
                    TextField("", text: $filter[dynamicMember: high]).frame(width: 90)
                }
            }
        case .choice(let path, let choices, let editable):
            row(field) {
                let items = options.choices(choices)
                HStack {
                    if editable { TextField(field.placeholder.text, text: $filter[dynamicMember: path]) }
                    Picker("", selection: $filter[dynamicMember: path]) {
                        if !items.contains(filter[keyPath: path]) { Text(filter[keyPath: path]).tag(filter[keyPath: path]) }
                        ForEach(items, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: editable ? 60 : .infinity)
                }
            }
            .disabled(disabled)
        case .toggle(let path):
            Toggle(field.label, isOn: $filter[dynamicMember: path]).disabled(disabled)
        case .rule(let index):
            HStack {
                Picker("", selection: $filter.rules[index].attribute) {
                    ForEach(filter.ruleChoices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Picker("", selection: $filter.rules[index].operatorText) {
                    ForEach(AttrRule.operators, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 60)
                TextField("", text: $filter.rules[index].value).frame(width: 60)
            }
        case .note(let note):
            Text(note.text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func row<Content: View>(_ field: FilterField<Filter>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(field.label.isEmpty ? "" : field.label + ":")
                .frame(width: 130, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
