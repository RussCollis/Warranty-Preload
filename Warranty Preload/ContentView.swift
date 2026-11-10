import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var settings = SettingsStore()
    @State private var engine = SyncEngine()

    var body: some View {
        HSplitView {
            SettingsPane(settings: settings, isRunning: engine.isRunning)
                .frame(minWidth: 460, idealWidth: 500)
            ActivityPane(settings: settings, engine: engine)
                .frame(minWidth: 420)
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}

// MARK: - Settings

private struct SettingsPane: View {
    @Bindable var settings: SettingsStore
    let isRunning: Bool

    @State private var showingPEMPicker = false
    @State private var showingFolderPicker = false
    @State private var showingClearConfirmation = false
    @State private var selectedVendors = Set<VendorEntry.ID>()

    var body: some View {
        Form {
            Section("Apple Business Manager API") {
                Picker("Service", selection: $settings.mode) {
                    ForEach(ServiceMode.allCases) { Text($0.title).tag($0) }
                }
                TextField("Client ID", text: $settings.clientID, prompt: Text("BUSINESSAPI.xxxxxxxx-…"))
                if settings.keyIDVerified {
                    // Once tested successfully the Key ID is hidden; "Change" reveals it for editing.
                    LabeledContent("Key ID") {
                        HStack {
                            Text(String(repeating: "•", count: 12) + "-" + String(settings.keyID.suffix(4)))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                            Label("Verified", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                                .help("Verified by a successful token request")
                            Button("Change") { settings.keyIDVerified = false }
                        }
                    }
                } else {
                    TextField("Key ID", text: $settings.keyID, prompt: Text("xxxxxxxx-xxxx-…"))
                }
                LabeledContent("Private Key (.pem)") {
                    HStack {
                        Text(settings.pemURL?.lastPathComponent ?? "Not selected")
                            .foregroundStyle(settings.pemURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.pemURL?.path ?? "")
                        Button("Choose…") { showingPEMPicker = true }
                    }
                }
                .fileImporter(isPresented: $showingPEMPicker,
                              allowedContentTypes: [UTType(filenameExtension: "pem") ?? .data, .data]) { result in
                    if case .success(let url) = result { settings.setPEM(url) }
                }
            }

            Section {
                LabeledContent("Output Folder") {
                    HStack {
                        Text(settings.outputURL?.lastPathComponent ?? "Not selected")
                            .foregroundStyle(settings.outputURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.outputURL?.path ?? "")
                        Button("Choose…") { showingFolderPicker = true }
                    }
                }
                .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { settings.setOutputFolder(url) }
                }
                TextField("Computer Template", text: $settings.computerFileName)
                if settings.deviceFilter != .mac {
                    TextField("Mobile Device Template", text: $settings.mobileFileName)
                }
                TextField("Inventory Preload", text: $settings.preloadFileName)
                Picker("Devices", selection: $settings.deviceFilter) {
                    ForEach(DeviceFilter.allCases) { Text($0.title).tag($0) }
                }
                TextField("Product Families", text: $settings.familyFilter, prompt: Text("Optional, e.g. Mac, iPad"))
            } header: {
                Text("Output")
            } footer: {
                Text("Existing files in the output folder are always read first. Devices already listed are skipped, so only new devices are downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Table($settings.vendors, selection: $selectedVendors) {
                    TableColumn("Purchase Source ID") { $vendor in
                        TextField("ID", text: $vendor.sourceID)
                            .font(.body.monospaced())
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("Vendor Name") { $vendor in
                        TextField("Name", text: $vendor.name)
                    }
                }
                .frame(minHeight: 170)

                HStack {
                    Button("Add Vendor", systemImage: "plus") {
                        let entry = VendorEntry(sourceID: "", name: "")
                        settings.vendors.append(entry)
                        selectedVendors = [entry.id]
                    }
                    Button("Remove", systemImage: "minus") {
                        settings.vendors.removeAll { selectedVendors.contains($0.id) }
                        selectedVendors = []
                    }
                    .disabled(selectedVendors.isEmpty)
                    Spacer()
                    Button("Restore Defaults") { settings.resetVendorsToDefaults() }
                }
            } header: {
                Text("Vendors")
            } footer: {
                Text("Purchase source IDs are case-sensitive. Unknown IDs are looked up via the API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Update Jamf Pro devices automatically", isOn: $settings.jamfEnabled)
                if settings.jamfEnabled {
                    TextField("Jamf Pro URL", text: $settings.jamfURL, prompt: Text("https://yourorg.jamfcloud.com"))
                    TextField("API Client ID", text: $settings.jamfClientID)
                    SecureField("Client Secret", text: $settings.jamfClientSecret)
                    Toggle("Overwrite values already set in Jamf", isOn: $settings.jamfOverwrite)
                }
            } header: {
                Text("Jamf Pro")
            } footer: {
                Text("Each sync writes PO number, PO date, vendor, warranty date and AppleCare ID to matching computers and mobile devices in Jamf Pro (by serial number). Only changed fields are sent. The API role needs Read and Update for Computers and Mobile Devices. The secret is stored in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear Saved Settings…", role: .destructive) { showingClearConfirmation = true }
            }
        }
        .formStyle(.grouped)
        .disabled(isRunning)
        .confirmationDialog("Clear all saved settings?", isPresented: $showingClearConfirmation) {
            Button("Clear Settings", role: .destructive) { settings.clearAll() }
        } message: {
            Text("This removes the Client ID, Key ID, .pem location, output folder, custom vendors and Jamf Pro settings.")
        }
    }
}

// MARK: - Activity

private struct ActivityPane: View {
    let settings: SettingsStore
    let engine: SyncEngine

    private var canRun: Bool {
        !settings.clientID.isEmpty && !settings.keyID.isEmpty
            && settings.pemURL != nil && settings.outputURL != nil
            && (!settings.jamfEnabled || settings.jamfConfigured)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if engine.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel", role: .cancel) { engine.cancel() }
                } else {
                    Button("Sync Purchase Information", systemImage: "arrow.triangle.2.circlepath") {
                        engine.start(settings: settings)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                    Button("Test Connection") { engine.testConnection(settings: settings) }
                        .disabled(settings.clientID.isEmpty || settings.keyID.isEmpty || settings.pemURL == nil)
                }
                Text(engine.statusText)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            StatsGrid(stats: engine.stats, showJamf: settings.jamfEnabled)

            LogView(lines: engine.log)

            HStack {
                ForEach(engine.writtenFiles, id: \.self) { url in
                    Button(url.lastPathComponent, systemImage: "doc.text") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .help("Show in Finder")
                }
                Spacer()
                Button("Clear Log") { engine.clearLog() }
                    .disabled(engine.isRunning || engine.log.isEmpty)
            }
        }
        .padding()
    }
}

private struct StatsGrid: View {
    let stats: SyncStats
    let showJamf: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
            GridRow {
                stat("Devices", stats.totalDevices)
                stat("Computers", stats.newComputers)
                stat("Mobile", stats.newMobile)
            }
            GridRow {
                stat("Already present", stats.skipped)
                stat("Copied", stats.copied)
                stat("Filtered", stats.filtered)
                stat("Coverage errors", stats.coverageErrors)
            }
            if showJamf {
                GridRow {
                    stat("Jamf updated", stats.jamfUpdated)
                    stat("Up to date", stats.jamfUpToDate)
                    stat("Not in Jamf", stats.jamfNotFound)
                    stat("Jamf errors", stats.jamfErrors)
                }
            }
        }
        .font(.callout)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value, format: .number).monospacedDigit().bold()
        }
    }
}

private struct LogView: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: line.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            .onChange(of: lines.last?.id) { _, newID in
                if let newID { proxy.scrollTo(newID, anchor: .bottom) }
            }
        }
    }

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .info: .primary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

#Preview {
    ContentView()
}
