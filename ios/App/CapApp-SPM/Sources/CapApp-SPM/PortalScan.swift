import SwiftUI
import AVFoundation
import UIKit

// MARK: - Scan model (native AVFoundation scanner + running batch)

struct SubmitDone { let id: Int; let buys: Int; var queued: Bool = false; var queueOpensAt: String? = nil; var laneAccepted: Int = 0 }

// A cert whose pricing failed (usually flaky show wifi). Kept as a retry row in the batch
// instead of being silently dropped — mirrors the web scanner's "tap to try again" card.
struct ScanError: Identifiable, Equatable { let cert: String; let message: String; var id: String { cert } }

@MainActor
public final class ScanModel: NSObject, ObservableObject {
    @Published var results: [SellerView] = [] { didSet { persistBatch() } }   // priced, newest first
    @Published var pendingCerts: Set<String> = []
    @Published var latest: SellerView?
    @Published var submitting = false
    @Published var toast: String?
    @Published var submitDone: SubmitDone?    // durable success confirmation
    @Published var submitError: String?       // persistent submit failure
    @Published var selected: Set<String> = [] { didSet { persistBatch() } }   // checked certs (takeable auto-checked on price)
    @Published var cameraDenied = false   // camera access denied/restricted — show guidance instead of a black preview
    @Published var cameraOn = true        // seller can turn the camera off and just paste certs
    @Published var cameraFront = false    // false = back camera (default), true = front/selfie
    @Published var hardwareScanner = false  // ON = capture a Bluetooth/USB barcode scanner's keystrokes into the batch
    @Published var windowLockMsg: String?    // set when a submit is blocked (409) before a gated window opens
    var acceptingScans = true   // gated off while the resume prompt is showing
    @Published var errored: [ScanError] = []   // certs whose pricing failed — kept as retry rows, never silently dropped

    private var seen = Set<String>()
    // AVFoundation objects live OUTSIDE the main actor: all camera config runs on sessionQueue, so
    // these are nonisolated (videoDevice is only ever touched on that queue). This is what lets the
    // session-config methods below be nonisolated and callable from sessionQueue.async without an
    // actor-isolation violation (which the Release/whole-module build enforces).
    private nonisolated let session = AVCaptureSession()
    private nonisolated let metaOutput = AVCaptureMetadataOutput()
    private nonisolated(unsafe) var videoDevice: AVCaptureDevice?     // active capture device (touched only on sessionQueue)
    private nonisolated let sessionQueue = DispatchQueue(label: "com.ktscollectibles.scan")
    private var lastEmit: [String: TimeInterval] = [:]
    nonisolated var captureSession: AVCaptureSession { session }

    var scannedCount: Int { seen.count }
    var hasContent: Bool { !results.isEmpty || !errored.isEmpty }
    var buyCount: Int { results.filter { $0.isBuy }.count }
    var selectedCount: Int { selected.count }
    var buyCerts: [String] { results.filter { $0.isBuy }.map { $0.cert } }
    var allBuySelected: Bool { let b = Set(buyCerts); return !b.isEmpty && b.isSubset(of: selected) }
    func isSelected(_ cert: String) -> Bool { selected.contains(cert) }
    // Totals follow the current selection, so untaken/unchecked cards never inflate them.
    var marketTotal: Double { results.filter { selected.contains($0.cert) }.reduce(0) { $0 + (ktsShownValue($1) ?? 0) } }
    var payoutTotal: Double { results.filter { selected.contains($0.cert) && $0.isBuy }.reduce(0) { $0 + ($1.offer ?? 0) } }

    private let batchKey: String
    init(owner: String) {
        batchKey = Self.draftKey(owner)
        UserDefaults.standard.removeObject(forKey: "kts_scan_batch_v1")
        super.init()
    }

