import Testing
@testable import Daldal

@MainActor
struct DialectTests {
    let iraqi = ManeuverPhraser(languageCode: "ar", iraqi: true)
    let formal = ManeuverPhraser(languageCode: "ar", iraqi: false)

    @Test func everydayIraqiWords() {
        #expect(iraqi.action(Maneuver(kind: .turn, direction: .right)) == "لف يمين")
        #expect(iraqi.action(Maneuver(kind: .continue, direction: .straight)) == "خليك سيده")
        #expect(iraqi.action(Maneuver(kind: .roundabout, direction: nil, roundaboutExit: 2)) == "بالفلكة، اطلع من الطلعة الثانية")
        #expect(iraqi.spoken(Maneuver(kind: .turn, direction: .left), distance: 200) == "بعد 200 متر، لف يسار")
    }

    @Test func formalArabicIsUnchanged() {
        #expect(formal.action(Maneuver(kind: .turn, direction: .right)) == "انعطف يميناً")
        #expect(formal.reportAhead(.accident, distance: 500) == "انتبه، حادث بعد 500 متر")
        #expect(iraqi.reportAhead(.accident, distance: 500) == "دير بالك، حادث بعد 500 متر")
    }
}
