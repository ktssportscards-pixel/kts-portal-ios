import Foundation

#if DEBUG
// ============================================================================
// OFFLINE DEMO MODE  —  set `KTS_PREVIEW_MOCK = true` in PortalCore.swift
//
// Runs the whole app with NO backend and NO login. It boots straight to Home,
// and the scanner works end to end:
//   • On a real device, point the camera at a graded slab's barcode.
//   • On the Simulator (no camera), tap the camera-off button, then "Price it"
//     and type ANY 7–13 digit number as a cert.
// Each cert gets a realistic, deterministic offer — a "normal weekend" where
// most cards are a BUY and some are a PASS. Submitting a batch is remembered on
// the device and shows up under Review / Past with accepted / pending / rejected
// statuses. Everything here is fictional and the whole file compiles out of
// Release / TestFlight builds (#if DEBUG).
// ============================================================================

func ktsMockDecode<T: Decodable>(_ json: String) -> T? {
    try? JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// A short pause so the "pricing…" state is visible, like a real network call.
func ktsMockDelay() async { try? await Task.sleep(nanoseconds: 300_000_000) }

private let ktsMockISOFormatter = ISO8601DateFormatter()
func ktsMockNowISO() -> String { ktsMockISOFormatter.string(from: Date()) }

// ---- Deterministic per-cert "weekend" pricing ------------------------------

private let ktsMockCats: [(key: String, label: String, titles: [String], grader: String)] = [
    ("pokemon", "Pokémon", ["Charizard VMAX Rainbow", "Umbreon VMAX Alt Art", "Pikachu Illustrator", "Lugia V Alt Art"], "PSA"),
    ("basketball", "Basketball", ["Victor Wembanyama Prizm", "Ja Morant Silver Prizm", "LeBron James Mosaic"], "PSA"),
    ("football", "Football", ["Patrick Mahomes Prizm", "C.J. Stroud Optic", "Justin Jefferson Select"], "PSA"),
    ("onepiece", "One Piece", ["Luffy Gear 5 Manga", "Shanks Alt Art", "Zoro Leader Parallel"], "CGC"),
    ("baseball", "Baseball", ["Mike Trout Chrome", "Shohei Ohtani Optic Holo"], "PSA"),
]

private func ktsMockSeed(_ cert: String) -> Int {
    let digits = cert.filter(\.isNumber)
    if let n = Int(digits.suffix(6)) { return abs(n) }
    return abs(digits.hashValue)
}

// true = BUY (bought on the spot), false = PASS (rejected). ~70% BUY.
func ktsMockIsBuy(_ cert: String) -> Bool { ktsMockSeed(cert) % 10 < 7 }

private func ktsMockFallback(_ cert: String) -> SellerView {
    ktsMockDecode("{\"cert\":\"\(cert)\",\"grader\":\"PSA\",\"grade\":\"9\",\"category\":\"pokemon\",\"categoryLabel\":\"Pokémon\",\"cardTitle\":\"Graded Slab\",\"cardladderValue\":100,\"value\":100,\"valueBasis\":\"market\",\"lastSale\":null,\"confidence\":80,\"decision\":\"PASS\",\"reason\":\"Not taking this one this week.\",\"offer\":null,\"offerPct\":null,\"band\":null,\"nearFull\":false,\"pctFull\":null,\"priced\":true,\"imageUrl\":\"\",\"lane\":false}")!
}

func ktsMockPrice(cert: String) -> SellerView {
    let n = ktsMockSeed(cert)
    let c = ktsMockCats[n % ktsMockCats.count]
    let title = c.titles[(n / 7) % c.titles.count]
    let grade = [10, 10, 9, 9, 8][n % 5]
    let value = Double(30 + (n % 50) * 12)               // $30 – $618
    let conf = 60 + (n % 40)                              // 60 – 99
    let buy = ktsMockIsBuy(cert)
    let ratePct = 88
    let offer = ((value * Double(ratePct) / 100) * 100).rounded() / 100
    let bandMin = max(10, (value * 0.35).rounded())
    let bandMax = (value * 1.4).rounded()
    let decision = buy ? "BUY" : "PASS"
    let reason = buy ? "" : "Below this week's minimum for \(c.label)."
    let offerStr = buy ? String(offer) : "null"
    let pctStr = buy ? String(ratePct) : "null"
    let json = """
    {"cert":"\(cert)","grader":"\(c.grader)","grade":"\(grade)","category":"\(c.key)","categoryLabel":"\(c.label)","cardTitle":"\(title)","cardladderValue":\(value),"value":\(value),"valueBasis":"market","lastSale":null,"confidence":\(conf),"decision":"\(decision)","reason":"\(reason)","offer":\(offerStr),"offerPct":\(pctStr),"band":{"min":\(bandMin),"max":\(bandMax)},"nearFull":false,"pctFull":null,"priced":true,"imageUrl":"","lane":false}
    """
    return ktsMockDecode(json) ?? ktsMockFallback(cert)
}

// ---- On-device record of what was "submitted" (survives app restarts) -------

enum KTSMockStore {
    private static let key = "kts_mock_submissions_v1"
    struct Rec: Codable { let id: Int; let created: String; let certs: [String] }

    static func all() -> [Rec] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let r = try? JSONDecoder().decode([Rec].self, from: d) else { return [] }
        return r
    }
    @discardableResult
    static func add(_ certs: [String]) -> Int {
        var r = all()
        let id = 900 + r.count
        r.insert(Rec(id: id, created: ktsMockNowISO(), certs: certs), at: 0)
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: key) }
        return id
    }
    static func remove(id: Int) {
        let r = all().filter { $0.id != id }
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// Weekend outcome for a submitted card: a BUY is mostly accepted, sometimes
// still pending review, occasionally rejected; a PASS reads as rejected.
private func ktsMockOutcome(_ cert: String) -> (item: String, review: String) {
    if !ktsMockIsBuy(cert) { return ("rejected", "refused") }
    switch ktsMockSeed(cert + "x") % 10 {
    case 0..<7: return ("accepted", "approved")
    case 7..<9: return ("pending", "pending")
    default:    return ("rejected", "refused")
    }
}

func ktsMockSubmit(certs: [String]) -> SubmitResponse {
    let id = KTSMockStore.add(certs)
    let buys = certs.filter(ktsMockIsBuy).count
    let offerTotal = certs.filter(ktsMockIsBuy).reduce(0.0) { $0 + (ktsMockPrice(cert: $1).offer ?? 0) }
    let json = "{\"ok\":true,\"submission_id\":\(id),\"counts\":{\"total\":\(certs.count),\"buy\":\(buys),\"pass\":\(certs.count - buys)},\"offer_total\":\(offerTotal),\"queued\":false,\"queueOpensAt\":null,\"laneAccepted\":0}"
    return ktsMockDecode(json) ?? ktsMockDecode("{\"ok\":true,\"submission_id\":\(id),\"counts\":{\"total\":0,\"buy\":0,\"pass\":0},\"offer_total\":0}")!
}

// ---- Build /mine out of the stored submissions + a little sample history ----

private func ktsMockItemJSON(_ cert: String) -> String {
    let v = ktsMockPrice(cert: cert)
    let o = ktsMockOutcome(cert)
    let conf = v.confidence.text.isEmpty ? "0" : v.confidence.text
    let offer = v.isBuy ? String(v.offer ?? 0) : "null"
    let clv = String(v.cardladderValue ?? 0)
    return "{\"cert\":\"\(cert)\",\"grader\":\"\(v.grader)\",\"grade\":\"\(v.grade)\",\"category\":\"\(v.categoryLabel)\",\"card_title\":\"\(v.cardTitle)\",\"cardladder_value\":\(clv),\"confidence\":\(conf),\"decision\":\"\(v.decision)\",\"offer_amount\":\(offer),\"item_status\":\"\(o.item)\",\"review_state\":\"\(o.review)\",\"image_url\":\"\"}"
}

private func ktsMockSubmissionJSON(id: Int, created: String, certs: [String]) -> String {
    let items = certs.map(ktsMockItemJSON).joined(separator: ",")
    let buys = certs.filter(ktsMockIsBuy).count
    let accepted = certs.filter { ktsMockOutcome($0).item == "accepted" }
    let offerTotal = accepted.reduce(0.0) { $0 + (ktsMockPrice(cert: $1).offer ?? 0) }
    let status = accepted.isEmpty ? (buys > 0 ? "pending" : "rejected") : "accepted"
    return "{\"id\":\(id),\"status\":\"\(status)\",\"created_at\":\"\(created)\",\"reviewed_at\":null,\"counts\":{\"total\":\(certs.count),\"buy\":\(buys),\"pass\":\(certs.count - buys)},\"offer_total\":\(offerTotal),\"items\":[\(items)]}"
}

// A couple of fictional "past" submissions so Home / Past aren't empty on day one.
private let ktsMockSampleSubs = """
{"id":101,"status":"accepted","created_at":"2026-11-05T10:00:00Z","reviewed_at":"2026-11-05T12:00:00Z","counts":{"total":3,"buy":2,"pass":1},"offer_total":580,"items":[
  {"cert":"171234567","grader":"PSA","grade":"10","category":"Pokémon","card_title":"Charizard VMAX Rainbow","cardladder_value":500,"confidence":92,"decision":"BUY","offer_amount":400,"item_status":"accepted","review_state":"approved","image_url":""},
  {"cert":"171234568","grader":"PSA","grade":"9","category":"Pokémon","card_title":"Pikachu Illustrator","cardladder_value":210,"confidence":88,"decision":"BUY","offer_amount":180,"item_status":"pending","review_state":"pending","image_url":""},
  {"cert":"171234569","grader":"PSA","grade":"8","category":"Pokémon","card_title":"Common Energy","cardladder_value":20,"confidence":60,"decision":"PASS","offer_amount":null,"item_status":"rejected","review_state":"refused","image_url":""}
]},
{"id":102,"status":"accepted","created_at":"2026-10-28T10:00:00Z","reviewed_at":"2026-10-28T12:00:00Z","counts":{"total":1,"buy":1,"pass":0},"offer_total":260,"items":[
  {"cert":"171239999","grader":"PSA","grade":"10","category":"Basketball","card_title":"Ja Morant Silver Prizm","cardladder_value":300,"confidence":95,"decision":"BUY","offer_amount":260,"item_status":"accepted","review_state":"approved","image_url":""}
]}
"""

func ktsMockMine() -> MineResponse {
    var subs = KTSMockStore.all().map { ktsMockSubmissionJSON(id: $0.id, created: $0.created, certs: $0.certs) }
    subs.append(ktsMockSampleSubs)
    let json = "{\"submissions\":[\(subs.joined(separator: ","))]}"
    return ktsMockDecode(json) ?? ktsMockDecode("{\"submissions\":[]}")!
}

func ktsMockDelete(id: Int) { KTSMockStore.remove(id: id) }

// ---- Rates + shipping so those screens render in demo mode ------------------

func ktsMockRates() -> RatesResponse {
    let json = """
    {"categories":[{"category":"pokemon","label":"Pokémon","graders":[{"grader":"PSA","minGrade":7,"minCert":70000000,"tiers":[{"min":30,"max":100,"rate":85,"minConf":3},{"min":100,"max":500,"rate":90,"minConf":4},{"min":500,"max":null,"rate":92,"minConf":4}]}]},{"category":"basketball","label":"Basketball","graders":[{"grader":"PSA","minGrade":8,"tiers":[{"min":30,"max":300,"rate":80},{"min":300,"max":null,"rate":85}]}]},{"category":"football","label":"Football","graders":[{"grader":"PSA","minGrade":8,"tiers":[{"min":30,"max":null,"rate":82}]}]},{"category":"onepiece","label":"One Piece","graders":[{"grader":"CGC","tiers":[{"min":30,"max":null,"rate":80}]}]}],"updated_at":null,"pokemonLane":null,"mainOpensAt":null,"pokemonOpensAt":null}
    """
    return ktsMockDecode(json) ?? ktsMockDecode("{\"categories\":[],\"updated_at\":null,\"pokemonLane\":null,\"mainOpensAt\":null,\"pokemonOpensAt\":null}")!
}

func ktsMockShipping() -> ShippingResponse {
    ktsMockDecode("{\"address\":\"Your ship-to address appears here once a card is accepted.\",\"weekStart\":null,\"shipment\":null}")
        ?? ktsMockDecode("{\"address\":null,\"weekStart\":null,\"shipment\":null}")!
}
#endif