    func start() {
        #if !targetEnvironment(simulator)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraDenied = false
            sessionQueue.async { [weak self] in self?.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.cameraDenied = !granted
                    if granted { self.sessionQueue.async { [weak self] in self?.configureAndRun() } }
                }
            }
        default:
            cameraDenied = true   // .denied / .restricted
        }
        #endif
    }
    func stop() {
        #if !targetEnvironment(simulator)
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
        #endif
    }

    private nonisolated func configureAndRun() {
        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                session.commitConfiguration(); return
            }
            session.addInput(input)
            videoDevice = device
            if session.canAddOutput(metaOutput) {
                session.addOutput(metaOutput)
                metaOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                let want: [AVMetadataObject.ObjectType] = [.qr, .code128, .code39, .code93, .ean13, .ean8, .interleaved2of5, .itf14, .dataMatrix, .pdf417, .aztec, .upce]
                metaOutput.metadataObjectTypes = want.filter { metaOutput.availableMetadataObjectTypes.contains($0) }
            }
            session.commitConfiguration()
            tuneDevice(device)
        }
        if !session.isRunning { session.startRunning() }
    }

    // Tune the active camera for reading a small, glossy cert barcode up close: restrict
    // autofocus to near range, keep continuous AF, and nudge a modest optical/sensor zoom so
    // more pixels land on the barcode. Everything is capability-guarded so an unsupported
    // device simply keeps stock behavior.
    private nonisolated func tuneDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            let z = min(1.5, device.maxAvailableVideoZoomFactor)
            if z > 1 { device.videoZoomFactor = z }
            device.unlockForConfiguration()
        } catch { /* keep stock settings if the device won't lock */ }
    }

    // Restrict barcode detection to the aimed box (normalized metadata-output coords, already
    // converted from the preview layer) so a neighboring slab's barcode on a crowded table
    // doesn't get grabbed. A degenerate rect is ignored, leaving the full-frame default.
    nonisolated func applyROI(_ rect: CGRect) {
        let x = Swift.min(Swift.max(rect.minX, 0), 1), y = Swift.min(Swift.max(rect.minY, 0), 1)
        let w = Swift.min(Swift.max(rect.width, 0), 1), h = Swift.min(Swift.max(rect.height, 0), 1)
        guard w > 0.05, h > 0.05 else { return }
        metaOutput.rectOfInterest = CGRect(x: x, y: y, width: w, height: h)
    }

    // Tap-to-focus from the preview (point is in device coords 0…1). Guarded per capability.
    nonisolated func focusTap(at point: CGPoint) {
        guard let device = videoDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    // Flip between the back and front camera, reconfiguring the running session.
    func flipCamera() {
        cameraFront.toggle()
        let position: AVCaptureDevice.Position = cameraFront ? .front : .back
        #if !targetEnvironment(simulator)
        sessionQueue.async { [weak self] in self?.reconfigureInput(position: position) }
        #endif
    }
    private nonisolated func reconfigureInput(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            videoDevice = device
        }
        session.commitConfiguration()
        if let d = videoDevice { tuneDevice(d) }   // re-apply focus/zoom to the new camera
    }

    // Turn the live camera fully on/off (stops the capture session when off).
    func setCameraOn(_ on: Bool) {
        cameraOn = on
        if on { start() } else { stop() }
    }

    // Pull a 7–13 digit cert out of whatever the barcode/QR carries.
    private func extractCert(_ raw: String) -> String? {
        let runs = raw.matches(ofPattern: "[0-9]{7,13}")
        if let best = runs.max(by: { $0.count < $1.count }) { return best }
        let digits = raw.filter(\.isNumber)
        return (7...13).contains(digits.count) ? digits : nil
    }

    func capture(_ raw: String) {
        guard acceptingScans, let cert = extractCert(raw), !seen.contains(cert) else { return }
        seen.insert(cert)
        pendingCerts.insert(cert)
        Haptics.tap()
        Task { await price(cert) }
    }

    // Pull EVERY cert out of a pasted blob — numeric runs 7–13 long (matches the web
    // app's algorithm), deduped, order preserved, capped so a huge paste can't run away.
    private func extractCerts(_ text: String) -> [String] {
        var out: [String] = []
        var seenHere = Set<String>()
        for run in text.components(separatedBy: CharacterSet.decimalDigits.inverted) {
            guard run.count >= 7, run.count <= 13, !seenHere.contains(run) else { continue }
            seenHere.insert(run); out.append(run)
            if out.count >= 300 { break }
        }
        return out
    }

    // Manual entry: accepts a single cert OR a big pasted list — prices them all.
    func manual(_ text: String) {
        let certs = extractCerts(text).filter { !seen.contains($0) }
        guard !certs.isEmpty else { toast = "That doesn't look like a cert number."; return }
        for c in certs { seen.insert(c); pendingCerts.insert(c) }
        if certs.count > 1 { toast = "Pricing \(certs.count) cards…" }
        Task {
            let maxConcurrent = 6
            var next = 0
            await withTaskGroup(of: Void.self) { group in
                func start() {
                    guard next < certs.count else { return }
                    let c = certs[next]; next += 1
                    group.addTask { await self.price(c) }
                }
                for _ in 0..<min(maxConcurrent, certs.count) { start() }
                while await group.next() != nil { start() }
            }
        }
    }

    private func price(_ cert: String) async {
        do {
            let v = try await API.shared.price(cert: cert)
            pendingCerts.remove(cert)
            errored.removeAll { $0.cert == cert }   // clear any prior failure for this cert
            results.removeAll { $0.cert == v.cert }
            results.insert(v, at: 0)
            if v.isBuy { selected.insert(v.cert) }   // auto-check takeable cards
            latest = v
        } catch {
            // Don't silently drop it (flaky show wifi) — keep a visible retry row. The cert stays
            // in `seen` so a repeat scan doesn't pile up; the retry row re-prices it on demand.
            pendingCerts.remove(cert)
            let msg = (error as? APIError)?.message ?? "Couldn't price that one — tap to try again."
            errored.removeAll { $0.cert == cert }
            errored.insert(ScanError(cert: cert, message: msg), at: 0)
        }
    }

    // Re-price a cert that failed (from its retry row).
    func retryError(_ cert: String) {
        errored.removeAll { $0.cert == cert }
        pendingCerts.insert(cert)
        Task { await price(cert) }
    }
    // Drop a failed cert for good (and free it so it can be scanned fresh).
    func dismissError(_ cert: String) {
        errored.removeAll { $0.cert == cert }
        seen.remove(cert)
    }
    // Re-price everything that failed (e.g. once wifi comes back).
    func retryAllErrors() {
        let certs = errored.map { $0.cert }
        guard !certs.isEmpty else { return }
        errored.removeAll()
        for c in certs { pendingCerts.insert(c) }
        Task { for c in certs { await price(c) } }
    }

    func remove(_ cert: String) {
        results.removeAll { $0.cert == cert }
        errored.removeAll { $0.cert == cert }
        seen.remove(cert); pendingCerts.remove(cert); selected.remove(cert)
        if latest?.cert == cert { latest = results.first }
    }
    func toggleSelect(_ cert: String) {
        if selected.contains(cert) { selected.remove(cert) } else { selected.insert(cert) }
    }
    func selectAllToggle() {
        let b = Set(buyCerts)
        if !b.isEmpty, b.isSubset(of: selected) { selected.subtract(b) } else { selected.formUnion(b) }
    }
    func removeSelected() {
        let kill = selected
        results.removeAll { kill.contains($0.cert) }
        for c in kill { seen.remove(c); pendingCerts.remove(c) }
        selected.removeAll()
        if let l = latest, kill.contains(l.cert) { latest = results.first }
    }

    func submit() async {
        let certs = Array(selected)
        guard !certs.isEmpty else { return }
        submitting = true; defer { submitting = false }
        submitError = nil; windowLockMsg = nil
        do {
            let r = try await API.shared.submit(certs: certs)
            let sent = Set(certs)
            results.removeAll { sent.contains($0.cert) }   // keep any unselected cards in the batch
            for c in sent { seen.remove(c); pendingCerts.remove(c) }
            selected.subtract(sent)   // deselect only what we sent; keep cards scanned mid-submit
            if let l = latest, sent.contains(l.cert) { latest = results.first }
            submitDone = SubmitDone(id: r.submission_id, buys: r.counts.buy, queued: r.queued ?? false, queueOpensAt: r.queueOpensAt, laneAccepted: r.laneAccepted ?? 0)   // durable confirmation
        } catch {
            if let e = error as? APIError, e.isWindowLocked {
                // Expected: the batch has cards for a window that hasn't opened (One Piece/sports,
                // or Pokémon). Nothing was stored server-side; keep the batch so they can submit
                // when it opens, or deselect those cards and submit the rest (e.g. CGC) now.
                windowLockMsg = ktsLockMessage(e)   // built client-side so the time reads in ET
            } else {
                submitError = (error as? APIError)?.message ?? "Submit failed — please try again."
            }
        }
    }

    // MARK: - Save / resume the in-progress batch locally (survives leaving the screen or quitting the app)
    static func draftKey(_ owner: String) -> String { "kts_scan_batch_v2:" + owner.lowercased() }
    private struct SavedBatch: Codable { let results: [SellerView]; let selected: [String] }
    func persistBatch() {
        let s = SavedBatch(results: results, selected: Array(selected))
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: batchKey) }
    }
    var savedBatchCount: Int {
        guard let d = UserDefaults.standard.data(forKey: batchKey),
              let s = try? JSONDecoder().decode(SavedBatch.self, from: d) else { return 0 }
        return s.results.count
    }
    func loadSavedBatch() {
        guard let d = UserDefaults.standard.data(forKey: batchKey),
              let s = try? JSONDecoder().decode(SavedBatch.self, from: d) else { return }
        results = s.results
        selected = Set(s.selected)
        seen = Set(s.results.map { $0.cert })
        latest = results.first
    }
    func clearSavedBatch() { UserDefaults.standard.removeObject(forKey: batchKey) }
}

