# CI builds

`.github/workflows/build.yml` builds the plugin for every platform Corona/Solar2D
loads it on, and packages the result as a Corona plugin bundle.

| Job | Runner | Produces |
| --- | --- | --- |
| `macos` | `macos-latest` | `plugin_movie.dylib` — universal (arm64 + x86_64) |
| `ios` | `macos-latest` | `libplugin_movie.a` for device (arm64) and simulator (arm64 + x86_64), in `BuiltPlugin/iphone{,-sim}` |
| `android` | `ubuntu-latest` | `libplugin.movie.so` for arm64-v8a, armeabi-v7a, x86, x86_64 + `android.tgz` |
| `windows` | `windows-latest` | `plugin_movie.dll` **when** the Corona Windows import libs are available, otherwise a MSVC compile check |
| `package` | `ubuntu-latest` | one `plugin.movie-<version>.zip`; published as a GitHub Release on `v*` tags |

Every job also runs on pull requests, so breakage is caught before merge.

## The Corona SDK dependency

Building a Corona plugin normally requires the Corona Native SDK installed by the
Simulator (`$HOME/Library/Application Support/Corona/Native`, `%CORONA_ROOT%` on
Windows). None of that is redistributable, so `ci/corona-native.sh` provisions a
`CORONA_ROOT`-shaped tree from public sources:

- **Headers** — the Corona plugin API (`CoronaLua.h`, `CoronaGraphics.h`,
  `CoronaLibrary.h`, …) and the Lua 5.1 headers, fetched at a pinned commit from
  the Solar2D engine sources (the open source continuation of Corona SDK).
- **`lua2c` stubs** — see below.

Everything else the plugin links against is already vendored in this repo:
`macosxlibs/`, `win32libs/`, `android/corona-libs/`, `android/jni/<abi>/` and
`shared/include/`.

### lua2c stubs — keep `shared/generated/plugin_movie.c` in sync

Each platform project normally shells out to Corona's `lua2c` at build time to
turn `shared/plugin_movie.lua` into `shared/generated/plugin_movie.c`. That tool
needs a 32-bit Lua binary from the Simulator install, so CI cannot run it.

The stubs written by `ci/corona-native.sh` instead copy the **committed**
`shared/generated/plugin_movie.c`, which is byte-identical to what `lua2c` emits.

> ⚠️ CI does not detect drift. If you edit `shared/plugin_movie.lua`, regenerate
> `shared/generated/plugin_movie.c` with a real Corona/Solar2D install and commit
> both files. Until then, CI keeps shipping the old Lua glue.

### Windows: compile check vs. real DLL

`win32/Plugin.vcxproj` links `$(CORONA_ROOT)\Corona\win\lib\*.lib` — the Corona
Windows import libraries, which only ship with the Simulator. Without them the
link step cannot resolve `lua_*` and `Corona*` and no DLL can be produced.

The Windows job therefore runs `msbuild /t:ClCompile`: all three translation
units are compiled with MSVC (this is what catches Windows-specific breakage),
but nothing is linked. The artifact contains the object files and a
`BUILD-MODE.txt` that says so.

To get a real `plugin_movie.dll` from CI, add a repository secret
`CORONA_WIN_SDK_URL` pointing at a zip of the Corona Windows import libraries
(either flat `*.lib` files or a `Corona/win/lib/` tree). The job then downloads
it, and `ci/build-windows.ps1` switches to a full `msbuild /t:Build` — the
published package will contain the DLL and `win32-sim.tgz` automatically.

## Running the same builds locally

```sh
# 1. provision a Corona tree (~15 files from Solar2D; cached per run)
ci/corona-native.sh "$PWD/.ci/corona-native"

# 2. macOS
CORONA_ROOT="$PWD/.ci/corona-native" bash mac/build.sh "$PWD/dist/mac"

# 3. iOS (device + simulator static libs and the Corona plugin structure)
CORONA_ROOT="$PWD/.ci/corona-native" bash ios/build.sh "$PWD/dist/ios"

# 4. Android (needs an NDK: brew install --cask android-ndk, or the SDK manager)
ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.0.12077973" \
CORONA_NATIVE="$PWD/.ci/corona-native" bash ci/build-android.sh "$PWD/dist/android"

# 5. Windows (PowerShell)
pwsh ci/build-windows.ps1 -CoronaRoot "$PWD/.ci/corona-native" -OutDir "$PWD/dist/win32"
```

Artifacts land in `dist/`, which is gitignored along with `.ci/` and
`android/libs/`.

## Notes and limits

- **Android ABI/platform.** `android/jni/Application.mk` still targets
  `android-16`, which NDK r23+ rejects. `ci/build-android.sh` passes
  `APP_PLATFORM=android-21 APP_STL=c++_static APP_ABI=…` on the `ndk-build`
  command line instead of editing the committed files, so local builds keep
  working exactly as before. `android/jni/Android.mk` now uses
  `CORONA_NATIVE ?= …`, so the hardcoded Windows path is overridable by the
  environment; the default is unchanged.
- **iOS demo app.** Only the plugin target is built. `ios/App.xcodeproj` needs
  the full Corona iOS player (`-lplayer`, `Corona/ios/lib`), which is not
  available in CI.
- **macOS codesigning.** The Xcode project's "Copy to Simulator's Plugin
  Directory" phase still runs; on a runner it just writes into the throwaway
  `$HOME`.
- **NDK version.** The workflow uses the runner's preinstalled NDK when present
  and otherwise downloads NDK r27c directly from `dl.google.com` (no third-party
  action, so no extra supply-chain surface).
