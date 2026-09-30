# ADR-006 :: Learned corrections

Last updated: `2026.09.29`

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
  - `corrections.json` holds pairs of at most 3 words on each side, evidence counts, a status (pending, added, rejected, suspect) and your labels;
  - `learned-dictionary` is a table in the dictionary format. It holds the automatic adds.
- **Your dictionary.** Parrot edits `~/.config/parrot/dictionary` only when you act: Accept in the review window, Fix Word, or `parrot import wispr --apply`. It edits lines and keeps every other line as it was.
- **Text in memory.** The edit watcher keeps the pasted text in memory for at most 60 s after delivery, to compare it with the field. This changes the rule in `Transcript.swift`, which said "never keep it after delivery". The watcher keeps no text after the watch ends. Logs hold counts and end reasons only.
- **Network.** Parrot calls an LLM only when you set a provider. The request holds these items only:
  - the pair;
  - local features: shape, sound similarity, and whether the heard form is common;
  - at most 5 related dictionary words.

  Context words go only when you turn on `sendContext`. Requests use an ephemeral `URLSession`. Logs never hold a request body or a response body. The API key is in the Keychain, never in `settings.json`.
- **No keystrokes.** The watcher uses Accessibility reads only. The event tap stays `flagsChanged` only (ADR-003).
- **Wispr Flow import.** Parrot reads Wispr's database through the SQLite backup API into memory. It never writes to Wispr's files, and it never writes a copy to disk.

## 2. Rationale

Each `Replaces` item is a hard find-and-replace on every dictation, and each Word is also a case rule. A wrong row damages every later dictation. Wispr Flow can learn freely, because its dictionary words are only hints to its models. A literal copy of Wispr's words into `Replaces` would turn every "Link" into "Zorblink". So each pair gets explicit rules, and local vetoes block the dangerous ones.

`DictionaryMigration` never writes into a dotfiles repository on its own. Automatic adds keep that rule: they go to the overlay, and your rows win over the overlay.

ADR-004 allows stored user text when the feature is opt-in, has a stated location, and has its own ADR. Word pairs are the least text that can teach a spelling.

Wispr Flow sends at most 4 words per dictation to its classifier, and it sends no sentence. The LLM payload here is of the same size. While no provider is set, goal 2 ("audio and text never leave the Mac") holds.

Rejected:
- A keystroke tap to see Enter and Backspace, as Wispr Flow has. It breaks ADR-003.
- An LLM rewrite of each dictation before the paste. It adds latency, it sends every transcript off the Mac, and processors are synchronous (ADR-001).
- `NSSpellChecker` as the common-word test. It accepts many rare names and brands as correct words. A bundled list of common words replaces it.

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
