import Foundation
import GMPlayerKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: gmremux-cli <input> [output.mp4]")
    exit(2)
}

let input = args[1]
let output = args.count >= 3 ? args[2] : NSTemporaryDirectory() + "gmremux-out.mp4"

print("FFmpeg \(GMRemuxer.ffmpegVersion)")
do {
    let probe = try GMRemuxer.probeSync(input)
    print("format: \(probe.formatName)  duration: \(String(format: "%.1f", probe.durationSeconds))s")
    for s in probe.streams {
        let mark = s.avfCompatible ? "✓" : "✗"
        print("  [\(s.id)] \(s.kind) \(mark) \(s.displayLabel)")
    }
    print("--- remuxing (auto-select) -> \(output)")
    var lastPct = -1
    try GMRemuxer.remuxSync(input: input, outputURL: URL(fileURLWithPath: output)) { frac in
        let pct = Int(frac * 100)
        if pct != lastPct, pct % 20 == 0 { print("    \(pct)%")
            lastPct = pct
        }
        return true
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: output)[.size]) as? Int) ?? 0
    print("DONE -> \(output) (\(size / 1_000_000) MB)")
} catch {
    print("ERROR: \(error)")
    exit(1)
}
