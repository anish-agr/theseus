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

    // ---- whole-home insurance PDF ----------------------------------------

    /// The claim document: every item you own across every room and
    /// every storage box — photo, location, size, serial, value,
    /// receipt-on-file, warranty. One file to send the adjuster.
    static func insurancePDF(rooms: [Room], things: [Thing],
                             spots: [StorageSpot]) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let sorted = things.sorted {
            ($0.price ?? 0, $0.displayName) > ($1.price ?? 0, $1.displayName)
        }
        let total = sorted.compactMap(\.price).reduce(0, +)
        func location(_ thing: Thing) -> String {
            if let id = thing.storageID,
               let spot = spots.first(where: { $0.id == id }) {
                return "in \(spot.name)"
            }
            return thing.room?.name ?? "—"
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-insurance-report.pdf")
        do {
            try renderer.writePDF(to: url) { pdf in
                pdf.beginPage()
                var y = margin

                func text(_ s: String, size: CGFloat,
                          weight: UIFont.Weight,
                          color: UIColor = .black,
                          indent: CGFloat = 0) {
                    s.draw(at: CGPoint(x: margin + indent, y: y),
                           withAttributes: [
                            .font: UIFont.systemFont(ofSize: size,
                                                     weight: weight),
                            .foregroundColor: color,
                           ])
                    y += size + 8
                }

                text("Home inventory — insurance report", size: 24,
                     weight: .bold)
                text(Date().formatted(date: .long, time: .omitted)
                     + " · \(sorted.count) items · total documented "
                     + "value " + currency(total),
                     size: 11, weight: .regular, color: .darkGray)
                text("Generated on-device by Theseus. Photos, serials "
                     + "and receipts are recorded per item below.",
                     size: 9, weight: .regular, color: .gray)
                y += 6

                // per-room subtotals
                text("Value by location", size: 13, weight: .semibold)
                var lines: [(String, Double, Int)] = []
                for room in rooms {
                    let inRoom = room.things.filter {
                        $0.storageID == nil
                    }
                    let v = inRoom.compactMap(\.price).reduce(0, +)
                    if !inRoom.isEmpty {
                        lines.append((room.name, v, inRoom.count))
                    }
                }
                for spot in spots {
                    let inSpot = things.filter {
                        $0.storageID == spot.id
                    }
                    let v = inSpot.compactMap(\.price).reduce(0, +)
                    if !inSpot.isEmpty {
                        lines.append((spot.name, v, inSpot.count))
                    }
                }
                for (name, value, count) in lines {
                    text("\(name) — \(count) items · "
                         + currency(value),
                         size: 10, weight: .regular, color: .darkGray,
                         indent: 12)
                }
                y += 8

                // item rows
                let rowH: CGFloat = 52
                func header() {
                    text("Item · location · size · serial · value",
                         size: 10, weight: .semibold, color: .gray)
                    y += 2
                }
                header()
                for thing in sorted {
                    if y + rowH > page.height - margin {
                        pdf.beginPage()
                        y = margin
                        header()
                    }
                    if let thumb = Store.loadThumb(thing.id) {
                        thumb.draw(in: CGRect(x: margin, y: y,
                                              width: 46, height: 46))
                    }
                    let tx = margin + 56
                    var line = y
                    func row(_ s: String, size: CGFloat,
                             weight: UIFont.Weight,
                             color: UIColor = .black) {
                        s.draw(at: CGPoint(x: tx, y: line),
                               withAttributes: [
                                .font: UIFont.systemFont(
                                    ofSize: size, weight: weight),
                                .foregroundColor: color,
                               ])
                        line += size + 4
                    }
                    var title = thing.displayName
                    if let price = thing.price {
                        title += "  ·  " + currency(price)
                        if thing.priceSource == "ai" {
                            title += " (AI estimate)"
                        }
                    }
                    row(title, size: 11, weight: .semibold)
                    var meta = location(thing)
                    if thing.widthM > 0 {
                        meta += " · \(thing.sizeDescription)"
                    }
                    if let serial = thing.serialNumber {
                        meta += " · SN \(serial)"
                    }
                    row(meta, size: 9, weight: .regular,
                        color: .darkGray)
                    var flags: [String] = []
                    if Store.hasReceipt(thing.id) {
                        flags.append("receipt on file")
                    }
                    if let until = thing.warrantyUntil {
                        let stamp = until.formatted(
                            date: .abbreviated, time: .omitted)
                        flags.append(until > Date()
                                     ? "warranty until \(stamp)"
                                     : "warranty expired \(stamp)")
                    }
                    if !flags.isEmpty {
                        row(flags.joined(separator: " · "), size: 8,
                            weight: .regular, color: .gray)
                    }
                    y += rowH
                }
            }
        } catch {
            return nil
        }
        return url
    }

    // ---- whole-inventory JSON --------------------------------------------

    static func inventoryJSON(rooms: [Room], allThings: [Thing] = [],
                              spots: [StorageSpot] = []) -> URL? {
        var out: [[String: Any]] = []
        var things = allThings
        if things.isEmpty {
            things = rooms.flatMap(\.things)
        }
        for thing in things {
                var row: [String: Any] = [
                    "name": thing.displayName,
                    "category": thing.category,
                    "first_seen": iso(thing.firstSeenAt),
                    "last_seen": iso(thing.lastSeenAt),
                ]
                if let room = thing.room { row["room"] = room.name }
                if let id = thing.storageID,
                   let spot = spots.first(where: { $0.id == id }) {
                    row["storage"] = spot.name
                }
                if thing.hasPosition {
                    row["position_m"] = [thing.positionX,
                                         thing.positionY]
                }
                if thing.widthM > 0 {
                    row["size_m"] = [thing.widthM, thing.sizeHeightM]
                }
                if let price = thing.price {
                    row["value"] = price
                    if thing.priceSource == "ai" {
                        row["value_source"] = "ai_estimate"
                    }
                }
                if !thing.recognizedText.isEmpty {
                    row["text"] = thing.recognizedText
                }
                if let barcode = thing.barcode {
                    row["barcode"] = barcode
                }
                if let serial = thing.serialNumber {
                    row["serial"] = serial
                }
                if let until = thing.warrantyUntil {
                    row["warranty_until"] = iso(until)
                }
                out.append(row)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["exported": iso(Date()), "things": out],
            options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-inventory.json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    // ---- condition-record PDFs (rental deposit evidence) -----------------

    /// One record: every photo with tag, timestamp and note, plus the
    /// seal hash — the "this is what the room looked like on day one"
    /// document.
    static func conditionPDF(record: ConditionRecord) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let shots = record.shots.sorted { $0.at < $1.at }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(safe(record.roomName))-\(record.kind)-condition.pdf")
        do {
            try renderer.writePDF(to: url) { pdf in
                pdf.beginPage()
                var y = margin
                func text(_ s: String, size: CGFloat,
                          weight: UIFont.Weight,
                          color: UIColor = .black) {
                    s.draw(at: CGPoint(x: margin, y: y),
                           withAttributes: [
                            .font: UIFont.systemFont(ofSize: size,
                                                     weight: weight),
                            .foregroundColor: color,
                           ])
                    y += size + 8
                }
                text("\(record.roomName) — \(record.kindTitle) "
                     + "condition record", size: 22, weight: .bold)
                text("Recorded "
                     + record.startedAt.formatted(date: .long,
                                                  time: .shortened)
                     + " · \(shots.count) photos",
                     size: 11, weight: .regular, color: .darkGray)
                if let sealedAt = record.sealedAt,
                   let hash = record.sealHash {
                    text("Sealed "
                         + sealedAt.formatted(date: .long,
                                              time: .shortened)
                         + " — SHA-256 fingerprint of all photos and "
                         + "captions:", size: 9, weight: .regular,
                         color: .darkGray)
                    text(hash, size: 8, weight: .medium,
                         color: .darkGray)
                    text("Recomputing the fingerprint over the same "
                         + "photos reproduces this value; any edit "
                         + "changes it.", size: 8, weight: .regular,
                         color: .gray)
                } else {
                    text("UNSEALED draft — seal the record in Theseus "
                         + "to freeze it.", size: 9, weight: .medium,
                         color: .gray)
                }
                y += 6

                // two photo cards per row
                let cardW = (page.width - margin * 2 - 12) / 2
                let cardH: CGFloat = 250
                var col = 0
                for shot in shots {
                    if y + cardH > page.height - margin {
                        pdf.beginPage()
                        y = margin
                        col = 0
                    }
                    let x = margin + CGFloat(col) * (cardW + 12)
                    if let image = Store.loadConditionShot(
                        recordID: record.id, shotID: shot.id) {
                        image.draw(in: CGRect(x: x, y: y,
                                              width: cardW,
                                              height: 190))
                    }
                    var line = y + 196
                    func cap(_ s: String, size: CGFloat,
                             weight: UIFont.Weight,
                             color: UIColor = .black) {
                        s.draw(in: CGRect(x: x, y: line,
                                          width: cardW,
                                          height: size + 4),
                               withAttributes: [
                                .font: UIFont.systemFont(
                                    ofSize: size, weight: weight),
                                .foregroundColor: color,
                               ])
                        line += size + 5
                    }
                    cap("\(shot.tag) · "
                        + shot.at.formatted(date: .abbreviated,
                                            time: .shortened),
                        size: 10, weight: .semibold)
                    if !shot.note.isEmpty {
                        cap(shot.note, size: 9, weight: .regular,
                            color: .darkGray)
                    }
                    col += 1
                    if col == 2 {
                        col = 0
                        y += cardH
                    }
                }
            }
        } catch {
            return nil
        }
        return url
    }

    /// Move-in vs move-out, one row per checklist tag: the "that
    /// scratch is in the day-one photo" document.
    static func conditionComparePDF(before: ConditionRecord,
                                    after: ConditionRecord) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        var tags: [String] = []
        for shot in before.shots + after.shots
        where !tags.contains(shot.tag) {
            tags.append(shot.tag)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(safe(before.roomName))-condition-compare.pdf")
        do {
            try renderer.writePDF(to: url) { pdf in
                pdf.beginPage()
                var y = margin
                func text(_ s: String, size: CGFloat,
                          weight: UIFont.Weight,
                          color: UIColor = .black) {
                    s.draw(at: CGPoint(x: margin, y: y),
                           withAttributes: [
                            .font: UIFont.systemFont(ofSize: size,
                                                     weight: weight),
                            .foregroundColor: color,
                           ])
                    y += size + 8
                }
                text("\(before.roomName) — condition comparison",
                     size: 22, weight: .bold)
                text("Left: \(before.kindTitle), "
                     + before.startedAt.formatted(date: .long,
                                                  time: .omitted)
                     + (before.isSealed ? " (sealed)" : "")
                     + "  ·  Right: \(after.kindTitle), "
                     + after.startedAt.formatted(date: .long,
                                                 time: .omitted)
                     + (after.isSealed ? " (sealed)" : ""),
                     size: 10, weight: .regular, color: .darkGray)
                y += 6

                let colW = (page.width - margin * 2 - 12) / 2
                let imgH: CGFloat = 170
                for tag in tags {
                    let left = before.shots.filter { $0.tag == tag }
                        .sorted { $0.at < $1.at }
                    let right = after.shots.filter { $0.tag == tag }
                        .sorted { $0.at < $1.at }
                    let rows = max(left.count, right.count, 1)
                    let blockH = CGFloat(rows) * (imgH + 26) + 22
                    if y + min(blockH, imgH + 48) > page.height - margin {
                        pdf.beginPage()
                        y = margin
                    }
                    text(tag, size: 13, weight: .semibold)
                    for i in 0..<rows {
                        if y + imgH + 26 > page.height - margin {
                            pdf.beginPage()
                            y = margin
                        }
                        func draw(_ shots: [ConditionShot],
                                  record: ConditionRecord,
                                  x: CGFloat) {
                            guard i < shots.count else {
                                "no photo".draw(
                                    at: CGPoint(x: x + 8, y: y + 8),
                                    withAttributes: [
                                        .font: UIFont.systemFont(
                                            ofSize: 9),
                                        .foregroundColor: UIColor.gray,
                                    ])
                                return
                            }
                            let shot = shots[i]
                            if let image = Store.loadConditionShot(
                                recordID: record.id,
                                shotID: shot.id) {
                                image.draw(in: CGRect(
                                    x: x, y: y, width: colW,
                                    height: imgH))
                            }
                            let caption = shot.note.isEmpty
                                ? shot.at.formatted(date: .abbreviated,
                                                    time: .shortened)
                                : shot.note
                            caption.draw(
                                at: CGPoint(x: x, y: y + imgH + 3),
                                withAttributes: [
                                    .font: UIFont.systemFont(
                                        ofSize: 8),
                                    .foregroundColor:
                                        UIColor.darkGray,
                                ])
                        }
                        draw(left, record: before, x: margin)
                        draw(right, record: after,
                             x: margin + colW + 12)
                        y += imgH + 26
                    }
                    y += 8
                }
            }
        } catch {
            return nil
        }
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
