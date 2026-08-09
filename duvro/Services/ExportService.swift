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

    // MARK: - Phase 7, Task 2: request permission, create the album, save in order

    static let albumName = "duvro — ready to post"

    /// The ONE entry point HandoffView calls. Requests add-only Photos
    /// permission (prd.md §4 step 10 / BUILD_ROADMAP Phase 7: "the first
    /// and only time the app asks" -- this app never asks for read access,
    /// PHPicker never required it), renders `items` via renderAll above,
    /// then saves everything into a freshly created "duvro — ready to
    /// post" album in ONE PHPhotoLibrary transaction (see saveAll's doc
    /// comment for why it can't look for an existing album first -- that
    /// was this function's crash, on-device, fixed in this commit).
    /// Staggers each asset's creationDate 1 SECOND APART with the FIRST
    /// item newest -- Instagram's own picker sorts most-recent-first, so
    /// that's what actually controls the order photos appear there
    /// (prd.md §7). Dates are anchored to `Date()` at call time, not
    /// backdated, so the photos don't bury themselves somewhere back in
    /// the user's camera roll.
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
            try await Self.saveAll(rendered, referenceDate: Date(), albumTitle: Self.albumName)
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

    /// ONE PHPhotoLibrary.performChanges transaction creates "duvro —
    /// ready to post" AND every asset in `rendered`, linking them via
    /// placeholders entirely within that single transaction.
    ///
    /// NOT a style choice -- this replaces a previous version that first
    /// tried PHAssetCollection.fetchAssetCollections(...) to find an
    /// existing album by title before creating one, and crashed on
    /// device immediately after the user granted permission ("attempted
    /// to access privacy-sensitive data without a usage description...
    /// NSPhotoLibraryUsageDescription"). PHAccessLevel.addOnly grants
    /// ZERO read access to the library -- ANY PHFetchRequest-family call
    /// (fetchAssetCollections, fetchAssets, even re-fetching a
    /// collection this app JUST created by its own local identifier)
    /// requires full-library NSPhotoLibraryUsageDescription, which this
    /// app deliberately never declares (CLAUDE.md's privacy
    /// architecture: add-only at export and nothing else -- the welcome
    /// screen's privacy claim depends on it, and adding that key would
    /// silence this crash by breaking that promise instead of fixing
    /// the actual bug).
    ///
    /// The only way to reference a Photos collection WITHOUT fetching it
    /// is the PHAssetCollectionChangeRequest object returned at the
    /// moment it's created -- and that's only valid inside the
    /// transaction that created it. It can't be stored and reused by a
    /// later, separate performChanges call (which is what per-photo
    /// transactions would need). So every asset that should land in the
    /// album has to be created in the SAME transaction as the album
    /// itself.
    ///
    /// REAL CONSEQUENCE, not a bug: this can never find and reuse an
    /// album from a previous export -- every export creates a NEW album.
    /// Photos permits duplicate album names, so a user who exports more
    /// than once ends up with multiple albums all titled "duvro — ready
    /// to post," one per export, rather than one that accumulates.
    /// There is no fetch-free way to avoid this under add-only-only
    /// permission; the alternative would be requesting full read/write
    /// access, which this app deliberately does not do.
    private nonisolated static func saveAll(_ rendered: [Data], referenceDate: Date, albumTitle: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            var placeholders: [PHObjectPlaceholder] = []
            for (index, data) in rendered.enumerated() {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let resourceOptions = PHAssetResourceCreationOptions()
                resourceOptions.uniformTypeIdentifier = UTType.jpeg.identifier
                creationRequest.addResource(with: .photo, data: data, options: resourceOptions)
                // index 0 (carousel position 1) gets the MOST RECENT date
                // -- see exportToPhotos' doc comment.
                creationRequest.creationDate = referenceDate.addingTimeInterval(-Double(index))
                if let placeholder = creationRequest.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                }
            }
            albumRequest.addAssets(placeholders as NSFastEnumeration)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let renderError = error as? RenderError, case .renderFailed(let index) = renderError {
            return "photo \(index + 1) couldn't be rendered."
        }
        return error.localizedDescription
    }
}
