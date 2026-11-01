param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $root 'src\noggit\texture_set.cpp'))
function Read-Section([string]$begin, [string]$end) {
  $start = $source.IndexOf($begin)
  $stop = $source.IndexOf($end, $start)
  if ($start -lt 0 -or $stop -le $start) { throw "Texture layer extraction marker missing: $begin" }
  return $source.Substring($start, $stop - $start)
}
$erase = Read-Section 'void TextureSet::eraseTexture(size_t id)' 'bool TextureSet::removeTextureLayer('
$remove = Read-Section 'bool TextureSet::removeTextureLayer(size_t id)' 'bool TextureSet::canPaintTexture('
$fixture = [IO.File]::ReadAllText((Join-Path $root 'tests\texture-layer-removal-regression.inc'))
if (!$fixture.Contains('// ACTUAL_ERASE_METHOD') -or !$fixture.Contains('// ACTUAL_REMOVE_METHOD')) {
  throw 'Texture layer removal fixture markers missing'
}
$fixture = $fixture.Replace('// ACTUAL_ERASE_METHOD', $erase).Replace('// ACTUAL_REMOVE_METHOD', $remove)
[IO.File]::WriteAllText($OutputPath, $fixture)
