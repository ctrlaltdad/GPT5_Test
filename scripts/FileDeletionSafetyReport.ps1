<#!
.SYNOPSIS
Generates a ranked report of files that may be safe to delete.

.DESCRIPTION
Analyzes files under a target path (default: current directory) and computes a safety score (0-100) estimating how "safe" it is to delete each file.
The script DOES NOT delete anything. It only reports.

Score Factors (weights are adjustable via parameters):
- Age since last write (older -> safer)
- Last access time (older -> safer)
- Redundancy by name pattern (e.g., many sequentially numbered backups -> safer)
- Located in common temp/cache directory names (temp, cache, logs, tmp) (safer)
- File extension type (e.g., .tmp, .log, .bak, .old -> safer; .exe, .dll, .sys -> risky)
- Size (very large & old/log/tmp may increase safety slightly)
- Recently created or modified files penalized
- System / hidden / read-only attributes penalized
- Very small random files (<1KB) with temp-like names slightly safer

Output: A CSV / JSON / table with: SafetyScore, ContributingFactors, FilePath, Name, Extension, Length (bytes), SizeHuman, Created, LastWrite, LastAccess, Attributes.

.EXAMPLE
# Basic usage in current directory
./FileDeletionSafetyReport.ps1 -Path . -Top 100 -OutCsv report.csv

.EXAMPLE
# Scan user temp directory and export JSON
./FileDeletionSafetyReport.ps1 -Path $env:TEMP -OutJson temp_safety.json

.NOTES
Adjust weight parameters to tune scoring. Always manually review before deleting.
#>
[CmdletBinding()] Param(
    [Parameter(Position=0)]
    [string] $Path = '.',

    [int] $Top = 200,

    [switch] $Recurse,

    [string] $OutCsv,
    [string] $OutJson,
    [string] $OutMarkdown,

    [int] $MinSizeBytes = 0,

    # Weight parameters (0-100). They will be normalized internally.
    [int] $WAge = 30,
    [int] $WAccessAge = 10,
    [int] $WTempLocation = 10,
    [int] $WExtension = 15,
    [int] $WRedundancy = 15,
    [int] $WAttributesPenalty = 10,
    [int] $WRecentWritePenalty = 10,
    [int] $WRecentCreatePenalty = 10,
    [int] $WSizeBonus = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path not found: $Path"
}

$now = Get-Date

# Helper: human readable file size
function Convert-Size {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    elseif ($Bytes -lt 1MB) { return "{0:N2} KB" -f ($Bytes/1KB) }
    elseif ($Bytes -lt 1GB) { return "{0:N2} MB" -f ($Bytes/1MB) }
    elseif ($Bytes -lt 1TB) { return "{0:N2} GB" -f ($Bytes/1GB) }
    else { return "{0:N2} TB" -f ($Bytes/1TB) }
}

# Gather files
$searchParams = @{ LiteralPath = $Path; File = $true }
if ($Recurse) { $searchParams['Recurse'] = $true }
$files = Get-ChildItem @searchParams -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.Length -ge $MinSizeBytes }

if (-not $files) {
    Write-Warning "No files found under path $Path (recurse=$Recurse) meeting criteria."
    return
}

# Precompute name groups for redundancy detection
$nameStemMap = @{}
foreach ($f in $files) {
    $stem = ($f.BaseName -replace '(?i)[-_]?(copy|backup|bak|old|temp|tmp|log|v\d+)$','')
    if (-not $nameStemMap.ContainsKey($stem)) { $nameStemMap[$stem] = @() }
    $nameStemMap[$stem] += $f
}

# Extensions considered usually safe (older -> safer)
$safeExt = '.tmp','.temp','.log','.bak','.old','.chk','.dmp','.err','.cache','.msi.old'
$riskyExt = '.exe','.dll','.sys','.ocx','.drv','.dat','.db','.pst','.xls','.xlsx','.doc','.docx','.pdf'

# Temp-like directory name fragments
$tempDirTokens = 'temp','tmp','cache','caches','log','logs','crash','minidump','reports','report','backups','bak'

