import Foundation
import CryptoKit

/// Errors surfaced by the ABM/ASM client.
nonisolated enum ABMError: LocalizedError {
    case invalidKey(String)
    case tokenFailed(Int, String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey(let detail):
            "The .pem file could not be read as an EC (P-256) private key. \(detail)"
        case .tokenFailed(let status, let body):
            "Token request failed (HTTP \(status)): \(body)"
        case .requestFailed(let detail):
            detail
        }
    }
}

/// A device record from `/orgDevices`.
nonisolated struct OrgDevice: Sendable {
    let serial: String
    let productFamily: String
    let orderNumber: String
    let purchaseSourceType: String
    let purchaseSourceID: String
    let orderDate: String
}

/// A single coverage entry from `/orgDevices/{serial}/appleCareCoverage`.
nonisolated struct Coverage: Sendable {
    let description: String
    let status: String
    let endDate: String
    let agreementNumber: String
}

/// Talks to the Apple Business / School Manager API.
/// Mirrors the behaviour of the original Warranty Wrangler script: JWT client assertion,
/// token refresh on 401, Retry-After / exponential backoff on 429, and retries on transport errors.
actor ABMClient {
    private static let authURL = "https://account.apple.com/auth/oauth2/v2/token"

    private let clientID: String
    private let keyID: String
    private let privateKey: P256.Signing.PrivateKey
    private let mode: ServiceMode
    private let log: @Sendable (String) -> Void
    private let session: URLSession

    private var accessToken: String?

    private let maxTries = 10
    private let backoffStart: Double = 1
    private let backoffMax: Double = 60
    private let jitterMax: Double = 0.75

    init(clientID: String, keyID: String, pem: String, mode: ServiceMode, log: @escaping @Sendable (String) -> Void) throws {
        privateKey = try Self.loadPrivateKey(pem: pem)
        self.clientID = clientID
        self.keyID = keyID
        self.mode = mode
        self.log = log

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    /// Loads a P-256 private key regardless of the PEM label.
    /// ABM-issued keys are labelled "EC PRIVATE KEY" (SEC1) but actually contain PKCS#8 data,
    /// which OpenSSL tolerates but CryptoKit's label-driven PEM parser rejects. So decode the
    /// base64 body ourselves and let `derRepresentation` detect PKCS#8 or SEC1.
    private static func loadPrivateKey(pem: String) throws -> P256.Signing.PrivateKey {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return key
        }
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        guard let der = Data(base64Encoded: body) else {
            throw ABMError.invalidKey("The file does not contain valid PEM (base64) data.")
        }
        do {
            return try P256.Signing.PrivateKey(derRepresentation: der)
        } catch {
            throw ABMError.invalidKey(error.localizedDescription)
        }
    }

    // MARK: - Authentication

    /// Builds the ES256-signed JWT client assertion (valid 180 days).
    private func makeClientAssertion() throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = [
            "sub": clientID,
            "aud": Self.authURL,
            "iat": now,
            "exp": now + 15_552_000,
            "jti": UUID().uuidString.lowercased(),
            "iss": clientID,
        ]
        let headerPart = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes]).base64URLEncoded
        let payloadPart = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]).base64URLEncoded
        let signingInput = "\(headerPart).\(payloadPart)"
        // CryptoKit's rawRepresentation is already the JOSE r||s (64-byte) format.
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncoded)"
    }

    /// Exchanges the client assertion for a bearer token.
    func authenticate() async throws {
        let assertion = try makeClientAssertion()
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_assertion_type", value: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            URLQueryItem(name: "client_assertion", value: assertion),
            URLQueryItem(name: "scope", value: mode.scope),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self)
        guard status == 200 else { throw ABMError.tokenFailed(status, body) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw ABMError.tokenFailed(status, "No access_token in response: \(body)")
        }
        accessToken = token
    }

    // MARK: - Resilient GET

    /// GET returning parsed JSON, with 401 refresh, 429 backoff and transport retries.
    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var backoff = backoffStart
        for attempt in 1...maxTries {
            try Task.checkCancellation()
            if accessToken == nil { try await authenticate() }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0

                switch status {
                case 200:
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return json
                    }
                    log("WARN: Invalid JSON body (try \(attempt)/\(maxTries)) \(url.path)")
                case 401:
                    log("WARN: 401 from API — refreshing token (try \(attempt)/\(maxTries))")
                    try await authenticate()
                    continue
                case 429:
                    if let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
                        log("WARN: 429 rate limit — Retry-After \(Int(retryAfter))s (try \(attempt)/\(maxTries))")
                        try await sleep(retryAfter)
                        backoff = backoffStart
                        continue
                    }
                    log("WARN: 429 rate limit — backing off (try \(attempt)/\(maxTries))")
                case 404:
                    throw ABMError.requestFailed("HTTP 404 for \(url.path)")
                default:
                    log("WARN: HTTP \(status) (try \(attempt)/\(maxTries)) \(url.path)")
                }
            } catch let error as ABMError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                log("WARN: Request error: \(error.localizedDescription) (try \(attempt)/\(maxTries))")
            }

            try await sleep(backoff + Double.random(in: 0...jitterMax))
            backoff = min(backoff * 2, backoffMax)
        }
        throw ABMError.requestFailed("Failed after \(maxTries) attempts: \(url.absoluteString)")
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: - Endpoints

    /// Fetches one page of devices. Returns the devices and the next cursor (if any).
    func fetchDevicePage(cursor: String?) async throws -> (devices: [OrgDevice], nextCursor: String?) {
        var components = URLComponents(string: "\(mode.apiBase)/orgDevices")!
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        let json = try await getJSON(components.url!)

        let data = json["data"] as? [[String: Any]] ?? []
        let devices = data.compactMap { item -> OrgDevice? in
            guard let serial = item["id"] as? String else { return nil }
            let attributes = item["attributes"] as? [String: Any] ?? [:]
            let orderDateTime = attributes["orderDateTime"] as? String ?? ""
            return OrgDevice(
                serial: serial,
                productFamily: attributes["productFamily"] as? String ?? "Unknown",
                orderNumber: attributes["orderNumber"] as? String ?? "",
                purchaseSourceType: attributes["purchaseSourceType"] as? String ?? "",
                purchaseSourceID: attributes["purchaseSourceId"] as? String ?? "",
                orderDate: String(orderDateTime.prefix { $0 != "T" })
            )
        }
        let meta = json["meta"] as? [String: Any]
        let paging = meta?["paging"] as? [String: Any]
        let next = paging?["nextCursor"] as? String
        return (devices, (next?.isEmpty ?? true) ? nil : next)
    }

    /// Fetches AppleCare / warranty coverage for a device.
    func fetchCoverage(serial: String) async throws -> [Coverage] {
        let encoded = serial.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serial
        let json = try await getJSON(URL(string: "\(mode.apiBase)/orgDevices/\(encoded)/appleCareCoverage")!)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.map { item in
            let attributes = item["attributes"] as? [String: Any] ?? [:]
            let end = attributes["endDateTime"] as? String ?? ""
            return Coverage(
                description: attributes["description"] as? String ?? "",
                status: attributes["status"] as? String ?? "",
                endDate: String(end.prefix { $0 != "T" }),
                agreementNumber: attributes["agreementNumber"] as? String ?? ""
            )
        }
    }

    /// Looks up a purchase source name for an ID not in the local vendor table.
    func fetchPurchaseSourceName(id: String) async -> String? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(mode.apiBase)/purchaseSources/\(encoded)"),
              let json = try? await getJSON(url),
              let data = json["data"] as? [String: Any],
              let attributes = data["attributes"] as? [String: Any],
              let name = attributes["name"] as? String, !name.isEmpty else { return nil }
        return name
    }
}

nonisolated extension Data {
    /// Base64URL encoding without padding (RFC 7515).
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
