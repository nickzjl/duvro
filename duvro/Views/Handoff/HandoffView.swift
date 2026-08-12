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
    /// The user's final (possibly hand-edited) caption from CaptionView --
    /// this is what actually gets copied to the clipboard on arrival at
    /// `.done` now, replacing the old hardcoded placeholder string. Every
    /// call site upstream of Handoff now runs through CaptionView first
    /// (Phase 9), so this is always real, user-approved text, not a
    /// generated draft nobody has seen.
    let caption: String

    @Environment(\.dismiss) private var dismiss
    @State private var exportService = ExportService()
    @State private var renderCache: [UUID: UIImage] = [:]
    @State private var showToast = false

    private var items: [ExportService.Item] {
        sessionStore.post.compactMap { score -> ExportService.Item? in
            guard let photo = sessionStore.photo(for: score.id) else { return nil }
            let variantName = sessionStore.pickedVariantName[score.id]
            guard let variant = pack.variants.first(where: { $0.name == variantName }) ?? pack.variants.first else { return nil }
            return ExportService.Item(photo: photo, variant: variant)
        }
    }

    /// "your 7 most recent photos" (or "your 1 most recent photo" -- a
    /// dump can shrink well below prd.md's usual 4-20 via skips, so this
    /// is a real case, not paranoia). Always the LIVE post count, never
    /// hardcoded -- with no album to point at, this number is the only
    /// thing telling the user which photos in their camera roll are
    /// theirs to select.
    private var recentPhotosPhrase: String {
        let count = sessionStore.post.count
        return "your \(count) most recent \(count == 1 ? "photo" : "photos")"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // NOT wrapped in a shared .frame(maxWidth: .infinity,
            // maxHeight: .infinity) across every case -- that was forcing
            // doneState's ScrollView (which already fills available space
            // on its own, same as every other ScrollView in this app) into
            // an extra outer size constraint none of the other screens
            // built this session have. Each of the simpler states
            // (progressState/permissionDeniedState/failedState) now
            // requests centering individually, since THEY genuinely need
            // it (a bare VStack would otherwise hug the top of the
            // screen); doneState is left alone.
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
            UIPasteboard.general.string = caption
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

    /// Unlike curation (indeterminate by design -- the network call's
    /// duration genuinely isn't knowable up front), export has a KNOWN
    /// denominator the moment `items` exists: the photo count.
    /// requestingPermission is still indeterminate (waiting on the user,
    /// not measurable), but once rendering actually starts, this shows a
    /// real determinate bar plus "N of M" -- not a spinner that looks
    /// identical whether 1 or 6 of 7 photos are done. Seven full-res
    /// renders is a long enough wait that a non-moving spinner reads as
    /// broken.
    private var progressState: some View {
        VStack(spacing: 16) {
            switch exportService.phase {
            case .exporting where exportService.totalCount > 0:
                // Ink black, not terracotta -- UI_NOTES §1 reserves
                // terracotta for selected states, helper notes, and pack
                // variant names specifically; a progress bar isn't one of
                // those, and "leave colors alone" means not inventing a
                // new use for the accent color either.
                ProgressView(
                    value: Double(exportService.exportedCount),
                    total: Double(exportService.totalCount)
                )
                .progressViewStyle(.linear)
                .tint(Color(hex: "171614"))
                .frame(width: 160)
                Text("saving your photos…")
                    .font(.duvroSubheadline)
                    .foregroundStyle(Color(hex: "777169"))
                Text("\(exportService.exportedCount) of \(exportService.totalCount)")
                    .font(.duvroCaption)
                    .foregroundStyle(Color(hex: "A7A097"))
            case .requestingPermission:
                ProgressView()
                Text("waiting for permission…")
                    .font(.duvroSubheadline)
                    .foregroundStyle(Color(hex: "777169"))
            default:
                ProgressView()
                Text("getting ready…")
                    .font(.duvroSubheadline)
                    .foregroundStyle(Color(hex: "777169"))
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        title: "saved to your camera roll",
                        body: "your photos are saved in full quality, ready to post."
                    )
                    stepRow(
                        icon: "doc.on.clipboard",
                        title: "caption copied",
                        body: "your caption is on the clipboard, ready to paste."
                    )
                    stepRow(
                        icon: "arrow.up.forward.app",
                        title: "finish in instagram",
                        // NO album to point at (Deferred work register:
                        // NAMED ALBUM DROPPED IN V1) -- staggered
                        // creationDate at export (ExportService.saveAll)
                        // is what actually makes "the N most recent
                        // photos" true, so this copy is describing a real
                        // mechanism, not a suggestion. Order is the one
                        // thing that silently breaks the post if the user
                        // gets it wrong (UI_NOTES handoff fix) -- "tap
                        // them in order" is required, not decoration.
                        body: "select your \(recentPhotosPhrase) and tap \(sessionStore.post.count == 1 ? "it" : "them") in order, then paste your caption."
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
                    photoStripCard(score)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// Each branch gets .resizable().aspectRatio(4/5, contentMode: .fill)
    /// applied DIRECTLY, not chained onto a Group wrapping the if/else --
    /// this replaces a version where those modifiers sat on the Group
    /// instead of either Image, which rendered thumbnails square rather
    /// than 4:5. Matches FinalReviewView.thumbnailCell's structure (same
    /// per-branch pattern, proven working, screenshotted earlier this
    /// session) rather than inventing a second way to size a thumbnail
    /// card.
    @ViewBuilder
    private func photoStripCard(_ score: PhotoScore) -> some View {
        if let image = renderCache[score.id] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(4 / 5, contentMode: .fill)
                .frame(width: 96, height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let photo = sessionStore.photo(for: score.id) {
            Image(uiImage: photo.thumbnail)
                .resizable()
                .aspectRatio(4 / 5, contentMode: .fill)
                .frame(width: 96, height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
