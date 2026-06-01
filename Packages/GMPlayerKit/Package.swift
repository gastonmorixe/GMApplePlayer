// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GMPlayerKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "GMPlayerKit", targets: ["GMPlayerKit"]),
        .executable(name: "gmremux-cli", targets: ["gmremux-cli"]),
    ],
    targets: [
        // Prebuilt FFmpeg 8.1.1 (remux-only) static libs, all Apple slices.
        .binaryTarget(
            name: "FFmpeg",
            path: "Frameworks/FFmpeg.xcframework"
        ),

        // C remux engine, split for SRP: compat.c (codec policy + scoring),
        // probe.c (probing), remux.c (stream-copy). Compiled against FFmpeg's
        // private headers (ffmpeg-include/); only include/gmremux.h is public.
        .target(
            name: "CFFmpeg",
            dependencies: ["FFmpeg", "CGMTimestamp"],
            path: "Sources/CFFmpeg",
            sources: ["compat.c", "probe.c", "remux.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("ffmpeg-include"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Security"),
            ]
        ),

        // Pure, FFmpeg-free timestamp policy for the remux copy loop. Split out
        // so it is unit-testable without the xcframework or a media file.
        .target(
            name: "CGMTimestamp",
            path: "Sources/CGMTimestamp",
            publicHeadersPath: "include"
        ),

        // On-demand streaming remux engine: dual AVIO (caller byte source in,
        // fragmented-MP4 segments out) so AVPlayer can stream+seek an MKV without
        // downloading/remuxing the whole file. gm_plan.c is pure (unit-tested);
        // gm_stream.c uses FFmpeg + reuses gm_ts (DTS) + gm_auto_select (CFFmpeg).
        .target(
            name: "CGMStream",
            dependencies: ["FFmpeg", "CGMTimestamp", "CFFmpeg"],
            path: "Sources/CGMStream",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../CFFmpeg/ffmpeg-include"),
            ]
        ),

        // Swift API + SwiftUI player view.
        .target(
            name: "GMPlayerKit",
            dependencies: ["CFFmpeg", "CGMStream"],
            path: "Sources/GMPlayerKit"
        ),

        .executableTarget(
            name: "gmremux-cli",
            dependencies: ["GMPlayerKit"],
            path: "Sources/gmremux-cli"
        ),
        // Dev-only headless harness to drive the streaming resource-loader path
        // against a real AVPlayer (diagnose playback failures end to end).
        .executableTarget(
            name: "gmstreamtest",
            dependencies: ["GMPlayerKit"],
            path: "Sources/gmstreamtest"
        ),
        .testTarget(
            name: "GMPlayerKitTests",
            dependencies: ["GMPlayerKit"],
            path: "Tests/GMPlayerKitTests"
        ),
        // Pure-C timestamp policy tests (no FFmpeg, no media file): fast, and
        // they pin the exact DTS/PTS cadence the remux must produce.
        .testTarget(
            name: "CGMTimestampTests",
            dependencies: ["CGMTimestamp"],
            path: "Tests/CGMTimestampTests"
        ),
        // Pure segmentation-plan tests (no FFmpeg, no network): keyframe grouping,
        // time->segment mapping. Exercises the C gm_plan API via the CGMStream module.
        .testTarget(
            name: "CGMStreamTests",
            dependencies: ["CGMStream"],
            path: "Tests/CGMStreamTests"
        ),
    ]
)
