#!/usr/bin/env bash
#
# Provision a CORONA_ROOT tree that the macOS, iOS, Android and Windows
# projects in this repo can build against on a machine that has no Corona /
# Solar2D Simulator installed.
#
# What it writes (matching Corona's own "Native" layout):
#
#   <dest>/Corona/shared/include/Corona/*.h   public plugin API headers
#   <dest>/Corona/shared/include/lua/*.h      Lua 5.1 headers
#   <dest>/Corona/mac/bin/lua                 executable stub (presence check only)
#   <dest>/Corona/mac/bin/lua2c.sh            lua2c stub (see below)
#   <dest>/Corona/win/bin/lua2c.bat           lua2c stub for the Windows build
#   <dest>/Corona/ios/lib/                    empty, silences ld search-path noise
#   <dest>/Corona/win/lib/                    empty unless --win-libs is used
#
# The headers are fetched from the Solar2D engine sources (the open source
# continuation of Corona SDK) at a pinned commit, so a build is reproducible.
#
# The lua2c stubs exist because every platform project normally shells out to
# Corona's lua2c tool at build time to turn shared/plugin_movie.lua into C. That
# tool needs a 32-bit Lua from the Simulator install. Instead the stubs copy the
# committed output, shared/generated/plugin_movie.c, which is byte-identical to
# what lua2c emits. Regenerate that file with a real Corona install whenever
# shared/plugin_movie.lua changes - CI will NOT notice the drift on its own.
#
# Usage:
#   ci/corona-native.sh <dest-dir> [--win-libs <zip-or-dir>]
#
# Environment:
#   S2D_REF   Solar2D commit/tag to take the headers from (default: pinned below)
#
set -euo pipefail

readonly DEFAULT_S2D_REF=22368dfc12090d3f61235050c7ff62a28ad6073e
readonly S2D_REF="${S2D_REF:-$DEFAULT_S2D_REF}"
readonly S2D_BASE="https://raw.githubusercontent.com/coronalabs/corona/${S2D_REF}"

# Public plugin API (CoronaGraphics.h pulls in CoronaMacros.h + CoronaPublicTypes.h,
# CoronaLua.h pulls in CoronaLog.h, CoronaLibrary.h pulls in CoronaLua.h).
readonly CORONA_HEADERS=(
	CoronaAssert.h
	CoronaEvent.h
	CoronaGraphics.h
	CoronaLibrary.h
	CoronaLog.h
	CoronaLua.h
	CoronaMacros.h
	CoronaMemory.h
	CoronaObjects.h
	CoronaPublicTypes.h
	CoronaVersion.h
)
readonly LUA_HEADERS=(lua.h luaconf.h lauxlib.h lualib.h)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '  %s\n' "$*"; }

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GENERATED_C="$REPO_ROOT/shared/generated/plugin_movie.c"

DEST=""
WIN_LIBS=""
while [ $# -gt 0 ]; do
	case "$1" in
		--win-libs) WIN_LIBS="${2:?--win-libs needs a path}"; shift 2 ;;
		-h|--help) sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
		-*) die "unknown option: $1" ;;
		*) [ -z "$DEST" ] || die "only one destination allowed"; DEST="$1"; shift ;;
	esac
done
[ -n "$DEST" ] || die "usage: ci/corona-native.sh <dest-dir> [--win-libs <zip-or-dir>]"
[ -f "$GENERATED_C" ] || die "missing $GENERATED_C - lua2c stubs have nothing to copy"

CORONA_DIR="$DEST/Corona"
INC_CORONA="$CORONA_DIR/shared/include/Corona"
INC_LUA="$CORONA_DIR/shared/include/lua"

mkdir -p "$INC_CORONA" "$INC_LUA" \
	"$CORONA_DIR/mac/bin" "$CORONA_DIR/win/bin" \
	"$CORONA_DIR/ios/lib" "$CORONA_DIR/win/lib" "$CORONA_DIR/mac/lib"

fetch() { # fetch <url> <dest>
	curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" \
		|| die "failed to download $1"
}

