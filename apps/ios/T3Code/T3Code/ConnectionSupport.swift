import Foundation

enum ConnectionMode: String, Codable, Sendable {
    case appAuth
    case token
}

enum ConnectionPhase: String, Sendable {
    case disconnected
    case checkingAuth
    case awaitingLogin
    case connecting
    case connected
    case failed
}

enum ConnectionAuthContext: Equatable, Sendable {
    case none
    case appSession(String)
    case token(String)
}

struct ServerEndpoint: Equatable, Sendable {
    let httpOrigin: URL

    func webSocketURL(auth: ConnectionAuthContext) throws -> URL {
        guard var components = URLComponents(url: httpOrigin, resolvingAgainstBaseURL: false) else {
            throw EndpointResolutionError.invalidURL
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw EndpointResolutionError.invalidURL
        }

        components.path = "/"
        components.query = nil
        components.fragment = nil

        switch auth {
        case .none:
            break
        case .appSession(let sessionToken):
            components.queryItems = [URLQueryItem(name: "auth_session", value: sessionToken)]
        case .token(let token):
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }

        guard let url = components.url else {
            throw EndpointResolutionError.invalidURL
        }
        return url
    }
}

enum EndpointResolutionError: LocalizedError, Equatable {
    case emptyHost
    case invalidHost
    case invalidPort
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .emptyHost:
            "Enter a server hostname or URL."
        case .invalidHost:
            "Enter a valid server hostname or URL."
        case .invalidPort:
            "Enter a valid port between 1 and 65535."
        case .invalidURL:
            "Unable to build a server URL from that value."
        }
    }
}

enum ConnectionIssue: LocalizedError, Equatable {
    case missingToken

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Enter an auth token or switch back to app login."
        }
    }
}

struct ConnectionErrorFormatter {
    static func message(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Connection timed out. Check the server host or port and try again."
            case .cannotFindHost, .dnsLookupFailed:
                return "The server host could not be found."
            case .cannotConnectToHost:
                return "Could not reach the server. Check the host and port."
            case .notConnectedToInternet:
                return "This device appears to be offline."
            case .networkConnectionLost:
                return "The network connection was lost."
            default:
                break
            }
        }

        if let transportError = error as? TransportError {
            switch transportError {
            case .serverError(let message):
                if message.localizedCaseInsensitiveContains("unauthorized websocket connection") {
                    return "Authorization failed. Sign in again or check the auth token."
                }
                if message.localizedCaseInsensitiveContains("orchestration.getSnapshot") {
                    return "Connected, but the server was too slow to return the initial snapshot."
                }
                return message
            case .timeout(let method):
                if method == "orchestration.getSnapshot" {
                    return "Connected, but the server was too slow to return the initial snapshot."
                }
            default:
                break
            }
        }

        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        let fallback = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Connection failed." : fallback
    }
}

enum EndpointResolver {
    static func resolve(hostInput: String, portOverride: String) throws -> ServerEndpoint {
        let trimmedHost = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw EndpointResolutionError.emptyHost
        }

        var raw = trimmedHost
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw) else {
            throw EndpointResolutionError.invalidHost
        }

        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            components.scheme = "https"
        }

        guard let host = components.host, !host.isEmpty else {
            throw EndpointResolutionError.invalidHost
        }

        let trimmedPort = portOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPort.isEmpty {
            guard let port = Int(trimmedPort), (1...65535).contains(port) else {
                throw EndpointResolutionError.invalidPort
            }
            components.port = port
        }

        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let normalizedURL = components.url else {
            throw EndpointResolutionError.invalidURL
        }

        return ServerEndpoint(httpOrigin: normalizedURL)
    }
}

struct AppAuthSessionState: Codable, Sendable, Equatable {
    let authRequired: Bool
    let authenticated: Bool
    let username: String?
}

struct AppAuthLoginResponse: Codable, Sendable, Equatable {
    let session: AppAuthSessionState
    let sessionToken: String
}

struct AppAuthErrorResponse: Codable, Sendable, Equatable {
    let message: String
}
