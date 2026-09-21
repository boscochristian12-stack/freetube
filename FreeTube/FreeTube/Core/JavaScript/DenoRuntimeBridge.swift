import Foundation

@available(iOS 17.0, *)
nonisolated enum DenoRuntimeBridge {
    enum Error: Swift.Error, CustomStringConvertible {
        case runtimeUnavailable
        case invalidUTF8
        case runtimeError(String)

        var description: String {
            switch self {
            case .runtimeUnavailable:
                return "Embedded Deno runtime returned no result"
            case .invalidUTF8:
                return "Embedded Deno runtime returned invalid UTF-8"
            case .runtimeError(let message):
                return "Embedded Deno runtime error: \(message)"
            }
        }
    }

    static func evaluate(_ source: String) throws -> String {
        let pointer = source.withCString { freetube_deno_eval($0) }
        guard let pointer else {
            throw Error.runtimeUnavailable
        }
        defer {
            freetube_deno_free_string(pointer)
        }

        let result = String(cString: pointer)
        guard !result.isEmpty else {
            throw Error.runtimeUnavailable
        }

        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.runtimeError(result)
        }

        guard let ok = object["ok"] as? Bool else {
            throw Error.runtimeError(result)
        }

        if ok {
            guard let stdout = object["stdout"] as? String else {
                throw Error.runtimeError("Embedded Deno runtime returned no stdout")
            }
            return stdout
        }

        throw Error.runtimeError((object["error"] as? String) ?? "Unknown embedded Deno error")
    }

    static func selfTest() throws -> Bool {
        let result = try evaluate("1 + 1")
        return result == "2"
    }
}
