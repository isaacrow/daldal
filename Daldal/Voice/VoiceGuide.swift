import AVFoundation
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
import Observation

/// Spoken turn-by-turn guidance: decides *when* to speak (from speed and distance) and *how* it sounds.
///
/// Timing follows what drivers expect from Waze-style apps: an early heads-up sized to your speed,
/// a final prompt about nine seconds before the turn, and back-to-back turns chained ("…then turn left").
@Observable
final class VoiceGuide: NSObject {
    var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "voice.muted")
            if isMuted { synthesizer.stopSpeaking(at: .immediate) }
        }
    }
    /// False when only the basic system voice is installed; Settings can suggest the Enhanced one.
    private(set) var hasHighQualityVoice = false

    @ObservationIgnored private let phraser: ManeuverPhraser
    @ObservationIgnored private let languageCode: String
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var chime: AVAudioPlayer?
    @ObservationIgnored private var spoken: Set<String> = []
    @ObservationIgnored private var currentStepIndex: Int?
    @ObservationIgnored private var lastReroute = Date.distantPast

    init(languageCode: String) {
        self.languageCode = languageCode
        phraser = ManeuverPhraser(languageCode: languageCode)
        isMuted = UserDefaults.standard.bool(forKey: "voice.muted")
        super.init()
        synthesizer.delegate = self
        selectVoice()
        if let url = Bundle.main.url(forResource: "chime", withExtension: "wav") {
            chime = try? AVAudioPlayer(contentsOf: url)
            chime?.volume = 0.55
            chime?.prepareToPlay()
        }
    }

    // MARK: Trip events

    func begin(route: Route, destinationName: String?) {
        spoken = []
        currentStepIndex = nil
        var opening = phraser.starting(to: destinationName)
        if let first = route.steps.dropFirst().first, let maneuver = Maneuver(step: route.steps.first, next: first) {
            opening += languageCode == "ar" ? "، " : ". "
            opening += phraser.spoken(maneuver, distance: route.steps.first?.distance)
        }
        say(opening)
    }

    func update(state: NavigationState, route: Route) {
        guard let steps = state.remainingSteps, let current = steps.first,
              let distance = state.currentProgress?.distanceToNextManeuver else { return }
        let stepIndex = route.steps.count - steps.count
        let next = steps.dropFirst().first
        guard let maneuver = Maneuver(step: current, next: next) else { return }
        let speed = max(state.preferredUserLocation?.speed?.value ?? 0, 0)

        if stepIndex != currentStepIndex {
            currentStepIndex = stepIndex
            // Just finished a turn onto a long road: reassure the driver there's nothing for a while.
            if current.distance > 3000, maneuver.kind != .arrive {
                speakOnce("\(stepIndex)-continue", phraser.continueFor(current.distance))
                return
            }
        }

        let near = min(max(60, speed * 9), 300)
        let early: Double = speed > 22 ? 2000 : speed > 14 ? 1000 : 400 // > 80 km/h, > 50 km/h, city

        if distance <= near {
            // Chain the following maneuver when it comes right after this one.
            var then: Maneuver?
            if let following = steps.dropFirst().first, following.distance < 150 {
                then = Maneuver(step: following, next: steps.dropFirst(2).first)
            }
            speakOnce("\(stepIndex)-near", phraser.spoken(maneuver, distance: nil, then: then))
        } else if distance <= early, distance > near + 150, current.distance > early * 0.6 {
            speakOnce("\(stepIndex)-early", phraser.spoken(maneuver, distance: distance))
        }
    }

    func rerouting() {
        // Rerouting can flicker on and off for a few seconds; announce it once.
        guard Date.now.timeIntervalSince(lastReroute) > 20 else { return }
        lastReroute = .now
        spoken = []
        currentStepIndex = nil
        say(phraser.rerouting, interrupt: true)
    }

    func reportAhead(_ type: ReportType, distance: Double) {
        say(phraser.reportAhead(type, distance: distance))
    }

    func fasterRoute(saving seconds: Double) {
        say(phraser.fasterRoute(saving: seconds))
    }

    /// The driver switched routes: forget what was announced for the old one.
    func routeChanged() {
        spoken = []
        currentStepIndex = nil
    }

    func arrived(destinationName: String?) {
        say(phraser.arrived(at: destinationName), interrupt: true)
    }

    func end() {
        synthesizer.stopSpeaking(at: .immediate)
        spoken = []
        currentStepIndex = nil
    }

    // MARK: Speaking

    private func speakOnce(_ key: String, _ text: String) {
        guard spoken.insert(key).inserted else { return }
        say(text, interrupt: key.hasSuffix("-near"))
    }

    private func say(_ text: String, interrupt: Bool = false) {
        guard !isMuted else { return }
        if interrupt { synthesizer.stopSpeaking(at: .word) }
        activateAudio()
        chime?.currentTime = 0
        chime?.play()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.preUtteranceDelay = chime == nil ? 0 : 0.3 // Let the chime ring first.
        utterance.postUtteranceDelay = 0.1
        utterance.prefersAssistiveTechnologySettings = true // Respect the user's Spoken Content settings.
        synthesizer.speak(utterance)
    }

    private func selectVoice() {
        let prefix = languageCode == "ar" ? "ar" : "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality {
            case .premium: 3
            case .enhanced: 2
            default: 1
            }
        }
        voice = candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: languageCode == "ar" ? "ar-SA" : "en-US")
        hasHighQualityVoice = voice.map { rank($0) > 1 } ?? false
    }

    /// Lowers music and pauses podcasts while we speak, instead of stopping them.
    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension VoiceGuide: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking { self.deactivateAudio() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking { self.deactivateAudio() }
        }
    }
}

extension Maneuver {
    /// The maneuver at the end of `step`. Its road name is the road you turn onto (`next`).
    init?(step: RouteStep?, next: RouteStep?) {
        guard let step else { return nil }
        let content = step.visualInstructions.first?.primaryContent
        let kind: Kind = switch content?.maneuverType {
        case .turn: .turn
        case .newName: .newName
        case .depart: .depart
        case .arrive: .arrive
        case .merge: .merge
        case .onRamp: .onRamp
        case .offRamp: .offRamp
        case .fork: .fork
        case .endOfRoad: .endOfRoad
        case .roundabout, .rotary, .roundaboutTurn: .roundabout
        default: .continue
        }
        let direction: Direction? = switch content?.maneuverModifier {
        case .uTurn: .uTurn
        case .sharpRight: .sharpRight
        case .right: .right
        case .slightRight: .slightRight
        case .straight: .straight
        case .slightLeft: .slightLeft
        case .left: .left
        case .sharpLeft: .sharpLeft
        default: nil
        }
        let road = next?.roadName?.trimmingCharacters(in: .whitespaces)
        self.init(
            kind: kind,
            direction: direction,
            roadName: road?.isEmpty == false ? road : nil,
            roundaboutExit: (next?.roundaboutExitNumber ?? step.roundaboutExitNumber).map(Int.init)
        )
    }
}
