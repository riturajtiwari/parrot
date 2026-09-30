# Learned corrections (fork)

Last updated: `2026.09.29`

> This fork of Parrot learns the spellings that you correct: names, brands, acronyms, technical terms, and joins or casing of such words. It can also import what Wispr Flow learned. Every learned pair is a few words, never a sentence. See [ADR-006](decisions/006-learned-corrections.md) for the decisions.

## 1. How Parrot uses a learned pair

A pair is what the model wrote (the heard form) and what you wrote instead. Each pair gets one or more rules:

| Rule | What Parrot writes | When |
|---|---|---|
| replace | `Word  heard` in the dictionary | The heard form is rare, sounds like the word, and you never keep it elsewhere. |
| case | `Word` in the dictionary | The word has a distinct spelling (a capital letter, CamelCase, capitals, digits) and is not an everyday word. |
| prompt | The word goes into the example sentence | The model hears the word as everyday words, so replace is unsafe. |

Each dictionary row changes every dictation, so local checks block the unsafe cases. "Link" never becomes "Zorblink" everywhere, and a lowercase word such as "dev" never gets a row.

## 2. Import from Wispr Flow

Parrot reads Wispr Flow's database read-only. It never writes to Wispr's files.

```sh
parrot import wispr            # print what Parrot would learn
parrot import wispr --apply    # decide each proposal: a accept, r reject, e rules, s skip, q quit
parrot import wispr --llm      # let the LLM judge from Settings review the proposals first
```

Accepted rows go into your `dictionary`. At the end, Parrot asks for one example sentence with the words that need it.

To find what Parrot's own model mishears in your voice, replay Wispr's recordings first:

```sh
swift run -c release parrot-bench wispr-replay --save
```

The replay prints the word error rate, how often the model writes your terms exactly, and what it writes instead. With `--save`, the import proposes those pairs too.

## 3. Fix Word

1. Select the misheard word in any app.
2. Choose **Fix Word…** in the Parrot menu, or **Services → Fix Word in Parrot**.
3. Type the correct spelling, check the rules, and click **Add**.

To set a shortcut, open **System Settings → Keyboard → Keyboard Shortcuts → Services** and find **Fix Word in Parrot**.

## 4. Review and Undo

**Review Corrections…** in the menu lists the pairs that wait for you, with the proposed rules, and the pairs added so far, with Undo. **Undo** in the menu removes the word Parrot added last. From a terminal:

```sh
parrot corrections list
parrot corrections undo Qwilbo
```

Undo removes a row only when Parrot created it. On your own row, it removes only the heard form that Parrot added.

## 5. Learning from your edits

After each paste into a watched app, Parrot reads the text field over Accessibility for up to 60 s. When you change a word, it proposes the pair. **Settings → Corrections → Learning** has three modes:

- **Off:** Parrot learns nothing.
- **Review:** Parrot collects pairs. Nothing changes until you accept one.
- **Hybrid:** Parrot adds clear fixes of rare words at once, with Undo, and queues the rest. It starts only when its proposals were right in 95% of at least 20 of your reviews. Automatic adds go to `~/Library/Application Support/parrot/learned-dictionary`, never into your own dictionary.

The watched apps are in `settings.json` under `corrections.watchedApps`. To see which apps expose their text fields, run `parrot-bench ax-probe`. Parrot never watches a password field, and it reads no keystrokes.

If you change a word that a learned rule wrote back to what you said, Parrot marks the rule as suspect and shows it in Review Corrections.

## 6. The LLM judge

The local rules work without a network. An LLM judge can check their proposals. **Settings → Corrections → Judge** offers Claude, OpenAI, Gemini, OpenRouter, Ollama, LM Studio, and any other OpenAI-compatible server.

- The key goes into the Keychain, never into `settings.json`.
- The judge gets each pair, such as "Kwilbo → Qwilbo", and a few local features. It never gets a sentence or audio.
- The judge can drop or narrow a proposal. It can never add a rule that a local check blocks.
- When a request fails, the pairs keep the local verdict.

```sh
parrot llm set-key claude      # or: openai, gemini, openrouter, custom
parrot llm models
parrot llm test
```

## 7. Files

| File | Holds |
|---|---|
| `~/.config/parrot/dictionary` | Your rows, and the rows you accepted |
| `~/Library/Application Support/parrot/learned-dictionary` | Rows that hybrid mode added on its own |
| `~/Library/Application Support/parrot/corrections.json` | Every pair with its evidence, status and your decision. Word pairs only |
| `~/.config/parrot/settings.json` | `corrections` settings, and the example sentence under `dictionary.examples` |
