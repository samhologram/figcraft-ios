#!/usr/bin/env bash
# Build the Rust bridge into FigCraftBridge.xcframework + generated Swift bindings.
#
# Usage: apple/scripts/build-xcframework.sh [--debug] [--sim-only] [-h|--help]
#   --debug     build the Rust bridge in debug profile (faster compile, slow runtime)
#   --sim-only  build only the iOS Simulator slice for the host architecture
#   (without it: device aarch64-apple-ios + Apple-silicon simulator aarch64-apple-ios-sim)
#
# Environment: CRAFT_FONTS_DIR is passed through to cargo (engine build.rs / font bundling).
# Idempotent: outputs are removed and regenerated on every run.
set -euo pipefail

PROFILE=release
PROFILE_FLAG=(--release)
SIM_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE=debug; PROFILE_FLAG=() ;;
    --sim-only) SIM_ONLY=1 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: build-xcframework.sh needs macOS with Xcode (xcodebuild, lipo)." >&2
  exit 1
fi
for tool in cargo rustup xcodebuild lipo; do
  command -v "$tool" >/dev/null || { echo "error: '$tool' not found in PATH" >&2; exit 1; }
done

APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$APPLE_DIR/bridge"
KIT_DIR="$APPLE_DIR/FigCraftKit"
BUILD_DIR="$APPLE_DIR/build/xcframework"
XCFRAMEWORK="$KIT_DIR/FigCraftBridge.xcframework"
SWIFT_DEST="$KIT_DIR/Sources/FigCraftKit"
LIB=libfigcraft_apple.a
MODULE=figcraft_appleFFI

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
if [[ -n "${CRAFT_FONTS_DIR:-}" ]]; then
  export CRAFT_FONTS_DIR
  echo "==> CRAFT_FONTS_DIR=$CRAFT_FONTS_DIR"
fi

if [[ "$SIM_ONLY" == 1 ]]; then
  case "$(uname -m)" in
    arm64) TARGETS=(aarch64-apple-ios-sim) ;;
    *) TARGETS=(x86_64-apple-ios) ;;
  esac
else
  TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)
fi

INSTALLED="$(rustup target list --installed)"
for t in "${TARGETS[@]}"; do
  if ! grep -qx "$t" <<<"$INSTALLED"; then
    echo "==> rustup target add $t"
    rustup target add "$t"
  fi
done

cd "$BRIDGE_DIR"
for t in "${TARGETS[@]}"; do
  echo "==> cargo build ($PROFILE) for $t"
  cargo build ${PROFILE_FLAG[@]+"${PROFILE_FLAG[@]}"} --lib --target "$t"
done

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/headers" "$BUILD_DIR/sim" "$BUILD_DIR/bindings"
target_lib() { echo "$BRIDGE_DIR/target/$1/$PROFILE/$LIB"; }

# Simulator slice: lipo arm64 + x86_64 when both were built.
SIM_LIBS=()
for t in aarch64-apple-ios-sim x86_64-apple-ios; do
  [[ " ${TARGETS[*]} " == *" $t "* ]] && SIM_LIBS+=("$(target_lib "$t")")
done
if [[ ${#SIM_LIBS[@]} -gt 1 ]]; then
  lipo -create "${SIM_LIBS[@]}" -output "$BUILD_DIR/sim/$LIB"
else
  cp "${SIM_LIBS[0]}" "$BUILD_DIR/sim/$LIB"
fi

echo "==> Generating Swift bindings (uniffi-bindgen)"
cd "$BRIDGE_DIR"
cargo run ${PROFILE_FLAG[@]+"${PROFILE_FLAG[@]}"} --features cli --bin uniffi-bindgen -- \
  generate --library "${SIM_LIBS[0]}" --language swift --out-dir "$BUILD_DIR/bindings"

cp "$BUILD_DIR/bindings/${MODULE}.h" "$BUILD_DIR/headers/"
cp "$BUILD_DIR/bindings/${MODULE}.modulemap" "$BUILD_DIR/headers/module.modulemap"

echo "==> Creating $XCFRAMEWORK"
rm -rf "$XCFRAMEWORK"
ARGS=(-library "$BUILD_DIR/sim/$LIB" -headers "$BUILD_DIR/headers")
if [[ "$SIM_ONLY" == 0 ]]; then
  ARGS+=(-library "$(target_lib aarch64-apple-ios)" -headers "$BUILD_DIR/headers")
fi
xcodebuild -create-xcframework "${ARGS[@]}" -output "$XCFRAMEWORK"

mkdir -p "$SWIFT_DEST"
cp "$BUILD_DIR/bindings/figcraft_apple.swift" "$SWIFT_DEST/figcraft_apple.swift"

echo "==> Done"
echo "    $XCFRAMEWORK"
echo "    $SWIFT_DEST/figcraft_apple.swift"
