import SwiftUI
import UIKit   // UIScreen (screen width for the interactive swipe-back)

// MARK: - Reusable styling

struct KTSPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Color(hex: 0x0A1326))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(KTS.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
struct KTSGhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(KTS.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KTS.line.opacity(0.7)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct KTSDangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(KTS.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(KTS.red.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct KTSField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var autocap: TextInputAutocapitalization = .never
    var keyboard: UIKeyboardType = .default
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) }
            else { TextField(placeholder, text: $text).keyboardType(keyboard) }
        }
        .textInputAutocapitalization(autocap)
        .autocorrectionDisabled()
        .foregroundColor(KTS.txt)
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(KTS.panel2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KTS.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct Crest: View {
    var size: CGFloat = 34
    var body: some View {
        Image("Crest", bundle: .main)
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26))
    }
}

// Big login logo: fades its glowy edges into the navy background so there's no visible box.
struct HeroLogo: View {
    var size: CGFloat = 184
    var body: some View {
        Image("Crest", bundle: .main)
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .mask(
                RadialGradient(gradient: Gradient(stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1.0)
                ]), center: .center, startRadius: 0, endRadius: size * 0.52)
            )
            .shadow(color: KTS.blue.opacity(0.35), radius: 26)
    }
}

struct Wordmark: View {
    var crestSize: CGFloat = 34
    var body: some View {
        HStack(spacing: crestSize > 0 ? 10 : 0) {
            if crestSize > 0 { Crest(size: crestSize) }
            (Text("KTS").foregroundColor(KTS.txt) + Text(" Portal").foregroundColor(KTS.accent))
                .font(.system(size: 20, weight: .heavy))
        }
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: 0xFFD7D7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(KTS.red.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(KTS.red.opacity(0.4)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Root

public struct RootView: View {
    @StateObject private var app = AppState()
    @State private var showSplash = true
    public init() {}
    public var body: some View {
        ZStack {
            ZStack {
                KTS.bg.ignoresSafeArea()
                RadialGradient(colors: [KTS.accent.opacity(0.06), .clear], center: .top, startRadius: 0, endRadius: 420)
                    .ignoresSafeArea()
                switch app.phase {
                case .loading:
                    ProgressView().tint(KTS.accent)
                case .auth:
                    AuthView().environmentObject(app)
                case .app:
                    AppShell().environmentObject(app)
                }
            }
            .environment(\.colorScheme, .dark)
            .tint(KTS.accent)
            .task { await app.boot() }

            // Launch "power-on surge" splash, then fade to the app.
            if showSplash {
                SplashView(onDone: { showSplash = false })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }
}

// MARK: - Auth

struct AuthView: View {
    @EnvironmentObject var app: AppState
    enum Tab { case login, join }
    @State private var tab: Tab = .login
    @State private var lUser = ""
    @State private var lPass = ""
    @State private var sCode = ""
    @State private var sUser = ""
    @State private var sEmail = ""
    @State private var sPhone = ""
    @State private var sPass = ""
    @State private var err = ""
    @State private var busy = false
    @State private var showForgot = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        HeroLogo(size: 196)
                        Text("Seller portal").font(.system(size: 14)).foregroundColor(KTS.muted)
                    }
                    .padding(.top, 10)

                    Picker("", selection: $tab) {
                        Text("Log in").tag(Tab.login)
                        Text("Join / Sign up").tag(Tab.join)
                    }
                    .pickerStyle(.segmented)

                    Banner(text: err)

                    if tab == .login {
                        VStack(spacing: 12) {
                            KTSField(placeholder: "Discord username", text: $lUser)
                            KTSField(placeholder: "Password", text: $lPass, secure: true)
                            Button(busy ? "…" : "Log in") { Task { await doLogin() } }
                                .buttonStyle(KTSPrimaryButton()).disabled(busy)
                            Button("Forgot password?") { err = ""; showForgot = true }
                                .font(.system(size: 13, weight: .medium)).foregroundColor(KTS.accent)
                                .padding(.top, 2)
                        }
                    } else {
                        VStack(spacing: 12) {
                            KTSField(placeholder: "Invite code", text: $sCode, autocap: .characters)
                            KTSField(placeholder: "Discord username", text: $sUser)
                            KTSField(placeholder: "Email", text: $sEmail, keyboard: .emailAddress)
                            KTSField(placeholder: "Cell phone", text: $sPhone, keyboard: .phonePad)
                            KTSField(placeholder: "Create a password (min 4)", text: $sPass, secure: true)
                            Button(busy ? "…" : "Create account") { Task { await doJoin() } }
                                .buttonStyle(KTSPrimaryButton()).disabled(busy)
                        }
                    }

                    Text("Invite-only. Your code comes from KTS.")
                        .font(.system(size: 12)).foregroundColor(KTS.muted)
                        .padding(.top, 4)

                    Spacer(minLength: 28)

                    BrandFooter().padding(.bottom, 12)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
            .sheet(isPresented: $showForgot) {
                ForgotPasswordView(prefillUser: lUser) { u in
                    lUser = u; err = "Password reset — log in with your new password."
                }
            }
        }
    }

    func doLogin() async {
        err = ""; guard !lUser.isEmpty, !lPass.isEmpty else { err = "Enter your username and password."; return }
        busy = true; defer { busy = false }
        do { let r = try await API.shared.login(username: lUser, password: lPass); app.onAuthed(r.seller.discord_username) }
        catch { err = (error as? APIError)?.message ?? "Login failed." }
    }
    func doJoin() async {
        err = ""
        let phoneDigits = sPhone.filter(\.isNumber)
        guard !sCode.isEmpty, !sUser.isEmpty else { err = "Fill in all fields."; return }
        guard isValidEmail(sEmail) else { err = "Enter a valid email address."; return }
        guard phoneDigits.count >= 10 else { err = "Enter a valid cell phone number."; return }
        guard sPass.count >= 12 else { err = "Password must be at least 12 characters."; return }
        busy = true; defer { busy = false }
        do { let r = try await API.shared.join(invite: sCode, username: sUser, password: sPass, email: sEmail, phone: sPhone); app.onAuthed(r.seller.discord_username, justJoined: true) }
        catch {
            let msg = (error as? APIError)?.message ?? "Sign up failed."
            if msg.contains("already registered") { tab = .login; lUser = sUser }
            err = msg
        }
    }
    private func isValidEmail(_ s: String) -> Bool {
        s.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }
}

// Password reset — request a code by username, then set a new password with it.
struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    var prefillUser: String = ""
    var onReset: (String) -> Void
    enum Step { case request, confirm, done }
    @State private var step: Step = .request
    @State private var username = ""
    @State private var code = ""
    @State private var newPass = ""
    @State private var err = ""
    @State private var busy = false

    var body: some View {
        ZStack {
            KTS.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Reset password").font(.system(size: 20, weight: .bold)).foregroundColor(KTS.txt)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundColor(KTS.muted)
                                .padding(8).background(KTS.panel.opacity(0.6)).clipShape(Circle())
                        }.accessibilityLabel("Close")
                    }
                    .padding(.top, 6)
                    Banner(text: err)
                    switch step {
                    case .request:
                        Text("Enter your username. We'll email a 6-digit reset code to the email on your account.")
                            .font(.system(size: 14)).foregroundColor(KTS.muted)
                        KTSField(placeholder: "Discord username", text: $username)
                        Button(busy ? "…" : "Send reset code") { Task { await sendCode() } }
                            .buttonStyle(KTSPrimaryButton()).disabled(busy)
                    case .confirm:
                        Text("If your account has an email on file, we sent a 6-digit code to it. Enter the code and a new password. No email on file? Contact KTS to reset.")
                            .font(.system(size: 14)).foregroundColor(KTS.muted)
                        KTSField(placeholder: "6-digit code", text: $code, keyboard: .numberPad)
                        KTSField(placeholder: "New password (min 4)", text: $newPass, secure: true)
                        Button(busy ? "…" : "Reset password") { Task { await doReset() } }
                            .buttonStyle(KTSPrimaryButton()).disabled(busy)
                        Button("Resend code") { Task { await sendCode() } }
                            .buttonStyle(KTSGhostButton()).disabled(busy)
                    case .done:
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundColor(KTS.green)
                            Text("Password reset").font(.system(size: 20, weight: .bold)).foregroundColor(KTS.txt)
                            Text("You can now log in with your new password.")
                                .font(.system(size: 14)).foregroundColor(KTS.muted).multilineTextAlignment(.center)
                            Button("Back to login") { onReset(username); dismiss() }.buttonStyle(KTSPrimaryButton())
                        }
                        .frame(maxWidth: .infinity).padding(.top, 12)
                    }
                    Spacer(minLength: 20)
                }
                .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
        }
        .environment(\.colorScheme, .dark).tint(KTS.accent)
        .onAppear { if username.isEmpty { username = prefillUser } }
    }

    private func sendCode() async {
        err = ""; guard !username.isEmpty else { err = "Enter your username."; return }
        busy = true; defer { busy = false }
        do { try await API.shared.forgotPassword(username: username); withAnimation { step = .confirm } }
        catch { err = (error as? APIError)?.message ?? "Couldn't send a code. Try again." }
    }
    private func doReset() async {
        err = ""
        guard code.count >= 4 else { err = "Enter the code from your email."; return }
        guard newPass.count >= 12 else { err = "Password must be at least 12 characters."; return }
        busy = true; defer { busy = false }
        do { try await API.shared.resetPassword(username: username, code: code, password: newPass); withAnimation { step = .done } }
        catch { err = (error as? APIError)?.message ?? "Couldn't reset — check the code and try again." }
    }
}

