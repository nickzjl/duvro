//
//  NetworkMonitor.swift
//  duvro
//
//  Phase 10: honest "no connection" messaging needs a real signal, not a
//  guess -- this wraps NWPathMonitor (Apple's own connectivity API, no
//  third-party dependency, matching CLAUDE.md's zero-dependency stack) as
//  a small @Observable service any screen can read.
//
//  Currently consumed by CaptionView only (BUILD_ROADMAP Phase 10's "no
//  network -- for the caption screen"). CaptionService's only
//  implementation today (TemplateCaptionService) already works with or
//  without a connection -- there is no live network-backed caption
//  endpoint yet (see that file's own header) -- so this never blocks or
//  changes what caption comes back; it only lets the UI say, honestly,
//  when the device itself has no connection, rather than staying silent
//  about it. Once Phase 9's real network endpoint exists, this same
//  signal becomes the thing that decides whether to attempt it at all.
//

import Foundation
import Network

@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isConnected = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.duvro.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
