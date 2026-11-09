import Foundation
import Observation

/// A single line in the activity log.
struct LogLine: Identifiable {
    enum Level { case info, success, warning, error }
    let id = UUID()
    let date = Date()
    let level: Level
    let text: String
}

/// Summary counters for a run.
struct SyncStats {
    var totalDevices = 0
    var newComputers = 0
    var newMobile = 0
    var skipped = 0
    var filtered = 0
    var coverageErrors = 0
    var pages = 0
}

/// Runs the ABM/ASM pull and writes the Jamf templates:
/// - Computer Template (MUT format)
/// - Mobile Device Template (MUT format, when mobile devices are included)
/// - Inventory Preload Template (Jamf Pro format)
@Observable
final class SyncEngine {
    private(set) var isRunning = false
    private(set) var log: [LogLine] = []
    private(set) var stats = SyncStats()
    private(set) var statusText = "Ready"
    private(set) var writtenFiles: [URL] = []

    private var task: Task<Void, Never>?

    // Pacing (matches the original script).
    private let deviceDelay: Duration = .milliseconds(100)
    private let pageDelay: Duration = .milliseconds(300)

    static let computerHeader = ["Computer Serial", "Display Name", "Asset Tag", "Barcode 1", "Barcode 2", "Username", "Real Name", "Email Address", "Position", "Phone Number", "Department", "Building", "Room", "PO Number", "Vendor", "Purchase Price", "PO Date", "Warranty Expires", "Is Leased", "Lease Expires", "AppleCare ID", "Site (ID or Name)"]
    static let mobileHeader = ["Mobile Device Serial", "Display Name", "Enforce Name", "Asset Tag", "Username", "Real Name", "Email Address", "Position", "Phone Number", "Department", "Building", "Room", "PO Number", "Vendor", "Purchase Price", "PO Date", "Warranty Expires", "Is Leased", "Lease Expires", "AppleCare ID", "Airplay Password (tvOS Only)", "Site (ID or Name)"]
    static let preloadHeader = ["Serial Number", "Device Type", "Username", "Full Name", "Email Address", "Phone Number", "Position", "Department", "Building", "Room", "PO Number", "PO Date", "Warranty Expiration", "Apple Care ID", "Purchase Price", "Life Expectancy", "Purchasing Account", "Purchasing Contact", "Lease Expiration", "Bar Code 1", "Bar Code 2", "Asset Tag", "Vendor"]

    func start(settings: SettingsStore) {
        guard !isRunning else { return }
        task = Task { await run(settings: settings) }
    }

    func cancel() {
        task?.cancel()
        append(.warning, "Cancelling…")
    }

    func clearLog() {
        log.removeAll()
    }

