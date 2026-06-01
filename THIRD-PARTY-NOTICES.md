# Third-Party Notices

GMApplePlayer is distributed under the MIT License (see `LICENSE`). It builds
against the following third-party component.

## FFmpeg

- Project: FFmpeg (https://ffmpeg.org)
- Version: 8.1.1 (pinned in `Scripts/build-ffmpeg.sh`)
- License: GNU Lesser General Public License, version 2.1 or later (LGPL-2.1+)

This project does **not** vendor FFmpeg binaries or source in the repository.
`Scripts/build-ffmpeg.sh` downloads the official FFmpeg 8.1.1 source release from
ffmpeg.org, verifies its SHA-256, and cross-compiles a **remux-only** static
`FFmpeg.xcframework` (libavformat, libavcodec, libavutil).

The configuration uses `--disable-everything` and re-enables only the demuxers,
muxers, parsers, bitstream filters, and protocols needed to repackage (stream
copy) media. No encoders or decoders are built, and **no GPL-only components**
(such as libx264 or GPL filters) are enabled, so the resulting libraries are
LGPL-2.1+, not GPL.

To comply with the LGPL, the FFmpeg source version is pinned and publicly
downloadable, the exact build configuration is in `Scripts/build-ffmpeg.sh`, and
FFmpeg is built as separate libraries that can be rebuilt and relinked. The full
FFmpeg license texts ship with the FFmpeg source (`COPYING.LGPLv2.1`, etc.).
