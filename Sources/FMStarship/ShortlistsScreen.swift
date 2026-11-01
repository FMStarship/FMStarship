@preconcurrency import StarshipCore
import StarshipFiles
import SwiftUI

/// FM's shortlists on the left, the one you opened in the normal table on the right.
struct ShortlistsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var players: [ShortlistEntry] = []
    @State private var staff: [ShortlistEntry] = []
    @State private var reading = false

    private static let dateFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateStyle = .medium
        format.timeStyle = .none
        return format
    }()

    var body: some View {
        HStack(alignment: .top, spacing: Metric.gap) {
            Panel {
                List(selection: Binding(get: { model.openShortlist?.url }, set: { url in
                    if let url { model.openShortlistFile(url) }
                })) {
                    Section("Player shortlists") { rows(players, kind: "players", empty: "No player shortlists yet") }
                    Section("Staff shortlists") { rows(staff, kind: "staff", empty: "No staff shortlists yet") }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                HStack {
                    Button("Open File...") { model.chooseShortlistFile() }
                    Spacer()
                    if reading { ProgressView().controlSize(.small) }
                    Button { model.shortlistsChanged() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Read the shortlist folders again")
                }
                .padding(10)
            }
            .frame(width: 270)

            Group {
                if let open = model.openShortlist {
                    PeopleList(isStaff: open.isStaff)
                } else {
                    Panel {
                        ContentUnavailableView("Pick a shortlist", systemImage: "list.star", description: Text(placeholder))
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Metric.gutter)
        .task(id: model.shortlistsVersion) { await read() }
    }

    private var placeholder: String {
        "Open one to see everyone on it. Players you've already signed are hidden here but stay in the file, so the same shortlist keeps working in other saves."
    }

    @ViewBuilder
    private func rows(_ entries: [ShortlistEntry], kind: String, empty: String) -> some View {
        if entries.isEmpty {
            Text(reading ? "Reading..." : empty).foregroundStyle(.secondary)
        }
        ForEach(entries, id: \.url) { entry in
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.shortlist.name).lineLimit(1)
                Text("\(entry.shortlist.uids.count) \(kind)  ·  \(Self.dateFormat.string(from: entry.modified))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .tag(entry.url)
        }
    }

    private func read() async {
        reading = true
        let found = await offMain {
            (ShortlistFile.list(isStaff: false), ShortlistFile.list(isStaff: true))
        }
        players = found.0
        staff = found.1
        reading = false
    }
}
