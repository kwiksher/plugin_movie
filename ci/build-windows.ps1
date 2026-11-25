<#
.SYNOPSIS
    Build (or at minimum compile-verify) the Win32 plugin on Windows.

.DESCRIPTION
    win32/Plugin.vcxproj links against the Corona Windows import libraries
    ($(CORONA_ROOT)\Corona\win\lib\*.lib), which ship with the Corona/Solar2D
    Simulator and are not redistributable in this repo. ci/corona-native.sh
    supplies the headers but not those .lib files, so this script has two modes:

      full          Corona win import libs are present -> real plugin_movie.dll
      compile-only  no import libs                      -> MSBuild ClCompile

    compile-only still compiles all three translation units (PluginMovie.cpp,
    theoraplay.c and the generated Lua glue) with MSVC, which is what catches
    Windows-specific breakage. It cannot produce a loadable DLL.

    Supply the import libs with a Corona/Solar2D install, or point
    --win-libs at them when provisioning ci/corona-native.sh.

.PARAMETER CoronaRoot
    Corona tree to build against. Default: <repo>/.ci/corona-native

.PARAMETER OutDir
    Where to copy the DLL / objects. Default: <repo>/dist/win32

.PARAMETER Configuration
    Release (default) or Debug.

.EXAMPLE
    pwsh ci/build-windows.ps1 -CoronaRoot C:\corona-native
#>
param(
    [string]$CoronaRoot = "",
    [string]$OutDir = "",
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($CoronaRoot)) { $CoronaRoot = Join-Path $repoRoot ".ci/corona-native" }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repoRoot "dist/win32" }
$CoronaRoot = (Resolve-Path -LiteralPath $CoronaRoot).Path

$headers = Join-Path $CoronaRoot "Corona/shared/include/Corona/CoronaLua.h"
if (-not (Test-Path -LiteralPath $headers)) {
    throw "$CoronaRoot is not a Corona tree (run ci/corona-native.sh first)"
}

# --- locate MSBuild ---------------------------------------------------------
$msbuild = $null
$onPath = Get-Command msbuild.exe -ErrorAction SilentlyContinue
if ($onPath) {
    $msbuild = $onPath.Source
} else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $candidate = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
            -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
        if ($candidate) { $msbuild = $candidate }
    }
}
if (-not $msbuild) { throw "MSBuild not found. Install Visual Studio with the C++ workload." }

# --- decide the mode --------------------------------------------------------
$winLibs = @(Get-ChildItem -Path (Join-Path $CoronaRoot "Corona/win/lib") -Filter *.lib -ErrorAction SilentlyContinue)
$fullLink = $winLibs.Count -gt 0
$target = if ($fullLink) { "Build" } else { "ClCompile" }

Write-Host "  MSBuild:  $msbuild"
Write-Host "  CORONA_ROOT: $CoronaRoot"
Write-Host "  mode:     $(if ($fullLink) { "full ($($winLibs.Count) import libs)" } else { "compile-only (no Corona import libs)" })"

$project = Join-Path $repoRoot "win32/Plugin.vcxproj"
$logFile = Join-Path ([System.IO.Path]::GetTempPath()) "plugin_movie_msbuild.log"

& $msbuild $project `
    "/t:$target" `
    "/p:Configuration=$Configuration" `
    "/p:Platform=Win32" `
    "/p:CORONA_ROOT=$CoronaRoot" `
    /m /nologo /v:minimal /fl `
    "/flp:LogFile=$logFile;Verbosity=normal"
if ($LASTEXITCODE -ne 0) {
    if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Tail 60 | Write-Host }
    throw "MSBuild failed with exit code $LASTEXITCODE (full log: $logFile)"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if ($fullLink) {
    $dll = Get-ChildItem -Path (Join-Path $repoRoot "win32") -Filter plugin_movie.dll -Recurse |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $dll) { throw "build reported success but plugin_movie.dll was not produced" }

    Copy-Item -LiteralPath $dll.FullName -Destination $OutDir -Force
    $tgz = Join-Path $dll.DirectoryName "win32-sim.tgz"
    if (Test-Path -LiteralPath $tgz) { Copy-Item -LiteralPath $tgz -Destination $OutDir -Force }
    "full" | Set-Content -LiteralPath (Join-Path $OutDir "BUILD-MODE.txt")
    Write-Host "  plugin_movie.dll -> $(Join-Path $OutDir "plugin_movie.dll")"
} else {
    # Keep the object files so the compile check leaves inspectable evidence.
    $objs = Get-ChildItem -Path (Join-Path $repoRoot "win32") -Filter *.obj -Recurse -File -ErrorAction SilentlyContinue
    foreach ($o in $objs) { Copy-Item -LiteralPath $o.FullName -Destination $OutDir -Force }
    @(
        "compile-only",
        "win32/Plugin.vcxproj was compiled (ClCompile) but not linked:",
        "the Corona Windows import libraries (Corona/win/lib/*.lib) were not available.",
        "Re-run with a Corona/Solar2D install, or pass --win-libs to ci/corona-native.sh,"
        "to produce a real plugin_movie.dll."
    ) | Set-Content -LiteralPath (Join-Path $OutDir "BUILD-MODE.txt")
    Write-Host "  compile check passed ($($objs.Count) object file(s)) -> $OutDir"
}