// Subtle brand footer that anchors the empty space below the login form.
struct BrandFooter: View {
    var body: some View {
        VStack(spacing: 6) {
            Rectangle().fill(KTS.line.opacity(0.55)).frame(width: 44, height: 1)
                .padding(.bottom, 3)
            Text("K T S   C O L L E C T I B L E S")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(KTS.txt.opacity(0.62))
            Text("Professional Card Buying & Wholesale")
                .font(.system(size: 11))
                .foregroundColor(KTS.muted.opacity(0.85))
        }
        .multilineTextAlignment(.center)
    }
}

// MARK: - App shell (flat navigation)

struct AppShell: View {
    @EnvironmentObject var app: AppState
    @State private var dragX: CGFloat = 0     // current screen's live offset during a back-drag
    @State private var backing = false        // a back-drag (or its finishing spring) is in progress

    private var canBack: Bool { app.screen != .home }
    private var screenW: CGFloat { max(UIScreen.main.bounds.width, 1) }

    // The app has no NavigationStack, so this hand-rolls an interactive edge-pop: the current
    // screen tracks the finger, Home eases in beneath it with a dim + parallax, and the drag
    // either springs to completion (→ Home) or snaps back on release.
    var body: some View {
        ZStack(alignment: .leading) {
            KTS.bg.ignoresSafeArea()

            // Previous screen (Home) revealed underneath, sliding in from the left behind a
            // fading dim so release reads as a real pop, not a hard cut.
            if backing && canBack {
                HomeView()
                    .environmentObject(app)
                    .allowsHitTesting(false)
                    .offset(x: -screenW * 0.25 * (1 - dragX / screenW))
                    .overlay(Color.black.opacity(0.22 * (1 - dragX / screenW)).ignoresSafeArea())
            }

            // The current screen follows the finger, with a soft shadow on its leading edge.
            currentScreen
                .environmentObject(app)
                .offset(x: dragX)
                .shadow(color: Color.black.opacity(backing ? 0.3 : 0), radius: 16, x: -10)

        }
        // Reliable left-edge pop via UIKit's screen-edge recognizer (a SwiftUI drag over a
        // ScrollView only catches intermittently). It drives the offset above and springs to
        // completion (→ Home) or snaps back on release.
        .overlay {
            if canBack {
                EdgePanBack(
                    onChanged: { tx in
                        backing = true
                        dragX = min(max(0, tx), screenW)
                    },
                    onEnded: { tx, vx in
                        guard backing else { return }
                        let w = screenW
                        if tx > w * 0.3 || vx > 350 {           // committed: drag ⅓ across, or a flick
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragX = w }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                                app.screen = .home; dragX = 0; backing = false
                            }
                        } else {                                 // cancelled: snap back
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragX = 0 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { backing = false }
                        }
                    }
                )
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $app.showWelcome) {
            WelcomeView().environmentObject(app)
        }
    }

    @ViewBuilder private var currentScreen: some View {
        switch app.screen {
        case .home:  HomeView()
        case .scan:  ScanView(owner: app.username).id(app.username)
        case .reviewCards: ReviewCardsView()
        case .pastSubs:    PastSubmissionsView()
        case .rates: RatesView()
        }
    }
}