extension ScanModel: AVCaptureMetadataOutputObjectsDelegate {
    public nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        var hit: String?
        for o in objects {
            if let c = o as? AVMetadataMachineReadableCodeObject, let s = c.stringValue, !s.isEmpty { hit = s; break }
        }
        if let s = hit { Task { @MainActor in self.capture(s) } }
    }
}

enum Haptics { static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }

extension String {
    func matches(ofPattern pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}

// MARK: - Camera preview (full-bleed). Dark placeholder on the Simulator.

struct CameraPreview: UIViewRepresentable {
    let model: ScanModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = UIColor(KTS.bg)
        v.model = model
        #if !targetEnvironment(simulator)
        v.videoPreviewLayer.session = model.captureSession
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        context.coordinator.view = v
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap(_:)))
        v.addGestureRecognizer(tap)
        #endif
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class Coordinator: NSObject {
        let model: ScanModel
        weak var view: PreviewView?
        init(model: ScanModel) { self.model = model }
        @objc func onTap(_ g: UITapGestureRecognizer) {
            #if !targetEnvironment(simulator)
            guard let v = view else { return }
            let p = g.location(in: v)
            let dev = v.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: p)
            let m = model
            Task { @MainActor in m.focusTap(at: dev) }
            #endif
        }
    }

    final class PreviewView: UIView {
        weak var model: ScanModel?
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        // Keep the metadata region-of-interest pinned to the on-screen aim box (matches AimFrame:
        // ~0.78×0.62 of the shorter side, centered a little above middle). Recomputed on layout +
        // rotation. Done via metadataOutputRectConverted so the orientation math stays correct.
        override func layoutSubviews() {
            super.layoutSubviews()
            #if !targetEnvironment(simulator)
            guard bounds.width > 0, bounds.height > 0, videoPreviewLayer.session != nil else { return }
            let W = bounds.width, H = bounds.height
            let w = min(W * 0.78, 320), h = w * 0.62
            let aim = CGRect(x: (W - w) / 2, y: H * 0.42 - h / 2, width: w, height: h)
            let roi = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: aim)
            let m = model
            Task { @MainActor in m?.applyROI(roi) }
            #endif
        }
    }
}

// MARK: - Scan screen

// Shown over the (black) camera preview when access is denied/restricted.
struct CameraDeniedOverlay: View {
    let onBack: () -> Void
    var body: some View {
        ZStack {
            KTS.bg.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "camera.fill").font(.system(size: 34)).foregroundColor(KTS.muted)
                Text("Camera access needed").font(.system(size: 20, weight: .bold)).foregroundColor(KTS.txt)
                Text("Scanning reads a slab's barcode with your camera. Turn on camera access for KTS Portal in Settings.")
                    .font(.system(size: 14)).foregroundColor(KTS.muted).multilineTextAlignment(.center).padding(.horizontal, 32)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: { Text("Open Settings").frame(maxWidth: .infinity) }
                .buttonStyle(KTSPrimaryButton()).padding(.horizontal, 48).padding(.top, 6)
                Button(action: onBack) { Text("Back to Home").frame(maxWidth: .infinity) }
                    .buttonStyle(KTSGhostButton()).padding(.horizontal, 48)
            }
        }
    }
}

// Durable "Submitted!" confirmation over the scan screen, with onward navigation
// (replaces the old 2.2s toast that left the seller staring at an empty scanner).
struct SubmitDoneOverlay: View {
    let done: SubmitDone
    let onView: () -> Void
    let onMore: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 46)).foregroundColor(KTS.green)
                Text("Submitted to KTS").font(.system(size: 22, weight: .heavy)).foregroundColor(KTS.txt)
                Text("Batch #\(done.id) · \(done.buys) card\(done.buys == 1 ? "" : "s") sent for review.")
                    .font(.system(size: 14)).foregroundColor(KTS.muted).multilineTextAlignment(.center)
                if done.queued {
                    Text("⏳ Queued — your Pokémon list locks when I submit at \(ktsWindowLabel(done.queueOpensAt, tz: "America/New_York", abbr: "ET")). Prices are estimates until then.")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(Color(hex: 0xE8A54B))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if done.laneAccepted > 0 {
                    Text("⚡ \(done.laneAccepted) bought on the spot — Pokémon unlimited.")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(KTS.green)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    Button(action: onView) { Text("View submission").frame(maxWidth: .infinity) }.buttonStyle(KTSPrimaryButton())
                    Button(action: onMore) { Text("Scan more").frame(maxWidth: .infinity) }.buttonStyle(KTSGhostButton())
                }.padding(.top, 4)
            }
            .padding(26)
            .background(KTS.panel)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(KTS.line.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 36)
        }
    }
}

