//
//  CurationService.swift
//  duvro
//
//  Phase 3.5's Stage 2 selection: the app-side call to the curation
//  endpoint (duvro-api.vercel.app/api/curate -- a Vercel serverless
//  function proxying the Claude API; shared infrastructure with Phase 9's
//  caption generation, which rides along in the SAME response rather than
//  a second call -- see `captions` below). Called by CurationSequenceView
//  after Stage 1 shortlisting; on success, its result REPLACES the
//  shortlist as the session's chosen set. FallbackSelectionService
//  remains the offline/failure path, unchanged -- see `curate`'s own doc
//  comment for the exact failure contract.
//
//  `nonisolated enum` with static functions, matching
//  ShortlistService/FallbackSelectionService/RunnerUpService's own
//  convention for stateless pipeline steps -- unlike PhotoImportService/
//  ScoringService/ExportService, this is ONE atomic network round-trip
//  with no per-item progress to publish, so there's no need for an
//  @Observable class here.
//
//  REQUEST/RESPONSE SHAPES verified against the LIVE endpoint this
//  session, not guessed from the spec alone: a throwaway synthetic-photo
//  request confirmed the exact success envelope (aesthetic/tier/
//  postConcept/selectedCount/insufficientStrongPhotos/carousel/
//  alternates/captions, all present, types as declared below) and the
//  exact error envelope ({error, code, details?}). One finding that
//  wasn't in the spec and would have shipped wrong without this check:
//  `metrics.timestamp` REJECTS both `null` and a missing key -- the
//  endpoint requires an ISO 8601 string or numeric epoch for every photo,
//  with no "no timestamp available" case. `photo.captureDate ?? Date()`
//  below is the fallback -- same "no real capture date, fall back to
//  now" convention EditEngine's own Y2K date stamp already uses for the
//  identical situation. A second finding, same check: `metrics.width`/
//  `height` reject null/missing the SAME way ("must be an integer >=
//  1") -- unlike timestamp, there's no honest fallback value for a
//  dimension that couldn't be read, so buildPayload drops that one
//  candidate from the request entirely rather than sending a fabricated
//  width/height (see that function's own doc comment).
//
//  NETWORK RESILIENCE (added after the first real device run): a first
//  on-device attempt failed because iOS's cellular-permission dialog
//  appeared WHILE the curation request was in flight -- the OS cancels
//  a request out from under URLSession when that happens, and by the
//  time the dialog was dismissed FallbackSelectionService had already
//  run. Two-sided fix: `performRequest` retries once, after a short
//  delay, on any network-class failure (a thrown error before an HTTP
//  response ever arrived -- NOT a non-200 status, which already got a
//  definitive answer and won't succeed twice); and
//  `prewarmCellularPermission`, called by ImportView the moment import
//  finishes, fires a tiny discarded request specifically to get that
//  dialog out of the way early, while the user is still browsing vibe
//  packs. The retry is the safety net; the prewarm is the actual fix.
//

import Foundation

