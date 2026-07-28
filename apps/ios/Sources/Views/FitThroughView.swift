// "Will this couch make the turn?" — the corridor-width solver with a
// number attached. Answers with the narrowest point on the route, not
// just yes/no, because the useful part is knowing WHERE it pinches.
import NavCore
import SwiftUI

struct FitThroughView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.dismiss) private var dismiss
    let room: Room
    @State private var widthCm: Double = 80
    @State private var target: Thing?
    @State private var result: (ok: Bool, pinch: Vec?, narrowest: Double)?

    var body: some View {
        NavigationStack {
            Form {
                Section("How wide is it?") {
                    HStack {
                        Slider(value: $widthCm, in: 20...200, step: 5)
                        Text("\(Int(widthCm)) cm")
                            .monospacedDigit().frame(width: 64)
                    }
                }
                Section("Carry it to") {
                    Picker("Destination", selection: $target) {
                        Text("Pick a thing").tag(nil as Thing?)
                        ForEach(room.things.filter(\.promoted)) { thing in
                            Text(thing.displayName).tag(thing as Thing?)
                        }
                    }
                }
                Section {
                    Button("Check the route") { check() }
                        .disabled(target == nil)
                }
                if let result {
                    Section("Verdict") {
                        Label(result.ok ? "It fits" : "It will not fit",
                              systemImage: result.ok
                              ? "checkmark.circle.fill"
                              : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                            .font(.headline)
                        LabeledContent(
                            "Narrowest point",
                            value: String(format: "%.2f m",
                                          result.narrowest))
                        if let pinch = result.pinch {
                            LabeledContent(
                                "Pinch located at",
                                value: String(format: "%.1f, %.1f m",
                                              pinch.x, pinch.y))
                        }
                        Text("Measured as a swept disc, which is "
                             + "conservative for long objects cornering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Will it fit?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func check() {
        guard let target else { return }
        result = engine.fitCheck(
            from: Vec(engine.pose.x, engine.pose.y),
            to: Vec(target.positionX, target.positionY),
            widthM: widthCm / 100)
    }
}
