//
//  PhotoImportService.swift
//  duvro
//
//  Turns PHPicker results into [Photo]. Every photo is downsampled to <=1280px
//  immediately (originals are copied to a temp store, not held in memory); only
//  small 200px thumbnails stay in memory for the grid. Processing runs with
//  bounded concurrency so we never decode more than a handful of full-size
//  images at once.
//

import Foundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@Observable
@MainActor
final class PhotoImportService {
    private(set) var photos: [Photo] = []
    private(set) var isImporting = false
    private(set) var importedCount = 0
    private(set) var totalCount = 0
    private(set) var peakMemoryMB: Double = 0

    private static let maxConcurrent = 4

    nonisolated private static let tempDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duvro-import", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func reset() {
        photos = []
        importedCount = 0
        totalCount = 0
        peakMemoryMB = 0
    }

    func process(results: [PHPickerResult]) async {
        isImporting = true
        photos = []
        importedCount = 0
        totalCount = results.count
        peakMemoryMB = MemoryMonitor.residentMB()

        let peakTracker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.peakMemoryMB = max(self.peakMemoryMB, MemoryMonitor.residentMB())
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        let providers = results.map(\.itemProvider)

        await withTaskGroup(of: Photo?.self) { group in
            var nextIndex = 0

            func startNext() {
                guard nextIndex < providers.count else { return }
                let provider = providers[nextIndex]
                nextIndex += 1
                group.addTask {
                    await Self.makePhoto(from: provider)
                }
            }

            for _ in 0..<min(Self.maxConcurrent, providers.count) {
                startNext()
            }

            while let photo = await group.next() {
                importedCount += 1
                if let photo {
                    photos.append(photo)
                }
                startNext()
            }
        }

        peakTracker.cancel()
        peakMemoryMB = max(peakMemoryMB, MemoryMonitor.residentMB())
        isImporting = false

        print("[memcheck] peak resident memory: \(String(format: "%.1f", peakMemoryMB)) MB after \(photos.count) photos")
    }

    nonisolated private static func makePhoto(from provider: NSItemProvider) async -> Photo? {
        do {
            let original = try await copyOriginal(from: provider)
            let downsampledURL = tempDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jpg")
            try downsample(imageAt: original, maxPixelSize: 1280, to: downsampledURL)
            let thumbnail = try thumbnailImage(from: downsampledURL, maxPixelSize: 200)
            return Photo(id: UUID(), originalURL: original, downsampledURL: downsampledURL, thumbnail: thumbnail)
        } catch {
            return nil
        }
    }

    nonisolated private static func copyOriginal(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ImportError.noFileRepresentation)
                    return
                }
                do {
                    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                    let destination = tempDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// internal, not private: reused by DebugFixture (Simulator-only debug
    /// tooling, see that file) so it downsamples debug photos identically
    /// to real imports rather than duplicating this logic. Also reused by
    /// EditEngine.renderFullResJPEGData (Phase 7's resolution cap), which
    /// is why this warning started firing on every EXPORTED photo, not
    /// just at import -- same underlying cause, wider surface.
    nonisolated static func downsample(imageAt sourceURL: URL, maxPixelSize: CGFloat, to destinationURL: URL) throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
            throw ImportError.decodeFailed
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ImportError.decodeFailed
        }
        // CGImageSourceCreateThumbnailAtIndex can hand back a CGImage
        // carrying an alpha channel (observed from HEIC sources
        // specifically -- iPhone's default photo format) even though the
        // content is fully opaque -- JPEG has no alpha support at all, so
        // encoding that image straight through CGImageDestinationFinalize
        // below triggers ImageIO's own "trying to save an opaque image
        // with 'AlphaPremulLast'... will double (!!!) the required memory
        // when decoding" warning, on every downsample -- which after this
        // function became export's resolution-cap step too (see the doc
        // comment above), meant on every exported photo. Re-drawing into
        // an explicitly opaque bitmap context (.noneSkipLast: no alpha,
        // 8 bits/component -- matching what the source image actually
        // is) before encoding is the standard fix: harmless if the source
        // was already opaque, strips the unnecessary channel if it wasn't.
        let opaqueImage = makeOpaque(cgImage) ?? cgImage
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.encodeFailed
        }
        CGImageDestinationAddImage(destination, opaqueImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImportError.encodeFailed
        }
    }

    /// Re-draws `cgImage` into a bitmap context with no alpha channel.
    /// nil (falls back to the original, unmodified image at the call
    /// site above -- this is a quality-of-encoding fix, not something
    /// worth failing the whole downsample over) if the color space is
    /// missing or context creation fails for any reason.
    nonisolated private static func makeOpaque(_ cgImage: CGImage) -> CGImage? {
        guard let colorSpace = cgImage.colorSpace else { return nil }
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context.makeImage()
    }

    /// internal, not private: see the note on `downsample` above.
    nonisolated static func thumbnailImage(from sourceURL: URL, maxPixelSize: CGFloat) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
            throw ImportError.decodeFailed
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ImportError.decodeFailed
        }
        return UIImage(cgImage: cgImage)
    }

    private enum ImportError: Error {
        case noFileRepresentation
        case decodeFailed
        case encodeFailed
    }
}
