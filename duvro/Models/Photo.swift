//
//  Photo.swift
//  duvro
//

import UIKit

struct Photo: Identifiable {
    let id: UUID
    /// Full-resolution copy of the picked asset, as delivered by PHPicker. Used once, at export.
    let originalURL: URL
    /// ≤1280px longest side. Used for all scoring and in-app preview work.
    let downsampledURL: URL
    /// ≤200px longest side, kept in memory for grid display.
    let thumbnail: UIImage
    /// EXIF DateTimeOriginal (or TIFF DateTime), read at import time via
    /// PhotoImportService.captureDate(from:). nil when the source photo
    /// carries neither tag -- PHPicker delivers files as-is, so this can't
    /// be backfilled after import; a photo imported without one stays nil
    /// for its whole life in this session. Optional, not defaulted to
    /// "now," so callers (currently just EditEngine's Y2K date stamp) can
    /// tell "no real capture date" apart from "captured this instant."
    let captureDate: Date?

    init(id: UUID, originalURL: URL, downsampledURL: URL, thumbnail: UIImage, captureDate: Date? = nil) {
        self.id = id
        self.originalURL = originalURL
        self.downsampledURL = downsampledURL
        self.thumbnail = thumbnail
        self.captureDate = captureDate
    }
}
