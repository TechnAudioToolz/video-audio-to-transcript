import CoreML
import FluidAudio
import Foundation

/// Where the speech models live: inside the app for the offline edition, otherwise downloaded once into
/// ~/Library/Application Support/Transcript Maker/models.
public enum ModelStore {
    public static var folder: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("models"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcript Maker/models")
    }

    /// The Parakeet build used for English: "ultra" has the lowest error rate of the Parakeet family
    /// (2.1 % on LibriSpeech test-clean, 3.8 % on test-other) and runs on macOS 14.
    static let parakeetVersion = AsrModelVersion.ultra

    static var parakeetFolder: URL { folder.appendingPathComponent(Repo.parakeetUltra.folderName) }

    public static var parakeetInstalled: Bool { AsrModels.modelsExist(at: parakeetFolder, version: parakeetVersion) }
}

public struct PipelineOptions: Sendable {
    /// Exact number of people talking, when known; nil to let the app work it out.
    public var speakers: Int?
    /// Words that should be spelled a particular way (names, jargon); used to steer the recogniser.
    public var vocabulary: [String] = []

    public init(speakers: Int? = nil) {
        self.speakers = speakers
    }
}

/// What the pipeline is doing, for the progress bar and the log.
public enum PipelineStage: String, Sendable {
    case loading = "Loading the speech models"
    case extracting = "Taking out the sound"
    case listening = "Listening for words"
    case speakers = "Telling the voices apart"
    case writing = "Writing the transcript"
}

