import SwiftUI
import Foundation

#if DEBUG
// Flip true in a local DEBUG sim build to preview the app with sample data: land on
// Home populated with fictional submissions, no backend or login needed. Ships false, and the whole
// mock path is compiled out of Release / TestFlight builds via #if DEBUG.
var KTS_PREVIEW_MOCK = false
#endif

// MARK: - Theme (navy + gold "dragon crest")

public enum KTS {
    public static let bg      = Color(hex: 0x0A1326)
    public static let panel   = Color(hex: 0x111D3A)
    public static let panel2  = Color(hex: 0x16244A)
    public static let line    = Color(hex: 0x263A66)
    public static let txt     = Color(hex: 0xE8EEFC)
    public static let muted   = Color(hex: 0x8A9BC4)
    public static let accent  = Color(hex: 0xF3C45E)   // gold — money / brand
    public static let accentDeep = Color(hex: 0xD8A23C)
    public static let green   = Color(hex: 0x4FC08D)   // BUY / accepted (muted)
    public static let red     = Color(hex: 0xDE8585)   // PASS / rejected (muted)
    public static let blue    = Color(hex: 0x5B9BFF)
}

public extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

// Money formatter that respects the incognito/hide-amounts flag.
public func ktsMoney(_ value: Double?, hide: Bool) -> String {
    guard let v = value else { return "—" }
    if hide { return "$•••" }
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
}

// Decodes a field that the API sends as either a number or "" (e.g. confidence). Codable so a scan batch can be saved.
public struct FlexNum: Codable, Hashable {
    public let text: String   // display string; "" when absent
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { text = String(i) }
        else if let d = try? c.decode(Double.self) { text = String(Int(d)) }
        else if let s = try? c.decode(String.self) { text = s }
        else { text = "" }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)   // round-trips via the string branch above
    }
    public var isEmpty: Bool { text.isEmpty }
}

// MARK: - API models

public struct Seller: Decodable { public let discord_username: String }
public struct MeResponse: Decodable { public let seller: Seller?; public let isAdmin: Bool; public let discordNote: Bool }
public struct AuthResponse: Decodable { public let ok: Bool; public let seller: Seller }

// POST /price result (camelCase sellerView). Codable so an in-progress scan batch can be saved/resumed.
public struct SellerView: Codable, Identifiable {
    public var id: String { cert }
    public let cert: String
    public let grader: String
    public let grade: String
    public let category: String
    public let categoryLabel: String
    public let cardTitle: String
    public let cardladderValue: Double?
    public let value: Double?          // dollars the offer is computed against: CGC = last sold, else = CardLadder market
    public let valueBasis: String?     // "lastSold" (CGC) or "market"; nil on older responses → treat as market
    public let lastSale: Double?       // CGC last-sold price, for reference
    public let confidence: FlexNum
    public let decision: String        // "BUY" | "PASS"
    public let reason: String
    public let offer: Double?
    public let offerPct: Double?       // KTS's buy rate to the SELLER = round(offer/market), as a % of market value
    public let band: PriceBand?        // the posted value range this card fell in
    public let nearFull: Bool?         // true when this card's value band is getting full (≥85%) → "submit soon"
    public let pctFull: Double?        // that band's approx %-full (0–100) when known; nil/absent otherwise
    public let priced: Bool
    public let imageUrl: String?       // real PSA/CGC cert photo (CloudFront); may be nil/absent
    public let lane: Bool?             // true = Pokémon unlimited lane buy (bought on the spot)
    public var isBuy: Bool { decision == "BUY" }
}

// Posted value range a card fell in (e.g. Football $30–$220). min/max in dollars.
public struct PriceBand: Codable { public let min: Double?; public let max: Double? }

public struct SubmitResponse: Decodable {
    public let ok: Bool
    public let submission_id: Int
    public let counts: Counts
    public let offer_total: Double
    public let queued: Bool?           // true = Pokémon PSA pre-submitted before the submission window; locks at queueOpensAt
    public let queueOpensAt: String?   // ISO — when the queued list locks (the submission window)
    public let laneAccepted: Int?      // how many cards were bought on the spot via the unlimited lane
    public struct Counts: Decodable { public let total: Int; public let buy: Int; public let pass: Int }
}

