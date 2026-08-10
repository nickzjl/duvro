//
//  MemoryMonitor.swift
//  duvro
//
//  Debug instrumentation for the Phase 1 memory acceptance check
//  ("import 200 photos, memory stays < 400MB"). Not user-facing.
//
//  nonisolated: residentMB() is a pure, stateless syscall wrapper (no
//  actor-isolated state at all) -- SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor would otherwise isolate it by default (same fix pattern as
//  EditEngine/CompositeScoring/ClusteringService/ShortlistService). Every
//  existing caller (PhotoImportService's peak tracker, ScoringService,
//  ExportService.renderAll's own peak tracker) happened to already run on
//  MainActor, so this went unnoticed until ExportService.renderAll started
//  calling it from inside a Task.detached closure (measuring memory
//  immediately around EditEngine.clearRenderCaches(), which has to run
//  alongside the render itself, off the main actor) -- that call site
//  surfaced the missing annotation as a warning rather than silently
//  working by accident.
//

import Foundation

nonisolated enum MemoryMonitor {
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
}
