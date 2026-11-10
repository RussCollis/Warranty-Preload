import Foundation

/// Errors surfaced by the Jamf Pro client.
nonisolated enum JamfError: LocalizedError {
    case invalidURL(String)
    case tokenFailed(Int, String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "\"\(value)\" is not a valid Jamf Pro URL."
        case .tokenFailed(let status, let body):
            "Jamf Pro token request failed (HTTP \(status)): \(body)"
        case .requestFailed(let detail):
            detail
        }
    }
}

/// The purchasing fields this app manages in Jamf Pro. Dates are `yyyy-MM-dd`.
nonisolated struct JamfPurchasing: Sendable, Equatable {
    var poNumber = ""
    var poDate = ""
    var vendor = ""
    var warrantyDate = ""
    var appleCareID = ""
}

/// A device record in Jamf Pro inventory.
nonisolated struct JamfDevice: Sendable {
    let id: String
    let isMac: Bool
    /// For mobile devices: the platform object used when updating (`ios` or `tvos`).
    let platformKey: String
    var purchasing: JamfPurchasing
}

/// Talks to the Jamf Pro API using an API client (client credentials).
/// Required API role privileges: Read/Update Computers and Read/Update Mobile Devices.
actor JamfClient {
    private let baseURL: URL
    private let clientID: String
    private let clientSecret: String
    private let log: @Sendable (String) -> Void
    private let session: URLSession

    private var accessToken: String?
    private var tokenExpiry = Date.distantPast

    private let maxTries = 5
    private let pageSize = 1000

    init(url: String, clientID: String, clientSecret: String, log: @escaping @Sendable (String) -> Void) throws {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://" + trimmed }
        guard let base = URL(string: trimmed), base.host() != nil else { throw JamfError.invalidURL(url) }
        baseURL = base
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.log = log

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    // MARK: - Authentication

    func authenticate() async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
        ]
        // URLComponents leaves "+" unescaped, which form decoding would read as a space.
        let body = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard status == 200 else { throw JamfError.tokenFailed(status, text) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw JamfError.tokenFailed(status, "No access_token in response: \(text)")
        }
        accessToken = token
        // Jamf API client tokens are short-lived (often 60s); renew a little before expiry.
        let lifetime = (json["expires_in"] as? Double) ?? 60
        tokenExpiry = Date().addingTimeInterval(max(lifetime - 10, 5))
    }

    // MARK: - Requests

    /// Sends a request with token renewal, 401 refresh and retries on 429/5xx/transport errors.
    private func send(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> Data {
        var backoff = 1.0
        for attempt in 1...maxTries {
            try Task.checkCancellation()
            if accessToken == nil || Date() >= tokenExpiry { try await authenticate() }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200..<300:
                    return data
                case 401:
                    log("WARN: Jamf 401 — refreshing token (try \(attempt)/\(maxTries))")
                    accessToken = nil
                    continue
                case 429, 500...:
                    log("WARN: Jamf HTTP \(status) (try \(attempt)/\(maxTries)) \(url.path)")
                default:
                    let text = String(decoding: data, as: UTF8.self)
                    throw JamfError.requestFailed("Jamf HTTP \(status) for \(method) \(url.path): \(text)")
                }
            } catch let error as JamfError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                log("WARN: Jamf request error: \(error.localizedDescription) (try \(attempt)/\(maxTries))")
            }

            try await Task.sleep(for: .milliseconds(Int(backoff * 1000)))
            backoff = min(backoff * 2, 30)
        }
        throw JamfError.requestFailed("Jamf request failed after \(maxTries) attempts: \(url.path)")
    }

    private func getJSON(_ path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        let data = try await send("GET", components.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JamfError.requestFailed("Invalid JSON from Jamf for \(path)")
        }
        return json
    }

    /// Reads every page of a paged inventory endpoint.
    private func fetchAll(_ path: String, sections: [String]) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var page = 0
        while true {
            let query = sections.map { URLQueryItem(name: "section", value: $0) } + [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: String(pageSize)),
            ]
            let json = try await getJSON(path, query: query)
            let pageResults = json["results"] as? [[String: Any]] ?? []
            results += pageResults
            let total = json["totalCount"] as? Int ?? results.count
            if pageResults.isEmpty || results.count >= total { return results }
            page += 1
        }
    }

    // MARK: - Inventory

    /// All computers keyed by serial number.
    func fetchComputers() async throws -> [String: JamfDevice] {
        let results = try await fetchAll("api/v1/computers-inventory", sections: ["HARDWARE", "PURCHASING"])
        var devices: [String: JamfDevice] = [:]
        for item in results {
            let hardware = item["hardware"] as? [String: Any] ?? [:]
            guard let id = Self.string(item["id"]),
                  let serial = hardware["serialNumber"] as? String, !serial.isEmpty else { continue }
            let p = item["purchasing"] as? [String: Any] ?? [:]
            devices[serial] = JamfDevice(id: id, isMac: true, platformKey: "", purchasing: JamfPurchasing(
                poNumber: p["poNumber"] as? String ?? "",
                poDate: Self.day(p["poDate"]),
                vendor: p["vendor"] as? String ?? "",
                warrantyDate: Self.day(p["warrantyDate"]),
                appleCareID: p["appleCareId"] as? String ?? ""))
        }
        return devices
    }

    /// All mobile devices keyed by serial number.
    func fetchMobileDevices() async throws -> [String: JamfDevice] {
        let results = try await fetchAll("api/v2/mobile-devices/detail", sections: ["HARDWARE", "PURCHASING"])
        var devices: [String: JamfDevice] = [:]
        for item in results {
            let hardware = item["hardware"] as? [String: Any] ?? [:]
            guard let id = Self.string(item["mobileDeviceId"]) ?? Self.string(item["id"]),
                  let serial = hardware["serialNumber"] as? String, !serial.isEmpty else { continue }
            let type = (item["deviceType"] as? String ?? "").lowercased()
            let p = item["purchasing"] as? [String: Any] ?? [:]
            devices[serial] = JamfDevice(id: id, isMac: false, platformKey: type == "tvos" ? "tvos" : "ios",
                                         purchasing: JamfPurchasing(
                poNumber: p["poNumber"] as? String ?? "",
                poDate: Self.day(p["poDate"]),
                vendor: p["vendor"] as? String ?? "",
                warrantyDate: Self.day(p["warrantyExpiresDate"]),
                appleCareID: p["appleCareId"] as? String ?? ""))
        }
        return devices
    }

    // MARK: - Updates

    /// Writes only the non-empty fields of `changes` to the device's purchasing record.
    func updatePurchasing(_ device: JamfDevice, changes: JamfPurchasing) async throws {
        if device.isMac {
            var purchasing: [String: Any] = [:]
            if !changes.poNumber.isEmpty { purchasing["poNumber"] = changes.poNumber }
            if !changes.poDate.isEmpty { purchasing["poDate"] = changes.poDate }
            if !changes.vendor.isEmpty { purchasing["vendor"] = changes.vendor }
            if !changes.warrantyDate.isEmpty { purchasing["warrantyDate"] = changes.warrantyDate }
            if !changes.appleCareID.isEmpty { purchasing["appleCareId"] = changes.appleCareID }
            _ = try await send("PATCH", baseURL.appending(path: "api/v1/computers-inventory-detail/\(device.id)"),
                               body: ["purchasing": purchasing])
        } else {
            // The v2 mobile device API takes full timestamps for purchasing dates.
            var purchasing: [String: Any] = [:]
            if !changes.poNumber.isEmpty { purchasing["poNumber"] = changes.poNumber }
            if !changes.poDate.isEmpty { purchasing["poDate"] = changes.poDate + "T00:00:00Z" }
            if !changes.vendor.isEmpty { purchasing["vendor"] = changes.vendor }
            if !changes.warrantyDate.isEmpty { purchasing["warrantyExpiresDate"] = changes.warrantyDate + "T00:00:00Z" }
            if !changes.appleCareID.isEmpty { purchasing["appleCareId"] = changes.appleCareID }
            _ = try await send("PATCH", baseURL.appending(path: "api/v2/mobile-devices/\(device.id)"),
                               body: [device.platformKey: ["purchasing": purchasing]])
        }
    }

    // MARK: - Helpers

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? Int { return String(n) }
        return nil
    }

    /// Normalises a Jamf date/timestamp to `yyyy-MM-dd`.
    private static func day(_ value: Any?) -> String {
        String((value as? String ?? "").prefix(10))
    }
}
