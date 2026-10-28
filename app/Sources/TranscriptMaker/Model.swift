import AppKit
import AVFoundation
import Foundation
import TranscriptCore
import UniformTypeIdentifiers

enum ItemState: String, Codable {
    case waiting, working, done, failed, stopped

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .working: return "Transcribing"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

enum ItemKind: String, Codable {
    case video, audio
}

/// One video or audio file to transcribe.
final class Item: ObservableObject, Identifiable {
    let id: UUID
    let url: URL
    let kind: ItemKind
    @Published var title: String
    @Published var duration: Double?
    @Published var thumbnail: NSImage?
    @Published var state: ItemState = .waiting
    @Published var queued = true
    @Published var progress = 0.0
    @Published var detail = ""
    @Published var error = ""
    /// Exact number of people talking; 0 lets the app work it out.
    @Published var speakers = 0
    /// Clean up the sound before listening.
    @Published var cleanup = Cleanup.off
    @Published var transcript: Transcript?
    /// The files written for this item (PDF, DOCX…).
    @Published var outputs: [URL] = []

    init(url: URL, kind: ItemKind, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.kind = kind
        self.title = url.deletingPathExtension().lastPathComponent
    }

    var transcriptFile: URL { AppModel.supportFolder.appendingPathComponent("transcripts/\(id.uuidString).json") }

    /// Reads the length and, for a video, a frame from a tenth of the way in for the list.
    @MainActor func loadDetails() async {
        let asset = AVURLAsset(url: url)
        if let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 {
            duration = time.seconds
        } else if let length = mediaLength(url) {  // files only ffmpeg reads
            duration = length
        }
        guard kind == .video else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let at = CMTime(seconds: min(30, (duration ?? 10) / 10), preferredTimescale: 600)
        if let (image, _) = try? await generator.image(at: at) {
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } else if let frame = await ffmpegFrame(url, at: at.seconds) {  // AV1, VP9, MKV… the Mac can't decode
            thumbnail = frame
        }
    }
}

/// One frame of a video as a small picture, through ffmpeg.
@MainActor
func ffmpegFrame(_ url: URL, at seconds: Double) async -> NSImage? {
    guard let ffmpeg = AudioExtractor.ffmpegPath else { return nil }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: file) }
    let data = await Task.detached { () -> Data? in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-loglevel", "error", "-ss", String(seconds), "-i", url.path,
                             "-frames:v", "1", "-vf", "scale=320:-2", "-y", file.path]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return try? Data(contentsOf: file)
    }.value
    return data.flatMap(NSImage.init(data:))
}

