// The spine of the product: "insure my home", start to finish.
// Four steps — scan, identify, document the valuable stuff, export —
// each one reusing machinery that already exists. The wizard's job is
// sequencing, not features: a person who has never read a manual walks
// out with a claim-ready PDF and an off-device backup.
import SwiftData
import SwiftUI

struct InsureWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var rooms: [Room]
    @Query(sort: \Thing.lastSeenAt, order: .reverse)
    private var things: [Thing]
    @Query private var spots: [StorageSpot]
    @Query private var records: [ConditionRecord]
    @ObservedObject private var ai = AIService.shared
    @State private var step = 0
    @State private var running = false
    @State private var identified: Int?
    @State private var problem: String?
    @State private var shareURL: URL?

    private var unidentified: [Thing] {
        things.filter { !$0.userNamed && $0.aiSummary == nil }
    }

    /// The dossier list: most valuable first, missing paper trail.
    private var needsDossier: [Thing] {
        things
            .filter {
                $0.price != nil && ($0.serialNumber == nil
                    || !Store.hasReceipt($0.id))
            }
            .sorted { ($0.price ?? 0) > ($1.price ?? 0) }
            .prefix(10)
            .map { $0 }
    }

    private var totalValue: Double {
        things.compactMap(\.price).reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Group {
                switch step {
                case 0: scanStep
                case 1: identifyStep
                case 2: dossierStep
                default: exportStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .top)
            .transition(.opacity)
            footerButtons
        }
        .brandBackground()
        .navigationTitle("Insure my home")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { url in
            ShareURLSheet(url: url)
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    // ---- chrome ----------------------------------------------------------

    private var stepHeader: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.brandThread
                                    : Color.white.opacity(0.15))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private var footerButtons: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if step < 3 {
                Button(step == 1 && !unidentified.isEmpty
                       ? "Skip for now" : "Next") {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func stepTitle(_ title: String,
                           _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold())
            Text(subtitle).font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 18)
    }

    // ---- step 1: rooms ---------------------------------------------------

    private var scanStep: some View {
        VStack(spacing: 14) {
            stepTitle("1 · Scan your rooms",
                      "Each scan captures the room and the things in "
                      + "it. Rough is fine — photos are what matter.")
            List {
                ForEach(rooms) { room in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(room.things.isEmpty
                                  ? Color.white.opacity(0.2)
                                  : Color.brandDot)
                            .frame(width: 10, height: 10)
                        Text(room.name)
                        Spacer()
                        Text("\(room.things.count) things · "
                             + String(format: "%.0f m²",
                                      room.floorAreaM2))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if rooms.isEmpty {
                    Text("No rooms yet — close this and scan from "
                         + "the Scan tab first.")
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    // ---- step 2: identify ------------------------------------------------

    private var identifyStep: some View {
        VStack(spacing: 14) {
            stepTitle("2 · Let the AI identify everything",
                      unidentified.isEmpty
                      ? "All \(things.count) items are identified."
                      : "\(unidentified.count) items don't have real "
                        + "names yet. One pass gives them names, "
                        + "descriptions and replacement values.")
            if unidentified.isEmpty {
                HStack(spacing: 8) {
                    SuccessDot(size: 16)
                    Text("Nothing left to identify")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 30)
            } else {
                Button {
                    runIdentify()
                } label: {
                    HStack {
                        Label("Identify \(unidentified.count) items",
                              systemImage: "sparkles")
                        if running { ThreadLoadingView(size: 24) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ai.isConfigured || running)
                .padding(.horizontal)
                if !ai.isConfigured {
                    Text("Needs the free AI key — Settings → AI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if running, let status = ai.batchStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let identified {
                HStack(spacing: 8) {
                    SuccessDot(size: 14)
                    Text("\(identified) items identified")
                        .font(.callout)
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Color.brandDotCool)
                    .padding(.horizontal)
            }
            Spacer()
        }
    }

    private func runIdentify() {
        running = true
        problem = nil
        Task {
            defer { running = false }
            do {
                identified = try await applyBatchIdentification(
                    unidentified, ai: ai)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // ---- step 3: dossier -------------------------------------------------

    private var dossierStep: some View {
        VStack(spacing: 14) {
            stepTitle("3 · Document the valuable stuff",
                      needsDossier.isEmpty
                      ? "Your valued items all have serials and "
                        + "receipts. Rare air."
                      : "Your most valuable items, missing a serial "
                        + "or a receipt. Each one you complete makes "
                        + "the claim harder to dispute.")
            List {
                ForEach(needsDossier) { thing in
                    NavigationLink {
                        ThingDetailView(thing: thing,
                                        activeRoom: .constant(nil),
                                        selectedTab: .constant(4))
                    } label: {
                        HStack(spacing: 12) {
                            ThingThumbnail(thingID: thing.id)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(
                                    cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thing.displayName)
                                    .font(.callout)
                                if let price = thing.price {
                                    Text(price.formatted(.currency(
                                        code: Locale.current.currency?
                                            .identifier ?? "USD")
                                        .precision(
                                            .fractionLength(0))))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "number.square")
                                    .foregroundStyle(
                                        thing.serialNumber != nil
                                        ? Color.brandDot
                                        : Color.white.opacity(0.25))
                                Image(systemName: "doc.text.image")
                                    .foregroundStyle(
                                        Store.hasReceipt(thing.id)
                                        ? Color.brandDot
                                        : Color.white.opacity(0.25))
                            }
                            .font(.footnote)
                        }
                    }
                }
                if needsDossier.isEmpty {
                    HStack(spacing: 8) {
                        SuccessDot(size: 14)
                        Text("Nothing missing")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    // ---- step 4: export --------------------------------------------------

    private var exportStep: some View {
        VStack(spacing: 18) {
            stepTitle("4 · Export the proof",
                      "The claim PDF for the adjuster, and a full "
                      + "backup for somewhere the fire can't reach.")
            HStack(spacing: 0) {
                stat("\(things.count)", "items")
                Divider().frame(height: 34)
                stat(totalValue.formatted(.currency(
                    code: Locale.current.currency?.identifier ?? "USD")
                    .precision(.fractionLength(0))), "documented")
                Divider().frame(height: 34)
                stat("\(records.filter(\.isSealed).count)",
                     "sealed records")
            }
            .padding(.vertical, 6)
            .background(.thinMaterial,
                        in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)

            Button {
                shareURL = Reports.insurancePDF(
                    rooms: rooms, things: things, spots: spots)
            } label: {
                Label("Claim-ready PDF",
                      systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Button {
                shareURL = Backup.fullBackup(
                    rooms: rooms, things: things, spots: spots,
                    records: records)
            } label: {
                Label("Back up everything (.zip)",
                      systemImage: "externaldrive.badge.icloud")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            Text("Save the backup to iCloud Drive, AirDrop it to a "
                 + "computer, or email it to yourself — photos and "
                 + "data, one file, opens anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
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
}
