#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 1 of 2 - Download Microsoft Office updates for offline patching.

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

function Search-Catalog {
    param([string]$Query)
    $searchUri = "$Script:CatalogBase/Search.aspx?q=" + [uri]::EscapeDataString($Query)
    $found = New-Object System.Collections.Generic.List[object]

    $resp = Invoke-WithRetry -Activity "Catalog search '$Query'" -ScriptBlock { Invoke-Web -Uri $searchUri }
    $page = 1
    while ($true) {
        $html = [string]$resp.Content
        $rows = ConvertFrom-CatalogResultHtml $html
        if ($rows.Count -eq 0 -and $html -match '8DDD00|errorPageDisplayedError') {
            throw "Catalog returned an error page for '$Query'."
        }
        foreach ($r in $rows) { $found.Add($r) }

        $cnt = [regex]::Match($html, 'of\s+(\d+)\s*\(page\s+(\d+)\s+of\s+(\d+)\)')
        if ($page -eq 1 -and $cnt.Success -and [int]$cnt.Groups[1].Value -ge 1000) {
            Write-Log "  '$Query' hit the catalog's 1000-result cap - some older items may be missing." WARN
        }
        if ($html -notmatch 'id="ctl00_catalogBody_nextPageLinkText"') { break }
        if ($cnt.Success -and [int]$cnt.Groups[2].Value -ge [int]$cnt.Groups[3].Value) { break }
        if ($page -ge 45) { break }

        $pageBody = @{
            '__EVENTTARGET'        = 'ctl00$catalogBody$nextPageLinkText'
            '__EVENTARGUMENT'      = Get-HiddenField $html '__EVENTARGUMENT'
            '__VIEWSTATE'          = Get-HiddenField $html '__VIEWSTATE'
            '__VIEWSTATEGENERATOR' = Get-HiddenField $html '__VIEWSTATEGENERATOR'
            '__EVENTVALIDATION'    = Get-HiddenField $html '__EVENTVALIDATION'
        }
        $page++
        Start-Sleep -Milliseconds 300
        $resp = Invoke-WithRetry -Activity "Catalog search '$Query' page $page" -ScriptBlock { Invoke-Web -Uri $searchUri -Method Post -Body $pageBody }
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

#region ------------------------------------------------------------------ manifest
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
        Write-Log ("Existing manifest loaded: {0} MSI patch file(s), {1} C2R build(s) - already-downloaded items will be skipped." -f $Script:MsiEntries.Count, $Script:C2REntries.Count)
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

    Write-Host ''
    Write-Host '  #   Product                                              Arch    Type  Lifecycle' -ForegroundColor White
    Write-Host '  --- ---------------------------------------------------- ------  ----  ------------'
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $archLabel = if ($it.Arch -eq 'x64') { '64-bit' } else { '32-bit' }
        $line = '  {0,3} {1,-52} {2,-6}  {3,-4}  {4}' -f ($i + 1), $it.Name, $archLabel, $it.Type, $it.Note
        if ($it.Type -eq 'MSI') { Write-Host $line } else { Write-Host $line -ForegroundColor DarkCyan }
    }
    Write-Host ''
    Write-Host '  Tip: not sure which you have? On a target PC open Word > File > Account > About.'
    Write-Host '       "Click-to-Run" in that window = C2R. Otherwise it is MSI. Bitness is shown there too.'
    Write-Host ''

    if ($Select) { $picked = @($Select | Where-Object { $_ -ge 1 -and $_ -le $items.Count } | Sort-Object -Unique) }
    else { $picked = Read-MultiSelection -Prompt 'Select products to download (e.g. 1,2,8  or A = all, Q = quit)' -Max $items.Count }
    if ($picked -contains -1 -or -not $picked) { Write-Log 'Nothing selected - exiting.' WARN; exit 0 }
    $selected = @($picked | ForEach-Object { $items[$_ - 1] })
    foreach ($s in $selected) { Write-Log ("Selected: {0} [{1}] {2}" -f $s.Name, $s.Arch, $s.Type) }

    $msiSel = @($selected | Where-Object { $_.Type -eq 'MSI' })
    $c2rSel = @($selected | Where-Object { $_.Type -eq 'C2R' })

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

    $stats = @{ MsiNew = 0; MsiSkipped = 0; MsiFailed = 0; C2ROk = 0; C2RFailed = 0 }

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
            if (-not (Read-YesNo '  Start downloading?' $true)) { Write-Log 'Cancelled by user.' WARN; exit 0 }
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

                foreach ($msp in $msps) {
                    $sig = Test-MicrosoftSignature $msp.FullName
                    if (-not $sig.Ok) { throw "Signature check failed for $($msp.Name): $($sig.Status) $($sig.Subject)" }
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
    Write-Log ("Folder size : {0}  ({1})" -f (Format-Size ([double]$totalSize)), $DownloadRoot)
    Write-Log "Manifest    : $(Join-Path $DownloadRoot 'manifest.json')"
    Write-Host ''
    Write-Host '  NEXT: copy the WHOLE folder (including manifest.json) to your share or the target PC,' -ForegroundColor Green
    Write-Host '        e.g. robocopy C:\OfficePatches \\fileserver\Patches\OfficePatches /E /Z' -ForegroundColor Green
    Write-Host '        then run 2-Install-OfficePatches.ps1 on the target machine as Administrator.' -ForegroundColor Green
    Write-Host ''
    if ($stats.MsiFailed -or $stats.C2RFailed) {
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
