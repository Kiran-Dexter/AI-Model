#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 1 of 2 - Download Microsoft Office AND Windows updates for offline patching.

    Windows (menu rows after the Office ones):
      * Windows 11 24H2/25H2, 22H2/23H2, Windows 10 22H2, Windows 10 LTSC 2021 (21H2),
        Windows Server 2019 / Windows 10 LTSC 2019 (1809) - x64, x86, ARM64 where they exist.
      * Downloads the Latest Cumulative Update (LCU), the .NET Framework cumulative update and,
        for 1809/Server 2019, the Servicing Stack Update. All files of an update (e.g. the
        Windows 11 24H2 "checkpoint" MSU) are kept together in one folder, as DISM requires.
      * Windows 10 22H2: besides the newest (ESU-only) update, the last public update
        (Oct-2025) is also kept, so PCs without an ESU licence can still be patched.

.DESCRIPTION
    Run this on a Windows machine WITH internet access.

    It lists the Office products/architectures, lets you pick which ones you need,
    and downloads:

      * MSI-based Office 2010 / 2013 / 2016 (Volume / Pro Plus / Standard / Visio / Project ...)
        Every patch published in the date range (default 2020-01-01 .. 2024-12-31) from the
        Microsoft Update Catalog. Each .cab is SHA1-verified against the catalog, expanded to
        its .msp, Authenticode-checked, and its MSI metadata (PatchCode + target ProductCodes)
        is written to manifest.json so Script 2 can work out applicability offline.

      * Click-to-Run Office 2019 / LTSC 2021 / LTSC 2024 / Microsoft 365 Apps
        C2R has no individual patches: every build is cumulative. The latest (or a pinned)
        build of the chosen update channel is downloaded with the Office Deployment Tool.

    Output layout (copy the whole folder to your share or to the target machine):

      <Root>\manifest.json  manifest.csv
      <Root>\MSI\Office2016\x86\KB5002xxx_excel-x-none\excel-x-none.msp
      <Root>\C2R\setup.exe
      <Root>\C2R\PerpetualVL2019\x64\Office\Data\16.0.x.y\...
      <Root>\Logs\

    The script is safe to re-run: already-downloaded files are skipped (resume).

.PARAMETER DownloadRoot
    Folder to store everything in. Default C:\OfficePatches

.PARAMETER StartDate / EndDate
    Catalog "last updated" date range for MSI patches. Default 2020-01-01 .. 2024-12-31.

.PARAMETER Mode
    All    = every patch in the range (complete archive, large).
    Latest = only the newest patch per Office component in the range (Office MSI patches
             are cumulative per component, so this is enough to fully patch a machine).
    If omitted you are asked.

.PARAMETER Select
    Menu numbers to download without prompting, e.g. -Select 1,2,7

.PARAMETER Languages
    Languages for Click-to-Run builds and language-specific MSI patches. Default en-us.
    Must include EVERY language installed on the target PCs.

.EXAMPLE
    .\1-Download-OfficePatches.ps1

.EXAMPLE
    .\1-Download-OfficePatches.ps1 -DownloadRoot D:\OfficePatches -Mode Latest -Select 1,2 -Languages en-us,de-de

.NOTES
    Requires Windows PowerShell 5.1. No external modules. Uses expand.exe and the Windows
    Installer COM object (both built into Windows).
#>
[CmdletBinding()]
param(
    [string]   $DownloadRoot = 'C:\OfficePatches',
    [datetime] $StartDate    = '2020-01-01',
    [datetime] $EndDate      = '2024-12-31',
    [ValidateSet('All', 'Latest')]
    [string]   $Mode,
    [datetime] $OsEndDate = (Get-Date),
    [ValidateSet('All', 'Latest')]
    [string]   $OsMode,
    [switch]   $SkipDotNet,
    [int[]]    $Select,
    [string[]] $Languages,
    [switch]   $SecurityOnly,
    [switch]   $KeepCab,
    [string]   $Proxy,
    [switch]   $ProxyUseDefaultCredentials,
    [ValidateRange(1, 10)]
    [int]      $MaxRetries = 4
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

#region ------------------------------------------------------------------ constants
$Script:CatalogBase = 'https://www.catalog.update.microsoft.com'
$Script:OdtUrl      = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
$Script:LogFile     = $null
$Script:WebSession  = $null

# Catalog search terms per MSI Office version (one search per component keeps each
# query well under the catalog's 1000-result cap).
$Script:MsiComponents = @{
    '2016' = @('Office', 'Excel', 'Word', 'PowerPoint', 'Outlook', 'Access', 'Publisher', 'OneNote', 'Project', 'Visio', 'Skype for Business')
    '2013' = @('Office', 'Excel', 'Word', 'PowerPoint', 'Outlook', 'Access', 'Publisher', 'OneNote', 'Project', 'Visio', 'Lync', 'InfoPath')
    '2010' = @('Office', 'Excel', 'Word', 'PowerPoint', 'Outlook', 'Access', 'Publisher', 'OneNote', 'Project', 'Visio', 'InfoPath')
}
# Server-side products that share names with the client products - never wanted here.
$Script:ExcludeTitle = 'Server|SharePoint|Web Apps|Office Online|Exchange|Viewer|Compatibility Pack|Office Web'

$Script:C2RChannels = @(
    [pscustomobject]@{ Channel = 'PerpetualVL2019';   ProductId = 'ProPlus2019Volume'; Name = 'Office 2019 Volume / Pro Plus 2019 (C2R)' }
    [pscustomobject]@{ Channel = 'PerpetualVL2021';   ProductId = 'ProPlus2021Volume'; Name = 'Office LTSC 2021 Pro Plus (C2R)' }
    [pscustomobject]@{ Channel = 'PerpetualVL2024';   ProductId = 'ProPlus2024Volume'; Name = 'Office LTSC 2024 Pro Plus (C2R)' }
    [pscustomobject]@{ Channel = 'MonthlyEnterprise'; ProductId = 'O365ProPlusRetail'; Name = 'Microsoft 365 Apps - Monthly Enterprise' }
    [pscustomobject]@{ Channel = 'SemiAnnual';        ProductId = 'O365ProPlusRetail'; Name = 'Microsoft 365 Apps - Semi-Annual Enterprise' }
    [pscustomobject]@{ Channel = 'Current';           ProductId = 'O365ProPlusRetail'; Name = 'M365 Apps / Office 2019-2024 Retail - Current' }
)

# Windows families. Builds that share one cumulative update are one family.
# Catalog titles look like "2025-10 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB...)".
# Searches are made per month ("2025-10 Cumulative Update 24H2") with only whole words that really
# appear in the titles; architecture and exact product are filtered from the title afterwards.
#   Terms = version word(s) to search, Since = first month the family received updates
$Script:OsFamilies = @(
    [pscustomobject]@{ Family = 'W11_24H2'; Name = 'Windows 11 24H2 / 25H2 (build 26100/26200)'; Arches = @('x64', 'arm64')
        Terms = @('24H2', '25H2'); Since = '2024-09'; Ssu = $false; Pattern = 'Windows 11,? version (24H2|25H2)'; Note = 'Supported' }
    [pscustomobject]@{ Family = 'W11_23H2'; Name = 'Windows 11 22H2 / 23H2 (build 22621/22631)'; Arches = @('x64', 'arm64')
        Terms = @('23H2', '22H2'); Since = '2022-09'; Ssu = $false; Pattern = 'Windows 11,? version (22H2|23H2)'; Note = 'EOL Nov-2026 (Ent)' }
    [pscustomobject]@{ Family = 'W10_22H2'; Name = 'Windows 10 22H2 (build 19045)'; Arches = @('x64', 'x86')
        Terms = @('22H2'); Since = '2022-10'; Ssu = $false; Pattern = 'Windows 10,? version 22H2'; Note = 'EOL Oct-2025, ESU' }
    [pscustomobject]@{ Family = 'W10_21H2'; Name = 'Windows 10 Enterprise LTSC 2021 (21H2, 19044)'; Arches = @('x64', 'x86')
        Terms = @('21H2'); Since = '2021-11'; Ssu = $false; Pattern = 'Windows 10,? version 21H2'; Note = 'EOL Jan-2027' }
    [pscustomobject]@{ Family = 'WS2019'; Name = 'Windows Server 2019 / Win10 LTSC 2019 (17763)'; Arches = @('x64')
        Terms = @('Server 2019'); Since = '2018-11'; Ssu = $true; Pattern = 'Windows Server 2019'; Note = 'EOL Jan-2029' }
)
$Script:Win10PublicEnd = [datetime]'2025-10-31'   # last non-ESU Windows 10 22H2 update month

$Script:SupportNote = @{
    '2010' = 'EOL Oct-2020'; '2013' = 'EOL Apr-2023'; '2016' = 'EOL Oct-2025'
    'PerpetualVL2019' = 'EOL Oct-2025'; 'PerpetualVL2021' = 'EOL Oct-2026'; 'PerpetualVL2024' = 'Supported'
    'MonthlyEnterprise' = 'Supported'; 'SemiAnnual' = 'Supported'; 'Current' = 'Supported'
}
#endregion

#region ------------------------------------------------------------------ helpers
function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $line  = '[{0}] [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    if ($Script:LogFile) { try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 } catch { } }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        if ($a.Trim() -match '^(y|yes)$') { return $true }
        if ($a.Trim() -match '^(n|no)$')  { return $false }
    }
}