// Left-edge back-swipe, backed by UIKit's screen-edge pan recognizer so it reliably wins the
// gesture over any ScrollView beneath (a plain SwiftUI DragGesture does not). The host view is
// transparent and only hit-tests the left strip below the header, so it never blocks content
// taps or the ‹ Home button. Reports live translation + release velocity back to SwiftUI.
struct EdgePanBack: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void    // translationX (≥0), velocityX

    func makeUIView(context: Context) -> UIView {
        let v = EdgeHitView()
        v.backgroundColor = .clear
        let g = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        g.edges = .left
        v.addGestureRecognizer(g)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }
    func makeCoordinator() -> Coordinator { Coordinator(onChanged, onEnded) }

    // Only the left strip below the header is interactive; everything else passes through.
    final class EdgeHitView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            point.x < 36 && point.y > 80
        }
    }
    final class Coordinator: NSObject {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        init(_ c: @escaping (CGFloat) -> Void, _ e: @escaping (CGFloat, CGFloat) -> Void) { onChanged = c; onEnded = e }
        @objc func handle(_ g: UIScreenEdgePanGestureRecognizer) {
            let tx = g.translation(in: g.view).x
            switch g.state {
            case .began, .changed: onChanged(max(0, tx))
            case .ended, .cancelled, .failed: onEnded(max(0, tx), g.velocity(in: g.view).x)
            default: break
            }
        }
    }
}