nonisolated enum CurationService {
    static let endpointURL = URL(string: "https://duvro-api.vercel.app/api/curate")!

    /// Premium isn't built -- "basic" always, for now -- but a parameter
    /// at every call site, not a literal baked into request-building, so
    /// a future premium tier slots in without touching this file.
    enum Tier: String {
        case basic
        // premium: not built yet
    }

    /// Anthropic's own per-request image limit. The shortlist is ~30, so
    /// this shouldn't bind in practice -- guarded explicitly rather than
    /// trusting that stays true.
    static let maxPhotosPerRequest = 100

    /// Thumbnails are downsampled to this before base64 encoding --
    /// deliberately NOT the 1280px working copies (token cost scales
    /// with pixel count, per the spec), and not the original either
    /// (same reason, worse).
    private static let thumbnailMaxPixelSize: CGFloat = 512

    /// One retry on a network-class failure (see `performRequest`) --
    /// the incident that motivated this: iOS's cellular-permission
    /// dialog appeared WHILE a curation request was in flight, which
    /// cancels the request out from under URLSession; by the time the
    /// dialog was dismissed, FallbackSelectionService had already run.
    /// A short-delayed retry catches that window, and covers ordinary
    /// flakiness the same way. `prewarmCellularPermission` below
    /// addresses the same incident from the other side -- getting the
    /// dialog to appear well before curation ever starts, so this retry
    /// is a safety net, not the primary fix.
    private static let maxNetworkRetries = 1
    private static let networkRetryDelay: Duration = .seconds(2)

    // MARK: - Result

    struct Result {
        /// Carousel order, resolved to PhotoScore -- IS the posting
        /// order (the model's own ranking); callers use it directly,
        /// never re-sort it. Can be EMPTY -- see `curate`'s own doc
        /// comment on `insufficientStrongPhotos`, a valid outcome, not
        /// a failure.
        let selected: [PhotoScore]
        /// Photo id -> role ("hero", "portrait", "outfit", "candid",
        /// "social", "place", "food", "detail", "atmosphere"). Stored
        /// for the showcase/debug views to consume; not consumed by
        /// either this session, per instruction ("Store it... can use
        /// it").
        let roles: [UUID: String]
        /// Resolved runner-ups -- the "swap"/"extension" alternates,
        /// filtered to photos that actually resolve to a known
        /// PhotoScore, with "extension" entries dropped once the
        /// carousel is already at 10 (nothing for an extension to add
        /// to there). This is what FinalReviewView's EXISTING "what we
        /// left out" row reads (SessionStore.runnerUps, unchanged) --
        /// same shape FallbackSelectionService's own runner-up path
        /// already produces, so nothing downstream needed to change.
        let runnerUps: [PhotoScore]
        /// Richer per-alternate metadata (type/replaceID/role/reason),
        /// keyed by photo id -- the detail behind `runnerUps` above,
        /// for a future debug view; not consumed by either this
        /// session.
        let alternateInfo: [UUID: AlternateInfo]
        /// Rank-ordered caption suggestions, 1-5. Wired into CaptionView
        /// via CurationCaptionService (CaptionService.swift) -- fetched
        /// ONCE here, alongside the selection, not re-fetched when the
        /// user actually reaches the caption screen later in the flow.
        let captions: [String]
    }

    struct AlternateInfo {
        let type: String // "swap" | "extension"
        let replaceID: UUID?
        let role: String?
        let reason: String?
    }

    /// Distinguishes WHY a call failed -- surfaced in DEBUG only (per
    /// instruction: "the user just sees the fallback happening"). Every
    /// case means the exact same thing to the caller (curate() returns
    /// nil; FallbackSelectionService runs instead) -- this only changes
    /// what gets printed, so a validation failure (a request-building
    /// bug on this end) can be told apart from an upstream API failure
    /// or a genuine timeout without needing a debugger attached.
    private enum FailureReason {
        case network(Error)
        case timeout
        case nonSuccessStatus(Int, code: String?, message: String?, details: [String]?)
        case malformedResponse(Error)
    }

    // MARK: - The call

    /// `candidates` are (score, photo) pairs the caller has already
    /// resolved -- CurationSequenceView already does this same
    /// sessionStore.photo(for:) lookup for rendering, so resolving once
    /// and passing pairs in avoids a second, actor-hopping lookup pass
    /// here. `clusterID` is ShortlistService's own output (clusterID
    /// isn't on PhotoScore itself -- it's a cross-photo clustering
    /// result, not a per-photo Vision signal).
    ///
    /// Returns nil ONLY on actual failure -- network error, timeout,
    /// non-200 status, or a response that doesn't decode. A SUCCESSFUL
    /// call that found nothing worth curating (`insufficientStrongPhotos:
    /// true`, `carousel: []` -- confirmed live as a real 200 response,
    /// not a hypothetical) returns a non-nil Result with an EMPTY
    /// `selected` -- callers must treat that as "route to the empty
    /// state," not as "fall back to on-device selection": the model
    /// already judged this batch and found it wanting, so running
    /// FallbackSelectionService instead would show a post the model
    /// itself already rejected.
    static func curate(
        candidates: [(score: PhotoScore, photo: Photo)],
        clusterID: [UUID: Int],
        tier: Tier = .basic,
        vibePack: String
    ) async -> Result? {
        let trimmed = Array(candidates.prefix(maxPhotosPerRequest))
        guard !trimmed.isEmpty else { return nil }

        let photos = await buildPayload(trimmed, clusterID: clusterID)
        guard !photos.isEmpty else {
            #if DEBUG
            print("[curation] no photo thumbnails could be encoded -- skipping the call entirely")
            #endif
            return nil
        }

        let body = RequestBody(photos: photos, tier: tier.rawValue, vibePack: vibePack)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The endpoint itself takes 20-45s (per spec, confirmed live: a
        // 3-photo synthetic-image test round-tripped in ~3.5s, but that
        // was an early insufficientStrongPhotos short-circuit, not a
        // full curation run) -- leave real headroom above that rather
        // than racing it.
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            logFailure(.malformedResponse(error), vibePack: vibePack, photoCount: photos.count)
            return nil
        }

        guard let (data, httpResponse) = await performRequest(request, vibePack: vibePack, photoCount: photos.count) else {
            return nil
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data)
            logFailure(
                .nonSuccessStatus(httpResponse.statusCode, code: errorBody?.code, message: errorBody?.error, details: errorBody?.details),
                vibePack: vibePack,
                photoCount: photos.count
            )
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            #if DEBUG
            print("[curation] success -- tier=\(decoded.tier) postConcept=\(decoded.postConcept) selectedCount=\(decoded.selectedCount) insufficientStrongPhotos=\(decoded.insufficientStrongPhotos) carousel=\(decoded.carousel.count) alternates=\(decoded.alternates.count) captions=\(decoded.captions.count)")
            #endif
            return resolve(decoded, candidates: trimmed)
        } catch {
            logFailure(.malformedResponse(error), vibePack: vibePack, photoCount: photos.count)
            return nil
        }
    }

    /// Retries ONLY a network-class failure -- a thrown error from
    /// `URLSession.data(for:)` means the request never reached the
    /// server at all (no connectivity, DNS failure, connection lost,
    /// timed out, cancelled mid-flight by the OS -- see the cellular-
    /// permission incident in maxNetworkRetries' own doc comment), so a
    /// second attempt has a real chance of succeeding. Deliberately does
    /// NOT retry a non-200 HTTP response (validation errors, 502s) --
    /// those already reached the server and got a definitive answer;
    /// `curate` handles that status check itself, on whatever this
    /// returns. The stray "response wasn't even HTTP" cast failure is
    /// also left un-retried -- not a thrown network error, and not a
    /// case expected to occur against an https:// endpoint in practice.
    private static func performRequest(
        _ request: URLRequest,
        vibePack: String,
        photoCount: Int
    ) async -> (Data, HTTPURLResponse)? {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    logFailure(.network(URLError(.badServerResponse)), vibePack: vibePack, photoCount: photoCount)
                    return nil
                }
                return (data, httpResponse)
            } catch {
                guard attempt < maxNetworkRetries else {
                    let isTimeout = (error as? URLError)?.code == .timedOut
                    logFailure(isTimeout ? .timeout : .network(error), vibePack: vibePack, photoCount: photoCount)
                    return nil
                }
                attempt += 1
                #if DEBUG
                print("[curation] network-class failure (\(error.localizedDescription)) -- retrying once after \(networkRetryDelay)")
                #endif
                try? await Task.sleep(for: networkRetryDelay)
            }
        }
    }

    // MARK: - Request building

    private static let isoFormatter = ISO8601DateFormatter()

    /// Skips any candidate missing a base64-encodable thumbnail OR real
    /// width/height -- confirmed LIVE against the endpoint, not assumed
    /// from the spec: `metrics.width`/`height` reject `null` exactly like
    /// `timestamp` does ("must be an integer >= 1"), so a PhotoScore
    /// whose dimensions couldn't be read (width/height nil -- see that
    /// property's own doc comment) has nothing valid to send. This is
    /// the one metric with no "no real capture date, fall back to now"-
    /// style fallback available -- there's no honest placeholder width/
    /// height the way `Date()` is an honest placeholder timestamp, so
    /// the photo is dropped from THIS call rather than sent with
    /// fabricated dimensions. Rare on the real PHPicker import path (see
    /// PhotoScore.width's own doc comment on when ImageIO's metadata
    /// read fails); the one path that hits this on EVERY photo is
    /// DebugFixture, which never populates width/height at all -- see
    /// the session report on that gap.
    private static func buildPayload(
        _ candidates: [(score: PhotoScore, photo: Photo)],
        clusterID: [UUID: Int]
    ) async -> [RequestBody.Photo] {
        await withTaskGroup(of: RequestBody.Photo?.self) { group in
            for (score, photo) in candidates {
                guard let width = score.width, let height = score.height else { continue }
                group.addTask {
                    guard let thumbnailBase64 = encodeThumbnail(from: photo.downsampledURL) else { return nil }
                    let metrics = RequestBody.Metrics(
                        category: score.category.rawValue,
                        faceCount: score.faceCount,
                        faceQuality: score.bestFaceQuality,
                        largestFaceAreaRatio: score.largestFaceAreaRatio,
                        clusterID: clusterID[score.id] ?? score.id.hashValue,
                        timestamp: isoFormatter.string(from: photo.captureDate ?? Date()),
                        width: width,
                        height: height
                    )
                    return RequestBody.Photo(id: score.id.uuidString, thumbnail: thumbnailBase64, metrics: metrics)
                }
            }
            var results: [RequestBody.Photo] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }

    /// Reuses PhotoImportService.downsample (the same Image I/O thumbnail
    /// generator every other downsample in this app goes through, EXIF-
    /// orientation-transform included -- see that function's own doc
    /// comment) rather than a second resize implementation. Source is
    /// the ALREADY-<=1280px downsampledURL, not the original -- a
    /// further downsample from there is cheap, and the original's real
    /// resolution has no bearing on what a 512px thumbnail needs.
    nonisolated private static func encodeThumbnail(from downsampledURL: URL) -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-curation-thumb-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try PhotoImportService.downsample(imageAt: downsampledURL, maxPixelSize: thumbnailMaxPixelSize, to: tempURL)
            let data = try Data(contentsOf: tempURL)
            return data.base64EncodedString()
        } catch {
            return nil
        }
    }

    // MARK: - Cellular-permission prewarm

    /// iOS shows its one-time "Allow Cellular Data?" dialog on the app's
    /// FIRST cellular network request -- there's no API to request it
    /// directly. ImportView calls this once, the moment import
    /// finishes, so the dialog appears while the user is browsing vibe
    /// packs rather than mid-curation, where it previously cancelled a
    /// real curation request out from under URLSession (see
    /// maxNetworkRetries' own doc comment for the incident this and
    /// that retry both address, from opposite ends). A HEAD request to
    /// the curation endpoint itself, not an unrelated host -- this also
    /// warms DNS/TLS for the same host the real call hits shortly
    /// after. Both the result and any error are discarded by design;
    /// this exists purely for its side effect on the OS's permission
    /// state, never for anything in its response.
    static func prewarmCellularPermission() async {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Response resolution

    /// `decoded.carousel`'s own order is preserved end to end -- compactMap
    /// over it in order, never sorted or re-ranked. `carouselIsFull` uses
    /// 10, not `count` (the user's requested photo count): the model
    /// decides carousel length itself (4-10, per spec -- there is no
    /// count field in the request), so 10 is the model's own hard
    /// ceiling, not whatever the user asked for.
    private static func resolve(_ decoded: ResponseBody, candidates: [(score: PhotoScore, photo: Photo)]) -> Result {
        let scoresByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.score.id.uuidString, $0.score) })

        let selected = decoded.carousel.compactMap { scoresByID[$0.id] }

        var roles: [UUID: String] = [:]
        for entry in decoded.carousel {
            guard let uuid = UUID(uuidString: entry.id) else { continue }
            roles[uuid] = entry.role
        }

        let carouselIsFull = selected.count >= 10
        var runnerUps: [PhotoScore] = []
        var alternateInfo: [UUID: AlternateInfo] = [:]
        for entry in decoded.alternates {
            guard entry.type != "extension" || !carouselIsFull else { continue }
            guard let uuid = UUID(uuidString: entry.id), let score = scoresByID[entry.id] else { continue }
            runnerUps.append(score)
            alternateInfo[uuid] = AlternateInfo(
                type: entry.type,
                replaceID: entry.replaceId.flatMap(UUID.init(uuidString:)),
                role: entry.role,
                reason: entry.reason
            )
        }

        let captions = decoded.captions.sorted { $0.rank < $1.rank }.map(\.text)

        return Result(selected: selected, roles: roles, runnerUps: runnerUps, alternateInfo: alternateInfo, captions: captions)
    }

    // MARK: - Failure logging (DEBUG only -- callers just see the fallback)

    private static func logFailure(_ reason: FailureReason, vibePack: String, photoCount: Int) {
        #if DEBUG
        let description: String
        switch reason {
        case .network(let error):
            description = "NETWORK error: \(error.localizedDescription)"
        case .timeout:
            description = "TIMEOUT (>\(60)s)"
        case .nonSuccessStatus(let status, let code, let message, let details):
            let detailText = details.map { " details=\($0.joined(separator: "; "))" } ?? ""
            description = "HTTP \(status) (\((400..<500).contains(status) ? "VALIDATION/CLIENT" : "API/SERVER")) code=\(code ?? "unknown") message=\(message ?? "none")\(detailText)"
        case .malformedResponse(let error):
            description = "MALFORMED RESPONSE: \(error)"
        }
        print("[curation] FAILED (\(photoCount) photos, vibePack=\(vibePack)) -- \(description) -- falling back to FallbackSelectionService")
        #endif
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        struct Metrics: Encodable {
            let category: String
            let faceCount: Int
            let faceQuality: Float
            let largestFaceAreaRatio: Float
            let clusterID: Int
            let timestamp: String
            // Both non-optional -- confirmed live that the endpoint
            // rejects null/missing here exactly like it does for
            // timestamp ("must be an integer >= 1"). buildPayload
            // filters out any candidate missing either before this type
            // is ever constructed -- see that function's own doc
            // comment for why there's no honest fallback value the way
            // Date() is for a missing timestamp.
            let width: Int
            let height: Int
        }
        struct Photo: Encodable {
            let id: String
            let thumbnail: String
            let metrics: Metrics
        }
        let photos: [Photo]
        let tier: String
        let vibePack: String
    }

    private struct ResponseBody: Decodable {
        struct CarouselEntry: Decodable {
            let id: String
            let role: String
            let selectionReason: String?
        }
        struct AlternateEntry: Decodable {
            let id: String
            let type: String
            let replaceId: String?
            let role: String?
            let reason: String?
        }
        struct CaptionEntry: Decodable {
            let rank: Int
            let text: String
        }
        let aesthetic: String
        let tier: String
        let postConcept: String
        let selectedCount: Int
        let insufficientStrongPhotos: Bool
        let carousel: [CarouselEntry]
        let alternates: [AlternateEntry]
        let captions: [CaptionEntry]
    }

    private struct ErrorBody: Decodable {
        let error: String
        let code: String
        let details: [String]?
    }
}
