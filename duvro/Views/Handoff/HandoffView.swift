//
//  HandoffView.swift
//  duvro
//
//  Phase 7, Task 3, "ready when you are" (prd.md §4 step 10, BUILD_ROADMAP
//  Phase 7, UI_NOTES fix 5/13(handoff bullet)/§6). Lands here directly from
//  FinalReviewView's "add a caption" -- see the comment on that call site
//  for why this phase skips straight past Phase 9's not-yet-built caption
//  screen.
//
//  Kicks off ExportService.exportToPhotos on arrival and switches its
//  whole body on ExportService.phase: an in-progress state while
//  photos render and save, a permission-denied state with a way to
//  recover, a failure state with a way to retry, and -- once `.done` --
//  the mockup's 3-step layout, matching design/14_hand off.png.
//

import SwiftUI

struct HandoffView: View {
    var sessionStore: SessionStore
    let pack: VibePack

    @Environment(\.dismiss) private var dismiss
    @State private var exportService = ExportService()
    @State private var renderCache: [UUID: UIImage] = [:]
    @State private var showToast = false

    /// Phase 9 placeholder (this phase explicitly does not build the
    /// caption screen -- SCOPE, per instruction). Phase 9 replaces this
    /// with a real generated suggestion; until then this is what gets
    /// copied to the clipboard so the rest of the handoff flow (b in
    /// prd.md §4 step 10: "copy caption to clipboard") has something real
    /// to do.
    private static let placeholderCaption = "just posted."

    private var items: [ExportService.Item] {
        sessionStore.post.compactMap { score -> ExportService.Item? in
            guard let photo = sessionStore.photo(for: score.id) else { return nil }
            let variantName = sessionStore.pickedVariantName[score.id]
            guard let variant = pack.variants.first(where: { $0.name == variantName }) ?? pack.variants.first else { return nil }
            return ExportService.Item(photo: photo, variant: variant)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch exportService.phase {
                case .idle, .requestingPermission, .exporting:
                    progressState
                case .permissionDenied:
                    permissionDeniedState
                case .failed(let reason):
                    failedState(reason: reason)
                case .done:
                    doneState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(hex: "F7F4EE").ignoresSafeArea())
        .overlay(alignment: .top) { if showToast { toast } }
        .task {
            renderStripPreviews()
            await exportService.exportToPhotos(items, expectedCount: sessionStore.post.count)
        }
        .onChange(of: exportService.phase) { _, newPhase in
            guard newPhase == .done else { return }
            // (b) in prd.md §4 step 10 -- copied only once export has
            // actually succeeded, not speculatively on arrival.
            UIPasteboard.general.string = Self.placeholderCaption
            withAnimation { showToast = true }
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation { showToast = false }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "171614"))
                    .frame(width: 44, height: 44)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - In progress (idle / requestingPermission / exporting)

    private var progressState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(exportService.isExporting ? "saving your photos…" : "getting ready…")
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
            if exportService.totalCount > 0 {
                Text("\(exportService.exportedCount) of \(exportService.totalCount)")
                    .font(.duvroCaption)
                    .foregroundStyle(Color(hex: "A7A097"))
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Permission denied (BUILD_ROADMAP: "handle denial gracefully")

    private var permissionDeniedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color(hex: "A7A097"))
            Text("duvro needs permission to save your photos")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
                .multilineTextAlignment(.center)
            Text("you can allow this in Settings, then come back here.")
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
                .multilineTextAlignment(.center)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Text("open settings")
                    .font(.duvroButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "171614"))
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Failed (render or Photos-library error -- distinct from denial)

    private func failedState(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color(hex: "A7A097"))
            Text("something went wrong saving your photos")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
                .multilineTextAlignment(.center)
            Text(reason)
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
                .multilineTextAlignment(.center)
            Button {
                Task { await exportService.retry(items, expectedCount: sessionStore.post.count) }
            } label: {
                Text("try again")
                    .font(.duvroButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "171614"))
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Done: the mockup's 3-step layout (design/14_hand off.png)

    private var doneState: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color(hex: "71816C")) // Success: Muted Sage, §1
                    Text("ready when you are")
                        .font(.duvroHeadline)
                        .foregroundStyle(Color(hex: "171614"))
                    Text("your curation is polished and waiting for its debut.")
                        .font(.duvroSubheadline)
                        .foregroundStyle(Color(hex: "777169"))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 20) {
                    stepRow(
                        icon: "square.and.arrow.down",
                        title: "saved to duvro album",
                        body: "images have been rendered in high-resolution to your local storage."
                    )
                    stepRow(
                        icon: "doc.on.clipboard",
                        title: "caption copied",
                        body: "your caption is on the clipboard, ready to paste."
                    )
                    stepRow(
                        icon: "arrow.up.forward.app",
                        title: "finish in instagram",
                        body: "select your photos from the duvro album, tap them in order, then paste your caption."
                    )
                }
                .padding(.horizontal, 20)

                photoStrip
            }
            .padding(.bottom, 12)
        }
        // UI_NOTES fix 5: the mockup's photo strip clips behind the fixed
        // bottom button -- bottom content inset must equal the button
        // container's real height + safe area. safeAreaInset (not a
        // guessed constant) does that structurally, same pattern as
        // EditFlowView/FinalReviewView.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            primaryButton
        }
    }

    private func stepRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(hex: "171614"), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.duvroStepTitle)
                    .foregroundStyle(Color(hex: "171614"))
                Text(body)
                    .font(.duvroSubheadline)
                    .foregroundStyle(Color(hex: "777169"))
            }
        }
    }

    /// The exact post, in carousel order, at 4:5 (UI_NOTES §1: "every
    /// photo displayed at 4:5 everywhere"). Uses the existing <=1280px
    /// preview render path (EditEngine.render), not the full-res export --
    /// this strip is decorative confirmation, not the export artifact
    /// itself, and re-decoding full-res originals here would duplicate
    /// exportToPhotos' own work for no visible benefit at thumbnail size.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessionStore.post) { score in
                    Group {
                        if let image = renderCache[score.id] {
                            Image(uiImage: image).resizable()
                        } else if let photo = sessionStore.photo(for: score.id) {
                            Image(uiImage: photo.thumbnail).resizable()
                        }
                    }
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .frame(width: 96, height: 120)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var primaryButton: some View {
        Button {
            InstagramLauncher.open()
        } label: {
            Text("open instagram")
                .font(.duvroButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(hex: "171614"))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(hex: "F7F4EE"))
    }

    // MARK: - Toast (BUILD_ROADMAP: "caption copied -- just paste ✨" on arrival)

    private var toast: some View {
        Text("caption copied — just paste ✨")
            .font(.duvroLabel)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(hex: "171614"), in: Capsule())
            .padding(.top, 56)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Preview renders for the photo strip

    private func renderStripPreviews() {
        let variants = pack.variants
        for score in sessionStore.post {
            guard renderCache[score.id] == nil, let photo = sessionStore.photo(for: score.id) else { continue }
            let variantName = sessionStore.pickedVariantName[score.id]
            guard let variant = variants.first(where: { $0.name == variantName }) ?? variants.first else { continue }
            Task {
                let image = await Task.detached(priority: .userInitiated) {
                    EditEngine.render(photo: photo, variant: variant)
                }.value
                renderCache[score.id] = image
            }
        }
    }
}