# Git Bash on the Windows runners has no unzip; bsdtar (tar.exe) reads zip files.
extract_zip() { # extract_zip <zip> <dest-dir>
	if command -v unzip >/dev/null 2>&1; then
		unzip -q "$1" -d "$2"
	elif tar -tf "$1" >/dev/null 2>&1; then
		mkdir -p "$2" && tar -xf "$1" -C "$2"
	elif command -v powershell >/dev/null 2>&1; then
		powershell -NoProfile -Command \
			"Expand-Archive -LiteralPath '$1' -DestinationPath '$2' -Force"
	else
		die "no zip extractor available for $1"
	fi
}

log "Solar2D headers @ ${S2D_REF:0:12}"
for h in "${CORONA_HEADERS[@]}"; do
	fetch "$S2D_BASE/librtt/Corona/$h" "$INC_CORONA/$h"
done
for h in "${LUA_HEADERS[@]}"; do
	fetch "$S2D_BASE/external/lua-5.1.3/src/$h" "$INC_LUA/$h"
done
log "${#CORONA_HEADERS[@]} Corona headers, ${#LUA_HEADERS[@]} Lua headers"

# --- lua2c stubs -------------------------------------------------------------
# Corona's mac build rule refuses to run unless $CORONA_ROOT/Corona/mac/bin/lua
# exists, and the Windows LuaToCpp target always shells out to lua2c.bat. Both
# are only presence-checked / invoked, so the stubs satisfy the projects.

cat > "$CORONA_DIR/mac/bin/lua" <<'STUB'
#!/bin/sh
echo "ci stub: no Lua interpreter in this Corona tree" >&2
exit 1
STUB
chmod +x "$CORONA_DIR/mac/bin/lua"

# Args: lua2c.sh <input.lua> <out-dir> <configuration> <corona-bin-dir>
cat > "$CORONA_DIR/mac/bin/lua2c.sh" <<STUB
#!/bin/sh
# ci stub - copies the committed lua2c output instead of running Corona's lua2c
set -e
out="\$2"
name=\$(basename "\$1" .lua)
cp "$GENERATED_C" "\$out/\$name.c"
STUB
chmod +x "$CORONA_DIR/mac/bin/lua2c.sh"

# Args (from win32/LuaToCppTask.targets):
#   lua2c.bat <bin-dir> <int-dir> <input.lua> <generated-files-dir> <config>
# cmd.exe needs a native Windows path here, even when this script runs in Git Bash.
GENERATED_C_WIN="$GENERATED_C"
if command -v cygpath >/dev/null 2>&1; then
	GENERATED_C_WIN=$(cygpath -w "$GENERATED_C")
fi
# .bat files are CRLF, and cmd.exe chokes on bare LF in some cases.
printf '@echo off\r\nrem ci stub - copies the committed lua2c output instead of running Corona lua2c\r\ncopy /Y "%s" "%%~4\\plugin_movie.c" >nul\r\n' \
	"$GENERATED_C_WIN" > "$CORONA_DIR/win/bin/lua2c.bat"

log "lua2c stubs wired to shared/generated/plugin_movie.c"

# --- optional real Corona Windows import libs --------------------------------
# A genuine plugin_movie.dll needs the Corona win import libs (lua.lib etc.).
# They ship with the Corona/Solar2D Simulator and are not redistributable here,
# so the Windows job links for real only when they are supplied.
if [ -n "$WIN_LIBS" ]; then
	if [ -d "$WIN_LIBS" ]; then
		cp -R "$WIN_LIBS"/. "$CORONA_DIR/win/lib/"
	elif [ -f "$WIN_LIBS" ]; then
		tmp=$(mktemp -d)
		extract_zip "$WIN_LIBS" "$tmp"
		# accept either a flat zip of .lib files or a Corona/win/lib tree
		found=$(find "$tmp" -name '*.lib' -print -quit)
		[ -n "$found" ] || die "no .lib files in $WIN_LIBS"
		find "$tmp" -name '*.lib' -exec cp {} "$CORONA_DIR/win/lib/" \;
		rm -rf "$tmp"
	else
		die "--win-libs: no such file or directory: $WIN_LIBS"
	fi
	log "Corona Windows import libs installed: $(ls "$CORONA_DIR/win/lib" | wc -l | tr -d ' ') file(s)"
else
	log "no Corona Windows import libs supplied (Windows build stays compile-only)"
fi

printf '\nCORONA_ROOT ready: %s\n' "$DEST"
