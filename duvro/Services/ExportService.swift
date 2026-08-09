//
//  ExportService.swift
//  duvro
//
//  Phase 7, Task 1: renders the final post at full resolution, one photo
//  at a time, bounded memory, in carousel order, with visible progress.
//  Deliberately knows NOTHING about Photos/PHPhotoLibrary -- `handle` is
//  supplied by the caller (Task 2: saving to the "duvro — ready to post"
//  album) and is called once per rendered photo. This split makes the
//  memory/order/crop guarantees below independently true and
//  independently verifiable (see duvroTests/ExportServiceTests.swift, run
//  entirely on-device-free via the Simulator/synthetic photos) without
//  needing Photos permission or a physical device at all.
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

    // MARK: - Phase 7, Task 2: request permission, find/create the album, save in order

    static let albumName = "duvro — ready to post"

    enum PhotosError: Error {
        case albumCreationFailed
    }

    /// The ONE entry point HandoffView calls. Requests add-only Photos
    /// permission (prd.md §4 step 10 / BUILD_ROADMAP Phase 7: "the first
    /// and only time the app asks" -- this app never asks for read access,
    /// PHPicker never required it), finds or creates "duvro — ready to
    /// post", then renders and saves `items` via renderAll above, staggering
    /// each asset's creationDate 1 SECOND APART with the FIRST item newest
    /// -- Instagram's own picker sorts most-recent-first, so that's what
    /// actually controls the order photos appear there (prd.md §7). Dates
    /// are anchored to `Date()` at call time, not backdated, so the photos
    /// don't bury themselves somewhere back in the user's camera roll.
    func exportToPhotos(_ items: [Item]) async {
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
            let album = try await Self.findOrCreateAlbum(named: Self.albumName)
            let referenceDate = Date()
            try await renderAll(items) { index, data in
                // index 0 (carousel position 1) gets the MOST RECENT date
                // -- see the doc comment above.
                let creationDate = referenceDate.addingTimeInterval(-Double(index))
                try await Self.save(imageData: data, creationDate: creationDate, to: album)
            }
            phase = .done
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Re-runs the same export after a `.failed` state (e.g. a transient
    /// Photos-library error) without re-prompting for permission, which is
    /// already granted at that point.
    func retry(_ items: [Item]) async {
        await exportToPhotos(items)
    }

    private nonisolated static func findOrCreateAlbum(named title: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        if let found = existing.firstObject {
            return found
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let placeholder else { throw PhotosError.albumCreationFailed }
        let created = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
        guard let album = created.firstObject else { throw PhotosError.albumCreationFailed }
        return album
    }

    /// One performChanges transaction per photo (not one batched
    /// transaction for the whole post): keeps this call's only live data
    /// the ONE `imageData` it was handed, consistent with renderAll's
    /// one-photo-at-a-time memory guarantee -- a single big transaction
    /// would need every photo's data alive simultaneously to build it.
    private nonisolated static func save(imageData: Data, creationDate: Date, to album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.uniformTypeIdentifier = UTType.jpeg.identifier
            creationRequest.addResource(with: .photo, data: imageData, options: resourceOptions)
            creationRequest.creationDate = creationDate

            guard
                let albumChangeRequest = PHAssetCollectionChangeRequest(for: album),
                let assetPlaceholder = creationRequest.placeholderForCreatedAsset
            else { return }
            albumChangeRequest.addAssets([assetPlaceholder] as NSArray)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let renderError = error as? RenderError, case .renderFailed(let index) = renderError {
            return "photo \(index + 1) couldn't be rendered."
        }
        if error is PhotosError {
            return "couldn't create the duvro album."
        }
        return error.localizedDescription
    }
}
