// The cloud brain, strictly opt-in. On-device Vision covers labels,
// OCR, barcodes and re-identification for free and offline; what it
// cannot do is *understand* — itemize an open box, estimate replacement
// value, actually answer "what is this". That takes a hosted vision
// model, so this file speaks three dialects behind one interface:
//
//   gemini    — Google AI Studio keys have a genuinely free tier
//               (no card), which is why it is the recommended default.
//   anthropic — best answers, pay-per-use.
//   custom    — any OpenAI-compatible /chat/completions endpoint
//               (Groq, OpenRouter, a home server…), free tiers exist.
//
// Privacy contract (REQUIREMENTS NFR-1): a photo leaves the device ONLY
// when the user taps an explicitly-AI button; nothing is ever sent in
// the background. Keys live in the Keychain, never in defaults, and are
// sent as headers, never in URLs.
import Foundation
import Security
import SwiftUI
import UIKit

// ---- keychain --------------------------------------------------------------

enum KeyStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.anish.theseus.ai",
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// ---- results ---------------------------------------------------------------

struct AIItem: Identifiable {
    let id = UUID()
    var name: String
    var category: String
    var estimatedValue: Double?
    /// 0…1, the model's own certainty.
    var confidence: Double?
    /// Which of the submitted photos it was seen in (0-based).
    var photoIndex: Int = 0
    /// Where in that photo, normalized 0…1 (x, y, w, h, top-left
    /// origin) — lets one shelf photo become per-item cropped thumbs.
    var box: CGRect?
}

struct AIIdentification {
    var name: String
    var category: String
    var summary: String
    var estimatedValue: Double?
    var valueNote: String
    var confidence: Double?
}

enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badReply(String)
    /// The model burned the whole output budget thinking and returned
    /// empty content (finishReason MAX_TOKENS) — retryable with a
    /// bigger budget.
    case truncated

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add an AI key in Settings first — the free "
                + "Gemini tier works."
        case .http(429, _):
            return "The free tier's per-minute limit — wait a "
                + "minute and try again; nothing is broken."
        case .http(let code, let body):
            return "AI request failed (\(code)): \(body.prefix(160))"
        case .badReply(let text):
            return "Couldn't read the AI's reply: \(text.prefix(120))"
        case .truncated:
            return "The model ran out of room before answering."
        }
    }
}

// ---- the service -----------------------------------------------------------

enum AIProviderKind: String, CaseIterable, Identifiable {
    case gemini, anthropic, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Gemini (free tier)"
        case .anthropic: return "Claude (Anthropic)"
        case .custom: return "Custom endpoint"
        }
    }

    var defaultModel: String {
        switch self {
        // Google retires model ids on a schedule (2.5-flash died for
        // new keys mid-2026); a 404 triggers auto-discovery below, so
        // this default only has to be right-ish, not eternal.
        case .gemini: return "gemini-3.6-flash"
        case .anthropic: return "claude-haiku-4-5"
        case .custom: return ""
        }
    }
}

