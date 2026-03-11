import Testing
@testable import T3Code

struct T3CodeTests {
    @Test
    func bareHostnameResolvesToHttpsAndWss() throws {
        let endpoint = try EndpointResolver.resolve(
            hostInput: "code.jjalangtry.com",
            portOverride: ""
        )

        #expect(endpoint.httpOrigin.absoluteString == "https://code.jjalangtry.com")
        #expect((try endpoint.webSocketURL(auth: .none).absoluteString) == "wss://code.jjalangtry.com/")
    }

    @Test
    func portOverrideAppliesToOriginAndSocket() throws {
        let endpoint = try EndpointResolver.resolve(
            hostInput: "http://192.168.1.42",
            portOverride: "3773"
        )

        #expect(endpoint.httpOrigin.absoluteString == "http://192.168.1.42:3773")
        #expect((try endpoint.webSocketURL(auth: .none).absoluteString) == "ws://192.168.1.42:3773/")
    }

    @Test
    func websocketAuthUsesExpectedQueryParameters() throws {
        let endpoint = try EndpointResolver.resolve(
            hostInput: "code.jjalangtry.com",
            portOverride: ""
        )

        #expect(
            (try endpoint.webSocketURL(auth: .token("secret")).absoluteString)
                == "wss://code.jjalangtry.com/?token=secret"
        )
        #expect(
            (try endpoint.webSocketURL(auth: .appSession("session-token")).absoluteString)
                == "wss://code.jjalangtry.com/?auth_session=session-token"
        )
    }

    @Test
    func errorFormatterMapsUnauthorizedAndSnapshotTimeout() {
        #expect(
            ConnectionErrorFormatter.message(
                for: TransportError.serverError("Unauthorized WebSocket connection")
            ) == "Authorization failed. Sign in again or check the auth token."
        )
        #expect(
            ConnectionErrorFormatter.message(
                for: TransportError.timeout("orchestration.getSnapshot")
            ) == "Connected, but the server was too slow to return the initial snapshot."
        )
    }
}
