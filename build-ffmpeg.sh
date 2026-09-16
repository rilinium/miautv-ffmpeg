#!/bin/bash
#
# Builds FFmpeg.xcframework: one dynamic framework per platform, LGPL only.
#
# Two things matter here and both are deliberate.
#
# LGPL, and 2.1 rather than 3. FFmpeg is LGPL 2.1 by default and only becomes GPL if you ask
# it to be, which the stock FFmpegKit release does. Passing disableGPL drops the GPL parts.
# FFmpegKit also passes --enable-version3, which lifts the whole build to LGPL 3, and LGPL 3
# is the version that does not sit well with the App Store: its anti-tivoization terms and
# the store's own restrictions on what a user may do with a signed binary pull against each
# other. VLC relicensed to 2.1 for exactly this reason. So the flag comes back out, which
# costs nothing once libsmbclient is gone: it was the only version3 component in the list.
# gmp goes for the same reason, being LGPL 3 itself; all it buys FFmpeg is RTMPE handshakes.
# Both claims are checked against the built artefact rather than taken on trust.
#
# Dynamic. FFmpegKit packages its output as static archives wearing a .framework directory,
# and static linking is the awkward half of the LGPL: it obliges us to hand out the app's
# object files so somebody could relink it against their own FFmpeg. Linking the archives
# into a real dylib instead means the swap is just replacing a file in the bundle, which is
# what the licence asks for and costs us nothing.
#
# Usage: Tools/build-ffmpeg.sh [platform ...]
#        defaults to every platform Miau TV ships on.
#
# Needs: brew install autoconf automake nasm yasm meson gnu-sed
#
set -euo pipefail

REPO="https://github.com/kingslay/FFmpegKit.git"
# Pinned: the build tree is patched below by line content, so a moving target would break it.
REV="6.1.4"

# FFmpeg 6.1's vf_scale_vt.c calls VTPixelTransferSession, which is tvOS/iOS 16 and up.
# FFmpegKit still asks for 13.0 and builds with -Werror, so the unguarded availability is a
# hard error. Nothing we ship runs on 16 or below anyway.
MIN_VERSION="17.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${FFMPEG_BUILD_DIR:-$ROOT/.ffmpeg-build}"
OUT="$ROOT/Vendor"

ALL_PLATFORMS=(tvos tvsimulator ios isimulator maccatalyst)
PLATFORMS=("${@:-}")
[ -z "${PLATFORMS[0]:-}" ] && PLATFORMS=("${ALL_PLATFORMS[@]}")

# gnu-sed, because the build scripts are written for GNU userland.
export PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:/usr/local/bin:$PATH"

for tool in autoconf automake nasm yasm meson gsed; do
  command -v "$tool" >/dev/null || { echo "missing $tool: brew install autoconf automake nasm yasm meson gnu-sed"; exit 1; }
done

# --- the FFmpeg build itself -------------------------------------------------

if [ ! -d "$WORK/.git" ]; then
  git clone --depth 1 --branch "$REV" "$REPO" "$WORK"
fi

MAIN="$WORK/Plugins/BuildFFmpeg/main.swift"
if grep -q 'return "13.0"' "$MAIN"; then
  gsed -i 's/return "13\.0"/return "'"$MIN_VERSION"'"/g' "$MAIN"
fi

CONFIGURE="$WORK/Plugins/BuildFFmpeg/BuildFFMPEG.swift"
if grep -q '"--enable-version3"' "$CONFIGURE"; then
  gsed -i 's/"--enable-version3",[[:blank:]]*//' "$CONFIGURE"
fi

# Our own changes to FFmpeg itself. FFmpegKit applies anything left here to the source after it
# fetches it, resetting the tree first, so this survives a re-run.
mkdir -p "$WORK/Plugins/BuildFFmpeg/patch/FFmpeg"
cp "$ROOT/Tools/ffmpeg-patches/"*.patch "$WORK/Plugins/BuildFFmpeg/patch/FFmpeg/"

