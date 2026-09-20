import Foundation

enum PlaybackSource: Sendable, Hashable {
    case direct(URL)
    /// HLS master/variant playlist. The Safari user-agent is retained with the source so AVPlayer's
    /// segment requests can be routed through HLSResourceLoaderDelegate with the same fingerprint.
    case hls(URL, userAgent: String)
    case localFile(URL)
    /// Separate video-only + audio-only streams that a downloader can stitch together.
    case composite(video: URL, audio: URL)

    var url: URL {
        switch self {
        case .direct(let url): return url
        case .hls(let url, _): return url
        case .localFile(let url): return url
        case .composite(let video, _): return video
        }
    }
}

protocol PlaybackResolving {
    func resolve(videoID: String, quality: VideoQuality) async throws -> PlaybackSource
}
