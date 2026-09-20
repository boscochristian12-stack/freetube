import Foundation
import AVFoundation
import OSLog

/// Streaming entry point for YouTube playback.
///
/// Provider pyramid:
///   0. Local cache (instant)
///   1. WEB / Safari HLS via native Innertube (primary)
///   2. WEB_EMBEDDED_PLAYER HLS/progressive (fallback)
///   3. Existing YouTubeKit iOS / TVHTML5 HLS/progressive (second fallback)
///
/// Only after every native streaming provider fails does PlayerStateManager deliberately enter the
/// local-file download fallback. No Invidious/Piped/public proxy is required for normal playback.
final class PlaybackResolver: PlaybackResolving {
    private let downloads: DownloadManagerLike
    private let streaming = StreamingService.shared
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlaybackResolver")

    init(downloads: DownloadManagerLike = DownloadManager.shared) {
        self.downloads = downloads
    }

    func resolve(videoID: String, quality: VideoQuality) async throws -> PlaybackSource {
        log.info("resolve(\(videoID, privacy: .public)) — cache → native stream providers")
        if let local = downloads.localFile(for: videoID) {
            log.info("resolve: cache hit → \(local.path, privacy: .public)")
            return .localFile(local)
        }
        return try await streaming.resolve(videoID: videoID, quality: quality)
    }
}