# Parses "1,3,5-7", "A" (all) or "Q" (quit -> returns -1)
function Read-MultiSelection {
    param([string]$Prompt, [int]$Max)
    while ($true) {
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $raw = $raw.Trim()
        if ($raw -match '^(a|all)$')       { return @(1..$Max) }
        if ($raw -match '^(q|quit|exit)$') { return @(-1) }
        $sel = New-Object System.Collections.Generic.List[int]
        $bad = $false
        foreach ($part in ($raw -split '[,;\s]+')) {
            if (-not $part) { continue }
            if ($part -match '^(\d+)-(\d+)$') {
                $a = [int]$Matches[1]; $b = [int]$Matches[2]
                if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
                foreach ($n in $a..$b) { if ($n -ge 1 -and $n -le $Max) { $sel.Add($n) } else { $bad = $true } }
            }
            elseif ($part -match '^\d+$') {
                $n = [int]$part
                if ($n -ge 1 -and $n -le $Max) { $sel.Add($n) } else { $bad = $true }
            }
            else { $bad = $true }
        }
        if ($bad -or $sel.Count -eq 0) {
            Write-Host '  Invalid selection. Examples: 1   1,3   2-5   A (all)   Q (quit)' -ForegroundColor Yellow
            continue
        }
        return @($sel | Sort-Object -Unique)
    }
}

