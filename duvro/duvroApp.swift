//
//  duvroApp.swift
//  duvro
//
//  Created by Nick Zhao on 8/1/26.
//

import SwiftUI

@main
struct duvroApp: App {
    var body: some Scene {
        WindowGroup {
            // TEMPORARY (item 14, Aug 1 2026 session): showing the Newsreader
            // opsz comparison so it can be screenshotted. Revert to ImportView()
            // once a cut is picked -- see FontComparisonView.swift.
            FontComparisonView()
        }
    }
}
