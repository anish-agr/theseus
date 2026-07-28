// Settings, diagnostics and the honest data controls.
import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var rooms: [Room]
    @Query private var things: [Thing]
    @StateObject private var embedder = EmbedderManager.shared
    @ObservedObject private var ai = AIService.shared
    @AppStorage("aiAutoName") private var aiAutoName = false
    @State private var keyDraft = ""
    @State private var aiTestState: AITestState = .idle
    @State private var modelChoices: [String] = []
    @State private var loadingModels = false
    @State private var confirmWipe = false
    @State private var showShare = false

    enum AITestState: Equatable {
        case idle, testing, ok
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                aiSection

                Section("Your data") {
                    LabeledContent("Rooms", value: "\(rooms.count)")
                    LabeledContent("Things", value: "\(things.count)")
                    LabeledContent("On disk", value: diskUsage)
                    ForEach(Store.bytesBreakdown(), id: \.label) {
                        bucket in
                        if bucket.bytes > 0 {
                            LabeledContent(bucket.label) {
                                Text(ByteCountFormatter.string(
                                    fromByteCount: bucket.bytes,
                                    countStyle: .file))
                                .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    Text("Everything is stored on this iPhone. No "
                         + "account, no server, no upload.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Natural-language search") {
                    switch embedder.state {
                    case .ready:
                        HStack(spacing: 8) {
                            Circle().fill(Color.brandDot)
                                .frame(width: 12, height: 12)
                            Text("Installed")
                        }
                    case .notInstalled:
                        Text("Search matches names, labels, text read "
                             + "off objects, synonyms — and, with AI "
                             + "naming on, the AI's one-line "
                             + "description of each item, so \"blue "
                             + "ceramic mug\" finds the mug.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("An on-device image model (search by "
                             + "photo meaning, no AI key) lands in a "
                             + "later build.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    case .downloading(let p):
                        ProgressView(value: p)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Scanning") {
                    Toggle("Hold-to-save (dwell) capture",
                           isOn: dwellBinding)
                    Text("Off means only the shutter button and voice "
                         + "save objects — the ring never fires on "
                         + "its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    Toggle("Record a trace", isOn: Binding(
                        get: { engine.recording },
                        set: { _ in engine.toggleRecording() }))
                    Text("Traces replay in the desktop viewer — this is "
                         + "how on-device behaviour gets debugged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !engine.recording, engine.traceJSONL() != nil {
                        Button {
                            showShare = true
                        } label: {
                            Label("Share last trace",
                                  systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmWipe = true
                    } label: {
                        Label("Delete everything", systemImage: "trash")
                    }
                } footer: {
                    Text("Removes every room, object, photo and map from "
                         + "this device. This cannot be undone.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete everything?", isPresented: $confirmWipe) {
                Button("Delete", role: .destructive, action: wipe)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every room, object and photo will be removed from "
                     + "this iPhone.")
            }
            .sheet(isPresented: $showShare) {
                if let text = engine.traceJSONL() {
                    ShareSheet(text: text)
                }
            }
        }
    }

    // ---- AI --------------------------------------------------------------

    private var aiSection: some View {
        Section {
            Picker("Provider", selection: $ai.kindRaw) {
                ForEach(AIProviderKind.allCases) { kind in
                    Text(kind.title).tag(kind.rawValue)
                }
            }
            .onChange(of: ai.kindRaw) { _, _ in
                keyDraft = KeyStore.load(account: ai.kind.rawValue) ?? ""
                aiTestState = .idle
            }
            SecureField("API key", text: $keyDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: keyDraft) { _, value in
                    ai.setKey(value)
                    aiTestState = .idle
                }
            if ai.kind == .custom {
                TextField("Endpoint — https://…/v1",
                          text: $ai.customEndpoint)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            TextField("Model — default \(ai.kind.defaultModel)",
                      text: $ai.modelOverride)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if ai.kind == .gemini {
                Button {
                    loadModelChoices()
                } label: {
                    HStack {
                        Text("Pick from this key's models")
                        Spacer()
                        if loadingModels {
                            ThreadLoadingView(size: 22)
                        }
                    }
                }
                .disabled(!ai.isConfigured || loadingModels)
            }
            HStack {
                Button("Test") {
                    aiTestState = .testing
                    Task {
                        do {
                            try await ai.ping()
                            aiTestState = .ok
                        } catch {
                            aiTestState = .failed(
                                error.localizedDescription)
                        }
                    }
                }
                .disabled(!ai.isConfigured || aiTestState == .testing)
                Spacer()
                switch aiTestState {
                case .idle:
                    EmptyView()
                case .testing:
                    ThreadLoadingView(size: 26)
                case .ok:
                    HStack(spacing: 6) {
                        SuccessDot(size: 14)
                        Text("Connected").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    Circle().fill(Color.brandDotCool)
                        .frame(width: 14, height: 14)
                }
            }
            if case .failed(let message) = aiTestState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Color.brandDotCool)
            }
            Toggle("Live mode: AI names each capture mid-scan",
                   isOn: $aiAutoName)
            Text("Off (default): scan fast, then identify everything "
                 + "at once afterwards — Stuff → ✨.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI")
        } footer: {
            if ai.kind == .gemini {
                Text("Free: sign in at aistudio.google.com/apikey — no "
                     + "card needed — and paste the key here. Unlocks "
                     + "box itemizing, value estimates and \"what is "
                     + "this\". Photos go only to the provider you "
                     + "chose, and only when you tap an AI button — "
                     + "or, with the toggle on, when a capture needs "
                     + "a name the phone can't work out itself.")
            } else {
                Text("Photos go only to the provider you chose, and "
                     + "only when you tap an AI button — or, with the "
                     + "toggle on, when a capture needs a name the "
                     + "phone can't work out itself.")
            }
        }
        .onAppear {
            keyDraft = KeyStore.load(account: ai.kind.rawValue) ?? ""
        }
        .confirmationDialog(
            "Models this key can use (best first)",
            isPresented: Binding(
                get: { !modelChoices.isEmpty },
                set: { if !$0 { modelChoices = [] } }),
            titleVisibility: .visible
        ) {
            ForEach(modelChoices.prefix(8), id: \.self) { name in
                Button(name) {
                    ai.modelOverride = name
                    aiTestState = .idle
                    modelChoices = []
                }
            }
            Button("Cancel", role: .cancel) { modelChoices = [] }
        }
    }

    private func loadModelChoices() {
        guard let key = KeyStore.load(account: ai.kind.rawValue),
              !key.isEmpty else { return }
        loadingModels = true
        Task {
            defer { loadingModels = false }
            do {
                modelChoices = try await AIService
                    .discoverGeminiModels(key: key)
            } catch {
                aiTestState = .failed(error.localizedDescription)
            }
        }
    }

    /// Backed by UserDefaults directly because ARSessionManager (not
    /// a view) reads the same key on the frame path.
    private var dwellBinding: Binding<Bool> {
        Binding(
            get: {
                UserDefaults.standard.object(forKey: "dwellCapture")
                    as? Bool ?? true
            },
            set: {
                UserDefaults.standard.set($0, forKey: "dwellCapture")
            })
    }

    private var diskUsage: String {
        let bytes = Store.totalBytes()
        return ByteCountFormatter.string(fromByteCount: bytes,
                                         countStyle: .file)
    }

    private func wipe() {
        for room in rooms { context.delete(room) }
        for thing in things { context.delete(thing) }
        Store.deleteAllBlobs()
        engine.resetForNewRoom()
        dismiss()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-trace.jsonl")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return UIActivityViewController(activityItems: [url],
                                        applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController,
                                context: Context) {}
}