@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    @AppStorage("aiProviderKind") var kindRaw
        = AIProviderKind.gemini.rawValue
    @AppStorage("aiModelOverride") var modelOverride = ""
    @AppStorage("aiCustomEndpoint") var customEndpoint = ""
    /// Model name learned from Google's own list after a 404 — the
    /// self-healing answer to Google retiring model ids under us.
    @AppStorage("aiGeminiResolved") var geminiResolved = ""
    /// Bumped so views re-read isConfigured after a key edit.
    @Published var keyEdition = 0
    /// Live progress line for batch work ("Batch 2 of 3…", "Rate
    /// limit — waiting 20 s…") so a long identify never looks dead.
    @Published var batchStatus: String?

    var kind: AIProviderKind {
        AIProviderKind(rawValue: kindRaw) ?? .gemini
    }

    var apiKey: String? {
        let k = KeyStore.load(account: kind.rawValue)
        return (k?.isEmpty ?? true) ? nil : k
    }

    var isConfigured: Bool { apiKey != nil }

    var model: String {
        if !modelOverride.isEmpty { return modelOverride }
        if kind == .gemini, !geminiResolved.isEmpty {
            return geminiResolved
        }
        return kind.defaultModel
    }

    func setKey(_ value: String) {
        KeyStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines),
                      account: kind.rawValue)
        keyEdition += 1
    }

    private var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    /// URLSession.shared allows a request to dribble along for days;
    /// on flaky wifi that reads as "it just never loads". Bound it:
    /// 30 s of silence or 150 s total and the call fails loudly, which
    /// the retry loop (or the user) can act on.
    private static let http: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 150
        return URLSession(configuration: config)
    }()

    // ---- the three product calls ----------------------------------------

    /// "What is this?" — lens, unknown objects, voice.
    func identify(image: UIImage, hint: String?) async throws
        -> AIIdentification {
        var prompt = """
        Identify the main object in this photo from inside a home. \
        Reply with ONLY strict JSON, no prose, exactly these keys: \
        {"name": "short object name a person would say", \
        "category": "one or two words", \
        "summary": "one sentence; mention brand/model if visible", \
        "estimated_value_\(currencyCode.lowercased())": number or null \
        (typical replacement value, used, \(currencyCode)), \
        "value_note": "very short basis for the estimate"}
        """
        if let hint, !hint.isEmpty {
            prompt += "\nContext that may help: \(hint)"
        }
        prompt += "\nAlso include \"confidence\": number 0-1, how "
            + "sure you are."
        let text = try await visionCall(prompt: prompt, image: image,
                                        maxTokens: 1000)
        guard let obj = Self.jsonObject(in: text) else {
            throw AIError.badReply(text)
        }
        return AIIdentification(
            name: (obj["name"] as? String) ?? "Object",
            category: (obj["category"] as? String) ?? "object",
            summary: (obj["summary"] as? String) ?? "",
            estimatedValue: Self.number(
                obj["estimated_value_\(currencyCode.lowercased())"]),
            valueNote: (obj["value_note"] as? String) ?? "",
            confidence: Self.number(obj["confidence"]))
    }

    /// Photograph an open box/shelf (several angles allowed) → the
    /// contents, itemized, each with a location box so a crowded
    /// shelf photo becomes per-item cropped thumbnails.
    func itemizeBox(images: [UIImage]) async throws -> [AIItem] {
        defer { batchStatus = nil }
        batchStatus = images.count > 1
            ? "Reading \(images.count) photos…"
            : "Reading the photo…"
        let prompt = """
        These \(images.count) photo(s) show the contents of one \
        storage container or shelf. List every distinct physical \
        item you can actually see (an item visible in two photos is \
        ONE item). Reply with ONLY a strict JSON array, no prose: \
        [{"name": "short specific item name", \
        "category": "one or two words", \
        "estimated_value_\(currencyCode.lowercased())": number or \
        null (typical used replacement value, \(currencyCode)), \
        "confidence": number 0-1, \
        "photo": photo number this item is best seen in (1-based), \
        "box_2d": [ymin, xmin, ymax, xmax] integers 0-1000, the \
        item's bounding box in that photo}] \
        Maximum 30 items. Skip the container itself.
        """
        let text = try await visionCall(prompt: prompt, images: images,
                                        maxTokens: 4000)
        guard let arr = Self.jsonArray(in: text) else {
            throw AIError.badReply(text)
        }
        return arr.compactMap { entry in
            guard let name = entry["name"] as? String,
                  !name.isEmpty else { return nil }
            var box: CGRect?
            if let raw = entry["box_2d"] as? [Any], raw.count == 4 {
                let vals = raw.compactMap { Self.anyNumber($0) }
                if vals.count == 4 {
                    // model convention [ymin, xmin, ymax, xmax]/1000
                    let y0 = vals[0] / 1000, x0 = vals[1] / 1000
                    let y1 = vals[2] / 1000, x1 = vals[3] / 1000
                    if x1 > x0, y1 > y0 {
                        box = CGRect(x: x0, y: y0,
                                     width: x1 - x0, height: y1 - y0)
                    }
                }
            }
            let photo = (Self.anyNumber(entry["photo"]).map {
                Int($0) - 1
            }) ?? 0
            return AIItem(
                name: name,
                category: (entry["category"] as? String) ?? "object",
                estimatedValue: Self.number(
                    entry["estimated_value_\(currencyCode.lowercased())"]),
                confidence: Self.anyNumber(entry["confidence"]),
                photoIndex: max(0, min(images.count - 1, photo)),
                box: box)
        }
    }

    /// Replacement-value estimate for one already-saved thing.
    func estimateValue(image: UIImage?, name: String,
                       details: String) async throws
        -> (value: Double, note: String) {
        defer { batchStatus = nil }
        batchStatus = "Estimating…"
        let prompt = """
        Estimate the replacement value of this item for a home \
        inventory, in \(currencyCode), as typically bought used/current \
        condition. Item: "\(name)". \(details) \
        Reply with ONLY strict JSON: \
        {"value_\(currencyCode.lowercased())": number, \
        "note": "short basis, one clause"}
        """
        let text = try await visionCall(prompt: prompt, image: image,
                                        maxTokens: 600)
        guard let obj = Self.jsonObject(in: text),
              let value = Self.number(
                obj["value_\(currencyCode.lowercased())"]) else {
            throw AIError.badReply(text)
        }
        return (value, (obj["note"] as? String) ?? "")
    }

    /// Batch mode — field test 3's "figure it all out afterwards":
    /// several photos per request, one JSON array back. Returns
    /// whatever it could identify, keyed by the caller's ids.
    func identifyBatch(_ items: [(id: UUID, image: UIImage)])
        async throws -> [UUID: AIIdentification] {
        var out: [UUID: AIIdentification] = [:]
        var lastFailure: Error?
        defer { batchStatus = nil }
        // 6 photos per call: well inside every provider's limits and
        // keeps one bad response from sinking the whole batch
        let chunks = stride(from: 0, to: items.count, by: 6).map {
            Array(items[$0..<min($0 + 6, items.count)])
        }
        for (index, chunk) in chunks.enumerated() {
            // a single-chunk run used to show NOTHING for the whole
            // 10-30 s call — always say what's happening
            batchStatus = chunks.count > 1
                ? "Batch \(index + 1) of \(chunks.count) — "
                    + "\(chunk.count) photos…"
                : "Identifying \(chunk.count) "
                    + "thing\(chunk.count == 1 ? "" : "s")…"
            // pace the free tier: back-to-back requests trip the
            // per-minute cap (field test 5's 429)
            if index > 0 {
                try await Task.sleep(for: .seconds(8))
            }
            let prompt = """
            You will be shown \(chunk.count) photos of household \
            objects, in order. Identify each one for a home \
            inventory. Reply with ONLY a strict JSON array of exactly \
            \(chunk.count) objects, one per photo, same order, each: \
            {"name": "specific short name a person would say — never \
            vague words like clothing, container or textile; include \
            brand/model if visible", "category": "one or two words", \
            "summary": "one sentence describing it (color, brand, \
            distinguishing details)", \
            "estimated_value_\(currencyCode.lowercased())": number or \
            null (typical used replacement value, \(currencyCode)), \
            "value_note": "very short basis", \
            "confidence": number 0-1, how sure you are}
            """
            do {
                let text = try await visionCall(
                    prompt: prompt,
                    images: chunk.map(\.image), maxTokens: 4000)
                guard let arr = Self.jsonArray(in: text) else {
                    throw AIError.badReply(text)
                }
                for (i, obj) in arr.enumerated()
                    where i < chunk.count {
                    out[chunk[i].id] = AIIdentification(
                        name: (obj["name"] as? String) ?? "Object",
                        category: (obj["category"] as? String)
                            ?? "object",
                        summary: (obj["summary"] as? String) ?? "",
                        estimatedValue: Self.number(
                            obj["estimated_value_\(currencyCode.lowercased())"]),
                        valueNote: (obj["value_note"] as? String)
                            ?? "",
                        confidence: Self.anyNumber(obj["confidence"]))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // a chunk that failed after all its retries must not
                // throw away the chunks that already succeeded — keep
                // going, apply what worked, surface the error only if
                // NOTHING worked (the rest stays queued for next tap)
                lastFailure = error
            }
        }
        if out.isEmpty, let lastFailure { throw lastFailure }
        return out
    }

    /// Settings "Test" button: cheapest possible round-trip. The
    /// budget is generous on purpose — thinking models can spend
    /// tokens before the first visible word.
    func ping() async throws {
        _ = try await visionCall(
            prompt: "Reply with exactly the word: ready",
            image: nil, maxTokens: 500)
    }

    // ---- transport -------------------------------------------------------

    private func visionCall(prompt: String, image: UIImage?,
                            maxTokens: Int) async throws -> String {
        try await visionCall(prompt: prompt,
                             images: image.map { [$0] } ?? [],
                             maxTokens: maxTokens)
    }

    private func visionCall(prompt: String, images: [UIImage],
                            maxTokens: Int) async throws -> String {
        guard let key = apiKey else { throw AIError.notConfigured }
        let jpegs = images.compactMap { Self.downscaledJPEG($0) }
        if kind == .gemini {
            return try await geminiCall(key: key, prompt: prompt,
                                        jpegs: jpegs,
                                        maxTokens: maxTokens)
        }
        return try await performCall(key: key, model: model,
                                     prompt: prompt, jpegs: jpegs,
                                     maxTokens: maxTokens)
    }

    /// Gemini's API surface shifts under us, so this call self-heals
    /// every failure the field tests have produced so far:
    ///  · 404 model retired      → list this key's models, retry
    ///  · 400 INVALID_ARGUMENT   → this generation rejects the
    ///    thinking-off knob; drop it, remember, retry
    ///  · MAX_TOKENS             → thinking ate the budget; retry
    ///    with 4× the tokens
    ///  · 429 per-minute cap     → wait Google's own retryDelay
    ///  · 500/503 overloaded     → their capacity, not our bug;
    ///    back off and retry
    ///  · URLError               → wifi hiccup mid-upload; retry once
    private func geminiCall(key: String, prompt: String,
                            jpegs: [Data],
                            maxTokens: Int) async throws -> String {
        var model = self.model
        var tokens = maxTokens
        var thinkingOff = !UserDefaults.standard.bool(
            forKey: "geminiNoThinkingCfg")
        var attempts = 0
        while true {
            attempts += 1
            do {
                let request = try Self.geminiRequest(
                    key: key, model: model, prompt: prompt,
                    jpegs: jpegs, maxTokens: tokens,
                    thinkingOff: thinkingOff)
                return try await send(request)
            } catch AIError.http(404, _) where attempts <= 2 {
                model = try await Self.discoverGeminiModel(key: key)
                geminiResolved = model
            } catch AIError.http(400, let body)
                where thinkingOff && attempts <= 3
                    && body.contains("INVALID_ARGUMENT") {
                thinkingOff = false
                UserDefaults.standard.set(
                    true, forKey: "geminiNoThinkingCfg")
            } catch AIError.truncated where attempts <= 4 {
                tokens = min(tokens * 4, 16000)
            } catch AIError.http(429, let body) where attempts <= 4 {
                // free-tier per-MINUTE cap (field test 5) — Google
                // says how long to wait; wait it and carry on
                let delay = Self.retryDelay(in: body) ?? 20
                guard delay <= 90 else {
                    throw AIError.http(429, body)
                }
                try await pause(delay,
                                "Rate limit — waiting \(Int(delay)) s…")
            } catch AIError.http(let code, _)
                where (code == 500 || code == 503) && attempts <= 4 {
                // "the model is overloaded, try again later" — their
                // capacity blip, not something the user should retype
                try await pause(Double(4 * attempts),
                                "Model is busy — retrying…")
            } catch let error as URLError
                where attempts <= 3 && error.code != .cancelled {
                try await pause(2, "Connection dropped — retrying…")
            }
        }
    }

    /// Wait with a visible reason, then put back whatever progress
    /// line was showing — a mid-batch rate-limit wait must not blank
    /// "Batch 2 of 3…" for the rest of the run.
    private func pause(_ seconds: Double, _ reason: String)
        async throws {
        let resume = batchStatus
        batchStatus = reason
        try await Task.sleep(for: .seconds(seconds))
        batchStatus = resume
    }

    /// Gemini 429 bodies carry RetryInfo like "retryDelay": "34s".
    static func retryDelay(in body: String) -> Double? {
        guard let range = body.range(
            of: #""retryDelay"\s*:\s*"([0-9.]+)s""#,
            options: .regularExpression) else { return nil }
        let span = body[range]
        let digits = span.drop { !$0.isNumber }
            .prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    /// Shared transport: run the request, surface HTTP failures with
    /// their body, hand back the extracted text.
    private func send(_ request: URLRequest) async throws -> String {
        let (data, response) = try await Self.http.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw AIError.http(code, raw)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw AIError.badReply(raw.isEmpty ? "empty" : raw)
        }
        let text = Self.extractText(kind: kind, from: obj) ?? ""
        // MAX_TOKENS means the reply was cut mid-generation. A partial
        // JSON array parses as nothing — surfacing it as "couldn't
        // read the reply" (the old behavior) blames the parser for the
        // budget. Treat any truncation as retryable-with-more-tokens.
        if raw.contains("MAX_TOKENS") {
            throw AIError.truncated
        }
        guard !text.isEmpty else {
            throw AIError.badReply(raw)
        }
        return text
    }

    private func performCall(key: String, model: String,
                             prompt: String, jpegs: [Data],
                             maxTokens: Int) async throws -> String {
        let request: URLRequest
        switch kind {
        case .gemini:
            request = try Self.geminiRequest(
                key: key, model: model, prompt: prompt, jpegs: jpegs,
                maxTokens: maxTokens, thinkingOff: false)
        case .anthropic:
            request = try Self.anthropicRequest(
                key: key, model: model, prompt: prompt, jpegs: jpegs,
                maxTokens: maxTokens)
        case .custom:
            request = try Self.openAIRequest(
                endpoint: customEndpoint, key: key, model: model,
                prompt: prompt, jpegs: jpegs, maxTokens: maxTokens)
        }
        return try await send(request)
    }

    /// GET /v1beta/models with this key: every general-purpose model
    /// that supports generateContent, best first (flash before pro,
    /// GA before preview, newer before older). Feeds both the 404
    /// auto-retry and the Settings model picker.
    static func discoverGeminiModels(key: String) async throws
        -> [String] {
        var req = URLRequest(url: URL(
            string: "https://generativelanguage.googleapis.com"
                + "/v1beta/models?pageSize=200")!)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await http.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            throw AIError.http(code, "couldn't list this key's "
                               + "available Gemini models")
        }
        let names = models.compactMap { entry -> String? in
            guard let name = entry["name"] as? String,
                  let methods = entry["supportedGenerationMethods"]
                    as? [String],
                  methods.contains("generateContent") else {
                return nil
            }
            return name.replacingOccurrences(of: "models/", with: "")
        }
        let special = ["lite", "tts", "audio", "image", "imagen",
                       "veo", "embedding", "thinking", "live", "aqa",
                       "gemma", "learnlm", "exp", "8b"]
        func general(_ n: String) -> Bool {
            special.allSatisfy { !n.contains($0) }
        }
        // newest first; GA names beat previews of the same family
        func newest(_ a: String, _ b: String) -> Bool {
            let ap = a.contains("preview")
            let bp = b.contains("preview")
            if ap != bp { return !ap }
            return a > b
        }
        let flash = names.filter { $0.contains("flash") && general($0) }
            .sorted(by: newest)
        let pro = names.filter {
            $0.contains("pro") && general($0)
        }.sorted(by: newest)
        let rest = names.sorted(by: newest)
        return flash + pro + rest
    }

    /// First choice from the ranked list — used by the 404 retry.
    static func discoverGeminiModel(key: String) async throws
        -> String {
        guard let best = try await discoverGeminiModels(
            key: key).first else {
            throw AIError.badReply(
                "this key has no usable Gemini model")
        }
        return best
    }

    private static func geminiRequest(key: String, model: String,
                                      prompt: String, jpegs: [Data],
                                      maxTokens: Int,
                                      thinkingOff: Bool) throws
        -> URLRequest {
        let url = URL(string: "https://generativelanguage.googleapis.com"
            + "/v1beta/models/\(model):generateContent")!
        var parts: [[String: Any]] = [["text": prompt]]
        for jpeg in jpegs {
            parts.append(["inline_data": [
                "mime_type": "image/jpeg",
                "data": jpeg.base64EncodedString(),
            ]])
        }
        // Thinking models burn output budget on reasoning before the
        // first visible word (empty content + MAX_TOKENS). We ASK for
        // no thinking where supported — but model generations disagree
        // about the knob's name and reject unknown ones with 400, so
        // geminiCall drops it on rejection and retries.
        var generation: [String: Any] = [
            "temperature": 0.2,
            "maxOutputTokens": maxTokens,
        ]
        if thinkingOff {
            generation["thinkingConfig"] = ["thinkingBudget": 0]
        }
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": generation,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // key travels as a header, never a URL query parameter
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func anthropicRequest(key: String, model: String,
                                         prompt: String, jpegs: [Data],
                                         maxTokens: Int) throws
        -> URLRequest {
        var content: [[String: Any]] = []
        for jpeg in jpegs {
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": "image/jpeg",
                "data": jpeg.base64EncodedString(),
            ]])
        }
        content.append(["type": "text", "text": prompt])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]],
        ]
        var req = URLRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",
                     forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func openAIRequest(endpoint: String, key: String,
                                      model: String, prompt: String,
                                      jpegs: [Data],
                                      maxTokens: Int) throws
        -> URLRequest {
        let base = endpoint.hasSuffix("/")
            ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: base + "/chat/completions"),
              url.scheme == "https" else {
            throw AIError.http(0, "Endpoint must be an https URL")
        }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for jpeg in jpegs {
            content.append(["type": "image_url", "image_url": [
                "url": "data:image/jpeg;base64,"
                    + jpeg.base64EncodedString(),
            ]])
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)",
                     forHTTPHeaderField: "Authorization")
        req.setValue("application/json",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func extractText(kind: AIProviderKind,
                                    from obj: [String: Any]) -> String? {
        switch kind {
        case .gemini:
            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"]
                    as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]]
            else { return nil }
            return parts.compactMap { $0["text"] as? String }
                .joined(separator: " ")
        case .anthropic:
            guard let content = obj["content"] as? [[String: Any]]
            else { return nil }
            return content.compactMap { $0["text"] as? String }
                .joined(separator: " ")
        case .custom:
            guard let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"]
                    as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    // ---- lenient JSON out of model prose --------------------------------

    static func jsonObject(in text: String) -> [String: Any]? {
        guard let span = extract(text, open: "{", close: "}"),
              let parsed = try? JSONSerialization.jsonObject(
                with: Data(span.utf8)) else { return nil }
        return parsed as? [String: Any]
    }

    static func jsonArray(in text: String) -> [[String: Any]]? {
        if let span = extract(text, open: "[", close: "]"),
           let parsed = try? JSONSerialization.jsonObject(
            with: Data(span.utf8)),
           let arr = parsed as? [[String: Any]] {
            return arr
        }
        // some replies wrap the array in an object — {"items": [...]}
        // — despite the prompt; take any array of objects inside
        if let obj = jsonObject(in: text) {
            for value in obj.values {
                if let arr = value as? [[String: Any]],
                   !arr.isEmpty {
                    return arr
                }
            }
        }
        return nil
    }

    /// Models fence their JSON or wrap it in chat; take the outermost
    /// balanced span and ignore everything around it.
    private static func extract(_ text: String, open: Character,
                                close: Character) -> String? {
        guard let start = text.firstIndex(of: open),
              let end = text.lastIndex(of: close),
              start < end else { return nil }
        return String(text[start...end])
    }

    /// Positive quantities (values, counts) — zero/negative is "none".
    static func number(_ any: Any?) -> Double? {
        anyNumber(any).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Any numeric — coordinates and confidences may be zero.
    static func anyNumber(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Upright-normalize then crop a normalized-rect region (small
    /// padding) — per-item thumbnails out of one shelf photo, using
    /// the model's own box_2d.
    static func crop(_ image: UIImage, box: CGRect) -> UIImage? {
        let size = image.size
        // redraw first: CGImage cropping ignores EXIF orientation
        let upright = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = upright.cgImage else { return nil }
        let padded = box.insetBy(dx: -box.width * 0.06,
                                 dy: -box.height * 0.06)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rect = CGRect(
            x: padded.minX * CGFloat(cg.width),
            y: padded.minY * CGFloat(cg.height),
            width: padded.width * CGFloat(cg.width),
            height: padded.height * CGFloat(cg.height)).integral
        guard rect.width > 8, rect.height > 8,
              let cut = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cut)
    }

    /// Cap the upload at ~1024 px / ~200 KB — plenty for recognition,
    /// kind to free-tier quotas.
    static func downscaledJPEG(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 1024
        let side = max(image.size.width, image.size.height)
        let scale = side > maxSide ? maxSide / side : 1
        let size = CGSize(width: image.size.width * scale,
                          height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }
}