/// Length in seconds of a file the Mac can't open itself (MKV, WebM…), from ffprobe next to ffmpeg.
func mediaLength(_ url: URL) -> Double? {
    guard let ffmpeg = AudioExtractor.ffmpegPath else { return nil }
    let probe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe")
    guard FileManager.default.isExecutableFile(atPath: probe.path) else { return nil }
    let process = Process()
    process.executableURL = probe
    process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

@MainActor
final class AppModel: ObservableObject {
    static let videoTypes = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "3gp"]
    static let audioTypes = ["mp3", "m4a", "m4b", "wav", "aiff", "aif", "caf", "flac", "ogg", "opus", "aac", "wma"]

    /// `--demo FOLDER` (for README pictures and tests) keeps everything in FOLDER: the list, the transcripts
    /// and the saved files, so the usual list and output folder are left alone.
    nonisolated static let demoFolder: URL? = {
        let args = CommandLine.arguments
        return args.firstIndex(of: "--demo").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    }()

    nonisolated static var supportFolder: URL {
        demoFolder?.appendingPathComponent("support")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Transcript Maker")
    }

    @Published var items: [Item] = []
    @Published var selection: Item.ID?
    /// The order things will be transcribed in (videos and audio alike). Items leave it when they start.
    @Published var queueOrder: [Item.ID] = []
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var showLog = UserDefaults.standard.bool(forKey: "showLog") {
        didSet { UserDefaults.standard.set(showLog, forKey: "showLog") }
    }
    @Published var log: [String] = []
    @Published var lastMessage = ""

    /// Empty means ~/Transcripts.
    @Published var outputPath = UserDefaults.standard.string(forKey: "outputPath") ?? "" {
        didSet { UserDefaults.standard.set(outputPath, forKey: "outputPath") }
    }
    @Published var formats = Set((UserDefaults.standard.stringArray(forKey: "formats") ?? ["pdf", "docx"])
        .compactMap(ExportFormat.init(rawValue:))) {
        didSet { UserDefaults.standard.set(formats.map(\.rawValue).sorted(), forKey: "formats") }
    }
    @Published var timestamps = UserDefaults.standard.object(forKey: "timestamps") as? Bool ?? true {
        didSet { UserDefaults.standard.set(timestamps, forKey: "timestamps") }
    }
    /// Sound clean-up for files added from now on (each file can be changed in its panel).
    @Published var defaultCleanup = Cleanup(rawValue: UserDefaults.standard.string(forKey: "cleanup") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(defaultCleanup.rawValue, forKey: "cleanup") }
    }
    /// Start transcribing as soon as files are added, without pressing Start.
    @Published var startWhenAdded = UserDefaults.standard.object(forKey: "startWhenAdded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(startWhenAdded, forKey: "startWhenAdded") }
    }

    private var process: Process?
    private var current: Item?
    private var startedAt = Date()
    private var stopRequested = false

    var outputFolder: URL {
        if let demo = Self.demoFolder { return demo.appendingPathComponent("output") }
        return outputPath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transcripts")
            : URL(fileURLWithPath: outputPath)
    }

    var videos: [Item] { ordered(items.filter { $0.kind == .video }) }
    var audios: [Item] { ordered(items.filter { $0.kind == .audio }) }
    var selectedItem: Item? { items.first { $0.id == selection } }

    /// What's being made and finished items first, then the queue in its order, then the rest.
    private func ordered(_ list: [Item]) -> [Item] {
        let rank: (Item) -> Int = { item in
            if item.state == .working { return -1 }
            if let i = self.queueOrder.firstIndex(of: item.id) { return i }
            return self.queueOrder.count + 1
        }
        return list.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.map(\.element)
    }

    func queuePosition(_ id: Item.ID) -> Int? { queueOrder.firstIndex(of: id).map { $0 + 1 } }

    func moveInQueue(_ id: Item.ID, by step: Int) {
        guard let i = queueOrder.firstIndex(of: id) else { return }
        let j = i + step
        guard queueOrder.indices.contains(j) else { return }
        queueOrder.swapAt(i, j)
        saveQueue()
    }

    // MARK: adding

    /// Files and folders dropped or chosen. Folders are searched for videos and audio.
    func add(_ urls: [URL]) {
        var added: [Item] = []
        for url in expand(urls) {
            let ext = url.pathExtension.lowercased()
            let kind: ItemKind
            if Self.videoTypes.contains(ext) { kind = .video } else if Self.audioTypes.contains(ext) { kind = .audio } else { continue }
            if items.contains(where: { $0.url == url && $0.state != .done }) { continue }
            let item = Item(url: url, kind: kind)
            item.cleanup = defaultCleanup
            items.append(item)
            queueOrder.append(item.id)
            added.append(item)
            Task { await item.loadDetails() }
        }
        guard !added.isEmpty else {
            lastMessage = "No videos or audio files there"
            return
        }
        if selection == nil { selection = added.first?.id }
        lastMessage = "Added \(added.count) file\(added.count == 1 ? "" : "s")"
        saveQueue()
        if startWhenAdded { startQueue() }
    }

    private func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
            guard isFolder.boolValue else { return [url] }
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    func remove(_ item: Item) {
        if item.state == .working { stop() }
        items.removeAll { $0.id == item.id }
        queueOrder.removeAll { $0 == item.id }
        try? FileManager.default.removeItem(at: item.transcriptFile)
        if selection == item.id { selection = items.first?.id }
        saveQueue()
    }

    var hasFinished: Bool { items.contains { $0.state == .done } }

    func clearFinished() {
        let finished = items.filter { $0.state == .done }
        items.removeAll { $0.state == .done }
        if let s = selection, !items.contains(where: { $0.id == s }) { selection = items.first?.id }
        lastMessage = "Cleared \(finished.count) finished item\(finished.count == 1 ? "" : "s") from the list (the transcripts are still in the output folder)"
        saveQueue()
    }

    /// Transcribe again, e.g. with a different number of speakers.
    func again(_ item: Item) {
        guard item.state != .working else { return }
        item.state = .waiting
        item.progress = 0
        item.error = ""
        item.detail = ""
        if !queueOrder.contains(item.id) { queueOrder.append(item.id) }
        saveQueue()
        startQueue()
    }

    // MARK: running

    func startQueue() {
        guard !isRunning else { return }
        stopRequested = false
        runNext()
    }

    private func runNext() {
        guard !stopRequested,
              let id = queueOrder.first(where: { id in items.contains { $0.id == id && $0.state != .working } }),
              let item = items.first(where: { $0.id == id }) else {
            isRunning = false
            isPaused = false
            current = nil
            return
        }
        queueOrder.removeAll { $0 == id }
        isRunning = true
        run(item)
    }

    /// Runs the engine helper (transcribe-cli, next to the app's own program) for one file.
    private func run(_ item: Item) {
        current = item
        item.state = .working
        item.progress = 0
        item.error = ""
        item.detail = "Starting…"
        startedAt = Date()
        appendLog("— \(item.url.lastPathComponent)")

        try? FileManager.default.createDirectory(at: item.transcriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = Self.helper
        var arguments = [item.url.path, "--json", item.transcriptFile.path, "--progress"]
        if item.speakers > 0 { arguments += ["--speakers", String(item.speakers)] }
        if item.cleanup != .off { arguments += ["--cleanup", item.cleanup.rawValue] }
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lastLine = LastLine()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            Task { @MainActor in
                for line in lines { self?.handle(line, for: item, last: lastLine) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.finished(item, status: finished.terminationStatus, reason: finished.terminationReason, lastLine: lastLine.text) }
        }
        do {
            try process.run()
            self.process = process
            saveQueue()
        } catch {
            item.state = .failed
            item.error = "Couldn't start the engine: \(error.localizedDescription)"
            runNext()
        }
    }

    /// The stages' share of the total time, measured on a few videos (listening and voices take most of it).
    private static let stageWeights: [String: (start: Double, share: Double)] = [
        "loading": (0, 0.04), "extracting": (0.04, 0.04), "cleaning": (0.08, 0.06), "listening": (0.14, 0.44),
        "speakers": (0.58, 0.4), "writing": (0.98, 0.02),
    ]

    private func handle(_ line: String, for item: Item, last: LastLine) {
        if line.hasPrefix("@stage ") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let weight = Self.stageWeights[String(parts[1])], let fraction = Double(parts[2]) else { return }
            item.progress = min(1, weight.start + weight.share * fraction)
            item.detail = describe(stage: String(parts[1]), fraction: fraction, overall: item.progress)
            return
        }
        if line.hasPrefix("[") { return }  // the speech library's own diagnostics
        last.text = line
        appendLog("    " + line)
    }

    private func describe(stage: String, fraction: Double, overall: Double) -> String {
        let names = ["loading": "Loading the speech models", "extracting": "Taking out the sound", "cleaning": "Cleaning up the sound",
                     "listening": "Listening for words", "speakers": "Telling the voices apart", "writing": "Writing the transcript"]
        var text = names[stage] ?? stage
        if fraction > 0, fraction < 1 { text += " · \(Int(fraction * 100))%" }
        let elapsed = Date().timeIntervalSince(startedAt)
        if overall > 0.1, elapsed > 10 {
            let left = elapsed / overall * (1 - overall)
            text += left < 60 ? " · under a minute left" : " · about \(Int(left / 60) + 1) min left"
        }
        return text
    }

    private func finished(_ item: Item, status: Int32, reason: Process.TerminationReason, lastLine: String) {
        process = nil
        isPaused = false
        if stopRequested || reason == .uncaughtSignal && status == SIGTERM {
            item.state = .stopped
            item.detail = ""
            appendLog("    Stopped")
        } else if status == 0, let transcript = try? Transcript.load(item.transcriptFile) {
            item.transcript = transcript
            item.state = .done
            item.progress = 1
            item.detail = ""
            exportAll(item)
            notifyDone(item)
        } else {
            item.state = .failed
            item.error = lastLine.hasPrefix("Failed: ") ? String(lastLine.dropFirst(8))
                : reason == .uncaughtSignal ? "The engine stopped unexpectedly (signal \(status)). Try again; if it keeps happening, see the log (⌘L)."
                : "The engine stopped unexpectedly. See the log (⌘L)."
            item.detail = ""
            appendLog("    Failed: \(item.error)")
        }
        saveQueue()
        runNext()
    }

    func pause() {
        guard let process, !isPaused else { return }
        kill(process.processIdentifier, SIGSTOP)
        isPaused = true
    }

    func resume() {
        guard let process, isPaused else { return }
        kill(process.processIdentifier, SIGCONT)
        isPaused = false
    }

    /// Stops the file being transcribed and the queue. What's queued stays queued.
    func stop() {
        stopRequested = true
        if let process {
            if isPaused { kill(process.processIdentifier, SIGCONT) }
            process.terminate()
        } else {
            isRunning = false
        }
        if let current, current.state == .working { queueOrder.insert(current.id, at: 0) }
    }

    /// transcribe-cli sits next to the app's program (Contents/MacOS in the app, .build/debug when developing).
    static var helper: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("transcribe-cli")
    }

    // MARK: exports

    var exportOptions: ExportOptions { ExportOptions(timestamps: timestamps) }

    /// Writes the chosen formats for a finished item into the output folder, replacing its own earlier files.
    func exportAll(_ item: Item) {
        guard let transcript = item.transcript else { return }
        let folder = outputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for format in ExportFormat.allCases where formats.contains(format) {
            let file = uniqueFile(folder, item.title, format.fileExtension, ownedBy: item)
            do {
                try Exporter.write(transcript, as: format, to: file, options: exportOptions)
                written.append(file)
            } catch {
                appendLog("    Couldn't write \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        item.outputs = written
        if !written.isEmpty {
            lastMessage = "Saved \(written.map { $0.pathExtension.uppercased() }.joined(separator: ", ")) for \(item.title)"
        }
        saveQueue()
    }

    /// "Title.pdf", or "Title 2.pdf" if another file already has that name.
    private func uniqueFile(_ folder: URL, _ title: String, _ ext: String, ownedBy item: Item) -> URL {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var n = 1
        while true {
            let file = folder.appendingPathComponent(n == 1 ? "\(safe).\(ext)" : "\(safe) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: file.path) || item.outputs.contains(file) { return file }
            n += 1
        }
    }

    /// Renaming a speaker ("Person 1" -> "Teacher") rewrites the saved files.
    func rename(_ item: Item, speaker: Int, to name: String) {
        guard var transcript = item.transcript, transcript.speakers.indices.contains(speaker) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let newName = trimmed.isEmpty ? "Person \(speaker + 1)" : trimmed
        guard transcript.speakers[speaker] != newName else { return }
        transcript.speakers[speaker] = newName
        item.transcript = transcript
        try? transcript.save(item.transcriptFile)
        exportAll(item)
    }

    // MARK: log

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    private func notifyDone(_ item: Item) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: saved list

    static var queueFile: URL { supportFolder.appendingPathComponent("queue.json") }

    private struct Saved: Codable {
        var id: UUID
        var path: String
        var kind: ItemKind
        var title: String
        var state: ItemState
        var queued: Bool
        var speakers: Int
        var cleanup: Cleanup?
        var outputs: [String]
        var error: String
    }

    func saveQueue() {
        let saved = items.map { item in
            Saved(id: item.id, path: item.url.path, kind: item.kind, title: item.title,
                  state: item.state == .working ? .waiting : item.state, queued: queueOrder.contains(item.id) || item.state == .working,
                  speakers: item.speakers, cleanup: item.cleanup, outputs: item.outputs.map(\.path), error: item.error)
        }
        // queue order first, then the rest
        let order = (current.map { [$0.id] } ?? []) + queueOrder
        let sorted = saved.sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
        try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sorted) { try? data.write(to: Self.queueFile, options: .atomic) }
    }

    func restoreQueue() {
        guard let data = try? Data(contentsOf: Self.queueFile),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        var order: [Item.ID] = []
        for s in saved where FileManager.default.fileExists(atPath: s.path) {
            let item = Item(url: URL(fileURLWithPath: s.path), kind: s.kind, id: s.id)
            item.title = s.title
            item.state = s.state
            item.speakers = s.speakers
            item.cleanup = s.cleanup ?? .off
            item.outputs = s.outputs.map { URL(fileURLWithPath: $0) }
            item.error = s.error
            if s.state == .done {
                item.transcript = try? Transcript.load(item.transcriptFile)
                item.progress = 1
            }
            if s.queued && s.state != .done { order.append(item.id) }
            items.append(item)
            Task { await item.loadDetails() }
        }
        queueOrder = order
        selection = items.first?.id
    }
}

/// The engine's last line of output, for the error message if it fails.
final class LastLine: @unchecked Sendable {
    var text = ""
}

// MARK: keep awake

/// The coffee cup in the toolbar: while it's on, the Mac doesn't go to sleep on its own, so long queues keep
/// going when you walk away. The screen can still turn off. Off again each time the app opens.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    private var activity: NSObjectProtocol?

    @Published var isOn = false {
        didSet {
            if isOn, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled], reason: "Transcript Maker: keeping the Mac awake")
            } else if !isOn, let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
    }
}