struct ScanView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var scan: ScanModel
    init(owner: String) {
        _scan = StateObject(wrappedValue: ScanModel(owner: owner))
    }
    @State private var showManual = false
    @State private var manualText = ""
    @State private var showCalc = false
    @State private var listExpanded = false
    @State private var sweep = false
    @State private var showResume = false
    @State private var resumeDecided = false

    // The submit-block message sits just under the top bar only after a too-early submit.
    private var windowBannerShowing: Bool { scan.windowLockMsg != nil }

    var body: some View {
        ZStack {
            CameraPreview(model: scan).ignoresSafeArea()
            if scan.cameraOn {
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
                // Aim frame
                AimFrame(sweep: sweep).allowsHitTesting(false)
            } else {
                KTS.bg.ignoresSafeArea()
                cameraOffPrompt
            }

            VStack(spacing: 0) {
                topBar
                if let lock = scan.windowLockMsg {
                    WindowBlockBanner(message: lock, onDismiss: { withAnimation { scan.windowLockMsg = nil } })
                        .padding(.horizontal, 14).padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !listExpanded {
                    cameraControls
                    Spacer()
                    if let e = scan.submitError {
                        Button { withAnimation { scan.submitError = nil } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                                Text(e).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.white).padding(.horizontal, 14).padding(.vertical, 10)
                            .background(KTS.red.opacity(0.92)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .padding(.horizontal, 14).padding(.bottom, 8)
                    }
                    if !scan.errored.isEmpty {
                        ScanErrorBanner(count: scan.errored.count,
                                        onRetryAll: { scan.retryAllErrors() },
                                        onReview: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { listExpanded = true } })
                            .padding(.horizontal, 14).padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let r = scan.latest { OfferCard(r: r, hide: app.hideAmounts).padding(.horizontal, 14).padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                SummarySheet(scan: scan, hide: app.hideAmounts, expanded: $listExpanded,
                             onSubmit: { Task { await scan.submit() } },
                             onManual: { showManual = true })
            }
            .onChange(of: scan.hasContent) { has in if !has { listExpanded = false } }
            .animation(.easeInOut(duration: 0.25), value: scan.windowLockMsg)

            // Invisible capture field for a hardware barcode scanner — holds focus while ON so
            // the scanner's "typed" cert + Return lands here (inputView is empty → no keyboard).
            // Paused while a sheet is up so it doesn't fight the manual editor for focus.
            HardwareScannerField(
                active: Binding(get: { scan.hardwareScanner && !showManual && !showCalc },
                                set: { scan.hardwareScanner = $0 })
            ) { cert in scan.manual(cert) }
                .frame(width: 1, height: 1).opacity(0.02).allowsHitTesting(false)

            if showResume {
                ResumePromptOverlay(count: scan.savedBatchCount,
                    onContinue: { scan.loadSavedBatch(); scan.acceptingScans = true; resumeDecided = true; withAnimation { showResume = false } },
                    onNew: { scan.clearSavedBatch(); scan.acceptingScans = true; resumeDecided = true; withAnimation { showResume = false } })
                    .transition(.opacity)
            }

            if scan.cameraDenied { CameraDeniedOverlay(onBack: { app.screen = .home }) }

            if let done = scan.submitDone {
                SubmitDoneOverlay(done: done,
                    onView: { scan.submitDone = nil; app.screen = .reviewCards },
                    onMore: { withAnimation { scan.submitDone = nil } })
                    .transition(.opacity)
                    .task { await app.refreshMine() }
            }
        }
        .background(KTS.bg.ignoresSafeArea())
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // don't let the phone sleep between slabs
            scan.start()
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { sweep = true }
            if !resumeDecided && scan.savedBatchCount > 0 {
                scan.acceptingScans = false
                withAnimation { showResume = true }
            } else {
                resumeDecided = true
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; scan.stop() }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scan.latest?.cert)
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showManual) { manualSheet }
        .sheet(isPresented: $showCalc) { CalcSheet() }
    }

    private var topBar: some View {
        HStack {
            circleButton("chevron.left") { app.screen = .home }
                .accessibilityLabel("Back to Home")
            Spacer()
            Text("Scan").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            circleButton(app.hideAmounts ? "eye.slash" : "eye") { app.setHide(!app.hideAmounts) }
                .accessibilityLabel(app.hideAmounts ? "Show dollar amounts" : "Hide dollar amounts")
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func circleButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
    }

    // Toggle hardware-scanner capture. When ON (gold), a hidden field catches a Bluetooth/USB
    // barcode scanner's keystrokes and each scanned cert is priced + added to the batch.
    private var scannerToggle: some View {
        Button {
            scan.hardwareScanner.toggle()
            scan.toast = scan.hardwareScanner ? "Hardware scanner on — scan your slabs" : "Hardware scanner off"
        } label: {
            Image(systemName: "barcode.viewfinder").font(.system(size: 16, weight: .semibold))
                .foregroundColor(scan.hardwareScanner ? .black : .white)
                .frame(width: 44, height: 44)
                .background {
                    if scan.hardwareScanner { Circle().fill(KTS.accent) }
                    else { Circle().fill(.ultraThinMaterial) }
                }
        }
        .accessibilityLabel(scan.hardwareScanner ? "Turn hardware scanner off" : "Use a hardware barcode scanner")
    }

    // Right-aligned camera controls: turn the camera off/on, and (when on) flip front/back.
    private var cameraControls: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                scannerToggle
                circleButton("plus.forwardslash.minus") { showCalc = true }
                    .accessibilityLabel("Calculator")
                circleButton(scan.cameraOn ? "video.fill" : "video.slash.fill") { withAnimation { scan.setCameraOn(!scan.cameraOn) } }
                    .accessibilityLabel(scan.cameraOn ? "Turn camera off" : "Turn camera on")
                if scan.cameraOn {
                    circleButton("arrow.triangle.2.circlepath") { scan.flipCamera() }
                        .accessibilityLabel("Flip camera")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    // Shown in place of the live preview when the camera is off — paste instead of scan.
    private var cameraOffPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill").font(.system(size: 38)).foregroundColor(KTS.muted)
            Text("Camera off").font(.system(size: 18, weight: .bold)).foregroundColor(KTS.txt)
            Text("Paste a list of cert numbers to price them,\nor turn the camera back on to scan.")
                .font(.system(size: 13)).foregroundColor(KTS.muted).multilineTextAlignment(.center)
            Button { showManual = true } label: {
                HStack(spacing: 6) { Image(systemName: "doc.on.clipboard"); Text("Paste cert numbers") }.frame(maxWidth: 260)
            }
            .buttonStyle(KTSPrimaryButton()).padding(.top, 4)
        }
        .padding(24).padding(.bottom, 130)
    }

    @ViewBuilder private var toastView: some View {
        if let t = scan.toast {
            Text(t).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, windowBannerShowing ? 120 : 70)   // clear the submit-block banner when showing
                .transition(.move(edge: .top).combined(with: .opacity))
                .task { try? await Task.sleep(nanoseconds: 2_200_000_000); scan.toast = nil }
        }
    }

    private var manualSheet: some View {
        VStack(spacing: 14) {
            Text("Enter cert numbers").font(.system(size: 17, weight: .bold)).foregroundColor(KTS.txt).padding(.top, 24)
            Text("Type one, or paste a whole list — we'll price them all.")
                .font(.system(size: 12)).foregroundColor(KTS.muted).multilineTextAlignment(.center)
            ZStack(alignment: .topLeading) {
                if manualText.isEmpty {
                    Text("Cert #s")
                        .font(.system(size: 15)).foregroundColor(KTS.muted.opacity(0.7))
                        .padding(.horizontal, 10).padding(.vertical, 12)
                }
                ManualCertEditor(text: $manualText).frame(height: 150).padding(4)
            }
            .background(KTS.panel.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(KTS.line.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Button("Price it") { scan.manual(manualText); manualText = ""; showManual = false }
                .buttonStyle(KTSPrimaryButton())
            Button("Cancel") { showManual = false }.buttonStyle(KTSGhostButton())
            Spacer()
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(KTS.bg.ignoresSafeArea())
    }
}

// Multi-line cert input that reads as transparent on the KTS dark theme.
// Cert entry = a NUMBER PAD (digits only, like CardLadder). SwiftUI's TextEditor ignores
// .keyboardType, so we bridge a UITextView whose keyboardType is .numberPad. Multi-line +
// paste still work (paste ignores keyboard type); extractCerts() splits a pasted list.
struct ManualCertEditor: UIViewRepresentable {
    @Binding var text: String
    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.keyboardType = .numberPad
        tv.font = .systemFont(ofSize: 15)
        tv.backgroundColor = .clear
        tv.textColor = UIColor(KTS.txt)
        tv.tintColor = UIColor(KTS.accent)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.delegate = context.coordinator
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: ManualCertEditor
        init(_ parent: ManualCertEditor) { self.parent = parent }
        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text }
    }
}

// Hidden capture field for a HARDWARE barcode scanner (Bluetooth or USB — it presents as a
// keyboard and "types" the cert then a Return). `inputView` is an empty view so the on-screen
// keyboard never appears, and the field holds first-responder while `active`. Each completed
// scan (a line, ended by the scanner's Return/CR) is handed to `onScan`, which prices it in.
struct HardwareScannerField: UIViewRepresentable {
    @Binding var active: Bool
    let onScan: (String) -> Void
    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.inputView = UIView()            // suppress the on-screen keyboard entirely
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.keyboardType = .numberPad
        tf.delegate = context.coordinator
        return tf
    }
    func updateUIView(_ tf: UITextField, context: Context) {
        context.coordinator.onScan = onScan
        DispatchQueue.main.async {
            if active, !tf.isFirstResponder { tf.becomeFirstResponder() }
            else if !active, tf.isFirstResponder { tf.resignFirstResponder() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func textField(_ tf: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.contains("\n") || string.contains("\r") { flush(tf); return false }   // end-of-scan
            return true
        }
        func textFieldShouldReturn(_ tf: UITextField) -> Bool { flush(tf); return false }
        private func flush(_ tf: UITextField) {
            let text = (tf.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            tf.text = ""
            if !text.isEmpty { onScan(text) }
        }
    }
}

// Resume-or-start-new prompt, shown over the camera when a saved scan batch exists.
struct ResumePromptOverlay: View {
    let count: Int
    let onContinue: () -> Void
    let onNew: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.66).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "tray.full.fill").font(.system(size: 30)).foregroundColor(KTS.accent)
                Text("Resume your submission?").font(.system(size: 18, weight: .bold)).foregroundColor(KTS.txt)
                Text("You have a saved batch of \(count) card\(count == 1 ? "" : "s"). Pick up where you left off, or start a new one.")
                    .font(.system(size: 14)).foregroundColor(KTS.muted).multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    Button("Continue saved (\(count))", action: onContinue).buttonStyle(KTSPrimaryButton())
                    Button("Start new", action: onNew).buttonStyle(KTSGhostButton())
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 330)
            .background(KTS.panel)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(KTS.line))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 30)
        }
        .environment(\.colorScheme, .dark)
    }
}