$results = foreach ($f in $files) {
    $ageDays = ($now - $f.LastWriteTime).TotalDays
    $createAgeDays = ($now - $f.CreationTime).TotalDays
    $accessAgeDays = if ($f.PSObject.Properties.Name -contains 'LastAccessTime') { ($now - $f.LastAccessTime).TotalDays } else { $ageDays }

    $scoreBreakdown = @()
    $score = 0.0

    # Age factor
    $ageScore = [Math]::Min(1, $ageDays / 180)   # full credit after ~6 months
    $score += $ageScore * $WAge
    $scoreBreakdown += "AgeFactor={0:N2}" -f $ageScore

    # Access age
    $accessScore = [Math]::Min(1, $accessAgeDays / 180)
    $score += $accessScore * $WAccessAge
    $scoreBreakdown += "AccessAgeFactor={0:N2}" -f $accessScore

    # Extension factor
    $ext = $f.Extension.ToLowerInvariant()
    $extFactor = if ($safeExt -contains $ext) { 1 } elseif ($riskyExt -contains $ext) { 0 } else { 0.4 }
    $score += $extFactor * $WExtension
    $scoreBreakdown += "ExtFactor={0:N2}" -f $extFactor

    # Temp-like directory factor
    $pathLower = $f.FullName.ToLowerInvariant()
    $dirFactor = if ($tempDirTokens | Where-Object { $pathLower -match "\\$_(\\|/|$)" -or $pathLower -match "\\$_\\" }) { 1 } else { 0 }
    $score += $dirFactor * $WTempLocation
    $scoreBreakdown += "TempDirFactor=$dirFactor"

    # Redundancy: many similar stems
    $stem = ($f.BaseName -replace '(?i)[-_]?(copy|backup|bak|old|temp|tmp|log|v\d+)$','')
    $groupCount = $nameStemMap[$stem].Count
    $redundancyFactor = [Math]::Min(1, ($groupCount - 1) / 9) # 10+ similar -> full
    $score += $redundancyFactor * $WRedundancy
    $scoreBreakdown += "RedundancyFactor={0:N2}(count=$groupCount)" -f $redundancyFactor

    # Size bonus (if large AND old & safe ext / temp dir)
    $sizeMB = $f.Length / 1MB
    $sizeBonusFactor = 0
    if ($sizeMB -ge 100 -and $ageDays -ge 90 -and ($extFactor -ge 0.4) -and ($dirFactor -eq 1 -or $extFactor -eq 1)) {
        $sizeBonusFactor = [Math]::Min(1, ($sizeMB - 100) / 900) # up to 1000MB
    }
    $score += $sizeBonusFactor * $WSizeBonus
    $scoreBreakdown += "SizeBonusFactor={0:N2}" -f $sizeBonusFactor

    # Penalties (subtract)
    $penalty = 0

    # Recent write penalty
    $recentWriteFactor = if ($ageDays -lt 7) { 1 } elseif ($ageDays -lt 30) { 0.5 } else { 0 }
    $penalty += $recentWriteFactor * $WRecentWritePenalty
    $scoreBreakdown += "RecentWritePenaltyFactor={0:N2}" -f $recentWriteFactor

    # Recent create penalty
    $recentCreateFactor = if ($createAgeDays -lt 7) { 1 } elseif ($createAgeDays -lt 30) { 0.5 } else { 0 }
    $penalty += $recentCreateFactor * $WRecentCreatePenalty
    $scoreBreakdown += "RecentCreatePenaltyFactor={0:N2}" -f $recentCreateFactor

    # Attribute penalty
    $attrPenaltyFactor = 0
    if ($f.Attributes.ToString().Contains('System')) { $attrPenaltyFactor += 0.7 }
    if ($f.Attributes.ToString().Contains('Hidden')) { $attrPenaltyFactor += 0.2 }
    if ($f.Attributes.ToString().Contains('ReadOnly')) { $attrPenaltyFactor += 0.2 }
    if ($ext -eq '.dll' -or $ext -eq '.sys') { $attrPenaltyFactor += 0.5 }
    $attrPenaltyFactor = [Math]::Min(1, $attrPenaltyFactor)
    $penalty += $attrPenaltyFactor * $WAttributesPenalty
    $scoreBreakdown += "AttrPenaltyFactor={0:N2}" -f $attrPenaltyFactor

    $score -= $penalty

    # Normalize to 0-100
    $maxPositive = ($WAge + $WAccessAge + $WTempLocation + $WExtension + $WRedundancy + $WSizeBonus)
    $maxNegative = ($WRecentWritePenalty + $WRecentCreatePenalty + $WAttributesPenalty)
    $rawMin = -$maxNegative
    $rawMax = $maxPositive
    $normScore = if ($rawMax - $rawMin -ne 0) { (($score - $rawMin) / ($rawMax - $rawMin)) * 100 } else { 0 }
    if ($normScore -lt 0) { $normScore = 0 }
    if ($normScore -gt 100) { $normScore = 100 }

    [PSCustomObject]@{
        SafetyScore = [Math]::Round($normScore,2)
        Factors      = ($scoreBreakdown -join ';')
        FilePath     = $f.FullName
        Name         = $f.Name
        Extension    = $ext
        Length       = $f.Length
        SizeHuman    = Convert-Size $f.Length
        Created      = $f.CreationTime
        LastWrite    = $f.LastWriteTime
        LastAccess   = if ($f.PSObject.Properties.Name -contains 'LastAccessTime') { $f.LastAccessTime } else { $null }
        Attributes   = $f.Attributes
    }
}

$sorted = $results | Sort-Object SafetyScore -Descending | Select-Object -First $Top

# Output table
$sorted | Format-Table -AutoSize SafetyScore, SizeHuman, LastWrite, Name, FilePath

if ($OutCsv) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv
    Write-Host "CSV written: $OutCsv" -ForegroundColor Green
}
if ($OutJson) {
    $sorted | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -Path $OutJson
    Write-Host "JSON written: $OutJson" -ForegroundColor Green
}
if ($OutMarkdown) {
    $md = @()
    $md += "# File Deletion Safety Report"
    $md += "Generated: $(Get-Date -Format o)"
    $md += "Scanned Path: $(Resolve-Path $Path)  Recurse=$Recurse  FilesConsidered=$($results.Count)  ShowingTop=$Top"
    $md += ''
    $md += "| Score | Size | LastWrite | Name | Path |"
    $md += "|------:|------:|-----------|------|------|"
    foreach ($r in $sorted) {
        $md += "| $($r.SafetyScore) | $($r.SizeHuman) | $($r.LastWrite.ToString('yyyy-MM-dd')) | $($r.Name) | $([System.Web.HttpUtility]::HtmlEncode($r.FilePath)) |"
    }
    $md += ''
    $md += '## Legend'
    $md += '* Score nearer 100 = likely safer to delete (still verify).'
    $md += '* Inspect Factors column in CSV/JSON for rationale.'
    $md -join "`n" | Set-Content -Encoding UTF8 -Path $OutMarkdown
    Write-Host "Markdown written: $OutMarkdown" -ForegroundColor Green
}

Write-Host "Done. Reviewed $($results.Count) files." -ForegroundColor Cyan