JOINED=$(IFS=,; echo "${PLATFORMS[*]}")
# FFmpeg takes the better part of an hour per platform, so repackaging an existing tree is
# worth being able to ask for on its own.
if [ -z "${FFMPEG_SKIP_BUILD:-}" ]; then
  echo "building FFmpeg for $JOINED"
  (
    cd "$WORK"
    # notRecompile leaves platforms that are already built alone, which is what makes adding one
    # more bearable. To force the lot again, delete .ffmpeg-build/.Script/FFmpeg first.
    swift package --disable-sandbox BuildFFmpeg disableGPL notRecompile "platforms=$JOINED" enable-FFmpeg
  )
fi

# --- one dynamic framework per platform --------------------------------------

SCRIPT_DIR="$WORK/.Script"
STAGE="$WORK/.dynamic"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Headers describing hardware and windowing stacks that do not exist on any Apple platform.
# They are part of the public tree but include things like <d3d11.h>, so an umbrella module
# cannot be built while they are present.
FOREIGN_HEADERS=(
  libavcodec/d3d11va.h libavcodec/dxva2.h libavcodec/qsv.h libavcodec/vdpau.h
  libavcodec/xvmc.h libavcodec/mathops.h
  libavutil/hwcontext_d3d11va.h libavutil/hwcontext_d3d12va.h libavutil/hwcontext_dxva2.h
  libavutil/hwcontext_qsv.h libavutil/hwcontext_vdpau.h libavutil/hwcontext_vaapi.h
  libavutil/hwcontext_vulkan.h libavutil/hwcontext_opencl.h libavutil/hwcontext_cuda.h
  libavutil/hwcontext_drm.h libavutil/hwcontext_mediacodec.h libavutil/hwcontext_amf.h
  libavutil/vulkan.h libavutil/vulkan_functions.h libavutil/vulkan_loader.h
)

# Link order is bottom up: avutil underpins everything, avformat and avfilter sit on avcodec.
#
# libavdevice is left out. It is FFmpeg's capture side, cameras and screens and sound cards, and
# a playback app never opens one. Under Catalyst it also brings in an AVFoundation input device
# written in Objective-C, which -all_load drags into the link whether anything wants it or not.
FFMPEG_LIBS=(avformat avcodec avfilter swresample swscale avutil)

platform_sdk() {
  case "$1" in
    tvos) echo appletvos ;;
    tvsimulator) echo appletvsimulator ;;
    ios) echo iphoneos ;;
    isimulator) echo iphonesimulator ;;
    maccatalyst) echo macosx ;;
  esac
}

platform_archs() {
  case "$1" in
    tvos|ios) echo arm64 ;;
    *) echo "arm64 x86_64" ;;
  esac
}

platform_triple() {
  case "$1" in
    tvos) echo "$2-apple-tvos$MIN_VERSION" ;;
    tvsimulator) echo "$2-apple-tvos$MIN_VERSION-simulator" ;;
    ios) echo "$2-apple-ios$MIN_VERSION" ;;
    isimulator) echo "$2-apple-ios$MIN_VERSION-simulator" ;;
    maccatalyst) echo "$2-apple-ios$MIN_VERSION-macabi" ;;
  esac
}

platform_bundle() {
  case "$1" in
    tvos) echo AppleTVOS ;;
    tvsimulator) echo AppleTVSimulator ;;
    ios|maccatalyst) echo iPhoneOS ;;
    isimulator) echo iPhoneSimulator ;;
  esac
}

FRAMEWORK_ARGS=()