// Gold corner brackets + sweeping line
struct AimFrame: View {
    let sweep: Bool
    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width * 0.78, 320)
            let h = w * 0.62
            ZStack {
                ForEach(0..<4) { i in Corner().stroke(KTS.accent, lineWidth: 3).frame(width: 26, height: 26).rotationEffect(.degrees(Double(i) * 90)).offset(cornerOffset(i, w, h)) }
                Rectangle().fill(KTS.accent.opacity(0.85)).frame(width: w - 24, height: 2)
                    .offset(y: sweep ? h/2 - 14 : -h/2 + 14).shadow(color: KTS.accent.opacity(0.6), radius: 4)
            }
            .frame(width: w, height: h)
            .position(x: geo.size.width/2, y: geo.size.height * 0.42)
        }
    }
    private func cornerOffset(_ i: Int, _ w: CGFloat, _ h: CGFloat) -> CGSize {
        switch i { case 0: return CGSize(width: -w/2 + 13, height: -h/2 + 13)
                   case 1: return CGSize(width:  w/2 - 13, height: -h/2 + 13)
                   case 2: return CGSize(width:  w/2 - 13, height:  h/2 - 13)
                   default:return CGSize(width: -w/2 + 13, height:  h/2 - 13) } }
}
struct Corner: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); return p }
}

