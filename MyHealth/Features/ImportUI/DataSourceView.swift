import SwiftUI
import UniformTypeIdentifiers
import AppKit
import HealthCore
import HealthUI
import HealthIntelligence

/// Where the data comes from, and how to keep it fresh.
struct DataSourceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingEraseConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                Text("Data Source").font(.title2.weight(.semibold))
                healthKitCard
                importCard
                watchedFolderCard
                statusCard
            }
            .padding(20)
        }
        .navigationTitle("Data Source")
    }

    // MARK: - HealthKit

    private var healthKitCard: some View {
        Card("HealthKit", subtitle: "Read directly from this Mac's health store") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: model.healthKitAvailability.isUsable
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.healthKitAvailability.isUsable ? .green : .orange)
                    Text(model.healthKitAvailability.message)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("macOS 26 (Tahoe) was the first release to give Mac apps HealthKit access. The Mac does not talk to your Apple Watch directly — data travels Watch → iPhone → iCloud Health sync → this Mac, so your iPhone still needs to be syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Sync now") {
                        Task { await model.syncFromHealthKit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.healthKitAvailability.isUsable || model.loadState.isWorking)

                    Picker("History", selection: $model.healthKitHistoryYears) {
                        Text("1 year").tag(1)
                        Text("3 years").tag(3)
                        Text("5 years").tag(5)
                        Text("10 years").tag(10)
                        Text("20 years").tag(20)
                    }
                    .frame(width: 180)

                    Toggle("Sync on launch", isOn: $model.autoSyncOnLaunch)
                }
            }
        }
    }

    // MARK: - File import

    private var importCard: some View {
        Card("Health export file", subtitle: "Works on any macOS version, and on Macs without HealthKit access") {
            VStack(alignment: .leading, spacing: 12) {
                Text("On your iPhone open **Health → your picture → Export All Health Data**. Save the `export.zip` somewhere this Mac can reach — iCloud Drive is the easy option — then import it here. Multi-gigabyte exports are fine; they stream rather than load into memory.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Import export.zip…") {
                        Task { await ImportPanel.present(model: model) }
                    }
                    .disabled(model.loadState.isWorking)

                    Button("Explore with sample data") {
                        Task { await model.loadSampleData() }
                    }
                    .disabled(model.loadState.isWorking)
                }
            }
        }
    }

    // MARK: - Watched folder

    private var watchedFolderCard: some View {
        Card("Watch a folder", subtitle: "Import automatically whenever a new export appears") {
            VStack(alignment: .leading, spacing: 12) {
                if let folder = model.watchedFolderURL {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Stop watching") { model.setWatchedFolder(nil) }
                        Button("Check now") {
                            Task { await model.importNewestExportFromWatchedFolder() }
                        }
                        .disabled(model.loadState.isWorking)
                    }
                } else {
                    Text("Point this at the iCloud Drive folder your phone saves exports into. When a newer export.zip lands there, MyHealth picks it up on its own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose folder…") { chooseFolder() }
                }
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        Card("Stored data") {
            if let database = model.database {
                VStack(alignment: .leading, spacing: 8) {
                    row("Source", model.sourceKind?.title ?? "Unknown")
                    if let name = database.sourceFileName { row("File", name) }
                    if let range = database.dateRange {
                        row("Covers", "\(Format.day(range.lowerBound)) – \(Format.day(range.upperBound))")
                    }
                    row("Days", Format.decimal(Double(database.days.count)))
                    row("Workouts", Format.decimal(Double(database.workouts.count)))
                    if let exported = database.exportedAt {
                        row("Exported", Format.dateTime(exported))
                    }
                    row("Last import", "\(Format.dateTime(database.importedAt)) (\(Format.relative(database.importedAt)))")
                    if let dob = database.profile.dateOfBirth {
                        row("Date of birth", Format.day(dob))
                    }
                    row("Biological sex", database.profile.biologicalSex.rawValue.capitalized)

                    Divider().padding(.vertical, 4)
                    Button("Erase stored data", role: .destructive) {
                        showingEraseConfirmation = true
                    }
                    .confirmationDialog("Erase the stored health database?",
                                        isPresented: $showingEraseConfirmation) {
                        Button("Erase", role: .destructive) { model.eraseStoredData() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This only deletes MyHealth's own copy in Application Support. Nothing in HealthKit or on your iPhone is touched.")
                    }
                }
            } else {
                Text("Nothing imported yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
            Spacer()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose the folder your Health exports are saved into."
        if panel.runModal() == .OK, let url = panel.url {
            model.setWatchedFolder(url)
            Task { await model.importNewestExportFromWatchedFolder() }
        }
    }
}

/// The open panel used from the toolbar, the menu bar and the empty state.
enum ImportPanel {
    @MainActor
    static func present(model: AppModel) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the export.zip from the iPhone Health app (or an export.xml)."
        panel.allowedContentTypes = [.zip, .xml, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await model.importExport(at: url)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("HealthKit") {
                Toggle("Sync automatically on launch", isOn: $model.autoSyncOnLaunch)
                Picker("History to read", selection: $model.healthKitHistoryYears) {
                    Text("1 year").tag(1)
                    Text("3 years").tag(3)
                    Text("5 years").tag(5)
                    Text("10 years").tag(10)
                    Text("20 years").tag(20)
                }
                Text(model.healthKitAvailability.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Automatic import") {
                if let folder = model.watchedFolderURL {
                    LabeledContent("Watched folder") {
                        Text(folder.lastPathComponent).truncationMode(.middle)
                    }
                    Button("Stop watching") { model.setWatchedFolder(nil) }
                } else {
                    Text("No folder is being watched. Set one up on the Data Source screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("iCloud") {
                    Text(model.syncSummary)
                        .foregroundStyle(model.syncIsHealthy ? Color.secondary : Color.orange)
                }
                Button("Sync now") { Task { await model.refreshFoodLogFromSync() } }
                Button("Re-upload everything") { Task { await model.fullResync() } }
            } header: {
                Text("Food log sync")
            } footer: {
                Text("Entries are saved on this Mac the instant you log them and uploaded afterwards, so losing connection never loses one. Only the food log syncs through iCloud — your health data comes from HealthKit on each device.")
                .font(.caption)
            }

            Section {
                Toggle("Look up food online", isOn: $model.allowNetworkLookups)
                if model.allowNetworkLookups {
                    SecureField("FoodData Central API key (optional)",
                                text: $model.foodDataCentralKey)
                }
                LabeledContent("Waiting to be looked up") {
                    Text("\(model.pendingLookupCount)")
                }
                Button("Look up now") {
                    Task { await model.resolvePendingNutrition() }
                }
                .disabled(model.isResolvingNutrition || model.pendingLookupCount == 0)
            } header: {
                Text("Nutrition lookups")
            } footer: {
                Text(model.allowNetworkLookups
                     ? "Food names you log are sent to Open Food Facts — and to USDA FoodData Central if you add a key — to fetch real nutrition figures. Only the name of the food is sent. Never your health data, your weight, your location or anything about where you were."
                     : "Switched off: nothing leaves this Mac. Nutrition comes from the built-in table and, where Apple Intelligence is available, its own estimates.")
                .font(.caption)
            }

            Section("What is switched on") {
                ForEach(model.lookupCapabilities, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle").font(.caption)
                }
            }

            Section("About the fitness index") {
                Text("The index blends cardio capacity, resting heart rate, heart rate variability, training volume, consistency and daily movement into one 0–100 number, scored against published population reference ranges for your age and sex. It is a way to see your own trajectory, not a medical assessment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
