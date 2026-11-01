import Foundation

/// The parts of a maneuver that wording depends on. Built from Ferrostar's visual instruction.
struct Maneuver: Equatable, Sendable {
    enum Kind: Sendable { case turn, depart, arrive, merge, onRamp, offRamp, fork, endOfRoad, roundabout, `continue`, newName }
    enum Direction: Sendable { case uTurn, sharpRight, right, slightRight, straight, slightLeft, left, sharpLeft }

    var kind: Kind
    var direction: Direction?
    var roadName: String? = nil
    var roundaboutExit: Int? = nil
}

/// Writes driving instructions in Arabic or English from maneuver data.
///
/// We don't use Valhalla's own Arabic narration: it mixes in English and drops numbers.
/// Phrases are short, imperative and end with the road name, so a driver gets the action first.
struct ManeuverPhraser {
    let languageCode: String
    /// Everyday Iraqi driving words ("لف يمين", "خليك سيده", "الفلكة") instead of formal Arabic. Set on the profile screen.
    var iraqi = UserDefaults.standard.bool(forKey: Self.iraqiKey)
    static let iraqiKey = "voice.iraqi"
    private var arabic: Bool { languageCode == "ar" }

    /// Formal Arabic, or its Iraqi spoken form when the dialect is on.
    private func say(_ formal: String, _ dialect: String) -> String { iraqi ? dialect : formal }

    /// The action alone, for the banner: "انعطف يميناً".
    func action(_ m: Maneuver) -> String {
        arabic ? arabicAction(m) : englishAction(m)
    }

    /// A full spoken instruction: "بعد 400 متر، انعطف يميناً إلى شارع الرشيد".
    func spoken(_ m: Maneuver, distance: Double?, then next: Maneuver? = nil) -> String {
        var sentence = action(m)
        if let road = m.roadName?.trimmingCharacters(in: .whitespaces), !road.isEmpty, m.kind != .arrive {
            sentence += arabic ? " إلى \(road)" : " onto \(road)"
        }
        if let distance {
            sentence = arabic
                ? "بعد \(spokenDistance(distance))، " + sentence
                : "In \(spokenDistance(distance)), " + lowercasedFirst(sentence)
        }
        if let next {
            sentence += arabic ? "، ثم \(action(next))" : ", then \(lowercasedFirst(action(next)))"
        }
        return sentence
    }

    func continueFor(_ distance: Double) -> String {
        arabic ? say("استمر لمسافة \(spokenDistance(distance))", "خليك سيده \(spokenDistance(distance))")
            : "Continue for \(spokenDistance(distance))"
    }

    func arrived(at name: String?) -> String {
        switch (arabic, name) {
        case (true, let name?): say("وصلت إلى \(name)", "وصلنا \(name)")
        case (true, nil): say("وصلت إلى وجهتك", "وصلنا")
        case (false, let name?): "You've arrived at \(name)"
        case (false, nil): "You've arrived"
        }
    }

    var rerouting: String { arabic ? say("جارٍ تعديل المسار", "دا أدوّر طريق ثاني") : "Finding a new route" }

    /// "انتبه، حادث بعد 500 متر" — said once when a report on the route comes into range.
    func reportAhead(_ type: ReportType, distance: Double) -> String {
        let d = spokenDistance(distance)
        if arabic {
            let name = switch type {
            case .jam: "ازدحام مروري"
            case .accident: "حادث"
            case .police: "شرطة"
            case .hazard: "خطر على الطريق"
            case .flood: "مياه على الطريق"
            case .closure: "طريق مغلق"
            case .pothole: "حفرة في الطريق"
            case .roadwork: "أعمال طريق"
            case .brokenLight: "إشارة ضوئية معطلة"
            }
            return say("انتبه، \(name) بعد \(d)", "دير بالك، \(name) بعد \(d)")
        }
        let name = switch type {
        case .jam: "Traffic jam"
        case .accident: "Accident"
        case .police: "Police"
        case .hazard: "Hazard"
        case .flood: "Flooded road"
        case .closure: "Road closed"
        case .pothole: "Pothole"
        case .roadwork: "Road works"
        case .brokenLight: "Broken traffic light"
        }
        return "\(name) reported in \(d)"
    }