    private func append(_ level: LogLine.Level, _ text: String) {
        log.append(LogLine(level: level, text: text))
        // Keep the log bounded for very large estates.
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    /// Checks the credentials by requesting a bearer token, without fetching any devices.
    func testConnection(settings: SettingsStore) {
        guard !isRunning else { return }
        task = Task {
            isRunning = true
            defer { isRunning = false }
            append(.info, "Testing connection to \(settings.mode.title)…")
            if await authenticatedClient(settings: settings) != nil {
                statusText = "Connection OK"
            }
        }
    }

    /// Validates the credentials, loads the private key and requests a bearer token.
    /// On success the Key ID is marked as verified (and masked in the UI).
    private func authenticatedClient(settings: SettingsStore) async -> ABMClient? {
        let clientID = settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyID = settings.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !keyID.isEmpty else {
            fail("Client ID and Key ID are required.")
            return nil
        }
        guard let pemURL = settings.pemURL else {
            fail("Choose the .pem private key file.")
            return nil
        }

        let pemAccess = pemURL.startAccessingSecurityScopedResource()
        defer { if pemAccess { pemURL.stopAccessingSecurityScopedResource() } }

        do {
            let pem = try String(contentsOf: pemURL, encoding: .utf8)
            let client = try ABMClient(clientID: clientID, keyID: keyID, pem: pem, mode: settings.mode) { [weak self] message in
                Task { @MainActor [weak self] in self?.append(.warning, message) }
            }
            statusText = "Authenticating…"
            append(.info, "Requesting bearer token…")
            try await client.authenticate()
            append(.success, "Bearer token obtained — credentials verified")
            settings.keyIDVerified = true
            return client
        } catch {
            fail(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Run

    private func run(settings: SettingsStore) async {
        isRunning = true
        stats = SyncStats()
        writtenFiles = []
        let started = Date()
        defer {
            isRunning = false
            let elapsed = Duration.seconds(Date().timeIntervalSince(started))
            append(.info, "Runtime: \(elapsed.formatted(.time(pattern: .hourMinuteSecond)))")
        }

        // Equivalent of `caffeinate`: keep the Mac awake while syncing.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Syncing purchase information from Apple Business Manager")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        guard let outputURL = settings.outputURL else { return fail("Choose an output folder.") }
        let outAccess = outputURL.startAccessingSecurityScopedResource()
        defer { if outAccess { outputURL.stopAccessingSecurityScopedResource() } }

        // Output selection.
        let familyFilter = Set(settings.familyFilter
            .split(separator: ",")
            .map { normalizeFamily(String($0)) }
            .filter { !$0.isEmpty })
        var wantComputer = settings.deviceFilter != .mobile
        var wantMobile = settings.deviceFilter != .mac
        if !familyFilter.isEmpty {
            if familyFilter == ["mac"] { wantMobile = false }
            if !familyFilter.contains("mac") { wantComputer = false }
        }

        let computerURL = outputURL.appending(path: csvName(settings.computerFileName))
        let mobileURL = outputURL.appending(path: csvName(settings.mobileFileName))
        let preloadURL = outputURL.appending(path: csvName(settings.preloadFileName))

        append(.success, "Mode: \(settings.mode.title)")
        append(.info, "Device filter: \(settings.deviceFilter.title) | Family filter: \(familyFilter.isEmpty ? "(none)" : settings.familyFilter)")

        // Authenticate before touching any output files.
        guard let client = await authenticatedClient(settings: settings) else { return }

        // Prepare output files (fresh or incremental).
        let computerFile = CSVFile(url: computerURL, header: Self.computerHeader, serialHeader: "Computer Serial")
        let mobileFile = CSVFile(url: mobileURL, header: Self.mobileHeader, serialHeader: "Mobile Device Serial")
        let preloadFile = CSVFile(url: preloadURL, header: Self.preloadHeader, serialHeader: "Serial Number")
        do {
            if wantComputer { try prepare(computerFile, incremental: settings.incremental) }
            if wantMobile { try prepare(mobileFile, incremental: settings.incremental) }
            try prepare(preloadFile, incremental: settings.incremental)
        } catch {
            return fail("Could not prepare output files: \(error.localizedDescription)")
        }

        // Vendor resolution: local table first, then live API lookup (cached).
        let vendorTable = settings.vendorLookup
        var vendorCache: [String: String] = [:]
        func vendorDisplay(for device: OrgDevice) async -> String {
            let id = device.purchaseSourceID
            guard !id.isEmpty else { return device.purchaseSourceType }
            if let name = vendorTable[id] { return "\(name) (\(id))" }
            if let cached = vendorCache[id] { return cached }
            let display: String
            if let name = await client.fetchPurchaseSourceName(id: id) {
                display = "\(name) (\(id))"
                append(.warning, "Vendor \(id) not in lookup table — resolved via API as \"\(name)\". Consider adding it.")
            } else {
                display = device.purchaseSourceType.isEmpty ? id : "\(device.purchaseSourceType) (\(id))"
                append(.warning, "Vendor \(id) not in lookup table and could not be resolved.")
            }
            vendorCache[id] = display
            return display
        }

        // Page through devices.
        var cursor: String?
        do {
            repeat {
                try Task.checkCancellation()
                stats.pages += 1
                statusText = "Fetching page \(stats.pages)…"
                let page = try await client.fetchDevicePage(cursor: cursor)
                append(.info, "Page \(stats.pages): \(page.devices.count) devices")

                for device in page.devices {
                    try Task.checkCancellation()
                    stats.totalDevices += 1

                    let family = normalizeFamily(device.productFamily)
                    let isMac = family == "mac"
                    if !familyFilter.isEmpty && !familyFilter.contains(family) { stats.filtered += 1; continue }
                    if (isMac && !wantComputer) || (!isMac && !wantMobile) { stats.filtered += 1; continue }

                    let templateFile = isMac ? computerFile : mobileFile
                    let needsTemplate = !templateFile.knownSerials.contains(device.serial)
                    let needsPreload = !preloadFile.knownSerials.contains(device.serial)
                    guard needsTemplate || needsPreload else { stats.skipped += 1; continue }

                    statusText = "Processing \(device.serial)…"
                    let vendor = await vendorDisplay(for: device)

                    // Coverage: prefer ACTIVE AppleCare, fall back to Limited Warranty.
                    var warrantyExpires = ""
                    var appleCareID = ""
                    do {
                        let coverage = try await client.fetchCoverage(serial: device.serial)
                        let appleCare = coverage.filter { $0.description != "Limited Warranty" }
                        if let active = appleCare.first(where: { $0.status == "ACTIVE" }) {
                            warrantyExpires = active.endDate
                        } else if let limited = coverage.first(where: { $0.description == "Limited Warranty" }) {
                            warrantyExpires = limited.endDate
                        }
                        let preferred = appleCare.first(where: { $0.status == "ACTIVE" }) ?? appleCare.first
                        appleCareID = preferred?.agreementNumber ?? ""
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        stats.coverageErrors += 1
                        append(.error, "Coverage unavailable for \(device.serial): \(error.localizedDescription)")
                    }

                    if needsTemplate {
                        let row = isMac
                            ? computerRow(device, vendor: vendor, warranty: warrantyExpires, appleCareID: appleCareID)
                            : mobileRow(device, vendor: vendor, warranty: warrantyExpires, appleCareID: appleCareID)
                        try templateFile.append(row: row)
                        if isMac { stats.newComputers += 1 } else { stats.newMobile += 1 }
                    }
                    if needsPreload {
                        try preloadFile.append(row: preloadRow(device, isMac: isMac, vendor: vendor, warranty: warrantyExpires, appleCareID: appleCareID))
                    }
                    append(.success, "\(device.serial) (\(device.productFamily)) — \(vendor.isEmpty ? "no vendor" : vendor)")

                    try await Task.sleep(for: deviceDelay)
                }

                cursor = page.nextCursor
                if cursor != nil { try await Task.sleep(for: pageDelay) }
            } while cursor != nil
        } catch is CancellationError {
            statusText = "Cancelled"
            append(.warning, "Sync cancelled. Rows written so far have been kept.")
            finish(files: [wantComputer ? computerFile : nil, wantMobile ? mobileFile : nil, preloadFile])
            return
        } catch {
            fail(error.localizedDescription)
            finish(files: [wantComputer ? computerFile : nil, wantMobile ? mobileFile : nil, preloadFile])
            return
        }

        finish(files: [wantComputer ? computerFile : nil, wantMobile ? mobileFile : nil, preloadFile])
        statusText = "Complete"
        append(.success, "Sync complete — \(stats.totalDevices) devices in \(settings.mode == .abm ? "ABM" : "ASM"), \(stats.newComputers) computers / \(stats.newMobile) mobile written, \(stats.skipped) already present, \(stats.filtered) filtered, \(stats.coverageErrors) coverage errors.")
    }

    private func fail(_ message: String) {
        statusText = "Failed"
        append(.error, message)
    }

    private func finish(files: [CSVFile?]) {
        writtenFiles = files.compactMap { $0?.url }.filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in writtenFiles { append(.info, "Output: \(url.lastPathComponent)") }
    }

    private func prepare(_ file: CSVFile, incremental: Bool) throws {
        if incremental, FileManager.default.fileExists(atPath: file.url.path) {
            try file.loadKnownSerials()
            append(.info, "\(file.url.lastPathComponent): \(file.knownSerials.count) existing serials — appending new devices only")
        } else {
            try file.create()
            append(.info, "Created \(file.url.lastPathComponent)")
        }
    }

    // MARK: - Row builders

    private func computerRow(_ d: OrgDevice, vendor: String, warranty: String, appleCareID: String) -> [CSVField] {
        var row = [CSVField](repeating: .empty, count: Self.computerHeader.count)
        row[0] = .quoted(d.serial)
        row[13] = .quoted(d.orderNumber)
        row[14] = .quoted(vendor)
        row[16] = .quoted(d.orderDate)
        row[17] = .quoted(warranty)
        row[20] = .quoted(appleCareID)
        return row
    }

    private func mobileRow(_ d: OrgDevice, vendor: String, warranty: String, appleCareID: String) -> [CSVField] {
        var row = [CSVField](repeating: .empty, count: Self.mobileHeader.count)
        row[0] = .quoted(d.serial)
        row[12] = .quoted(d.orderNumber)
        row[13] = .quoted(vendor)
        row[15] = .quoted(d.orderDate)
        row[16] = .quoted(warranty)
        row[19] = .quoted(appleCareID)
        return row
    }

    private func preloadRow(_ d: OrgDevice, isMac: Bool, vendor: String, warranty: String, appleCareID: String) -> [CSVField] {
        var row = [CSVField](repeating: .empty, count: Self.preloadHeader.count)
        row[0] = .plain(d.serial)
        row[1] = .plain(isMac ? "Computer" : "Mobile Device")
        row[10] = .plain(d.orderNumber)
        row[11] = .plain(d.orderDate)
        row[12] = .plain(warranty)
        row[13] = .plain(appleCareID)
        row[17] = .plain(vendor)          // Purchasing Contact (matches existing preload template)
        return row
    }

    // MARK: - Helpers

    private func normalizeFamily(_ value: String) -> String {
        value.lowercased().filter { $0 != " " && $0 != "-" }
    }

    private func csvName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "output" : trimmed
        return base.lowercased().hasSuffix(".csv") ? base : base + ".csv"
    }
}

// MARK: - CSV

/// A CSV cell. `quoted` always wraps in quotes (MUT template style); `plain` quotes only when required.
enum CSVField {
    case empty
    case plain(String)
    case quoted(String)

    var encoded: String {
        switch self {
        case .empty:
            return ""
        case .quoted(let value):
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .plain(let value):
            if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }
    }
}

/// An output CSV file that is written incrementally (row by row) so progress survives interruption.
final class CSVFile {
    let url: URL
    let header: [String]
    let serialHeader: String
    private(set) var knownSerials: Set<String> = []

    init(url: URL, header: [String], serialHeader: String) {
        self.url = url
        self.header = header
        self.serialHeader = serialHeader
    }

    func create() throws {
        try (header.joined(separator: ",") + "\n").write(to: url, atomically: true, encoding: .utf8)
        knownSerials = []
    }

    /// Reads the first column of an existing file so already-present serials can be skipped.
    func loadKnownSerials() throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var serials = Set<String>()
        for line in contents.split(whereSeparator: \.isNewline) {
            let first = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let serial = first.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            if !serial.isEmpty && serial != serialHeader { serials.insert(serial) }
        }
        knownSerials = serials
        // Make sure appended rows start on a new line.
        if !contents.isEmpty && !contents.hasSuffix("\n") {
            try appendRaw("\n")
        }
    }

    func append(row: [CSVField]) throws {
        try appendRaw(row.map(\.encoded).joined(separator: ",") + "\n")
        if case .quoted(let serial) = row.first { knownSerials.insert(serial) }
        if case .plain(let serial) = row.first { knownSerials.insert(serial) }
    }

    private func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
