import AVFoundation
import CoreLocation
import FoundationModels
import Observation
import Speech

/// A free voice assistant that runs on the iPhone: Apple's speech recognition listens, the Apple Intelligence
/// on-device model answers (using Daldal's own search and city guides as tools), and Daldal's voice speaks.
/// Nothing leaves the phone except the place searches the tools make.
@Observable
final class OnDeviceAssistant {
    enum Status: Equatable {
        case ready, listening, thinking
        case unavailable(String)
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    private(set) var status: Status = .ready
    private(set) var lines: [Line] = []
    /// What's been heard so far while listening.
    private(set) var partial = ""

    @ObservationIgnored private let voice: VoiceGuide
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer: SFSpeechRecognizer?

    init(voice: VoiceGuide, search: any PlaceSearchService, guide: CityGuideStore, location: @escaping () -> CLLocation?,
         onShow: @escaping ([Place]) -> Void = { _ in }, onRoute: @escaping (Place) -> Void = { _ in }) {
        self.voice = voice
        let localeID = AppLanguage.code == "ar" ? "ar-SA" : "en-US"
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))

        switch SystemLanguageModel.default.availability {
        case .available:
            guard SystemLanguageModel.default.supportsLocale(Locale(identifier: localeID)) else {
                status = .unavailable(String(localized: "Apple Intelligence on this iPhone doesn't support this language yet."))
                return
            }
            let context = AssistantContext(search: search, guide: guide, location: location, onShow: onShow, onRoute: onRoute)
            let tools: [any Tool] = [FindPlaceTool(context: context), NearbyTool(context: context),
                                     NavigateTool(context: context), PlacesToVisitTool(context: context)]
            session = LanguageModelSession(tools: tools) {
                """
                You are Daldal, a friendly navigation assistant for drivers and visitors in Iraq.
                Answer in the same language the user speaks (Arabic or English), in at most three short sentences,
                because your answer is read aloud. Use the tools to find places and places to visit; never invent
                addresses or distances. Places you find are marked on the map. For everyday needs near the user
                (toilets, restaurants, fuel, pharmacy, ATM, mosque, parking, hotel) use nearby. When the user wants to
                go somewhere, call navigate with the place's name or its number in the last list; it starts the route.
                """
            }
        case .unavailable(.deviceNotEligible):
            status = .unavailable(String(localized: "This iPhone doesn't support Apple Intelligence. The ElevenLabs assistant can be set up instead."))
        case .unavailable(.appleIntelligenceNotEnabled):
            status = .unavailable(String(localized: "Turn on Apple Intelligence in Settings to use the free assistant."))
        case .unavailable(.modelNotReady):
            status = .unavailable(String(localized: "Apple Intelligence is still downloading. Try again in a few minutes."))
        case .unavailable:
            status = .unavailable(String(localized: "The on-device assistant isn't available right now."))
        }
    }

    // MARK: Listening

    func toggleListening() {
        status == .listening ? finishListening() : startListening()
    }

    private func startListening() {
        guard session != nil, let recognizer, recognizer.isAvailable else { return }
        Task {
            let speech = await Self.authorizeSpeech()
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard speech == .authorized, microphone else {
                status = .unavailable(String(localized: "Allow speech recognition and the microphone in Settings to talk to the assistant."))
                return
            }
            do { try beginRecording(with: recognizer) } catch { status = .ready }
        }
    }

    // The Speech and audio callbacks arrive on background queues, so they're built outside the main actor.
    nonisolated private static func authorizeSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
    }

    nonisolated private static func tap(into request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func handler(_ deliver: @escaping @Sendable (String?, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in deliver(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil) }
    }

    private func beginRecording(with recognizer: SFSpeechRecognizer) throws {
        task?.cancel()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        partial = ""

        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, done in
            Task { @MainActor in
                guard let self else { return }
                if let text { self.partial = text }
                if done, self.status == .listening { self.finishListening() }
            }
        })
        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(into: request))
        audioEngine.prepare()
        try audioEngine.start()
        status = .listening
    }

    private func finishListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        let heard = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        guard !heard.isEmpty else { status = .ready; return }
        Task { await answer(heard) }
    }

    // MARK: Answering

    func answer(_ question: String) async {
        guard let session, !session.isResponding else { return }
        lines.append(Line(fromUser: true, text: question))
        status = .thinking
        do {
            let reply = try await session.respond(to: question).content
            lines.append(Line(fromUser: false, text: reply))
            voice.announce(reply, interrupt: true)
        } catch {
            lines.append(Line(fromUser: false, text: String(localized: "Sorry, I couldn't answer that. Try asking another way.")))
        }
        status = .ready
    }

    func stop() {
        if status == .listening { finishListening() }
    }
}

// MARK: Tools the model can call

/// The app's search and guides, reached from the model's tools (which run off the main actor).
final class AssistantContext {
    let search: any PlaceSearchService
    let guide: CityGuideStore
    let location: () -> CLLocation?
    let onShow: ([Place]) -> Void
    let onRoute: (Place) -> Void
    /// The last places found, so "take me to the second one" works.
    private var lastFound: [Place] = []

