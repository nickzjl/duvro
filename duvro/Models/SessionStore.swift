//
//  SessionStore.swift
//  duvro
//
//  First cut of the session-owned state BUILD_ROADMAP's Project Structure
//  describes ("one @Observable SessionStore owning the flow: photos ->
//  scores -> selection -> picks/tweaks -> export"). This session only
//  needed a home for the chosen selection: FallbackSelectionService
//  produces it as data, and this is where it's stored so Phase 4+ can read
//  it without depending on a debug view or reaching into ImportView's
//  local @State. Growing this to also own photos/scores (currently still
//  View-local @State in ImportView) is future work, not done here.
//
//  No persistence -- a session is ephemeral, per BUILD_ROADMAP.
//

import Foundation

@Observable
@MainActor
final class SessionStore {
    /// The chosen post, in final order. nil until a selection has been
    /// made. Currently only ever written by the Phase 3.5 offline fallback
    /// path (FallbackSelectionService) -- once the curation call exists,
    /// its result will also write here, and will take priority whenever
    /// it's available (see FallbackSelectionService's header comment: this
    /// stays the no-network branch, not a placeholder that gets replaced).
    private(set) var chosenSelection: FallbackSelectionResult?

    func setChosenSelection(_ result: FallbackSelectionResult) {
        chosenSelection = result
    }
}
