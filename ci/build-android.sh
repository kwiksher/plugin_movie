#!/usr/bin/env bash
#
# Build the Android plugin (all four ABIs) and pack android.tgz.
#
# The Corona Android prebuilts (liblua.so / libcorona.so / libopenal.so) and the
# ogg/vorbis/theora static libs are vendored in android/corona-libs and
# android/jni/<abi>, so the only external input is a Corona-compatible header
# tree - see ci/corona-native.sh.
#
# Usage:
#   ci/build-android.sh <out-dir>
#
# Environment:
#   CORONA_NATIVE      Corona tree (default: .ci/corona-native in the repo root)
#   ANDROID_NDK_HOME   NDK root (also checked: ANDROID_NDK_ROOT, $1 fallback)
#   APP_ABIS           space separated, default: "arm64-v8a armeabi-v7a x86 x86_64"
#   ANDROID_PLATFORM   default: android-21 (NDK r23+ refuses android-16 from Application.mk)
#
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '  %s\n' "$*"; }

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR=${1:-"$REPO_ROOT/dist/android"}
CORONA_NATIVE=${CORONA_NATIVE:-"$REPO_ROOT/.ci/corona-native"}
NDK=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
APP_ABIS=${APP_ABIS:-"arm64-v8a armeabi-v7a x86 x86_64"}
ANDROID_PLATFORM=${ANDROID_PLATFORM:-android-21}

[ -n "$NDK" ] || die "set ANDROID_NDK_HOME to an installed NDK"
[ -x "$NDK/ndk-build" ] || die "$NDK/ndk-build not found"
[ -d "$CORONA_NATIVE/Corona/shared/include/Corona" ] \
	|| die "$CORONA_NATIVE is not a Corona tree (run ci/corona-native.sh first)"

mkdir -p "$OUT_DIR"

log "NDK: $(tr -d '\r\n' < "$NDK/source.properties" 2>/dev/null | grep -i revision | sed 's/.*=//')"
log "ABIs: $APP_ABIS ($ANDROID_PLATFORM)"

# APP_ABI / APP_PLATFORM / APP_STL are passed on the command line so they win
# over android/jni/Application.mk without editing it for CI.
(
	cd "$REPO_ROOT/android"
	CORONA_NATIVE="$CORONA_NATIVE" "$NDK/ndk-build" \
		NDK_PROJECT_PATH=. \
		APP_BUILD_SCRIPT=jni/Android.mk \
		APP_ABI="$APP_ABIS" \
		APP_PLATFORM="$ANDROID_PLATFORM" \
		APP_STL=c++_static \
		APP_OPTIM=release \
		-j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" \
		APP_CFLAGS="-Wno-null-conversion"
)

# Ship the fresh builds in place of whatever was last committed to jniLibs.
for abi in $APP_ABIS; do
	so="libplugin.movie.so"
	[ -f "$REPO_ROOT/android/libs/$abi/$so" ] || die "missing android/libs/$abi/$so"
	mkdir -p "$REPO_ROOT/android/jniLibs/$abi"
	cp "$REPO_ROOT/android/libs/$abi/$so" "$REPO_ROOT/android/jniLibs/$abi/$so"

	# Smoke test: the plugin is useless unless Corona can find its entry point.
	NM=$(find "$NDK/toolchains/llvm/prebuilt" -maxdepth 3 -name 'llvm-nm' -print -quit)
	if [ -n "$NM" ]; then
		# Capture first: `nm ... | grep -q` races under `set -o pipefail`, because
		# grep exits on the first match and nm then dies of SIGPIPE, which fails
		# the pipeline even though the symbol was found. Both globs are needed -
		# a bare `*pattern` is a suffix match, and this is not the last symbol.
		symbols=$("$NM" -D --defined-only "$REPO_ROOT/android/jniLibs/$abi/$so")
		case "$symbols" in
			*"T luaopen_plugin_movie"*) ;;
			*) die "$abi: luaopen_plugin_movie is not exported" ;;
		esac
		log "$abi: $(file -b "$REPO_ROOT/android/jniLibs/$abi/$so" | cut -d, -f1-2), luaopen_plugin_movie exported"
	else
		log "$abi: built (llvm-nm not found, export not verified)"
	fi
done

# android.tgz is the Corona plugin package for Android.
(
	cd "$REPO_ROOT/android"
	tar -czf "$OUT_DIR/android.tgz" metadata.lua jniLibs
)
log "package: $OUT_DIR/android.tgz"