// Native post-signup confirmation — shown once, right after a brand-new account is created.
struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ZStack {
            KTS.bg.ignoresSafeArea()
            RadialGradient(colors: [KTS.accent.opacity(0.08), .clear], center: .top, startRadius: 0, endRadius: 440)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                HeroLogo(size: 148)
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundColor(KTS.green)
                    Text("You're all set").font(.system(size: 26, weight: .heavy)).foregroundColor(KTS.accent)
                    Text("Welcome, \(app.username.isEmpty ? "seller" : app.username) — your KTS Portal account is ready.")
                        .font(.system(size: 15, weight: .medium)).foregroundColor(KTS.txt)
                        .multilineTextAlignment(.center)
                    Text("At a show, scan your slabs and you'll see KTS's offer on each card instantly — then submit a batch for review. A confirmation email is on its way to your inbox.")
                        .font(.system(size: 13)).foregroundColor(KTS.muted)
                        .multilineTextAlignment(.center).padding(.horizontal, 6)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button("Start scanning") { app.screen = .scan; app.showWelcome = false }
                        .buttonStyle(KTSPrimaryButton())
                    Button("Go to home") { app.showWelcome = false }
                        .buttonStyle(KTSGhostButton())
                }
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .environment(\.colorScheme, .dark)
        .tint(KTS.accent)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var loaded = false
    @State private var confirmSignOut = false

    // This buying week's accepted payout + counts (resets weekly), alongside all-time.
    private var acceptedThisWeekTotal: Double {
        app.submissions.filter { ktsIsThisWeek($0.created_at) }.flatMap { $0.items }
            .filter { $0.item_status == "accepted" }.reduce(0) { $0 + ($1.offer_amount ?? 0) }
    }
    private var acceptedThisWeekCount: Int {
        app.submissions.filter { ktsIsThisWeek($0.created_at) }.flatMap { $0.items }
            .filter { $0.item_status == "accepted" }.count
    }
    private var pendingThisWeekCount: Int {
        app.submissions.filter { ktsIsThisWeek($0.created_at) }.flatMap { $0.items }
            .filter { $0.item_status == "pending" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Wordmark(crestSize: 30)
                Spacer()
                Button { confirmSignOut = true } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(KTS.muted)
                }
                .accessibilityLabel("Sign out")
                .confirmationDialog("Sign out of KTS Portal?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                    Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                    Button("Cancel", role: .cancel) { }
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Greeting + a hero stat the seller can be proud of.
                    VStack(alignment: .leading, spacing: 14) {
                        (Text("Welcome back, ").foregroundColor(KTS.muted)
                         + Text(app.username.isEmpty ? "seller" : app.username).foregroundColor(KTS.txt).fontWeight(.bold))
                            .font(.system(size: 25, weight: .semibold))
                            .padding(.horizontal, 20)

                        if app.mineLoadFailed && app.submissions.isEmpty {
                            Button { Task { await app.refreshMine() } } label: {
                                Text("Couldn't load your stats — tap to retry").font(.system(size: 13)).foregroundColor(KTS.accent)
                            }.buttonStyle(.plain).padding(.horizontal, 20)
                        } else {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundColor(KTS.accent)
                                    Text("ACCEPTED THIS WEEK").font(.system(size: 11, weight: .bold)).foregroundColor(KTS.muted)
                                }
                                Text(ktsMoney(acceptedThisWeekTotal, hide: app.hideAmounts))
                                    .font(.system(size: 42, weight: .heavy)).foregroundColor(KTS.accent)
                                    .monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                                HStack(spacing: 7) {
                                    Text("\(acceptedThisWeekCount) card\(acceptedThisWeekCount == 1 ? "" : "s") this week")
                                        .font(.system(size: 13, weight: .semibold)).foregroundColor(KTS.txt.opacity(0.85))
                                    if pendingThisWeekCount > 0 {
                                        Text("·").font(.system(size: 13)).foregroundColor(KTS.muted)
                                        Text("\(pendingThisWeekCount) pending").font(.system(size: 13, weight: .medium)).foregroundColor(KTS.muted)
                                    }
                                }
                                Rectangle().fill(KTS.line.opacity(0.5)).frame(height: 1).padding(.top, 6).padding(.bottom, 2)
                                HStack(spacing: 5) {
                                    Text(ktsMoney(app.acceptedTotal, hide: app.hideAmounts)).font(.system(size: 13, weight: .bold)).foregroundColor(KTS.txt).monospacedDigit()
                                    Text("accepted all-time").font(.system(size: 12)).foregroundColor(KTS.muted)
                                    Spacer(minLength: 4)
                                    Text("\(app.acceptedCount) card\(app.acceptedCount == 1 ? "" : "s")").font(.system(size: 12)).foregroundColor(KTS.muted)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(LinearGradient(colors: [KTS.accent.opacity(0.16), KTS.accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .background(KTS.panel.opacity(0.6))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KTS.accent.opacity(0.28)))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 22)

                    VStack(spacing: 10) {
                        MenuCard(icon: "camera.fill", title: "Scan & Submit", subtitle: "Price your slabs and send a batch") { app.screen = .scan }
                        MenuCard(icon: "square.stack.3d.up.fill", title: "Review Cards", subtitle: "Your cards this buying week") { app.screen = .reviewCards }
                        MenuCard(icon: "doc.text.fill", title: "Past Submissions", subtitle: "Previous buying weeks") { app.screen = .pastSubs }
                        MenuCard(icon: "tag.fill", title: "This Week's Rates", subtitle: "What KTS pays, by category") { app.screen = .rates }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
        .task { if !loaded { loaded = true; await app.refreshMine() } }
    }
}

// Rich navigation card (icon tile + title + subtitle + chevron).
struct MenuCard: View {
    let icon: String; let title: String; let subtitle: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(KTS.accent)
                    .frame(width: 44, height: 44)
                    .background(RadialGradient(colors: [Color(hex: 0x1D2D55), Color(hex: 0x13203F)], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: 52))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(KTS.line.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(KTS.txt)
                    Text(subtitle).font(.system(size: 12.5)).foregroundColor(KTS.muted)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").foregroundColor(KTS.muted).font(.system(size: 14, weight: .semibold))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KTS.panel.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KTS.line.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// Simple sub-screen scaffold with a back button.
struct SubScreen<Content: View>: View {
    @EnvironmentObject var app: AppState
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.screen = .home } label: {
                    HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Home") }
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(KTS.muted)
                }
                Spacer()
                Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(KTS.txt)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            content
        }
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
    }
}

// MARK: - Date helpers

func ktsParseDate(_ iso: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)
}

// "2d ago" / "3h ago" / "just now" from an ISO-8601 timestamp.
func ktsRelativeTime(_ iso: String) -> String {
    guard let d = ktsParseDate(iso) else { return "" }
    if Date().timeIntervalSince(d) < 60 { return "just now" }
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    return rel.localizedString(for: d, relativeTo: Date())
}

// Start of the current buying week — most recent Tuesday, 00:00 local. (Monday stays in the
// prior week so the previous buying week can be finalized/shipped on Mondays.)
func ktsStartOfThisWeek() -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 3 // Tuesday
    return cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
}
func ktsIsThisWeek(_ iso: String) -> Bool {
    guard let d = ktsParseDate(iso) else { return false }
    return d >= ktsStartOfThisWeek()
}
// Tuesday-00:00 (local) week start for any date — buckets past submissions by buying week.
func ktsWeekStart(for date: Date) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 3 // Tuesday
    return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
}
// "Oct 21 – 27" style label for a Tue–Mon week.
func ktsWeekLabel(_ weekStart: Date) -> String {
    let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    let md = DateFormatter(); md.dateFormat = "MMM d"
    let dOnly = DateFormatter(); dOnly.dateFormat = "d"
    let mon = DateFormatter(); mon.dateFormat = "MMM"
    return mon.string(from: weekStart) == mon.string(from: end)
        ? "\(md.string(from: weekStart)) – \(dOnly.string(from: end))"
        : "\(md.string(from: weekStart)) – \(md.string(from: end))"
}

// The Review Cards bucket for a submitted item: "approved" | "pending" | "refused".
// Prefers the backend's review_state; falls back to the legacy status for older rows.
func ktsReviewBucket(_ it: SubItem) -> String {
    switch it.review_state {
    case "approved", "pending", "refused": return it.review_state!
    default:
        if it.item_status == "accepted" { return "approved" }
        if it.item_status == "rejected" { return "refused" }
        return it.decision == "BUY" ? "approved" : "refused"
    }
}

// "Oct 24" from a Date.
func ktsShortDate(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
}
// cents -> "$30" / "$0.40" / "$1,400"
func ktsDollars(_ cents: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"
    let whole = cents % 100 == 0
    f.maximumFractionDigits = whole ? 0 : 2; f.minimumFractionDigits = whole ? 0 : 2
    return f.string(from: NSNumber(value: Double(cents) / 100.0)) ?? "$\(Double(cents)/100.0)"
}
// Category key -> display label.
func ktsCatLabel(_ c: String) -> String {
    switch c {
    case "one_piece", "onepiece": return "One Piece"
    case "pokemon": return "Pokémon"
    default: return c.prefix(1).uppercased() + c.dropFirst()
    }
}

