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
}
