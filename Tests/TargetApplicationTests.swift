import Foundation

enum TargetApplicationTests {
    static func run() {
        testKnownBundlesAreClassified()
        testUnknownBundlesAreLeftToContextInference()
        testAgentPromptInstructionCoversDeveloperSyntax()
    }

    private static func testKnownBundlesAreClassified() {
        let expectations: [(String, TargetApplication)] = [
            ("com.conductor.app", .agentPrompt),
            ("com.anthropic.claudefordesktop", .agentPrompt),
            ("com.openai.chat", .agentPrompt),
            ("com.openai.codex", .agentPrompt),
            ("net.whatsapp.WhatsApp", .chat),
            ("com.tinyspeck.slackmacgap", .chat),
            ("com.superhuman.electron", .email),
            ("com.apple.mail", .email),
            ("com.todesktop.230313mzl4w4u92", .codeEditor),
            ("com.microsoft.VSCode", .codeEditor),
            ("com.apple.Terminal", .terminal),
            ("notion.id", .notes)
        ]
        for (bundleIdentifier, expected) in expectations {
            TestSupport.expectEqual(TargetApplication(bundleIdentifier: bundleIdentifier), expected)
        }
    }

    private static func testUnknownBundlesAreLeftToContextInference() {
        TestSupport.expectEqual(TargetApplication(bundleIdentifier: nil), nil)
        TestSupport.expectEqual(TargetApplication(bundleIdentifier: ""), nil)
        TestSupport.expectEqual(TargetApplication(bundleIdentifier: "com.google.Chrome"), nil)
    }

    private static func testAgentPromptInstructionCoversDeveloperSyntax() {
        let instruction = TargetApplication.agentPrompt.instruction
        for marker in ["/", "underscore", "arobase", "path"] {
            TestSupport.expect(instruction.contains(marker), "Agent prompt instruction must mention \(marker)")
        }
    }
}
