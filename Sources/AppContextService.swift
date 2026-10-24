import Foundation
import ApplicationServices
import AppKit

struct AppSelectionSnapshot {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let textInsertionTarget: AppTextInsertionTarget?
    let usesOriginalFieldInsertion: Bool
}

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let contextSystemPrompt: String?
    let contextPrompt: String?

    var contextSummary: String {
        currentActivity
    }

    var summaryForPostProcessing: String {
        ContextInferenceFailure.usableSummary(currentActivity)
    }
}

final class AppContextService {
    static let defaultContextModel = "qwen/qwen3.8-27b"
    static let defaultContextPrompt = """
You are a context synthesis assistant for a speech-to-text pipeline.
Given app/window metadata, output exactly two sentences that describe what the user is doing right now and the likely writing intent in the current window.
Prioritize concrete details only from the context: for email, identify recipients, subject or thread cues, and whether the user is replying or composing; for terminal/code/text work, identify the active command, file, document title, or topic.
If details are missing, state uncertainty instead of inventing facts.
Return only two sentences, no labels, no markdown, no extra commentary.
"""
    static let defaultContextPromptDate = "2026-02-24"

    private let apiKey: String
    private let baseURL: String
    private let customContextPrompt: String
    private let contextModel: String
    private var contextRequestTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "context_request_timeout_seconds")
        return override > 0 ? override : 20
    }

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        customContextPrompt: String = "",
        contextModel: String = AppContextService.defaultContextModel
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.customContextPrompt = customContextPrompt
        let trimmedModel = contextModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextModel = trimmedModel.isEmpty ? Self.defaultContextModel : trimmedModel
    }

    private func resolveContextPrompt() -> String {
        let trimmedPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrompt.isEmpty ? Self.defaultContextPrompt : trimmedPrompt
    }

    /// Captures the mode and optional target together; off skips insertion-target reads.
    func collectSelectionSnapshot(captureInsertionTarget: Bool = false) -> AppSelectionSnapshot {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppSelectionSnapshot(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                textInsertionTarget: nil,
                usesOriginalFieldInsertion: captureInsertionTarget
            )
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        let textInsertionTarget = captureInsertionTarget ? AppTextInsertionTarget.capture(
            from: appElement, processIdentifier: frontmostApp.processIdentifier
        ) : nil
        return AppSelectionSnapshot(
            appName: frontmostApp.localizedName,
            bundleIdentifier: frontmostApp.bundleIdentifier,
            windowTitle: focusedWindowTitle(from: appElement) ?? frontmostApp.localizedName,
            selectedText: !captureInsertionTarget || textInsertionTarget != nil ? rawSelectedText(from: appElement) : nil,
            textInsertionTarget: textInsertionTarget,
            usesOriginalFieldInsertion: captureInsertionTarget
        )
    }

    func collectContext() async -> AppContext {
        let contextSystemPrompt = resolveContextPrompt()

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                currentActivity: "You are dictating in an unrecognized context.",
                contextSystemPrompt: contextSystemPrompt,
                contextPrompt: nil
            )
        }

        let appName = frontmostApp.localizedName
        let bundleIdentifier = frontmostApp.bundleIdentifier
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        let windowTitle = focusedWindowTitle(from: appElement) ?? appName
        let selectedText = selectedText(from: appElement)
        let currentActivity: String
        let contextPrompt: String?
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                contextSystemPrompt: contextSystemPrompt
            ) {
            case .success(let result):
                currentActivity = result.activity
                contextPrompt = result.prompt
            case .failure(let error):
                currentActivity = error.summary
                contextPrompt = nil
            }
        } else {
            currentActivity = ContextInferenceFailure.missingAPIKey.summary
            contextPrompt = nil
        }

        return AppContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            currentActivity: currentActivity,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt
        )
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        contextSystemPrompt: String
    ) async -> Result<(activity: String, prompt: String), ContextInferenceFailure> {
        let model = contextModel
        do {
            var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = contextRequestTimeoutSeconds
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let metadata = """
App: \(appName ?? "Unknown")
Bundle ID: \(bundleIdentifier ?? "Unknown")
Window: \(windowTitle ?? "Unknown")
Selected text: \(selectedText ?? "None")
"""

            let userMessage = "Analyze the context and infer the user's current activity in exactly two sentences.\n\n\(metadata)"
            let fullPrompt = "Model: \(model)\n\n[System]\n\(contextSystemPrompt)\n[User]\n\(userMessage)"

            var payload: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": contextSystemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]

            payload.merge(Self.inferenceRequestOptions(for: model)) { _, option in option }

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let (data, response) = try await LLMAPITransport.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            return Self.inferenceResult(data: data, status: httpResponse.statusCode, model: model, prompt: fullPrompt)
        } catch {
            if (error as? URLError)?.code == .timedOut { return .failure(.timeout) }
            return .failure(.network)
        }
    }

    static func inferenceRequestOptions(for model: String) -> [String: Any] {
        // Two sentences need a small completion budget. Leaving this unset
        // can reserve more output tokens than Groq's free-tier TPM limit.
        var options: [String: Any] = ["max_completion_tokens": 512]
        let config = ModelConfiguration.config(for: model)
        if let effort = config.reasoningEffort { options["reasoning_effort"] = effort }
        if let include = config.includeReasoning { options["include_reasoning"] = include }
        return options
    }

    static func inferenceResult(
        data: Data, status: Int, model: String, prompt: String
    ) -> Result<(activity: String, prompt: String), ContextInferenceFailure> {
        guard status == 200 else { return .failure(.httpStatus(status)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return .failure(.invalidResponse)
        }
        guard let activity = activitySummary(from: content, model: model) else {
            return .failure(.emptySummary)
        }
        return .success((activity: activity, prompt: prompt))
    }

    static func activitySummary(from rawContent: String, model: String) -> String? {
        var content = rawContent
        if ModelConfiguration.config(for: model).shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return normalizedActivitySummary(cleaned)
    }

    private static func normalizedActivitySummary(_ value: String) -> String {
        let sentences = value
            .split(whereSeparator: { $0 == "." || $0 == "。" || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count <= 2 {
            return value
        }

        let firstTwo = sentences.prefix(2)
        return firstTwo.joined(separator: ". ") + "."
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        if let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) {
            return trimmedText(windowTitle)
        }

        return nil
    }

    private func selectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let selectedText = accessibilityString(from: focusedElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        if let selectedText = accessibilityString(from: appElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        return nil
    }

    private func rawSelectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let selectedText = accessibilityRawString(from: focusedElement, attribute: kAXSelectedTextAttribute as CFString) {
            return selectedText
        }

        if let selectedText = accessibilityRawString(from: appElement, attribute: kAXSelectedTextAttribute as CFString) {
            return selectedText
        }

        return nil
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return trimmedText(stringValue)
    }

    private func accessibilityRawString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue.isEmpty ? nil : stringValue
    }

    private func trimmedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }
}
