// Batch identification — field test 3's verdict: don't make the AI
// guess object-by-object mid-scan; capture fast, then sit down and let
// one screen identify EVERYTHING afterwards (several photos per
// request). This is the step that turns a pile of "Unnamed object"
// into an insurance-grade inventory: specific names, descriptions
// (searchable), and replacement values.
import SwiftData
import SwiftUI

struct AIReviewView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Thing.lastSeenAt, order: .reverse)
    private var things: [Thing]
    @ObservedObject private var ai = AIService.shared
    @State private var picked: Set<UUID> = []
    @State private var running = false
    @State private var doneCount: Int?
    @State private var problem: String?
    @State private var seeded = false

    /// Things the cascade never confidently identified: no user name,
    /// no AI pass yet.
    private var candidates: [Thing] {
        things.filter { !$0.userNamed && $0.aiSummary == nil }
    }

    var body: some View {
        List {
            if !ai.isConfigured {
                Section {
                    Label("Add a free AI key in Settings first "
                          + "(Gemini — no card needed).",
                          systemImage: "key")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    identify()
                } label: {
                    HStack {
                        Label(picked.isEmpty
                              ? "Identify with AI"
                              : "Identify \(picked.count) items with AI",
                              systemImage: "sparkles")
                        Spacer()
                        if running { ThreadLoadingView(size: 26) }
                    }
                }
                .disabled(!ai.isConfigured || picked.isEmpty || running)
                if let doneCount {
                    HStack(spacing: 8) {
                        SuccessDot(size: 13)
                        Text("\(doneCount) items identified — names, "
                             + "descriptions and values are in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color.brandDotCool)
                }
            } footer: {
                Text("Photos are sent in batches to the provider you "
                     + "chose. Uncheck anything you'd rather keep "
                     + "private. A name you typed yourself is never "
                     + "overwritten.")
            }

            if candidates.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        SuccessDot(size: 13)
                        Text("Everything is identified — nothing "
                             + "needs the AI right now.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Waiting to be identified — "
                        + "\(candidates.count)") {
                    ForEach(candidates) { thing in
                        Button {
                            if picked.contains(thing.id) {
                                picked.remove(thing.id)
                            } else {
                                picked.insert(thing.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName:
                                        picked.contains(thing.id)
                                      ? "circle.inset.filled"
                                      : "circle")
                                    .foregroundStyle(Color.brandThread)
                                ThingThumbnail(thingID: thing.id)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(
                                        cornerRadius: 8))
                                VStack(alignment: .leading,
                                       spacing: 2) {
                                    Text(thing.displayName)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                    if let room = thing.room {
                                        Text(room.name)
                                            .font(.caption2)
                                            .foregroundStyle(
                                                .secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Identify with AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !seeded {
                seeded = true
                picked = Set(candidates.map(\.id))
            }
        }
    }

    private func identify() {
        let targets = candidates.filter { picked.contains($0.id) }
        let items: [(id: UUID, image: UIImage)] = targets.compactMap {
            thing in
            Store.loadThumb(thing.id).map { (thing.id, $0) }
        }
        guard !items.isEmpty else {
            problem = "These items have no photos to send."
            return
        }
        running = true
        problem = nil
        doneCount = nil
        Task {
            defer { running = false }
            do {
                let results = try await ai.identifyBatch(items)
                var applied = 0
                for thing in targets {
                    guard let idn = results[thing.id] else { continue }
                    if !thing.userNamed {
                        thing.displayName = idn.name
                        thing.autoLabel = idn.name
                        thing.autoConfidence = max(
                            thing.autoConfidence, 0.75)
                    }
                    thing.category = idn.category
                    thing.aiSummary = idn.summary
                    if thing.price == nil,
                       let value = idn.estimatedValue {
                        thing.price = value
                        thing.priceSource = "ai"
                    }
                    SpotlightIndex.index(thing)
                    applied += 1
                }
                doneCount = applied
                picked = []
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
