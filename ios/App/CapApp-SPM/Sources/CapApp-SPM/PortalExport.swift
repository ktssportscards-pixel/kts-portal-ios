import SwiftUI
import UIKit

// MARK: - CSV / TSV export for the seller's own submissions

enum KTSExport {
    // RFC-4180-ish CSV: quote any field containing a comma, quote, or newline.
    static func csv(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n")
    }
    // Tab-separated — paste straight into Google Sheets / Excel.
    static func tsv(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
            .joined(separator: "\n")
    }
    private static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
    // Plain number for spreadsheets (no "$", so it stays numeric).
    static func money(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
    static func date(_ iso: String) -> String {
        guard let d = ktsParseDate(iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d)
    }
    static func writeTempCSV(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try text.data(using: .utf8)?.write(to: url, options: .atomic); return url } catch { return nil }
    }

    // Present the system share sheet for a file, from the top-most view controller
    // (more reliable than wrapping UIActivityViewController in a SwiftUI .sheet).
    @MainActor static func share(_ url: URL) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let root = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {       // iPad anchor
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}

// Seller's own submissions → one row per slab.
func ktsSellerExport(_ subs: [Submission]) -> (header: [String], rows: [[String]]) {
    let header = ["Date", "Submission", "Cert", "Grader", "Grade", "Category", "Card", "CardLadder", "Offer", "Status", "Confidence"]
    var rows: [[String]] = []
    for s in subs.sorted(by: { $0.created_at > $1.created_at }) {
        for it in s.items {
            rows.append([
                KTSExport.date(s.created_at), "#\(s.id)", it.cert, it.grader, it.grade, it.category,
                it.card_title, KTSExport.money(it.cardladder_value), KTSExport.money(it.offer_amount),
                it.item_status.capitalized, it.confidence.text,
            ])
        }
    }
    return (header, rows)
}

// MARK: - Reusable Copy / CSV bar

struct ExportBar: View {
    let fileName: String                                  // e.g. "kts-my-submissions.csv"
    let build: () -> (header: [String], rows: [[String]]) // computed lazily so it reflects fresh data
    @State private var copied = false

    var body: some View {
        let data = build()
        let empty = data.rows.isEmpty
        return HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = KTSExport.tsv(data.header, data.rows)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied" : "Copy")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(KTSGhostButton()).disabled(empty)

            Button {
                let csv = KTSExport.csv(data.header, data.rows)
                if let url = KTSExport.writeTempCSV(csv, name: fileName) { KTSExport.share(url) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Download CSV")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(KTSGhostButton()).disabled(empty)
        }
        .opacity(empty ? 0.5 : 1)
    }
}
