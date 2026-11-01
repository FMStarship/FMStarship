import StarshipSearch
import SwiftUI

/// Which columns show, grouped as the catalogue groups them, and in what order.
struct ColumnsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let staff: Bool

    @State private var columns: [Col] = []
    @State private var order: [String] = []

    private var groups: [(name: String, columns: [Col])] {
        var names: [String] = []
        var byGroup: [String: [Col]] = [:]
        for col in columns {
            if byGroup[col.group] == nil { names.append(col.group) }
            byGroup[col.group, default: []].append(col)
        }
        return names.map { ($0, byGroup[$0] ?? []) }
    }

    private func canShow(_ col: Col) -> Bool { Columns.allowed(col, showHidden: model.showHidden, showAbility: model.showsAbility) }

    private var offNote: String? {
        if !model.showHidden { return "Hidden attributes are switched off, so their columns, CA and PA can't be shown." }
        return model.showsAbility ? nil : "Ability is switched off, so CA and PA can't be shown."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                List {
                    ForEach(groups, id: \.name) { group in
                        Section {
                            ForEach(group.columns) { col in
                                Toggle(isOn: visible(col)) {
                                    Text(col.name).foregroundStyle(col.hidden ? Color(nsColor: model.colors.hidden) : .primary)
                                }
                                .disabled(!canShow(col))
                            }
                        } header: {
                            Toggle(group.name, isOn: visible(group: group.columns))
                                .toggleStyle(.checkbox)
                                .font(.headline)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 280, maxWidth: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Order").font(.headline).padding([.top, .leading], 10)
                    Text("Drag to rearrange").font(.subheadline).foregroundStyle(.secondary).padding(.leading, 10)
                    List {
                        ForEach(order, id: \.self) { Text($0) }
                            .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.inset)
                }
                .frame(width: 230)
            }

            if let offNote {
                Text(offNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Divider().padding(.top, 6)
            HStack {
                Button("Select default") { select { $0.isDefault } }
                Button("Select all") { select { _ in true } }
                Button("Select none") { select { _ in false } }
                Button("Reset layout") {
                    model.resetColumns(staff: staff)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    model.chooseColumns(staff: staff, visible: Set(columns.filter(\.visible).map(\.name)), order: order)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 620)
        .onAppear {
            columns = staff ? model.allStaffColumns : model.allPlayerColumns
            order = (staff ? model.staffColumns : model.playerColumns).map(\.name)
        }
    }

    private func visible(_ col: Col) -> Binding<Bool> {
        Binding(get: { columns.first { $0.name == col.name }?.visible ?? false },
                set: { setVisible(col.name, $0) })
    }

    private func visible(group: [Col]) -> Binding<Bool> {
        Binding(get: { group.allSatisfy { col in columns.first { $0.name == col.name }?.visible ?? false } },
                set: { value in
                    for col in group where canShow(col) { setVisible(col.name, value) }
                })
    }

    private func setVisible(_ name: String, _ value: Bool) {
        guard let index = columns.firstIndex(where: { $0.name == name }) else { return }
        columns[index].visible = value
        if value {
            if canShow(columns[index]), !order.contains(name) { order.append(name) }
        } else {
            order.removeAll { $0 == name }
        }
    }

    private func select(_ wanted: (Col) -> Bool) {
        for col in columns where canShow(col) { setVisible(col.name, wanted(col)) }
    }
}