// GET /mine (snake_case)
public struct MineResponse: Decodable { public let submissions: [Submission] }
public struct Submission: Decodable, Identifiable {
    public let id: Int
    public let status: String          // pending | accepted | rejected
    public let created_at: String
    public let reviewed_at: String?
    public let counts: Counts
    public let offer_total: Double
    public let items: [SubItem]
    public struct Counts: Decodable { public let total: Int; public let buy: Int; public let pass: Int }
}
public struct SubItem: Decodable, Identifiable {
    public var id: String { cert }
    public let cert: String
    public let grader: String
    public let grade: String
    public let category: String        // label here (e.g. "Baseball")
    public let card_title: String
    public let cardladder_value: Double?
    public let confidence: FlexNum
    public let decision: String
    public let offer_amount: Double?
    public let item_status: String     // pending | accepted | rejected | pass (UNCHANGED — legacy builds rely on it)
    public let review_state: String?   // approved | pending | refused | nil(legacy) — drives the Review Cards tabs
    public let image_url: String?      // real cert photo; may be "" or absent
}

// Tolerant numeric decode: the KTS rules store blank tier fields as the
// empty string "" (not null). Coerce "", missing, Int, and numeric strings so a
// single open-ended tier can't throw and break the whole rules/rates decode.
enum KTSFlex {
    static func double<K>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key) { return d }
        if let i = try? c.decode(Int.self, forKey: key) { return Double(i) }
        if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

// GET /rates
public struct RatesResponse: Decodable {
    public let categories: [RateCategory]
    public let updated_at: String?
    public let pokemonLane: PokemonLane?   // the Pokémon unlimited lane, its own section (nil = off)
    public let mainOpensAt: String?   // ISO — when One Piece + sports submissions open (nil = open/unknown)
    public let pokemonOpensAt: String?   // ISO — when Pokémon submissions open (nil = open/unknown)
}
// Pokémon unlimited lane — seller-safe fields only.
// All numerics are Double? so an int-or-float JSON number decodes either way; keys may be absent.
public struct PokemonLane: Decodable {
    public let minValue: Double?
    public let maxValue: Double?
    public let minConf: Double?
    public let grades: [Int]?
    public let minYear: Double?
    public let english: Bool?
    public let rate: Double?
    public let maxCopies: Double?
}
public struct RateCategory: Decodable, Identifiable { public var id: String { category }; public let category: String; public let label: String; public let graders: [RateGrader] }
public struct RateGrader: Decodable, Identifiable {
    public var id: String { grader }
    public let grader: String
    public let minGrade: Double?        // track-level min grade (e.g. 7) or nil (any grade)
    public let minCert: Double?         // lowest cert NUMBER KTS will take — recency gate; nil = any
    public let tiers: [RateTier]
    enum CodingKeys: String, CodingKey { case grader, minGrade, minCert, tiers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grader = try c.decode(String.self, forKey: .grader)
        minGrade = KTSFlex.double(c, .minGrade)   // "" / missing -> nil
        minCert = KTSFlex.double(c, .minCert)
        tiers = try c.decode([RateTier].self, forKey: .tiers)
    }
}
public struct RateTier: Decodable, Identifiable {
    public var id: String { "\(min ?? -1)-\(max ?? -1)-\(rate)-\(minConf ?? -1)-\(minGrade ?? -1)" }
    public let min: Double?
    public let max: Double?
    public let rate: Double
    public let minConf: Double?         // CardLadder confidence 1–5 (NOT %) or nil (any)
    public let minGrade: Double?        // tier-level min-grade override or nil
    enum CodingKeys: String, CodingKey { case min, max, rate, minConf, minGrade }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = KTSFlex.double(c, .min); max = KTSFlex.double(c, .max)
        rate = KTSFlex.double(c, .rate) ?? 0
        minConf = KTSFlex.double(c, .minConf); minGrade = KTSFlex.double(c, .minGrade)
    }
}

// GET /shipping — ship-to address + this buying week's shipment for the seller.
// POST /shipping/tracking { tracking } returns { ok, registered, shipment }.
public struct Shipment: Decodable {
    public let tracking: String?
    public let carrier: String?
    public let status: String?        // "unknown" | "in_transit" | "delivered" | …
    public let delivered_at: String?  // ISO when delivered
}
public struct ShippingResponse: Decodable {
    public let address: String?
    public let weekStart: String?
    public let shipment: Shipment?
}
public struct ShippingTrackingResponse: Decodable {
    public let ok: Bool
    public let registered: Bool?
    public let shipment: Shipment?
}


// MARK: - API client (cookie-based auth via shared HTTPCookieStorage)

public struct APIError: LocalizedError {
    public let message: String
    public var unauthorized = false
    public var lockedWindow: String?      // "main" | "pokemon" when /submit blocks a gated window (409)
    public var mainOpensAt: String?    // ISO8601 — when the main (One Piece + sports) window opens
    public var pokemonOpensAt: String?    // ISO8601 — when the Pokémon window opens
    public var errorDescription: String? { message }
    public var isWindowLocked: Bool { lockedWindow != nil }
}