function Invoke-WithRetry {
    param([scriptblock]$ScriptBlock, [string]$Activity, [int]$Attempts = $MaxRetries)
    $try = 0
    while ($true) {
        $try++
        try { return (& $ScriptBlock) }
        catch {
            if ($try -ge $Attempts) { throw }
            $delay = [int][math]::Min(60, 5 * [math]::Pow(2, $try - 1))
            Write-Log "$Activity failed (attempt $try/$Attempts): $($_.Exception.Message) - retrying in $delay s" WARN
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-Web {
    param([string]$Uri, [string]$Method = 'Get', $Body, [string]$OutFile)
    $ProgressPreference = 'SilentlyContinue'   # IWR's own progress bar makes downloads ~10x slower in PS 5.1
    $p = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = 600; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = $Body }
    if ($OutFile)        { $p.OutFile = $OutFile }
    if ($Script:WebSession) { $p.WebSession = $Script:WebSession } else { $p.SessionVariable = 'newSession' }
    if ($Proxy) {
        $p.Proxy = $Proxy
        if ($ProxyUseDefaultCredentials) { $p.ProxyUseDefaultCredentials = $true }
    }
    $r = Invoke-WebRequest @p
    if (-not $Script:WebSession -and $newSession) { $Script:WebSession = $newSession }
    return $r
}

function ConvertFrom-HtmlText {
    param([string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return '' }
    $t = [regex]::Replace($Html, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function Get-HiddenField {
    param([string]$Html, [string]$Name)
    $m = [regex]::Match($Html, '<input[^>]*\bname="' + [regex]::Escape($Name) + '"[^>]*>', 'IgnoreCase')
    if (-not $m.Success) { return '' }
    $v = [regex]::Match($m.Value, '\bvalue="([^"]*)"', 'IgnoreCase')
    if ($v.Success) { return [System.Net.WebUtility]::HtmlDecode($v.Groups[1].Value) }
    return ''
}

function ConvertTo-Bytes {
    param([string]$Text)
    $m = [regex]::Match($Text, '([\d\.,]+)\s*(KB|MB|GB)', 'IgnoreCase')
    if (-not $m.Success) { return 0 }
    $n = [double]::Parse(($m.Groups[1].Value -replace ',', ''), [Globalization.CultureInfo]::InvariantCulture)
    switch ($m.Groups[2].Value.ToUpper()) { 'KB' { return [int64]($n * 1KB) } 'MB' { return [int64]($n * 1MB) } 'GB' { return [int64]($n * 1GB) } }
    return 0
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}
#endregion

#region ------------------------------------------------------------------ Microsoft Update Catalog
function ConvertFrom-CatalogResultHtml {
    param([string]$Html)
    $rows = New-Object System.Collections.Generic.List[object]
    $table = [regex]::Match($Html, '(?s)id="ctl00_catalogBody_updateMatches".*?</table>')
    if (-not $table.Success) { return $rows }

    foreach ($tr in [regex]::Matches($table.Value, '(?s)<tr\b([^>]*)>(.*?)</tr>')) {
        $attr  = $tr.Groups[1].Value
        $inner = $tr.Groups[2].Value
        if ($attr -match 'headerRow') { continue }

        $idm = [regex]::Match($inner, 'goToDetails\("([0-9a-fA-F\-]{36})"\)')
        if (-not $idm.Success) { $idm = [regex]::Match($inner, '<input[^>]*\bid="([0-9a-fA-F\-]{36})"') }
        if (-not $idm.Success) { $idm = [regex]::Match($attr, 'id="([0-9a-fA-F\-]{36})_R\d+"') }
        if (-not $idm.Success) { continue }

        $cells = @([regex]::Matches($inner, '(?s)<td\b[^>]*>(.*?)</td>') | ForEach-Object { $_.Groups[1].Value })
        if ($cells.Count -lt 6) { continue }

        # Locate the "Last Updated" column (m/d/yyyy) and read the other columns relative to it
        $di = -1
        for ($i = 0; $i -lt $cells.Count; $i++) {
            if ((ConvertFrom-HtmlText $cells[$i]) -match '^\d{1,2}/\d{1,2}/\d{4}$') { $di = $i; break }
        }
        if ($di -lt 3) { continue }

        $date = [datetime]::ParseExact((ConvertFrom-HtmlText $cells[$di]), 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture)
        $sizeBytes = 0
        if ($cells.Count -gt $di + 2) {
            $orig = [regex]::Match($cells[$di + 2], 'originalSize[^>]*>\s*(\d+)\s*<', 'IgnoreCase')
            if ($orig.Success) { $sizeBytes = [int64]$orig.Groups[1].Value } else { $sizeBytes = ConvertTo-Bytes (ConvertFrom-HtmlText $cells[$di + 2]) }
        }
        $title = ConvertFrom-HtmlText $cells[$di - 3]
        $kbm   = [regex]::Match($title, 'KB(\d{6,8})')

        $rows.Add([pscustomobject]@{
            UpdateId       = $idm.Groups[1].Value.ToLower()
            Title          = $title
            Products       = ConvertFrom-HtmlText $cells[$di - 2]
            Classification = ConvertFrom-HtmlText $cells[$di - 1]
            Date           = $date
            SizeBytes      = $sizeBytes
            KB             = $(if ($kbm.Success) { $kbm.Groups[1].Value } else { $null })
        })
    }
    return $rows
}

# One catalog page -> rows + flags. Never throws for "no results"; only network errors throw.
function Get-CatalogPage {
    param([string]$Uri, [string]$Method = 'Get', $Body)
    $r    = Invoke-Web -Uri $Uri -Method $Method -Body $Body
    $html = [string]$r.Content
    $rows = @(ConvertFrom-CatalogResultHtml $html)
    $pm   = [regex]::Match($html, '\(page\s+(\d+)\s+of\s+(\d+)\)')
    return [pscustomobject]@{
        Html      = $html
        Rows      = $rows
        PageNo    = $(if ($pm.Success) { [int]$pm.Groups[1].Value } else { 0 })
        NoResults = ($rows.Count -eq 0 -and $html -match 'noResultText|did not find any results')
        ErrorCode = [regex]::Match($html, '8DDD0[0-9A-Fa-f]{3}').Value
    }
}

function Search-Catalog {
    param([string]$Query)
    $searchUri = "$Script:CatalogBase/Search.aspx?q=" + [uri]::EscapeDataString($Query)
    $found = New-Object System.Collections.Generic.List[object]
    $ids   = @{}

    # First page. A page with zero rows is either "no results" or a transient catalog error page;
    # retry once, then accept it as empty instead of failing the whole run.
    $page = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $page = Invoke-WithRetry -Activity "Catalog search '$Query'" -ScriptBlock { Get-CatalogPage -Uri $searchUri }
        if ($page.Rows.Count -gt 0 -or $page.NoResults) { break }
        if ($attempt -eq 1) { Start-Sleep -Seconds 5 }
    }
    if ($page.Rows.Count -eq 0) {
        if (-not $page.NoResults) {
            $why = if ($page.ErrorCode) { "catalog page $($page.ErrorCode)" } else { 'empty page' }
            Write-Log "  '$Query': no results ($why)."
        }
        return $found
    }

    $pageNo = 1
    while ($true) {
        foreach ($r in $page.Rows) { if (-not $ids.ContainsKey($r.UpdateId)) { $ids[$r.UpdateId] = $true; $found.Add($r) } }
        $html = $page.Html
        $cnt  = [regex]::Match($html, 'of\s+(\d+)\s*\(page\s+(\d+)\s+of\s+(\d+)\)')
        if ($pageNo -eq 1 -and $cnt.Success -and [int]$cnt.Groups[1].Value -ge 1000) {
            Write-Log "  '$Query' hit the catalog's 1000-result cap - some older items may be missing." WARN
        }
        if ($html -notmatch 'id="ctl00_catalogBody_nextPageLinkText"') { break }
        if ($cnt.Success -and [int]$cnt.Groups[2].Value -ge [int]$cnt.Groups[3].Value) { break }
        if ($pageNo -ge 40) { break }

        $pageNo++
        Start-Sleep -Milliseconds 300
        $next = $null
        try {
            # 1st choice: page number in the URL (simple GET)
            $next = Invoke-WithRetry -Activity "Catalog search '$Query' page $pageNo" -Attempts 2 -ScriptBlock { Get-CatalogPage -Uri "$searchUri&p=$pageNo" }
            if ($next.Rows.Count -eq 0 -or $next.PageNo -ne $pageNo) {
                # 2nd choice: ASP.NET "next page" postback
                $pageBody = @{
                    '__EVENTTARGET'        = 'ctl00$catalogBody$nextPageLinkText'
                    '__EVENTARGUMENT'      = Get-HiddenField $html '__EVENTARGUMENT'
                    '__VIEWSTATE'          = Get-HiddenField $html '__VIEWSTATE'
                    '__VIEWSTATEGENERATOR' = Get-HiddenField $html '__VIEWSTATEGENERATOR'
                    '__EVENTVALIDATION'    = Get-HiddenField $html '__EVENTVALIDATION'
                }
                $next = Invoke-WithRetry -Activity "Catalog search '$Query' page $pageNo (postback)" -Attempts 2 -ScriptBlock { Get-CatalogPage -Uri $searchUri -Method Post -Body $pageBody }
            }
        }
        catch { $next = $null }
        if (-not $next -or $next.Rows.Count -eq 0) {
            Write-Log "  '$Query': page $pageNo could not be loaded - keeping the $($found.Count) result(s) already found." WARN
            break
        }
        $page = $next
    }
    return $found
}

function Get-CatalogDownloadLink {
    param([string]$UpdateId)
    $post = '[{"size":0,"languages":"","uidInfo":"' + $UpdateId + '","updateID":"' + $UpdateId + '"}]'
    $dlg  = Invoke-WithRetry -Activity "Resolve download link $UpdateId" -ScriptBlock {
        Invoke-Web -Uri "$Script:CatalogBase/DownloadDialog.aspx" -Method Post -Body @{ updateIDs = $post }
    }
    $html  = [string]$dlg.Content
    $links = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($html, "\.url\s*=\s*'([^']+)'")) { $links.Add($m.Groups[1].Value) }
    if ($links.Count -eq 0) {
        foreach ($m in [regex]::Matches($html, "(https?://[^'`"\s]+?\.(?:cab|exe|msp))")) { $links.Add($m.Groups[1].Value) }
    }
    return @($links | Select-Object -Unique)
}
#endregion

#region ------------------------------------------------------------------ files / MSI
function Save-VerifiedFile {
    param([string]$Url, [string]$Path, [string]$Sha1)
    if ($Sha1 -and (Test-Path -LiteralPath $Path)) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash -eq $Sha1.ToUpper()) { return }
    }
    $part = "$Path.part"
    $candidates = @()
    if ($Url -like 'http://*') { $candidates += ('https://' + $Url.Substring(7)) }   # prefer TLS, fall back to the original URL
    $candidates += $Url

    Invoke-WithRetry -Activity "Download $(Split-Path $Path -Leaf)" -ScriptBlock {
        $lastError = $null
        foreach ($candidate in $candidates) {
            try {
                if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
                Invoke-Web -Uri $candidate -OutFile $part | Out-Null
                $lastError = $null
                break
            }
            catch { $lastError = $_ }
        }
        if ($lastError) { throw $lastError }
        if ($Sha1) {
            $h = (Get-FileHash -LiteralPath $part -Algorithm SHA1).Hash
            if ($h -ne $Sha1.ToUpper()) { throw "SHA1 mismatch (expected $Sha1, got $h)" }
        }
    } | Out-Null
    Move-Item -LiteralPath $part -Destination $Path -Force
}

function Expand-UpdatePackage {
    param([string]$Package, [string]$Destination)
    $ErrorActionPreference = 'Continue'   # native tools write to stderr; don't turn that into terminating errors
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    if ($Package -like '*.cab') {
        $out = & "$env:SystemRoot\System32\expand.exe" "$Package" -F:* "$Destination" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "expand.exe failed ($LASTEXITCODE): $($out -join ' ')" }
    }
    elseif ($Package -like '*.exe') {
        $p = Start-Process -FilePath $Package -ArgumentList "/extract:`"$Destination`" /quiet" -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "Self-extractor failed with exit code $($p.ExitCode)" }
    }
    elseif ($Package -like '*.msp') {
        Copy-Item -LiteralPath $Package -Destination $Destination -Force
    }
    return @(Get-ChildItem -LiteralPath $Destination -Filter '*.msp' -File -Recurse)
}

function Test-MicrosoftSignature {
    param([string]$Path)
    try {
        $sig  = Get-AuthenticodeSignature -LiteralPath $Path
        $subj = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        return [pscustomobject]@{ Ok = ($sig.Status -eq 'Valid' -and $subj -match 'Microsoft'); Status = [string]$sig.Status; Subject = $subj }
    }
    catch { return [pscustomobject]@{ Ok = $false; Status = $_.Exception.Message; Subject = '' } }
}

# Decides whether an extracted .msp can be trusted. Many catalog .msp files carry no embedded
# Authenticode signature - the Microsoft signature is on the .cab they ship in, and the catalog
# also publishes the file's SHA1 (verified at download). Chain of trust, strongest first:
#   1. .msp itself signed by Microsoft
#   2. containing .cab/.exe signed by Microsoft
#   3. containing package matched the SHA1 published by the Update Catalog (HTTPS)
function Get-PatchTrust {
    param([string]$MspPath, $PackageSig, [string]$CatalogSha1)
    $name   = Split-Path $MspPath -Leaf
    $mspSig = Test-MicrosoftSignature $MspPath
    if ($mspSig.Ok) { return 'MspSignature' }
    if ($mspSig.Status -eq 'HashMismatch') { throw "$name is signed but its content does not match the signature (HashMismatch) - corrupt or tampered." }
    if ($PackageSig -and $PackageSig.Ok) {
        Write-Log "  $name has no embedded signature ($($mspSig.Status)); trusted via Microsoft-signed package." INFO
        return 'PackageSignature'
    }
    if ($CatalogSha1) {
        Write-Log "  $name and its package are unsigned; trusted via the SHA1 published by the Update Catalog." WARN
        return 'CatalogHash'
    }
    $pkgStatus = if ($PackageSig) { $PackageSig.Status } else { 'n/a' }
    throw "Cannot verify $name : msp signature $($mspSig.Status), package signature $pkgStatus, no catalog hash."
}

# Reads PatchCode, target ProductCodes and KB from an .msp via the Windows Installer COM API.
function Get-MspMetadata {
    param([string]$Path)
    $meta = [ordered]@{ PatchCode = $null; TargetProductCodes = @(); ObsoletedPatchCodes = @(); KB = $null; PatchDisplayName = $null }
    $installer = $null; $db = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db  = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 32))  # 32 = open as patch
        $si  = $db.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $db, @(0))
        $template = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(7))   # target ProductCodes
        $revision = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(9))   # PatchCode + obsoleted codes
        $guids = @([regex]::Matches($revision, '\{[0-9A-Fa-f\-]{36}\}') | ForEach-Object { $_.Value.ToUpper() })
        if ($guids.Count -gt 0) { $meta.PatchCode = $guids[0] }
        if ($guids.Count -gt 1) { $meta.ObsoletedPatchCodes = @($guids[1..($guids.Count - 1)]) }
        $meta.TargetProductCodes = @([regex]::Matches($template, '\{[0-9A-Fa-f\-]{36}\}') | ForEach-Object { $_.Value.ToUpper() } | Select-Object -Unique)
        try {
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT `Property`, `Value` FROM `MsiPatchMetadata`'))
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            while ($true) {
                $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if ($null -eq $rec) { break }
                $prop = [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
                $val  = [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(2))
                if ($prop -eq 'KBArticle Number') { $meta.KB = ($val -replace '\D', '') }
                if ($prop -eq 'DisplayName')      { $meta.PatchDisplayName = $val }
            }
            [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        }
        catch { }
    }
    catch {
        Write-Log "  Could not read MSI metadata from $(Split-Path $Path -Leaf): $($_.Exception.Message)" WARN
    }
    finally {
        foreach ($o in @($db, $installer)) { if ($o) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { } } }
    }
    return [pscustomobject]$meta
}
#endregion

#region ------------------------------------------------------------------ Windows updates
function Get-OsUpdateKind {
    param([string]$Title)
    if ($Title -match 'Preview|Dynamic|Hotpatch|Safe OS|Setup|Feature update|Upgrade|Language|Internet Explorer|Flash|Security Only|Delta') { return $null }
    if ($Title -match 'Servicing Stack Update')                     { return 'SSU' }
    if ($Title -match 'Cumulative Update for \.NET Framework')       { return 'DotNet' }
    if ($Title -match 'Cumulative Update for (Microsoft )?Windows')  { return 'LCU' }
    return $null
}

function Get-DotNetTag {
    param([string]$Title)
    if ($Title -match '4\.8\.1') { return '4.8.1' }
    if ($Title -match '4\.8')    { return '4.8' }
    if ($Title -match '4\.7\.2') { return '4.7.2' }
    return 'other'
}

# First day of every month between From and To, newest first.
function Get-MonthList {
    param([datetime]$From, [datetime]$To)
    $first = (Get-Date -Year $From.Year -Month $From.Month -Day 1).Date
    $m     = (Get-Date -Year $To.Year -Month $To.Month -Day 1).Date
    $list  = @()
    while ($m -ge $first) { $list += $m; $m = $m.AddMonths(-1) }
    return $list
}

# Filters catalog rows to one Windows family + the selected architectures and adds them to $Found.
function Add-OsCatalogRow {
    param($Rows, $Fam, [string[]]$Arches, [hashtable]$Found, [hashtable]$Seen)
    $kept = 0
    foreach ($r in @($Rows)) {
        if ($r.Title -notmatch $Fam.Pattern) { continue }
        $kind = Get-OsUpdateKind $r.Title
        if (-not $kind) { continue }
        if ($kind -eq 'DotNet' -and $SkipDotNet) { continue }
        foreach ($arch in $Arches) {
            if ($r.Title -notmatch ('\b' + [regex]::Escape($arch) + '\b')) { continue }   # "x64-based" / "for x64" / "ARM64-based"
            $key = "$($r.UpdateId)|$arch"
            if ($Found.ContainsKey($key)) { continue }
            $tag = if ($kind -eq 'DotNet') { Get-DotNetTag $r.Title } else { '' }
            $dk  = '{0}|{1}|{2}|{3}|{4}' -f $Fam.Family, $arch, $kind, $tag, $r.KB
            if ($r.KB -and $Seen.ContainsKey($dk)) { continue }   # same KB listed as 22H2 and 23H2 etc.
            $Seen[$dk] = $true
            $sortDate = $r.Date
            $rm = [regex]::Match($r.Title, '^(\d{4})-(\d{2})\b')
            if ($rm.Success) { $sortDate = (Get-Date -Year ([int]$rm.Groups[1].Value) -Month ([int]$rm.Groups[2].Value) -Day 15).Date }
            $r | Add-Member -NotePropertyName Family    -NotePropertyValue $Fam.Family -Force
            $r | Add-Member -NotePropertyName Arch      -NotePropertyValue $arch -Force
            $r | Add-Member -NotePropertyName Kind      -NotePropertyValue $kind -Force
            $r | Add-Member -NotePropertyName DotNetTag -NotePropertyValue $tag -Force
            $r | Add-Member -NotePropertyName SortDate  -NotePropertyValue $sortDate -Force
            $Found[$key] = $r
            $kept++
        }
    }
    return $kept
}

# "Newest only" mode: stop scanning back once every architecture has its cumulative update
# (+ .NET within 12 months, + servicing stack within 24 months for Server 2019).
function Test-OsScanComplete {
    param($Fam, [string[]]$Arches, [hashtable]$Found, [int]$Scanned)
    foreach ($arch in $Arches) {
        $mine = @($Found.Values | Where-Object { $_.Family -eq $Fam.Family -and $_.Arch -eq $arch })
        if (-not @($mine | Where-Object { $_.Kind -eq 'LCU' })) { return $false }
        if (-not $SkipDotNet -and $Scanned -lt 12 -and -not @($mine | Where-Object { $_.Kind -eq 'DotNet' })) { return $false }
        if ($Fam.Ssu -and $Scanned -lt 24 -and -not @($mine | Where-Object { $_.Kind -eq 'SSU' })) { return $false }
    }
    return $true
}

# Reads the OS build (e.g. 19045.5247) an LCU installs, from the unattend XML inside the MSU.
# Best effort - newer MSU formats may not carry it; Script 2 then falls back to KB/date logic.
function Get-MsuTargetBuild {
    param([string]$Msu)
    $tmp = Join-Path $env:TEMP ('msu_' + [guid]::NewGuid().ToString('N'))
    $ErrorActionPreference = 'Continue'
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        & "$env:SystemRoot\System32\expand.exe" "$Msu" '-F:*.xml' "$tmp" 2>&1 | Out-Null
        foreach ($x in @(Get-ChildItem -LiteralPath $tmp -Filter '*.xml' -File -Recurse -ErrorAction SilentlyContinue)) {
            $txt = [string](Get-Content -LiteralPath $x.FullName -Raw -ErrorAction SilentlyContinue)
            $m = [regex]::Match($txt, 'Package_for_RollupFix"[^>]*?version="(\d+)\.(\d+)\.')
            if (-not $m.Success) { $m = [regex]::Match($txt, 'version="(\d+)\.(\d+)\.[^"]*"[^>]*?name="Package_for_RollupFix"') }
            if ($m.Success) { return "$($m.Groups[1].Value).$($m.Groups[2].Value)" }
        }
    }
    catch { }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    return $null
}

# Large files (Windows LCUs are 0.5 - 4 GB): BITS with a live progress bar and resume,
# falling back to a direct download when BITS is unavailable.
function Save-LargeFile {
    param([string]$Url, [string]$Path, [string]$Sha1, [string]$Label)
    if ($Sha1 -and (Test-Path -LiteralPath $Path)) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash -eq $Sha1.ToUpper()) { return }
    }
    $part = "$Path.part"
    $src  = if ($Url -like 'http://*') { 'https://' + $Url.Substring(7) } else { $Url }
    $job  = $null
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        $bits = @{ Source = $src; Destination = $part; Asynchronous = $true; DisplayName = 'OfficeWinPatchDownload'; Priority = 'Foreground'; ErrorAction = 'Stop' }
        if ($Proxy) { $bits.ProxyUsage = 'Override'; $bits.ProxyList = $Proxy }
        $job = Start-BitsTransfer @bits
        $transientSince = $null
        while ($job.JobState -in @('Queued', 'Connecting', 'Transferring', 'TransientError')) {
            if ($job.JobState -eq 'TransientError') {
                if (-not $transientSince) { $transientSince = Get-Date }
                elseif (((Get-Date) - $transientSince).TotalMinutes -gt 10) { throw "BITS transient error for 10 min: $($job.ErrorDescription)" }
            }
            else { $transientSince = $null }
            $tot = [double]$job.BytesTotal; $got = [double]$job.BytesTransferred
            if ($tot -gt 0 -and $tot -lt 1e15) {
                Write-Progress -Id 2 -ParentId 1 -Activity "Downloading $Label" -Status ('{0} of {1}' -f (Format-Size $got), (Format-Size $tot)) -PercentComplete ([int](100 * $got / $tot))
            }
            else { Write-Progress -Id 2 -ParentId 1 -Activity "Downloading $Label" -Status 'Connecting...' }
            Start-Sleep -Seconds 2
        }
        Write-Progress -Id 2 -Activity "Downloading $Label" -Completed
        if ($job.JobState -ne 'Transferred') { throw "BITS job ended in state $($job.JobState): $($job.ErrorDescription)" }
        Complete-BitsTransfer -BitsJob $job
        $job = $null
        if ($Sha1) {
            $h = (Get-FileHash -LiteralPath $part -Algorithm SHA1).Hash
            if ($h -ne $Sha1.ToUpper()) { throw "SHA1 mismatch (expected $Sha1, got $h)" }
        }
        Move-Item -LiteralPath $part -Destination $Path -Force
    }
    catch {
        if ($job) { try { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue } catch { } }
        Write-Log "  BITS download failed ($($_.Exception.Message)) - using direct download instead." WARN
        Save-VerifiedFile -Url $Url -Path $Path -Sha1 $Sha1
    }
}
#endregion

#region ------------------------------------------------------------------ manifest
$Script:OsEntries  = @{}   # key UpdateId -> entry
$Script:DoneOs     = @{}   # key UpdateId -> $true when every file exists
$Script:Sha1Cache  = @{}   # SHA1 -> full path (re-use checkpoint MSUs instead of re-downloading)
$Script:MsiEntries = @{}   # key UpdateId|SourceFile|MspFile -> entry
$Script:DoneSources = @{}  # key UpdateId|SourceFile -> $true
$Script:C2REntries = @{}   # key Channel|Arch -> entry

function Import-Manifest {
    $path = Join-Path $DownloadRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($m.Msi)) {
            if (-not $e) { continue }
            $Script:MsiEntries["$($e.UpdateId)|$($e.SourceFile)|$($e.FileName)"] = $e
            if (Test-Path -LiteralPath (Join-Path $DownloadRoot $e.RelativePath)) { $Script:DoneSources["$($e.UpdateId)|$($e.SourceFile)"] = $true }
        }
        foreach ($e in @($m.C2R)) { if ($e) { $Script:C2REntries["$($e.Channel)|$($e.Arch)"] = $e } }
        foreach ($e in @($m.Os)) {
            if (-not $e) { continue }
            $Script:OsEntries[$e.UpdateId] = $e
            $allThere = $true
            foreach ($f in @($e.Files)) {
                $full = Join-Path $DownloadRoot $f.RelativePath
                if (Test-Path -LiteralPath $full) { if ($f.Sha1) { $Script:Sha1Cache[([string]$f.Sha1).ToUpper()] = $full } } else { $allThere = $false }
            }
            if ($allThere) { $Script:DoneOs[$e.UpdateId] = $true }
        }
        Write-Log ("Existing manifest loaded: {0} MSI patch file(s), {1} C2R build(s), {2} Windows update(s) - already-downloaded items will be skipped." -f $Script:MsiEntries.Count, $Script:C2REntries.Count, $Script:OsEntries.Count)
    }
    catch { Write-Log "Existing manifest.json could not be read ($($_.Exception.Message)); a new one will be written." WARN }
}

function Save-Manifest {
    $path = Join-Path $DownloadRoot 'manifest.json'
    $obj = [ordered]@{
        SchemaVersion = 1
        Generator     = '1-Download-OfficePatches.ps1'
        Generated     = (Get-Date).ToString('s')
        DateRange     = '{0:yyyy-MM-dd}..{1:yyyy-MM-dd}' -f $StartDate, $EndDate
        Msi           = @($Script:MsiEntries.Values | Sort-Object Family, Arch, Date, KB)
        C2R           = @($Script:C2REntries.Values | Sort-Object Channel, Arch)
        Os            = @($Script:OsEntries.Values | Sort-Object Family, Arch, Kind, Date)
    }
    $tmp = "$path.tmp"
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force

    $csv = Join-Path $DownloadRoot 'manifest.csv'
    $rows = @()
    $rows += @($Script:MsiEntries.Values | Sort-Object Family, Arch, Date | ForEach-Object {
        [pscustomobject]@{ Type = 'MSI'; Product = "Office $($_.Family)"; Arch = $_.Arch; KB = $_.KB; Component = $_.Component
            Classification = $_.Classification; Date = $_.Date; Title = $_.Title; File = $_.RelativePath; PatchCode = $_.PatchCode }
    })
    $rows += @($Script:C2REntries.Values | ForEach-Object {
        [pscustomobject]@{ Type = 'C2R'; Product = $_.Channel; Arch = $_.Arch; KB = ''; Component = 'All apps'
            Classification = 'Cumulative build'; Date = $_.Downloaded; Title = "Build $($_.Version) ($($_.Languages -join ','))"; File = $_.RelativePath; PatchCode = '' }
    })
    $rows += @($Script:OsEntries.Values | Sort-Object Family, Arch, Kind, Date | ForEach-Object {
        [pscustomobject]@{ Type = 'OS'; Product = $_.Family; Arch = $_.Arch; KB = $_.KB; Component = $_.Kind
            Classification = $(if ($_.TargetBuild) { "Build $($_.TargetBuild)" } else { '' }); Date = $_.Date; Title = $_.Title; File = $_.RelativeDir; PatchCode = '' }
    })
    if ($rows.Count) { $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 }
}
#endregion

#region ------------------------------------------------------------------ main
$exitCode = 0
try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    if ($ProxyUseDefaultCredentials -and -not $Proxy) {
        try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }
    }

    $DownloadRoot = $DownloadRoot.TrimEnd('\')
    $LogDir = Join-Path $DownloadRoot 'Logs'
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $Script:LogFile = Join-Path $LogDir ('Download_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Cyan
    Write-Host '   Office Offline Patch Downloader                (Step 1 of 2)' -ForegroundColor Cyan
    Write-Host '=====================================================================' -ForegroundColor Cyan
    Write-Log "Download folder : $DownloadRoot"
    Write-Log "Log file        : $Script:LogFile"
    Write-Log "PowerShell      : $($PSVersionTable.PSVersion) ($($ExecutionContext.SessionState.LanguageMode))"
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Log 'PowerShell is in Constrained Language Mode on this machine. Run the downloader on an unrestricted workstation, or sign/allow-list the script.' WARN
    }
    if ($EndDate -lt $StartDate) { throw "EndDate ($EndDate) is before StartDate ($StartDate)." }

    Write-Log 'Checking internet access to the Microsoft Update Catalog...' STEP
    try { Invoke-WithRetry -Activity 'Catalog connectivity test' -Attempts 2 -ScriptBlock { Invoke-Web -Uri "$Script:CatalogBase/Home.aspx" } | Out-Null; Write-Log 'Catalog reachable.' OK }
    catch { throw "Cannot reach $Script:CatalogBase ($($_.Exception.Message)). Check internet/proxy access (use -Proxy http://proxy:port -ProxyUseDefaultCredentials)." }

    Import-Manifest

    # ---------------------------------------------------------------- product menu
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($fam in '2016', '2013', '2010') {
        foreach ($arch in 'x86', 'x64') {
            $items.Add([pscustomobject]@{ Type = 'MSI'; Family = $fam; Arch = $arch; Channel = $null; ProductId = $null
                Name = "Office $fam Pro Plus / Std / Visio / Project (MSI)"; Note = $Script:SupportNote[$fam] })
        }
    }
    foreach ($c in $Script:C2RChannels) {
        foreach ($arch in 'x86', 'x64') {
            $items.Add([pscustomobject]@{ Type = 'C2R'; Family = $null; Arch = $arch; Channel = $c.Channel; ProductId = $c.ProductId
                Name = $c.Name; Note = $Script:SupportNote[$c.Channel] })
        }
    }
    # Windows rows are appended last so existing -Select numbers for Office keep working
    foreach ($fam in $Script:OsFamilies) {
        foreach ($arch in $fam.Arches) {
            $items.Add([pscustomobject]@{ Type = 'OS'; Family = $fam.Family; Arch = $arch; Channel = $null; ProductId = $null
                Name = $fam.Name; Note = $fam.Note })
        }
    }

    Write-Host ''
    Write-Host '  #   Product                                              Arch    Type  Lifecycle' -ForegroundColor White
    Write-Host '  --- ---------------------------------------------------- ------  ----  ------------'
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $archLabel = switch ($it.Arch) { 'x64' { '64-bit' } 'arm64' { 'ARM64' } default { '32-bit' } }
        if ($i -gt 0 -and $it.Type -ne $items[$i - 1].Type) { Write-Host '' }
        $line = '  {0,3} {1,-52} {2,-6}  {3,-4}  {4}' -f ($i + 1), $it.Name, $archLabel, $it.Type, $it.Note
        switch ($it.Type) { 'MSI' { Write-Host $line } 'C2R' { Write-Host $line -ForegroundColor DarkCyan } default { Write-Host $line -ForegroundColor DarkYellow } }
    }
    Write-Host ''
    Write-Host '  Tip: not sure which you have? On a target PC open Word > File > Account > About.'
    Write-Host '       "Click-to-Run" in that window = C2R. Otherwise it is MSI. Bitness is shown there too.'
    Write-Host '       Windows version: run "winver" on a target PC (the build number picks the row).'
    Write-Host ''

    if ($Select) { $picked = @($Select | Where-Object { $_ -ge 1 -and $_ -le $items.Count } | Sort-Object -Unique) }
    else { $picked = Read-MultiSelection -Prompt 'Select products to download (e.g. 1,2,8  or A = all, Q = quit)' -Max $items.Count }
    if ($picked -contains -1 -or -not $picked) { Write-Log 'Nothing selected - exiting.' WARN; exit 0 }
    $selected = @($picked | ForEach-Object { $items[$_ - 1] })
    foreach ($s in $selected) { Write-Log ("Selected: {0} [{1}] {2}" -f $s.Name, $s.Arch, $s.Type) }

    $msiSel = @($selected | Where-Object { $_.Type -eq 'MSI' })
    $c2rSel = @($selected | Where-Object { $_.Type -eq 'C2R' })
    $osSel  = @($selected | Where-Object { $_.Type -eq 'OS' })

    if ($osSel.Count -and -not $OsMode) {
        if ($Select) { $OsMode = 'Latest' }
        else {
            Write-Host ''
            Write-Host '  Windows updates are cumulative - the newest one contains every earlier fix.'
            Write-Host '    [1] Newest update per Windows version  (recommended)'
            Write-Host ("    [2] Every monthly update {0:yyyy-MM} .. {1:yyyy-MM}  (archive only - each one is 0.5-4 GB)" -f $StartDate, $OsEndDate)
            do { $a = Read-Host '  Choose 1 or 2 [1]' } until ($a -eq '' -or $a -eq '1' -or $a -eq '2')
            $OsMode = if ($a -eq '2') { 'All' } else { 'Latest' }
        }
    }
    if ($osSel.Count -and -not $SkipDotNet -and -not $Select) {
        $SkipDotNet = -not (Read-YesNo '  Also download .NET Framework cumulative updates for these Windows versions?' $true)
    }

    # ---------------------------------------------------------------- options
    if ($msiSel.Count -and -not $Select) {
        Write-Host ''
        Write-Host ("  MSI date range: {0:yyyy-MM-dd} .. {1:yyyy-MM-dd}" -f $StartDate, $EndDate)
        if (-not (Read-YesNo '  Keep this date range?' $true)) {
            do { $s = Read-Host '  Start date (yyyy-MM-dd)' } until ($s -match '^\d{4}-\d{2}-\d{2}$')
            do { $e = Read-Host '  End date   (yyyy-MM-dd)' } until ($e -match '^\d{4}-\d{2}-\d{2}$')
            $StartDate = [datetime]::ParseExact($s, 'yyyy-MM-dd', $null)
            $EndDate   = [datetime]::ParseExact($e, 'yyyy-MM-dd', $null)
            if ($EndDate -lt $StartDate) { throw 'End date is before start date.' }
        }
        if (-not $SecurityOnly) { $SecurityOnly = -not (Read-YesNo '  Include non-security (bug-fix) updates as well?' $true) }
    }
    if ($msiSel.Count -and -not $Mode) {
        Write-Host ''
        Write-Host '  Download mode for MSI patches:'
        Write-Host '    [1] Newest patch per component in the range  (recommended - patches are cumulative, much smaller)'
        Write-Host '    [2] Every patch in the range                 (full archive; useful if auditors check each KB)'
        do { $a = Read-Host '  Choose 1 or 2 [1]' } until ($a -eq '' -or $a -eq '1' -or $a -eq '2')
        $Mode = if ($a -eq '2') { 'All' } else { 'Latest' }
    }
    if (-not $Mode) { $Mode = 'Latest' }

    if (-not $Languages) {
        if ($Select) { $Languages = @('en-us') }
        else {
            $ans = Read-Host '  Languages (comma separated, must cover every language installed on target PCs) [en-us]'
            $Languages = if ([string]::IsNullOrWhiteSpace($ans)) { @('en-us') } else { @($ans -split '[,;\s]+' | Where-Object { $_ }) }
        }
    }
    $Languages = @($Languages | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -match '^[a-z]{2,3}(-[a-z0-9]{2,4}){1,2}$' } | Select-Object -Unique)
    if (-not $Languages) { $Languages = @('en-us') }

    Write-Log ("Options: date range {0:yyyy-MM-dd}..{1:yyyy-MM-dd} | mode {2} | security only {3} | languages {4}" -f $StartDate, $EndDate, $Mode, [bool]$SecurityOnly, ($Languages -join ','))

    if ($osSel.Count) { Write-Log ("Windows options: mode {0} | .NET updates {1} | up to {2:yyyy-MM-dd}" -f $OsMode, (-not $SkipDotNet), $OsEndDate) }

    $stats = @{ MsiNew = 0; MsiSkipped = 0; MsiFailed = 0; C2ROk = 0; C2RFailed = 0; OsNew = 0; OsSkipped = 0; OsFailed = 0 }

    # ================================================================ MSI phase
    if ($msiSel.Count) {
        Write-Log 'Searching the Microsoft Update Catalog (this takes a few minutes)...' STEP
        $found  = @{}
        $qTotal = 0; foreach ($m in $msiSel) { $qTotal += $Script:MsiComponents[$m.Family].Count }
        $qDone  = 0
        foreach ($item in $msiSel) {
            $archText = if ($item.Arch -eq 'x86') { '32-Bit' } else { '64-Bit' }
            $comps    = $Script:MsiComponents[$item.Family]
            foreach ($comp in $comps) {
                $qDone++
                $query = if ($comp -eq 'Office') { "Microsoft Office $($item.Family) $archText" } else { "$comp $($item.Family) $archText" }
                Write-Progress -Id 1 -Activity 'Searching Microsoft Update Catalog' -Status "[$qDone/$qTotal] $query" -PercentComplete ([int](100 * $qDone / $qTotal))
                try { $rows = Search-Catalog -Query $query }
                catch { Write-Log "  Search failed for '$query': $($_.Exception.Message)" ERROR; continue }

                $kept = 0
                foreach ($r in $rows) {
                    if ($found.ContainsKey($r.UpdateId)) { continue }
                    if ($r.Title -notmatch "\b$($item.Family)\b") { continue }
                    if ($r.Title -notmatch [regex]::Escape("$archText Edition")) { continue }
                    if ($r.Title -match $Script:ExcludeTitle) { continue }
                    if ($r.Date -lt $StartDate -or $r.Date -gt $EndDate) { continue }
                    if ($SecurityOnly -and $r.Classification -notmatch 'Security') { continue }

                    $component = 'Office'
                    foreach ($c in ($comps | Where-Object { $_ -ne 'Office' })) { if ($r.Title -match [regex]::Escape($c)) { $component = $c; break } }
                    $r | Add-Member -NotePropertyName Family    -NotePropertyValue $item.Family
                    $r | Add-Member -NotePropertyName Arch      -NotePropertyValue $item.Arch
                    $r | Add-Member -NotePropertyName Component -NotePropertyValue $component
                    $found[$r.UpdateId] = $r
                    $kept++
                }
                Write-Log ('  {0,-42} {1,4} result(s), {2,4} new in range' -f $query, $rows.Count, $kept)
            }
        }
        Write-Progress -Id 1 -Activity 'Searching Microsoft Update Catalog' -Completed
        Write-Log ("Catalog search complete: {0} update(s) in range." -f $found.Count) OK

        # ------------------------------------------------ resolve download links
        Write-Log 'Resolving download links...' STEP
        $files = New-Object System.Collections.Generic.List[object]
        $n = 0; $total = [math]::Max(1, $found.Count)
        foreach ($u in $found.Values) {
            $n++
            Write-Progress -Id 1 -Activity 'Resolving download links' -Status "[$n/$($found.Count)] KB$($u.KB) $($u.Component) $($u.Family) $($u.Arch)" -PercentComplete ([int](100 * $n / $total))
            try { $links = @(Get-CatalogDownloadLink -UpdateId $u.UpdateId) }
            catch { Write-Log "  Could not get links for KB$($u.KB) ($($u.Title)): $($_.Exception.Message)" ERROR; $stats.MsiFailed++; continue }
            if (-not $links) { Write-Log "  No download link returned for KB$($u.KB) ($($u.Title))" WARN; continue }
            foreach ($l in $links) {
                $fileName  = Split-Path ([uri]$l).AbsolutePath -Leaf
                $base      = [IO.Path]::GetFileNameWithoutExtension($fileName)
                $patchName = $base; $sha1 = $null
                $hm = [regex]::Match($base, '^(.*)_([0-9a-fA-F]{40})$')
                if ($hm.Success) { $patchName = $hm.Groups[1].Value; $sha1 = $hm.Groups[2].Value }
                # language-specific packages (e.g. proof-de-de) - keep only selected languages
                $lm = [regex]::Match($patchName, '-([a-z]{2,3}-[a-z]{2,4})$', 'IgnoreCase')
                if ($lm.Success -and $Languages -notcontains $lm.Groups[1].Value.ToLower()) { continue }
                $files.Add([pscustomobject]@{ Update = $u; Url = $l; FileName = $fileName; PatchName = $patchName.ToLower(); Sha1 = $sha1 })
            }
            Start-Sleep -Milliseconds 120
        }
        Write-Progress -Id 1 -Activity 'Resolving download links' -Completed

        if ($Mode -eq 'Latest') {
            $before = $files.Count
            $latest = @($files | Group-Object { '{0}|{1}|{2}' -f $_.Update.Family, $_.Update.Arch, $_.PatchName } | ForEach-Object {
                $_.Group | Sort-Object -Property @{ Expression = { $_.Update.Date } }, @{ Expression = { [int64]('0' + $_.Update.KB) } } -Descending | Select-Object -First 1
            })
            $files = New-Object System.Collections.Generic.List[object]
            foreach ($f in $latest) { $files.Add($f) }
            Write-Log ("Latest-per-component mode: {0} file(s) reduced to {1}." -f $before, $files.Count) OK
        }

        $estimate = 0; foreach ($f in $files) { $estimate += $f.Update.SizeBytes }
        Write-Log ("{0} MSI patch file(s) to process, approx. {1} download." -f $files.Count, (Format-Size $estimate)) STEP
        if ($files.Count -and -not $Select) {
            if (-not (Read-YesNo '  Start downloading the Office MSI patches?' $true)) { Write-Log 'Office MSI downloads skipped by user.' WARN; $files = New-Object System.Collections.Generic.List[object] }
        }

        # ------------------------------------------------ download loop
        $n = 0; $total = [math]::Max(1, $files.Count)
        foreach ($f in $files) {
            $n++
            $u = $f.Update
            $srcKey = "$($u.UpdateId)|$($f.FileName)"
            $kbTag  = if ($u.KB) { "KB$($u.KB)" } else { $u.UpdateId.Substring(0, 8) }
            $label  = "$kbTag $($f.PatchName) (Office $($u.Family) $($u.Arch))"
            Write-Progress -Id 1 -Activity 'Downloading MSI patches' -Status "[$n/$($files.Count)] $label" -PercentComplete ([int](100 * ($n - 1) / $total))

            if ($Script:DoneSources.ContainsKey($srcKey)) { $stats.MsiSkipped++; continue }

            $relDir = "MSI\Office$($u.Family)\$($u.Arch)\$($kbTag)_$($f.PatchName)"
            $dir    = Join-Path $DownloadRoot $relDir
            $pkg    = Join-Path $dir $f.FileName
            try {
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Save-VerifiedFile -Url $f.Url -Path $pkg -Sha1 $f.Sha1
                $msps = @(Expand-UpdatePackage -Package $pkg -Destination $dir)
                if (-not $msps) { throw 'No .msp found inside the downloaded package.' }

                $pkgSig = $null
                if ($pkg -notlike '*.msp') { $pkgSig = Test-MicrosoftSignature $pkg }

                foreach ($msp in $msps) {
                    $trust = Get-PatchTrust -MspPath $msp.FullName -PackageSig $pkgSig -CatalogSha1 $f.Sha1
                    $mspSha256 = (Get-FileHash -LiteralPath $msp.FullName -Algorithm SHA256).Hash
                    $meta = Get-MspMetadata $msp.FullName
                    $entry = [pscustomobject]@{
                        UpdateId            = $u.UpdateId
                        KB                  = $(if ($u.KB) { $u.KB } else { $meta.KB })
                        Title               = $u.Title
                        Family              = $u.Family
                        Arch                = $u.Arch
                        Component           = $u.Component
                        Classification      = $u.Classification
                        Date                = $u.Date.ToString('yyyy-MM-dd')
                        SourceFile          = $f.FileName
                        FileName            = $msp.Name
                        PatchName           = [IO.Path]::GetFileNameWithoutExtension($msp.Name).ToLower()
                        RelativePath        = (Join-Path $relDir $msp.Name)
                        SizeBytes           = $msp.Length
                        CabSha1             = $f.Sha1
                        MspSha256           = $mspSha256
                        Trust               = $trust
                        PatchCode           = $meta.PatchCode
                        TargetProductCodes  = @($meta.TargetProductCodes)
                        ObsoletedPatchCodes = @($meta.ObsoletedPatchCodes)
                        SourceUrl           = $f.Url
                    }
                    $Script:MsiEntries["$srcKey|$($msp.Name)"] = $entry
                }
                $Script:DoneSources[$srcKey] = $true
                if (-not $KeepCab -and $pkg -notlike '*.msp') { Remove-Item -LiteralPath $pkg -Force -ErrorAction SilentlyContinue }
                $stats.MsiNew++
                Write-Log "  [$n/$($files.Count)] OK  $label" OK
                if ($stats.MsiNew % 10 -eq 0) { Save-Manifest }
            }
            catch {
                $stats.MsiFailed++
                Write-Log "  [$n/$($files.Count)] FAILED $label : $($_.Exception.Message)" ERROR
            }
        }
        Write-Progress -Id 1 -Activity 'Downloading MSI patches' -Completed
        Save-Manifest
    }

    # ================================================================ Windows phase
    if ($osSel.Count) {
        Write-Log 'Searching the Microsoft Update Catalog for Windows updates (month by month)...' STEP
        $osFound = @{}   # UpdateId|Arch -> row
        $seen    = @{}   # Family|Arch|Kind|Tag|KB -> dedupe title variants (e.g. 22H2 and 23H2 entries of one KB)
        $famIds  = @($osSel | Select-Object -ExpandProperty Family -Unique)
        foreach ($famId in $famIds) {
            $fam    = @($Script:OsFamilies | Where-Object { $_.Family -eq $famId })[0]
            $arches = @($osSel | Where-Object { $_.Family -eq $famId } | Select-Object -ExpandProperty Arch)
            $since  = [datetime]::ParseExact($fam.Since + '-01', 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $from   = if ($OsMode -eq 'All' -and $StartDate -gt $since) { $StartDate } else { $since }
            $months = @(Get-MonthList -From $from -To $OsEndDate)
            $terms  = if ($OsMode -eq 'All') { @($fam.Terms) } else { @($fam.Terms[0]) }   # newest updates are listed under the first term
            Write-Log ("  {0} [{1}] - {2}" -f $fam.Name, ($arches -join ', '), $(if ($OsMode -eq 'All') { "$($months.Count) month(s)" } else { 'newest first, stops when found' }))

            $scanned = 0
            foreach ($mon in $months) {
                $scanned++
                $mTag = $mon.ToString('yyyy-MM')
                $queries = @()
                foreach ($t in $terms) {
                    $queries += "$mTag Cumulative Update $t"
                    if ($fam.Ssu) { $queries += "$mTag Servicing Stack Update $t" }
                }
                foreach ($query in $queries) {
                    $pct = [int](100 * $scanned / [math]::Max(1, $months.Count))
                    Write-Progress -Id 1 -Activity "Searching catalog: $($fam.Name)" -Status $query -PercentComplete $pct
                    try { $rows = @(Search-Catalog -Query $query) }
                    catch { Write-Log "  Search failed for '$query': $($_.Exception.Message)" ERROR; continue }
                    $kept = Add-OsCatalogRow -Rows $rows -Fam $fam -Arches $arches -Found $osFound -Seen $seen
                    if ($rows.Count) { Write-Log ('    {0,-44} {1,3} result(s), {2,3} usable' -f $query, $rows.Count, $kept) }
                }
                if ($OsMode -eq 'Latest') {
                    if (Test-OsScanComplete -Fam $fam -Arches $arches -Found $osFound -Scanned $scanned) { break }
                    if ($scanned -ge 36) { Write-Log "  Scanned 36 months back without finding everything for $($fam.Name)." WARN; break }
                }
            }

            # Windows 10 22H2: also fetch the last public (non-ESU) update month
            if ($OsMode -eq 'Latest' -and $famId -eq 'W10_22H2') {
                $havePublic = @($osFound.Values | Where-Object { $_.Family -eq 'W10_22H2' -and $_.Kind -eq 'LCU' -and $_.SortDate -le $Script:Win10PublicEnd })
                if (-not $havePublic) {
                    $query = '{0:yyyy-MM} Cumulative Update 22H2' -f $Script:Win10PublicEnd
                    try {
                        $rows = @(Search-Catalog -Query $query)
                        $kept = Add-OsCatalogRow -Rows $rows -Fam $fam -Arches $arches -Found $osFound -Seen $seen
                        Write-Log ('    {0,-44} {1,3} result(s), {2,3} usable (last public update)' -f $query, $rows.Count, $kept)
                    }
                    catch { Write-Log "  Search failed for '$query': $($_.Exception.Message)" ERROR }
                }
            }

            foreach ($arch in $arches) {
                if (-not @($osFound.Values | Where-Object { $_.Family -eq $famId -and $_.Arch -eq $arch -and $_.Kind -eq 'LCU' })) {
                    Write-Log "  No cumulative update found for $($fam.Name) $arch. The catalog may be busy - re-run later (finished items are kept)." WARN
                }
            }
        }
        Write-Progress -Id 1 -Activity 'Searching catalog' -Completed

        $osList = @($osFound.Values)
        if ($OsMode -eq 'Latest') {
            $keep = @{}
            foreach ($g in ($osList | Group-Object { '{0}|{1}|{2}|{3}' -f $_.Family, $_.Arch, $_.Kind, $_.DotNetTag })) {
                $sorted = @($g.Group | Sort-Object -Property SortDate, Date)
                $keep[$sorted[-1].UpdateId] = $sorted[-1]
                if ($g.Group[0].Family -eq 'W10_22H2' -and $g.Group[0].Kind -ne 'SSU') {
                    # also keep the last public (non-ESU) update for PCs without an ESU licence
                    $public = @($sorted | Where-Object { $_.SortDate -le $Script:Win10PublicEnd })
                    if ($public) { $keep[$public[-1].UpdateId] = $public[-1] }
                }
            }
            $osList = @($keep.Values)
        }
        $osList = @($osList | Sort-Object -Property Family, Arch, Kind, SortDate)
        foreach ($u in $osList) { Write-Log ("  -> {0,-8} {1,-6} {2,-6} KB{3,-8} {4:yyyy-MM}  {5}" -f $u.Family, $u.Arch, $u.Kind, $u.KB, $u.SortDate, $u.Title) }

        $osEstimate = 0; foreach ($u in $osList) { $osEstimate += $u.SizeBytes }
        Write-Log ("{0} Windows update(s) selected, approx. {1} download." -f $osList.Count, (Format-Size $osEstimate)) STEP
        if ($osList.Count -and -not $Select) {
            if (-not (Read-YesNo '  Start downloading the Windows updates?' $true)) { Write-Log 'Windows downloads skipped by user.' WARN; $osList = @() }
        }

        $n = 0; $total = [math]::Max(1, $osList.Count)
        foreach ($u in $osList) {
            $n++
            $kbTag = if ($u.KB) { "KB$($u.KB)" } else { $u.UpdateId.Substring(0, 8) }
            $label = "$($u.Kind) $kbTag $($u.Family) $($u.Arch)"
            Write-Progress -Id 1 -Activity 'Downloading Windows updates' -Status "[$n/$($osList.Count)] $label" -PercentComplete ([int](100 * ($n - 1) / $total))
            if ($Script:DoneOs.ContainsKey($u.UpdateId)) { $stats.OsSkipped++; Write-Log "  [$n/$($osList.Count)] already downloaded: $label"; continue }

            $suffix = if ($u.Kind -eq 'DotNet') { "_$($u.DotNetTag)" } else { '' }
            $relDir = "OS\$($u.Family)\$($u.Arch)\$($u.Kind)$($suffix)_$kbTag"
            $dir    = Join-Path $DownloadRoot $relDir
            try {
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $links = @(Get-CatalogDownloadLink -UpdateId $u.UpdateId)
                if (-not $links) { throw 'The catalog returned no download link.' }
                if ($links.Count -gt 1) { Write-Log "  $label consists of $($links.Count) files (e.g. checkpoint + update) - all are kept together." }

                $fileEntries = @()
                foreach ($l in $links) {
                    $fileName = Split-Path ([uri]$l).AbsolutePath -Leaf
                    $sha1 = $null
                    $hm = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($fileName), '_([0-9a-fA-F]{40})$')
                    if ($hm.Success) { $sha1 = $hm.Groups[1].Value.ToUpper() }
                    $dest = Join-Path $dir $fileName

                    if ($sha1 -and -not (Test-Path -LiteralPath $dest) -and $Script:Sha1Cache.ContainsKey($sha1) -and (Test-Path -LiteralPath $Script:Sha1Cache[$sha1])) {
                        Write-Log "  Re-using already downloaded $fileName (no second download)"
                        Copy-Item -LiteralPath $Script:Sha1Cache[$sha1] -Destination $dest -Force
                    }
                    Save-LargeFile -Url $l -Path $dest -Sha1 $sha1 -Label "$label - $fileName"

                    $sig = Test-MicrosoftSignature $dest
                    $trust = 'Signature'
                    if (-not $sig.Ok) {
                        if ($sig.Status -eq 'HashMismatch') { throw "$fileName signature HashMismatch - corrupt or tampered." }
                        if (-not $sha1) { throw "$fileName is not Microsoft-signed ($($sig.Status)) and has no catalog hash." }
                        $trust = 'CatalogHash'
                        Write-Log "  $fileName has no valid embedded signature ($($sig.Status)); trusted via catalog SHA1." WARN
                    }
                    $fi = Get-Item -LiteralPath $dest
                    if ($sha1) { $Script:Sha1Cache[$sha1] = $dest }
                    $fileEntries += [pscustomobject]@{
                        FileName = $fileName; RelativePath = (Join-Path $relDir $fileName); Sha1 = $sha1
                        Sha256 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash; Trust = $trust; SizeBytes = $fi.Length
                    }
                }

                # Primary package = the one named after this KB (others are checkpoint prerequisites)
                $primary = @($fileEntries | Where-Object { $u.KB -and $_.FileName -match "kb$($u.KB)" })
                if (-not $primary) { $primary = @($fileEntries | Sort-Object SizeBytes -Descending) }
                $primary = $primary[0]

                $targetBuild = $null
                if ($u.Kind -eq 'LCU' -and $primary.FileName -like '*.msu') {
                    Write-Log "  Reading target OS build from $($primary.FileName) (can take a minute)..."
                    $targetBuild = Get-MsuTargetBuild (Join-Path $DownloadRoot $primary.RelativePath)
                    if ($targetBuild) { Write-Log "  Installs OS build $targetBuild" } else { Write-Log '  Build number not readable from this package format - Script 2 will use KB/date checks.' }
                }

                $sizeSum = 0; foreach ($fe in $fileEntries) { $sizeSum += $fe.SizeBytes }
                $Script:OsEntries[$u.UpdateId] = [pscustomobject]@{
                    UpdateId    = $u.UpdateId
                    KB          = $u.KB
                    Title       = $u.Title
                    Family      = $u.Family
                    Arch        = $u.Arch
                    Kind        = $u.Kind
                    DotNetTag   = $u.DotNetTag
                    Date        = $u.SortDate.ToString('yyyy-MM-dd')
                    TargetBuild = $targetBuild
                    RelativeDir = $relDir
                    PrimaryFile = $primary.FileName
                    Files       = @($fileEntries)
                    SizeBytes   = $sizeSum
                }
                $Script:DoneOs[$u.UpdateId] = $true
                $stats.OsNew++
                Write-Log "  [$n/$($osList.Count)] OK  $label ($(Format-Size $sizeSum))" OK
                Save-Manifest
            }
            catch {
                $stats.OsFailed++
                Write-Log "  [$n/$($osList.Count)] FAILED $label : $($_.Exception.Message)" ERROR
            }
        }
        Write-Progress -Id 1 -Activity 'Downloading Windows updates' -Completed
    }

    # ================================================================ C2R phase
    if ($c2rSel.Count) {
        Write-Log 'Preparing Click-to-Run downloads (Office Deployment Tool)...' STEP
        $c2rRoot = Join-Path $DownloadRoot 'C2R'
        New-Item -ItemType Directory -Path $c2rRoot -Force | Out-Null
        $setup = Join-Path $c2rRoot 'setup.exe'

        $needOdt = $true
        if (Test-Path -LiteralPath $setup) { if ((Test-MicrosoftSignature $setup).Ok) { $needOdt = $false } }
        if ($needOdt) {
            Write-Log "Downloading Office Deployment Tool from $Script:OdtUrl"
            Save-VerifiedFile -Url $Script:OdtUrl -Path $setup -Sha1 $null
        }
        $sig = Test-MicrosoftSignature $setup
        if (-not $sig.Ok) { throw "ODT setup.exe signature is not valid ($($sig.Status)). Aborting C2R downloads." }
        Write-Log "ODT ready: $setup (signed by $($sig.Subject))" OK

        $pinned = @{}
        $odtLogDir = Join-Path $LogDir 'ODT'
        New-Item -ItemType Directory -Path $odtLogDir -Force | Out-Null

        foreach ($item in $c2rSel) {
            if (-not $pinned.ContainsKey($item.Channel)) {
                $v = ''
                if (-not $Select) {
                    Write-Host ''
                    Write-Host "  $($item.Name): C2R builds are cumulative - the latest build contains every fix from 2020-2024 and later."
                    do { $v = (Read-Host '  Press Enter for the LATEST build, or type a specific build (e.g. 16.0.10417.20007)').Trim() }
                    until ($v -eq '' -or $v -match '^\d+\.\d+\.\d+\.\d+$')
                }
                $pinned[$item.Channel] = $v
            }
            $version  = $pinned[$item.Channel]
            $bits     = if ($item.Arch -eq 'x64') { '64' } else { '32' }
            $relPath  = "C2R\$($item.Channel)\$($item.Arch)"
            $target   = Join-Path $DownloadRoot $relPath
            New-Item -ItemType Directory -Path $target -Force | Out-Null

            $verAttr  = if ($version) { " Version=`"$version`"" } else { '' }
            $langXml  = ($Languages | ForEach-Object { "      <Language ID=`"$_`" />" }) -join "`r`n"
            $xml = @"
<Configuration>
  <Add SourcePath="$target" OfficeClientEdition="$bits" Channel="$($item.Channel)"$verAttr>
    <Product ID="$($item.ProductId)">
$langXml
    </Product>
  </Add>
  <Logging Level="Standard" Path="$odtLogDir" />
</Configuration>
"@
            $xmlPath = Join-Path $c2rRoot ("download_{0}_{1}.xml" -f $item.Channel, $item.Arch)
            Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8

            Write-Log ("Downloading {0} {1}-bit build {2} (several GB, please wait)..." -f $item.Channel, $bits, $(if ($version) { $version } else { '(latest)' })) STEP
            try {
                $proc = Start-Process -FilePath $setup -ArgumentList "/download `"$xmlPath`"" -WorkingDirectory $c2rRoot -PassThru -WindowStyle Hidden
                $null = $proc.Handle
                $started = Get-Date
                while (-not $proc.HasExited) {
                    $sum = (Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    Write-Progress -Id 2 -Activity "ODT download: $($item.Channel) $bits-bit" -Status ('{0} downloaded - elapsed {1:hh\:mm\:ss}' -f (Format-Size ([double]$sum)), ((Get-Date) - $started))
                    Start-Sleep -Seconds 5
                }
                $proc.WaitForExit()
                Write-Progress -Id 2 -Activity "ODT download: $($item.Channel) $bits-bit" -Completed

                $dataDir = Join-Path $target 'Office\Data'
                $verDir = $null
                if (Test-Path -LiteralPath $dataDir) {
                    $verDir = Get-ChildItem -LiteralPath $dataDir -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
                }
                if ($proc.ExitCode -ne 0 -or -not $verDir) {
                    throw "ODT exit code $($proc.ExitCode); no build folder found. See ODT logs in $odtLogDir"
                }
                $Script:C2REntries["$($item.Channel)|$($item.Arch)"] = [pscustomobject]@{
                    Channel = $item.Channel; Arch = $item.Arch; Version = $verDir.Name; ProductId = $item.ProductId
                    Languages = @($Languages); RelativePath = $relPath; Downloaded = (Get-Date).ToString('yyyy-MM-dd')
                }
                $stats.C2ROk++
                Write-Log ("  OK  {0} {1}-bit build {2}" -f $item.Channel, $bits, $verDir.Name) OK
                Save-Manifest
            }
            catch {
                $stats.C2RFailed++
                Write-Log "  FAILED $($item.Channel) $bits-bit : $($_.Exception.Message)" ERROR
            }
        }
    }

    # ================================================================ summary
    $totalSize = (Get-ChildItem -LiteralPath $DownloadRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    Write-Host ''
    Write-Log '===================== SUMMARY =====================' STEP
    if ($msiSel.Count) { Write-Log ("MSI patches : {0} downloaded, {1} already present, {2} failed" -f $stats.MsiNew, $stats.MsiSkipped, $stats.MsiFailed) }
    if ($c2rSel.Count) { Write-Log ("C2R builds  : {0} downloaded, {1} failed" -f $stats.C2ROk, $stats.C2RFailed) }
    if ($osSel.Count)  { Write-Log ("Windows     : {0} downloaded, {1} already present, {2} failed" -f $stats.OsNew, $stats.OsSkipped, $stats.OsFailed) }
    Write-Log ("Folder size : {0}  ({1})" -f (Format-Size ([double]$totalSize)), $DownloadRoot)
    Write-Log "Manifest    : $(Join-Path $DownloadRoot 'manifest.json')"
    Write-Host ''
    Write-Host '  NEXT: copy the WHOLE folder (including manifest.json) to your share or the target PC,' -ForegroundColor Green
    Write-Host '        e.g. robocopy C:\OfficePatches \\fileserver\Patches\OfficePatches /E /Z' -ForegroundColor Green
    Write-Host '        then run 2-Install-OfficePatches.ps1 on the target machine as Administrator.' -ForegroundColor Green
    Write-Host ''
    if ($stats.MsiFailed -or $stats.C2RFailed -or $stats.OsFailed) {
        $exitCode = 1
        Write-Log 'Some items failed - simply re-run the script; finished items are skipped.' WARN
    }
}
catch {
    $exitCode = 1
    Write-Log "FATAL: $($_.Exception.Message)" ERROR
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace ERROR }
}
finally {
    Write-Progress -Id 1 -Activity 'Done' -Completed
    Write-Progress -Id 2 -Activity 'Done' -Completed
}
exit $exitCode
#endregion
