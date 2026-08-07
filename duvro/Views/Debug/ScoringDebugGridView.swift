//
//  ScoringDebugGridView.swift
//  duvro
//
//  DEBUG-only tuning instrument for Phase 2 (BUILD_ROADMAP: "this is the
//  tuning tool -- build it well"). Not part of the product UI flow.
//  Shows every photo with every sub-score, the composite, category, and
//  utility flag; sortable; tap to enlarge.
//

import SwiftUI

struct ScoringDebugGridView: View {
    let photos: [Photo]
    let scores: [PhotoScore]
    var failedCount: Int = 0
    var failureReasons: [String] = []

    @State private var sortDescending = true
    @State private var enlarged: PhotoScore?

    private var photosByID: [UUID: Photo] {
        Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    }

    private var sortedScores: [PhotoScore] {
        scores.sorted {
            sortDescending ? $0.compositeScore > $1.compositeScore : $0.compositeScore < $1.compositeScore
        }
    }

    /// So "no good photos in this roll" (scores empty, failedCount 0) reads
    /// differently from "scoring broke" (scores empty, failedCount > 0).
    private var titleText: String {
        failedCount > 0 ? "scoring debug (\(scores.count) ok, \(failedCount) failed)" : "scoring debug (\(scores.count))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if scores.isEmpty && failedCount > 0 {
                    failureBanner
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(sortedScores) { score in
                        if let photo = photosByID[score.id] {
                            ScoreCard(photo: photo, score: score)
                                .onTapGesture { enlarged = score }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(hex: "F7F4EE"))
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        sortDescending.toggle()
                    } label: {
                        Label("sort", systemImage: sortDescending ? "arrow.down" : "arrow.up")
                    }
                }
            }
            .sheet(item: $enlarged) { score in
                if let photo = photosByID[score.id] {
                    ScoreDetailView(photo: photo, score: score)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("scoring broke -- \(failedCount)/\(failedCount + scores.count) photos threw")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
            ForEach(failureReasons, id: \.self) { reason in
                Text(reason)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.red.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(12)
    }
}

private struct ScoreCard: View {
    let photo: Photo
    let score: PhotoScore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .frame(height: 130)
                    .clipped()

                if let reason = score.rejectionReason {
                    Text("REJECTED\n\(reason.displayDescription)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .padding(3)
                        .background(.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .padding(4)
                } else if score.isUtility {
                    // Flagged isUtility by Vision but spared the hard reject
                    // because its aesthetic score isn't low -- surfaced
                    // distinctly so false positives like this stay visible.
                    Text("UTILITY?")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(3)
                        .background(.orange.opacity(0.85))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(String(format: "%.3f", score.compositeScore))
                .font(.system(size: 15, weight: .bold, design: .monospaced))

            categoryBadge

            Group {
                Text("aes \(String(format: "%.2f", score.rawAestheticScore))")
                Text("face \(score.faceCount)  q\(String(format: "%.2f", score.bestFaceQuality))  hum \(score.humanCount)")
                Text("grp \(String(format: "%.1f", score.groupBonus))")
                Text("txt \(String(format: "%.2f", score.textCoverage))  blk \(score.textBlockCount)")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color(hex: "777169"))
        }
        .padding(6)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var categoryBadge: some View {
        Text(score.category.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(hex: "171614"))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

private struct ScoreDetailView: View {
    let photo: Photo
    let score: PhotoScore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(uiImage: photo.thumbnail)
                        .resizable()
                        .aspectRatio(4 / 5, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        row("composite", String(format: "%.4f", score.compositeScore))
                        row("category", score.category.rawValue)
                        row("isUtility (raw Vision flag)", score.isUtility ? "yes" : "no")
                        row("hard rejected", score.rejectionReason?.displayDescription ?? "no")
                        row("raw aesthetic", String(format: "%.4f", score.rawAestheticScore))
                        row("normalized aesthetic", String(format: "%.4f", CompositeScoring.normalizeAesthetic(score.rawAestheticScore)))
                        row("face count", score.isHardRejected ? "0 (Stage 2 skipped -- rejected)" : "\(score.faceCount)")
                        row("best face quality", score.isHardRejected ? "0 (Stage 2 skipped -- rejected)" : String(format: "%.4f", score.bestFaceQuality))
                        row("human count (body detection)", score.isHardRejected ? "0 (Stage 2 skipped -- rejected)" : "\(score.humanCount)")
                        row("group bonus", String(format: "%.2f", score.groupBonus))
                        row("feature print", score.isHardRejected ? "nil (Stage 2 skipped -- rejected)" : (score.featurePrint != nil ? "present" : "nil"))
                        row("text coverage", "\(String(format: "%.4f", score.textCoverage)) (measurement only, not consumed)")
                        row("text block count", "\(score.textBlockCount)")
                    }
                    .font(.system(size: 13, design: .monospaced))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("classification labels")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        ForEach(score.classificationLabels, id: \.identifier) { label in
                            Text("\(label.identifier)  \(String(format: "%.3f", label.confidence))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color(hex: "777169"))
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(hex: "F7F4EE"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Color(hex: "777169"))
            Spacer()
            Text(value)
        }
    }
}
