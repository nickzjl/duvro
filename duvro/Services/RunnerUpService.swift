//
//  RunnerUpService.swift
//  duvro
//
//  Phase 6 needs a "what we left out" row (prd.md P0.9, UI_NOTES fix 10):
//  the next-best shortlisted photos that didn't make the chosen post,
//  ADAPTIVE 2-5, not fixed at 3. Pulled from the shortlist remainder --
//  the same pool FallbackSelectionService picks the post from -- respecting
//  the same one-photo-per-cluster rule that service uses, so a runner-up
//  is never a near-duplicate of something already in the post (or of
//  another runner-up).
//
//  ADAPTIVE COUNT RULE (deliberately simple, per the task brief -- "don't
//  overthink this, flag your rule"): count how many eligible remainder
//  candidates fall within `closenessThreshold` of the lowest CHOSEN photo's
//  composite -- i.e. "how many almost made it." Clamp that count to 2...5.
//  If fewer than 2 are actually close, still show 2 (the row's floor) by
//  taking the next-best regardless of closeness, so it's never emptier than
//  the UI's minimum -- rationale is "always give the user *something* to
//  swap in," not "only show near-misses." `closenessThreshold` is a named
//  constant specifically so it can be tuned against real distributions;
//  0.15 is a starting guess (roughly 15% of the composite's 0...1 range),
//  not derived from data.
//

import Foundation

nonisolated enum RunnerUpService {
    static let minCount = 2
    static let maxCount = 5
    /// How close (in composite score) a remainder candidate must be to the
    /// lowest CHOSEN photo's composite to count as a genuine "almost made
    /// it" near-miss. Tune this, not the count logic, to change how the
    /// adaptive count behaves.
    static let closenessThreshold: Double = 0.15

    /// `chosen` is the CURRENT post (SessionStore.post), not
    /// chosenSelection.selected -- skips during Phase 5 change what's
    /// "chosen," and runner-ups should reflect that, not the original
    /// proposal.
    static func compute(shortlist: ShortlistResult, chosen: [PhotoScore]) -> [PhotoScore] {
        guard !chosen.isEmpty else { return [] }
        let lowestChosenComposite = Double(chosen.map(\.compositeScore).min() ?? 0)
        let chosenIDs = Set(chosen.map(\.id))
        var usedClusterIDs = Set(chosen.compactMap { shortlist.clusterID[$0.id] })

        let ranked = shortlist.shortlisted
            .filter { !chosenIDs.contains($0.id) }
            .sorted { $0.compositeScore > $1.compositeScore }

        // One-per-cluster, same walk-and-skip pattern as
        // FallbackSelectionService/ShortlistService: never a runner-up
        // that's a near-duplicate of something already chosen, or of an
        // earlier (higher-composite) runner-up.
        var eligible: [PhotoScore] = []
        for candidate in ranked {
            let clusterID = shortlist.clusterID[candidate.id]
            if let clusterID, usedClusterIDs.contains(clusterID) { continue }
            eligible.append(candidate)
            if let clusterID { usedClusterIDs.insert(clusterID) }
        }

        let close = eligible.filter { lowestChosenComposite - Double($0.compositeScore) <= closenessThreshold }
        if close.count >= minCount {
            return Array(close.prefix(maxCount))
        }
        return Array(eligible.prefix(minCount))
    }
}
