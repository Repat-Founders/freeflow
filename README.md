<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="FreeFlow icon">
</p>

<h1 align="center">FreeFlow</h1>

<p align="center">
  Free and open source alternative to <a href="https://wisprflow.ai">Wispr Flow</a>, <a href="https://superwhisper.com">Superwhisper</a>, and <a href="https://monologue.to">Monologue</a>.
</p>

<p align="center">
  <a href="https://github.com/zachlatta/freeflow/releases/latest/download/FreeFlow.dmg"><b>⬇ Download FreeFlow.dmg</b></a><br>
  <sub>Works on all Macs (Apple Silicon + Intel)</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="FreeFlow demo" width="600">
</p>

<p align="center">
  <i>Thank you to <a href="https://github.com/marcbodea">@marcbodea</a> for maintaining FreeFlow!</i>
</p>

> **Personal fork.** This is a personal fork of
> [zachlatta/freeflow](https://github.com/zachlatta/freeflow). It removes the
> Screen Recording permission and all screenshot capture, merges the two
> dictation shortcuts into one, and tunes cleanup for French dictation with
> embedded English technical terms. There is no prebuilt download: the link
> above installs the upstream app, not this fork. Build it from source as
> described in [Installation](#installation).

## Overview

FreeFlow is a free Mac dictation app inspired by [Wispr Flow](https://wisprflow.ai/), [Superwhisper](https://superwhisper.com/), and [Monologue](https://www.monologue.to/). It gives you fast AI transcription, context-aware cleanup, and voice-driven text editing without a monthly subscription.

## Installation

Requirements: macOS 13 or later, and Xcode (it provides `swiftc` and the macOS
SDK). Open Xcode once after installing it to accept the license.

**1. Create a code-signing certificate (once).** The build signs the app with
a certificate named `FreeFlow Dev`. A self-signed one is enough:

1. Open **Keychain Access**, then **Keychain Access › Certificate Assistant ›
   Create a Certificate…**
2. Name: `FreeFlow Dev` (exactly). Identity Type: **Self Signed Root**.
   Certificate Type: **Code Signing**. Click Create.
3. Check that it is visible: `security find-identity -p codesigning` should
   list `"FreeFlow Dev"`.

Why it matters: macOS ties the Accessibility permission to the app's
signature. With a stable certificate, the permission survives every rebuild.
You can build without one using `make CODESIGN_IDENTITY=-` (ad-hoc signing),
but macOS then silently revokes Accessibility after each rebuild and pasting
stops working until you grant it again.

**2. Build and launch.**

```bash
git clone https://github.com/<you>/freeflow.git
cd freeflow
make run
```

This produces `build/FreeFlow Dev.app` and opens it. `make install` builds,
quits the running copy, replaces `/Applications/FreeFlow Dev.app` and relaunches
it. To sign with another certificate without passing it every time, put
`CODESIGN_IDENTITY = <name>` in an untracked `Makefile.local`.

**3. Set it up.** The first launch walks you through it:

- Paste a free Groq API key from [console.groq.com](https://console.groq.com/keys).
- Allow **Microphone** access.
- Allow **Accessibility** access (System Settings › Privacy & Security ›
  Accessibility). It is what lets FreeFlow paste text and read the frontmost
  app's context.

**Updates.** A source build never checks for updates, and the fork has no
Check for Updates entry: the upstream release would replace it. To update,
`git pull` and run `make install`.

## Quick Start

1. Install as described above
2. Get a free Groq API key from [groq.com](https://groq.com/)
3. Hold `Fn` to talk and release to stop, or double-tap `Fn` to dictate hands-free until a single tap stops it. Whatever you say is pasted into the current text field

## Features

- **One dictation shortcut:** Hold to talk, or double-tap for hands-free dictation. A lone tap is ignored.
- **Context-aware cleanup:** FreeFlow reads the frontmost app's name, window title and selected text through Accessibility, so formatting and spelling fit email, terminals, docs and chat. No Screen Recording permission, no screenshots.
- **Original-field insertion (opt in):** Enable **Insert into the original field** in Settings → General → Text insertion to keep dictation tied to its starting field when switching windows. This is off by default and applies to new dictations; otherwise dictation pastes into the currently focused field. Changed or unavailable fields and unconfirmed writes leave the transcript available through Paste Again rather than risking a misplaced or duplicate paste. Paste fallback, or Enter when an editor loses background focus, may briefly activate the original app before restoring your previous focus.
- **Readable output:** Long dictations are split into paragraphs at changes of idea; spoken enumerations become lists; reported speech is quoted.
- **Custom vocabulary:** Add names, jargon, and project-specific words that FreeFlow should preserve during cleanup. When speech recognition keeps mishearing a term, list the misheard forms in parentheses — `Higgsfield (XField, X Field)` — and FreeFlow replaces them.
- **Add to Vocabulary shortcut:** Select a word anywhere, press the shortcut, confirm with Return.
- **OpenAI-compatible providers:** Use Groq by default, or configure a custom model and API URL in settings.

## Edit Mode

Edit Mode lets you highlight existing text and transform it with a spoken instruction, like "make this shorter" or "turn this into bullets." Enable it in settings, then use your normal dictation shortcut on selected text, or choose Manual mode to require an extra modifier key.

## Privacy

There is no FreeFlow server, so FreeFlow does not store or retain your data. The only information that leaves your computer are API calls to your configured transcription and LLM provider.

## Custom Cleanup

If you'd rather keep cleanup more literal and less context-aware, you can paste this simpler prompt into the custom system prompt setting:

<details>
  <summary>Simple post-processing prompt</summary>

  <pre><code>You are a dictation post-processor. You receive raw speech-to-text output and return clean text ready to be typed into an application.

Your job:
- Remove filler words (um, uh, you know, like) unless they carry meaning.
- Fix spelling, grammar, and punctuation errors.
- When the transcript already contains a word that is a close misspelling of a name or term from the context or custom vocabulary, correct the spelling. Never insert names or terms from context that the speaker did not say.
- Preserve the speaker's intent, tone, and meaning exactly.

Output rules:
- Return ONLY the cleaned transcript text, nothing else. So NEVER output words like "Here is the cleaned transcript text:"
- If the transcription is empty, return exactly: EMPTY
- Do not add words, names, or content that are not in the transcription. The context is only for correcting spelling of words already spoken.
- Do not change the meaning of what was said.

Example:
RAW_TRANSCRIPTION: "hey um so i just wanted to like follow up on the meating from yesterday i think we should definately move the dedline to next friday becuz the desine team still needs more time to finish the mock ups and um yeah let me know if that works for you ok thanks"

Then your response would be ONLY the cleaned up text, so here your response is ONLY:
"Hey, I just wanted to follow up on the meeting from yesterday. I think we should definitely move the deadline to next Friday because the design team still needs more time to finish the mockups. Let me know if that works for you. Thanks."</code></pre>
</details>

## Using a Local Model

FreeFlow can use OpenAI-compatible local or self-hosted providers instead of Groq. In settings, configure the API base URL and model IDs for your local LLM provider, such as Ollama, LM Studio, or another OpenAI-compatible server. If your transcription backend uses a different endpoint from your LLM backend, set the transcription API URL separately.

Local models are often slower than hosted providers, especially on cold start, long recordings, or busy hardware.

<details>
  <summary>Configure longer timeouts for local models</summary>

  FreeFlow keeps the default network timeout at 20 seconds, but you can extend it with macOS defaults:

```bash
defaults write com.zachlatta.freeflow transcription_timeout_seconds -float 120
defaults write com.zachlatta.freeflow post_processing_timeout_seconds -float 120
defaults write com.zachlatta.freeflow context_request_timeout_seconds -float 120
```

The timeout keys are:

- `transcription_timeout_seconds`: audio transcription requests
- `post_processing_timeout_seconds`: transcript cleanup and edit mode requests
- `context_request_timeout_seconds`: nearby app context requests

Only positive values are used. Remove a custom timeout to return to the 20-second default:

```bash
defaults delete com.zachlatta.freeflow transcription_timeout_seconds
defaults delete com.zachlatta.freeflow post_processing_timeout_seconds
defaults delete com.zachlatta.freeflow context_request_timeout_seconds
```

</details>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up the project, build, test, and submit changes.

## License

Licensed under the MIT license.
