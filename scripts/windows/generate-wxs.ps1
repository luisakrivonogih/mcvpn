<#
.SYNOPSIS
  Generates a WiX v4/v5 .wxs from a Flutter Windows release folder.

.DESCRIPTION
  `flutter build windows` output isn't a fixed file list (it varies with
  Flutter/plugin versions -- data\flutter_assets, ICU data, plugin DLLs,
  etc.), so a hand-authored <Files> list would drift out of sync. This walks
  the release directory and emits one <Component>/<File> per file, nesting
  <Directory> elements to match the on-disk tree exactly (WiX needs the
  layout preserved -- the app looks up assets by path relative to its own
  exe at runtime, so flattening everything into one folder would break it).

  This is the least-tested part of the whole release pipeline -- written
  and reasoned through without a Windows host or the WiX toolset to run it
  against. Treat the first CI run of the windows job as the actual test.

.PARAMETER SourceDir
  The flutter build windows release folder, e.g.
  app\build\windows\x64\runner\Release

.PARAMETER Version
  App version for the MSI's Package/@Version.

.PARAMETER OutFile
  Where to write the generated .wxs.
#>
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$ErrorActionPreference = "Stop"

# Fixed so upgrades (same UpgradeCode, new Version) work across releases --
# do not change this without a real reason.
$upgradeCode = "B4B6C7A0-5F1B-4C7D-9B0D-4E9E7B0B5B11"

$root = (Resolve-Path $SourceDir).Path

function New-TreeNode {
    [PSCustomObject]@{ Dirs = [ordered]@{}; Files = New-Object System.Collections.Generic.List[string] }
}

$tree = New-TreeNode
Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($root.Length + 1)
    $parts = $rel -split '[\\/]'
    $node = $tree
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $name = $parts[$i]
        if (-not $node.Dirs.Contains($name)) { $node.Dirs[$name] = New-TreeNode }
        $node = $node.Dirs[$name]
    }
    $node.Files.Add($_.FullName)
}

$sb = New-Object System.Text.StringBuilder
$componentIds = New-Object System.Collections.Generic.List[string]
$counter = 0

function Get-SanitizedId([string]$s) {
    $clean = ($s -replace '[^A-Za-z0-9_]', '_')
    if ($clean.Length -gt 50) { $clean = $clean.Substring(0, 50) }
    return $clean
}

function Write-Node($node, [string]$dirId, [string]$indent) {
    foreach ($name in $node.Dirs.Keys) {
        $script:counter++
        $childId = "dir_$($script:counter)_$(Get-SanitizedId $name)"
        [void]$sb.AppendLine("$indent<Directory Id=`"$childId`" Name=`"$name`">")
        Write-Node $node.Dirs[$name] $childId "$indent  "
        [void]$sb.AppendLine("$indent</Directory>")
    }
    foreach ($f in $node.Files) {
        $script:counter++
        $cid = "cmp_$($script:counter)"
        $fid = "file_$($script:counter)"
        $fileName = Split-Path $f -Leaf
        [void]$sb.AppendLine("$indent<Component Id=`"$cid`" Directory=`"$dirId`" Guid=`"*`">")
        [void]$sb.AppendLine("$indent  <File Id=`"$fid`" Source=`"$f`" Name=`"$fileName`" KeyPath=`"yes`" />")
        [void]$sb.AppendLine("$indent</Component>")
        $script:componentIds.Add($cid)
    }
}

Write-Node $tree "INSTALLFOLDER" "        "

$componentRefsXml = ($componentIds | ForEach-Object { "      <ComponentRef Id=`"$_`" />" }) -join "`r`n"

$wxs = @"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="mcvpn" Manufacturer="mcvpn" Version="$Version" UpgradeCode="$upgradeCode" Compressed="yes">
    <MajorUpgrade DowngradeErrorMessage="A newer version of mcvpn is already installed." />
    <MediaTemplate EmbedCab="yes" />

    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="mcvpn">
$($sb.ToString())
      </Directory>
    </StandardDirectory>

    <StandardDirectory Id="ProgramMenuFolder">
      <Directory Id="AppProgramMenuFolder" Name="mcvpn">
        <Component Id="ShortcutComponent" Directory="AppProgramMenuFolder" Guid="*">
          <Shortcut Id="AppStartMenuShortcut" Name="mcvpn"
                    Target="[INSTALLFOLDER]mcvpn.exe" WorkingDirectory="INSTALLFOLDER" />
          <RemoveFolder Id="RemoveAppProgramMenuFolder" On="uninstall" />
          <RegistryValue Root="HKCU" Key="Software\mcvpn" Name="installed"
                          Type="integer" Value="1" KeyPath="yes" />
        </Component>
      </Directory>
    </StandardDirectory>

    <Feature Id="MainFeature" Title="mcvpn" Level="1">
$componentRefsXml
      <ComponentRef Id="ShortcutComponent" />
    </Feature>
  </Package>
</Wix>
"@

Set-Content -Path $OutFile -Value $wxs -Encoding UTF8
Write-Host "Wrote $OutFile with $($componentIds.Count) file components"
