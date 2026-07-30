// The insurance assistant: one screen that answers "if this building
// burned down tomorrow, could I prove what I owned?" Totals, the gaps
// in the paper trail, warranty status — all passive, surfaced when YOU
// open it (house rule: no nagging, ever) — and the one-tap claim PDF.
import SwiftData
import SwiftUI

struct InsuranceView: View {
    @Query private var rooms: [Room]
    @Query private var things: [Thing]
    @Query private var spots: [StorageSpot]
    @ObservedObject private var ai = AIService.shared
    @State private var shareURL: URL?

    private var valued: [Thing] { things.filter { $0.price != nil } }
    private var total: Double {
        valued.compactMap(\.price).reduce(0, +)
    }
    private var missingReceipt: [Thing] {
        valued.filter { !Store.hasReceipt($0.id) }
    }
    private var missingValue: [Thing] {
        things.filter { $0.price == nil }
    }
    private var underWarranty: [Thing] {
        things.filter { $0.warrantyUntil != nil }
            .sorted {
                ($0.warrantyUntil ?? .distantPast)
                    < ($1.warrantyUntil ?? .distantPast)
            }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    InsureWizardView()
                } label: {
                    HStack(spacing: 12) {
                        ThreadLogoView()
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Insure my home — step by step")
                                .font(.callout.weight(.semibold))
                            Text("Scan → identify → serials & "
                                 + "receipts → claim PDF + backup")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                HStack(spacing: 0) {
                    stat(currency(total), "documented value")
                    Divider().frame(height: 34)
                    stat("\(valued.count)/\(things.count)",
                         "items valued")
                    Divider().frame(height: 34)
                    stat("\(things.count - missingReceipt.count - missingValue.count)",
                         "with receipts")
                }
            }

            Section {
                Button {
                    shareURL = Reports.insurancePDF(
                        rooms: rooms, things: things, spots: spots)
                } label: {
                    Label("Export claim-ready PDF",
                          systemImage: "doc.badge.arrow.up")
                }
                .disabled(things.isEmpty)
            } footer: {
                Text("Every item with photo, location, size, serial, "
                     + "value, receipt and warranty status — the "
                     + "document an adjuster asks for.")
            }

            if !missingValue.isEmpty || !missingReceipt.isEmpty {
                Section("Gaps worth closing") {
                    if !missingValue.isEmpty {
                        NavigationLink {
                            GapListView(
                                title: "No value yet",
                                things: missingValue,
                                hint: ai.isConfigured
                                    ? "Open one and tap Estimate value"
                                        + " with AI."
                                    : "Open one and type what it's "
                                        + "worth — or add a free AI key"
                                        + " in Settings to estimate "
                                        + "automatically.")
                        } label: {
                            row("tag.slash",
                                "\(missingValue.count) items have no "
                                + "value")
                        }
                    }
                    if !missingReceipt.isEmpty {
                        NavigationLink {
                            GapListView(
                                title: "Valued, no receipt",
                                things: missingReceipt,
                                hint: "A receipt photo turns an "
                                    + "estimate into proof.")
                        } label: {
                            row("doc.text.magnifyingglass",
                                "\(missingReceipt.count) valued items "
                                + "lack a receipt")
                        }
                    }
                }
            }

            if !underWarranty.isEmpty {
                Section("Warranties") {
                    ForEach(underWarranty) { thing in
                        HStack(spacing: 12) {
                            ThingThumbnail(thingID: thing.id)
                                .frame(width: 38, height: 38)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(thing.displayName)
                                    .font(.callout)
                                if let until = thing.warrantyUntil {
                                    Text(until > Date()
                                         ? "until \(until.formatted(date: .abbreviated, time: .omitted))"
                                         : "expired \(until.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(
                                            until > Date()
                                            ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(
                                                Color.brandDotCool))
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Insurance")
        .brandBackground()
        .sheet(item: $shareURL) { url in
            ShareURLSheet(url: url)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold().monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color.brandThread)
        }
    }

    private func currency(_ v: Double) -> String {
        v.formatted(.currency(
            code: Locale.current.currency?.identifier ?? "USD")
            .precision(.fractionLength(0)))
    }
}

struct GapListView: View {
    let title: String
    let things: [Thing]
    let hint: String
    @Query private var spots: [StorageSpot]

    var body: some View {
        List {
            Section {
                ForEach(things) { thing in
                    ThingRow(thing: thing, showRoom: true,
                             spotName: thing.storageID.flatMap {
                                 id in spots.first {
                                     $0.id == id
                                 }?.name
                             })
                }
            } footer: {
                Text(hint)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
