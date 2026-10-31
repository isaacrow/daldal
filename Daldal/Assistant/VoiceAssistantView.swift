import ElevenLabs
import SwiftUI

/// A spoken conversation with Daldal's assistant, powered by an ElevenLabs Conversational AI agent.
///
/// Test feature. The agent (its voice, language and knowledge) is set up in the ElevenLabs dashboard; the app
/// only needs its public agent id, built in from the ELEVENLABS_AGENT_ID GitHub secret.
struct VoiceAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SearchStore.self) private var search
    @Environment(CityGuideStore.self) private var guide
    @Environment(LocationService.self) private var location
    @Environment(NavigationModel.self) private var nav
    @State private var onDevice: OnDeviceAssistant?
    @State private var conversation: Conversation?
    @State private var failure: String?
    @State private var connecting = false

    private var agentID: String? {
        let id = (Bundle.main.object(forInfoDictionaryKey: "ElevenLabsAgentID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty || id.hasPrefix("$(") ? nil : id
    }

    var body: some View {
        NavigationStack {
            Group {
                if agentID == nil {
                    if let onDevice { OnDeviceConversation(assistant: onDevice) }
                } else if let conversation {
                    LiveConversation(conversation: conversation) {
                        Task { await conversation.endConversation() }
                        self.conversation = nil
                    }
                } else {
                    startScreen
                }
            }
            .onAppear {
                guard agentID == nil, onDevice == nil else { return }
                onDevice = OnDeviceAssistant(voice: nav.voice, search: search.service, guide: guide) { [location] in location.location }
            }
            .onDisappear { onDevice?.stop() }
            .navigationTitle("Voice assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if let conversation { Task { await conversation.endConversation() } }
                        dismiss()
                    } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    private var startScreen: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            AssistantOrb(active: false, speaking: false)
            Text("Ask about places, roads and directions, in Arabic or English.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button {
                Task { await start() }
            } label: {
                Group {
                    if connecting { ProgressView() } else { Text("Start talking") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            .disabled(connecting)
            Text("Test feature: your voice is sent to ElevenLabs to answer you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Theme.Spacing.xl)
    }

    private func start() async {
        guard let agentID else { return }
        connecting = true
        failure = nil
        defer { connecting = false }
        do {
            conversation = try await ElevenLabs.startConversation(agentId: agentID)
        } catch {
            failure = String(localized: "Couldn't connect to the assistant. Check your internet and try again.")
        }
    }
}

/// The live call: a breathing orb while the agent listens or speaks, the transcript, and mute/end controls.
private struct LiveConversation: View {
    @ObservedObject var conversation: Conversation
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            AssistantOrb(active: conversation.state.isActive, speaking: conversation.agentState == .speaking)
                .padding(.top, Theme.Spacing.l)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(conversation.messages) { message in
                            let mine = message.role == .user
                            Text(message.content)
                                .padding(Theme.Spacing.m)
                                .background(mine ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.12),
                                            in: .rect(cornerRadius: 16))
                                .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                }
                .onChange(of: conversation.messages.count) {
                    if let last = conversation.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            HStack(spacing: Theme.Spacing.l) {
                Button {
                    Task { try? await conversation.toggleMute() }
                } label: {
                    Label { Text(conversation.isMuted ? "Unmute" : "Mute") } icon: {
                        Icon(conversation.isMuted ? .volumeOff : .assistant, size: 18)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glass)
                Button(action: onEnd) {
                    Text("End").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
            .font(.headline)
            .padding(Theme.Spacing.l)
        }
    }

    private var statusText: LocalizedStringKey {
        switch conversation.state {
        case .idle, .connecting: "Connecting…"
        case .active:
            switch conversation.agentState {
            case .speaking: "Speaking…"
            case .thinking: "Thinking…"
            case .listening: "Listening…"
            }
        case .ended: "Conversation ended"
        case .error: "Something went wrong. End and try again."
        }
    }
}

/// A soft orb that breathes while listening and pulses while the assistant speaks.
private struct AssistantOrb: View {
    let active: Bool
    let speaking: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.15)],
                                     center: .center, startRadius: 8, endRadius: 90))
                .frame(width: 170, height: 170)
                .scaleEffect(pulse ? (speaking ? 1.12 : 1.04) : 0.96)
                .blur(radius: 2)
            Icon(.assistant, size: 44).foregroundStyle(.white)
        }
        .opacity(active ? 1 : 0.75)
        .animation(.easeInOut(duration: speaking ? 0.45 : 1.6).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

/// The free assistant: hold a conversation with Apple Intelligence on the phone, no account needed.
private struct OnDeviceConversation: View {
    let assistant: OnDeviceAssistant
    @State private var typed = ""
    @State private var showSetup = false

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            AssistantOrb(active: assistant.status == .listening, speaking: assistant.status == .thinking)
                .padding(.top, Theme.Spacing.l)
            Text(statusText).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.l)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(assistant.lines) { line in
                            Text(line.text)
                                .padding(Theme.Spacing.m)
                                .background(line.fromUser ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.12),
                                            in: .rect(cornerRadius: 16))
                                .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                                .id(line.id)
                        }
                        if !assistant.partial.isEmpty {
                            Text(assistant.partial).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                }
                .onChange(of: assistant.lines.count) {
                    if let last = assistant.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if case .unavailable = assistant.status {
                Button("Set up the ElevenLabs assistant instead") { showSetup = true }
                    .font(.footnote)
            } else {
                HStack(spacing: Theme.Spacing.m) {
                    TextField("Type a question", text: $typed)
                        .textFieldStyle(.plain)
                        .padding(Theme.Spacing.m)
                        .glassEffect(.regular, in: .capsule)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button {
                        assistant.toggleListening()
                    } label: {
                        Icon(assistant.status == .listening ? .close : .assistant, size: 22)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(assistant.status == .thinking)
                    .accessibilityLabel(assistant.status == .listening ? "Stop listening" : "Talk")
                    .accessibilityIdentifier("assistant.talk")
                }
                .padding(.horizontal, Theme.Spacing.l)
                Text("Free test assistant: runs on your iPhone with Apple Intelligence. Only place searches use the internet.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.l)
            }
        }
        .padding(.bottom, Theme.Spacing.l)
        .sheet(isPresented: $showSetup) { SetupInstructions() }
    }

    private func send() {
        let question = typed.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        typed = ""
        Task { await assistant.answer(question) }
    }

    private var statusText: String {
        switch assistant.status {
        case .ready: String(localized: "Tap the microphone and ask about places to visit or anywhere in Iraq.")
        case .listening: String(localized: "Listening…")
        case .thinking: String(localized: "Thinking…")
        case .unavailable(let reason): reason
        }
    }
}

private struct SetupInstructions: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                AssistantOrb(active: false, speaking: false).frame(maxWidth: .infinity)
                Text("Set up the voice assistant").font(.title2.weight(.bold))
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text("1. Create a free account at elevenlabs.io and open Agents.")
                    Text("2. Create an agent: pick an Arabic voice and describe it as Daldal's navigation helper for Iraq.")
                    Text("3. In the agent's security settings, allow public access, then copy its agent ID.")
                    Text("4. On GitHub, add the secret ELEVENLABS_AGENT_ID with that ID. The next build turns this screen on.")
                }
                .font(.body)
            }
            .padding(Theme.Spacing.xl)
        }
    }
}
