# ADR-006 :: Learned corrections

Last updated: `2026.09.30`

> This fork learns the spelling corrections that you make: from a Wispr Flow import, from Fix Word, and later from the text field after a paste. Parrot keeps word pairs, never sentences. It writes to your dictionary only when you act. Automatic adds go to an overlay file that Parrot owns. An LLM judge is optional, and it gets only the word pair.

## 1. Decision

- **Opt-in.** `corrections.learn` in `settings.json` controls learning: `off`, `review` (the default), `hybrid` or `auto`. In `review`, Parrot collects candidates, and nothing changes until you accept one.
- **Rules.** Each learned pair gets one or more rules:
  - `replace` writes `Word  heard`;
  - `case` writes the Word only;
  - `prompt` adds the Word to the example sentence;
  - `none` writes nothing.

  Local vetoes stop a `replace` rule for a common single word, and stop any row for an all-lowercase or common word. The LLM cannot override a veto.
- **Stored text.** Two files in `~/Library/Application Support/parrot/`, both owner-only (0600):
  - `corrections.json` holds pairs of at most 3 words on each side, evidence counts (times seen, times the heard form occurs in kept text, whether you added the word by hand), a status (pending, added, rejected, suspect) and your labels;
  - `learned-dictionary` is a table in the dictionary format. It holds the automatic adds.
- **Your dictionary.** Parrot edits `~/.config/parrot/dictionary` only when you act: Accept in the review window, Fix Word, or `parrot import wispr --apply`. It edits lines and keeps every other line as it was.
- **Text in memory.** The edit watcher keeps the pasted text in memory for at most 60 s after delivery, to compare it with the field. This changes the rule in `Transcript.swift`, which said "never keep it after delivery". The watcher keeps no text after the watch ends. Logs hold counts and end reasons only.
- **Network.** Parrot calls an LLM only when you set a provider. The request holds these items only:
  - the pair;
  - local features: shape, sound similarity, and whether the heard form is common;
  - at most 5 related dictionary words.

  Context words go only when you turn on `sendContext`. Requests use an ephemeral `URLSession`. Logs never hold a request body or a response body. The API key is in the Keychain, never in `settings.json`.
- **Connecting a provider.** Settings → Corrections shows a tile for each provider:
  - Claude, OpenAI and Gemini let no other app sign in for the user. Parrot opens the page where the user makes a key. While the Connect window is open, Parrot reads the clipboard and takes only text in the shape of that provider's key. It checks the key by listing the models, which costs nothing. Then it saves the key in the Keychain and clears it from the clipboard.
  - OpenRouter has a sign-in, OAuth with PKCE, that returns a key. The redirect goes to a one-shot listener on the loopback interface, which takes one request and stops after at most 5 minutes.
  - Ollama and LM Studio run on the Mac. Parrot asks them for their models.
- **Wispr Flow import in Settings.** The Import button runs the same import as `parrot import wispr`. The judge checks the pairs when one is connected. The proposals wait in Review Corrections, and Review Corrections shows the rules recorded with each pair, narrowed by the local vetoes.
- **Learning notice.** After an edit, a notice above the recording pill shows the word pair with Add and Not this, or Added with Undo, or a short reason when Parrot learns nothing. It takes no focus, it shows only the pair that `corrections.json` already holds, and the log gives the reason without the words.
- **Electron apps.** A watched app built on Electron gets `AXManualAccessibility` set once per run when a dictation starts there, as assistive apps do, so Parrot can read its fields. Unwatched apps are never asked.
- **No keystrokes.** The watcher uses Accessibility reads only. The event tap stays `flagsChanged` only (ADR-003).
- **Wispr Flow import.** Parrot opens Wispr's database read-only: as an ordinary reader while Wispr Flow runs, and as an immutable file when it is quit. All reads run in one transaction. It never writes to Wispr's files, and it never writes a copy to disk.
- **Common words.** The English word embedding that ships with macOS decides what is a common word. It needs no download and no bundled list.

## 2. Rationale

Each `Replaces` item is a hard find-and-replace on every dictation, and each Word is also a case rule. A wrong row damages every later dictation. Wispr Flow can learn freely, because its dictionary words are only hints to its models. A literal copy of Wispr's words into `Replaces` would turn every "Link" into "Zorblink". So each pair gets explicit rules, and local vetoes block the dangerous ones.

`DictionaryMigration` never writes into a dotfiles repository on its own. Automatic adds keep that rule: they go to the overlay, and your rows win over the overlay.

ADR-004 allows stored user text when the feature is opt-in, has a stated location, and has its own ADR. Word pairs are the least text that can teach a spelling.

Wispr Flow sends at most 4 words per dictation to its classifier, and it sends no sentence. The LLM payload here is of the same size. While no provider is set, goal 2 ("audio and text never leave the Mac") holds.

Rejected:
- A keystroke tap to see Enter and Backspace, as Wispr Flow has. It breaks ADR-003.
- An LLM rewrite of each dictation before the paste. It adds latency, it sends every transcript off the Mac, and processors are synchronous (ADR-001).
- `NSSpellChecker` as the common-word test. It accepts many rare names and brands as correct words. A bundled list of common words replaces it.
- A sign-in with a Claude.ai or Google AI consumer account. Their terms allow those sign-ins only in the providers' own apps, so Claude and Gemini connect with an API key.

## 3. Design Implications

- `Paths` gets `correctionsFile`, `learnedDictionaryFile` and `dictionaryLock`.
- `DictionaryProcessor` merges your dictionary and the overlay. Your rows win.
- The writer and the CLI take an `flock` on `dictionaryLock` before they write, so the app and the CLI never write at the same time.
- Validation of `corrections.json` rejects any string longer than 3 words.
- Tests assert that a canary word never reaches stderr, the stores, or a request body when `sendContext` is off.

## 4. When to Revisit

- If upstream ships #54 with its own dictionary writer, use it and remove this one.
- If an on-device model judges pairs well enough, make it the default judge.
- If automatic adds reach 95% precision on your labels for two weeks, consider a setting that writes them to your dictionary.
- Add "Sign in with ChatGPT" (OpenAI, September 2026) for OpenAI: it lets open-source apps use the user's ChatGPT plan with no key. It needs the Responses API and token refresh.
- If Anthropic or Google add a sign-in for other apps, use it instead of the key page.
