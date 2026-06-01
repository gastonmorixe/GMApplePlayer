#!/usr/bin/env bash
#
# build-ffmpeg.sh, Cross-compile a REMUX-ONLY FFmpeg 8.1.1 into an
# FFmpeg.xcframework for Apple platforms (macOS / iOS / tvOS, device + simulator,
# all arm64).
#
# "Remux-only" means: no encoders, no decoders, no scale/resample/filter/device
# libraries. Just enough of libavformat + libavcodec (parsers + bitstream
# filters) + libavutil to demux MKV/MOV/MPEG-TS and mux fragmented MP4, copying
# elementary streams without re-encoding.
#
# Output:
#   <GM_ROOT>/Packages/GMPlayerKit/Frameworks/FFmpeg.xcframework
#
# Usage:
#   ./build-ffmpeg.sh [platform ...]
#   platforms: macos ios ios-sim tvos tvos-sim   (default: all five)
#
#   ./build-ffmpeg.sh macos                       # just mac slice (fast loop)
#   FFMPEG_ENABLE_NETWORK=0 ./build-ffmpeg.sh macos   # local-file-only, fewest deps
#   ./build-ffmpeg.sh                             # all slices + xcframework
#
# Env:
#   FFMPEG_SRC             path to extracted ffmpeg source. If it exists it is
#                          used as-is (fast local loop). If it does NOT exist,
#                          the pinned FFMPEG_VERSION release is downloaded,
#                          checksum-verified, and extracted automatically, so a
#                          fresh clone or CI runner needs zero manual setup.
#   FFMPEG_ENABLE_NETWORK  1 (default) = http/https via SecureTransport; 0 = file only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLE_PLATFORM="$(cd "$GM_ROOT/.." && pwd)"
BUILD_ROOT="$GM_ROOT/build/ffmpeg"
FRAMEWORKS_DIR="$GM_ROOT/Packages/GMPlayerKit/Frameworks"
XCFRAMEWORK="$FRAMEWORKS_DIR/FFmpeg.xcframework"
ENABLE_NETWORK="${FFMPEG_ENABLE_NETWORK:-1}"

# Pinned FFmpeg release. FFMPEG_SHA256 is the official ffmpeg.org tarball digest;
# bump all three together when moving versions.
FFMPEG_VERSION="8.1.1"
FFMPEG_SHA256="b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

# Default to a sibling checkout (the local dev layout); auto-downloaded if absent.
FFMPEG_SRC="${FFMPEG_SRC:-$APPLE_PLATFORM/repos/ffmpeg-${FFMPEG_VERSION}}"

# Resolve FFMPEG_SRC: if it already holds an ffmpeg tree, use it untouched
# (your machine: ../repos/ffmpeg-8.1.1). Otherwise fetch + verify + extract the
# pinned release into build/ffmpeg/src and point at that (fresh clone / CI).
ensure_ffmpeg_src() {
  if [[ -f "$FFMPEG_SRC/configure" ]]; then
    echo "==> FFmpeg source: $FFMPEG_SRC (existing)"
    return
  fi
  echo "==> FFmpeg source not found at: $FFMPEG_SRC"
  echo "    auto-fetching FFmpeg $FFMPEG_VERSION ..."
  local cache="$BUILD_ROOT/src"
  local tarball="$cache/ffmpeg-${FFMPEG_VERSION}.tar.xz"
  local extracted="$cache/ffmpeg-${FFMPEG_VERSION}"
  mkdir -p "$cache"
  if [[ ! -f "$extracted/configure" ]]; then
    if [[ ! -f "$tarball" ]]; then
      echo "    downloading $FFMPEG_URL"
      curl -fSL --retry 3 -o "$tarball.part" "$FFMPEG_URL"
      mv "$tarball.part" "$tarball"
    fi
    echo "    verifying sha256"
    if ! echo "$FFMPEG_SHA256  $tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
      echo "    ERROR: checksum mismatch for $tarball" >&2
      echo "    expected $FFMPEG_SHA256" >&2
      echo "    got      $(shasum -a 256 "$tarball" | awk '{print $1}')" >&2
      rm -f "$tarball"
      exit 1
    fi
    echo "    extracting -> $extracted"
    tar -xJf "$tarball" -C "$cache"
  fi
  FFMPEG_SRC="$extracted"
  echo "    FFmpeg source ready: $FFMPEG_SRC"
}

MACOS_MIN="12.0"; IOS_MIN="15.0"; TVOS_MIN="15.0"