public final class API {
    public static let shared = API()
    public static let baseURL = URL(string: "https://portal.ktscollectibles.com")!
    private let session: URLSession
    // Fired on any 401 so a logged-in seller whose cookie expired is sent back to login.
    public var onUnauthorized: (() -> Void)?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 25
        session = URLSession(configuration: cfg)
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await send(path, method: method, httpBody: data)
    }

    // Core sender; accepts an already-encoded JSON body (used for Codable payloads too).
    private func send(_ path: String, method: String, httpBody: Data?) async throws -> Data {
        // Split off a "?query" so it stays a real query string — appendingPathComponent would
        // percent-encode the "?" into the path and the server would never see the params.
        let url: URL
        if let q = path.firstIndex(of: "?") {
            var comp = URLComponents(url: API.baseURL.appendingPathComponent(String(path[..<q])), resolvingAgainstBaseURL: false)!
            comp.percentEncodedQuery = String(path[path.index(after: q)...])
            url = comp.url ?? API.baseURL.appendingPathComponent(path)
        } else {
            url = API.baseURL.appendingPathComponent(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let b = httpBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = b
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw APIError(message: "Network error — check your connection.") }
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "No response from server.") }
        if http.statusCode >= 400 {
            if http.statusCode == 401 { onUnauthorized?() }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? String {
                // /submit reports a closed window as `locked: "main"|"pokemon"`.
                let locked = obj["locked"] as? String
                throw APIError(message: e, unauthorized: http.statusCode == 401,
                               lockedWindow: locked,
                               mainOpensAt: obj["mainOpensAt"] as? String,
                               pokemonOpensAt: obj["pokemonOpensAt"] as? String)
            }
            throw APIError(message: "Something went wrong (\(http.statusCode)).", unauthorized: http.statusCode == 401)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(message: "Unexpected response from server.") }
    }

    public func me() async throws -> MeResponse { try decode(try await request("me")) }
    public func login(username: String, password: String) async throws -> AuthResponse {
        try decode(try await request("login", method: "POST", body: ["discord_username": username, "password": password]))
    }
    public func join(invite: String, username: String, password: String, email: String, phone: String) async throws -> AuthResponse {
        try decode(try await request("join", method: "POST", body: [
            "invite_code": invite, "discord_username": username, "password": password,
            "email": email, "phone": phone
        ]))
    }
    public func logout() async throws { _ = try await request("logout", method: "POST") }
    // Password reset: request a code (always succeeds, never reveals account existence), then confirm.
    public func forgotPassword(username: String) async throws {
        _ = try await request("forgot-password", method: "POST", body: ["discord_username": username])
    }
    public func resetPassword(username: String, code: String, password: String) async throws {
        _ = try await request("reset-password", method: "POST", body: ["discord_username": username, "code": code, "password": password])
    }

    public func price(cert: String) async throws -> SellerView {
        #if DEBUG
        if KTS_PREVIEW_MOCK { await ktsMockDelay(); return ktsMockPrice(cert: cert) }
        #endif
        struct R: Decodable { let results: [SellerView] }
        let r: R = try decode(try await request("price", method: "POST", body: ["cert": cert]))
        guard let first = r.results.first else { throw APIError(message: "No price came back.") }
        return first
    }
    public func deleteSubmission(id: Int) async throws {
        #if DEBUG
        if KTS_PREVIEW_MOCK { ktsMockDelete(id: id); return }
        #endif
        _ = try await request("submission/\(id)", method: "DELETE")
    }
    public func submit(certs: [String]) async throws -> SubmitResponse {
        #if DEBUG
        if KTS_PREVIEW_MOCK { await ktsMockDelay(); return ktsMockSubmit(certs: certs) }
        #endif
        return try decode(try await request("submit", method: "POST", body: ["certs": certs]))
    }
    public func mine() async throws -> MineResponse {
        #if DEBUG
        if KTS_PREVIEW_MOCK { return ktsMockMine() }
        #endif
        return try decode(try await request("mine"))
    }
    public func rates() async throws -> RatesResponse {
        #if DEBUG
        if KTS_PREVIEW_MOCK { return ktsMockRates() }
        #endif
        return try decode(try await request("rates"))
    }

    // Shipping: where to mail this week's approved cards + this week's tracking/delivery state.
    public func shipping() async throws -> ShippingResponse {
        #if DEBUG
        if KTS_PREVIEW_MOCK { return ktsMockShipping() }
        #endif
        return try decode(try await request("shipping"))
    }
    public func submitTracking(_ tracking: String) async throws -> ShippingTrackingResponse {
        try decode(try await request("shipping/tracking", method: "POST", body: ["tracking": tracking]))
    }

    // Register this device's APNs token. Uses the all-users endpoint so sellers register too
    // (admins are sellers as well). The backend targets submission alerts to admin devices
    // only, and broadcasts to every registered device.
    public func registerPushToken(_ token: String) async {
        _ = try? await request("push-token", method: "POST", body: ["token": token, "platform": "ios"])
    }
}


