# Learned corrections (fork)

Last updated: `2026.09.30`

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

In **Settings → Corrections**, click **Import** next to Wispr Flow. Parrot applies the rules to each pair. When you connected a judge, the judge checks the pairs too. Then **Review Corrections** opens with the proposals. Accept or reject each one there. A second import adds only new pairs, and a pair you decided keeps your decision.

The same import from a terminal:

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

The replay prints the word error rate, how often the model writes your terms exactly, and what it writes instead. With `--save`, the import proposes those pairs too. Saved pairs stay out of Review Corrections until an import judges them with the text you kept in Wispr Flow, because a form you keep must never be replaced.

## 3. Fix Word

1. Select the misheard word in any app.
2. Choose **Fix Word…** in the Parrot menu, or **Services → Fix Word in Parrot**.
3. Type the correct spelling, check the rules, and click **Add**.

To set a shortcut, open **System Settings → Keyboard → Keyboard Shortcuts → Services** and find **Fix Word in Parrot**.

## 4. Review and Undo

**Review Corrections…** in the menu lists the pairs that wait for you, with the proposed rules and where each pair came from, and the pairs added so far, with Undo. **Undo** in the menu removes the word Parrot added last.

Under the lists is the **Example sentence**. Whisper reads it before each dictation, so it writes the words in it your way. The window names the accepted words that the sentence does not hold yet. Keep it to 12 words or fewer: each word adds about 4 ms to every dictation.

From a terminal:

```sh
parrot corrections list
parrot corrections undo Qwilbo
```

Undo removes a row only when Parrot created it. On your own row, it removes only the heard form that Parrot added.

## 5. Learning from your edits

After each paste into a watched app, Parrot reads the text field over Accessibility for up to 60 s. When you change a word, a notice above the dictation pill says what Parrot made of it:

- **Learn heard → word? · Add · Not this:** Parrot asks before it learns. Add writes the row into your dictionary. Not this means Parrot never proposes the pair again. If you ignore the notice, the pair waits in Review Corrections.
- **Added “word” to your dictionary · Undo:** Parrot added a clear fix at once (Hybrid, after its gate opens). Undo removes it.
- **Edit seen: nothing to learn (reason):** Parrot saw the change, but it is a rewording, an everyday word, or something else that is unsafe to learn.

A notice takes no focus from your app, and a new dictation hides it. A dot on the menu bar bird shows that pairs wait in Review Corrections. **Settings → Corrections → Notices** turns the notices off.

**Settings → Corrections → Learning** has three modes:

- **Off:** Parrot learns nothing.
- **Review:** Parrot always asks. Nothing changes until you add a word.
- **Hybrid:** Parrot asks first. When its proposals match 95% of your choices over at least 20 of them, it adds clear fixes of rare words at once, with Undo. Automatic adds go to `~/Library/Application Support/parrot/learned-dictionary`, never into your own dictionary.

The watched apps are in `settings.json` under `corrections.watchedApps`; the log names an app that is not on the list when you dictate into it. Apps built on Electron, such as Claude and Slack, share their text fields only when an assistive app asks, as VoiceOver does. When you start a dictation in a watched Electron app, Parrot asks once, which costs that app some memory and CPU. To see which apps expose their text fields, run `parrot-bench ax-probe`. Parrot never watches a password field, and it reads no keystrokes.

If you change a word that a learned rule wrote back to what you said, Parrot marks the rule as suspect and shows it in Review Corrections.

## 6. The LLM judge

The local rules work without a network. An LLM judge can check their proposals. **Settings → Corrections → Judge** shows a tile for each provider. Click a tile to connect it:

| Provider | How it connects |
|---|---|
| Claude, OpenAI, Gemini | Parrot opens the page where you make a key: the Claude Console, the OpenAI Platform, or Google AI Studio. Copy the new key. Parrot takes it from the clipboard, checks it, saves it in the Keychain, and removes it from the clipboard. These providers let no other app sign in for you. |
| OpenRouter | Sign in to OpenRouter in your browser. OpenRouter gives Parrot a key of its own, which you can delete on openrouter.ai. |
| Ollama, LM Studio | Parrot finds the server on this Mac and picks one of its models. Nothing leaves the Mac. |
| Other | Type the base URL of any OpenAI-compatible server, and a key if it needs one. |

When the key works, choose a model. Parrot selects the smallest one, such as Claude Haiku 4.5, a GPT mini or a Gemini Flash, because the judge only sorts word pairs. Parrot tests the model with two made-up pairs before it saves it. To change the model later, click **Change…** next to **Model**. **Test Connection** sends the same two made-up pairs. **Disconnect** removes the key from the Keychain. The key still works at the provider until you delete it there.

- Parrot reads the clipboard only while the Connect window is open. It takes only text in the shape of that provider's key.
- The OpenRouter sign-in listens on this Mac's loopback address for one request, for at most 5 minutes.
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
