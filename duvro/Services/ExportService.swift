//
//  ExportService.swift
//  duvro
//
//  Phase 7, Task 1: renders the final post at full resolution, one photo
//  at a time, bounded memory, in carousel order, with visible progress.
//  Deliberately knows NOTHING about Photos/PHPhotoLibrary -- `handle` is
//  supplied by the caller (Task 2: saving to the camera roll, see the
//  MARK below for why there's no album) and is called once per rendered
//  photo. This split makes the memory/order/crop guarantees below
//  independently true and independently verifiable (see
//  duvroTests/ExportServiceTests.swift, run entirely on-device-free via
//  the Simulator/synthetic photos) without needing Photos permission or a
//  physical device at all.
//
//  MEMORY (the real risk this phase, per BUILD_ROADMAP): a 12MP photo is
//  roughly 48MB decoded; the project's ceiling is 400MB (currently peaking
//  at 167MB during import). Rendering 7 photos concurrently, or holding
//  their rendered output in an array, would multiply that 48MB by up to 7
//  before anything gets released. This loop instead: renders ONE photo
//  (decode original -> run the op chain -> crop to 4:5 -> encode to JPEG
//  Data, all inside an autoreleasepool, all off the main actor) -> hands
//  that Data to `handle` -> lets it fall out of scope (ARC releases it)
//  before starting the next photo. At no point does this hold more than
//  one photo's worth of decoded/encoded image data.
//

import Foundation
import Photos
import UniformTypeIdentifiers

@Observable
@MainActor
final class ExportService {
    struct Item {
        let photo: Photo
        let variant: EditVariant
    }

    enum RenderError: Error {
        case renderFailed(index: Int)
    }

    /// Phase 7, Task 2's state machine. `phase` (not a bag of separate
    /// bools) so HandoffView can switch over one value instead of
    /// reasoning about which flag combinations are actually reachable.
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case exporting
        case done
        /// Distinct from `.failed` -- BUILD_ROADMAP Phase 7's own
        /// requirement is "handle denial gracefully: the user should see
        /// what happened and what to do, not a dead screen," which needs
        /// its own copy (open Settings) rather than the generic
        /// try-again-worded failure state below.
        case permissionDenied
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var exportedCount = 0
    private(set) var totalCount = 0
    private(set) var isExporting = false
    /// Sampled the same way PhotoImportService.process tracks import's
    /// peak (MemoryMonitor.residentMB, polled every 200ms in the
    /// background) -- consistent measurement methodology so this number is
    /// comparable to the "167MB during import" reference point.
    private(set) var peakMemoryMB: Double = 0

    /// Renders `items` to full-res, 4:5-cropped JPEG data, ONE AT A TIME,
    /// in `items`' order (the caller is responsible for that order being
    /// the final review carousel's order, i.e. SessionStore.post -- this
    /// function does not re-derive or re-sort anything). `handle` is
    /// awaited before moving to the next photo, so a slow write (Task 2:
    /// PHPhotoLibrary) naturally back-pressures the render loop rather
    /// than racing ahead and accumulating rendered-but-unsaved data.
    ///
    /// Throws (and stops) on the first render failure rather than
    /// skipping it silently -- a partially-exported post (missing a
    /// photo, wrong order) is worse than a clear failure the caller can
    /// surface and let the user retry.
    func renderAll(_ items: [Item], handle: (Int, Data) async throws -> Void) async throws {
        isExporting = true
        exportedCount = 0
        totalCount = items.count
        peakMemoryMB = MemoryMonitor.residentMB()
        defer { isExporting = false }

        let peakTracker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.peakMemoryMB = max(self.peakMemoryMB, MemoryMonitor.residentMB())
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { peakTracker.cancel() }

        for (index, item) in items.enumerated() {
            // Off the main actor (CIContext work is CPU-bound and
            // shouldn't block the progress UI), autoreleasepool-wrapped
            // (this is the actual memory guarantee -- Image I/O and
            // CoreImage both autorelease intermediate buffers internally,
            // and without this those buffers can live until the
            // surrounding Task exits rather than being freed between
            // photos).
            let data: Data? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    EditEngine.renderFullResJPEGData(photo: item.photo, variant: item.variant)
                }
            }.value

            guard let data else { throw RenderError.renderFailed(index: index) }

