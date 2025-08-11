# A comparison of LLM coding models. 
This one is for GPT5.  Each one starts with a single prompt: 

Create for me a script that can run on windows that identifies files that are safe to delete. It doesn't delete them itself, but provides a ranking of safety. In the report, include the safety-score, parameters that went into the score consideration, file name, size, date created, and date updated. 



# File Deletion Safety Report Script

A PowerShell script that ranks files by an estimated "safety" of deletion (0-100). It NEVER deletes anything; it only reports scores with factor breakdowns so you can make informed manual decisions.

## Features
- Multi-factor scoring: age, last access, extension type, temp/log directory hints, redundancy of similarly named files, size, and attribute penalties.
- Adjustable weights for each factor via parameters.
- Supports optional recursion.
- Export to CSV, JSON, and/or Markdown.
- Human-readable size column + raw byte length.

## Usage
From a PowerShell prompt in the repository root:

```powershell
# Basic (current directory, top 100)
./scripts/FileDeletionSafetyReport.ps1

# Recurse through a path and export CSV + JSON
./scripts/FileDeletionSafetyReport.ps1 -Path C:\Some\Folder -Recurse -OutCsv report.csv -OutJson report.json

# Show top 300 candidates
./scripts/FileDeletionSafetyReport.ps1 -Top 300

# Scan temp folder with custom weights
./scripts/FileDeletionSafetyReport.ps1 -Path $env:TEMP -Recurse -WAge 40 -WExtension 25 -WRedundancy 10

# Include Markdown summary
./scripts/FileDeletionSafetyReport.ps1 -Path $env:TEMP -OutMarkdown temp_report.md
```

## Parameters (Key)
- Path: Root directory (default: '.')
- Recurse: Include subdirectories.
- Top: Number of top-scoring files to display (default: 200)
- MinSizeBytes: Ignore files smaller than this.
- Weight parameters: WAge, WAccessAge, WTempLocation, WExtension, WRedundancy, WAttributesPenalty, WRecentWritePenalty, WRecentCreatePenalty, WSizeBonus.
- OutCsv / OutJson / OutMarkdown: Export paths.

## Interpreting Scores
- 80-100: Likely disposable (old logs/temp/backups); still verify no active process uses them.
- 60-79: Possibly safe; inspect manually.
- 40-59: Mixed signals; caution.
- <40: Probably important or recently used.

Inspect the Factors column (CSV/JSON) for the rationale. Example: `AgeFactor=1.00;AccessAgeFactor=1.00;ExtFactor=1.00;TempDirFactor=1;RedundancyFactor=0.44(count=5);SizeBonusFactor=0.12;RecentWritePenaltyFactor=0.00;RecentCreatePenaltyFactor=0.00;AttrPenaltyFactor=0.00`

## Safety Notes
- Always keep backups before deleting.
- Do not rely solely on file extension; verify context.
- System / program directories (Windows, Program Files, System32) should generally not be targeted.
- Consider testing deletions by moving files to a quarantine folder first.

## Customizing Logic
Edit `FileDeletionSafetyReport.ps1` to adjust:
- Extension lists `$safeExt`, `$riskyExt`.
- Temp directory tokens `$tempDirTokens`.
- Scoring math for your environment.

## License
Provided as-is, no warranty. Use at your own risk.