for platform in "${PLATFORMS[@]}"; do
  thin="$SCRIPT_DIR/FFmpeg/$platform/thin"
  [ -d "$thin" ] || { echo "no FFmpeg output for $platform"; exit 1; }

  sdk=$(platform_sdk "$platform")
  sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
  archs=$(platform_archs "$platform")

  # The licence check, per platform, on the artefact rather than on the command line.
  config="$SCRIPT_DIR/FFmpeg/$platform/scratch/$(echo $archs | cut -d' ' -f1)/config.h"
  if ! grep -q "^#define CONFIG_GPL 0$" "$config"; then
    echo "refusing to package $platform: this build is not LGPL (see $config)"
    exit 1
  fi
  if ! grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"$' "$config"; then
    echo "refusing to package $platform: wanted LGPL 2.1, got $(grep -m1 FFMPEG_LICENSE "$config")"
    exit 1
  fi

  slices=()
  for arch in $archs; do
    lib="$thin/$arch/lib"

    catalyst_flags=()
    if [ "$platform" = "maccatalyst" ]; then
      catalyst_flags=(
        -isystem "$sdk_path/System/iOSSupport/usr/include"
        -iframework "$sdk_path/System/iOSSupport/System/Library/Frameworks"
      )
    fi

    archives=()
    for name in "${FFMPEG_LIBS[@]}"; do
      archives+=("$lib/lib$name.a")
    done
    echo "linking $platform/$arch"
    xcrun clang -dynamiclib \
      -target "$(platform_triple "$platform" "$arch")" \
      -isysroot "$sdk_path" \
      "${catalyst_flags[@]+"${catalyst_flags[@]}"}" \
      -install_name @rpath/FFmpeg.framework/FFmpeg \
      -Wl,-all_load \
      "${archives[@]}" \
      -lz -lbz2 -lxml2 -liconv -licucore -lpthread -lm \
      -framework AudioToolbox -framework VideoToolbox -framework CoreMedia \
      -framework CoreVideo -framework CoreFoundation -framework CoreGraphics \
      -framework Metal -framework Security \
      -o "$STAGE/FFmpeg-$platform-$arch.dylib"

    slices+=("$STAGE/FFmpeg-$platform-$arch.dylib")
  done

  fw="$STAGE/$platform/FFmpeg.framework"
  mkdir -p "$fw/Headers" "$fw/Modules"
  lipo -create "${slices[@]}" -output "$fw/FFmpeg"

  first_arch=$(echo $archs | cut -d' ' -f1)
  cp -R "$thin/$first_arch/include/"* "$fw/Headers/"
  for header in "${FOREIGN_HEADERS[@]}"; do
    rm -f "$fw/Headers/$header"
  done

  cat > "$fw/Modules/module.modulemap" <<MODULEMAP
framework module FFmpeg [system] {
    umbrella "."
    export *
}
MODULEMAP

  version=$(sed -n 's/^#define FFMPEG_VERSION "n\{0,1\}\(.*\)"$/\1/p' \
    "$SCRIPT_DIR/FFmpeg/$platform/scratch/$first_arch/libavutil/ffversion.h" | head -1)
  rm -f "$fw/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleIdentifier string org.ffmpeg.FFmpeg" \
    -c "Add :CFBundleName string FFmpeg" \
    -c "Add :CFBundleExecutable string FFmpeg" \
    -c "Add :CFBundlePackageType string FMWK" \
    -c "Add :CFBundleVersion string ${version:-1}" \
    -c "Add :CFBundleShortVersionString string ${version:-1}" \
    -c "Add :MinimumOSVersion string $MIN_VERSION" \
    -c "Add :CFBundleSupportedPlatforms array" \
    -c "Add :CFBundleSupportedPlatforms: string $(platform_bundle "$platform")" \
    "$fw/Info.plist" >/dev/null

  # Catalyst is held to the Mac's bundle rules, where a framework keeps its contents under
  # Versions and its Info.plist in Resources. A flat one embeds and signs happily and then fails
  # validation on the way to the App Store, which is a long way to go to find out.
  if [ "$platform" = "maccatalyst" ]; then
    mkdir -p "$fw/Versions/A/Resources"
    for item in "$fw"/*; do
      [ "$item" = "$fw/Versions" ] && continue
      mv "$item" "$fw/Versions/A/"
    done
    mv "$fw/Versions/A/Info.plist" "$fw/Versions/A/Resources/Info.plist"
    ln -sfn A "$fw/Versions/Current"
    for item in FFmpeg Headers Modules Resources; do
      ln -sfn "Versions/Current/$item" "$fw/$item"
    done
  fi

  FRAMEWORK_ARGS+=(-framework "$fw")
done

# --- the xcframework ---------------------------------------------------------

mkdir -p "$OUT"
rm -rf "$OUT/FFmpeg.xcframework"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$OUT/FFmpeg.xcframework"

# FFmpeg's own licence travels with it, since what we ship is its binary.
cp "$SCRIPT_DIR/FFmpeg-n"*/COPYING.LGPLv2.1 "$OUT/FFmpeg.xcframework/LICENSE"

echo
echo "wrote $OUT/FFmpeg.xcframework"
file "$OUT/FFmpeg.xcframework/"*/FFmpeg.framework/FFmpeg | grep -c "dynamically linked" | xargs echo "dynamic slices:"
