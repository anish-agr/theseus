// Receipt OCR: photograph or pick a receipt and the app reads the
// total and the purchase date off it — on-device, no AI call. A value
// with a receipt behind it is "documented", not "estimated", which is
// the difference an insurance adjuster actually cares about.
import Foundation
import UIKit

struct ReceiptReading {
    var total: Double?
    var date: Date?
}

enum ReceiptReader {
    /// Totals appear near these words; the LARGEST amount on the
    /// receipt is the fallback (item lines are smaller than totals).
    private static let totalWords = ["total", "amount due", "balance",
                                     "grand total", "amount"]
    private static let notTotalWords = ["subtotal", "tax", "change",
                                        "cash", "tender", "saved",
                                        "discount"]

    static func read(_ image: UIImage) -> ReceiptReading {
        let lines = VisionPipeline.textLines(in: image)
        var reading = ReceiptReading()

        // ---- the total ---------------------------------------------------
        var best: Double?
        var bestScore = -1
        for (index, line) in lines.enumerated() {
            for amount in amounts(in: line) {
                var score = 0
                let lower = line.lowercased()
                // context: the line itself, or the line right above
                // (receipts often put "TOTAL" and the number apart)
                let context = lower + " "
                    + (index > 0 ? lines[index - 1].lowercased() : "")
                if totalWords.contains(where: context.contains) {
                    score += 10
                }
                if notTotalWords.contains(where: lower.contains) {
                    score -= 8
                }
                if score > bestScore
                    || (score == bestScore && amount > (best ?? 0)) {
                    bestScore = score
                    best = amount
                }
            }
        }
        reading.total = best

        // ---- the date ----------------------------------------------------
        // NSDataDetector handles every "3/14/24" / "Mar 14, 2024" /
        // "2024-03-14" a register prints
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let joined = lines.joined(separator: "\n")
            let matches = detector.matches(
                in: joined, range: NSRange(joined.startIndex...,
                                           in: joined))
            reading.date = matches
                .compactMap(\.date)
                .filter { $0 <= Date() }     // receipts are the past
                .first
        }
        return reading
    }

    /// Currency-looking numbers in a line: "$1,299.99", "12.50",
    /// "€ 49,90". Rejects obvious non-prices (phone numbers, card
    /// digits) by requiring the cents separator.
    private static func amounts(in line: String) -> [Double] {
        let pattern = #"[\$€£]?\s?([0-9]{1,3}(?:[, ][0-9]{3})*|[0-9]+)[.,]([0-9]{2})(?![0-9])"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap {
            match in
            guard let whole = Range(match.range(at: 1), in: line),
                  let cents = Range(match.range(at: 2), in: line)
            else { return nil }
            let units = line[whole]
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard let u = Double(units),
                  let c = Double(line[cents]) else { return nil }
            let value = u + c / 100
            // sane receipt range; a 7-digit "total" is a card number
            return (0.5...100_000).contains(value) ? value : nil
        }
    }
}
