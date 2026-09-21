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

        return result
    }

    static func selfTest() throws -> Bool {
        let result = try evaluate("1 + 1")
        return result == "2"
    }
}
