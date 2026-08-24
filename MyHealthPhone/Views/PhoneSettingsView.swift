import SwiftUI
import HealthCore
import HealthIntelligence

struct PhoneSettingsView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Look up food online", isOn: $model.allowNetworkLookups)
                    if model.allowNetworkLookups {
                        SecureField("FoodData Central API key (optional)",
                                    text: $model.foodDataCentralKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    }
                } header: {
                    Text("Nutrition lookups")
                } footer: {
                    Text(model.allowNetworkLookups
                         ? "Food names you log are sent to Open Food Facts, and to USDA FoodData Central if you add a key, to fetch nutrition figures. Only the name of the food is sent — never your health data, your weight, or anything about where you were. Turn this off and the app uses its built-in table only, and nothing leaves this phone."
                         : "Nothing leaves this phone. Nutrition comes from the built-in table and, where Apple Intelligence is available, its own estimates.")
                }

                Section("What is switched on") {
                    ForEach(model.capabilities, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(.callout)
                    }
                }

                Section {
                    HStack {
                        Text("iCloud")
                        Spacer()
                        Text(model.syncSummary)
                            .foregroundStyle(model.syncIsHealthy ? .secondary : .orange)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Sync now") { Task { await model.refreshAndResolve() } }
                    Button("Re-upload everything") { Task { await model.fullResync() } }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Your log is saved on this device the moment you log it, and uploaded afterwards. Losing connection never loses an entry — it waits in a queue and goes up when you are back online.")
                }

                Section {
                    HStack {
                        Text("Waiting to be looked up")
                        Spacer()
                        Text("\(model.pendingCount)").foregroundStyle(.secondary)
                    }
                    Button("Look up now") {
                        Task { await model.resolvePending() }
                    }
                    .disabled(model.isResolving || model.pendingCount == 0)
                } header: {
                    Text("Queue")
                } footer: {
                    Text("Items logged on the Watch arrive here as estimates. The phone has the language model and the network, so it finishes them off and syncs the corrected figures back.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
