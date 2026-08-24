import SwiftUI
import HealthCore
import HealthUI
import HealthIntelligence

/// Two things live here: the written read on your fitness, and the
/// conversational food diary.
///
/// Both use Apple Intelligence, and neither depends on it. The verdict is
/// computed arithmetically and only phrased by the model; the diary falls back
/// to keyword matching against the built-in tables.
struct CoachView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var conversation = ConversationModel()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VSplitView {
            verdict
            diary
        }
        .navigationTitle("Coach")
    }

    // MARK: - Verdict

    private var verdict: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                Card("Are you fitter?",
                     subtitle: "Computed from your data, then written up") {
                    if let narrative = model.narrative {
                        Text(narrative)
                            .font(.callout)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Load some data and this fills in.")
                            .foregroundStyle(.secondary)
                    }

                    if !HealthCoach.availability.isUsable {
                        Label(HealthCoach.availability.message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let briefing = model.analytics.briefing, !briefing.suggestions.isEmpty {
                    Card("What would move the needle") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(briefing.suggestions.enumerated()), id: \.offset) { _, item in
                                Label(item, systemImage: "arrow.right.circle")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minHeight: 200, idealHeight: 320)
    }

    // MARK: - Diary

    private var diary: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Food diary", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                if !conversation.messages.isEmpty {
                    Button("Start over") { conversation.reset(model: model) }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(conversation.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if conversation.isThinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 10) {
                TextField("Two pints of IPA and a chicken curry at The Eagle…",
                          text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || conversation.isThinking)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minHeight: 260)
        .task { conversation.startIfNeeded(model: model) }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await conversation.send(text, model: model) }
    }

    @ViewBuilder
    private func bubble(_ message: ConversationModel.Bubble) -> some View {
        HStack {
            if message.isFromPerson { Spacer(minLength: 60) }
            VStack(alignment: message.isFromPerson ? .trailing : .leading, spacing: 6) {
                Text(message.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromPerson ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                                     : AnyShapeStyle(.background.secondary),
                                in: RoundedRectangle(cornerRadius: 12))

                if !message.entries.isEmpty {
                    loggedCard(message)
                }
            }
            if !message.isFromPerson { Spacer(minLength: 60) }
        }
    }

    private func loggedCard(_ message: ConversationModel.Bubble) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let context = message.context {
                HStack(spacing: 5) {
                    Image(systemName: context.symbolName).font(.caption)
                    Text(message.venueName ?? context.title)
                        .font(.caption.weight(.medium))
                    if message.venueName != nil {
                        Text("· \(context.title)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Theme.color(for: .nutrition))
            }

            ForEach(message.entries) { entry in
                HStack {
                    Text(entry.servings > 1
                         ? "\(Format.servings(entry.servings)) × \(entry.name)" : entry.name)
                    .font(.caption)
                    Spacer()
                    if entry.total.alcoholGrams > 0 {
                        Text(String(format: "%.1f units",
                                    AlcoholUnits.ukUnits(grams: entry.total.alcoholGrams)))
                        .font(.caption2).foregroundStyle(.orange)
                    }
                    Text("\(Int(entry.total.kilocalories)) kcal")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            let total = message.entries.reduce(Nutrition.empty) { $0 + $1.total }
            Divider()
            HStack {
                Text("Total").font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(total.kilocalories)) kcal")
                    .font(.caption.monospacedDigit().weight(.medium))
            }
        }
        .padding(10)
        .frame(maxWidth: 380)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Owns the agent and turns its replies into something the view can render.
@MainActor
final class ConversationModel: ObservableObject {

    struct Bubble: Identifiable {
        let id = UUID()
        let isFromPerson: Bool
        let text: String
        var entries: [FoodEntry] = []
        var context: MealContext?
        var venueName: String?
    }

    @Published private(set) var messages: [Bubble] = []
    @Published private(set) var isThinking = false

    private let agent = LoggingAgent()
    private var started = false

    func startIfNeeded(model: AppModel) {
        guard !started else { return }
        started = true
        let hour = Calendar.current.component(.hour, from: Date())
        let logged = model.foodLog.total(on: .today)
        messages.append(Bubble(isFromPerson: false,
                               text: agent.greeting(alreadyLogged: logged, timeOfDay: hour)))
    }

    func reset(model: AppModel) {
        agent.reset()
        messages = []
        started = false
        startIfNeeded(model: model)
    }

    func send(_ text: String, model: AppModel) async {
        messages.append(Bubble(isFromPerson: true, text: text))
        isThinking = true
        let turn = await agent.send(text)
        isThinking = false

        messages.append(Bubble(
            isFromPerson: false,
            text: [turn.reply, turn.followUpQuestion]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            entries: turn.entries,
            context: turn.hasItems ? turn.context : nil,
            venueName: turn.venueName))

        if turn.hasItems {
            await model.addEntries(turn.entries,
                                   context: turn.context,
                                   venueName: turn.venueName)
        }
    }
}
