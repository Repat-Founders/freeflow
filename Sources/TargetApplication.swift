import Foundation

/// The kind of app being dictated into, recognized from its bundle id so the
/// cleanup model gets the formatting rule next to the transcript instead of
/// guessing it from the context summary. Unknown apps, browsers included,
/// stay with the context inference.
enum TargetApplication: Equatable {
    case agentPrompt
    case chat
    case email
    case codeEditor
    case terminal
    case notes

    private static let bundles: [String: TargetApplication] = [
        "com.conductor.app": .agentPrompt,
        "com.anthropic.claudefordesktop": .agentPrompt,
        "com.openai.chat": .agentPrompt,
        "com.openai.codex": .agentPrompt,
        "net.whatsapp.WhatsApp": .chat,
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.MobileSMS": .chat,
        "com.superhuman.electron": .email,
        "com.apple.mail": .email,
        "com.todesktop.230313mzl4w4u92": .codeEditor,
        "com.microsoft.VSCode": .codeEditor,
        "com.apple.Terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "com.mitchellh.ghostty": .terminal,
        "dev.warp.Warp-Stable": .terminal,
        "notion.id": .notes,
        "com.apple.Notes": .notes
    ]

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier, let target = Self.bundles[bundleIdentifier] else { return nil }
        self = target
    }

    var instruction: String {
        switch self {
        case .agentPrompt:
            "Prompt to an AI coding agent. Natural prose with French typography. Write spoken developer syntax as typed: \"slash\" followed by a command name becomes /command-name, lowercase, words joined by hyphens (\"slash code review\" -> /code-review). A spoken file path becomes a path: \"slash\" -> /, \"point\" or \"dot\" before an extension -> . (\"app slash models slash user point rb\" -> app/models/user.rb). \"underscore\" -> _ (\"user underscore id\" -> user_id). \"arobase\" or \"at\" before a name -> @name. Keep identifiers, commands and English technical terms exactly as spoken."
        case .chat:
            "Chat message. Natural, direct register. No headings, no bold."
        case .email:
            "Email. Formal register, complete sentences, each starting with a capital letter, salutation and closing included. A salutation or a closing only if it was spoken."
        case .codeEditor:
            "Code editor. Plain text, straight quotes, no French typographic spacing. Preserve identifiers verbatim."
        case .terminal:
            "Terminal. Plain text only: straight quotes, no guillemets, no bullets, no space before punctuation, no capitalization changes to commands."
        case .notes:
            "Notes app. Markdown allowed when the speaker structured their speech."
        }
    }
}
