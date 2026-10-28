import Foundation
import TranscriptCore

// transcribe-cli VIDEO [--speakers N] [--out FOLDER] [--json FILE] [--progress]
//   Writes VIDEO's transcript as JSON, PDF, DOCX, TXT, SRT and VTT into FOLDER (default: next to the video).
//   --json FILE   write only the transcript JSON, to FILE (the app does this, then writes the other files itself)
//   --progress    also print machine-readable lines for the app: "@stage listening 0.42"
// The app runs this as a separate process, so Pause can freeze it and Stop can end it at once.
setvbuf(stdout, nil, _IOLBF, 0)  // line by line, so the app sees progress as it happens

let args = Array(CommandLine.arguments.dropFirst())
let flagsWithValues = ["--speakers", "--out", "--json"]
func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
let positional = args.enumerated().filter { i, arg in
    !arg.hasPrefix("--") && !(i > 0 && flagsWithValues.contains(args[i - 1]))
}.map(\.element)
guard let path = positional.first else {
    print("usage: transcribe-cli VIDEO [--speakers N] [--out FOLDER] [--json FILE] [--progress]")
    exit(2)
}
let input = URL(fileURLWithPath: path)
let options = PipelineOptions(speakers: value("--speakers").flatMap(Int.init))
let machine = args.contains("--progress")

final class StageMeter: @unchecked Sendable {
    var stage: PipelineStage?
    var shown = -1.0
}
let meter = StageMeter()

let started = Date()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-cli-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }
do {
    let transcript = try await Pipeline().run(input, workFolder: work, options: options, stage: { stage, fraction in
        if meter.stage != stage {
            meter.stage = stage
            meter.shown = -1
            print("\(stage.rawValue)…")
        }
        if machine, fraction - meter.shown >= 0.01 || (fraction >= 1 && meter.shown < 1) {
            meter.shown = fraction
            print("@stage \(stage) \(String(format: "%.3f", fraction))")
        }
    }, log: { print($0) })

    if let json = value("--json") {
        try transcript.save(URL(fileURLWithPath: json))
    } else {
        let folder = value("--out").map { URL(fileURLWithPath: $0) } ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
        try transcript.save(stem.appendingPathExtension("json"))
        for format in ExportFormat.allCases {
            try Exporter.write(transcript, as: format, to: stem.appendingPathExtension(format.fileExtension))
        }
    }
    print(String(format: "Done in %.1f s: %d words, %d speaker%@", Date().timeIntervalSince(started),
                 transcript.wordCount, transcript.speakers.count, transcript.speakers.count == 1 ? "" : "s"))
} catch {
    print("Failed: \(error.localizedDescription)")
    exit(1)
}
