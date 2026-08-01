//
//  ImportView.swift
//  duvro
//

import SwiftUI

struct ImportView: View {
    @State private var importService = PhotoImportService()
    @State private var isPickerPresented = false

    private let minimumPhotos = 20
    private let maximumPhotos = 200

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: "F7F4EE").ignoresSafeArea()

            if importService.photos.isEmpty && !importService.isImporting {
                emptyState
            } else {
                grid
            }

            #if DEBUG
            debugOverlay
            #endif
        }
        .sheet(isPresented: $isPickerPresented) {
            PhotoPicker(selectionLimit: maximumPhotos) { results in
                isPickerPresented = false
                Task {
                    await importService.process(results: results)
                }
            }
            .ignoresSafeArea()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("pick your favorites")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Text("select 20–200 photos to start")
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
            Spacer()
            Button {
                isPickerPresented = true
            } label: {
                Text("select photos")
                    .font(.duvroButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "171614"))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(importService.photos) { photo in
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .aspectRatio(4 / 5, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .clipped()
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 64)
            .padding(.bottom, 40)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("your photos")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Text(countLabel)
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
        }
        .padding(.horizontal, 20)
    }

    private var countLabel: String {
        if importService.isImporting {
            return "\(importService.importedCount) of \(importService.totalCount) processed…"
        }
        let count = importService.photos.count
        if count < minimumPhotos {
            return "\(count) selected — add a few more, 20 is the minimum for a good curation"
        }
        return "\(count) photos selected"
    }

    #if DEBUG
    private var debugOverlay: some View {
        HStack {
            Spacer()
            Text(String(format: "peak %.0fMB · %d/%d", importService.peakMemoryMB, importService.photos.count, importService.totalCount))
                .font(.system(size: 11, design: .monospaced))
                .padding(6)
                .background(.black.opacity(0.7))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
    }
    #endif
}

#Preview {
    ImportView()
}
