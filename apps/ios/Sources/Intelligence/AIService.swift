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
}

struct AIIdentification {
    var name: String
    var category: String
    var summary: String
    var estimatedValue: Double?
    var valueNote: String
}

enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badReply(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add an AI key in Settings first — the free "
                + "Gemini tier works."
        case .http(let code, let body):
            return "AI request failed (\(code)): \(body.prefix(160))"
        case .badReply(let text):
            return "Couldn't read the AI's reply: \(text.prefix(120))"
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
        case .gemini: return "gemini-2.5-flash"
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
    /// Bumped so views re-read isConfigured after a key edit.
    @Published var keyEdition = 0

    var kind: AIProviderKind {
        AIProviderKind(rawValue: kindRaw) ?? .gemini
    }

    var apiKey: String? {
        let k = KeyStore.load(account: kind.rawValue)
        return (k?.isEmpty ?? true) ? nil : k
    }

    var isConfigured: Bool { apiKey != nil }

    var model: String {
        modelOverride.isEmpty ? kind.defaultModel : modelOverride
    }

    func setKey(_ value: String) {
        KeyStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines),
                      account: kind.rawValue)
        keyEdition += 1
    }

    private var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

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
        let text = try await visionCall(prompt: prompt, image: image,
                                        maxTokens: 300)
        guard let obj = Self.jsonObject(in: text) else {
            throw AIError.badReply(text)
        }
        return AIIdentification(
            name: (obj["name"] as? String) ?? "Object",
            category: (obj["category"] as? String) ?? "object",
            summary: (obj["summary"] as? String) ?? "",
            estimatedValue: Self.number(
                obj["estimated_value_\(currencyCode.lowercased())"]),
            valueNote: (obj["value_note"] as? String) ?? "")
    }

    /// Photograph an open box → the box's contents, itemized.
    func itemizeBox(image: UIImage) async throws -> [AIItem] {
        let prompt = """
        This photo shows the contents of a storage container (box, bin, \
        drawer or shelf). List every distinct physical item you can \
        actually see. Reply with ONLY a strict JSON array, no prose: \
        [{"name": "short item name", "category": "one or two words", \
        "estimated_value_\(currencyCode.lowercased())": number or null \
        (typical used replacement value, \(currencyCode))}] \
        Maximum 25 items. Skip the container itself.
        """
        let text = try await visionCall(prompt: prompt, image: image,
                                        maxTokens: 1200)
        guard let arr = Self.jsonArray(in: text) else {
            throw AIError.badReply(text)
        }
        return arr.compactMap { entry in
            guard let name = entry["name"] as? String,
                  !name.isEmpty else { return nil }
            return AIItem(
                name: name,
                category: (entry["category"] as? String) ?? "object",
                estimatedValue: Self.number(
                    entry["estimated_value_\(currencyCode.lowercased())"]))
        }
    }

    /// Replacement-value estimate for one already-saved thing.
    func estimateValue(image: UIImage?, name: String,
                       details: String) async throws
        -> (value: Double, note: String) {
        let prompt = """
        Estimate the replacement value of this item for a home \
        inventory, in \(currencyCode), as typically bought used/current \
        condition. Item: "\(name)". \(details) \
        Reply with ONLY strict JSON: \
        {"value_\(currencyCode.lowercased())": number, \
        "note": "short basis, one clause"}
        """
        let text = try await visionCall(prompt: prompt, image: image,
                                        maxTokens: 200)
        guard let obj = Self.jsonObject(in: text),
              let value = Self.number(
                obj["value_\(currencyCode.lowercased())"]) else {
            throw AIError.badReply(text)
        }
        return (value, (obj["note"] as? String) ?? "")
    }

    /// Settings "Test" button: cheapest possible round-trip.
    func ping() async throws {
        _ = try await visionCall(
            prompt: "Reply with exactly the word: ready",
            image: nil, maxTokens: 10)
    }

    // ---- transport -------------------------------------------------------

    private func visionCall(prompt: String, image: UIImage?,
                            maxTokens: Int) async throws -> String {
        guard let key = apiKey else { throw AIError.notConfigured }
        let jpeg = image.flatMap { Self.downscaledJPEG($0) }
        let request: URLRequest
        switch kind {
        case .gemini:
            request = try Self.geminiRequest(
                key: key, model: model, prompt: prompt, jpeg: jpeg,
                maxTokens: maxTokens)
        case .anthropic:
            request = try Self.anthropicRequest(
                key: key, model: model, prompt: prompt, jpeg: jpeg,
                maxTokens: maxTokens)
        case .custom:
            request = try Self.openAIRequest(
                endpoint: customEndpoint, key: key, model: model,
                prompt: prompt, jpeg: jpeg, maxTokens: maxTokens)
        }
        let (data, response) = try await URLSession.shared.data(
            for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AIError.http(code,
                               String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
            let text = Self.extractText(kind: kind, from: obj),
            !text.isEmpty else {
            throw AIError.badReply(
                String(data: data, encoding: .utf8) ?? "empty")
        }
        return text
    }

    private static func geminiRequest(key: String, model: String,
                                      prompt: String, jpeg: Data?,
                                      maxTokens: Int) throws -> URLRequest {
        let url = URL(string: "https://generativelanguage.googleapis.com"
            + "/v1beta/models/\(model):generateContent")!
        var parts: [[String: Any]] = [["text": prompt]]
        if let jpeg {
            parts.append(["inline_data": [
                "mime_type": "image/jpeg",
                "data": jpeg.base64EncodedString(),
            ]])
        }
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": ["temperature": 0.2,
                                 "maxOutputTokens": maxTokens],
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
                                         prompt: String, jpeg: Data?,
                                         maxTokens: Int) throws
        -> URLRequest {
        var content: [[String: Any]] = []
        if let jpeg {
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
                                      jpeg: Data?, maxTokens: Int) throws
        -> URLRequest {
        let base = endpoint.hasSuffix("/")
            ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: base + "/chat/completions"),
              url.scheme == "https" else {
            throw AIError.http(0, "Endpoint must be an https URL")
        }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let jpeg {
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
        guard let span = extract(text, open: "[", close: "]"),
              let parsed = try? JSONSerialization.jsonObject(
                with: Data(span.utf8)) else { return nil }
        return parsed as? [[String: Any]]
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

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d > 0 ? d : nil }
        if let i = any as? Int { return i > 0 ? Double(i) : nil }
        if let s = any as? String { return Double(s) }
        return nil
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
