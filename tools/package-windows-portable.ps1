[CmdletBinding()]
param(
    [string]$ReleaseDirectory = "",
    [string]$OutputDirectory = "",
    [string]$PackageName = "ShadowWorld-Neil-Portable-Windows-x64",
    [string]$VCRedistDirectory = "",
    [switch]$KeepStaging
)

$ErrorActionPreference = "Stop"

function Get-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathWithin([string]$Path, [string]$Parent) {
    $fullPath = Get-FullPath $Path
    $fullParent = Get-FullPath $Parent
    return $fullPath.Equals($fullParent, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullParent + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-V143RedistDirectory {
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
        throw "ProgramFiles(x86) is not set. Pass -VCRedistDirectory explicitly."
    }

    $vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw "vswhere.exe was not found at '$vswhere'. Pass -VCRedistDirectory explicitly."
    }

    $installPath = & $vswhere -latest -products '*' -version '[17.0,18.0)' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($installPath)) {
        throw "No Visual Studio 2022 instance with x64 C++ tools was found. Pass -VCRedistDirectory explicitly."
    }

    $redistRoot = Join-Path $installPath "VC\Redist\MSVC"
    if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) {
        throw "Visual Studio redist folder is missing: $redistRoot"
    }

    $candidates = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^14\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending

    foreach ($candidate in $candidates) {
        $crtDirectory = Join-Path $candidate.FullName "x64\Microsoft.VC143.CRT"
        if (Test-Path -LiteralPath $crtDirectory -PathType Container) {
            return $crtDirectory
        }
    }

    throw "No x64 Microsoft.VC143.CRT directory was found under '$redistRoot'. Pass -VCRedistDirectory explicitly."
}

function Copy-ResourceTree([string]$Source, [string]$RelativeDestination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required runtime resource directory is missing: $Source"
    }

    $sourceRoot = (Get-FullPath $Source) + '\'
    $files = Get-ChildItem -LiteralPath $Source -File -Recurse -Force
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($sourceRoot.Length).Replace('\', '/')
        $packagePath = "$RelativeDestination/$relativePath"

        if ($file.Extension -in @('.pdb', '.lib', '.exp', '.obj', '.ilk', '.log', '.user', '.suo')) {
            continue
        }
        if ($packagePath -match '(^|/)\.git(/|$)' -or
            $packagePath -match '^plugins/qmltooling(/|$)' -or
            $packagePath -match '^qml/QtTest(/|$)') {
            continue
        }

        $destination = Join-Path $script:StageDirectory ($packagePath.Replace('/', '\'))
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
}

function Copy-RequiredFile([string]$Source, [string]$DestinationName) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required package file is missing: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $script:StageDirectory $DestinationName)
}

$repositoryRoot = Get-FullPath (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($ReleaseDirectory)) {
    $ReleaseDirectory = Join-Path $repositoryRoot "build\bin\Release"
}
$ReleaseDirectory = Get-FullPath $ReleaseDirectory
if (-not (Test-Path -LiteralPath $ReleaseDirectory -PathType Container)) {
    throw "Release output directory was not found: $ReleaseDirectory"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Split-Path -Parent $repositoryRoot) "ShadowWorld-Packages"
}
$OutputDirectory = Get-FullPath $OutputDirectory
if (Test-PathWithin $OutputDirectory $repositoryRoot) {
    throw "OutputDirectory must be outside the source checkout: $repositoryRoot"
}

$releaseInfo = Get-Item -LiteralPath $ReleaseDirectory
$buildRoot = $ReleaseDirectory
if ($releaseInfo.Name -ieq "Release" -and $releaseInfo.Parent.Name -ieq "bin") {
    $buildRoot = $releaseInfo.Parent.Parent.FullName
}
if (Test-PathWithin $OutputDirectory $buildRoot) {
    throw "OutputDirectory must be outside the build tree: $buildRoot"
}

