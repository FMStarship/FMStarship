import Foundation
@preconcurrency import StarshipAnalysis

/// The save FM has loaded, as far as it can be told without reading it: the date in FM's bar, and the names FM's memory
/// holds now where the read found the human managers' clubs. Nil where it can't be told, such as during a match, when
/// FM's bar isn't up.
struct SaveIdentity: Equatable {
    var date: String?
    var clubs: String?

    /// Whether this is another save than `read`, or the same one further on. Only what's known on both sides counts,
    /// so a moment without FM's bar changes nothing.
    func differs(from read: SaveIdentity) -> Bool {
        if let date, let was = read.date, date != was { return true }
        if let clubs, let was = read.clubs, clubs != was { return true }
        return false
    }
}

/// Which of the model's reads of the save FM Starship's screens inside FM may be made from, so that none shows people
/// from another save than the one FM has loaded. A read is stale from the moment FM's save may have changed, and so is
/// one that was still going on then, since part of it was read before.
struct SaveWatch {
    /// What `follow` noticed.
    enum Change: Equatable {
        case none
        /// FM's save isn't the one read: another date in FM's bar, or the clubs gone from where they were.
        case saveChanged
        /// A read that was going on when the save changed has finished, and is stale too.
        case readWasStale
    }

    /// The read made before FM's save changed. Weak, so that a read the model has let go of isn't taken for a new one
    /// made at the same address.
    private weak var stale: AnyObject?
    /// Whether a read was going on when the save changed.
    private var staleWhenRead = false
    /// The read `readAs` was taken for, and how FM showed the save then.
    private weak var identified: AnyObject?
    private(set) var readAs: SaveIdentity?

    /// Whether screens may be made from this read.
    func usable(_ read: AnyObject?) -> Bool { read != nil && read !== stale && !staleWhenRead }

    /// Whether the save has to be read before anything can be shown. Not while a read is going on: it's waited for.
    func needsReading(_ read: AnyObject?, loading: Bool) -> Bool { !loading && !usable(read) }

    /// FM's save has changed, or may have: what was read so far is stale.
    mutating func saveChanged(read: AnyObject?, loading: Bool) {
        stale = read
        staleWhenRead = loading
        identified = nil
        readAs = nil
    }

    /// Follows the model's reads, with the save as FM shows it now, which is only worked out when there's a read to
    /// compare it with. The first look at a read is how FM showed the save when it was made.
    mutating func follow(read: AnyObject?, loading: Bool, now: () -> SaveIdentity) -> Change {
        if staleWhenRead, !loading {
            stale = read
            staleWhenRead = false
            return .readWasStale
        }
        guard usable(read) else { return .none }
        guard read === identified, let readAs else {
            identified = read
            readAs = now()
            return .none
        }
        return now().differs(from: readAs) ? .saveChanged : .none
    }
}

/// The settings that decide what a screen of FM Starship's shows from a read: how Ability shows CA and PA, if at all,
/// whether Hidden attributes is on, and the units for money, wages and heights. That's all of `DisplayOptions` but
/// `insideGame`, which is always true here.
struct ShownAs: Equatable {
    let reveal: AbilityReveal
    let showHidden: Bool
    let units: MoneyUnits

    init(_ display: DisplayOptions) {
        reveal = display.reveal
        showHidden = display.showHidden
        units = display.units
    }
}

/// One of FM Starship's screens as it was made: from which analysis, and with which settings.
struct MadeScreen<Content> {
    let revision: Int
    let shownAs: ShownAs
    let content: Content

    /// Whether it may be shown with the settings as they are now. Nil `now` means there's no read to show.
    func fits(_ now: ShownAs?) -> Bool { Self.fits(madeWith: shownAs, now: now) }

    /// Whatever was made with Hidden attributes on can hold hidden attributes, and CA and PA unless Ability is off, so
    /// it doesn't stay up once it's off, not even until it's made again. One made with it off is missing them once it's
    /// on, and one made with another Ability or other units shows other numbers. Nil is no read, which nothing fits.
    static func fits(madeWith: ShownAs?, now: ShownAs?) -> Bool { madeWith != nil && madeWith == now }
}
