//
//  ClusterInspectorView.swift
//  duvro
//
//  DEBUG-only. Recurring-person clustering (item 4) is a research spike:
//  a general Vision feature print is NOT a face-identity embedding, so
//  clusters might group by lighting/angle/background rather than by
//  person. This view exists to tell the difference by eye -- every
//  cluster as a row of the actual face crops it contains, with size.
//
//  Each thumbnail is labeled with its short key (photoID prefix-faceIndex)
//  so it can be cross-referenced against the pairwise-distance console dump
//  ScoringService prints after clustering (item 1c).
//

import SwiftUI

struct ClusterInspectorView: View {
    let clusters: [PersonClusterDisplay]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if clusters.isEmpty {
                        Text("no clusters of size >= 2 -- either no recurring faces this session, or every face wound up in its own cluster.")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color(hex: "777169"))
                            .padding(20)
                    }
                    ForEach(clusters) { cluster in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("cluster \(cluster.id) -- \(cluster.size) faces")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 6) {
                                    ForEach(cluster.members) { member in
                                        VStack(spacing: 2) {
                                            Image(uiImage: member.thumbnail)
                                                .resizable()
                                                .aspectRatio(1, contentMode: .fill)
                                                .frame(width: 90, height: 90)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            Text(member.key)
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(Color(hex: "777169"))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(hex: "FFFCF7"))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(12)
            }
            .background(Color(hex: "F7F4EE"))
            .navigationTitle("cluster inspector (\(clusters.count))")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.light)
    }
}
