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
import ImageIO
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
            #if DEBUG
            let beforeMB = MemoryMonitor.residentMB()
            // Candidate 1 (per instruction): are later photos physically
            // larger source files or different pixel dimensions than
            // earlier ones? File size via FileManager, pixel dimensions
            // + EXIF orientation via CGImageSourceCopyProperties -- both
            // metadata-only reads, no decode, so this doesn't itself
            // perturb the memory numbers being measured.
            print("[export] photo \(index + 1)/\(items.count) source: \(Self.sourceImageInfo(for: item.photo.originalURL))")
            #endif

            // Off the main actor (CIContext work is CPU-bound and
            // shouldn't block the progress UI), autoreleasepool-wrapped
            // (the memory guarantee for OBJECTIVE-C AUTORELEASED
            // intermediates -- Image I/O and CoreImage both autorelease
            // internally, and without this those buffers can live until
            // the surrounding Task exits rather than being freed between
            // photos). autoreleasepool alone was NOT sufficient on
            // device even after the resolution cap and a fresh
            // per-render CIContext -- for the FULL story on why a fresh
            // context replaced the shared one specifically for this
            // call (clearCaches() measured exactly +0.0MB, every time,
            // on the expensive photos -- proof the retained memory
            // wasn't in what that method targets), see
            // renderFullResJPEGData's doc comment in EditEngine.swift.
            let data: Data? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    EditEngine.renderFullResJPEGData(photo: item.photo, variant: item.variant)
                }
            }.value

            guard let data else { throw RenderError.renderFailed(index: index) }

            #if DEBUG
            print("[export] photo \(index + 1) rendered JPEG: \(data.count / 1024)KB")
            #endif

            try await handle(index, data)
            exportedCount = index + 1

            #if DEBUG
            // Per-photo delta, not just the running peak -- shows
            // whether memory now stays roughly flat photo to photo
            // (the resolution cap and fresh per-render context both
            // landed) or still climbs (either fix incomplete, or a
            // third factor neither accounts for).
            let afterMB = MemoryMonitor.residentMB()
            print("[export] photo \(index + 1)/\(items.count): \(String(format: "%.1f", beforeMB))MB -> \(String(format: "%.1f", afterMB))MB (Δ\(String(format: "%+.1f", afterMB - beforeMB))MB)")
            #endif
        }

        peakMemoryMB = max(peakMemoryMB, MemoryMonitor.residentMB())
        #if DEBUG
        print("[export] peak resident memory: \(String(format: "%.1f", peakMemoryMB)) MB across \(items.count) photos")
        #endif
    }

    #if DEBUG
    /// Diagnostic only -- metadata reads (file size via FileManager,
    /// pixel dimensions + EXIF orientation via
    /// CGImageSourceCopyPropertiesAtIndex), no decode. Answers candidate
    /// 1: are the photos where memory jumps physically larger files or
    /// different pixel dimensions than the ones before them.
    private nonisolated static func sourceImageInfo(for url: URL) -> String {
        var parts: [String] = []
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let byteCount = attributes[.size] as? Int {
            parts.append("\(byteCount / 1024)KB")
        } else {
            parts.append("size unknown")
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int
            let height = properties[kCGImagePropertyPixelHeight] as? Int
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            if let width, let height {
                parts.append("\(width)x\(height)px raw, EXIF orientation \(orientation)")
            } else {
                parts.append("dimensions unknown")
            }
        } else {
            parts.append("dimensions unknown")
        }
        return parts.joined(separator: ", ")
    }
    #endif

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
    /// else is there, so making them the N most recent, contiguous
    /// assets is load-bearing, not decorative. HandoffView's copy
    /// reflects this ("select the N most recent photos, tap them in
    /// order") -- deliberately silent on which end is newest, since that
    /// part turned out to be exactly what was wrong here (see
    /// exportToPhotos' doc comment) and the copy never needed to commit
    /// to it either way.

    /// The ONE entry point HandoffView calls. Requests add-only Photos
    /// permission (prd.md §4 step 10 / BUILD_ROADMAP Phase 7: "the first
    /// and only time the app asks" -- this app never asks for read access,
    /// PHPicker never required it), renders `items` via renderAll above,
    /// then saves everything to the camera roll via saveAll. Staggers each
    /// asset's creationDate 1 SECOND APART with the LAST item newest --
    /// see saveAll's `secondsBeforeNewest` for the actual formula. This
    /// was inverted (first item used to get the newest date) after
    /// on-device testing: the FIRST item being newest was based on an
    /// ASSUMED "Instagram's picker sorts most-recent-first" that turned
    /// out to be backwards -- verified on device, the picker actually
    /// showed the LAST-saved photo (whichever had the highest
    /// creationDate) first, so the post's photo 1 (which needs to appear
    /// first when the user taps through the picker) has to be the OLDEST
    /// of the batch, not the newest. With no album to search, this
    /// ordering is still what makes the post identifiable as a
    /// contiguous block at all (see the MARK above) -- only WHICH END is
    /// newest changed, not that they're staggered and contiguous. Dates
    /// are anchored to `Date()` at call time (the newest one, now the
    /// LAST item, sits exactly at `Date()`), not backdated, so the
    /// photos don't bury themselves somewhere back in the user's camera
    /// roll.
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
    /// GUARD, added after 14 assets appeared in the camera roll for a
    /// 7-photo post -- every one an exact duplicate. Could not find a
    /// structural double-call in this file (grepped the whole app: one
    /// exportToPhotos call site -- HandoffView's .task -- one renderAll
    /// call site, one saveAll call site, one performChanges call site;
    /// none of them loop or call each other more than once as written).
    /// Two remaining candidates, neither ruled out with certainty: (a)
    /// PHPhotoLibrary.performChanges is documented as possibly invoking
    /// its change block more than once to resolve a write conflict --
    /// but that's meant for changes that depend on existing state
    /// (retrying a conflicting edit), and saveAll's block is
    /// unconditional creation with nothing to conflict with, which
    /// makes this an imperfect fit, not a confirmed one; (b) something
    /// causes this function to be entered twice for one export attempt
    /// -- a duplicate `.task` firing, a retry racing an in-flight call,
    /// or a mechanism not yet identified. This guard defends against
    /// (b) unconditionally, regardless of which it turns out to be:
    /// re-entry is refused while a call is already in flight
    /// (.requestingPermission/.exporting) or has already finished
    /// (.done -- nothing legitimate re-triggers export after success).
    /// Starting fresh from .idle, or explicitly retrying from
    /// .permissionDenied/.failed, is unaffected. If duplicates STILL
    /// appear after this ships, that rules out (b) and narrows this
    /// down to (a) -- worth knowing either way, hence the print below
    /// staying in place rather than being removed once this guard
    /// exists.
    func exportToPhotos(_ items: [Item], expectedCount: Int) async {
        switch phase {
        case .requestingPermission, .exporting, .done:
            #if DEBUG
            print("[export] exportToPhotos called again while phase == \(phase) -- refused, not starting a second export")
            #endif
            return
        case .idle, .permissionDenied, .failed:
            break
        }

        #if DEBUG
        print("[export] exportToPhotos starting -- \(items.count) items")
        #endif

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
            try await renderAll(items) { index, data in
                rendered.append(data)
                #if DEBUG
                // Candidate 3 (per instruction): is the save path itself
                // what's accumulating -- holding every rendered JPEG in
                // this array until saveAll runs at the end, rather than
                // writing and releasing each one as it's produced. This
                // is the running total of exactly what `rendered` is
                // holding at this point, independent of whatever
                // renderAll's own before/after prints show for the
                // render step itself -- if THIS number climbs in step
                // with the memory jumps, the array is the culprit; if it
                // stays small (a few MB total) while memory still jumps,
                // it isn't.
                let cumulativeKB = rendered.reduce(0) { $0 + $1.count } / 1024
                print("[export] rendered[] after photo \(index + 1): \(rendered.count) items held, \(cumulativeKB)KB cumulative")
                #endif
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
        #if DEBUG
        // Diagnostic, separate from exportToPhotos' phase guard: that
        // guard defends against this FUNCTION being entered twice; this
        // counter instead checks whether performChanges invokes its
        // change block more than once WITHIN a single call here --
        // Apple documents performChanges as possibly retrying its block
        // to resolve a write conflict, which would explain 14 assets
        // for a 7-photo post without exportToPhotos ever being called
        // twice at all. A plain class (not a struct/local var) so the
        // closure below -- which performChanges may invoke on a queue
        // other than this one -- shares the SAME counter instance
        // across however many times it's actually called.
        //
        // NOTE: an earlier version of this diagnostic also fetched the
        // just-created assets back via PHAsset.fetchAssets(withLocalIdentifiers:)
        // to log their persisted creationDate. REMOVED -- that fetch is a
        // Photos-library READ, and .addOnly authorization grants no read
        // access at all. On device it crashed with "attempted to access
        // privacy-sensitive data without a usage description," which
        // NSPhotoLibraryUsageDescription would fix but CLAUDE.md's privacy
        // architecture (add-only, at export, no read access ever) rules
        // out adding. The "created 0 asset(s)" log line that preceded the
        // crash was the fetch failing, not the save -- the assets almost
        // certainly saved fine before the app died confirming it. Nothing
        // in this file may call any PHAsset/PHFetchResult/PHImageManager
        // read API; if the Instagram-picker-order investigation needs to
        // confirm persisted creationDates again, it has to be done by
        // inspecting the camera roll by hand, not by reading it back here.
        final class InvocationCounter: @unchecked Sendable { var count = 0 }
        let counter = InvocationCounter()
        #endif

        try await PHPhotoLibrary.shared().performChanges {
            #if DEBUG
            counter.count += 1
            print("[export] saveAll's performChanges block invoked (call #\(counter.count)) -- creating \(rendered.count) assets")
            #endif
            for (index, data) in rendered.enumerated() {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let resourceOptions = PHAssetResourceCreationOptions()
                resourceOptions.uniformTypeIdentifier = UTType.jpeg.identifier
                creationRequest.addResource(with: .photo, data: data, options: resourceOptions)
                creationRequest.creationDate = Self.creationDate(forIndex: index, count: rendered.count, referenceDate: referenceDate)
            }
        }

        #if DEBUG
        if counter.count > 1 {
            print("[export] WARNING: performChanges invoked its change block \(counter.count) times for ONE saveAll call -- this is almost certainly why duplicates appeared in the camera roll")
        } else {
            print("[export] saveAll's performChanges completed -- \(rendered.count) asset(s) requested, block invoked \(counter.count) time(s)")
        }
        #endif
    }

    /// Pure and separately testable on purpose -- this exact formula was
    /// wrong once already (the first version handed index 0 the newest
    /// date, backwards, per an assumption about Instagram's picker order
    /// that turned out to be false; see exportToPhotos' doc comment for
    /// the on-device correction). `internal`, not `private`, specifically
    /// so a unit test can call it directly without touching
    /// PHPhotoLibrary at all.
    ///
    /// index 0 (carousel position 1, the post's first photo) gets the
    /// OLDEST date; the LAST index gets `referenceDate` itself, i.e. the
    /// newest. Verified on device: Instagram's picker shows the
    /// highest-creationDate asset first, so the photo that needs to
    /// appear first when the user taps through the picker has to be the
    /// OLDEST of the batch, not the newest.
    nonisolated static func creationDate(forIndex index: Int, count: Int, referenceDate: Date) -> Date {
        let secondsBeforeNewest = Double(max(count - 1 - index, 0))
        return referenceDate.addingTimeInterval(-secondsBeforeNewest)
    }

    private static func describe(_ error: Error) -> String {
        if let renderError = error as? RenderError, case .renderFailed(let index) = renderError {
            return "photo \(index + 1) couldn't be rendered."
        }
        return error.localizedDescription
    }
}