# Remux-only component set. Names verified against FFmpeg 8.1.1 source
# (libavformat/allformats.c, libavcodec/parsers.c, ffbuild bsf list).
COMMON_FLAGS=(
  --disable-everything
  --disable-programs --disable-doc --disable-debug
  --disable-shared --enable-static --enable-pic --enable-small
  --disable-autodetect
  --enable-avformat --enable-avcodec
  --disable-avdevice --disable-avfilter --disable-swscale
  --disable-swresample
  # input containers
  --enable-demuxer=matroska --enable-demuxer=mov --enable-demuxer=mpegts
  --enable-demuxer=mp3 --enable-demuxer=aac --enable-demuxer=ac3
  --enable-demuxer=flac --enable-demuxer=wav
  # output containers
  --enable-muxer=mov --enable-muxer=mp4
  # parsers (needed to repacketize elementary streams during copy)
  --enable-parser=hevc --enable-parser=h264 --enable-parser=aac
  --enable-parser=aac_latm --enable-parser=ac3 --enable-parser=av1
  --enable-parser=mpegaudio --enable-parser=flac --enable-parser=opus
  --enable-parser=vorbis --enable-parser=dca --enable-parser=vp9
  # bitstream filters used in remux (annexb<->mp4, adts->asc, extradata)
  --enable-bsf=hevc_mp4toannexb --enable-bsf=h264_mp4toannexb
  --enable-bsf=vvc_mp4toannexb --enable-bsf=aac_adtstoasc
  --enable-bsf=extract_extradata --enable-bsf=dump_extradata --enable-bsf=setts
  # ── subtitles: TEXT subs -> WebVTT for HLS subtitle renditions ──────────────
  # AVPlayer's HLS subtitle renditions are WebVTT only; image subs (PGS/VobSub)
  # cannot be carried. We DECODE the source text subtitle (subrip/ass/mov_text/
  # webvtt) and ENCODE WebVTT segments. The matroska/mov demuxers above already
  # read the subtitle packets; these add the codec + WebVTT muxer.
  # decoders: turn the source text subtitle into ASS/text the encoder consumes
  --enable-decoder=subrip --enable-decoder=srt --enable-decoder=ass
  --enable-decoder=ssa --enable-decoder=movtext --enable-decoder=webvtt
  --enable-decoder=text
  # encoder + muxer: emit WebVTT segments AVPlayer's HLS subtitle renditions need
  --enable-encoder=webvtt --enable-muxer=webvtt
  # (subtitle packets come from the matroska/mov demuxers already enabled above;
  #  no standalone subtitle demuxer is needed for in-container subs.)
  # always need local file IO
  --enable-protocol=file
)

NETWORK_FLAGS=(
  --enable-network
  --enable-protocol=http --enable-protocol=https --enable-protocol=tcp
  --enable-protocol=tls --enable-protocol=crypto --enable-protocol=data
  --enable-securetransport
  --enable-demuxer=hls
)

# build_slice <slice> <arch> <sdk> <min-flag>
build_slice() {
  local slice="$1" arch="$2" sdk="$3" minflag="$4"
  local prefix="$BUILD_ROOT/$slice"
  local sysroot cc
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"

  echo "==> [$slice] arch=$arch sdk=$sdk min=$minflag network=$ENABLE_NETWORK"
  rm -rf "$prefix" "$BUILD_ROOT/obj-$slice"
  mkdir -p "$BUILD_ROOT/obj-$slice"
  pushd "$BUILD_ROOT/obj-$slice" >/dev/null

  local cflags="-arch $arch $minflag -isysroot $sysroot -fembed-bitcode-marker -Os"
  local ldflags="-arch $arch $minflag -isysroot $sysroot"

  local -a flags=("${COMMON_FLAGS[@]}")
  if [[ "$ENABLE_NETWORK" == "1" ]]; then
    flags+=("${NETWORK_FLAGS[@]}")
  else
    flags+=(--disable-network)
  fi

  "$FFMPEG_SRC/configure" \
    --prefix="$prefix" \
    --enable-cross-compile --target-os=darwin --arch="$arch" \
    --cc="$cc" --sysroot="$sysroot" \
    --extra-cflags="$cflags" --extra-ldflags="$ldflags" \
    "${flags[@]}" >"$BUILD_ROOT/configure-$slice.log" 2>&1 || {
      echo "    configure FAILED; tail of log:"; tail -25 "$BUILD_ROOT/configure-$slice.log"; exit 1; }

  echo "    make -j$(sysctl -n hw.ncpu) ..."
  make -j"$(sysctl -n hw.ncpu)" >"$BUILD_ROOT/make-$slice.log" 2>&1 || {
      echo "    make FAILED; tail of log:"; tail -25 "$BUILD_ROOT/make-$slice.log"; exit 1; }
  make install >>"$BUILD_ROOT/make-$slice.log" 2>&1
  popd >/dev/null
  echo "    [$slice] OK -> $prefix"
}

assemble_xcframework() {
  echo "==> Assembling FFmpeg.xcframework from: $*"
  rm -rf "$XCFRAMEWORK"; mkdir -p "$FRAMEWORKS_DIR"
  local -a args=()
  for slice in "$@"; do
    local prefix="$BUILD_ROOT/$slice"
    [[ -d "$prefix/lib" ]] || { echo "    skip $slice (not built)"; continue; }
    local merged="$prefix/libFFmpeg.a"
    # Merge whatever libav*/libsw* slices exist (remux-only = libav* only).
    libtool -static -o "$merged" "$prefix"/lib/lib*.a 2>/dev/null
    args+=(-library "$merged" -headers "$prefix/include")
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$XCFRAMEWORK"
  echo "    created $XCFRAMEWORK"
}

PLATFORMS=("$@")
[[ ${#PLATFORMS[@]} -eq 0 ]] && PLATFORMS=(macos ios ios-sim tvos tvos-sim)

ensure_ffmpeg_src

BUILT=()
for p in "${PLATFORMS[@]}"; do
  case "$p" in
    macos)    build_slice macos    arm64 macosx           "-mmacosx-version-min=$MACOS_MIN";        BUILT+=(macos) ;;
    ios)      build_slice ios      arm64 iphoneos         "-mios-version-min=$IOS_MIN";             BUILT+=(ios) ;;
    ios-sim)  build_slice ios-sim  arm64 iphonesimulator  "-mios-simulator-version-min=$IOS_MIN";   BUILT+=(ios-sim) ;;
    tvos)     build_slice tvos     arm64 appletvos        "-mtvos-version-min=$TVOS_MIN";           BUILT+=(tvos) ;;
    tvos-sim) build_slice tvos-sim arm64 appletvsimulator "-mtvos-simulator-version-min=$TVOS_MIN"; BUILT+=(tvos-sim) ;;
    *) echo "unknown platform: $p" >&2; exit 2 ;;
  esac
done
assemble_xcframework "${BUILT[@]}"
echo "DONE ($(printf '%s ' "${BUILT[@]}"))."
