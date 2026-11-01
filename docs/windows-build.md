# Windows Release build and portable ZIP

This guide records the Windows x64 development build verified for the
`feature/texture-layer-removal` branch. It covers compilation, Qt deployment,
regression checks and packaging; it does not claim validation on a clean
Windows machine.

## Changes included in this branch

- The Texture Picker removes one selected non-base terrain texture layer from
  the current chunk. Layer removal preserves the other layers as represented
  by the texture set and supports undo and redo.
- Viewport cursor wrapping supports continuous right-button camera rotation
  and Alt+middle-button object scaling at the viewport edges.
- The Windows CMake integration selects external StormLib 9.40 and zlib when
  available. The `cmake` submodule gitlink points to the published
  `dependency-cmake-stormlib-zlib` branch in the ShadowWorld fork. External
  zlib is also used for PNG2BLP when found, avoiding duplicate zlib symbols.

## Required Windows tools

- Windows 11 x64 for the validated development setup.
- Visual Studio 2022 with **Desktop development with C++**, the MSVC v143
  x64/x86 build tools, and a Windows 10 or 11 SDK.
- CMake, Git, and PowerShell 5.1 or later.
- A vcpkg checkout and the `x64-windows` triplet.
- Qt **5.15.19** packages for the same x64 triplet. The application uses Qt
  Core, Gui, Widgets, OpenGL extensions, Xml, Network, Multimedia, Sql, Quick,
  QML, and SVG modules. `qt5-tools` is required for `qmake` and
  `windeployqt` during configuration/deployment.
- A package-provided StormLib **9.40** target and external zlib. bzip2 and the
  image/font/compression libraries are pulled in as dependencies by the
  selected packages.

Install the Qt and archive packages before configuring the editor, using a
vcpkg ports checkout that provides the tested versions:

```powershell
$env:VCPKG_ROOT = "<path-to-vcpkg>"
& "$env:VCPKG_ROOT\vcpkg.exe" install `
  qt5-base:x64-windows `
  qt5-declarative:x64-windows `
  qt5-imageformats:x64-windows `
  qt5-multimedia:x64-windows `
  qt5-svg:x64-windows `
  qt5-tools:x64-windows `
  stormlib:x64-windows `
  zlib:x64-windows
```

The tested vcpkg packages were Qt 5.15.19, StormLib 9.40, and zlib 1.3.2.
This repository does not currently carry a vcpkg manifest or baseline lock,
so package versions are determined by the vcpkg checkout. Check the resolved
versions with `vcpkg list` before relying on a new build environment. Some
other dependencies are brought in by CMake `FetchContent` or the initialized
Git submodules; the first configure therefore needs network access unless
those sources are already cached.

Clone the feature branch with its submodules, or initialize submodules in an
existing clone:

```powershell
git clone --recurse-submodules --branch feature/texture-layer-removal `
  https://github.com/neily2nd/ShadowWorld-Noggit-Red-Modern.git ShadowWorld
Set-Location ShadowWorld
# For an existing checkout instead:
git submodule update --init --recursive
```

The `cmake` submodule is hosted on the same fork and records the
`dependency-cmake-stormlib-zlib` branch. Keep that gitlink and `.gitmodules`
entry together when publishing a new parent revision.

## Configure and build Release

Use a fresh build directory outside the source checkout. Replace the vcpkg
path below with the local installation path:

```powershell
$repo = (Resolve-Path .).Path
$vcpkgRoot = "<path-to-vcpkg>"
$build = "<path-outside-checkout>\shadowworld-vs2022"

cmake -S $repo -B $build `
  -G "Visual Studio 17 2022" -A x64 `
  "-DCMAKE_TOOLCHAIN_FILE=$vcpkgRoot/scripts/buildsystems/vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows `
  -DVCPKG_USE_LEGACY_APPLOCAL=ON `
  "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" `
  -DCMAKE_BUILD_TYPE=Release