if ([string]::IsNullOrWhiteSpace($PackageName) -or $PackageName -in @('.', '..') -or
    $PackageName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
    $PackageName.Contains('/') -or $PackageName.Contains('\')) {
    throw "PackageName must be a single valid folder/file name."
}

if ([string]::IsNullOrWhiteSpace($VCRedistDirectory)) {
    $VCRedistDirectory = Get-V143RedistDirectory
}
$VCRedistDirectory = Get-FullPath $VCRedistDirectory
if (-not (Test-Path -LiteralPath $VCRedistDirectory -PathType Container)) {
    throw "VC redist directory was not found: $VCRedistDirectory"
}
if ($VCRedistDirectory -notmatch '\\x64\\Microsoft\.VC143\.CRT$') {
    throw "Expected the x64\Microsoft.VC143.CRT directory, got: $VCRedistDirectory"
}

$script:OutputDirectory = $OutputDirectory
$archivePath = Join-Path $OutputDirectory ($PackageName + ".zip")
$runId = [Guid]::NewGuid().ToString("N")
$temporaryRoot = Get-FullPath ([System.IO.Path]::GetTempPath())
$runDirectory = Join-Path $temporaryRoot ("ShadowWorld-Portable-" + $runId)
$script:StageDirectory = Join-Path $runDirectory $PackageName
$verificationDirectory = Join-Path $runDirectory "verification"

if ((Test-PathWithin $runDirectory $repositoryRoot) -or
    (Test-PathWithin $runDirectory $buildRoot)) {
    throw "Temporary staging directory must remain outside the source and build trees."
}
if (Test-Path -LiteralPath $runDirectory) {
    throw "Refusing to reuse an existing temporary path: $runDirectory"
}

New-Item -ItemType Directory -Path $script:StageDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

Copy-RequiredFile (Join-Path $ReleaseDirectory "noggit.exe") "noggit.exe"
Copy-RequiredFile (Join-Path $ReleaseDirectory "qt.conf") "qt.conf"
Copy-RequiredFile (Join-Path $repositoryRoot "dist\noggit_template.json") "noggit.json"
Copy-RequiredFile (Join-Path $repositoryRoot "COPYING") "COPYING"
$qtConfig = Get-Content -LiteralPath (Join-Path $script:StageDirectory 'qt.conf') -Raw
if ($qtConfig -match '(?im)^\s*[A-Za-z0-9_.-]+\s*=\s*(?:[A-Za-z]:[\\/]|\\\\|/|.*(?:^|[\\/])\.\.(?:[\\/]|$))') {
    throw "qt.conf must not contain absolute or parent-relative paths."
}

$runtimeDlls = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File -Filter '*.dll')
if ($runtimeDlls.Count -eq 0) {
    throw "No app-local runtime DLLs were found in $ReleaseDirectory"
}
foreach ($dll in $runtimeDlls) {
    Copy-Item -LiteralPath $dll.FullName -Destination $script:StageDirectory
}

$requiredRootDlls = @(
    'Qt5Core.dll', 'Qt5Gui.dll', 'Qt5Widgets.dll', 'Qt5Network.dll',
    'Qt5Multimedia.dll', 'Qt5Sql.dll', 'Qt5Quick.dll', 'Qt5Qml.dll',
    'StormLib.dll'
)
foreach ($dllName in $requiredRootDlls) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:StageDirectory $dllName) -PathType Leaf)) {
        throw "Required app-local DLL is missing from Release output: $dllName"
    }
}
if (-not ((Test-Path (Join-Path $script:StageDirectory 'z.dll')) -or
          (Test-Path (Join-Path $script:StageDirectory 'zlib1.dll')) -or
          (Test-Path (Join-Path $script:StageDirectory 'zlib.dll')))) {
    throw "No external zlib runtime DLL was found in $ReleaseDirectory"
}
if (-not ((Test-Path (Join-Path $script:StageDirectory 'bz2.dll')) -or
          (Test-Path (Join-Path $script:StageDirectory 'bzip2.dll')))) {
    throw "No bzip2 runtime DLL was found in $ReleaseDirectory"
}

$resourceDirectories = @(
    'themes', 'definitions', 'native-db2-definitions', 'noggit-definitions',
    'licenses', 'plugins', 'qml'
)
foreach ($directory in $resourceDirectories) {
    Copy-ResourceTree (Join-Path $ReleaseDirectory $directory) $directory
}

if (-not (Test-Path -LiteralPath (Join-Path $script:StageDirectory 'licenses\wow.export-MIT.txt') -PathType Leaf)) {
    throw "The wow.export attribution notice is missing from the deployed Release output."
}

Copy-RequiredFile (Join-Path $repositoryRoot 'dist\listfile\listfile.csv') 'listfile.csv'

$crtFiles = @(Get-ChildItem -LiteralPath $VCRedistDirectory -File |
    Where-Object { $_.Extension -in @('.dll', '.manifest') })
if ($crtFiles.Count -eq 0) {
    throw "No redistributable runtime files were found in $VCRedistDirectory"
}
foreach ($crtFile in $crtFiles) {
    $destination = Join-Path $script:StageDirectory $crtFile.Name
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $crtFile.FullName -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            throw "Conflicting runtime DLL exists in the app output: $($crtFile.Name)"
        }
    } else {
        Copy-Item -LiteralPath $crtFile.FullName -Destination $destination
    }
}

$requiredCrtFiles = @(
    'msvcp140.dll', 'msvcp140_atomic_wait.dll',
    'vcruntime140.dll', 'vcruntime140_1.dll'
)
foreach ($crtName in $requiredCrtFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:StageDirectory $crtName) -PathType Leaf)) {
        throw "Required x64 VC143 runtime file is missing: $crtName"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $script:StageDirectory 'plugins\platforms\qwindows.dll') -PathType Leaf)) {
    throw "Qt Windows platform plugin is missing: plugins\platforms\qwindows.dll"
}
if (-not (Test-Path -LiteralPath (Join-Path $script:StageDirectory 'plugins\imageformats\qjpeg.dll') -PathType Leaf)) {
    throw "Qt JPEG image plugin is missing: plugins\imageformats\qjpeg.dll"
}

