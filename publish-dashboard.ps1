$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$skillRoot = "C:\Users\Administrator\.codex\skills\ai-daily-review"
$indexPath = Join-Path $projectRoot "index.html"
$siteUrl = "https://michaelmao0511.github.io/ai-daily-review-dashboard/"
$expectedRemotePattern = "^(https://github\.com/|git@github\.com:)MichaelMao0511/ai-daily-review-dashboard(?:\.git)?$"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git -C $projectRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return ($output -join [Environment]::NewLine).Trim()
}

function Write-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$TradeDate,
        [string]$Commit,
        [bool]$Verified,
        [string]$ErrorMessage
    )

    [ordered]@{
        status = $Status
        trade_date = $TradeDate
        commit = $Commit
        url = $siteUrl
        verified = $Verified
        error = $ErrorMessage
    } | ConvertTo-Json -Compress
}

try {
    $sourceFiles = @(Get-ChildItem -LiteralPath $skillRoot -Filter "*.html" -File)
    if ($sourceFiles.Count -ne 1) {
        throw "Expected exactly one dashboard HTML under $skillRoot, found $($sourceFiles.Count)"
    }
    $sourcePath = $sourceFiles[0].FullName

    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ".git") -PathType Container)) {
        throw "Git repository not initialized: $projectRoot"
    }

    $remote = Invoke-Git -Arguments @("remote", "get-url", "origin")
    if ($remote -notmatch $expectedRemotePattern) {
        throw "Unexpected Git remote: $remote"
    }

    $branch = Invoke-Git -Arguments @("branch", "--show-current")
    if ($branch -ne "main") {
        throw "Expected branch main, found: $branch"
    }

    $sourceHtml = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)
    $dateMatch = [regex]::Match(
        $sourceHtml,
        'window\.__AI_DAILY_REVIEW_DATA__\s*=\s*\{"latest":\{"trade_date":"(?<date>\d{4}-\d{2}-\d{2})"'
    )
    if (-not $dateMatch.Success) {
        throw "No valid latest trade_date found in dashboard source"
    }
    $tradeDate = $dateMatch.Groups["date"].Value

    $robotsMeta = '<meta name="robots" content="noindex, nofollow, noarchive" />'
    if ($sourceHtml.Contains($robotsMeta)) {
        $siteHtml = $sourceHtml
    } else {
        $charsetTag = '<meta charset="utf-8" />'
        if (-not $sourceHtml.Contains($charsetTag)) {
            throw "Expected charset tag not found in dashboard source"
        }
        $siteHtml = $sourceHtml.Replace($charsetTag, "$charsetTag`r`n    $robotsMeta")
    }

    $layoutMarker = "/* online-responsive-fix */"
    if (-not $siteHtml.Contains($layoutMarker)) {
        $layoutCss = @"
$layoutMarker
.tables,
.table-section {
  min-width: 0;
}

.table-scroll {
  width: 100%;
}
"@
        $siteHtml = $siteHtml.Replace("</style>", "$layoutCss`r`n</style>")
    }

    $currentHtml = if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
    } else {
        $null
    }
    if ($currentHtml -ne $siteHtml) {
        [System.IO.File]::WriteAllText($indexPath, $siteHtml, $utf8NoBom)
    }

    Invoke-Git -Arguments @("add", "--", "index.html", "robots.txt", ".nojekyll") | Out-Null
    $staged = Invoke-Git -Arguments @("status", "--short", "--", "index.html", "robots.txt", ".nojekyll")
    $createdCommit = -not [string]::IsNullOrWhiteSpace($staged)
    if ($createdCommit) {
        Invoke-Git -Arguments @("commit", "-m", "Update dashboard $tradeDate") | Out-Null
    }

    $branchStatus = Invoke-Git -Arguments @("status", "--short", "--branch")
    $hadPendingCommits = $branchStatus -match '\[ahead \d+'
    Invoke-Git -Arguments @("push", "origin", "main") | Out-Null

    $commit = Invoke-Git -Arguments @("rev-parse", "HEAD")
    $expectedMarker = '"trade_date":"' + $tradeDate + '"'
    $cacheKey = "$($commit.Substring(0, 12))-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $verified = $false
    $deadline = (Get-Date).AddMinutes(5)
    do {
        try {
            $response = Invoke-WebRequest -Uri "${siteUrl}?v=$cacheKey" -UseBasicParsing -TimeoutSec 20
            if (
                $response.StatusCode -eq 200 -and
                $response.Content.Contains($expectedMarker) -and
                $response.Content.Contains($layoutMarker)
            ) {
                $verified = $true
                break
            }
        } catch {
            # GitHub Pages can return 404 while a new deployment is propagating.
        }

        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    if (-not $verified) {
        throw "Online verification did not find trade_date $tradeDate within 5 minutes"
    }

    $status = if ($createdCommit -or $hadPendingCommits) { "published" } else { "no_change" }
    Write-Result -Status $status -TradeDate $tradeDate -Commit $commit -Verified $true
    exit 0
} catch {
    Write-Result -Status "failed" -TradeDate $tradeDate -Commit $commit -Verified $false -ErrorMessage $_.Exception.Message
    exit 1
}
