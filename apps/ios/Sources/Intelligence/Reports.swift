// Exports: the room report PDF (insurance / moving), the floor plan as
// an image, and the whole inventory as JSON. All plain files handed to
// the system share sheet — nothing leaves the device except by the
// user's explicit choice of destination.
import NavCore
import SwiftUI
import UIKit

enum Reports {

    // ---- floor plan drawing (shared by PDF and PNG) ----------------------

    /// Draw a room's saved grid: free floor dark teal, obstacles amber,
    /// remembered things as labelled dots. Pure CoreGraphics so the
    /// same code serves screen, PNG and PDF contexts.
    static func drawFloorPlan(grid: OccupancyGrid, things: [Thing],
                              in ctx: CGContext, rect: CGRect) {
        ctx.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
        ctx.fill(rect)
        let scale = min(rect.width, rect.height)
            / CGFloat(Double(grid.width) * grid.cellSize)
        let cellPx = scale * CGFloat(grid.cellSize)
        let ox = rect.minX
        let oy = rect.maxY

        let free = UIColor(red: 0.10, green: 0.30, blue: 0.30, alpha: 1)
        let occ = UIColor(red: 0.85, green: 0.65, blue: 0.25, alpha: 1)
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let lo = grid.lo[y * grid.width + x]
                let color: UIColor
                if lo >= LO_OCC { color = occ }
                else if lo <= LO_FREE { color = free }
                else { continue }
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(
                    x: ox + CGFloat(x) * cellPx,
                    y: oy - CGFloat(y + 1) * cellPx,
                    width: cellPx + 0.5, height: cellPx + 0.5))
            }
        }

        func toPx(_ wx: Double, _ wy: Double) -> CGPoint {
            CGPoint(x: ox + CGFloat(wx - grid.origin.x) * scale,
                    y: oy - CGFloat(wy - grid.origin.y) * scale)
        }

        let label = [
            NSAttributedString.Key.font:
                UIFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: UIColor.white,
        ] as [NSAttributedString.Key: Any]
        for thing in things.prefix(80) {
            let p = toPx(thing.positionX, thing.positionY)
            guard rect.insetBy(dx: 2, dy: 2).contains(p) else { continue }
            ctx.setFillColor(UIColor.systemYellow.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5,
                                       width: 5, height: 5))
            NSAttributedString(string: thing.displayName, attributes: label)
                .draw(at: CGPoint(x: p.x + 4, y: p.y - 4))
        }
    }

    // ---- floor plan PNG --------------------------------------------------

    static func floorPlanPNG(room: Room) -> URL? {
        guard let grid = Store.loadGrid(room.id) else { return nil }
        let size = CGSize(width: 1000, height: 1000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { rctx in
            drawFloorPlan(grid: grid, things: room.things,
                          in: rctx.cgContext,
                          rect: CGRect(origin: .zero, size: size))
            let title = "\(room.name) — Theseus"
            title.draw(
                at: CGPoint(x: 16, y: 12),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor.white,
                ])
        }
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe(room.name))-floorplan.png")
        try? data.write(to: url, options: .atomic)
        return url
    }

    // ---- room report PDF -------------------------------------------------

    /// The "prove what you owned" document: floor plan, then every item
    /// with photo, size, value and last-seen date.
    static func roomReportPDF(room: Room) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792) // letter
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let things = room.things.sorted {
            ($0.price ?? 0, $0.displayName) > ($1.price ?? 0, $1.displayName)
        }
        let total = things.compactMap(\.price).reduce(0, +)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe(room.name))-report.pdf")
        do {
            try renderer.writePDF(to: url) { pdf in
                pdf.beginPage()
                var y = margin

                func text(_ s: String, size: CGFloat, weight: UIFont.Weight,
                          color: UIColor = .black) {
                    s.draw(at: CGPoint(x: margin, y: y), withAttributes: [
                        .font: UIFont.systemFont(ofSize: size,
                                                 weight: weight),
                        .foregroundColor: color,
                    ])
                    y += size + 8
                }

                text("\(room.name) — inventory report", size: 24,
                     weight: .bold)
                let dateLine = Date().formatted(date: .long,
                                                time: .omitted)
                var summary = "\(things.count) items · "
                    + String(format: "%.0f m² mapped", room.floorAreaM2)
                if total > 0 {
                    summary += " · total value "
                        + currency(total)
                }
                text("\(dateLine) · \(summary)", size: 11,
                     weight: .regular, color: .darkGray)
                text("Generated on-device by Theseus. Positions and "
                     + "sizes are measured from the room scan.",
                     size: 9, weight: .regular, color: .gray)
                y += 4

                if let grid = Store.loadGrid(room.id) {
                    let planRect = CGRect(x: margin, y: y,
                                          width: page.width - margin * 2,
                                          height: 260)
                    drawFloorPlan(grid: grid, things: room.things,
                                  in: pdf.cgContext, rect: planRect)
                    y += 272
                }

                // item cards, three per row
                let cols = 3
                let cardW = (page.width - margin * 2
                             - CGFloat(cols - 1) * 12) / CGFloat(cols)
                let cardH: CGFloat = 150
                var col = 0
                for thing in things {
                    if y + cardH > page.height - margin {
                        pdf.beginPage()
                        y = margin
                        col = 0
                    }
                    let x = margin + CGFloat(col) * (cardW + 12)
                    let card = CGRect(x: x, y: y, width: cardW,
                                      height: cardH)
                    pdf.cgContext.setFillColor(
                        UIColor(white: 0.96, alpha: 1).cgColor)
                    pdf.cgContext.fill(card)
                    if let thumb = Store.loadThumb(thing.id) {
                        thumb.draw(in: CGRect(x: x + 6, y: y + 6,
                                              width: cardW - 12,
                                              height: 84))
                    }
                    var line = y + 96
                    func cardText(_ s: String, size: CGFloat,
                                  weight: UIFont.Weight,
                                  color: UIColor = .black) {
                        s.draw(in: CGRect(x: x + 6, y: line,
                                          width: cardW - 12,
                                          height: size + 4),
                               withAttributes: [
                            .font: UIFont.systemFont(ofSize: size,
                                                     weight: weight),
                            .foregroundColor: color,
                        ])
                        line += size + 5
                    }
                    cardText(thing.displayName, size: 10, weight: .bold)
                    cardText(thing.sizeDescription, size: 8,
                             weight: .regular, color: .darkGray)
                    var meta = "seen " + thing.lastSeenAt.formatted(
                        date: .abbreviated, time: .omitted)
                    if let price = thing.price {
                        meta = currency(price) + " · " + meta
                    }
                    cardText(meta, size: 8, weight: .regular,
                             color: .darkGray)

                    col += 1
                    if col == cols {
                        col = 0
                        y += cardH + 12
                    }
                }
            }
        } catch {
            return nil
        }
        return url
    }

    // ---- whole-inventory JSON --------------------------------------------

    static func inventoryJSON(rooms: [Room]) -> URL? {
        var out: [[String: Any]] = []
        for room in rooms {
            for thing in room.things {
                var row: [String: Any] = [
                    "name": thing.displayName,
                    "room": room.name,
                    "category": thing.category,
                    "position_m": [thing.positionX, thing.positionY],
                    "first_seen": iso(thing.firstSeenAt),
                    "last_seen": iso(thing.lastSeenAt),
                ]
                if thing.widthM > 0 {
                    row["size_m"] = [thing.widthM, thing.sizeHeightM]
                }
                if let price = thing.price { row["value"] = price }
                if !thing.recognizedText.isEmpty {
                    row["text"] = thing.recognizedText
                }
                if let barcode = thing.barcode {
                    row["barcode"] = barcode
                }
                out.append(row)
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["exported": iso(Date()), "things": out],
            options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-inventory.json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    // ---- helpers ---------------------------------------------------------

    private static func currency(_ v: Double) -> String {
        v.formatted(.currency(
            code: Locale.current.currency?.identifier ?? "USD")
            .precision(.fractionLength(0)))
    }

    private static func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9-]",
                               with: "-",
                               options: .regularExpression)
    }
}
