import Foundation
import Observation

/// A single purchase source (reseller) mapping: ABM `purchaseSourceId` -> display name.
nonisolated struct VendorEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var sourceID: String
    var name: String
}

/// Which Apple management service to talk to.
nonisolated enum ServiceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case abm, asm
    var id: String { rawValue }
    var title: String { self == .abm ? "Apple Business Manager" : "Apple School Manager" }
    var apiBase: String { self == .abm ? "https://api-business.apple.com/v1" : "https://api-school.apple.com/v1" }
    var scope: String { self == .abm ? "business.api" : "school.api" }
}

/// Which device types to include in the output.
nonisolated enum DeviceFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case mac, mobile, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mac: "Mac only"
        case .mobile: "Mobile only"
        case .both: "Mac + Mobile"
        }
    }
}

/// Persists the user's configuration in UserDefaults until it is manually cleared.
/// File locations are stored as security-scoped bookmarks so they survive relaunches in the sandbox.
@Observable
final class SettingsStore {
    static let defaultVendors: [VendorEntry] = [
        VendorEntry(sourceID: "1C99B860", name: "O2 UK"),
        VendorEntry(sourceID: "2287450", name: "Jigsaw24"),
        VendorEntry(sourceID: "A3F0E30", name: "Viewdata Computing Ltd"),
        VendorEntry(sourceID: "892F050", name: "COMPUTACENTER (UK) LTD"),
        VendorEntry(sourceID: "1D0CDC710", name: "Vohkus Ltd"),
    ]

    private enum Key {
        static let clientID = "clientID"
        static let keyID = "keyID"
        static let keyIDVerified = "keyIDVerified"
        static let mode = "mode"
        static let deviceFilter = "deviceFilter"
        static let familyFilter = "familyFilter"
        static let computerFileName = "computerFileName"
        static let mobileFileName = "mobileFileName"
        static let preloadFileName = "preloadFileName"
        static let vendors = "vendors"
        static let pemBookmark = "pemBookmark"
        static let outputBookmark = "outputBookmark"
    }

    private let defaults = UserDefaults.standard

    var clientID: String { didSet { defaults.set(clientID, forKey: Key.clientID) } }
    var keyID: String {
        didSet {
            defaults.set(keyID, forKey: Key.keyID)
            // A changed Key ID has not been verified yet.
            if keyID != oldValue { keyIDVerified = false }
        }
    }
    /// Set after a successful token request; the UI masks the Key ID once verified.
    var keyIDVerified: Bool { didSet { defaults.set(keyIDVerified, forKey: Key.keyIDVerified) } }
    var mode: ServiceMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    var deviceFilter: DeviceFilter { didSet { defaults.set(deviceFilter.rawValue, forKey: Key.deviceFilter) } }
    var familyFilter: String { didSet { defaults.set(familyFilter, forKey: Key.familyFilter) } }
    var computerFileName: String { didSet { defaults.set(computerFileName, forKey: Key.computerFileName) } }
    var mobileFileName: String { didSet { defaults.set(mobileFileName, forKey: Key.mobileFileName) } }
    var preloadFileName: String { didSet { defaults.set(preloadFileName, forKey: Key.preloadFileName) } }
    var vendors: [VendorEntry] { didSet { saveVendors() } }

    /// Resolved locations (from saved bookmarks).
    private(set) var pemURL: URL?
    private(set) var outputURL: URL?

    init() {
        clientID = defaults.string(forKey: Key.clientID) ?? ""
        keyID = defaults.string(forKey: Key.keyID) ?? ""
        keyIDVerified = defaults.bool(forKey: Key.keyIDVerified)
        mode = ServiceMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .abm
        deviceFilter = DeviceFilter(rawValue: defaults.string(forKey: Key.deviceFilter) ?? "") ?? .mac
        familyFilter = defaults.string(forKey: Key.familyFilter) ?? ""
        computerFileName = defaults.string(forKey: Key.computerFileName) ?? "ComputerTemplate.csv"
        mobileFileName = defaults.string(forKey: Key.mobileFileName) ?? "MobileDeviceTemplate.csv"
        preloadFileName = defaults.string(forKey: Key.preloadFileName) ?? "inventory-preload-template.csv"

        if let data = defaults.data(forKey: Key.vendors),
           let saved = try? JSONDecoder().decode([VendorEntry].self, from: data) {
            vendors = saved
        } else {
            vendors = Self.defaultVendors
        }

        pemURL = resolveBookmark(forKey: Key.pemBookmark)
        outputURL = resolveBookmark(forKey: Key.outputBookmark)
    }

    /// Vendor lookup dictionary keyed by purchaseSourceId (case-sensitive, trimmed).
    var vendorLookup: [String: String] {
        var lookup: [String: String] = [:]
        for vendor in vendors {
            let id = vendor.sourceID.trimmingCharacters(in: .whitespaces)
            let name = vendor.name.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty && !name.isEmpty { lookup[id] = name }
        }
        return lookup
    }

    func setPEM(_ url: URL) {
        pemURL = url
        saveBookmark(for: url, forKey: Key.pemBookmark)
    }

    func setOutputFolder(_ url: URL) {
        outputURL = url
        saveBookmark(for: url, forKey: Key.outputBookmark)
    }

    func resetVendorsToDefaults() {
        vendors = Self.defaultVendors
    }

    /// Wipes everything saved and returns to first-launch defaults.
    func clearAll() {
        for key in [Key.clientID, Key.keyID, Key.keyIDVerified, Key.mode, Key.deviceFilter, Key.familyFilter,
                    Key.computerFileName, Key.mobileFileName, Key.preloadFileName,
                    Key.vendors, Key.pemBookmark, Key.outputBookmark] {
            defaults.removeObject(forKey: key)
        }
        clientID = ""
        keyID = ""
        keyIDVerified = false
        mode = .abm
        deviceFilter = .mac
        familyFilter = ""
        computerFileName = "ComputerTemplate.csv"
        mobileFileName = "MobileDeviceTemplate.csv"
        preloadFileName = "inventory-preload-template.csv"
        vendors = Self.defaultVendors
        pemURL = nil
        outputURL = nil
        defaults.removeObject(forKey: Key.vendors)
    }

    // MARK: - Persistence helpers

    private func saveVendors() {
        if let data = try? JSONEncoder().encode(vendors) {
            defaults.set(data, forKey: Key.vendors)
        }
    }

    private func saveBookmark(for url: URL, forKey key: String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            defaults.set(data, forKey: key)
        }
    }

    private func resolveBookmark(forKey key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        if isStale { saveBookmark(for: url, forKey: key) }
        return url
    }
}
