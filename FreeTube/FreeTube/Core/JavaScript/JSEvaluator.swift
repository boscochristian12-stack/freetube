import Foundation
import WebKit

/// Synchronous JavaScript evaluator backed by Apple's WebKit JavaScript engine.
///
/// yt-dlp's current EJS challenge solver is designed to run inside a modern browser-like
/// JavaScript environment. JavaScriptCore alone is missing several Web/Deno-compatible pieces
/// that the EJS bundle can exercise, which caused the old bridge to return empty stdout on iOS.
/// WKWebView uses the same WebKit engine available to the OS and is the engine used by the
/// official yt-dlp Apple WebKit JSI provider.
///
/// The public API stays synchronous because PythonJSBridge exposes this evaluator to the
/// embedded Python runtime through a synchronous builtins.eval_js() function. WebKit work is
/// scheduled on the main queue, while the Python worker waits on a semaphore.
/// Baseline playback restored; keep this file in the workflow path so the restored tree rebuilds.
@available(iOS 17.0, *)
// Uses WKWebView because yt-dlp's current EJS solver expects a browser-grade JS environment.
nonisolated struct JSEvaluator {
    enum Error: Swift.Error, CustomStringConvertible {
        case scriptError(message: String)
        case nullContext
        case noResult
        case mainThreadUnavailable

        var description: String {
            switch self {
            case .scriptError(let message): return "JS script error: \(message)"
            case .nullContext: return "WKWebView could not be created"
            case .noResult: return "JavaScript evaluation produced no value"
            case .mainThreadUnavailable: return "WebKit evaluation cannot block the main thread"
            }
        }
    }

    /// Evaluates JavaScript and returns the text emitted by console.log().
    ///
    /// yt-dlp's EJS runtime communicates its result through console.log(JSON.stringify(...)).
    /// We therefore replace console.log inside a private wrapper and return the captured lines.
    static func evaluate(_ code: String) throws -> String {
        guard !Thread.isMainThread else {
            throw Error.mainThreadUnavailable
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = EvaluationBox()

        DispatchQueue.main.async {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()

            let webView = WKWebView(
                frame: .zero,
                configuration: configuration
            )
            box.webView = webView

            let delegate = NavigationDelegate {
                let script = wrapForStdoutCapture(code)

                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        box.error = Error.scriptError(message: error.localizedDescription)
                    } else if let string = value as? String {
                        box.result = string
                    } else if let value {
                        box.result = String(describing: value)
                    } else {
                        box.error = Error.noResult
                    }

                    box.webView = nil
                    box.delegate = nil
                    semaphore.signal()
                }
            }

            box.delegate = delegate
            webView.navigationDelegate = delegate
            webView.loadHTMLString(
                "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>",
                baseURL: URL(string: "https://www.youtube.com/")
            )
        }

        semaphore.wait()

        if let error = box.error {
            throw error
        }

        guard let result = box.result else {
            throw Error.noResult
        }

        return result
    }

    private static func wrapForStdoutCapture(_ userCode: String) -> String {
        """
        ;(function() {
            var __ftStdout = [];
            var __ftConsole = {
                log: function() {
                    var parts = Array.prototype.map.call(arguments, function(a) { return String(a); });
                    __ftStdout.push(parts.join(' '));
                },
                error: function() {},
                warn: function() {},
                info: function() {},
                debug: function() {}
            };

            var __ftOldConsole = globalThis.console;
            globalThis.console = __ftConsole;

            try {
                \(userCode)
            } finally {
                globalThis.console = __ftOldConsole;
            }

            return __ftStdout.join('\\n');
        })()
        """
    }

    private final class EvaluationBox: @unchecked Sendable {
        var webView: WKWebView?
        var delegate: NavigationDelegate?
        var result: String?
        var error: Swift.Error?
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            onFinish()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Swift.Error
        ) {
            onFinish()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Swift.Error
        ) {
            onFinish()
        }
    }
}