/// Stateless native streaming/download service shared by playback and the YouTube Downloads tab.
///
/// The primary provider uses the current YouTube WEB client with a Safari user-agent. Current yt-dlp
/// documentation notes that web_safari can expose pre-merged HLS formats which currently avoid GVS
/// PO-token requirements. HLS availability is not guaranteed, so the next providers remain important.
///
/// The service deliberately does not point at Invidious, Piped, or an arbitrary public proxy.
final class StreamingService {
    static let shared = StreamingService()

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "StreamingService")
    private let webClientVersion = "2.20260708.00.00"
    private let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"
    private let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    private init() {}

    func resolve(videoID: String, quality: VideoQuality) async throws -> PlaybackSource {
        var failures: [String] = []

        // Tier 1: WEB/Safari HLS.
        do {
            let json = try await fetchPlayerJSON(
                videoID: videoID,
                clientName: "WEB",
                clientID: 1,
                clientVersion: webClientVersion,
                userAgent: safariUserAgent,
                embedURL: nil
            )
            if let hls = await verifiedHLS(from: json, userAgent: safariUserAgent) {
                log.info("tier1 web_safari HLS verified for \(videoID, privacy: .public)")
                return .hls(hls, userAgent: safariUserAgent)
            }
            failures.append("web_safari:hls-unavailable")
        } catch {
            failures.append("web_safari:\(Self.shortError(error))")
        }

        // Tier 2: WEB_EMBEDDED_PLAYER HLS/progressive.
        do {
            let json = try await fetchPlayerJSON(
                videoID: videoID,
                clientName: "WEB_EMBEDDED_PLAYER",
                clientID: 56,
                clientVersion: webClientVersion,
                userAgent: safariUserAgent,
                embedURL: "https://www.youtube.com/"
            )
            if let hls = await verifiedHLS(from: json, userAgent: safariUserAgent) {
                log.info("tier2 web_embedded HLS verified for \(videoID, privacy: .public)")
                return .hls(hls, userAgent: safariUserAgent)
            }
            if let direct = await verifiedProgressive(
                from: json,
                maxHeight: quality.heightCap ?? Int.max,
                userAgent: safariUserAgent
            ) {
                log.info("tier2 web_embedded progressive verified for \(videoID, privacy: .public)")
                return .direct(direct)
            }
            failures.append("web_embedded:no-playable-format")
        } catch {
            failures.append("web_embedded:\(Self.shortError(error))")
        }

        // Tier 3: VISIONOS is a current no-JS-player fallback. yt-dlp currently lists it as a
        // cookieless last-resort client that can return direct formats without signature decoding.
        // It is especially useful when WEB Safari stops exposing its HLS manifest.
        do {
            let json = try await fetchPlayerJSON(
                videoID: videoID,
                clientName: "VISIONOS",
                clientID: 101,
                clientVersion: visionOSClientVersion,
                userAgent: visionOSUserAgent,
                embedURL: nil
            )
            if let direct = await verifiedProgressive(
                from: json,
                maxHeight: quality.heightCap ?? Int.max,
                userAgent: visionOSUserAgent
            ) {
                log.info("tier3 visionOS progressive verified for \(videoID, privacy: .public)")
                return .direct(direct)
            }
            if let hls = await verifiedHLS(from: json, userAgent: visionOSUserAgent) {
                log.info("tier3 visionOS HLS verified for \(videoID, privacy: .public)")
                return .hls(hls, userAgent: visionOSUserAgent)
            }
            failures.append("visionOS:no-playable-format")
        } catch {
            failures.append("visionOS:\(Self.shortError(error))")
        }

        // Tier 4: existing YouTubeKit clients.
        let service = VideoService()
        do {
            let info = try await service.fetchInfo(id: videoID)
            if let hls = info.streamingURL,
               await validateHLS(url: hls, userAgent: safariUserAgent) {
                log.info("tier3 YouTubeKit/iOS HLS verified for \(videoID, privacy: .public)")
                return .hls(hls, userAgent: safariUserAgent)
            }
            if let url = await verifiedProgressive(
                from: info.formats,
                maxHeight: quality.heightCap ?? Int.max,
                userAgent: safariUserAgent
            ) {
                log.info("tier3 YouTubeKit/iOS progressive verified for \(videoID, privacy: .public)")
                return .direct(url)
            }
            failures.append("youtubeKit:ios-no-playable-format")
        } catch {
            failures.append("youtubeKit:ios-\(Self.shortError(error))")
        }

        do {
            let info = try await service.fetchInfoViaTVHTML5(id: videoID)
            if let hls = info.streamingURL,
               await validateHLS(url: hls, userAgent: safariUserAgent) {
                log.info("tier3 YouTubeKit/TVHTML5 HLS verified for \(videoID, privacy: .public)")
                return .hls(hls, userAgent: safariUserAgent)
            }
            if let url = await verifiedProgressive(
                from: info.formats,
                maxHeight: quality.heightCap ?? Int.max,
                userAgent: safariUserAgent
            ) {
                log.info("tier3 YouTubeKit/TVHTML5 progressive verified for \(videoID, privacy: .public)")
                return .direct(url)
            }
            failures.append("youtubeKit:tvhtml5-no-playable-format")
        } catch {
            failures.append("youtubeKit:tvhtml5-\(Self.shortError(error))")
        }

        log.error("No native stream provider succeeded for \(videoID, privacy: .public): \(failures.joined(separator: " | "), privacy: .public)")
        throw StreamingError.providersExhausted(failures.joined(separator: "; "))
    }

    /// Saves a resolved native stream to disk. DownloadManager calls this before it enters its
    /// Python/yt-dlp final fallback, keeping Downloads functional when EJS is unavailable.
    func downloadToFile(videoID: String, quality: VideoQuality, destination: URL) async throws {
        let source = try await resolve(videoID: videoID, quality: quality)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        switch source {
        case .hls(let url, let userAgent):
            let args = [
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning",
                "-headers", "User-Agent: \(userAgent)\r\nReferer: https://www.youtube.com/\r\n",
                "-i", url.absoluteString,
                "-c", "copy",
                "-movflags", "+faststart",
                destination.path
            ]
            let exit = await FFmpegRunner.shared.run(args)
            guard exit == 0, FileManager.default.fileExists(atPath: destination.path) else {
                throw StreamingError.downloadFailed("HLS ffmpeg exit \(exit)")
            }

        case .direct(let url):
            try await downloadDirect(url: url, destination: destination)

        case .localFile(let url):
            try FileManager.default.copyItem(at: url, to: destination)

        case .composite:
            throw StreamingError.downloadFailed("Composite source is not a direct download candidate")
        }
    }

    private func fetchPlayerJSON(
        videoID: String,
        clientName: String,
        clientID: Int,
        clientVersion: String,
        userAgent: String,
        embedURL: String?
    ) async throws -> [String: Any] {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)") else {
            throw StreamingError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(clientID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let client = YouTubeKitClient.shared
        if !client.cookies.isEmpty {
            request.setValue(client.cookies, forHTTPHeaderField: "Cookie")
        }
        if !client.visitorData.isEmpty {
            request.setValue(client.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var contextClient: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "userAgent": userAgent,
            "hl": "en",
            "gl": "US"
        ]
        if !client.visitorData.isEmpty {
            contextClient["visitorData"] = client.visitorData
        }

        var context: [String: Any] = ["client": contextClient]
        if let embedURL {
            context["thirdParty"] = ["embedUrl": embedURL]
        }

        let body: [String: Any] = [
            "context": context,
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw StreamingError.httpStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StreamingError.httpStatus(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamingError.invalidResponse
        }

        if let playability = json["playabilityStatus"] as? [String: Any],
           let status = playability["status"] as? String,
           status != "OK" {
            let reason = playability["reason"] as? String ?? status
            throw StreamingError.playability(reason)
        }

        return json
    }

    private func verifiedHLS(from json: [String: Any], userAgent: String) async -> URL? {
        guard
            let streamingData = json["streamingData"] as? [String: Any],
            let raw = streamingData["hlsManifestUrl"] as? String,
            let url = URL(string: raw),
            await validateHLS(url: url, userAgent: userAgent)
        else {
            return nil
        }
        return url
    }

    private struct ProgressiveCandidate {
        let url: URL
        let height: Int
        let bitrate: Int
    }

    private func verifiedProgressive(
        from json: [String: Any],
        maxHeight: Int,
        userAgent: String
    ) async -> URL? {
        let raw = ((json["streamingData"] as? [String: Any])?["formats"] as? [[String: Any]]) ?? []
        let candidates = raw.compactMap { item -> ProgressiveCandidate? in
            guard let rawURL = item["url"] as? String,
                  let url = URL(string: rawURL),
                  let height = item["height"] as? Int else {
                return nil
            }
            let mime = (item["mimeType"] as? String ?? "").lowercased()
            guard mime.contains("video/mp4"), mime.contains("audio") else {
                return nil
            }
            return ProgressiveCandidate(
                url: url,
                height: height,
                bitrate: item["bitrate"] as? Int ?? 0
            )
        }
        .filter { $0.height <= maxHeight }
        .sorted {
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.bitrate > $1.bitrate
        }

        for candidate in candidates {
            if await validateDirectURL(candidate.url, userAgent: userAgent) {
                return candidate.url
            }
        }
        return nil
    }

    private func verifiedProgressive(
        from formats: [VideoFormat],
        maxHeight: Int,
        userAgent: String
    ) async -> URL? {
        let candidates = formats
            .filter { $0.containsBothTracks && $0.url != nil }
            .filter { ($0.height ?? Int.max) <= maxHeight }
            .sorted {
                let lhs = ($0.height ?? 0, $0.bitrate ?? 0)
                let rhs = ($1.height ?? 0, $1.bitrate ?? 0)
                return lhs > rhs
            }

        for candidate in candidates {
            if let url = candidate.url,
               await validateDirectURL(url, userAgent: userAgent) {
                return url
            }
        }
        return nil
    }

    private func validateHLS(url: URL, userAgent: String) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Origin")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let text = String(data: Data(data.prefix(64_000)), encoding: .utf8)
            else { return false }
            return text.contains("#EXTM3U")
        } catch {
            log.notice("HLS validation failed: \(Self.shortError(error), privacy: .public)")
            return false
        }
    }

    private func validateDirectURL(url: URL, userAgent: String) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func downloadDirect(url: URL, destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Origin")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw StreamingError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw StreamingError.downloadFailed("Could not open output file")
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(65_536)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 65_536 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
    }

    private static func shortError(_ error: Error) -> String {
        let message = error.localizedDescription
        return message.isEmpty ? String(describing: error) : message
    }
}

enum StreamingError: Error, LocalizedError {
    case providersExhausted(String)
    case httpStatus(Int)
    case invalidResponse
    case playability(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .providersExhausted(let details):
            return "No playable YouTube stream was available. \(details)"
        case .httpStatus(let code):
            return "YouTube returned HTTP \(code)."
        case .invalidResponse:
            return "YouTube returned an invalid player response."
        case .playability(let reason):
            return "YouTube playback is unavailable: \(reason)"
        case .downloadFailed(let reason):
            return "Stream download failed: \(reason)"
        }
    }
}

/// Subset of DownloadManager the resolver depends on. Allows tests to swap a mock.
protocol DownloadManagerLike: Sendable {
    func localFile(for videoID: String) -> URL?
    func ensureDownloaded(video: Video, quality: VideoQuality, priority: DownloadPriority) async throws -> URL
}

@available(iOS 17.0, *)
extension DownloadManager: DownloadManagerLike {}

/// Retained for source compatibility with older call sites.
protocol TemporaryDownloading: Sendable {
    func downloadTemporary(videoID: String, format: VideoFormat) async throws -> URL
}
