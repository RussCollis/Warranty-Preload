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
    var copied = 0
    var filtered = 0
    var coverageErrors = 0
    var pages = 0
    var jamfUpdated = 0
    var jamfUpToDate = 0
    var jamfNotFound = 0
    var jamfErrors = 0
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

    /// Jamf Pro connection and inventory (keyed by serial) for the current run, when enabled.
    private var jamf: JamfClient?
    private var jamfDevices: [String: JamfDevice] = [:]
    private var jamfOverwrite = false
    /// Serials already pushed to Jamf from the saved files before the ABM pull.
    private var jamfSynced: Set<String> = []

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
            guard await authenticatedClient(settings: settings) != nil else { return }
            if settings.jamfEnabled {
                guard await authenticatedJamfClient(settings: settings) != nil else { return }
            }
            statusText = "Connection OK"
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

    /// Creates a Jamf Pro client and requests a token.
    private func authenticatedJamfClient(settings: SettingsStore) async -> JamfClient? {
        guard settings.jamfConfigured else {
            fail("Jamf Pro URL, API Client ID and Client Secret are required.")
            return nil
        }
        do {
            let client = try JamfClient(url: settings.jamfURL,
                                        clientID: settings.jamfClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                        clientSecret: settings.jamfClientSecret) { [weak self] message in
                Task { @MainActor [weak self] in self?.append(.warning, message) }
            }
            append(.info, "Requesting Jamf Pro token…")
            try await client.authenticate()
            append(.success, "Jamf Pro token obtained")
            return client
        } catch {
            fail(error.localizedDescription)
            return nil
        }
    }

    /// Authenticates to Jamf Pro and loads the inventory needed for this run.
    private func prepareJamf(settings: SettingsStore, computers: Bool, mobile: Bool) async -> Bool {
        guard let client = await authenticatedJamfClient(settings: settings) else { return false }
        do {
            statusText = "Reading Jamf Pro inventory…"
            var devices: [String: JamfDevice] = [:]
            if computers {
                let found = try await client.fetchComputers()
                append(.info, "Jamf Pro: \(found.count) computers")
                devices.merge(found) { first, _ in first }
            }
            if mobile {
                let found = try await client.fetchMobileDevices()
                append(.info, "Jamf Pro: \(found.count) mobile devices")
                devices.merge(found) { first, _ in first }
            }
            jamf = client
            jamfDevices = devices
            jamfOverwrite = settings.jamfOverwrite
            return true
        } catch {
            fail("Could not read Jamf Pro inventory: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes a device's purchase data to its Jamf Pro record when it differs.
    /// Errors are logged and counted; only cancellation is rethrown.
    private func syncToJamf(_ info: PurchaseInfo, isMac: Bool) async throws {
        guard let jamf else { return }
        // Devices handled by the saved-file pass were already counted; only an actual change is reported again.
        let alreadyCounted = jamfSynced.contains(info.serial)
        guard let device = jamfDevices[info.serial], device.isMac == isMac else {
            if !alreadyCounted { stats.jamfNotFound += 1 }
            return
        }

        // Only fields with an ABM value that differ (or, without overwrite, are empty in Jamf).
        func change(_ new: String, _ current: String) -> String {
            let new = new.trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new != current else { return "" }
            return jamfOverwrite || current.isEmpty ? new : ""
        }
        let current = device.purchasing
        let changes = JamfPurchasing(
            poNumber: change(info.orderNumber, current.poNumber),
            poDate: change(info.orderDate, current.poDate),
            vendor: change(info.vendor, current.vendor),
            warrantyDate: change(info.warranty, current.warrantyDate),
            appleCareID: change(info.appleCareID, current.appleCareID))
        guard changes != JamfPurchasing() else {
            if !alreadyCounted { stats.jamfUpToDate += 1 }
            return
        }

        do {
            try await jamf.updatePurchasing(device, changes: changes)
            stats.jamfUpdated += 1
            append(.success, "\(info.serial) — updated in Jamf Pro")
            // Keep the cached copy current in case the serial appears again.
            var updated = device
            for (keyPath, value) in [(\JamfPurchasing.poNumber, changes.poNumber), (\.poDate, changes.poDate),
                                     (\.vendor, changes.vendor), (\.warrantyDate, changes.warrantyDate),
                                     (\.appleCareID, changes.appleCareID)] where !value.isEmpty {
                updated.purchasing[keyPath: keyPath] = value
            }
            jamfDevices[info.serial] = updated
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            stats.jamfErrors += 1
            append(.error, "Jamf Pro update failed for \(info.serial): \(error.localizedDescription)")
        }
    }

    /// Pushes the purchase data already saved in the output files to Jamf Pro, before contacting ABM.
    /// Template rows take precedence over preload rows; preload-only devices use Jamf's own device type.
    private func syncSavedFilesToJamf(computerFile: CSVFile?, mobileFile: CSVFile?, preloadFile: CSVFile) async throws {
        guard jamf != nil else { return }
        var saved: [String: (info: PurchaseInfo, isMac: Bool?)] = [:]
        for (serial, info) in preloadFile.records { saved[serial] = (info, nil) }
        for (serial, info) in mobileFile?.records ?? [:] { saved[serial] = (info, false) }
        for (serial, info) in computerFile?.records ?? [:] { saved[serial] = (info, true) }
        guard !saved.isEmpty else { return }

        statusText = "Updating Jamf Pro from saved files…"
        append(.info, "Jamf Pro: applying \(saved.count) saved devices from the output files…")
        for (serial, entry) in saved.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            try await syncToJamf(entry.info, isMac: entry.isMac ?? jamfDevices[serial]?.isMac ?? false)
            jamfSynced.insert(serial)
        }
        append(.success, "Jamf Pro (saved files) — \(stats.jamfUpdated) updated, \(stats.jamfUpToDate) already up to date, \(stats.jamfNotFound) not in Jamf, \(stats.jamfErrors) errors.")
    }

    // MARK: - Run

    private func run(settings: SettingsStore) async {
        isRunning = true
        stats = SyncStats()
        writtenFiles = []
        let started = Date()
        jamf = nil
        jamfDevices = [:]
        jamfSynced = []
        defer {
            isRunning = false
            jamf = nil
            jamfDevices = [:]
            jamfSynced = []
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
        if settings.jamfEnabled {
            guard await prepareJamf(settings: settings, computers: wantComputer, mobile: wantMobile) else { return }
        }

        // Always read existing files first so devices already present are never downloaded again.
        let computerFile = CSVFile(url: computerURL, header: Self.computerHeader, columns: .computerTemplate)
        let mobileFile = CSVFile(url: mobileURL, header: Self.mobileHeader, columns: .mobileTemplate)
        let preloadFile = CSVFile(url: preloadURL, header: Self.preloadHeader, columns: .inventoryPreload)
        do {
            if wantComputer { try prepare(computerFile) }
            if wantMobile { try prepare(mobileFile) }
            try prepare(preloadFile)
        } catch {
            return fail("Could not prepare output files: \(error.localizedDescription)")
        }

        // Update Jamf from what is already saved locally first; the ABM pass below then only
        // touches Jamf for devices whose data is new or changed.
        do {
            try await syncSavedFilesToJamf(computerFile: wantComputer ? computerFile : nil,
                                           mobileFile: wantMobile ? mobileFile : nil,
                                           preloadFile: preloadFile)
        } catch {
            statusText = "Cancelled"
            append(.warning, "Sync cancelled before contacting \(settings.mode == .abm ? "ABM" : "ASM").")
            return
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
                    let templateRecord = templateFile.records[device.serial]
                    let preloadRecord = preloadFile.records[device.serial]
                    let needsTemplate = templateRecord == nil
                    let needsPreload = preloadRecord == nil
                    guard needsTemplate || needsPreload else {
                        stats.skipped += 1
                        // Already pushed to Jamf from the saved files — nothing new to send.
                        if !jamfSynced.contains(device.serial), let existing = templateRecord ?? preloadRecord {
                            try await syncToJamf(existing, isMac: isMac)
                        }
                        continue
                    }

                    // Already in the other file? Copy its data instead of calling the API again.
                    // Template rows are always complete; preload rows only count if they hold purchase data
                    // (older preload files may contain just the vendor).
                    if let existing = templateRecord ?? preloadRecord.flatMap({ $0.hasPurchaseData ? $0 : nil }) {
                        let info = PurchaseInfo(
                            serial: device.serial,
                            orderNumber: existing.orderNumber.isEmpty ? device.orderNumber : existing.orderNumber,
                            orderDate: existing.orderDate.isEmpty ? device.orderDate : existing.orderDate,
                            vendor: existing.vendor.isEmpty ? await vendorDisplay(for: device) : existing.vendor,
                            warranty: existing.warranty,
                            appleCareID: existing.appleCareID)
                        try write(info, isMac: isMac, toTemplate: needsTemplate ? templateFile : nil,
                                  toPreload: needsPreload ? preloadFile : nil)
                        stats.copied += 1
                        try await syncToJamf(info, isMac: isMac)
                        append(.info, "\(device.serial) — copied from existing \(needsTemplate ? preloadFile.url.lastPathComponent : templateFile.url.lastPathComponent)")
                        continue
                    }

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

                    let info = PurchaseInfo(serial: device.serial, orderNumber: device.orderNumber,
                                            orderDate: device.orderDate, vendor: vendor,
                                            warranty: warrantyExpires, appleCareID: appleCareID)
                    try write(info, isMac: isMac, toTemplate: needsTemplate ? templateFile : nil,
                              toPreload: needsPreload ? preloadFile : nil)
                    append(.success, "\(device.serial) (\(device.productFamily)) — \(vendor.isEmpty ? "no vendor" : vendor)")
                    try await syncToJamf(info, isMac: isMac)

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
        append(.success, "Sync complete — \(stats.totalDevices) devices in \(settings.mode == .abm ? "ABM" : "ASM"), \(stats.newComputers) computers / \(stats.newMobile) mobile written, \(stats.skipped) already present, \(stats.copied) copied between files, \(stats.filtered) filtered, \(stats.coverageErrors) coverage errors.")
        if settings.jamfEnabled {
            append(.success, "Jamf Pro — \(stats.jamfUpdated) updated, \(stats.jamfUpToDate) already up to date, \(stats.jamfNotFound) not in Jamf, \(stats.jamfErrors) errors.")
        }
    }

    private func fail(_ message: String) {
        statusText = "Failed"
        append(.error, message)
    }

    private func finish(files: [CSVFile?]) {
        writtenFiles = files.compactMap { $0?.url }.filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in writtenFiles { append(.info, "Output: \(url.lastPathComponent)") }
    }

    /// Loads an existing file's rows (so those devices are skipped), or creates the file with its header.
    private func prepare(_ file: CSVFile) throws {
        if FileManager.default.fileExists(atPath: file.url.path) {
            try file.loadExisting()
            append(.info, "\(file.url.lastPathComponent): \(file.records.count) existing devices read — only new devices will be added")
        } else {
            try file.create()
            append(.info, "Created \(file.url.lastPathComponent)")
        }
    }

    // MARK: - Row builders

    /// Appends the missing row(s) for a device.
    private func write(_ info: PurchaseInfo, isMac: Bool, toTemplate templateFile: CSVFile?, toPreload preloadFile: CSVFile?) throws {
        if let templateFile {
            try templateFile.append(row: isMac ? computerRow(info) : mobileRow(info))
            if isMac { stats.newComputers += 1 } else { stats.newMobile += 1 }
        }
        if let preloadFile {
            try preloadFile.append(row: preloadRow(info, isMac: isMac))
        }
    }

    private func computerRow(_ info: PurchaseInfo) -> [CSVField] {
        var row = [CSVField](repeating: .empty, count: Self.computerHeader.count)
        row[0] = .quoted(info.serial)
        row[13] = .quoted(info.orderNumber)
        row[14] = .quoted(info.vendor)
        row[16] = .quoted(info.orderDate)
        row[17] = .quoted(info.warranty)
        row[20] = .quoted(info.appleCareID)
        return row
    }

    private func mobileRow(_ info: PurchaseInfo) -> [CSVField] {
        var row = [CSVField](repeating: .empty, count: Self.mobileHeader.count)
        row[0] = .quoted(info.serial)
        row[12] = .quoted(info.orderNumber)
        row[13] = .quoted(info.vendor)
        row[15] = .quoted(info.orderDate)
        row[16] = .quoted(info.warranty)
        row[19] = .quoted(info.appleCareID)
        return row
    }

    private func preloadRow(_ info: PurchaseInfo, isMac: Bool) -> [CSVField] {
        var row = [CSVField](repeating: .empty, count: Self.preloadHeader.count)
        row[0] = .plain(info.serial)
        row[1] = .plain(isMac ? "Computer" : "Mobile Device")
        row[10] = .plain(info.orderNumber)
        row[11] = .plain(info.orderDate)
        row[12] = .plain(info.warranty)
        row[13] = .plain(info.appleCareID)
        row[17] = .plain(info.vendor)          // Purchasing Contact (matches existing preload template)
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

/// The purchase data written for one device.
struct PurchaseInfo {
    var serial: String
    var orderNumber: String
    var orderDate: String
    var vendor: String
    var warranty: String
    var appleCareID: String

    /// True when the row holds more than just a serial/vendor (i.e. coverage or order data was captured).
    var hasPurchaseData: Bool {
        !orderNumber.isEmpty || !orderDate.isEmpty || !warranty.isEmpty || !appleCareID.isEmpty
    }
}

/// Which header names hold each value in a given template.
struct CSVColumns {
    let serial: String
    let orderNumber: String
    let orderDate: String
    let vendor: [String]        // first non-empty wins
    let warranty: String
    let appleCareID: String

    static let computerTemplate = CSVColumns(serial: "Computer Serial", orderNumber: "PO Number", orderDate: "PO Date",
                                             vendor: ["Vendor"], warranty: "Warranty Expires", appleCareID: "AppleCare ID")
    static let mobileTemplate = CSVColumns(serial: "Mobile Device Serial", orderNumber: "PO Number", orderDate: "PO Date",
                                           vendor: ["Vendor"], warranty: "Warranty Expires", appleCareID: "AppleCare ID")
    static let inventoryPreload = CSVColumns(serial: "Serial Number", orderNumber: "PO Number", orderDate: "PO Date",
                                             vendor: ["Purchasing Contact", "Vendor"], warranty: "Warranty Expiration",
                                             appleCareID: "Apple Care ID")
}

/// An output CSV file that is written incrementally (row by row) so progress survives interruption.
/// Existing rows are read first so those devices are not downloaded again.
final class CSVFile {
    let url: URL
    let header: [String]
    let columns: CSVColumns
    /// Existing rows keyed by serial number.
    private(set) var records: [String: PurchaseInfo] = [:]

    init(url: URL, header: [String], columns: CSVColumns) {
        self.url = url
        self.header = header
        self.columns = columns
    }

    func create() throws {
        try (header.joined(separator: ",") + "\n").write(to: url, atomically: true, encoding: .utf8)
        records = [:]
    }

    /// Parses an existing file. The header must match the template so appended rows line up.
    func loadExisting() throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let rows = CSVParser.parse(contents)

        guard let fileHeader = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces) }) else {
            // Empty file: just write the header.
            return try create()
        }
        guard fileHeader == header else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) has different columns from the expected template. Rename or move it so a new file can be created."
            ])
        }

        let index = Dictionary(fileHeader.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func value(_ row: [String], _ name: String) -> String {
            guard let i = index[name], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        var loaded: [String: PurchaseInfo] = [:]
        for row in rows.dropFirst() {
            let serial = value(row, columns.serial)
            guard !serial.isEmpty else { continue }
            loaded[serial] = PurchaseInfo(
                serial: serial,
                orderNumber: value(row, columns.orderNumber),
                orderDate: value(row, columns.orderDate),
                vendor: columns.vendor.lazy.map { value(row, $0) }.first { !$0.isEmpty } ?? "",
                warranty: value(row, columns.warranty),
                appleCareID: value(row, columns.appleCareID))
        }
        records = loaded

        // Make sure appended rows start on a new line.
        if !contents.isEmpty && !contents.hasSuffix("\n") {
            try appendRaw("\n")
        }
    }

    func append(row: [CSVField]) throws {
        try appendRaw(row.map(\.encoded).joined(separator: ",") + "\n")
        // Track the serial so the same device is never written twice in one run.
        switch row.first {
        case .quoted(let serial), .plain(let serial):
            records[serial] = records[serial] ?? PurchaseInfo(serial: serial, orderNumber: "", orderDate: "",
                                                              vendor: "", warranty: "", appleCareID: "")
        default:
            break
        }
    }

    private func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

/// Minimal RFC 4180 CSV parser (quoted fields, escaped quotes, embedded commas/newlines, CRLF, BOM).
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let c = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": endField()
            case "\r":
                let next = iterator.next()
                if next != "\n" { pending = next }
                endRow()
            case "\n": endRow()
            case "\u{FEFF}" where field.isEmpty && row.isEmpty && rows.isEmpty: break   // BOM
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