/// Video in, transcript out: sound -> words with times -> who spoke when -> paragraphs per speaker.
public actor Pipeline {
    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?

    public init() {}

    /// Loads (and the first time, downloads) the models. Takes a few seconds; the first load on a Mac also
    /// compiles them for its Neural Engine, which takes a minute or two.
    public func prepare(log: @Sendable (String) -> Void = { _ in }) async throws {
        try await prepareSpeech(log: log)
        try await prepareVoices()
    }

    /// The speech recogniser. `encoderUnits` nil means its usual place, the Neural Engine.
    func prepareSpeech(encoderUnits: MLComputeUnits? = nil, log: @Sendable (String) -> Void) async throws {
        guard asr == nil else { return }
        let folder = ModelStore.parakeetFolder
        let models: AsrModels
        if ModelStore.parakeetInstalled {
            models = try await AsrModels.load(from: folder, version: ModelStore.parakeetVersion, encoderComputeUnits: encoderUnits)
        } else {
            log("Downloading the speech recognition model (about 650 MB, once)…")
            models = try await AsrModels.downloadAndLoad(to: folder, version: ModelStore.parakeetVersion,
                                                         encoderComputeUnits: encoderUnits)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    /// The models that tell voices apart.
    func prepareVoices(speakers: Int? = nil) async throws {
        let manager = OfflineDiarizerManager(config: Self.voiceSettings(speakers: speakers))
        try await manager.prepareModels(directory: ModelStore.folder)
        diarizer = manager
    }

    static func voiceSettings(speakers: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        // Windows every second instead of every two: catches quick replies ("Have you thought about…? I haven't.")
        // that the default folds into the speaker around them. Twice the work, about 5 s per minute of audio.
        config.segmentation.stepRatio = 0.1
        if let speakers { config.clustering.numSpeakers = speakers }
        return config
    }

    public func run(_ input: URL, workFolder: URL, options: PipelineOptions = PipelineOptions(),
                    stage: @escaping @Sendable (PipelineStage, Double) -> Void,
                    log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Transcript {
        stage(.loading, 0)
        // one model set at a time: loading the voice models while the speech model is still being readied
        // for the Neural Engine has made the speech model fail
        try await prepareSpeech(log: log)
        guard let asr else { throw TranscriptError.modelsMissing("speech model") }

        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let wav = workFolder.appendingPathComponent("audio-16k.wav")
        stage(.extracting, 0)
        var started = Date()
        let duration = try await AudioExtractor.extract(input, to: wav) { stage(.extracting, $0) }
        log(String(format: "Sound taken out: %@ long (%.1f s)", clock(duration), Date().timeIntervalSince(started)))

        stage(.listening, 0)
        started = Date()
        let progressTask = Task {
            for try await fraction in await asr.transcriptionProgressStream { stage(.listening, fraction) }
        }
        defer { progressTask.cancel() }
        var state = TdtDecoderState.make()
        let result: ASRResult
        do {
            result = try await asr.transcribeDiskBacked(wav, decoderState: &state)
        } catch {
            // Right after the app is installed or updated, the Mac compiles the models for its Neural Engine and
            // the first prediction can fail. Loading them again and starting over has always worked.
            log("The speech model hiccupped (\(error.localizedDescription)); starting over on the graphics chip")
            self.asr = nil
            try await prepareSpeech(encoderUnits: .cpuAndGPU, log: log)
            guard let fresh = self.asr else { throw error }
            state = TdtDecoderState.make()
            result = try await fresh.transcribeDiskBacked(wav, decoderState: &state)
        }
        let words = Self.words(from: result.tokenTimings ?? [])
        log(String(format: "Heard %d words (%.1f s, %.0fx faster than real time)",
                   words.count, Date().timeIntervalSince(started), duration / max(0.1, Date().timeIntervalSince(started))))
        guard !words.isEmpty else { throw TranscriptError.nothingHeard }

        stage(.speakers, 0)
        started = Date()
        var segments: [TimedSpeakerSegment] = []
        if let count = options.speakers, count <= 1 {
            log("One speaker, as set")
        } else {
            try await prepareVoices(speakers: options.speakers)
            guard let diarizer else { throw TranscriptError.modelsMissing("voice model") }
            segments = try await diarizer.process(wav) { done, total in stage(.speakers, Double(done) / Double(max(1, total))) }.segments
            log(String(format: "Found %d voice%@ (%.1f s)", Set(segments.map(\.speakerId)).count,
                       Set(segments.map(\.speakerId)).count == 1 ? "" : "s", Date().timeIntervalSince(started)))
        }

        stage(.writing, 0)
        var transcript = Merger.transcript(words: words, segments: segments)
        transcript.title = input.deletingPathExtension().lastPathComponent
        transcript.sourceFile = input.lastPathComponent
        transcript.duration = duration
        transcript.engine = "Parakeet (\(ModelStore.parakeetVersion))"
        try? FileManager.default.removeItem(at: wav)  // about 2 MB a minute; the transcript keeps the times
        return transcript
    }

    /// Joins the recogniser's word pieces ("▁ex", "amp", "le") into whole words with start and end times.
    /// Word pieces that start a new word begin with a space.
    static func words(from tokens: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        var confidences: [Float] = []
        for token in tokens {
            let piece = token.token.replacingOccurrences(of: "▁", with: " ")
            let startsWord = piece.hasPrefix(" ") || words.isEmpty
            let text = piece.trimmingCharacters(in: .whitespaces)
            if startsWord {
                if let last = words.indices.last { words[last].confidence = confidences.reduce(0, +) / Float(confidences.count) }
                guard !text.isEmpty else { continue }
                words.append(Word(text: text, start: token.startTime, end: token.endTime, confidence: token.confidence))
                confidences = [token.confidence]
            } else if let last = words.indices.last {
                words[last].text += text
                words[last].end = token.endTime
                confidences.append(token.confidence)
            }
        }
        if let last = words.indices.last, !confidences.isEmpty {
            words[last].confidence = confidences.reduce(0, +) / Float(confidences.count)
        }
        return words
    }
}

/// Puts each word with the voice that was speaking when it was said, and groups the words into paragraphs.
enum Merger {
    static func transcript(words: [Word], segments: [TimedSpeakerSegment]) -> Transcript {
        let segments = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var labels: [String: Int] = [:]  // diarizer's id -> Person number, in the order they first speak
        var previous = 0
        var speakerOfWord: [Int] = words.map { word in
            let id = speakerId(at: (word.start + word.end) / 2, in: segments)
            guard let id else { return previous }  // between voices: keep the last speaker
            if labels[id] == nil { labels[id] = labels.count }
            previous = labels[id]!
            return previous
        }
        smoothBlips(&speakerOfWord, words)

        var paragraphs: [Paragraph] = []
        for (i, word) in words.enumerated() {
            let speaker = speakerOfWord[i]
            if var current = paragraphs.last, current.speaker == speaker, !shouldBreak(current, before: word) {
                current.words.append(word)
                paragraphs[paragraphs.count - 1] = current
            } else {
                paragraphs.append(Paragraph(speaker: speaker, words: [word]))
            }
        }
        let count = max(1, (speakerOfWord.max() ?? 0) + 1)
        return Transcript(title: "", sourceFile: "", duration: 0, engine: "", created: Date(),
                          speakers: (1...count).map { "Person \($0)" }, paragraphs: paragraphs)
    }

    /// The voice speaking at a moment, or the nearest one within a second.
    static func speakerId(at time: Double, in segments: [TimedSpeakerSegment]) -> String? {
        var best: (distance: Double, id: String)?
        for segment in segments {
            let start = Double(segment.startTimeSeconds), end = Double(segment.endTimeSeconds)
            if start > time + 1 { break }
            let distance = time < start ? start - time : (time > end ? time - end : 0)
            if distance == 0 { return segment.speakerId }
            if distance <= 1, distance < (best?.distance ?? .infinity) { best = (distance, segment.speakerId) }
        }
        return best?.id
    }

    /// One or two quick words given to someone else in the middle of a person's sentence are almost always
    /// a voice-matching slip, not a real interruption: give them back.
    static func smoothBlips(_ speakers: inout [Int], _ words: [Word]) {
        var i = 0
        while i < speakers.count {
            var j = i
            while j + 1 < speakers.count, speakers[j + 1] == speakers[i] { j += 1 }
            let length = j - i + 1
            if i > 0, j + 1 < speakers.count, speakers[i - 1] == speakers[j + 1], length <= 2,
               words[j].end - words[i].start < 0.8,
               words[i].start - words[i - 1].end < 0.3, words[j + 1].start - words[j].end < 0.3 {
                for k in i...j { speakers[k] = speakers[i - 1] }
            }
            i = j + 1
        }
    }

    /// Long stretches by one speaker are split at a sentence end after about a minute, or at a long pause.
    static func shouldBreak(_ paragraph: Paragraph, before word: Word) -> Bool {
        guard let last = paragraph.words.last else { return false }
        let sentenceEnded = last.text.last.map { ".?!".contains($0) } ?? false
        let pause = word.start - last.end
        return sentenceEnded && (paragraph.end - paragraph.start > 60 || pause > 3)
    }
}
