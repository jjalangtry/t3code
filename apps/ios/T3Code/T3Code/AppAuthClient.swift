import Foundation

nonisolated enum AppAuthClientError: LocalizedError, Equatable {
    case invalidCredentials(String)
    case expiredSession
    case server(String)
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
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
}

struct AppAuthClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSession(origin: URL, sessionToken: String?) async throws -> AppAuthSessionState {
        var request = URLRequest(url: origin.appending(path: "api/auth/session"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await execute(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppAuthClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw AppAuthClientError.expiredSession
        }
        guard httpResponse.statusCode == 200 else {
            let serverMessage = decodeServerMessage(from: data)
            throw AppAuthClientError.server(serverMessage ?? "Unable to check sign-in status.")
        }
        do {
            return try decoder.decode(AppAuthSessionState.self, from: data)
        } catch {
            throw AppAuthClientError.invalidResponse
        }
    }

    func login(origin: URL, username: String, password: String) async throws -> AppAuthLoginResponse {
        var request = URLRequest(url: origin.appending(path: "api/auth/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(LoginRequest(username: username, password: password))

        let (data, response) = try await execute(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppAuthClientError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            do {
                return try decoder.decode(AppAuthLoginResponse.self, from: data)
            } catch {
                throw AppAuthClientError.invalidResponse
            }
        }

        let serverMessage = decodeServerMessage(from: data)
        if httpResponse.statusCode == 401 {
            throw AppAuthClientError.invalidCredentials(serverMessage ?? "Invalid username or password.")
        }
        throw AppAuthClientError.server(serverMessage ?? "Sign-in failed.")
    }

    func logout(origin: URL, sessionToken: String?) async throws {
        var request = URLRequest(url: origin.appending(path: "api/auth/logout"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await execute(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppAuthClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let serverMessage = decodeServerMessage(from: data)
            throw AppAuthClientError.server(serverMessage ?? "Sign-out failed.")
        }
    }

    private func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if let urlError = error as? URLError {
                throw AppAuthClientError.network(ConnectionErrorFormatter.message(for: urlError))
            }
            throw AppAuthClientError.network(ConnectionErrorFormatter.message(for: error))
        }
    }

    private func decodeServerMessage(from data: Data) -> String? {
        if let payload = try? decoder.decode(AppAuthErrorResponse.self, from: data) {
            let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
        return nil
    }
}

private struct LoginRequest: Encodable {
    let username: String
    let password: String
}