    func fasterRoute(saving seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return arabic
            ? say("وجدت طريقاً أسرع يوفّر \(arabicMinutes(minutes))", "لكيت طريق أسرع يوفّر \(arabicMinutes(minutes))")
            : "Found a faster route that saves \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    /// Arabic counted nouns: دقيقة واحدة، دقيقتين، 3–10 دقائق، 11+ دقيقة.
    func arabicMinutes(_ n: Int) -> String {
        switch n {
        case 1: "دقيقة واحدة"
        case 2: "دقيقتين"
        case 3...10: "\(n) دقائق"
        default: "\(n) دقيقة"
        }
    }

    func starting(to name: String?) -> String {
        switch (arabic, name) {
        case (true, let name?): say("لنبدأ. الطريق إلى \(name)", "يلّا، الطريق إلى \(name)")
        case (true, nil): say("لنبدأ", "يلّا نمشي")
        case (false, let name?): "Starting route to \(name)"
        case (false, nil): "Starting route"
        }
    }

    /// Rounded the way people say distances: 50 m steps up to a kilometre, then half kilometres.
    func spokenDistance(_ meters: Double) -> String {
        if meters < 1000 {
            let rounded = meters < 100 ? max(10, (meters / 10).rounded() * 10) : (meters / 50).rounded() * 50
            if rounded >= 1000 { return spokenDistance(1000) }
            let n = Int(rounded)
            return arabic ? "\(n) متر" : "\(n) meters"
        }
        let km = (meters / 500).rounded() / 2
        // Fixed Western digits: the voice reads them correctly in both languages, and tests stay stable.
        let text = km == km.rounded() ? String(Int(km)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), km)
        if arabic {
            return km == 1 ? "كيلومتر واحد" : km == 2 ? "كيلومترين" : "\(text) كيلومتر"
        }
        return km == 1 ? "1 kilometer" : "\(text) kilometers"
    }

    // MARK: Arabic

    private func arabicAction(_ m: Maneuver) -> String {
        switch m.kind {
        case .depart: return say("انطلق", "يلّا امشي")
        case .arrive: return arabicArrival(m.direction)
        case .roundabout:
            guard let exit = m.roundaboutExit else { return say("ادخل الدوّار", "ادخل بالفلكة") }
            return say("عند الدوّار، اسلك المخرج \(arabicOrdinal(exit))", "بالفلكة، اطلع من الطلعة \(arabicOrdinalFeminine(exit))")
        case .merge: return "اندمج في الطريق" + arabicSide(m.direction, prefix: " من ")
        case .onRamp: return "اسلك المدخل" + arabicSide(m.direction, prefix: " على ")
        case .offRamp: return "اسلك المخرج" + arabicSide(m.direction, prefix: " على ")
        case .fork: return arabicKeep(m.direction)
        case .endOfRoad: return say("في نهاية الطريق، ", "بآخر الشارع، ") + arabicTurn(m.direction ?? .straight)
        case .continue, .newName:
            if let d = m.direction, d != .straight { return arabicTurn(d) }
            return say("استمر مباشرة", "خليك سيده")
        case .turn: return arabicTurn(m.direction ?? .straight)
        }
    }

    private func arabicTurn(_ d: Maneuver.Direction) -> String {
        switch d {
        case .uTurn: say("استدر للخلف", "ارجع يوتيرن")
        case .sharpRight: say("انعطف بحدة إلى اليمين", "اكسر يمين")
        case .right: say("انعطف يميناً", "لف يمين")
        case .slightRight: say("انحرف قليلاً إلى اليمين", "ميّل شوية يمين")
        case .straight: say("استمر مباشرة", "خليك سيده")
        case .slightLeft: say("انحرف قليلاً إلى اليسار", "ميّل شوية يسار")
        case .left: say("انعطف يساراً", "لف يسار")
        case .sharpLeft: say("انعطف بحدة إلى اليسار", "اكسر يسار")
        }
    }

