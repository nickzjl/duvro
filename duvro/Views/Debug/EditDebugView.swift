//
//  EditDebugView.swift
//  duvro
//
//  DEBUG-only tuning instrument for Phase 4. Renders ONE photo through all
//  3 Golden Hour variants side by side with the original, and shows each
//  variant's render time in ms -- Phase 4's acceptance is <1s per variant
//  on device, and this is where that gets measured for real.
//
//  Source photo: sessionStore.chosenSelection's top pick, if there is one.
//  chosenSelection hasn't been verified on device yet -- the one-per-
//  cluster fallback rule may return fewer than 7 photos, or (if Phase 3's
//  shortlist step was never run this session) none at all. Phase 4's job
//  is verifying the render pipeline, not re-verifying Phase 3's selection,
//  so an empty/short chosenSelection falls back to any scored photo from
//  the current import rather than leaving this screen with nothing to
//  show. The chosen-selection count is surfaced either way so it's visible
//  in this run regardless of which path was taken.
//

import SwiftUI

struct EditDebugView: View {
    let photos: [Photo]
    let scores: [PhotoScore]
    let chosenSelection: FallbackSelectionResult?

    @State private var renders: [RenderResult] = []
    @State private var isRendering = false
    @State private var packLoadError: VibePackLoadError?

    private struct RenderResult: Identifiable {
        var id: String { variantName }
        let variantName: String
        let image: UIImage
        let milliseconds: Double
    }

    private var photosByID: [UUID: Photo] {
        Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    }

    /// nil only if there is truly nothing to render from -- no chosen
    /// selection AND no scored photos at all.
    private var sourcePhoto: Photo? {
        if let topPick = chosenSelection?.selected.first, let photo = photosByID[topPick.id] {
            return photo
        }
        // Fallback: chosenSelection is empty/unavailable.
        if let anyScore = scores.first, let photo = photosByID[anyScore.id] {
            return photo
        }
        return nil
    }

    private var usingFallbackSource: Bool {
        chosenSelection?.selected.first == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let sourcePhoto {
                        originalCard(sourcePhoto)
                        if isRendering {
                            Text("rendering…")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color(hex: "777169"))
                        } else if let packLoadError {
                            failureBanner(packLoadError)
                        } else {
                            ForEach(renders) { result in
                                variantCard(result)
                            }
                        }
                    } else {
                        Text("no scored photos to render -- score some photos first")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color(hex: "777169"))
                    }
                }
                .padding(12)
            }
            .background(Color(hex: "F7F4EE"))
            .navigationTitle("edit debug")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.light)
        .task(id: sourcePhoto?.id) {
            await render()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            let chosenCount = chosenSelection?.selected.count ?? 0
            Text("chosenSelection: \(chosenCount)/\(FallbackSelectionService.fallbackCount)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(chosenCount < FallbackSelectionService.fallbackCount ? Color(hex: "A04021") : Color(hex: "171614"))
            Text(usingFallbackSource
                 ? "source: any scored photo (chosenSelection empty/unavailable)"
                 : "source: chosenSelection's top pick")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: "777169"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func failureBanner(_ error: VibePackLoadError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("golden_hour pack failed to load — \(failureKind(error))")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(error.diagnosticDescription)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Short label for the headline; the full detail (including the
    /// path(s) looked up) is in `error.diagnosticDescription` below it --
    /// this screen is the only place the reason surfaces on a device with
    /// no console attached, so both the category and the detail need to be
    /// readable without Xcode.
    private func failureKind(_ error: VibePackLoadError) -> String {
        switch error {
        case .missingOrUnreadable: return "missing/unreadable"
        case .decodeFailed: return "decode failed"
        case .wrongVariantCount: return "wrong variant count"
        }
    }

    // MARK: - Cards

    private func originalCard(_ photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("original")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Image(uiImage: photo.thumbnail)
                .resizable()
                .aspectRatio(4 / 5, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(8)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func variantCard(_ result: RenderResult) -> some View {
        let overBudget = result.milliseconds >= 1000
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.variantName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text(String(format: "%.0f ms", result.milliseconds))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(overBudget ? .white : Color(hex: "171614"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(overBudget ? Color.red.opacity(0.85) : Color(hex: "EEE9DF"))
                    .clipShape(Capsule())
            }
            Image(uiImage: result.image)
                .resizable()
                .aspectRatio(4 / 5, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(8)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Rendering

    private func render() async {
        guard let sourcePhoto else { return }
        let pack: VibePack
        switch VibePackLoader.load(named: "golden_hour") {
        case .failure(let error):
            packLoadError = error
            renders = []
            return
        case .success(let loaded):
            pack = loaded
        }
        packLoadError = nil
        isRendering = true
        renders = []

        // Off the main actor so a slow render (this is exactly what's being
        // measured, so it isn't assumed fast) doesn't freeze the UI while
        // timing runs -- EditEngine.render is a nonisolated, stateless call.
        let computed: [RenderResult] = await Task.detached(priority: .userInitiated) {
            pack.variants.map { variant in
                let start = DispatchTime.now()
                let image = EditEngine.render(photo: sourcePhoto, variant: variant)
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                return RenderResult(variantName: variant.name, image: image, milliseconds: elapsedMs)
            }
        }.value

        renders = computed
        isRendering = false
    }
}