// Offer card that rises over the camera
struct OfferCard: View {
    let r: SellerView; let hide: Bool
    var body: some View {
        let buy = r.isBuy
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: buy ? "checkmark.seal.fill" : "xmark.octagon.fill").foregroundColor(buy ? KTS.green : KTS.red)
                Text(buy ? "KTS will buy this" : "Can't take right now").font(.system(size: 15, weight: .heavy)).foregroundColor(buy ? KTS.green : KTS.red)
                Spacer()
                if buy { Text(ktsMoney(r.offer, hide: hide)).font(.system(size: 26, weight: .heavy)).foregroundColor(KTS.accent) }
            }
            if !r.cardTitle.isEmpty { Text(r.cardTitle).font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.txt).lineLimit(2) }
            Text("\(r.categoryLabel) · \(r.grader) \(r.grade) · #\(r.cert)\(ktsConfSuffix(r))")
                .font(.system(size: 12)).foregroundColor(KTS.muted)
            if !buy, !r.reason.isEmpty { Text(r.reason).font(.system(size: 12)).foregroundColor(KTS.red.opacity(0.9)) }
            if buy {
                HStack(spacing: 6) {
                    // Value (Market, or "Last sold" for CGC) is public — always visible, even in incognito.
                    Text("\(ktsValueLabel(r)) \(ktsMoney(ktsShownValue(r), hide: false))").foregroundColor(KTS.txt)
                    // Buy-rate % hides in incognito (else payout = market × % would leak).
                    if let pct = r.offerPct, !hide {
                        Text("·").foregroundColor(KTS.muted)
                        Text("\(Int(pct.rounded()))% buy rate").foregroundColor(KTS.muted)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                if let band = r.band, let lo = band.min, let hi = band.max {
                    Text("\(r.categoryLabel) \(ktsBand(lo, hi, hide: false))")
                        .font(.system(size: 11)).foregroundColor(KTS.muted)
                }
                if r.nearFull == true {
                    Text("⏳ Limited space in this range — submit soon to lock it in.")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(Color(hex: 0xE8A54B))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if r.lane == true {
                    Text("⚡ Bought on the spot — unlimited.")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(KTS.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else if r.category.lowercased() == "pokemon" {
                    Text("Estimate — your price locks when I submit this at the next window (~3 AM ET).")
                        .font(.system(size: 11)).foregroundColor(KTS.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .background((buy ? KTS.green : KTS.red).opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke((buy ? KTS.green : KTS.red).opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// Bottom summary sheet — drag/tap the handle to expand into the full scanned-cards list.
struct SummarySheet: View {
    @ObservedObject var scan: ScanModel
    let hide: Bool
    @Binding var expanded: Bool
    let onSubmit: () -> Void
    let onManual: () -> Void

    private var isFull: Bool { expanded && scan.hasContent }

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle: tap or drag up to reveal the scanned-cards list
            VStack(spacing: 5) {
                Capsule().fill(KTS.muted.opacity(0.45)).frame(width: 40, height: 5)
                if scan.hasContent {
                    Text(expanded ? "Swipe down to close" : ktsHandleLabel(results: scan.results.count, errored: scan.errored.count))
                        .font(.system(size: 11, weight: .medium)).foregroundColor(KTS.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8).padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .gesture(DragGesture(minimumDistance: 10).onEnded { v in
                if v.translation.height < -24 { set(true) } else if v.translation.height > 24 { set(false) }
            })

            if isFull {
                // Fully expanded: totals pinned top, list fills, actions pinned bottom.
                totalsRow.padding(.horizontal, 18).padding(.bottom, 8)
                selectAllRow
                Rectangle().fill(KTS.line.opacity(0.5)).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(scan.errored) { e in
                            ScanErrorRow(error: e,
                                         onRetry: { scan.retryError(e.cert) },
                                         onDismiss: { withAnimation { scan.dismissError(e.cert) } })
                            Rectangle().fill(KTS.line.opacity(0.3)).frame(height: 1).padding(.leading, 16)
                        }
                        ForEach(scan.results) { r in
                            ScannedRow(r: r, hide: hide,
                                       selected: scan.isSelected(r.cert),
                                       onToggle: { withAnimation { scan.toggleSelect(r.cert) } },
                                       onRemove: { withAnimation { scan.remove(r.cert) } })
                            Rectangle().fill(KTS.line.opacity(0.3)).frame(height: 1).padding(.leading, 16)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Rectangle().fill(KTS.line.opacity(0.5)).frame(height: 1)
                actionsRow.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 10)
            } else {
                summary
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isFull ? .infinity : nil)
        .background(sheetBackground)
        .clipShape(RoundedCorners(radius: 26, corners: [.topLeft, .topRight]))
        .overlay(RoundedCorners(radius: 26, corners: [.topLeft, .topRight]).stroke(KTS.line.opacity(0.6)))
    }

    @ViewBuilder private var sheetBackground: some View {
        if isFull {
            KTS.bg   // opaque for the full takeover — no camera bleed through the list
        } else {
            Color.clear.background(.ultraThinMaterial).background(KTS.panel.opacity(0.7))
        }
    }

    private var selectAllRow: some View {
        HStack {
            Button(action: { withAnimation { scan.selectAllToggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: scan.allBuySelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18)).foregroundColor(scan.allBuySelected ? KTS.accent : KTS.muted)
                    Text("Select all takeable").font(.system(size: 13, weight: .medium)).foregroundColor(KTS.txt)
                }
            }
            .buttonStyle(.plain)
            .disabled(scan.buyCerts.isEmpty)
            Spacer()
            Text("\(scan.selectedCount) selected").font(.system(size: 12)).foregroundColor(KTS.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func toggle() { if scan.hasContent { set(!expanded) } }
    private func set(_ v: Bool) { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded = v } }

    // Collapsed layout: totals + actions together (unchanged look).
    private var summary: some View {
        VStack(spacing: 12) { totalsRow; actionsRow }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
    }

    private var totalsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(scan.scannedCount) scanned").font(.system(size: 17, weight: .heavy)).foregroundColor(KTS.txt)
                if !scan.pendingCerts.isEmpty { Text("pricing \(scan.pendingCerts.count)…").font(.system(size: 12)).foregroundColor(KTS.accent) }
                else { Text("\(scan.selectedCount) selected").font(.system(size: 12)).foregroundColor(KTS.muted) }
            }
            Spacer()
            totalCol("MARKET", ktsMoney(scan.marketTotal, hide: false), KTS.txt)
            totalCol("PAYOUT", ktsMoney(scan.payoutTotal, hide: hide), KTS.accent)
        }
    }

    private var actionsRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if scan.selectedCount > 0 {
                    Button(action: { withAnimation { scan.removeSelected() } }) {
                        Text("Remove \(scan.selectedCount)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KTSDangerButton())
                }
                Button(action: onSubmit) {
                    Text(scan.submitting ? "Sending…" : (scan.selectedCount > 0 ? "Submit \(scan.selectedCount)" : "Submit"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KTSPrimaryButton())
                .disabled(scan.selectedCount == 0 || scan.submitting)
                .opacity(scan.selectedCount == 0 ? 0.5 : 1)
            }
            Button(action: onManual) {
                HStack(spacing: 6) { Image(systemName: "keyboard"); Text("Enter manually") }
                    .font(.system(size: 14, weight: .medium)).foregroundColor(KTS.muted)
            }
        }
    }

    private func totalCol(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(KTS.muted)
            Text(value).font(.system(size: 18, weight: .heavy)).foregroundColor(color).monospacedDigit()
        }
        .padding(.leading, 16)
    }
}

// One row in the expanded list: checkbox (takeable) · cert photo · title · offer, or a dimmed Pass row with remove.
struct ScannedRow: View {
    let r: SellerView; let hide: Bool
    let selected: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            if r.isBuy {
                Button(action: onToggle) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 21)).foregroundColor(selected ? KTS.accent : KTS.muted.opacity(0.7))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 21)
            }

            AsyncImage(url: URL(string: r.imageUrl ?? "")) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: KTS.panel2.opacity(0.8)
                }
            }
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(KTS.line.opacity(0.6)))
            .saturation(r.isBuy ? 1 : 0.3)

            VStack(alignment: .leading, spacing: 3) {
                Text(r.cardTitle.isEmpty ? "Cert \(r.cert)" : r.cardTitle)
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.txt).lineLimit(1)
                Text("\(r.grader) \(r.grade) · \(r.categoryLabel) · #\(r.cert)")
                    .font(.system(size: 12)).foregroundColor(KTS.muted).lineLimit(1)
                if r.nearFull == true {
                    Text("⏳ Limited space — submit soon")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: 0xE8A54B)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if r.isBuy {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ktsMoney(r.offer, hide: hide)).font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.accent).monospacedDigit()
                    if ktsShownValue(r) != nil {
                        Text(ktsRowMarketPct(r, hide: hide)).font(.system(size: 10)).foregroundColor(KTS.muted).monospacedDigit()
                    }
                }
            } else {
                Text(r.reason.isEmpty ? "Pass" : r.reason)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: 0xE8A54B))   // amber — "band getting full" warning.
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 134, alignment: .trailing)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundColor(KTS.muted.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .opacity(r.isBuy ? 1 : 0.7)
        .contentShape(Rectangle())
        .onTapGesture { if r.isBuy { onToggle() } }
    }
}

