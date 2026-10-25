param(
    [string]$PluginsRoot = "C:\Users\Administrator\Downloads\AstrBot\data\plugins",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RelativePathCompat {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $baseUri = New-Object System.Uri(($BasePath.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri($TargetPath)
    return [System.Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($targetUri).ToString()
    ).Replace('/', '\')
}

function Should-SkipPath {
    param([string]$RelativePath)

    $segments = $RelativePath -split "[\\/]+"
    if ($segments -contains ".git" -or
        $segments -contains ".venv" -or
        $segments -contains "__pycache__" -or
        $segments -contains ".pytest_cache" -or
        $segments -contains ".ruff_cache" -or
        $segments -contains "tests") {
        return $true
    }
    return ([IO.Path]::GetExtension($RelativePath) -eq ".pyc")
}

function Invoke-DeployAction {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    if ($DryRun) {
        Write-Host "[DryRun] $Description"
        return
    }
    Write-Host $Description
    & $Action
}

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourcePluginRoot = $RepoRoot
$MetadataPath = Join-Path $SourcePluginRoot "metadata.yaml"

if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
    throw "metadata.yaml not found: $MetadataPath"
}

$PluginName = $null
foreach ($line in Get-Content -LiteralPath $MetadataPath -Encoding UTF8) {
    if ($line -match '^\s*name:\s*(.+?)\s*$') {
        $PluginName = $Matches[1].Trim()
        break
    }
}
if ($PluginName -ne "astrbot_plugin_neurobrain") {
    throw "Unexpected plugin name: $PluginName"
}

$ResolvedPluginsRoot = (Resolve-Path -LiteralPath $PluginsRoot).Path
$TargetPluginRoot = [IO.Path]::GetFullPath((Join-Path $ResolvedPluginsRoot $PluginName))
if (-not $TargetPluginRoot.StartsWith($ResolvedPluginsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved target path escapes plugins root: $TargetPluginRoot"
}

$managedFiles = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)

Invoke-DeployAction "Ensure target directory: $TargetPluginRoot" {
    New-Item -ItemType Directory -Path $TargetPluginRoot -Force | Out-Null
}

$sourceFiles = Get-ChildItem -LiteralPath $SourcePluginRoot -Recurse -File | Where-Object {
    $relative = Get-RelativePathCompat -BasePath $SourcePluginRoot -TargetPath $_.FullName
    (-not (Should-SkipPath $relative)) -and ($_.Name -ne "deploy_neurobrain.ps1")
}

foreach ($file in $sourceFiles) {
    $relative = Get-RelativePathCompat -BasePath $SourcePluginRoot -TargetPath $file.FullName
    [void]$managedFiles.Add($relative)
    $targetPath = Join-Path $TargetPluginRoot $relative
    $targetParent = Split-Path -Parent $targetPath
    Invoke-DeployAction "Copy file: $relative" {
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
    }
}

if (Test-Path -LiteralPath $TargetPluginRoot -PathType Container) {
    $targetFiles = Get-ChildItem -LiteralPath $TargetPluginRoot -Recurse -File | Where-Object {
        $relative = Get-RelativePathCompat -BasePath $TargetPluginRoot -TargetPath $_.FullName
        -not (Should-SkipPath $relative)
    }
    foreach ($file in $targetFiles) {
        $relative = Get-RelativePathCompat -BasePath $TargetPluginRoot -TargetPath $file.FullName
        if (-not $managedFiles.Contains($relative)) {
            Invoke-DeployAction "Remove stale file: $relative" {
                Remove-Item -LiteralPath $file.FullName -Force
            }
        }
    }
}

Write-Host ""
Write-Host "Deploy source : $SourcePluginRoot"
Write-Host "Deploy target : $TargetPluginRoot"
Write-Host "Plugin name   : $PluginName"
if ($DryRun) {
    Write-Host "Mode          : DryRun"
} else {
    Write-Host "Mode          : Apply"
}