    private func arabicKeep(_ d: Maneuver.Direction?) -> String {
        switch d {
        case .left, .slightLeft, .sharpLeft: say("التزم المسار الأيسر", "خليك عالسايد اليسار")
        case .right, .slightRight, .sharpRight: say("التزم المسار الأيمن", "خليك عالسايد اليمين")
        default: say("استمر مباشرة", "خليك سيده")
        }
    }

    private func arabicSide(_ d: Maneuver.Direction?, prefix: String) -> String {
        switch d {
        case .left, .slightLeft, .sharpLeft: prefix + "اليسار"
        case .right, .slightRight, .sharpRight: prefix + "اليمين"
        default: ""
        }
    }

    private func arabicArrival(_ d: Maneuver.Direction?) -> String {
        switch d {
        case .left, .slightLeft, .sharpLeft: say("وجهتك على اليسار", "وصلنا، المكان على يسارك")
        case .right, .slightRight, .sharpRight: say("وجهتك على اليمين", "وصلنا، المكان على يمينك")
        default: say("وجهتك أمامك", "وصلنا، المكان كدامك")
        }
    }

    /// "الطلعة الأولى، الثانية…" (exit is feminine in the dialect's الطلعة).
    private func arabicOrdinalFeminine(_ n: Int) -> String {
        let words = ["الأولى", "الثانية", "الثالثة", "الرابعة", "الخامسة", "السادسة", "السابعة", "الثامنة"]
        return (1...words.count).contains(n) ? words[n - 1] : "رقم \(n)"
    }

    private func arabicOrdinal(_ n: Int) -> String {
        let words = ["الأول", "الثاني", "الثالث", "الرابع", "الخامس", "السادس", "السابع", "الثامن"]
        return (1...words.count).contains(n) ? words[n - 1] : "رقم \(n)"
    }

    // MARK: English

    private func englishAction(_ m: Maneuver) -> String {
        switch m.kind {
        case .depart: return "Head out"
        case .arrive: return englishArrival(m.direction)
        case .roundabout:
            guard let exit = m.roundaboutExit else { return "Enter the roundabout" }
            return "At the roundabout, take the \(englishOrdinal(exit)) exit"
        case .merge: return "Merge" + englishSide(m.direction, prefix: " from the ")
        case .onRamp: return "Take the ramp" + englishSide(m.direction, prefix: " on the ")
        case .offRamp: return "Take the exit" + englishSide(m.direction, prefix: " on the ")
        case .fork: return englishKeep(m.direction)
        case .endOfRoad: return "At the end of the road, " + lowercasedFirst(englishTurn(m.direction ?? .straight))
        case .continue, .newName:
            if let d = m.direction, d != .straight { return englishTurn(d) }
            return "Continue straight"
        case .turn: return englishTurn(m.direction ?? .straight)
        }
    }

    private func englishTurn(_ d: Maneuver.Direction) -> String {
        switch d {
        case .uTurn: "Make a U-turn"
        case .sharpRight: "Turn sharp right"
        case .right: "Turn right"
        case .slightRight: "Bear right"
        case .straight: "Continue straight"
        case .slightLeft: "Bear left"
        case .left: "Turn left"
        case .sharpLeft: "Turn sharp left"
        }
    }

    private func englishKeep(_ d: Maneuver.Direction?) -> String {
        switch d {
        case .left, .slightLeft, .sharpLeft: "Keep left"
        case .right, .slightRight, .sharpRight: "Keep right"
        default: "Continue straight"
        }
    }

    private func englishSide(_ d: Maneuver.Direction?, prefix: String) -> String {
        switch d {
        case .left, .slightLeft, .sharpLeft: prefix + "left"
        case .right, .slightRight, .sharpRight: prefix + "right"
        default: ""
        }
    }

    private func englishArrival(_ d: Maneuver.Direction?) -> String {
        switch d {
        case .left, .slightLeft, .sharpLeft: "Your destination is on the left"
        case .right, .slightRight, .sharpRight: "Your destination is on the right"
        default: "Your destination is ahead"
        }
    }

    private func englishOrdinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    private func lowercasedFirst(_ s: String) -> String {
        s.prefix(1).lowercased() + s.dropFirst()
    }
}