// Shared "couldn't load" + retry for the /mine-backed screens.
struct MineErrorRetry: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 26)).foregroundColor(KTS.muted)
            Text("Couldn't load your submissions.").font(.system(size: 14)).foregroundColor(KTS.muted)
            Button { Task { await app.refreshMine() } } label: { Text("Retry").frame(maxWidth: 180) }
                .buttonStyle(KTSGhostButton())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}

// Review Cards status tabs: All / Pending / Approved / Refused.
enum ReviewTab: CaseIterable {
    case all, pending, approved, refused
    var title: String {
        switch self {
        case .all: return "All"
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .refused: return "Refused"
        }
    }
    var bucket: String? {   // nil = no filter (All)
        switch self {
        case .all: return nil
        case .pending: return "pending"
        case .approved: return "approved"
        case .refused: return "refused"
        }
    }
}

// Review Cards — everything submitted THIS buying week, filterable by review status.
struct ReviewCardsView: View {
    @EnvironmentObject var app: AppState
    @State private var loaded = false
    @State private var tab: ReviewTab = .all

    private var weekItems: [SubItem] {
        app.submissions.filter { ktsIsThisWeek($0.created_at) }.flatMap { $0.items }
    }
    // Approved cards this week = what the seller actually ships, so the ship card shows only then.
    private var approvedThisWeek: Int { weekItems.filter { ktsReviewBucket($0) == "approved" }.count }
    private func tabCount(_ t: ReviewTab) -> Int {
        guard let b = t.bucket else { return weekItems.count }
        return weekItems.filter { ktsReviewBucket($0) == b }.count
    }
    private func bucketTotal(_ bucket: String) -> Double {
        weekItems.filter { ktsReviewBucket($0) == bucket }.reduce(0) { $0 + ($1.offer_amount ?? 0) }
    }
    private var filteredItems: [SubItem] {
        guard let b = tab.bucket else { return weekItems }
        return weekItems.filter { ktsReviewBucket($0) == b }
    }