    init(search: any PlaceSearchService, guide: CityGuideStore, location: @escaping () -> CLLocation?,
         onShow: @escaping ([Place]) -> Void, onRoute: @escaping (Place) -> Void) {
        self.search = search
        self.guide = guide
        self.location = location
        self.onShow = onShow
        self.onRoute = onRoute
    }

    func findPlaces(_ query: String) async -> String {
        let here = location()
        guard let places = try? await search.search(query, near: here?.coordinate), !places.isEmpty else {
            return "No places found."
        }
        return remember(Array(places.prefix(5)))
    }

    func nearby(_ kind: String) async -> String {
        guard let category = NearbyCategory(spoken: kind) else {
            return await findPlaces(kind)
        }
        let here = location()?.coordinate ?? Region.defaultCenter
        guard let places = try? await Overpass.nearby(category, around: here, languageCode: AppLanguage.code),
              !places.isEmpty else { return "None found within 15 km." }
        return remember(Array(places.prefix(5)))
    }

    func navigate(to target: String) async -> String {
        let trimmed = target.trimmingCharacters(in: .whitespaces).lowercased()
        let ordinals: [(String, Int)] = [("1", 0), ("first", 0), ("\u{0627}\u{0644}\u{0627}\u{0648}\u{0644}", 0),
                                         ("\u{0627}\u{0644}\u{0623}\u{0648}\u{0644}", 0), ("2", 1), ("second", 1),
                                         ("\u{0627}\u{0644}\u{062B}\u{0627}\u{0646}\u{064A}", 1), ("3", 2), ("third", 2),
                                         ("\u{0627}\u{0644}\u{062B}\u{0627}\u{0644}\u{062B}", 2), ("4", 3), ("5", 4)]
        var place = ordinals.first { trimmed.contains($0.0) }.flatMap { lastFound.indices.contains($0.1) ? lastFound[$0.1] : nil }
        place = place ?? lastFound.first { $0.name.lowercased().contains(trimmed) || trimmed.contains($0.name.lowercased()) }
        if place == nil, let found = try? await search.search(target, near: location()?.coordinate).first {
            place = found
        }
        guard let place else { return "Couldn't find that place." }
        onRoute(place)
        let km = place.distance(from: location()).map { String(format: "%.1f km", $0 / 1000) } ?? ""
        return "Route started to \(place.name) \(km)."
    }

    private func remember(_ places: [Place]) -> String {
        lastFound = places
        onShow(places)
        let here = location()
        return places.enumerated().map { index, place in
            let km = place.distance(from: here).map { String(format: "%.1f km away", $0 / 1000) } ?? ""
            return "\(index + 1). \(place.name) (\(place.subtitle)) \(km)"
        }.joined(separator: "\n")
    }

    func placesToVisit(_ count: Int) -> String {
        let language = AppLanguage.code
        guard let city = location().flatMap({ guide.city(near: $0.coordinate) }) ?? guide.cities.first(where: { !$0.places.isEmpty }) else {
            return "No city guide available."
        }
        return city.places.prefix(max(1, min(count, 8))).map { place in
            let summary = place.summary(languageCode: language).map { String($0.prefix(160)) } ?? ""
            return "\(place.name(languageCode: language)): \(summary)"
        }.joined(separator: "\n")
    }
}

/// Finds places in Iraq by name or kind, nearest first.
nonisolated struct FindPlaceTool: Tool {
    let name = "findPlace"
    let description = "Search for places in Iraq by name or type, such as a mosque, hospital, fuel station or street."
    let context: AssistantContext

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "What to search for, in the user's language")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        await context.findPlaces(arguments.query)
    }
}

/// Everyday places near the user (toilets, restaurants, fuel...) from OpenStreetMap, marked on the map.
nonisolated struct NearbyTool: Tool {
    let name = "nearby"
    let description = "Find the nearest toilets, restaurants, cafes, fuel stations, pharmacies, hospitals, ATMs, mosques, parking or hotels."
    let context: AssistantContext

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The kind of place, e.g. toilets, restaurant, fuel, pharmacy")
        var kind: String
    }

    func call(arguments: Arguments) async throws -> String {
        await context.nearby(arguments.kind)
    }
}

/// Starts a route to a place the user named or picked from the last list.
nonisolated struct NavigateTool: Tool {
    let name = "navigate"
    let description = "Start driving directions to a place: its name, or its number in the last list of results."
    let context: AssistantContext

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The place's name or its number in the last list (1, 2, 3...)")
        var place: String
    }

    func call(arguments: Arguments) async throws -> String {
        await context.navigate(to: arguments.place)
    }
}

/// The best places to visit in the user's city, with a one-line description each.
nonisolated struct PlacesToVisitTool: Tool {
    let name = "placesToVisit"
    let description = "List the best places to visit (monuments, shrines, museums, historic sites) in the city the user is in."
    let context: AssistantContext

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "How many places to list, 1 to 8")
        var count: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await context.placesToVisit(arguments.count)
    }
}