// MARK: - App state (flat hub-and-spoke navigation, like the web app's showView)

@MainActor
public final class AppState: ObservableObject {
    public enum Phase { case loading, auth, app }
    public enum Screen { case home, scan, reviewCards, pastSubs, rates }

    @Published public var phase: Phase = .loading
    @Published public var screen: Screen = .home
    @Published public var username: String = ""
    @Published public var isAdmin: Bool = false
    @Published public var hideAmounts: Bool = UserDefaults.standard.string(forKey: "kts_hide") == "1"
    @Published public var showWelcome = false   // one-time post-signup confirmation screen

    // shared submissions cache (home stats + subs screen both use /mine)
    @Published public var submissions: [Submission] = []
    @Published public var mineLoadFailed = false   // last /mine fetch errored (vs genuinely empty)

    public init() {
        API.shared.onUnauthorized = { [weak self] in
            Task { @MainActor in
                #if DEBUG
                if KTS_PREVIEW_MOCK { return }   // sim preview: don't bounce when unmocked admin calls 401
                #endif
                guard let self = self, self.phase == .app else { return }
                self.username = ""; self.isAdmin = false; self.submissions = []
                self.screen = .home; self.phase = .auth
            }
        }
        // Tapping a "new submission" push deep-links to Review Cards.
        NotificationCenter.default.addObserver(forName: .ktsOpenReview, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.phase == .app else { return }
            self.screen = .reviewCards
        }
    }

    // Every logged-in user: ask for notification permission + register for APNs. Admins get
    // all users can receive broadcast announcements. The backend targets new-submission
    // alerts to staff devices only, so sellers only ever receive broadcasts.
    public func maybeRegisterPush() { KTSPush.requestAndRegister() }

    public func setHide(_ v: Bool) {
        hideAmounts = v
        UserDefaults.standard.set(v ? "1" : "0", forKey: "kts_hide")
    }

    public func boot() async {
        #if DEBUG
        if KTS_PREVIEW_MOCK {   // offline demo (no backend/login): land on Home; the scanner works via PortalMock
            username = "demo"; phase = .app; screen = .home
            submissions = ktsMockMine().submissions
            return
        }
        #endif
        do {
            let me = try await API.shared.me()
            if let s = me.seller { username = s.discord_username; isAdmin = me.isAdmin; phase = .app; screen = .home; maybeRegisterPush() }
            else { phase = .auth }
        } catch { phase = .auth }
    }

    public func onAuthed(_ name: String, justJoined: Bool = false) {
        username = name; phase = .app; screen = .home
        showWelcome = justJoined   // show the native welcome only for brand-new signups
        #if DEBUG
        if KTS_PREVIEW_MOCK { isAdmin = true }   // sim-only admin preview
        #endif
        // Re-fetch /me so admin status is known right after login/join (mirrors the web client).
        Task {
            if let me = try? await API.shared.me() {
                isAdmin = me.isAdmin
                if let s = me.seller { username = s.discord_username }
                maybeRegisterPush()
            }
        }
    }

    public func signOut() async {
        UserDefaults.standard.removeObject(forKey: ScanModel.draftKey(username))
        try? await API.shared.logout()
        if let url = URL(string: "https://portal.ktscollectibles.com") {
            let storage = HTTPCookieStorage.shared
            for cookie in storage.cookies(for: url) ?? [] where ["kts_admin", "kts_seller"].contains(cookie.name) {
                storage.deleteCookie(cookie)
            }
        }
        username = ""; isAdmin = false; submissions = []
        phase = .auth; screen = .home; showWelcome = false
    }

    public func refreshMine() async {
        do { submissions = try await API.shared.mine().submissions; mineLoadFailed = false }
        catch { mineLoadFailed = true }
    }

    // Home stats derived from /mine, by each slab's OWN item_status (so an admin
    // rejecting a single slab removes it from "accepted" / "paid").
    public var pendingCount: Int {
        submissions.flatMap { $0.items }.filter { $0.item_status == "pending" }.count
    }
    public var acceptedCount: Int {
        submissions.flatMap { $0.items }.filter { $0.item_status == "accepted" }.count
    }
    public var acceptedTotal: Double {
        submissions.flatMap { $0.items }.filter { $0.item_status == "accepted" }
            .reduce(0) { $0 + ($1.offer_amount ?? 0) }
    }
}
