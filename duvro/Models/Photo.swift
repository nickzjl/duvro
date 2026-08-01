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
}
