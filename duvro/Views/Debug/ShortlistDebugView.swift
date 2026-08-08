//
//  ShortlistDebugView.swift
//  duvro
//
//  DEBUG-only tuning instrument for Phase 3's shortlist step. Shows the
//  shortlist exactly as ShortlistService produced it -- grouped by category,
//  in shortlist order -- plus enough aggregate stats to tell "no place
//  photos in this roll" apart from "place photos exist but didn't make the
//  shortlist." Renders data owned by ShortlistService; no selection logic
//  lives here.
//
//  Also renders FallbackSelectionService's chosen set, when there is one --
//  extended for that purpose rather than building a third debug view, since
//  the chosen set is downstream of (and meaningless without) the shortlist
//  shown below it.
//

import SwiftUI

struct ShortlistDebugView: View {
    let photos: [Photo]
    let result: ShortlistResult
    var selection: FallbackSelectionResult?
    var runnerUps: [PhotoScore] = []

    private var photosByID: [UUID: Photo] {
        Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    }

    /// Category order matches ShortlistService's fill order (people first),
    /// not PhotoCategory's declaration order -- this is meant to read the
    /// same way the shortlist was built.
    private static let categoryOrder: [PhotoCategory] = [.people, .place, .food, .detail]

    private var groupedByCategory: [(category: PhotoCategory, items: [PhotoScore])] {
        Self.categoryOrder.compactMap { category in
            let items = result.shortlisted.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let selection {
                        chosenSection(selection)
                    }
                    if !runnerUps.isEmpty {
                        runnerUpSection
                    }
                    ForEach(groupedByCategory, id: \.category) { group in
                        categorySection(group.category, group.items)
                    }
                }
                .padding(12)
            }
            .background(Color(hex: "F7F4EE"))
            .navigationTitle("shortlist debug (\(result.shortlisted.count))")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Header

    private var clusterSizes: [Int] {
        result.clusterMembers.values.map(\.count)
    }

    private var clusterSizeSummary: String {
        let sizes = clusterSizes
        let size1 = sizes.count { $0 == 1 }
        let size2 = sizes.count { $0 == 2 }
        let size3 = sizes.count { $0 == 3 }
        let size5plus = sizes.count { $0 >= 5 }
        let largest = sizes.max() ?? 0
        return "clusters \(sizes.count) total — size1 \(size1) · size2 \(size2) · size3 \(size3) · size5+ \(size5plus) · largest \(largest)"
    }

    private var categoryDistributionSummary: String {
        PhotoCategory.allCases
            .map { category in
                "\(category.rawValue) \(result.surviving.count { $0.category == category })"
            }
            .joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("shortlisted \(result.shortlisted.count) · surviving \(result.surviving.count) · rejected \(result.rejectedCount)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(clusterSizeSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: "777169"))
            Text("category dist. (all surviving): \(categoryDistributionSummary)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: "777169"))
            Text(String(format: "clustering + shortlist: %.3fs · %d distance-compute failures", result.elapsedSeconds, result.clusteringDistanceFailureCount))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(result.clusteringDistanceFailureCount > 0 ? Color(hex: "A04021") : Color(hex: "777169"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Chosen (FallbackSelectionService output)

    private func chosenSection(_ selection: FallbackSelectionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("chosen \(selection.selected.count)/\(FallbackSelectionService.fallbackCount) — \(selection.orderedByTimestamp ? "chronological" : "composite order (no timestamp available)")")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(hex: "A04021"))
                .foregroundStyle(.white)
                .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(Array(selection.selected.enumerated()), id: \.element.id) { index, score in
                    if let photo = photosByID[score.id] {
                        ChosenCard(
                            photo: photo,
                            score: score,
                            position: index + 1,
                            clusterID: result.clusterID[score.id] ?? -1
                        )
                    }
                }
            }
        }
    }

    // MARK: - Runner-ups (RunnerUpService output, "what we left out")

    private var runnerUpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("runner-ups \(runnerUps.count) (adaptive \(RunnerUpService.minCount)–\(RunnerUpService.maxCount), threshold \(String(format: "%.2f", RunnerUpService.closenessThreshold)))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(hex: "777169"))
                .foregroundStyle(.white)
                .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(runnerUps) { score in
                    if let photo = photosByID[score.id] {
                        ShortlistCard(photo: photo, score: score, clusterID: result.clusterID[score.id] ?? -1)
                    }
                }
            }
        }
    }

    // MARK: - Category sections

    private func categorySection(_ category: PhotoCategory, _ items: [PhotoScore]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(category.rawValue) (\(items.count)/\(ShortlistService.quotas[category] ?? 0))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(hex: "171614"))
                .foregroundStyle(.white)
                .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(items) { score in
                    if let photo = photosByID[score.id] {
                        ShortlistCard(photo: photo, score: score, clusterID: result.clusterID[score.id] ?? -1)
                    }
                }
            }
        }
    }
}

private struct ChosenCard: View {
    let photo: Photo
    let score: PhotoScore
    let position: Int
    let clusterID: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .frame(height: 120)
                    .clipped()

                Text("\(position)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(5)
                    .background(.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                    .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(String(format: "%.3f", score.compositeScore))
                .font(.system(size: 13, weight: .bold, design: .monospaced))

            Group {
                Text("cluster \(clusterID)")
                Text("face \(score.faceCount)  q\(String(format: "%.2f", score.bestFaceQuality))")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color(hex: "777169"))
        }
        .padding(6)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ShortlistCard: View {
    let photo: Photo
    let score: PhotoScore
    let clusterID: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(uiImage: photo.thumbnail)
                .resizable()
                .aspectRatio(4 / 5, contentMode: .fill)
                .frame(height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(String(format: "%.3f", score.compositeScore))
                .font(.system(size: 13, weight: .bold, design: .monospaced))

            Group {
                Text("cluster \(clusterID)")
                Text("face \(score.faceCount)  q\(String(format: "%.2f", score.bestFaceQuality))")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color(hex: "777169"))
        }
        .padding(6)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
