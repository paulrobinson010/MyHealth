import SwiftUI
import HealthCore
import HealthIntelligence

/// Talk to it, or tap a preset. Both end up in the same queue.
struct PhoneLogView: View {
    @EnvironmentObject private var model: PhoneModel
    @StateObject private var conversation = PhoneConversation()
    @State private var draft = ""
    @State private var showingPresets = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(conversation.bubbles) { bubble in
                                bubbleView(bubble).id(bubble.id)
                            }
                            if conversation.isThinking {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: conversation.bubbles.count) { _, _ in
                        withAnimation { proxy.scrollTo(conversation.bubbles.last?.id, anchor: .bottom) }
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    Button { showingPresets = true } label: {
                        Image(systemName: "list.bullet").font(.title3)
                    }
                    TextField("Two pints and a curry…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                              || conversation.isThinking)
                }
                .padding()
            }
            .navigationTitle("Log")
            .sheet(isPresented: $showingPresets) { PresetSheet() }
            .task { conversation.startIfNeeded(model: model) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await conversation.send(text, model: model) }
    }

    @ViewBuilder
    private func bubbleView(_ bubble: PhoneConversation.Bubble) -> some View {
        HStack {
            if bubble.isFromPerson { Spacer(minLength: 50) }
            VStack(alignment: bubble.isFromPerson ? .trailing : .leading, spacing: 6) {
                Text(bubble.text)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubble.isFromPerson
                                ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                : AnyShapeStyle(Color(.secondarySystemBackground)),
                                in: RoundedRectangle(cornerRadius: 14))
                ForEach(bubble.entries) { entry in
                    EntryRow(entry: entry)
                        .padding(10)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if !bubble.isFromPerson { Spacer(minLength: 50) }
        }
    }
}

struct PresetSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Drinks") {
                    ForEach(DrinkPreset.standard.filter { matches($0.name) }) { preset in
                        Button {
                            Task {
                                await model.log(FoodEntry(name: preset.name,
                                                          timestamp: Date().timeIntervalSince1970,
                                                          nutrition: preset.nutrition,
                                                          source: .catalogue,
                                                          resolution: .resolved(
                                                            NutritionProvenance(source: .computed,
                                                                                confidence: 0.95))),
                                                context: nil)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                Text(String(format: "%.1f units · %d kcal",
                                            preset.ukUnits, Int(preset.nutrition.kilocalories)))
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Food") {
                    ForEach(FoodPreset.catalogue.filter { matches($0.name) }) { preset in
                        Button {
                            Task {
                                await model.log(FoodEntry(name: preset.name,
                                                          timestamp: Date().timeIntervalSince1970,
                                                          nutrition: preset.nutrition,
                                                          source: .catalogue,
                                                          resolution: .resolved(
                                                            NutritionProvenance(source: .builtIn,
                                                                                confidence: 0.75))),
                                                context: nil)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                Text("\(Int(preset.nutrition.kilocalories)) kcal · \(preset.servingDescription)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Add")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }
}

@MainActor
final class PhoneConversation: ObservableObject {
    struct Bubble: Identifiable {
        let id = UUID()
        let isFromPerson: Bool
        let text: String
        var entries: [FoodEntry] = []
    }

    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var isThinking = false

    private let agent = LoggingAgent()
    private var started = false

    func startIfNeeded(model: PhoneModel) {
        guard !started else { return }
        started = true
        let hour = Calendar.current.component(.hour, from: Date())
        bubbles.append(Bubble(isFromPerson: false,
                              text: agent.greeting(alreadyLogged: model.log.total(on: .today),
                                                   timeOfDay: hour)))
    }

    func send(_ text: String, model: PhoneModel) async {
        bubbles.append(Bubble(isFromPerson: true, text: text))
        isThinking = true
        let turn = await agent.send(text)
        isThinking = false

        bubbles.append(Bubble(
            isFromPerson: false,
            text: [turn.reply, turn.followUpQuestion]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
            entries: turn.entries))

        for entry in turn.entries {
            await model.log(entry, context: turn.hasItems ? turn.context : nil)
        }
    }
}
