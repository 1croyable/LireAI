import Foundation
import ReadiumShared

/// One unpersisted fragment, owned by the currently open book's session.
struct PendingSelection {
    let text: String
    let locator: Locator
    let bookID: UUID

    func orderedFragments(with current: PendingSelection) -> [String]? {
        guard bookID == current.bookID else { return nil }
        let earlier = FragmentOrder.pendingFirst(
            total: (locator.locations.totalProgression, current.locator.locations.totalProgression),
            positions: (locator.locations.position, current.locator.locations.position),
            sameResource: locator.href.isEquivalentTo(current.locator.href),
            progression: (locator.locations.progression, current.locator.locations.progression)
        )
        return earlier ? [text, current.text] : [current.text, text]
    }
}