// Grab-handle subtitle for the summary sheet: "3 cards · 2 to retry · swipe up".
func ktsHandleLabel(results: Int, errored: Int) -> String {
    var parts: [String] = []
    if results > 0 { parts.append("\(results) card\(results == 1 ? "" : "s")") }
    if errored > 0 { parts.append("\(errored) to retry") }
    let head = parts.joined(separator: " · ")
    return head.isEmpty ? "swipe up" : head + " · swipe up"
}

// A failed-to-price cert as a row in the expanded list — amber, with Retry + dismiss. Mirrors
// the web scanner's persistent "Couldn't price · tap to try again" card so flaky show wifi
// never silently eats a scan.
struct ScanErrorRow: View {
    let error: ScanError
    let onRetry: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 20)).foregroundColor(Color(hex: 0xE8A54B)).frame(width: 21)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cert \(error.cert)").font(.system(size: 14, weight: .semibold)).foregroundColor(KTS.txt).lineLimit(1)
                Text(error.message).font(.system(size: 12)).foregroundColor(Color(hex: 0xE8A54B))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(action: onRetry) {
                Text("Retry").font(.system(size: 13, weight: .semibold)).foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(KTS.accent).clipShape(Capsule())
            }.buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundColor(KTS.muted.opacity(0.5))
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture { onRetry() }
    }
}

// Collapsed-state nudge when some cards failed to price (flaky connection): retry them all,
// or tap to open the list and retry one at a time.
struct ScanErrorBanner: View {
    let count: Int
    let onRetryAll: () -> Void
    let onReview: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) card\(count == 1 ? "" : "s") couldn't be priced")
                    .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Flaky connection? Tap to retry.").font(.system(size: 11)).foregroundColor(Color(hex: 0xE8A54B).opacity(0.85))
            }
            Spacer(minLength: 4)
            Button(action: onRetryAll) {
                Text("Retry all").font(.system(size: 13, weight: .bold)).foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Color(hex: 0xE8A54B)).clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .foregroundColor(Color(hex: 0xE8A54B))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(Color(hex: 0xE8A54B).opacity(0.16))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(hex: 0xE8A54B).opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onReview() }
    }
}

// "$30–$220" posted band range (or hidden in incognito).
func ktsBand(_ lo: Double, _ hi: Double, hide: Bool) -> String {
    hide ? "$•••" : "$\(Int(lo))–$\(Int(hi))"
}

// Compact "market · buy-rate" subline for a scan row, e.g. "$36.00 · 90%".
// Market stays visible in incognito; the % hides (market × % would leak the payout).
func ktsRowMarketPct(_ r: SellerView, hide: Bool) -> String {
    let v = ktsMoney(ktsShownValue(r), hide: false)
    if let pct = r.offerPct, !hide { return "\(v) · \(Int(pct.rounded()))%" }
    return v
}

// The value the offer is computed against (CGC = last sold, else CardLadder market).
// Falls back to cardladderValue for older responses that don't send `value`.
func ktsShownValue(_ r: SellerView) -> Double? { r.value ?? r.cardladderValue }

// Label for that value: "Last sold" for CGC (last-sold basis), else "Market".
func ktsValueLabel(_ r: SellerView) -> String { r.valueBasis == "lastSold" ? "Last sold" : "Market" }

// CardLadder match-confidence suffix for a card's identity line, e.g. " · 95% match"
// (blank when the cert has no confidence score). Not sensitive — always shown.
func ktsConfSuffix(_ r: SellerView) -> String {
    r.confidence.isEmpty ? "" : " · \(r.confidence.text)% match"
}

// MARK: - Submission windows (One Piece + sports have a window; Pokémon has its own)

// Parse an ISO8601 timestamp (with or without fractional seconds).
func ktsParseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// True when a window opens in the future, so its cards can't be submitted yet.
func ktsIsFuture(_ iso: String?) -> Bool {
    guard let d = ktsParseISO(iso) else { return false }
    return d > Date()
}