    var body: some View {
        SubScreen(title: "Review Cards") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 11) {
                            KTSStatTile(value: ktsMoney(bucketTotal("approved"), hide: app.hideAmounts), label: "Approved this week", extra: "", color: KTS.accent)
                            KTSStatTile(value: ktsMoney(bucketTotal("pending"), hide: app.hideAmounts), label: "Awaiting approval", extra: "", color: KTS.blue)
                        }
                        Text(bucketTotal("pending") > 0 ? "Approved cards are locked in; pending are still under review." : "Every card you've submitted since Tuesday is below.")
                            .font(.system(size: 12)).foregroundColor(KTS.muted)
                    }
                    .padding(.top, 2).padding(.bottom, 2)

                    if approvedThisWeek > 0 { ShipCardView() }

                    if !app.submissions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ExportBar(fileName: "kts-my-submissions.csv") { ktsSellerExport(app.submissions) }
                            Text("Export all your submissions — copy for Sheets or download a CSV.")
                                .font(.system(size: 11)).foregroundColor(KTS.muted)
                        }
                        .padding(.bottom, 2)
                    }

                    if !weekItems.isEmpty { reviewTabBar }

                    if weekItems.isEmpty && app.mineLoadFailed {
                        MineErrorRetry()
                    } else if weekItems.isEmpty {
                        Text("No cards submitted yet this week.").font(.system(size: 14)).foregroundColor(KTS.muted)
                            .padding(.vertical, 40).frame(maxWidth: .infinity)
                    } else if filteredItems.isEmpty {
                        Text("No \(tab.title.lowercased()) cards this week.").font(.system(size: 14)).foregroundColor(KTS.muted)
                            .padding(.vertical, 30).frame(maxWidth: .infinity)
                    } else {
                        ForEach(filteredItems.indices, id: \.self) { i in
                            SubCardRow(item: filteredItems[i], batch: ktsReviewBucket(filteredItems[i]), hide: app.hideAmounts)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
        .environmentObject(app)
        .task { if !loaded { loaded = true; await app.refreshMine() } }
    }

    private var reviewTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReviewTab.allCases, id: \.self) { t in
                    let selected = tab == t
                    Button { withAnimation(.easeInOut(duration: 0.15)) { tab = t } } label: {
                        HStack(spacing: 6) {
                            Text(t.title).font(.system(size: 13, weight: .semibold))
                            Text("\(tabCount(t))").font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(selected ? Color.black.opacity(0.18) : KTS.line.opacity(0.5))
                                .clipShape(Capsule())
                        }
                        .foregroundColor(selected ? .black : KTS.txt)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(selected ? KTS.accent : KTS.panel.opacity(0.6))
                        .overlay(Capsule().stroke(KTS.line.opacity(selected ? 0 : 0.5)))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// Past Submissions — prior buying weeks grouped into week rows; tap a week to see its
// submissions, tap a submission for detail.
struct PastSubmissionsView: View {
    @EnvironmentObject var app: AppState
    @State private var loaded = false
    @State private var selected: Submission?
    @State private var openWeek: Date?

    private var pastSubs: [Submission] {
        app.submissions.filter { !ktsIsThisWeek($0.created_at) }
    }
    // Group past submissions into Tue–Mon weeks, newest first.
    private var weeks: [SellerWeekGroup] {
        var map: [Date: [Submission]] = [:]
        for s in pastSubs {
            guard let d = ktsParseDate(s.created_at) else { continue }
            map[ktsWeekStart(for: d), default: []].append(s)
        }
        return map.keys.sorted(by: >).map { SellerWeekGroup(weekStart: $0, subs: map[$0] ?? []) }
    }
    private var openWeekSubs: [Submission] {
        guard let w = openWeek else { return [] }
        return pastSubs
            .filter { ktsParseDate($0.created_at).map { ktsWeekStart(for: $0) } == w }
            .sorted { $0.created_at > $1.created_at }
    }

    var body: some View {
        SubScreen(title: "Past Submissions") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !app.submissions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ExportBar(fileName: "kts-my-submissions.csv") { ktsSellerExport(app.submissions) }
                            Text("Export all your submissions — copy for Sheets or download a CSV.")
                                .font(.system(size: 11)).foregroundColor(KTS.muted)
                        }
                        .padding(.bottom, 2)
                    }

                    if pastSubs.isEmpty && app.mineLoadFailed {
                        MineErrorRetry()
                    } else if pastSubs.isEmpty {
                        Text("No past submissions yet.").font(.system(size: 14)).foregroundColor(KTS.muted)
                            .padding(.vertical, 40).frame(maxWidth: .infinity)
                    } else if let w = openWeek {
                        // One week's submissions.
                        Button { withAnimation(.easeInOut(duration: 0.18)) { openWeek = nil } } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                                Text("Weeks").font(.system(size: 14, weight: .semibold))
                            }.foregroundColor(KTS.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(ktsWeekLabel(w)).font(.system(size: 16, weight: .heavy)).foregroundColor(KTS.txt)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(openWeekSubs) { sub in
                            Button { selected = sub } label: { SubGroupRow(sub: sub, hide: app.hideAmounts) }
                                .buttonStyle(.plain)
                        }
                    } else {
                        // The list of past weeks.
                        ForEach(weeks) { g in
                            Button { withAnimation(.easeInOut(duration: 0.18)) { openWeek = g.weekStart } } label: {
                                SellerWeekRow(group: g, hide: app.hideAmounts)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
            }
        }
        .environmentObject(app)
        .sheet(item: $selected) { sub in
            SubmissionDetailView(sub: sub).environmentObject(app)
        }
        .task { if !loaded { loaded = true; await app.refreshMine() } }
    }
}

// One buying week of a seller's own submissions (for the Past Submissions week list).
struct SellerWeekGroup: Identifiable {
    let weekStart: Date
    let subs: [Submission]
    var id: Date { weekStart }
    var cards: Int { subs.reduce(0) { $0 + $1.items.count } }
    var subCount: Int { subs.count }
    var acceptedTotal: Double {
        subs.flatMap { $0.items }.filter { $0.item_status == "accepted" }.reduce(0) { $0 + ($1.offer_amount ?? 0) }
    }
}

// A week row in Past Submissions: date range + card/submission count + what the seller got.
struct SellerWeekRow: View {
    let group: SellerWeekGroup; let hide: Bool
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ktsWeekLabel(group.weekStart)).font(.system(size: 15, weight: .bold)).foregroundColor(KTS.txt)
                Text("\(group.cards) card\(group.cards == 1 ? "" : "s") · \(group.subCount) submission\(group.subCount == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundColor(KTS.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ktsMoney(group.acceptedTotal, hide: hide)).font(.system(size: 15, weight: .heavy)).foregroundColor(KTS.accent).monospacedDigit()
                Text("accepted").font(.system(size: 9.5, weight: .semibold)).foregroundColor(KTS.muted)
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(KTS.muted)
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(KTS.panel.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KTS.line.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// Collapsed submission row: "N cards · 2d ago · Approved · You get $X".
struct SubGroupRow: View {
    let sub: Submission; let hide: Bool
    private var acceptedTotal: Double {
        sub.items.filter { $0.item_status == "accepted" }.reduce(0) { $0 + ($1.offer_amount ?? 0) }
    }
    private var approved: Bool { sub.items.contains { $0.item_status == "accepted" } }
    private var statusColor: Color { approved ? KTS.green : KTS.red }
    private var count: Int { sub.items.count }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("\(count) card\(count == 1 ? "" : "s") · \(ktsRelativeTime(sub.created_at))")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(KTS.txt)
                    HStack(spacing: 3) {
                        if approved { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                        Text(approved ? "Approved" : "Rejected").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(statusColor.opacity(0.14)).clipShape(Capsule())
                }
                Text("You get \(ktsMoney(acceptedTotal, hide: hide))")
                    .font(.system(size: 13)).foregroundColor(KTS.muted).monospacedDigit()
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(KTS.muted)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(KTS.panel.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KTS.line.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// One submission expanded: its slabs, with a delete option when fully rejected.
struct SubmissionDetailView: View {
    let sub: Submission
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var err = ""
    @State private var confirmDelete = false

    private var acceptedTotal: Double {
        sub.items.filter { $0.item_status == "accepted" }.reduce(0) { $0 + ($1.offer_amount ?? 0) }
    }
    private var canDelete: Bool { !sub.items.contains { $0.item_status == "accepted" } }

    var body: some View {
        ZStack {
            KTS.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(ktsRelativeTime(sub.created_at).isEmpty ? "Submission" : "Submitted \(ktsRelativeTime(sub.created_at))")
                        .font(.system(size: 17, weight: .bold)).foregroundColor(KTS.txt)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundColor(KTS.muted)
                            .padding(8).background(KTS.panel.opacity(0.6)).clipShape(Circle())
                            .accessibilityLabel("Close")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("YOU GET").font(.system(size: 11, weight: .medium)).foregroundColor(KTS.muted)
                            Text(ktsMoney(acceptedTotal, hide: app.hideAmounts)).font(.system(size: 28, weight: .semibold)).foregroundColor(KTS.accent).monospacedDigit()
                        }
                        .padding(.horizontal, 2).padding(.bottom, 2)
                        Banner(text: err)
                        ForEach(sub.items) { it in
                            SubCardRow(item: it, batch: ktsReviewBucket(it), hide: app.hideAmounts)
                        }
                        if canDelete {
                            Button { confirmDelete = true } label: {
                                Text(busy ? "Deleting…" : "Delete submission").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(KTSDangerButton()).disabled(busy).padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 28)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .confirmationDialog("Delete this rejected submission? This can't be undone.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func delete() {
        Task {
            busy = true; defer { busy = false }
            err = ""
            do {
                try await API.shared.deleteSubmission(id: sub.id)
                await app.refreshMine()
                dismiss()
            } catch { err = (error as? APIError)?.message ?? "Couldn't delete." }
        }
    }
}

// Submission card: title · grade & cert · CL value + payout at %, with a status badge.
struct SubCardRow: View {
    let item: SubItem; let batch: String; let hide: Bool   // batch = review bucket: "approved" | "pending" | "refused"
    private var statusColor: Color { batch == "approved" ? KTS.green : batch == "refused" ? KTS.red : KTS.accent }
    private var label: String { batch == "approved" ? "Approved" : batch == "refused" ? "Refused" : "Pending" }
    private var icon: String { batch == "approved" ? "checkmark" : batch == "refused" ? "xmark" : "clock" }
    private var pct: Int? {
        guard let cl = item.cardladder_value, cl > 0, let off = item.offer_amount else { return nil }
        return Int((off / cl * 100).rounded())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Text(item.card_title.isEmpty ? "Cert \(item.cert)" : item.card_title)
                    .font(.system(size: 15, weight: .bold)).foregroundColor(KTS.txt)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 9, weight: .bold))
                    Text(label).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(statusColor)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(statusColor.opacity(0.14)).clipShape(Capsule())
                .fixedSize()
            }
            Text("\(item.grader) \(item.grade) · Cert \(item.cert)")
                .font(.system(size: 13)).foregroundColor(KTS.muted)
            HStack(spacing: 5) {
                Text(ktsMoney(item.cardladder_value, hide: hide))
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.txt).monospacedDigit()
                Text("CL value").font(.system(size: 13)).foregroundColor(KTS.muted)
                if batch == "approved" {
                    Text("·").font(.system(size: 13)).foregroundColor(KTS.muted)
                    Text(ktsMoney(item.offer_amount, hide: hide))
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.accent).monospacedDigit()
                    if let p = pct { Text("at \(p)%").font(.system(size: 13)).foregroundColor(KTS.muted) }
                } else if batch == "pending" {
                    Text("·").font(.system(size: 13)).foregroundColor(KTS.muted)
                    Text(ktsMoney(item.offer_amount, hide: hide))
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.accent).monospacedDigit()
                    Text("· awaiting approval").font(.system(size: 13)).foregroundColor(KTS.muted)
                } else {   // refused
                    Text("·").font(.system(size: 13)).foregroundColor(KTS.muted)
                    Text("Not purchased").font(.system(size: 13)).foregroundColor(KTS.muted)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KTS.panel.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KTS.line.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// "Ship your cards" — ship-to address + this week's tracking entry + delivery status.
// Shown on Review Cards once the seller has approved cards this week (what they ship). Mirrors
// the web renderShipCard against GET /shipping + POST /shipping/tracking.
struct ShipCardView: View {
    @State private var address = ""
    @State private var shipment: Shipment?
    @State private var loaded = false
    @State private var loadedOK = false
    @State private var tracking = ""
    @State private var editing = false
    @State private var busy = false
    @State private var err = ""

    private var delivered: Bool { (shipment?.status ?? "").lowercased() == "delivered" }
    private var hasTracking: Bool { !((shipment?.tracking ?? "").isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ship your cards").font(.system(size: 16, weight: .bold)).foregroundColor(KTS.txt)
            Text("Mail this week's approved cards to the address below, then add your tracking number.")
                .font(.system(size: 12)).foregroundColor(KTS.muted).fixedSize(horizontal: false, vertical: true)

            if !loadedOK {
                ProgressView().tint(KTS.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                if address.isEmpty {
                    Text("Shipping address coming soon — check back here or ask KTS.")
                        .font(.system(size: 13)).foregroundColor(KTS.muted)
                } else {
                    Text(address).font(.system(size: 14)).foregroundColor(KTS.txt)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(KTS.panel2)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KTS.line.opacity(0.6)))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if delivered {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(KTS.green)
                        Text("Delivered").font(.system(size: 15, weight: .heavy)).foregroundColor(KTS.green)
                        if let d = shipment?.delivered_at, let date = ktsParseDate(d) {
                            Text("· \(ktsShortDate(date))").font(.system(size: 13)).foregroundColor(KTS.muted)
                        }
                    }.padding(.top, 2)
                    if let t = shipment?.tracking, !t.isEmpty {
                        Text("Tracking \(t)").font(.system(size: 12)).foregroundColor(KTS.muted)
                    }
                } else if hasTracking && !editing {
                    HStack(spacing: 5) {
                        Text("Tracking").font(.system(size: 14)).foregroundColor(KTS.txt)
                        Text(shipment?.tracking ?? "").font(.system(size: 14, weight: .bold)).foregroundColor(KTS.txt)
                        Text("· in transit").font(.system(size: 13)).foregroundColor(KTS.muted)
                    }.padding(.top, 2)
                    Button("Change tracking number") { tracking = shipment?.tracking ?? ""; editing = true }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(KTS.accent)
                } else {
                    Banner(text: err)
                    HStack(spacing: 8) {
                        TextField("Tracking number", text: $tracking)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .foregroundColor(KTS.txt)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .background(KTS.panel2)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(KTS.line))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button(busy ? "…" : "Save") { Task { await save() } }
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.black)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(KTS.accent).clipShape(RoundedRectangle(cornerRadius: 10))
                            .disabled(busy || tracking.trimmingCharacters(in: .whitespaces).isEmpty)
                            .opacity(tracking.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                    }
                    Text("Paste your tracking number once you ship — we'll confirm when it arrives.")
                        .font(.system(size: 11)).foregroundColor(KTS.muted)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(KTS.panel.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KTS.accent.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task { if !loaded { loaded = true; await load() } }
    }

    private func load() async {
        do {
            let r = try await API.shared.shipping()
            address = (r.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            shipment = r.shipment
        } catch { }
        loadedOK = true
    }
    private func save() async {
        let code = tracking.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        busy = true; defer { busy = false }
        err = ""
        do {
            let r = try await API.shared.submitTracking(code)
            shipment = r.shipment
            editing = false
        } catch { err = (error as? APIError)?.message ?? "Couldn't save that tracking number." }
    }
}

struct RatesView: View {
    @EnvironmentObject var app: AppState
    @State private var rates: RatesResponse?
    @State private var loaded = false
    @State private var err = ""

    var body: some View {
        SubScreen(title: "Rates") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What KTS is buying this week, as a % of CardLadder market value.")
                        .font(.system(size: 13)).foregroundColor(KTS.muted).padding(.top, 2)
                    if let r = rates, ktsIsFuture(r.mainOpensAt) || ktsIsFuture(r.pokemonOpensAt) {
                        WindowOpenNotes(mainOpensAt: r.mainOpensAt, pokemonOpensAt: r.pokemonOpensAt)
                    }
                    if let r = rates {
                        if let lane = r.pokemonLane { PokemonLaneCard(lane: lane) }   // its own section, shown even if no normal tracks
                        ForEach(r.categories) { cat in RateCategoryCard(cat: cat, hide: app.hideAmounts) }
                    } else if !err.isEmpty {
                        VStack(spacing: 10) {
                            Banner(text: err)
                            Button { Task { await load() } } label: { Text("Retry").frame(maxWidth: .infinity) }
                                .buttonStyle(KTSGhostButton())
                        }.padding(.top, 8)
                    } else {
                        ProgressView().tint(KTS.accent).frame(maxWidth: .infinity).padding(30)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
            }
        }
        .environmentObject(app)
        .task { if !loaded { loaded = true; await load() } }
    }
    private func load() async {
        err = ""
        do { rates = try await API.shared.rates() }
        catch { err = (error as? APIError)?.message ?? "Couldn't load rates." }
    }
}

// Pokémon unlimited lane — its OWN green section on the Rates screen, mirroring the web
// Rates page. Money is null-safe so an open-ended bound reads cleanly, and
// the card renders whenever the lane is on, even in a week with no normal tracks posted.
struct PokemonLaneCard: View {
    let lane: PokemonLane
    private func money(_ n: Double?) -> String? {
        guard let n = n, n.isFinite else { return nil }
        return "$" + String(Int(n.rounded()))
    }
    private var range: String {
        let a = money(lane.minValue), b = money(lane.maxValue)
        if let a = a, let b = b { return a + "–" + b }
        if let a = a { return a + "+" }
        if let b = b { return "up to " + b }
        return "any value"
    }
    var body: some View {
        let grades = (lane.grades ?? [9, 10]).map(String.init).joined(separator: " & ")
        let gate = ["PSA " + grades, range, "CL \(Int(lane.minConf ?? 4))+",
                    "\(Int(lane.minYear ?? 2016))–present", "English only"].joined(separator: "  ·  ")
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Pokémon — Unlimited")
                    .font(.system(size: 15, weight: .heavy)).foregroundColor(KTS.txt)
                Spacer(minLength: 4)
                Text("UNLIMITED")
                    .font(.system(size: 10, weight: .heavy)).foregroundColor(Color(hex: 0x0C1B14))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(KTS.green).clipShape(Capsule())
            }
            Text("\(Int(lane.rate ?? 87))% on any card that matches — bought on the spot, no cap.")
                .font(.system(size: 13)).foregroundColor(KTS.txt)
                .fixedSize(horizontal: false, vertical: true)
            Text(gate)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(KTS.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let mc = lane.maxCopies {
                Text("Up to \(Int(mc)) copies of each card.")
                    .font(.system(size: 11)).foregroundColor(KTS.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(KTS.green.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KTS.green.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}


// Headline stat tile used on the Home hero (value + label + optional sub, colored accent bar).
struct KTSStatTile: View {
    let value: String; let label: String; let extra: String; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .heavy)).foregroundColor(color)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(KTS.muted)
                .padding(.top, 9).lineLimit(1).minimumScaleFactor(0.7)
            if !extra.isEmpty {
                Text(extra).font(.system(size: 11)).foregroundColor(KTS.muted).padding(.top, 2).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13).padding(.leading, 14).padding(.trailing, 11)
        .background(KTS.panel2.opacity(0.7))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KTS.line.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// A muted requirement chip on the Rates page, e.g. "PSA 7+" (grade) or "CL 3+" (confidence).
struct ReqPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).foregroundColor(KTS.muted)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(KTS.panel2.opacity(0.85))
            .overlay(Capsule().stroke(KTS.line.opacity(0.55)))
            .clipShape(Capsule())
            .fixedSize()
    }
}
// Whole grade ("7") vs half grade ("9.5").
func ktsGradeStr(_ g: Double) -> String { g == g.rounded() ? String(Int(g)) : String(format: "%g", g) }

struct RateCategoryCard: View {
    let cat: RateCategory
    let hide: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cat.label).font(.system(size: 15, weight: .semibold)).foregroundColor(KTS.txt)
            ForEach(cat.graders) { g in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Text(g.grader.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundColor(KTS.muted)
                        if let mg = g.minGrade { ReqPill(text: "\(g.grader) \(ktsGradeStr(mg))+") }
                        if let mcd = g.minCert { ReqPill(text: "cert \(Int((mcd / 1_000_000).rounded()))M+") }
                        Spacer(minLength: 0)
                    }
                    ForEach(g.tiers) { t in
                        HStack(spacing: 6) {
                            Text(rangeText(t)).font(.system(size: 14)).foregroundColor(KTS.txt).lineLimit(1)
                            Spacer(minLength: 6)
                            if let mg = t.minGrade { ReqPill(text: "\(g.grader) \(ktsGradeStr(mg))+") }
                            if let mc = t.minConf { ReqPill(text: "CL \(Int(mc))+") }
                            Text("\(Int(t.rate))%").font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.accent).monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(KTS.panel2.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .background(KTS.panel.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KTS.line.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func rangeText(_ t: RateTier) -> String {
        if hide { return "$•••" }
        if let lo = t.min, let hi = t.max { return "$\(Int(lo))–$\(Int(hi))" }
        if let lo = t.min { return "$\(Int(lo))+" }
        if let hi = t.max { return "up to $\(Int(hi))" }
        return "Any value"
    }
}

