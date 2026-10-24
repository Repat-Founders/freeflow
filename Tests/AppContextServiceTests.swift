import Foundation

enum AppContextServiceTests {
    static func run() {
        testQwenRawOutputIsSummarized()
        testQwenReasoningOutputIsStripped()
        testNonStrippingModelPreservesExistingBehavior()
        testDeprecatedGroqModelsAreNotPredefined()
        testQwenCleanupDisablesReasoning()
        testInferenceFailureDiagnostics()
        testContextRequestBudget()
        testFailedSummariesStayOutOfPostProcessing()
    }

    private static func testQwenRawOutputIsSummarized() {
        let output = """
        The user is replying to an email about the product launch. They likely intend to confirm the next steps. This third sentence should be dropped.
        """

        let summary = AppContextService.activitySummary(from: output, model: "qwen/qwen3.8-27b")

        TestSupport.expectEqual(
            summary,
            "The user is replying to an email about the product launch. They likely intend to confirm the next steps."
        )
    }

    private static func testQwenReasoningOutputIsStripped() {
        let output = """
        <think>
        Hidden chain of thought should never appear in context.
        It contains misleading details.
        </think>
        The user is editing a project note in FreeFlow. They likely intend to tighten the release wording.
        """

        let summary = AppContextService.activitySummary(from: output, model: "qwen/qwen3.8-27b")

        TestSupport.expectEqual(
            summary,
            "The user is editing a project note in FreeFlow. They likely intend to tighten the release wording."
        )
        TestSupport.expect(summary?.contains("Hidden chain of thought") == false, "Qwen reasoning leaked into summary")
    }

    private static func testNonStrippingModelPreservesExistingBehavior() {
        let output = "<think>Visible for non-stripping models.</think> The user is writing a status update."

        let summary = AppContextService.activitySummary(
            from: output,
            model: "meta-llama/llama-4-scout-17b-16e-instruct"
        )

        TestSupport.expectEqual(summary, output)
    }

    private static func testDeprecatedGroqModelsAreNotPredefined() {
        let deprecatedModels = [
            "qwen/qwen3-32b",
            "qwen/qwen3.6-27b",
            "groq/compound",
            "groq/compound-mini",
            "meta-llama/llama-4-scout-17b-16e-instruct",
            "llama-3.1-8b-instant",
            "llama-3.3-70b-versatile"
        ]

        for model in deprecatedModels {
            TestSupport.expect(!ModelConfiguration.llmModels.contains(model), "Deprecated model remains in picker: \(model)")
        }
        TestSupport.expect(ModelConfiguration.llmModels.contains("qwen/qwen3.8-27b"), "New fallback is missing from picker")
    }

    private static func testQwenCleanupDisablesReasoning() {
        let config = ModelConfiguration.config(for: "qwen/qwen3.8-27b")

        TestSupport.expect(config.reasoningEffort == "none", "Qwen cleanup should disable reasoning")
        TestSupport.expect(config.includeReasoning == false, "Qwen cleanup should exclude reasoning output")
    }
    private static func testContextRequestBudget() {
        let options = AppContextService.inferenceRequestOptions(for: "qwen/qwen3.8-27b")
        TestSupport.expectEqual(options["max_completion_tokens"] as? Int, 512)
        TestSupport.expectEqual(options["reasoning_effort"] as? String, "none")
        TestSupport.expectEqual(options["include_reasoning"] as? Bool, false)
        let custom = AppContextService.inferenceRequestOptions(for: "synthetic/custom")
        TestSupport.expectEqual(custom["max_completion_tokens"] as? Int, 512)
        TestSupport.expect(custom["reasoning_effort"] == nil, "Unknown providers should not receive reasoning options")
    }

    private static func testInferenceFailureDiagnostics() {
        let hostileResponse = Data(#"{"error":{"message":"synthetic-secret-token and captured content"}}"#.utf8)
        for status in [400, 401, 403, 404, 429, 500, 503] {
            let result = AppContextService.inferenceResult(data: hostileResponse, status: status, model: "synthetic-model", prompt: "synthetic-prompt")
            guard case .failure(let error) = result else {
                fatalError("HTTP failure returned usable context")
            }
            TestSupport.expect(error.summary.contains("HTTP \(status)"), "Provider status was discarded")
            TestSupport.expect(!error.summary.contains("synthetic-secret-token"), "Provider response leaked into diagnostics")
            TestSupport.expect(ContextInferenceFailure.isFailureSummary(error.summary), "Failure should be highlighted")
        }
        for (data, expected) in [
            (Data("invalid JSON".utf8), ContextInferenceFailure.invalidResponse.summary),
            (Data(#"{"choices":[{"message":{"content":"<think>hidden</think> "}}]}"#.utf8), ContextInferenceFailure.emptySummary.summary)
        ] {
            let result = AppContextService.inferenceResult(data: data, status: 200, model: "qwen/qwen3.8-27b", prompt: "synthetic-prompt")
            guard case .failure(let error) = result else { fatalError("Invalid result was accepted") }
            TestSupport.expectEqual(error.summary, expected)
        }
        let success = AppContextService.inferenceResult(
            data: Data(#"{"choices":[{"message":{"content":"The user is editing a synthetic note."}}]}"#.utf8),
            status: 200, model: "qwen/qwen3.8-27b", prompt: "synthetic-prompt"
        )
        guard case .success(let result) = success else { fatalError("Valid context was rejected") }
        TestSupport.expectEqual(result.activity, "The user is editing a synthetic note.")
        TestSupport.expectEqual(result.prompt, "synthetic-prompt")
    }

    private static func testFailedSummariesStayOutOfPostProcessing() {
        let failures = [
            ContextInferenceFailure.httpStatus(404).summary,
            ContextInferenceFailure.httpStatus(429).summary,
            ContextInferenceFailure.timeout.summary,
            ContextInferenceFailure.missingAPIKey.summary,
            "Could not reliably infer a two-sentence summary for SyntheticApp from the visible metadata.",
            "Could not refresh app context at stop time; using text-only post-processing.",
            "You are dictating in an unrecognized context."
        ]
        for summary in failures {
            let context = AppContext(
                appName: "SyntheticApp", bundleIdentifier: "test.synthetic", windowTitle: "Synthetic note",
                selectedText: nil, currentActivity: summary, contextSystemPrompt: nil, contextPrompt: nil
            )
            TestSupport.expectEqual(context.summaryForPostProcessing, "")
            TestSupport.expectEqual(context.contextSummary, summary)
            TestSupport.expectEqual(ContextInferenceFailure.promptSection(for: summary), "")
        }
        TestSupport.expectEqual(ContextInferenceFailure.promptSection(for: "The user is writing a synthetic note."),
                                "CONTEXT: \"The user is writing a synthetic note.\"\n")
    }

}
