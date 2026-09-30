import ArgumentParser
import Foundation
import ParrotCore

// Developer benchmarks for Parrot. Not part of Parrot.app.

/// `parrot-bench transcription <folder>` times the model;
/// `parrot-bench capture` times the microphone;
/// `parrot-bench ax-probe` checks what your apps' text fields offer.
struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot-bench",
        abstract: "Measure latency: the model over recordings, or microphone capture.",
        subcommands: [BenchTranscription.self, BenchCapture.self, BenchAXProbe.self],
        defaultSubcommand: BenchTranscription.self
    )
}

/// What each app's focused text field offers over Accessibility (ADR-006).
struct BenchAXProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax-probe",
        abstract: "Check which Accessibility reads and notifications your apps' text fields support.",
        discussion: """
            Watches the focused element for --seconds while you click into a \
            text field in each app and type a few characters. Prints one row \
            per app and role with flags and counts. Never prints text. The \
            terminal needs the Accessibility permission.
            """
    )

    @Option(name: .long, help: "Seconds to watch.") var seconds: Double = 45

    @Option(name: .long, help: "Seconds between two looks at the focused element.") var interval: Double = 0.5

    func run() throws {
        try exiting { try AXProbe.run(AXProbeOptions(seconds: seconds, interval: interval)) }
    }
}

/// Press-to-first-sample of the default input (#52).
struct BenchCapture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Time press-to-first-sample on the default input, cold and warm.",
        discussion: """
            Opens and closes the default input the way a dictation does and \
            prints the median and p90, in milliseconds, of the time from the \
            press to the first captured sample, cold (after --idle seconds \
            without capture) and warm (--gap seconds after the last). It also \
            checks between presses that the input is not running. Speak or \
            not; no audio is kept.
            """
    )

    @Option(name: .long, help: "Rounds: one cold and one warm capture each.") var runs: Int = 5

    @Option(name: .long, help: "Seconds without capture before each cold capture.") var idle: Double = 300

    @Option(name: .long, help: "Seconds between a cold capture and the warm one.") var gap: Double = 2

    @Option(name: .long, help: "Seconds to hold each capture after its first buffer.") var hold: Double = 0.5

    @Option(
        name: .long,
        help: "Capture mode: \(CaptureMode.allCases.map(\.rawValue).joined(separator: ", ")).",
        transform: parseCaptureMode
    )
    var mode: CaptureMode = .standard

    @Flag(name: .long, help: "Write the last capture to ~/Library/Caches/parrot/last-capture.wav.") var dumpWav: Bool = false

    func run() throws {
        try exiting {
            try CaptureBench.run(CaptureBenchOptions(runs: runs, idle: idle, gap: gap, hold: hold, mode: mode, dumpWav: dumpWav))
        }
    }
}

/// Transcription latency over local recordings (#49).
struct BenchTranscription: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcription",
        abstract: "Time the model over a folder of recordings: median and p90 per stage.",
        discussion: """
            Runs the model over every .wav file in the folder and prints each \
            transcription stage's median and p90 in milliseconds. A .txt file \
            beside a recording, holding what was said, adds its word error rate. \
            Prints timings and counts, never transcript text.
            """
    )

    @Argument(help: "Folder of .wav recordings.") var folder: String

    @Option(name: .long, help: "Timed runs per file.") var runs: Int = 10

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.") var model: String?

    @Option(name: .long, help: "Prompt text to use instead of the dictionary's example sentence.") var prompt: String?

    @Flag(name: .long, help: "Run without a prompt.") var noPrompt: Bool = false

    @Flag(name: .long, help: "Use WhisperKit's default settings, as Parrot ran before #49, to compare.") var baseline: Bool = false

    @Option(name: .long, help: "Compute units for the audio encoder: ane, gpu, cpu or all.") var encoder: String?

    @Option(name: .long, help: "Compute units for the text decoder: ane, gpu, cpu or all.") var decoder: String?

    @Option(name: .long, help: "Seconds to sit idle before each timed run.") var pause: Double = 0

    @Option(name: .long, help: "Trim leading and trailing silence: on or off. Defaults to the tuning's choice.")
    var trim: String?

    @Option(name: .long, help: "Seconds of silence before the audio, after the trim. Defaults to the tuning's choice.")
    var leadPad: Double?

    @Option(name: .long, help: "Seconds of silence after the audio, after the trim. Defaults to the tuning's choice.")
    var trailPad: Double?

    @Option(name: .long, help: "Language for a multilingual model: a code such as pt, or auto. Defaults to auto.")
    var language: String?

    @Option(name: .long, help: "Comma-separated languages Automatic chooses among, such as en,es. Defaults to the Mac's languages.")
    var spoken: String?

    func validate() throws {
        if let trim, !["on", "off"].contains(trim) { throw ValidationError("--trim: expected on or off") }
        for (name, value) in [("--lead-pad", leadPad), ("--trail-pad", trailPad)] {
            if let value, value < 0 || value > 5 { throw ValidationError("\(name): expected 0 to 5 seconds") }
        }
    }

    func run() throws {
        try exiting {
            try TranscriptionBench.run(BenchOptions(
                folder: folder,
                runs: runs,
                model: model,
                prompt: prompt,
                noPrompt: noPrompt,
                baseline: baseline,
                encoder: encoder,
                decoder: decoder,
                pause: pause,
                trim: trim.map { $0 == "on" },
                leadPad: leadPad,
                trailPad: trailPad,
                language: language == "auto" ? nil : language,
                spoken: spoken?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
            ))
        }
    }
}

/// `--mode`: a `CaptureMode` by name.
private func parseCaptureMode(_ raw: String) throws -> CaptureMode {
    guard let mode = CaptureMode(rawValue: raw) else {
        throw ValidationError("expected one of: \(CaptureMode.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return mode
}

/// Maps ParrotCore's `SilentExit` to an exit code. Any other error reaches
/// ArgumentParser, which prints it and exits nonzero.
private func exiting(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let exit as SilentExit {
        throw ExitCode(exit.code)
    }
}

Bench.main()
