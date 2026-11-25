import Foundation
import StarshipCore

/// The save FM has loaded, further on than when it was read. FM's rules are then asked about people through a read of a
/// day that has gone, and their answers fail, so the screens say so rather than show what's left as current.
package struct SaveProgress: Equatable {
    /// The game date the read found.
    let readOn: Date
    /// The game date FM's memory holds now.
    let now: Date

    /// Nil unless both dates are known and the save is later now.
    init?(readOn: Date?, now: Date?) {
        guard let readOn, let now, now > readOn else { return nil }
        self.readOn = readOn
        self.now = now
    }

    /// One line over every screen.
    var notice: String {
        "FM is on \(Self.day(now)), but what FM Starship shows was read on \(Self.day(readOn, withYear: !sameYear)). Press Load Save to read it again."
    }

    /// Over a list the game couldn't narrow by who would join. Load Save is only mentioned when it can help: with the
    /// live game and FM's rules on (`canReload`), not for a snapshot or a build whose rules are off.
    package static func joinWarning(_ progress: SaveProgress?, canReload: Bool) -> String {
        let warning = "FM couldn't be asked who would join, so nobody in this list is known to want to come."
        guard canReload else { return warning }
        guard let progress else { return warning + " Press Load Save to try again." }
        return warning + " FM has moved on to \(day(progress.now)) since your save was read. Press Load Save to read it again."
    }

    private var sameYear: Bool {
        GameDate.calendar.component(.year, from: now) == GameDate.calendar.component(.year, from: readOn)
    }

    private static func day(_ date: Date, withYear: Bool = true) -> String {
        (withYear ? dayAndYear : dayOnly).string(from: date)
    }

    private static let dayAndYear = format("d MMM yyyy")
    private static let dayOnly = format("d MMM")

    /// POSIX, so September is "Sep" whatever the Mac's language and region.
    private static func format(_ pattern: String) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = GameDate.calendar.timeZone
        format.dateFormat = pattern
        return format
    }
}
