import Foundation

/// Fills a dictation's `TranscriptionContext` from the dictionary: the example
/// sentence for the active language as the prompt, and the canonical spellings
/// as the vocabulary. In Automatic the language is unknown until the engine
/// hears it, so every example sentence goes along and the engine picks the one
/// for the language it settled on.
package struct DictionaryContext {
    let store: DictionarySource
    /// The language being spoken, when known. Without it the prompt is left
    /// to the engine, from `examples`.
    let language: String?
    /// The example sentences, by language code, from `settings.json`
    /// (`dictionary.examples`).
    let examples: [String: String]

    package init(store: DictionarySource, language: String?, examples: [String: String] = [:]) {
        self.store = store
        self.language = language
        self.examples = examples
    }

    package func context() -> TranscriptionContext {
        TranscriptionContext(
            language: language,
            prompt: UserDictionary(examples: examples).example(for: language),
            vocabulary: store.current().dictionary.vocabulary,
            examples: language == nil ? examples : [:]
        )
    }

    /// The example sentences saved in `settings.json`, read directly for
    /// tools that run without a `SettingsStore` (which is `@MainActor`), such
    /// as `parrot-bench`. Empty when the file is missing or doesn't parse.
    package static func savedExamples() -> [String: String] {
        savedExamples(in: Paths.settingsFile)
    }

    static func savedExamples(in file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return [:] }
        return settings.dictionary.examples
    }

    /// The language a model will hear, when that is certain without a
    /// setting: a single-language model such as `whisper-base.en`. Nil for
    /// multilingual models, whose language comes from the Language setting or
    /// detection: an example sentence in the wrong language drags the decoder
    /// into it (#23).
    package static func knownLanguage(of model: TranscriptionModel) -> String? {
        guard model.languages.count == 1, let only = model.languages.first, only != "multi" else { return nil }
        return only
    }

    /// The language `model` will be told to expect: its only language, or
    /// the Language setting `setting` if the model supports it. Nil for
    /// Automatic.
    package static func language(of model: TranscriptionModel, setting: String?) -> String? {
        if let only = knownLanguage(of: model) { return only }
        if let code = setting?.lowercased(), model.isMultilingual, model.supportedLanguages.contains(code) { return code }
        return nil
    }
}