            try await handle(index, data)
            exportedCount = index + 1
        }

        peakMemoryMB = max(peakMemoryMB, MemoryMonitor.residentMB())
        #if DEBUG
        print("[export] peak resident memory: \(String(format: "%.1f", peakMemoryMB)) MB across \(items.count) photos")
        #endif
    }

    // MARK: - Phase 7, Task 2: request permission, save in order

    /// NO ALBUM. v1 saves to the camera roll, not a named "duvro — ready
    /// to post" album -- confirmed by isolation test that
    /// PHAssetCollectionChangeRequest.creationRequestForAssetCollection
    /// crashes under PHAccessLevel.addOnly authorization ("attempted to
    /// access privacy-sensitive data... NSPhotoLibraryUsageDescription").
    /// .addOnly covers saving ASSETS but not creating a named COLLECTION
    /// -- a different PHObject type. Every other candidate was ruled out
    /// first: no PHFetchResult/PHFetchOptions/PHAsset/PHImageManager/
    /// PHCachingImageManager call anywhere in the app, no legacy
    /// no-access-level authorization form anywhere, device-build
    /// Info.plist confirmed correct. Removing album creation entirely
    /// (this file's saveAll) exported cleanly on device -- that's the
    /// confirmation, not a guess. Recorded in BUILD_ROADMAP's Deferred
    /// work register (NAMED ALBUM DROPPED IN V1) along with the two
    /// options if this becomes a real complaint in TestFlight
    /// (.readWrite, or an opt-in upgrade flow) -- neither is built
    /// without a product decision first.
    ///
    /// Consequence this design leans on: since there's no album to find
    /// the post in, the staggered creationDate below isn't just nice
    /// ordering -- it's THE mechanism that makes the post findable at
    /// all. Every photo lands in the user's camera roll among whatever
    /// else is there, so making them the N most recent, contiguous,
    /// newest-first assets is load-bearing, not decorative. HandoffView's
    /// copy reflects this ("select the N most recent photos, tap them in
    /// order").

    /// The ONE entry point HandoffView calls. Requests add-only Photos
    /// permission (prd.md §4 step 10 / BUILD_ROADMAP Phase 7: "the first
    /// and only time the app asks" -- this app never asks for read access,
    /// PHPicker never required it), renders `items` via renderAll above,
    /// then saves everything to the camera roll via saveAll. Staggers each
    /// asset's creationDate 1 SECOND APART with the FIRST item newest --
    /// Instagram's own picker sorts most-recent-first, so that's what
    /// actually controls the order photos appear there (prd.md §7), and
    /// with no album to search, it's also what makes the post identifiable
    /// as a contiguous block at all (see the MARK above). Dates are
    /// anchored to `Date()` at call time, not backdated, so the photos
    /// don't bury themselves somewhere back in the user's camera roll.
    ///
    /// `expectedCount` is HandoffView's sessionStore.post.count -- the
    /// number of photos the user actually chose. `items` is built via a
    /// compactMap over that post (HandoffView.items) that silently drops
    /// any entry whose photo or variant can't be resolved; without this
    /// check, a resolution failure for even one photo would export
    /// fewer photos than the user expects while still landing on
    /// `.done` -- a quieter version of the exact silent-failure class
    /// this audit is about, even though it isn't caused by a thrown
    /// error at all. `items.isEmpty` is the same failure taken to its
    /// extreme (every photo failed to resolve, or the caller passed
    /// nothing) and is folded into the same check rather than treated
    /// as a separate case, since both mean the same thing: what's about
    /// to be exported doesn't match what the user chose.
    func exportToPhotos(_ items: [Item], expectedCount: Int) async {
        guard !items.isEmpty, items.count == expectedCount else {
            phase = .failed("some of your photos couldn't be prepared for export.")
            return
        }

        phase = .requestingPermission
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else {
            // .limited doesn't meaningfully apply to .addOnly (it's a
            // read-access concept), but treating anything short of
            // .authorized -- .denied, .restricted, .notDetermined after a
            // dismissed prompt, or a future/unexpected case -- as denied
            // is the safe default: never attempt a write duvro doesn't
            // have clear permission for.
            phase = .permissionDenied
            return
        }

        phase = .exporting
        do {
            // Rendered JPEG Data, collected in render order as renderAll
            // produces it -- NOT decoded/rendered image buffers (the
            // ~48MB-per-photo memory risk the previous commit's
            // autoreleasepool guards against). A JPEG at this quality is
            // a few MB; holding up to 20 of them (prd.md's dump-size
            // ceiling) is on the order of tens of MB, nowhere near the
            // decoded-buffer risk -- see saveAll's doc comment for why
            // this collection step exists at all.
            var rendered: [Data] = []
            rendered.reserveCapacity(items.count)
            try await renderAll(items) { _, data in
                rendered.append(data)
            }
            try await Self.saveAll(rendered, referenceDate: Date())
            phase = .done
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Re-runs the same export after a `.failed` state (e.g. a transient
    /// Photos-library error) without re-prompting for permission, which is
    /// already granted at that point.
    func retry(_ items: [Item], expectedCount: Int) async {
        await exportToPhotos(items, expectedCount: expectedCount)
    }

    /// Bare asset creation, straight to the camera roll -- no
    /// PHAssetCollectionChangeRequest, no album, by design (see the MARK
    /// above this section). One PHPhotoLibrary.performChanges transaction
    /// for the whole post: PHAssetCreationRequest.forAsset() doesn't
    /// return anything that needs linking to a collection this time, so
    /// (unlike the album-based version this replaced) there's no
    /// structural reason every asset has to be created in the same
    /// transaction -- it's still batched this way for the same reason as
    /// before: `rendered` is already fully collected in memory by the
    /// time this runs (small JPEG Data, not decoded buffers -- see
    /// exportToPhotos), so there's no memory cost to one transaction over
    /// several, and one transaction is simpler.
    private nonisolated static func saveAll(_ rendered: [Data], referenceDate: Date) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for (index, data) in rendered.enumerated() {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let resourceOptions = PHAssetResourceCreationOptions()
                resourceOptions.uniformTypeIdentifier = UTType.jpeg.identifier
                creationRequest.addResource(with: .photo, data: data, options: resourceOptions)
                // index 0 (carousel position 1) gets the MOST RECENT date
                // -- see exportToPhotos' doc comment.
                creationRequest.creationDate = referenceDate.addingTimeInterval(-Double(index))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let renderError = error as? RenderError, case .renderFailed(let index) = renderError {
            return "photo \(index + 1) couldn't be rendered."
        }
        return error.localizedDescription
    }
}