// e.g. "Sat 3:00 AM ET" / "Fri 6:00 PM ET" — in the given time zone. Both windows show in ET.
func ktsWindowLabel(_ iso: String?, tz: String, abbr: String) -> String {
    guard let d = ktsParseISO(iso) else { return "soon" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = TimeZone(identifier: tz)
    f.dateFormat = "EEE h:mm a"
    return f.string(from: d) + " " + abbr
}

// Submit-block text, built client-side from the 409's `locked` + opensAt so the time reads
// in ET (matching the Rates page), rather than echoing the server's PT-worded message.
func ktsLockMessage(_ e: APIError) -> String {
    switch e.lockedWindow {
    case "main":
        return "One Piece & sports open \(ktsWindowLabel(e.mainOpensAt, tz: "America/New_York", abbr: "ET")). You can submit them then."
    case "pokemon":
        return "Pokémon opens \(ktsWindowLabel(e.pokemonOpensAt, tz: "America/New_York", abbr: "ET")). You can submit them then."
    default:
        return e.message
    }
}

// Gold note(s) over the scan screen while a window is still closed. Scanning & pricing
// work anytime; only submitting that window's cards waits.
struct WindowOpenNotes: View {
    let mainOpensAt: String?
    let pokemonOpensAt: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if ktsIsFuture(mainOpensAt) {
                line("One Piece & sports open \(ktsWindowLabel(mainOpensAt, tz: "America/New_York", abbr: "ET"))")
            }
            if ktsIsFuture(pokemonOpensAt) {
                line("Pokémon opens \(ktsWindowLabel(pokemonOpensAt, tz: "America/New_York", abbr: "ET"))")
            }
            Text("Scan & price anytime — submit these once the window opens.")
                .font(.system(size: 11)).foregroundColor(KTS.accent.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(KTS.accent.opacity(0.14))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(KTS.accent.opacity(0.45)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func line(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill").font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(KTS.accent)
    }
}

// Shown after a submit is blocked (409): the batch is kept, so the seller can submit the
// cards that are open now and come back for the gated ones when their window opens.
struct WindowBlockBanner: View {
    let message: String
    let onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark.fill").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your batch is saved — submit the rest now, or come back then.")
                    .font(.system(size: 11)).foregroundColor(KTS.accent.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(KTS.accent.opacity(0.8))
            }
        }
        .foregroundColor(KTS.accent)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(KTS.accent.opacity(0.16))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(KTS.accent.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Calculator (plain basic calculator, opened from the scan screen)

@MainActor final class CalcModel: ObservableObject {
    @Published var display = "0"
    @Published var history: [String] = []      // "a op b = c", newest first
    private var stored: Double?                 // left operand
    private var op: String?                     // pending operator (÷ × − +)
    private var typingNew = true                // next digit starts a fresh entry

    func digit(_ d: String) {
        if typingNew { display = (d == "." ? "0." : d); typingNew = false; return }
        if d == "." { if !display.contains(".") { display += "." }; return }
        display = (display == "0") ? d : display + d
    }
    func setOp(_ newOp: String) {
        if op != nil && !typingNew { evaluate(record: false) } else { stored = Double(display) }
        op = newOp; typingNew = true
    }
    func equals() { evaluate(record: true); op = nil; typingNew = true }
    func clear() { display = "0"; stored = nil; op = nil; typingNew = true }
    func backspace() {
        if typingNew || display == "0" { return }
        display.removeLast()
        if display.isEmpty || display == "-" { display = "0"; typingNew = true }
    }
    func percent() { display = trim((Double(display) ?? 0) / 100); typingNew = true }

    private func evaluate(record: Bool) {
        guard let op = op, let lhs = stored else { stored = Double(display); return }
        let rhs = Double(display) ?? 0
        let result: Double
        switch op {
        case "+": result = lhs + rhs
        case "−": result = lhs - rhs
        case "×": result = lhs * rhs
        case "÷": result = rhs == 0 ? 0 : lhs / rhs
        default:  result = rhs
        }
        if record { history.insert("\(trim(lhs)) \(op) \(trim(rhs)) = \(trim(result))", at: 0) }
        display = trim(result); stored = result
    }
    private func trim(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "0" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(format: "%g", d)
    }
}

enum CalcKeyKind { case digit, op, util, equals }

struct CalcSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var calc = CalcModel()
    @State private var showHistory = false

    var body: some View {
        ZStack {
            KTS.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button { withAnimation { showHistory.toggle() } } label: {
                        HStack(spacing: 5) { Image(systemName: "clock.arrow.circlepath"); Text("History") }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(calc.history.isEmpty ? KTS.muted.opacity(0.4) : KTS.muted)
                    }.disabled(calc.history.isEmpty)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundColor(KTS.muted)
                            .padding(8).background(KTS.panel.opacity(0.6)).clipShape(Circle())
                    }.accessibilityLabel("Close")
                }
                .padding(.top, 14)

                if showHistory && !calc.history.isEmpty {
                    ScrollView {
                        VStack(alignment: .trailing, spacing: 6) {
                            ForEach(Array(calc.history.enumerated()), id: \.offset) { _, h in
                                Text(h).font(.system(size: 13)).foregroundColor(KTS.muted)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    .padding(12).background(KTS.panel.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(calc.display)
                    .font(.system(size: 56, weight: .light)).foregroundColor(KTS.txt)
                    .lineLimit(1).minimumScaleFactor(0.35)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.vertical, 6)

                GeometryReader { geo in
                    let s: CGFloat = 10
                    let bw = (geo.size.width - 3 * s) / 4
                    let bh = (geo.size.height - 4 * s) / 5
                    VStack(spacing: s) {
                        HStack(spacing: s) {
                            key("⌫", .util, bw, bh) { calc.backspace() }
                            key("AC", .util, bw, bh) { calc.clear() }
                            key("%", .util, bw, bh) { calc.percent() }
                            key("÷", .op, bw, bh) { calc.setOp("÷") }
                        }
                        HStack(spacing: s) {
                            key("7", .digit, bw, bh) { calc.digit("7") }
                            key("8", .digit, bw, bh) { calc.digit("8") }
                            key("9", .digit, bw, bh) { calc.digit("9") }
                            key("×", .op, bw, bh) { calc.setOp("×") }
                        }
                        HStack(spacing: s) {
                            key("4", .digit, bw, bh) { calc.digit("4") }
                            key("5", .digit, bw, bh) { calc.digit("5") }
                            key("6", .digit, bw, bh) { calc.digit("6") }
                            key("−", .op, bw, bh) { calc.setOp("−") }
                        }
                        HStack(spacing: s) {
                            key("1", .digit, bw, bh) { calc.digit("1") }
                            key("2", .digit, bw, bh) { calc.digit("2") }
                            key("3", .digit, bw, bh) { calc.digit("3") }
                            key("+", .op, bw, bh) { calc.setOp("+") }
                        }
                        HStack(spacing: s) {
                            key("0", .digit, bw * 2 + s, bh) { calc.digit("0") }
                            key(".", .digit, bw, bh) { calc.digit(".") }
                            key("=", .equals, bw, bh) { calc.equals() }
                        }
                    }
                }
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 20)
        }
        .environment(\.colorScheme, .dark).tint(KTS.accent)
    }

    private func key(_ label: String, _ kind: CalcKeyKind, _ w: CGFloat, _ h: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(kind == .op || kind == .equals ? .black : KTS.txt)
                .frame(width: w, height: h)
                .background(keyBg(kind))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    private func keyBg(_ k: CalcKeyKind) -> Color {
        switch k {
        case .digit: return KTS.panel2
        case .util:  return KTS.panel.opacity(0.9)
        case .op, .equals: return KTS.accent
        }
    }
}

struct RoundedCorners: Shape {
    var radius: CGFloat; var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