$config = Get-Content -LiteralPath (Join-Path $script:StageDirectory 'noggit.json') -Raw | ConvertFrom-Json
foreach ($pathValue in @(
    $config.Noggit.ApplicationProjectPath,
    $config.Noggit.ApplicationThemePath,
    $config.Noggit.ApplicationDatabaseDefinitionsPath,
    $config.Noggit.ApplicationNoggitDefinitionsPath,
    $config.Noggit.ApplicationListFilePath,
    $config.Noggit.LoggingConfiguration.ApplicationLoggingPath
)) {
    if ([string]::IsNullOrWhiteSpace($pathValue) -or [System.IO.Path]::IsPathRooted($pathValue) -or
        $pathValue -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "The packaged configuration must use safe relative paths; found '$pathValue'."
    }
}

$forbiddenFiles = @(Get-ChildItem -LiteralPath $script:StageDirectory -File -Recurse -Force |
    Where-Object {
        $_.Name -match '^(log(\..*)?\.txt|imgui\.ini|noggit\.(lib|exp)|.*\.pdb|.*\.ilk|.*\.obj|CMakeCache\.txt)$' -or
        $_.Name -match '^(\.env|id_rsa|credentials.*\.json|secrets.*\.json|.*\.pem)$'
    })
if ($forbiddenFiles.Count -gt 0) {
    throw "Build or private files were found in staging: $($forbiddenFiles.FullName -join ', ')"
}
if (Test-Path -LiteralPath (Join-Path $script:StageDirectory 'projects')) {
    throw "Local project data must not be included in the package."
}

Compress-Archive -LiteralPath $script:StageDirectory -DestinationPath $archivePath `
    -CompressionLevel Optimal -Force

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipFile = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $entries = @($zipFile.Entries)
    $archiveRoots = @($entries | ForEach-Object {
        $entryName = $_.FullName.Replace('\', '/')
        ($entryName -split '/')[0]
    } | Sort-Object -Unique)
} finally {
    $zipFile.Dispose()
}
if ($archiveRoots.Count -ne 1 -or $archiveRoots[0] -ne $PackageName) {
    throw "ZIP must contain only the '$PackageName' top-level folder."
}

Expand-Archive -LiteralPath $archivePath -DestinationPath $verificationDirectory
$extractedRoot = Join-Path $verificationDirectory $PackageName
if (-not (Test-Path -LiteralPath (Join-Path $extractedRoot 'noggit.exe') -PathType Leaf)) {
    throw "Extracted ZIP does not contain $PackageName\noggit.exe"
}

$stagedFiles = @(Get-ChildItem -LiteralPath $script:StageDirectory -File -Recurse -Force)
$extractedFiles = @(Get-ChildItem -LiteralPath $extractedRoot -File -Recurse -Force)
if ($stagedFiles.Count -ne $extractedFiles.Count) {
    throw "ZIP extraction file count differs from staging ($($stagedFiles.Count) vs $($extractedFiles.Count))."
}

$stagedHashes = @{}
foreach ($file in $stagedFiles) {
    $relative = $file.FullName.Substring($script:StageDirectory.Length).TrimStart('\').Replace('\', '/')
    $stagedHashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}
foreach ($file in $extractedFiles) {
    $relative = $file.FullName.Substring($extractedRoot.Length).TrimStart('\').Replace('\', '/')
    if (-not $stagedHashes.ContainsKey($relative)) {
        throw "Extracted ZIP contains an unexpected file: $relative"
    }
    $extractedHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($stagedHashes[$relative] -ne $extractedHash) {
        throw "SHA-256 mismatch after ZIP extraction: $relative"
    }
}

$archiveInfo = Get-Item -LiteralPath $archivePath
$sizeMiB = [Math]::Round($archiveInfo.Length / 1MB, 1)
Write-Host "Portable ZIP verified: $archivePath"
Write-Host "Size: $($archiveInfo.Length) bytes ($sizeMiB MiB)"
Write-Host "Top-level folder: $PackageName"
Write-Host "Staged/extracted files matched by SHA-256: $($stagedFiles.Count)"
if ($KeepStaging) {
    Write-Host "Staging retained at: $script:StageDirectory"
    Write-Host "Verification extraction retained at: $verificationDirectory"
} else {
    $temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
    $resolvedRunDirectory = Get-FullPath $runDirectory
    if (-not $resolvedRunDirectory.StartsWith($temporaryRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRunDirectory) -ne ("ShadowWorld-Portable-" + $runId)) {
        throw "Refusing to remove a staging path that does not match this run: $resolvedRunDirectory"
    }
    Remove-Item -LiteralPath $resolvedRunDirectory -Recurse -Force
    Write-Host "Temporary staging and verification folders removed."
}
