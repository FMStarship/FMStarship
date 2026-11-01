import AppKit
import StarshipAnalysis
import StarshipCore
import SwiftUI

/// One club's squad, or its backroom staff, in the normal table.
struct OpenSquadScreen: View {
    @EnvironmentObject private var model: AppModel

    private var squads: [String] { model.squadCatalogue?.squads(for: model.squadClub) ?? [OpenSquad.allSquads] }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.gap) {
            ControlBar {
                HStack(spacing: 5) {
                    Text(OpenSquad.clubLabel)
                    ClubComboBox(clubs: model.squadCatalogue?.clubs ?? [], text: $model.squadClub) { open($0) }
                        .frame(width: 260)
                }
                if !model.squadShowsStaff {
                    Picker(OpenSquad.squadLabel, selection: $model.squadName) {
                        ForEach(squads, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                    .onChange(of: model.squadName) { model.showSquad() }
                }
                Picker("Show", selection: $model.squadShowsStaff) {
                    Text("Players").tag(false)
                    Text("Staff").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.squadShowsStaff) { model.showSquad() }
            } trailing: {
                EmptyView()
            }
            PeopleList(isStaff: model.squadShowsStaff)
        }
        .padding(Metric.gutter)
        .onAppear {
            guard model.squadClub.isEmpty, let start = model.squadCatalogue?.startingClub(), !start.isEmpty else { return }
            open(start)
        }
    }

    /// A newly picked club starts on its first squad, as the original's dialog does.
    private func open(_ club: String) {
        guard let catalogue = model.squadCatalogue else { return }
        model.squadClub = club
        if let found = catalogue.club(matching: club) {
            let choices = catalogue.squads(for: found)
            model.squadName = choices[catalogue.startingSquadIndex(for: found)]
        }
        model.showSquad()
    }
}

/// There are thousands of clubs, so this asks for rows as it needs them and completes as you type.
struct ClubComboBox: NSViewRepresentable {
    let clubs: [String]
    @Binding var text: String
    let onChoose: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = true
        box.dataSource = context.coordinator
        box.delegate = context.coordinator
        box.completes = true
        box.numberOfVisibleItems = 14
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if box.stringValue != text, box.currentEditor() == nil { box.stringValue = text }
    }

    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: ClubComboBox

        init(_ parent: ClubComboBox) { self.parent = parent }

        func numberOfItems(in comboBox: NSComboBox) -> Int { parent.clubs.count }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            index < parent.clubs.count ? parent.clubs[index] : nil
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            parent.clubs.first { $0.range(of: string, options: [.caseInsensitive, .anchored]) != nil }
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            parent.clubs.firstIndex(of: string) ?? NSNotFound
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  box.indexOfSelectedItem < parent.clubs.count else { return }
            parent.onChoose(parent.clubs[box.indexOfSelectedItem])
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            let typed = box.stringValue
            if typed != parent.text, !typed.isEmpty { parent.onChoose(typed) }
        }
    }
}
