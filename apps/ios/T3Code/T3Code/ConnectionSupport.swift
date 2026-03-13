import Foundation

nonisolated enum ConnectionMode: String, Codable, Sendable {
    case appAuth
    case token
}

nonisolated enum ConnectionPhase: String, Sendable {
    case disconnected
    case checkingAuth
    case awaitingLogin
    case connecting
    case connected
    case failed
}

nonisolated enum ConnectionAuthContext: Equatable, Sendable {
    case none
    case appSession(String)
    case token(String)
}

nonisolated struct ServerEndpoint: Equatable, Sendable {
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

nonisolated enum EndpointResolutionError: LocalizedError, Equatable {
    case emptyHost
    case invalidHost
    case invalidPort
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .emptyHost:
            return "Enter a server hostname or URL."
        case .invalidHost:
            return "Enter a valid server hostname or URL."
        case .invalidPort:
            return "Enter a valid port between 1 and 65535."
        case .invalidURL:
            return "Unable to build a server URL from that value."
        }
    }
}

nonisolated enum ConnectionIssue: LocalizedError, Equatable {
    case missingToken

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Enter an auth token or switch back to app login."
        }
    }
}

struct ConnectionErrorFormatter {
    nonisolated static func message(for error: any Error, connectionMode: ConnectionMode? = nil) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Connection timed out. Check the server and try again."
            case .cannotFindHost, .dnsLookupFailed:
                return "The server host could not be found."
            case .cannotConnectToHost:
                return "Could not reach the server. Check the host or advanced port override."
            case .notConnectedToInternet:
                return "This device appears to be offline."
            case .networkConnectionLost:
                return "The network connection was lost."
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 40 {
            return "The server response was too large. Try clearing old threads or reducing history."
        }

        if nsError.localizedDescription.localizedCaseInsensitiveContains("message too long") {
            return "The server response was too large. Try clearing old threads or reducing history."
        }

        if let transportError = error as? TransportError {
            switch transportError {
            case .serverError(let message):
                if message.localizedCaseInsensitiveContains("unauthorized") {
                    switch connectionMode {
                    case .token:
                        return "That auth token was rejected."
                    case .appAuth:
                        return "Your sign-in session expired. Sign in again."
                    case .none:
                        return "Authorization failed. Sign in again or check the auth token."
                    }
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

        if let appAuthError = error as? AppAuthClientError {
            switch appAuthError {
            case .invalidCredentials(let message):
                return message
            case .expiredSession:
                return "Your saved session expired. Sign in again."
            case .server(let message):
                return message
            case .invalidResponse:
                return "The server returned an invalid auth response."
            case .network(let message):
                return message
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

nonisolated enum EndpointResolver {
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

nonisolated struct AppAuthSessionState: Codable, Sendable, Equatable {
    let authRequired: Bool
    let authenticated: Bool
    let username: String?
}

nonisolated struct AppAuthLoginResponse: Codable, Sendable, Equatable {
    let session: AppAuthSessionState
    let sessionToken: String
}

nonisolated struct AppAuthErrorResponse: Codable, Sendable, Equatable {
    let message: String
}
