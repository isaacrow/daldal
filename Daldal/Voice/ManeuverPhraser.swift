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
    private var arabic: Bool { languageCode == "ar" }

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
        arabic ? "استمر لمسافة \(spokenDistance(distance))" : "Continue for \(spokenDistance(distance))"
    }

    func arrived(at name: String?) -> String {
        switch (arabic, name) {
        case (true, let name?): "وصلت إلى \(name)"
        case (true, nil): "وصلت إلى وجهتك"
        case (false, let name?): "You've arrived at \(name)"
        case (false, nil): "You've arrived"
        }
    }

    var rerouting: String { arabic ? "جارٍ تعديل المسار" : "Finding a new route" }

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
            return "انتبه، \(name) بعد \(d)"
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
            ? "وجدت طريقاً أسرع يوفّر \(arabicMinutes(minutes))"
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
        case (true, let name?): "لنبدأ. الطريق إلى \(name)"
        case (true, nil): "لنبدأ"
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
        case .depart: return "انطلق"
        case .arrive: return arabicArrival(m.direction)
        case .roundabout:
            guard let exit = m.roundaboutExit else { return "ادخل الدوّار" }
            return "عند الدوّار، اسلك المخرج \(arabicOrdinal(exit))"
        case .merge: return "اندمج في الطريق" + arabicSide(m.direction, prefix: " من ")
        case .onRamp: return "اسلك المدخل" + arabicSide(m.direction, prefix: " على ")
        case .offRamp: return "اسلك المخرج" + arabicSide(m.direction, prefix: " على ")
        case .fork: return arabicKeep(m.direction)
        case .endOfRoad: return "في نهاية الطريق، " + arabicTurn(m.direction ?? .straight)
        case .continue, .newName:
            if let d = m.direction, d != .straight { return arabicTurn(d) }
            return "استمر مباشرة"
        case .turn: return arabicTurn(m.direction ?? .straight)
        }
    }

    private func arabicTurn(_ d: Maneuver.Direction) -> String {
        switch d {
        case .uTurn: "استدر للخلف"
        case .sharpRight: "انعطف بحدة إلى اليمين"
        case .right: "انعطف يميناً"
        case .slightRight: "انحرف قليلاً إلى اليمين"
        case .straight: "استمر مباشرة"
        case .slightLeft: "انحرف قليلاً إلى اليسار"
        case .left: "انعطف يساراً"
        case .sharpLeft: "انعطف بحدة إلى اليسار"
        }
    }

    private func arabicKeep(_ d: Maneuver.Direction?) -> String {
        switch d {
        case .left, .slightLeft, .sharpLeft: "التزم المسار الأيسر"
        case .right, .slightRight, .sharpRight: "التزم المسار الأيمن"
        default: "استمر مباشرة"
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
        case .left, .slightLeft, .sharpLeft: "وجهتك على اليسار"
        case .right, .slightRight, .sharpRight: "وجهتك على اليمين"
        default: "وجهتك أمامك"
        }
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