cmake --build $build --config Release --target noggit --parallel 8
```

`CMAKE_BUILD_TYPE` does not select a configuration for Visual Studio's
multi-configuration generator. `--config Release` does that. The explicit
`CMAKE_BUILD_TYPE=Release` is retained because this project's existing Qt
post-build helper also checks that variable when selecting `windeployqt`'s
Release mode; leaving it unset registers both helper commands.

With the vcpkg toolchain, Qt's CMake packages are discovered from the selected
triplet; an explicit machine-specific `Qt5_DIR` is normally unnecessary.
`VCPKG_USE_LEGACY_APPLOCAL=ON` enables vcpkg's app-local dependency copy into
the executable directory. The project's Qt post-build step separately runs
`windeployqt`, so `qt5-tools` must be installed before configuration. The
deployment helper locates `windeployqt` next to the imported `Qt5::qmake`
tool.

The root CMake configuration also queries qmake for the optional Qt MySQL
plugin version using a legacy SDK-layout path. In the validated vcpkg setup
that query can be empty and produce an optional MySQL-driver download warning;
it did not prevent Qt deployment or the Release link. The MySQL plugin is not
required to start the editor. MySQL-backed project database features require
`qsqlmysql.dll`; SQLite and ODBC drivers are deployed separately.

The executable is written to `$build\bin\Release\noggit.exe`.

## Regression checks

The focused Windows regression targets are configured from `tests` and can be
run without opening a map:

```powershell
$testBuild = "<path-outside-checkout>\shadowworld-regressions"
cmake -S "$repo\tests" -B $testBuild -DCMAKE_BUILD_TYPE=Release
cmake --build $testBuild --config Release --target `
  texture_paint texture_layer_removal cursor_wrap
ctest --test-dir $testBuild -C Release --output-on-failure `
  -R "^(texture_paint|texture_layer_removal|cursor_wrap)$"
```

The registered checks cover texture painting, individual texture-layer
removal and viewport cursor wrapping. See [tests/README.md](../tests/README.md)
for the wider standalone test suite and its OpenGL requirements.

## Create the portable ZIP

After a successful Release build and Qt deployment, run the packaging script
from the repository root. `OutputDirectory` must be outside both the checkout
and build tree:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\package-windows-portable.ps1 `
  -ReleaseDirectory "$build\bin\Release" `
  -OutputDirectory "<path-outside-checkout-and-build>"
```

The script stages the executable and app-local DLLs, Qt plugins and QML
modules, project definitions and themes, the listfile, license notices, and
the x64 VC143 runtime files. It excludes logs, PDBs, linker outputs, QML test
modules, local projects and editor UI state. It creates a ZIP with one named
top-level folder, extracts it to a temporary verification directory, and
compares every extracted file with the staging copy by SHA-256. Visual Studio
2022's x64 VC143 redist is found through `vswhere`; use `-VCRedistDirectory`
if automatic discovery is unavailable. The argument must point to the
`x64\Microsoft.VC143.CRT` directory.

The output folder contains the ZIP. Staging and verification use a unique
temporary folder; that folder is removed after successful verification. Pass
`-KeepStaging` to retain it for inspection, and `-PackageName` to change the
folder/archive name. The ZIP is a development/test build; do not add generated
logs, a local project directory, or the build directory.

## Portable launch acceptance and limitations

The current portable distribution was extracted to a normal Downloads folder
and launched directly through `noggit.exe`; the user confirmed general editor
functionality. This is a test on the development machine, not verification on
a clean Windows installation or another person's computer.

- Extract to an **ASCII-only** path. Startup currently rejects paths that
  contain non-ASCII characters.
- Noggit stores some preferences through Windows registry-backed `QSettings`
  under the `Noggit` application name. Another installation may share those
  preferences; this is not fully isolated portable settings storage.
- WoW client data is not included. Configure a project to use a compatible
  local client installation.
- The Qt MySQL driver is optional and absent from the validated ZIP; MySQL
  integrations are unavailable until a matching Qt 5.15.19 x64 driver is
  supplied.
- The package includes the app-local VC143 runtime files from the build's
  matching VS2022 redist. Windows system components such as graphics and
  media APIs remain operating-system dependencies.
- Compatibility with a clean Windows installation, newer client layouts,
  or another computer has not been established by this development build.

For a manual smoke test, extract the ZIP to a writable ASCII-only folder,
double-click `noggit.exe`, confirm the main window opens, then configure the
WoW client/project path if prompted. Do not edit or save a map during the
startup-only check. For feature acceptance, test texture-layer removal with
undo/redo and camera/scaling movement separately on a backed-up project.
