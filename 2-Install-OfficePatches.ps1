#Requires -Version 5.1
<#
.SYNOPSIS
    STEP 2 of 2 - Detect installed Office and install ONLY the patches it needs,
    from a local folder or a password-protected \\server\share.

.DESCRIPTION
    Run on the target machine (Windows 10 / Server 2019, hardened, no internet) as Administrator.

      1. Pre-flight checks (elevation, 64-bit host, language mode, pending reboot, MSI policies).
      2. Detects installed Office:
           - MSI Office 2010 / 2013 / 2016 (incl. Visio/Project) from the registry
             (Win32_Product is deliberately NOT used - it is slow and can trigger repairs).
           - Click-to-Run Office 2019 / LTSC 2021 / LTSC 2024 / Microsoft 365 Apps
             (version, channel, bitness, language).
      3. Asks where the patches are: local folder or UNC share. For a share it tries the current
         identity first; if access is denied it auto-detects the domain and prompts for
         credentials (DOMAIN\user pre-filled), with retry and clear error messages.
      4. Reads manifest.json written by Script 1 (falls back to scanning the folder) and works out
         which patches apply: right Office version + bitness + target ProductCodes actually
         installed, not already installed, not older than what is installed.
      5. Shows the plan; you install everything, pick items, or just export a report.
      6. Copies each needed file to a local staging folder first (the Windows Installer and
         Click-to-Run services run as SYSTEM and cannot use your share credentials), verifies
         the Microsoft signature, installs with progress, and logs everything.

    Logs + CSV report: C:\ProgramData\OfficePatching\Logs

.PARAMETER SourcePath
    Folder that contains manifest.json / MSI / C2R (local path or \\server\share\folder).
    If omitted you are asked.

.PARAMETER Mode
    Latest = newest applicable patch per Office component only (default, recommended; Office MSI
             patches are cumulative per component).
    All    = every applicable patch, oldest first.

.PARAMETER Unattended
    No prompts: installs everything needed. Combine with -SourcePath, -Credential, -ForceCloseApps.

.PARAMETER DryRun
    Detect + plan + report only. Nothing is installed.

.EXAMPLE
    .\2-Install-OfficePatches.ps1

.EXAMPLE
    .\2-Install-OfficePatches.ps1 -SourcePath \\fs01\Patches\OfficePatches -DryRun

.EXAMPLE
    $c = Get-Credential CONTOSO\svc_patch
    .\2-Install-OfficePatches.ps1 -SourcePath \\fs01\Patches\OfficePatches -Credential $c -Unattended -ForceCloseApps

.NOTES
    Exit codes: 0 = success / nothing to do, 3010 = success but reboot required, 1 = one or more failures.
#>
[CmdletBinding()]
param(
    [string]       $SourcePath,
    [ValidateSet('Latest', 'All')]
    [string]       $Mode,
    [pscredential] $Credential,
    [string]       $StagePath = (Join-Path $env:ProgramData 'OfficePatching\Stage'),
    [string]       $LogPath   = (Join-Path $env:ProgramData 'OfficePatching\Logs'),
    [switch]       $Unattended,
    [switch]       $DryRun,
    [switch]       $ForceCloseApps,
    [switch]       $SkipMsi,
    [switch]       $SkipC2R,
    [switch]       $SkipSignatureCheck,
    [switch]       $KeepStage,
    [ValidateRange(10, 600)]
    [int]          $C2RTimeoutMinutes = 120,
    [ValidateRange(0, 60)]
    [int]          $MsiBusyRetries = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

#region ------------------------------------------------------------------ constants / state
$Script:LogFile        = $null
$Script:MappedDrive    = $null
$Script:RebootRequired = $false
$Script:KeepStageForce = $false
$Script:Results        = @()
$Script:FullLanguage   = ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage')

$Script:UninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$Script:C2RConfigKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$Script:C2RPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'

# MSI products that Click-to-Run installs for integration - they are NOT MSI Office.
$Script:C2RHelperSkus = @('007E', '008C', '008F', '00DD')

$Script:C2RChannelMap = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'MonthlyEnterprise'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'SemiAnnual'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'SemiAnnualPreview'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'CurrentPreview'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'BetaChannel'
    'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'PerpetualVL2019'
    '5030841d-c919-4594-8d2d-84ae4f96e58e' = 'PerpetualVL2021'
    '7983bac0-e531-40cf-be00-fd24fe66619c' = 'PerpetualVL2024'
}
# Policy "updatebranch" names -> ODT channel names
$Script:PolicyBranchMap = @{
    'Current' = 'Current'; 'FirstReleaseCurrent' = 'CurrentPreview'; 'MonthlyEnterprise' = 'MonthlyEnterprise'
    'Deferred' = 'SemiAnnual'; 'FirstReleaseDeferred' = 'SemiAnnualPreview'; 'InsiderFast' = 'BetaChannel'
}

$Script:OfficeProcesses = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'MSACCESS', 'MSPUB', 'ONENOTE', 'ONENOTEM',
    'VISIO', 'WINPROJ', 'LYNC', 'INFOPATH', 'GROOVE', 'MSOSYNC', 'SPDESIGN', 'CLVIEW', 'GRAPH', 'MSOUC', 'UcMapi', 'lynchtmlconv')
#endregion

#region ------------------------------------------------------------------ UI / logging helpers
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
    if ($Unattended) { return $Default }
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        if ($a.Trim() -match '^(y|yes)$') { return $true }
        if ($a.Trim() -match '^(n|no)$')  { return $false }
    }
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Allowed, [string]$Default)
    while ($true) {
        $a = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($a) -and $Default) { return $Default.ToUpper() }
        $a = $a.Trim().ToUpper()
        if ($Allowed -contains $a) { return $a }
        Write-Host "  Please enter one of: $($Allowed -join ', ')" -ForegroundColor Yellow
    }
}

function Read-MultiSelection {
    param([string]$Prompt, [int]$Max)
    while ($true) {
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $raw = $raw.Trim()
        if ($raw -match '^(a|all)$')       { return @(1..$Max) }
        if ($raw -match '^(q|quit|exit)$') { return @(-1) }
        $sel = @(); $bad = $false
        foreach ($part in ($raw -split '[,;\s]+')) {
            if (-not $part) { continue }
            if ($part -match '^(\d+)-(\d+)$') {
                $a = [int]$Matches[1]; $b = [int]$Matches[2]
                if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
                foreach ($n in $a..$b) { if ($n -ge 1 -and $n -le $Max) { $sel += $n } else { $bad = $true } }
            }
            elseif ($part -match '^\d+$') {
                $n = [int]$part
                if ($n -ge 1 -and $n -le $Max) { $sel += $n } else { $bad = $true }
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

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Set-OrRemoveRegValue {
    param([string]$Path, [string]$Name, $Value)
    if ($null -eq $Value) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value }
}

function ConvertTo-Date {
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    try { return [datetime]::ParseExact([string]$Value, 'yyyy-MM-dd', $null) } catch { }
    try { return [datetime]$Value } catch { return [datetime]'1900-01-01' }
}

# Start a process and show an elapsed-time progress bar until it exits. CLM-safe (no .NET method calls).
function Invoke-ProcessWithProgress {
    param([string]$FilePath, [string]$Arguments, [string]$Activity)
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    $null = $p.Handle   # caches the handle so ExitCode is available afterwards
    $start = Get-Date
    $spin = @('|', '/', '-', '\'); $k = 0
    while (-not $p.HasExited) {
        Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Status ('{0} working... {1:mm\:ss} elapsed' -f $spin[$k % 4], ((Get-Date) - $start))
        $k++
        Start-Sleep -Seconds 1
    }
    Wait-Process -Id $p.Id -ErrorAction SilentlyContinue
    Write-Progress -Id 2 -Activity $Activity -Completed
    return $p.ExitCode
}
#endregion

#region ------------------------------------------------------------------ system checks
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        $ErrorActionPreference = 'Continue'
        $groups = & "$env:SystemRoot\System32\whoami.exe" /groups 2>$null
        return [bool]($groups -match 'S-1-16-12288|S-1-16-16384')   # High / System integrity
    }
}

function Get-OsDescription {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $rel = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
    return "$($cv.ProductName) $rel (build $($cv.CurrentBuild).$($cv.UBR))"
}

function Test-PendingReboot {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        if (Test-Path -LiteralPath $k) { return $true }
    }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { return $true }
    return $false
}

function Test-MsiPolicy {
    $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
    $disableMsi   = Get-RegValue $k 'DisableMSI'
    $disablePatch = Get-RegValue $k 'DisablePatch'
    if ($disableMsi -eq 2)   { Write-Log 'Policy DisableMSI=2: Windows Installer is disabled on this machine. MSI patching will fail (exit 1625).' WARN }
    if ($disablePatch -eq 1) { Write-Log 'Policy DisablePatch=1: MSI patching is blocked by Group Policy (exit 1643). Ask the GPO owner for an exception.' WARN }
}
#endregion

#region ------------------------------------------------------------------ Office detection
function ConvertTo-SquishedGuid {
    param([string]$Guid)
    $g = $Guid.Trim('{', '}').Replace('-', '').ToUpper()
    if ($g.Length -ne 32) { return $null }
    $out = ''
    for ($i = 7; $i -ge 0; $i--)   { $out += $g[$i] }
    for ($i = 11; $i -ge 8; $i--)  { $out += $g[$i] }
    for ($i = 15; $i -ge 12; $i--) { $out += $g[$i] }
    for ($i = 16; $i -lt 32; $i += 2) { $out += "$($g[$i + 1])$($g[$i])" }
    return $out
}

function Get-InstalledOfficeMsi {
    $famMap = @{ '14' = '2010'; '15' = '2013'; '16' = '2016' }
    $seen = @{}
    $list = @()
    foreach ($root in $Script:UninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $name = $k.PSChildName
            $m = [regex]::Match($name, '^\{90(1[456])0000-([0-9A-Fa-f]{4})-([0-9A-Fa-f]{4})-([01])000-[01]000000FF1CE\}$')
            if (-not $m.Success) { continue }
            $code = $name.ToUpper()
            if ($seen.ContainsKey($code)) { continue }
            $seen[$code] = $true
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $sku = $m.Groups[2].Value.ToUpper()
            $arch = 'x86'; if ($m.Groups[4].Value -eq '1') { $arch = 'x64' }
            $isHelper = ($Script:C2RHelperSkus -contains $sku) -or ([string]$p.DisplayName -match 'Click-to-Run')
            $list += [pscustomobject]@{
                ProductCode     = $code
                Family          = $famMap[$m.Groups[1].Value]
                Arch            = $arch
                Sku             = $sku
                DisplayName     = [string]$p.DisplayName
                Version         = [string]$p.DisplayVersion
                SystemComponent = ($p.SystemComponent -eq 1)
                IsC2RHelper     = $isHelper
            }
        }
    }
    return $list
}

function Get-InstalledMsiPatchState {
    $state = @{ Squished = @{}; KBs = @{} }
    $pk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Patches'
    if (Test-Path -LiteralPath $pk) {
        foreach ($k in Get-ChildItem -LiteralPath $pk -ErrorAction SilentlyContinue) { $state.Squished[$k.PSChildName.ToUpper()] = $true }
    }
    foreach ($root in $Script:UninstallRoots) {
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            if ($k.PSChildName -notmatch '0000000FF1CE\}_') { continue }   # Office MSI patch entries
            $dn = [string](Get-RegValue $k.PSPath 'DisplayName')
            $m = [regex]::Match($dn, 'KB(\d{6,8})')
            if ($m.Success) { $state.KBs[$m.Groups[1].Value] = $true }
        }
    }
    return $state
}

function Get-InstalledOfficeC2R {
    if (-not (Test-Path -LiteralPath $Script:C2RConfigKey)) { return $null }
    $c = Get-ItemProperty -LiteralPath $Script:C2RConfigKey -ErrorAction SilentlyContinue
    if (-not $c -or -not $c.VersionToReport) { return $null }

    $channel = $null; $channelSource = ''
    foreach ($pair in @(@('UpdateChannel', $c.UpdateChannel), @('CDNBaseUrl', $c.CDNBaseUrl))) {
        if (-not $pair[1]) { continue }
        $g = [regex]::Match([string]$pair[1], '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($g.Success -and $Script:C2RChannelMap.ContainsKey($g.Value.ToLower())) {
            $channel = $Script:C2RChannelMap[$g.Value.ToLower()]; $channelSource = $pair[0]; break
        }
    }
    if (-not $channel) {
        $branch = Get-RegValue $Script:C2RPolicyKey 'updatebranch'
        if ($branch -and $Script:PolicyBranchMap.ContainsKey($branch)) { $channel = $Script:PolicyBranchMap[$branch]; $channelSource = 'Policy updatebranch' }
    }
    $arch = 'x86'; if ([string]$c.Platform -match '64') { $arch = 'x64' }
    $client = $null
    $candidates = @()
    if ($c.ClientFolder)          { $candidates += ('{0}\OfficeC2RClient.exe' -f ([string]$c.ClientFolder).TrimEnd('\')) }
    if ($env:CommonProgramW6432)  { $candidates += "$env:CommonProgramW6432\microsoft shared\ClickToRun\OfficeC2RClient.exe" }
    if ($env:CommonProgramFiles)  { $candidates += "$env:CommonProgramFiles\microsoft shared\ClickToRun\OfficeC2RClient.exe" }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { $client = $candidate; break }
    }
    return [pscustomobject]@{
        Products      = [string]$c.ProductReleaseIds
        Version       = [string]$c.VersionToReport
        Arch          = $arch
        Channel       = $channel
        ChannelSource = $channelSource
        Culture       = ([string]$c.ClientCulture).ToLower()
        UpdatesEnabled = [string]$c.UpdatesEnabled
        UpdateUrl     = [string]$c.UpdateUrl
        ClientExe     = $client
    }
}
#endregion

#region ------------------------------------------------------------------ share / credentials
function Get-DomainContext {
    $ctx = [pscustomobject]@{ PartOfDomain = $false; DnsDomain = $null; NetBios = $null }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $ctx.PartOfDomain = [bool]$cs.PartOfDomain
        if ($cs.PartOfDomain) { $ctx.DnsDomain = [string]$cs.Domain }
    }
    catch {
        # WMI blocked on some hardened builds - fall back to the registry
        $d = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'Domain'
        if ($d) { $ctx.PartOfDomain = $true; $ctx.DnsDomain = [string]$d }
    }
    if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) { $ctx.NetBios = $env:USERDOMAIN }
    elseif ($ctx.DnsDomain) { $ctx.NetBios = ($ctx.DnsDomain.Split('.')[0]).ToUpper() }
    return $ctx
}

function Disconnect-ServerSession {
    param([string]$Server)
    $ErrorActionPreference = 'Continue'
    $lines = & "$env:SystemRoot\System32\net.exe" use 2>$null
    foreach ($l in $lines) {
        $m = [regex]::Match([string]$l, '(\\\\' + [regex]::Escape($Server) + '\\\S+)', 'IgnoreCase')
        if ($m.Success) {
            & "$env:SystemRoot\System32\net.exe" use $m.Groups[1].Value /delete /y 2>&1 | Out-Null
            Write-Log "  Disconnected $($m.Groups[1].Value)"
        }
    }
}

function Connect-PatchSource {
    param([string]$Path)
    $Path = $Path.Trim().Trim('"').TrimEnd('\')

    if ($Path -notmatch '^\\\\[^\\]+\\[^\\]+') {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Local folder not found: $Path" }
        Write-Log "Using local patch folder: $Path" OK
        return $Path
    }

    $parts     = $Path.TrimStart('\').Split('\')
    $server    = $parts[0]
    $shareRoot = "\\$server\$($parts[1])"
    Write-Log "Network source $Path (server: $server, share: $shareRoot)"

    if (-not $Credential) {
        Write-Log 'Testing access with the current Windows identity...'
        if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) {
            Write-Log 'Share is accessible with the current identity - no credentials needed.' OK
            return $Path
        }
        Write-Log 'Current identity cannot read the share - credentials are required.' WARN
    }

    $ctx = Get-DomainContext
    if ($ctx.PartOfDomain) { Write-Log "Domain detected: $($ctx.DnsDomain)  (NetBIOS: $($ctx.NetBios))" OK }
    else { Write-Log 'This machine is in a WORKGROUP. Use SERVER\user or DOMAIN\user for the share account.' WARN }
    $defaultUser = if ($ctx.NetBios) { "$($ctx.NetBios)\$env:USERNAME" } else { "$server\" }

    $cred = $Credential
    $disconnectTried = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not $cred) {
            if ($Unattended) { throw "No access to $shareRoot and -Unattended was used without -Credential." }
            $cred = Get-Credential -UserName $defaultUser -Message "Credentials for $shareRoot  (attempt $attempt of 3)"
            if (-not $cred) { throw 'Credential prompt was cancelled.' }
        }
        if ($cred.UserName -notmatch '[\\@]' -and $ctx.NetBios) {
            $cred = New-Object System.Management.Automation.PSCredential("$($ctx.NetBios)\$($cred.UserName)", $cred.Password)
        }
        Write-Log "Connecting to $shareRoot as $($cred.UserName)..."
        try {
            if (Get-PSDrive -Name 'OfficePatchSrc' -ErrorAction SilentlyContinue) { Remove-PSDrive -Name 'OfficePatchSrc' -Force -ErrorAction SilentlyContinue }
            New-PSDrive -Name 'OfficePatchSrc' -PSProvider FileSystem -Root $shareRoot -Credential $cred -Scope Script -ErrorAction Stop | Out-Null
            $Script:MappedDrive = 'OfficePatchSrc'
            if (-not (Test-Path -LiteralPath $Path)) { throw "Connected to $shareRoot, but folder '$Path' does not exist or is not readable by $($cred.UserName)." }
            Write-Log "Connected to $shareRoot as $($cred.UserName)." OK
            return $Path
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '1219|multiple connections') {
                Write-Log "Windows already holds a connection to $server under another account (error 1219)." WARN
                if (-not $disconnectTried -and (Read-YesNo "  Disconnect existing connections to \\$server and retry?" $true)) {
                    Disconnect-ServerSession -Server $server
                    $disconnectTried = $true
                    $attempt--
                    continue
                }
                throw "Error 1219: close other connections to $server (net use) or use the same account."
            }
            elseif ($msg -match '1326|user name or password|logon failure|unknown user') { Write-Log 'Logon failure: user name or password is incorrect.' ERROR }
            elseif ($msg -match '1909|locked out')                                       { throw "Account $($cred.UserName) is locked out." }
            elseif ($msg -match '1311|logon servers')                                    { Write-Log 'No domain controller available to validate the logon (error 1311). Try SERVER\localuser.' ERROR }
            elseif ($msg -match '\b53\b|\b67\b|network path was not found|network name cannot be found') {
                throw "Cannot reach $shareRoot. Check the server name/DNS, that TCP 445 is open through the firewall, and the share name."
            }
            elseif ($msg -match 'denied')    { Write-Log "Access denied for $($cred.UserName) on $shareRoot." ERROR }
            else                              { Write-Log "Connection failed: $msg" ERROR }
            if ($Unattended) { throw "Could not connect to $shareRoot : $msg" }
            $cred = $null
        }
    }
    throw "Could not connect to $shareRoot after 3 attempts."
}
#endregion

#region ------------------------------------------------------------------ patch set
function Get-MspMetadata {
    param([string]$Path)
    if (-not $Script:FullLanguage) { return $null }
    $meta = [ordered]@{ PatchCode = $null; TargetProductCodes = @() }
    $installer = $null; $db = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 32))
        $si = $db.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $db, @(0))
        $template = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(7))
        $revision = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(9))
        $g = [regex]::Match($revision, '\{[0-9A-Fa-f\-]{36}\}')
        if ($g.Success) { $meta.PatchCode = $g.Value.ToUpper() }
        $meta.TargetProductCodes = @([regex]::Matches($template, '\{[0-9A-Fa-f\-]{36}\}') | ForEach-Object { $_.Value.ToUpper() } | Select-Object -Unique)
    }
    catch { return $null }
    finally {
        foreach ($o in @($db, $installer)) { if ($o) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { } } }
    }
    return [pscustomobject]$meta
}

function Import-PatchSet {
    param([string]$Root)
    $entries = @()
    $manifestPath = Join-Path $Root 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        Write-Log "Reading $manifestPath"
        try {
            $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in @($m.Msi)) {
                if (-not $e -or -not $e.RelativePath) { continue }
                $entries += [pscustomobject]@{
                    Family             = [string]$e.Family
                    Arch               = ([string]$e.Arch).ToLower()
                    KB                 = [string]$e.KB
                    Title              = [string]$e.Title
                    Component          = [string]$e.Component
                    Classification     = [string]$e.Classification
                    Date               = ConvertTo-Date $e.Date
                    PatchName          = ([string]$e.PatchName).ToLower()
                    RelativePath       = [string]$e.RelativePath
                    FullPath           = (Join-Path $Root ([string]$e.RelativePath))
                    SizeBytes          = [int64]$e.SizeBytes
                    PatchCode          = [string]$e.PatchCode
                    TargetProductCodes = @($e.TargetProductCodes | Where-Object { $_ })
                }
            }
            Write-Log ("Manifest lists {0} MSI patch file(s) (generated {1}, range {2})." -f $entries.Count, $m.Generated, $m.DateRange) OK
            return $entries
        }
        catch {
            Write-Log "manifest.json could not be read ($($_.Exception.Message)) - scanning folders instead." WARN
            $entries = @()
        }
    }
    else { Write-Log 'No manifest.json found - scanning the folder for .msp files.' WARN }

    $scanRoot = Join-Path $Root 'MSI'
    if (-not (Test-Path -LiteralPath $scanRoot)) { $scanRoot = $Root }
    $files = @(Get-ChildItem -LiteralPath $scanRoot -Filter '*.msp' -File -Recurse -ErrorAction SilentlyContinue)
    if (-not $Script:FullLanguage) { Write-Log 'Constrained Language Mode: .msp metadata cannot be read - applicability will be decided by msiexec.' WARN }
    $i = 0
    foreach ($f in $files) {
        $i++
        Write-Progress -Id 1 -Activity 'Scanning patch folder' -Status $f.Name -PercentComplete ([int](100 * $i / $files.Count))
        $fam = $null; $arch = $null; $kb = ''
        $fm = [regex]::Match($f.FullName, 'Office(2010|2013|2016)\\(x86|x64)\\', 'IgnoreCase')
        if ($fm.Success) { $fam = $fm.Groups[1].Value; $arch = $fm.Groups[2].Value.ToLower() }
        $km = [regex]::Match($f.FullName, 'KB(\d{6,8})', 'IgnoreCase')
        if ($km.Success) { $kb = $km.Groups[1].Value }
        $meta = Get-MspMetadata $f.FullName
        if ((-not $fam -or -not $arch) -and $meta -and $meta.TargetProductCodes) {
            $tm = [regex]::Match($meta.TargetProductCodes[0], '^\{90(1[456])0000-[0-9A-F]{4}-[0-9A-F]{4}-([01])000')
            if ($tm.Success) {
                $fam = @{ '14' = '2010'; '15' = '2013'; '16' = '2016' }[$tm.Groups[1].Value]
                $arch = 'x86'; if ($tm.Groups[2].Value -eq '1') { $arch = 'x64' }
            }
        }
        if (-not $fam -or -not $arch) { Write-Log "  Skipping $($f.Name): cannot tell which Office version/bitness it is for (keep the MSI\Office20xx\x86|x64 folder layout)." WARN; continue }
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
        $entries += [pscustomobject]@{
            Family = $fam; Arch = $arch; KB = $kb; Title = $f.Name; Component = ''; Classification = ''
            Date = $f.LastWriteTime; PatchName = $f.BaseName.ToLower(); RelativePath = $rel; FullPath = $f.FullName
            SizeBytes = $f.Length
            PatchCode = $(if ($meta) { $meta.PatchCode } else { '' })
            TargetProductCodes = $(if ($meta) { @($meta.TargetProductCodes) } else { @() })
        }
    }
    Write-Progress -Id 1 -Activity 'Scanning patch folder' -Completed
    Write-Log ("Folder scan found {0} usable .msp file(s)." -f $entries.Count)
    return $entries
}

function Get-C2RSource {
    param([string]$Root)
    $out = @()
    $c2rRoot = Join-Path $Root 'C2R'
    if (-not (Test-Path -LiteralPath $c2rRoot)) { return $out }
    foreach ($ch in Get-ChildItem -LiteralPath $c2rRoot -Directory -ErrorAction SilentlyContinue) {
        foreach ($ar in Get-ChildItem -LiteralPath $ch.FullName -Directory -ErrorAction SilentlyContinue) {
            $data = Join-Path $ar.FullName 'Office\Data'
            if (-not (Test-Path -LiteralPath $data)) { continue }
            $vers = @(Get-ChildItem -LiteralPath $data -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
            if (-not $vers) { continue }
            $langs = @(Get-ChildItem -LiteralPath $vers[0].FullName -File -Filter 'stream.*.dat' -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -match '^stream\.(x86|x64)\.([a-z]{2,3}-[a-z\-]+)\.dat$') { $Matches[2].ToLower() } } | Sort-Object -Unique)
            $size = (Get-ChildItem -LiteralPath $vers[0].FullName -File -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $out += [pscustomobject]@{
                Channel = $ch.Name; Arch = $ar.Name.ToLower(); Version = $vers[0].Name
                Path = $ar.FullName; DataPath = $data; VersionPath = $vers[0].FullName
                Languages = $langs; SizeBytes = [int64]$size
            }
        }
    }
    return $out
}
#endregion

#region ------------------------------------------------------------------ planning
function New-MsiPlan {
    param($Entries, $Products, $PatchState, [string]$PlanMode)

    $realProducts = @($Products | Where-Object { -not $_.IsC2RHelper })
    $installedCodes = @{}
    foreach ($p in $realProducts) { $installedCodes[$p.ProductCode] = $true }
    $families = @{}
    foreach ($p in ($realProducts | Where-Object { -not $_.SystemComponent -and $_.DisplayName })) { $families["$($p.Family)|$($p.Arch)"] = $true }

    $plan = @()
    foreach ($e in $Entries) {
        if (-not $families.ContainsKey("$($e.Family)|$($e.Arch)")) { continue }
        $status = 'Needed'; $reason = ''
        $sq = $null; if ($e.PatchCode) { $sq = ConvertTo-SquishedGuid $e.PatchCode }

        if ($sq -and $PatchState.Squished.ContainsKey($sq)) { $status = 'Installed'; $reason = 'Patch already registered' }
        elseif (-not $e.PatchCode -and $e.KB -and $PatchState.KBs.ContainsKey($e.KB)) { $status = 'Installed'; $reason = "KB$($e.KB) already in Installed Updates" }
        elseif (@($e.TargetProductCodes).Count -gt 0) {
            $hit = $false
            foreach ($t in $e.TargetProductCodes) { if ($installedCodes.ContainsKey(([string]$t).ToUpper())) { $hit = $true; break } }
            if (-not $hit) { $status = 'NotApplicable'; $reason = 'Targets no installed Office product/language' }
        }
        $plan += [pscustomobject]@{
            Type = 'MSI'; KB = $e.KB; Component = $e.Component; Family = $e.Family; Arch = $e.Arch; Date = $e.Date
            PatchName = $e.PatchName; Title = $e.Title; RelativePath = $e.RelativePath; FullPath = $e.FullPath
            SizeBytes = $e.SizeBytes; PatchCode = $e.PatchCode; Status = $status; Reason = $reason
            GroupKey = '{0}|{1}|{2}' -f $e.Family, $e.Arch, $e.PatchName
        }
    }

    # Supersedence inside each component (msp name): Office MSI patches are cumulative per component
    foreach ($grp in ($plan | Group-Object GroupKey)) {
        $sorted = @($grp.Group | Sort-Object -Property @{ Expression = { $_.Date } }, @{ Expression = { [int64]('0' + $_.KB) } })
        $newestInstalled = $sorted | Where-Object { $_.Status -eq 'Installed' } | Select-Object -Last 1
        if ($newestInstalled) {
            foreach ($p in $sorted) {
                if ($p.Status -eq 'Needed' -and $p.Date -lt $newestInstalled.Date) {
                    $p.Status = 'Superseded'; $p.Reason = "Newer KB$($newestInstalled.KB) already installed"
                }
            }
        }
        if ($PlanMode -eq 'Latest') {
            $needed = @($sorted | Where-Object { $_.Status -eq 'Needed' })
            if ($needed.Count -gt 1) {
                $keep = $needed[$needed.Count - 1]
                for ($i = 0; $i -lt $needed.Count - 1; $i++) {
                    $needed[$i].Status = 'Superseded'; $needed[$i].Reason = "Replaced by newer KB$($keep.KB) in this run"
                }
            }
        }
    }

    foreach ($p in ($plan | Where-Object { $_.Status -eq 'Needed' })) {
        if (-not (Test-Path -LiteralPath $p.FullPath)) { $p.Status = 'MissingFile'; $p.Reason = "File not found: $($p.RelativePath)" }
    }
    return @($plan | Sort-Object -Property @{ Expression = { $_.Date } }, @{ Expression = { [int64]('0' + $_.KB) } })
}

function New-C2RPlan {
    param($Installed, $Sources)
    if (-not $Installed) { return $null }
    $plan = [pscustomobject]@{ Type = 'C2R'; Status = 'NoSource'; Reason = ''; Installed = $Installed; Source = $null }

    $match = @($Sources | Where-Object { $_.Channel -eq $Installed.Channel -and $_.Arch -eq $Installed.Arch })
    if ($match) { $plan.Source = $match[0] }
    elseif ($Sources) {
        Write-Log ("No downloaded C2R build matches the installed channel '{0}' ({1})." -f $Installed.Channel, $Installed.Arch) WARN
        $sameArch = @($Sources | Where-Object { $_.Arch -eq $Installed.Arch })
        if ($sameArch -and -not $Unattended) {
            Write-Host '  Available C2R builds with matching bitness:'
            for ($i = 0; $i -lt $sameArch.Count; $i++) { Write-Host ('    [{0}] {1} {2} build {3}' -f ($i + 1), $sameArch[$i].Channel, $sameArch[$i].Arch, $sameArch[$i].Version) }
            Write-Host '  WARNING: using a different channel MOVES this PC to that channel.' -ForegroundColor Yellow
            $a = Read-Host '  Number to use, or Enter to skip Click-to-Run'
            if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $sameArch.Count) { $plan.Source = $sameArch[[int]$a - 1] }
        }
    }
    if (-not $plan.Source) {
        $plan.Reason = "No build for channel '$($Installed.Channel)' $($Installed.Arch) in the patch folder (expected C2R\$($Installed.Channel)\$($Installed.Arch))"
        return $plan
    }
    if (-not $Installed.ClientExe) { $plan.Status = 'Failed'; $plan.Reason = 'OfficeC2RClient.exe not found'; return $plan }

    if (([version]$plan.Source.Version) -gt ([version]$Installed.Version)) {
        $plan.Status = 'Needed'
        $plan.Reason = "$($Installed.Version) -> $($plan.Source.Version)"
        if ($Installed.Culture -and $plan.Source.Languages -and ($plan.Source.Languages -notcontains $Installed.Culture)) {
            Write-Log ("Installed language '{0}' is not in the downloaded build ({1}). The update may fail - re-download with that language." -f $Installed.Culture, ($plan.Source.Languages -join ',')) WARN
        }
    }
    else { $plan.Status = 'UpToDate'; $plan.Reason = "Installed $($Installed.Version) >= available $($plan.Source.Version)" }
    return $plan
}
#endregion

#region ------------------------------------------------------------------ execution
function Confirm-OfficeAppsClosed {
    while ($true) {
        $running = @(Get-Process -Name $Script:OfficeProcesses -ErrorAction SilentlyContinue)
        if (-not $running) { return $true }
        $names = ($running | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
        Write-Log "Office applications are running: $names" WARN
        if ($ForceCloseApps) {
            Write-Log 'Closing them (-ForceCloseApps)...' WARN
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            continue
        }
        if ($Unattended) { Write-Log 'Unattended run without -ForceCloseApps: patches for open files may need a reboot to finish.' WARN; return $true }
        Write-Host '  [C] Close them now (UNSAVED WORK IS LOST)   [R] I closed them - check again   [I] Ignore and continue   [A] Abort'
        switch (Read-Choice -Prompt '  Choice' -Allowed @('C', 'R', 'I', 'A') -Default 'R') {
            'C' { $running | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
            'R' { }
            'I' { return $true }
            'A' { return $false }
        }
    }
}

function Copy-FileWithRetry {
    param([string]$Source, [string]$Destination)
    for ($n = 1; $n -le 3; $n++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        }
        catch {
            if ($n -eq 3) { throw "Copy failed after 3 attempts: $($_.Exception.Message)" }
            Write-Log "  Copy attempt $n failed ($($_.Exception.Message)) - retrying in 10 s" WARN
            Start-Sleep -Seconds 10
        }
    }
}

function Copy-Folder {
    param([string]$Source, [string]$Destination, [switch]$Recurse, [string]$Activity = 'Copying files')
    $Source = $Source.TrimEnd('\'); $Destination = $Destination.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $srcFiles = @(Get-ChildItem -LiteralPath $Source -File -Recurse:$Recurse -ErrorAction Stop)
    $total = ($srcFiles | Measure-Object -Property Length -Sum).Sum
    if (-not $total) { $total = 1 }
    $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'

    if (Test-Path -LiteralPath $robo) {
        $rlog = Join-Path $LogPath ('robocopy_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $what = if ($Recurse) { '/E' } else { '*.*' }
        $argList = '"{0}" "{1}" {2} /Z /R:3 /W:10 /NP /NFL /NDL /XJ /LOG+:"{3}"' -f $Source, $Destination, $what, $rlog
        $p = Start-Process -FilePath $robo -ArgumentList $argList -PassThru -WindowStyle Hidden
        $null = $p.Handle
        while (-not $p.HasExited) {
            $done = (Get-ChildItem -LiteralPath $Destination -File -Recurse:$Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $pct = [int](100 * $done / $total); if ($pct -gt 100) { $pct = 100 }
            Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Status ('{0} of {1}' -f (Format-Size $done), (Format-Size $total)) -PercentComplete $pct
            Start-Sleep -Seconds 3
        }
        Wait-Process -Id $p.Id -ErrorAction SilentlyContinue
        Write-Progress -Id 2 -Activity $Activity -Completed
        if ($p.ExitCode -ge 8) { throw "robocopy failed (exit $($p.ExitCode)) - see $rlog" }
    }
    else {
        $srcRoot = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')
        $done = 0
        foreach ($f in $srcFiles) {
            $dst = Join-Path $Destination $f.FullName.Substring($srcRoot.Length).TrimStart('\')
            $dd = Split-Path -Path $dst -Parent
            if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
            Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Status $f.Name -PercentComplete ([int](100 * $done / $total))
            Copy-FileWithRetry -Source $f.FullName -Destination $dst
            $done += $f.Length
        }
        Write-Progress -Id 2 -Activity $Activity -Completed
    }
}

function Test-PatchSignature {
    param([string]$Path)
    if ($SkipSignatureCheck) { return }
    $sig  = Get-AuthenticodeSignature -LiteralPath $Path
    $subj = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
    $st   = [string]$sig.Status
    if ($st -eq 'Valid' -and $subj -match 'Microsoft') { Write-Log '  Signature: valid (Microsoft Corporation)'; return }
    if ($st -in @('NotSigned', 'HashMismatch', 'NotSupportedFileFormat')) { throw "Signature check FAILED ($st) - file is corrupt or has been modified." }
    if ($subj -match 'Microsoft') { Write-Log "  Signature status '$st' (chain could not be fully verified offline) - signer is Microsoft, continuing." WARN; return }
    throw "Signature check FAILED ($st, signer '$subj')."
}

function Get-MsiResultText {
    param([int]$Code)
    switch ($Code) {
        0    { return 'Success' }
        3010 { return 'Success - reboot required' }
        1641 { return 'Success - reboot initiated by installer' }
        1642 { return 'Not applicable (no target product, or already superseded)' }
        1618 { return 'Another installation is in progress' }
        1603 { return 'Fatal error during installation - see MSI log' }
        1612 { return 'Original Office install source needed (MSOCache missing) - see MSI log' }
        1619 { return 'Patch package could not be opened' }
        1625 { return 'Blocked by system policy (AppLocker / SRP / DisableMSI)' }
        1635 { return 'Patch package could not be opened (corrupt or inaccessible)' }
        1636 { return 'Patch package cannot be applied (invalid/unsupported)' }
        1638 { return 'Another version of this product is already installed' }
        1639 { return 'Invalid command line' }
        1643 { return 'Patch blocked by system policy (DisablePatch)' }
        1648 { return 'No valid patch sequence found' }
        default { return "Exit code $Code" }
    }
}

function Install-MsiPatch {
    param($Item)
    $kbTag = if ($Item.KB) { "KB$($Item.KB)" } else { 'KB?' }
    $label = "$kbTag $($Item.PatchName) (Office $($Item.Family) $($Item.Arch))"
    $res = [pscustomobject]@{ Type = 'MSI'; Item = $label; KB = $Item.KB; Status = 'Failed'; ExitCode = $null; Detail = ''; Log = '' }
    try {
        Write-Log "Staging $label" STEP
        $stageDir = Join-Path (Join-Path $StagePath 'MSI') (Split-Path -Path $Item.RelativePath -Parent)
        if (-not (Test-Path -LiteralPath $stageDir)) { New-Item -ItemType Directory -Path $stageDir -Force | Out-Null }
        $local = Join-Path $stageDir (Split-Path -Path $Item.FullPath -Leaf)
        Copy-FileWithRetry -Source $Item.FullPath -Destination $local
        Test-PatchSignature -Path $local

        $log = Join-Path $LogPath ('MSI_{0}_{1}_{2}.log' -f $kbTag, $Item.PatchName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $res.Log = $log
        $argList = '/p "{0}" /qn /norestart REBOOT=ReallySuppress /l*v "{1}"' -f $local, $log
        Write-Log "  Installing: msiexec.exe $argList"
        $busy = 0
        while ($true) {
            $code = Invoke-ProcessWithProgress -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -Arguments $argList -Activity "Installing $label"
            if ($code -eq 1618 -and $busy -lt $MsiBusyRetries) {
                $busy++
                Write-Log "  Windows Installer is busy (1618) - waiting 30 s (retry $busy/$MsiBusyRetries)" WARN
                Start-Sleep -Seconds 30
                continue
            }
            break
        }
        $res.ExitCode = $code
        $res.Detail   = Get-MsiResultText $code
        switch ($code) {
            0       { $res.Status = 'Installed' }
            3010    { $res.Status = 'Installed'; $Script:RebootRequired = $true }
            1641    { $res.Status = 'Installed'; $Script:RebootRequired = $true }
            1642    { $res.Status = 'NotApplicable' }
            default { $res.Status = 'Failed' }
        }
        $lvl = 'OK'; if ($res.Status -eq 'Failed') { $lvl = 'ERROR' } elseif ($res.Status -eq 'NotApplicable') { $lvl = 'WARN' }
        Write-Log "  Result: $($res.Status) - $($res.Detail)" $lvl
        if ($res.Status -eq 'Failed') { Write-Log "  MSI log: $log" ERROR }
    }
    catch {
        $res.Status = 'Failed'; $res.Detail = $_.Exception.Message
        Write-Log "  FAILED $label : $($_.Exception.Message)" ERROR
    }
    return $res
}

function Update-C2ROffice {
    param($Plan)
    $inst = $Plan.Installed; $src = $Plan.Source
    $res = [pscustomobject]@{ Type = 'C2R'; Item = "Click-to-Run $($src.Channel) $($inst.Arch): $($inst.Version) -> $($src.Version)"
        KB = ''; Status = 'Failed'; ExitCode = $null; Detail = ''; Log = '' }
    $backup = $null
    try {
        $stageRoot = Join-Path $StagePath ('C2R\{0}\{1}' -f $src.Channel, $src.Arch)
        $stageData = Join-Path $stageRoot 'Office\Data'
        Write-Log ("Staging Click-to-Run build {0} ({1}) to {2}" -f $src.Version, (Format-Size $src.SizeBytes), $stageRoot) STEP
        Copy-Folder -Source $src.DataPath -Destination $stageData -Activity 'Copying C2R version descriptors'
        Copy-Folder -Source $src.VersionPath -Destination (Join-Path $stageData $src.Version) -Recurse -Activity "Copying C2R build $($src.Version)"
        $vcab = if ($src.Arch -eq 'x64') { 'v64.cab' } else { 'v32.cab' }
        if (-not (Test-Path -LiteralPath (Join-Path $stageData $vcab))) { throw "$vcab is missing from the build - the download looks incomplete. Re-run Script 1." }

        $backup = @{
            UpdateUrl   = Get-RegValue $Script:C2RConfigKey 'UpdateUrl'
            PolPath     = Get-RegValue $Script:C2RPolicyKey 'updatepath'
            PolTarget   = Get-RegValue $Script:C2RPolicyKey 'updatetargetversion'
        }
        Write-Log "  Pointing Click-to-Run at the local staged build (original UpdateUrl: '$($backup.UpdateUrl)')"
        Set-ItemProperty -LiteralPath $Script:C2RConfigKey -Name 'UpdateUrl' -Value $stageRoot
        if ($null -ne $backup.PolPath)   { Write-Log '  Temporarily overriding GPO updatepath (restored afterwards)' WARN; Set-ItemProperty -LiteralPath $Script:C2RPolicyKey -Name 'updatepath' -Value $stageRoot }
        if ($null -ne $backup.PolTarget) { Write-Log '  Temporarily overriding GPO updatetargetversion (restored afterwards)' WARN; Set-ItemProperty -LiteralPath $Script:C2RPolicyKey -Name 'updatetargetversion' -Value $src.Version }

        $argStr = "/update user updatetoversion=$($src.Version) displaylevel=false forceappshutdown=true updatepromptuser=false"
        Write-Log "  Running: `"$($inst.ClientExe)`" $argStr" STEP
        Start-Process -FilePath $inst.ClientExe -ArgumentList $argStr -WindowStyle Hidden | Out-Null

        $target   = [version]$src.Version
        $start    = Get-Date
        $deadline = $start.AddMinutes($C2RTimeoutMinutes)
        $finished = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $cur = [string](Get-RegValue $Script:C2RConfigKey 'VersionToReport')
            Write-Progress -Id 2 -ParentId 1 -Activity "Click-to-Run update to $($src.Version)" -Status ('Installed now: {0}  |  elapsed {1:hh\:mm\:ss}  |  timeout {2} min' -f $cur, ((Get-Date) - $start), $C2RTimeoutMinutes)
            if ($cur -and ([version]$cur -ge $target)) { $finished = $true; break }
        }
        Write-Progress -Id 2 -Activity 'Click-to-Run update' -Completed
        if ($finished) {
            $res.Status = 'Installed'; $res.Detail = "Now at $([string](Get-RegValue $Script:C2RConfigKey 'VersionToReport'))"
            Write-Log "  Click-to-Run updated: $($res.Detail)" OK
        }
        else {
            $res.Status = 'Timeout'
            $res.Detail = "Version did not reach $($src.Version) within $C2RTimeoutMinutes min. Check $env:windir\Temp\$env:COMPUTERNAME-*.log"
            $Script:KeepStageForce = $true   # update may still be running and needs the staged files
            Write-Log "  $($res.Detail)" ERROR
        }
    }
    catch {
        $res.Status = 'Failed'; $res.Detail = $_.Exception.Message
        Write-Log "  FAILED Click-to-Run update: $($_.Exception.Message)" ERROR
    }
    finally {
        if ($backup -and -not $Script:KeepStageForce) {
            Set-OrRemoveRegValue -Path $Script:C2RConfigKey -Name 'UpdateUrl' -Value $backup.UpdateUrl
            if ($null -ne $backup.PolPath)   { Set-ItemProperty -LiteralPath $Script:C2RPolicyKey -Name 'updatepath' -Value $backup.PolPath }
            if ($null -ne $backup.PolTarget) { Set-ItemProperty -LiteralPath $Script:C2RPolicyKey -Name 'updatetargetversion' -Value $backup.PolTarget }
            Write-Log '  Original Click-to-Run update settings restored.'
        }
        elseif ($backup) {
            Write-Log "  UpdateUrl left pointing at $StagePath because the update may still be running. Restore it to '$($backup.UpdateUrl)' afterwards." WARN
        }
    }
    return $res
}
#endregion

#region ------------------------------------------------------------------ main
$Script:ExitCode = 0
try {
    foreach ($d in @($LogPath, $StagePath)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:LogFile = Join-Path $LogPath ('Install_{0}_{1}.log' -f $env:COMPUTERNAME, $stamp)

    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Cyan
    Write-Host '   Office Offline Patch Installer                 (Step 2 of 2)' -ForegroundColor Cyan
    Write-Host '=====================================================================' -ForegroundColor Cyan
    if ($DryRun) { Write-Host '   DRY RUN - nothing will be installed' -ForegroundColor Yellow }

    # ------------------------------------------------------------ 1. pre-flight
    Write-Log 'Step 1/6  Pre-flight checks' STEP
    if (-not (Test-IsAdmin)) { throw 'This script must run elevated. Right-click PowerShell > "Run as administrator".' }
    if ($env:PROCESSOR_ARCHITEW6432) { throw '32-bit PowerShell detected on 64-bit Windows. Use C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe.' }
    Write-Log "Computer   : $env:COMPUTERNAME  -  $(Get-OsDescription)"
    Write-Log "PowerShell : $($PSVersionTable.PSVersion)  -  language mode $($ExecutionContext.SessionState.LanguageMode)"
    Write-Log "Log file   : $Script:LogFile"
    if (-not $Script:FullLanguage) { Write-Log 'Constrained Language Mode detected: script works, but .msp metadata fallback is disabled. Sign/allow-list the script for full functionality.' WARN }
    if (Test-PendingReboot) { Write-Log 'A reboot is already pending on this machine. Patching continues, but reboot afterwards.' WARN; $Script:RebootRequired = $true }
    Test-MsiPolicy
    $sysDrive = Get-PSDrive -Name $StagePath.Substring(0, 1) -ErrorAction SilentlyContinue
    if ($sysDrive) { Write-Log ("Staging    : $StagePath  ({0} free)" -f (Format-Size $sysDrive.Free)) }

    # ------------------------------------------------------------ 2. detect Office
    Write-Log 'Step 2/6  Detecting installed Office' STEP
    $msiProducts = @(Get-InstalledOfficeMsi)
    $mainMsi     = @($msiProducts | Where-Object { -not $_.IsC2RHelper -and -not $_.SystemComponent -and $_.DisplayName })
    $c2r         = Get-InstalledOfficeC2R

    Write-Host ''
    if ($mainMsi) {
        Write-Host '  MSI-installed Office:' -ForegroundColor White
        foreach ($p in ($mainMsi | Sort-Object Family, DisplayName)) {
            Write-Host ('    - {0,-55} {1,-16} Office {2} {3}' -f $p.DisplayName, $p.Version, $p.Family, $p.Arch)
        }
    }
    if ($c2r) {
        Write-Host '  Click-to-Run Office:' -ForegroundColor White
        Write-Host ("    - Products : {0}" -f $c2r.Products)
        Write-Host ("    - Version  : {0}   Bitness: {1}   Language: {2}" -f $c2r.Version, $c2r.Arch, $c2r.Culture)
        $chText = if ($c2r.Channel) { "$($c2r.Channel)  (from $($c2r.ChannelSource))" } else { 'UNKNOWN' }
        Write-Host ("    - Channel  : {0}" -f $chText)
    }
    Write-Host ''
    if (-not $mainMsi -and -not $c2r) {
        Write-Log 'No Microsoft Office installation was found on this machine. Nothing to do.' WARN
        exit 0
    }
    Write-Log ("Found {0} MSI Office product(s){1}." -f $mainMsi.Count, $(if ($c2r) { " and Click-to-Run $($c2r.Version) ($($c2r.Channel))" } else { '' })) OK

    # ------------------------------------------------------------ 3. patch source
    Write-Log 'Step 3/6  Connecting to the patch source' STEP
    if (-not $SourcePath) {
        if ($Unattended) { throw '-SourcePath is required with -Unattended.' }
        Write-Host '  Where are the patches?'
        Write-Host '    [1] Network share   (e.g. \\fileserver\Patches\OfficePatches)'
        Write-Host '    [2] Local folder    (e.g. D:\OfficePatches)'
        $kind = Read-Choice -Prompt '  Choose 1 or 2' -Allowed @('1', '2') -Default '1'
        do {
            $SourcePath = (Read-Host '  Path to the folder that contains manifest.json').Trim().Trim('"')
            if ($kind -eq '1' -and $SourcePath -notmatch '^\\\\') { Write-Host '  A share path must start with \\' -ForegroundColor Yellow; $SourcePath = '' }
        } until ($SourcePath)
    }
    $root = Connect-PatchSource -Path $SourcePath
    if (-not (Test-Path -LiteralPath (Join-Path $root 'manifest.json')) -and -not (Test-Path -LiteralPath (Join-Path $root 'MSI')) -and -not (Test-Path -LiteralPath (Join-Path $root 'C2R'))) {
        Write-Log "No manifest.json, MSI or C2R folder in $root - is this the folder Script 1 created?" WARN
    }

    # ------------------------------------------------------------ 4. plan
    Write-Log 'Step 4/6  Working out which patches this machine needs' STEP
    if (-not $Mode) {
        if ($Unattended) { $Mode = 'Latest' }
        else {
            Write-Host '  Install mode:'
            Write-Host '    [1] Newest applicable patch per component  (recommended - patches are cumulative, fastest)'
            Write-Host '    [2] Every applicable patch, oldest first   (slow; for audits that check each KB)'
            $Mode = if ((Read-Choice -Prompt '  Choose 1 or 2' -Allowed @('1', '2') -Default '1') -eq '2') { 'All' } else { 'Latest' }
        }
    }
    Write-Log "Mode: $Mode"

    $msiPlan = @()
    if ($mainMsi -and -not $SkipMsi) {
        $entries    = @(Import-PatchSet -Root $root)
        $patchState = Get-InstalledMsiPatchState
        Write-Log ("Installed Office MSI patches found in registry: {0}" -f $patchState.Squished.Count)
        $msiPlan = @(New-MsiPlan -Entries $entries -Products $msiProducts -PatchState $patchState -PlanMode $Mode)
        if (-not $msiPlan) { Write-Log 'No MSI patches in the source match the installed Office version/bitness.' WARN }
    }
    $c2rPlan = $null
    if ($c2r -and -not $SkipC2R) {
        $sources = @(Get-C2RSource -Root $root)
        $c2rPlan = New-C2RPlan -Installed $c2r -Sources $sources
    }

    $needed = @($msiPlan | Where-Object { $_.Status -eq 'Needed' })
    $counts = $msiPlan | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    if ($msiPlan) { Write-Log ("MSI plan: {0}" -f ($counts -join '  ')) }
    if ($c2rPlan) { Write-Log ("C2R plan: {0} - {1}" -f $c2rPlan.Status, $c2rPlan.Reason) }

    $planCsv = Join-Path $LogPath ('Plan_{0}_{1}.csv' -f $env:COMPUTERNAME, $stamp)
    $planRows = @($msiPlan | Select-Object Type, Status, KB, Component, Family, Arch, @{ n = 'Date'; e = { $_.Date.ToString('yyyy-MM-dd') } }, PatchName, Reason, RelativePath)
    if ($c2rPlan) {
        $planRows += [pscustomobject]@{ Type = 'C2R'; Status = $c2rPlan.Status; KB = ''; Component = 'All apps'; Family = $c2rPlan.Installed.Channel
            Arch = $c2rPlan.Installed.Arch; Date = ''; PatchName = $(if ($c2rPlan.Source) { $c2rPlan.Source.Version } else { '' }); Reason = $c2rPlan.Reason; RelativePath = '' }
    }
    if ($planRows) { $planRows | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding UTF8; Write-Log "Full plan saved: $planCsv" }

    # ------------------------------------------------------------ 5. choose
    $work = @()
    foreach ($p in $needed) { $work += $p }
    if ($c2rPlan -and $c2rPlan.Status -eq 'Needed') { $work += $c2rPlan }

    if (-not $work) {
        Write-Log 'This machine already has everything available in the patch source. Nothing to install.' OK
        exit 0
    }

    Write-Host ''
    Write-Host '  #    Type  KB         Component            Office   Arch  Date        Size' -ForegroundColor White
    Write-Host '  ---  ----  ---------  -------------------  -------  ----  ----------  --------'
    for ($i = 0; $i -lt $work.Count; $i++) {
        $w = $work[$i]
        if ($w.Type -eq 'MSI') {
            $comp = if ($w.Component) { $w.Component } else { $w.PatchName }
            Write-Host ('  {0,-4} MSI   {1,-9}  {2,-19}  {3,-7}  {4,-4}  {5:yyyy-MM-dd}  {6}' -f ($i + 1), $(if ($w.KB) { "KB$($w.KB)" } else { '-' }), $comp, $w.Family, $w.Arch, $w.Date, (Format-Size $w.SizeBytes))
        }
        else {
            Write-Host ('  {0,-4} C2R   {1,-9}  {2,-19}  {3,-7}  {4,-4}  {5,-10}  {6}' -f ($i + 1), '-', "$($w.Installed.Version) -> $($w.Source.Version)", 'C2R', $w.Installed.Arch, '', (Format-Size $w.Source.SizeBytes)) -ForegroundColor DarkCyan
        }
    }
    Write-Host ''

    if ($DryRun) {
        Write-Log "Dry run: $($work.Count) item(s) would be installed. See $planCsv" OK
        exit 0
    }
    if (-not $Unattended) {
        Write-Host '  [I] Install all items listed above'
        Write-Host '  [S] Select which items to install'
        Write-Host '  [R] Report only (plan already saved to CSV) and exit'
        Write-Host '  [Q] Quit'
        switch (Read-Choice -Prompt '  Choice' -Allowed @('I', 'S', 'R', 'Q') -Default 'I') {
            'S' {
                $pick = Read-MultiSelection -Prompt '  Item numbers (e.g. 1,3,5-8 or A)' -Max $work.Count
                if ($pick -contains -1) { Write-Log 'Quit by user.' WARN; exit 0 }
                $work = @($pick | ForEach-Object { $work[$_ - 1] })
            }
            'R' { Write-Log "Report only. Plan: $planCsv" OK; exit 0 }
            'Q' { Write-Log 'Quit by user.' WARN; exit 0 }
        }
    }

    # ------------------------------------------------------------ 6. install
    Write-Log ("Step 5/6  Installing {0} item(s)" -f $work.Count) STEP
    if (-not (Confirm-OfficeAppsClosed)) { Write-Log 'Aborted by user (Office apps still open).' WARN; exit 1 }

    $total = $work.Count; $n = 0
    $began = Get-Date
    foreach ($w in $work) {
        $n++
        $label = if ($w.Type -eq 'MSI') { "KB$($w.KB) $($w.PatchName)" } else { "Click-to-Run $($w.Source.Version)" }
        Write-Progress -Id 1 -Activity 'Office patching' -Status ("[{0}/{1}] {2}" -f $n, $total, $label) -PercentComplete ([int](100 * ($n - 1) / $total))
        Write-Log ("[{0}/{1}] {2}" -f $n, $total, $label) STEP
        if ($w.Type -eq 'MSI') { $Script:Results += Install-MsiPatch -Item $w }
        else                   { $Script:Results += Update-C2ROffice -Plan $w }
    }
    Write-Progress -Id 1 -Activity 'Office patching' -Completed

    # ------------------------------------------------------------ summary
    Write-Log 'Step 6/6  Summary' STEP
    $ok   = @($Script:Results | Where-Object { $_.Status -eq 'Installed' }).Count
    $na   = @($Script:Results | Where-Object { $_.Status -eq 'NotApplicable' }).Count
    $bad  = @($Script:Results | Where-Object { $_.Status -in @('Failed', 'Timeout') }).Count
    $Script:Results | Format-Table -Property Type, Item, Status, ExitCode, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    $reportCsv = Join-Path $LogPath ('Result_{0}_{1}.csv' -f $env:COMPUTERNAME, $stamp)
    $Script:Results | Export-Csv -LiteralPath $reportCsv -NoTypeInformation -Encoding UTF8
    Write-Log ("Installed: {0}   Not applicable: {1}   Failed: {2}   Duration: {3:hh\:mm\:ss}" -f $ok, $na, $bad, ((Get-Date) - $began)) $(if ($bad) { 'WARN' } else { 'OK' })
    Write-Log "Result report: $reportCsv"
    if ($c2r) {
        $after = Get-InstalledOfficeC2R
        if ($after) { Write-Log "Click-to-Run version now: $($after.Version)" }
    }

    if ($bad) { $Script:ExitCode = 1 }
    elseif ($Script:RebootRequired) { $Script:ExitCode = 3010 }

    if ($Script:RebootRequired) {
        Write-Log 'A REBOOT IS REQUIRED to complete patching.' WARN
        if (-not $Unattended -and (Read-YesNo '  Restart the computer now?' $false)) {
            Write-Log 'Restarting in 60 seconds (shutdown /a to cancel)...' WARN
            & "$env:SystemRoot\System32\shutdown.exe" /r /t 60 /c 'Office patching complete - restarting' /d p:2:17
        }
    }
}
catch {
    $Script:ExitCode = 1
    Write-Log "FATAL: $($_.Exception.Message)" ERROR
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace ERROR }
}
finally {
    Write-Progress -Id 1 -Activity 'Office patching' -Completed
    Write-Progress -Id 2 -Activity 'Office patching' -Completed
    if (-not $KeepStage -and -not $Script:KeepStageForce -and (Test-Path -LiteralPath $StagePath)) {
        Remove-Item -LiteralPath $StagePath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'Local staging folder cleaned up.'
    }
    if ($Script:MappedDrive) {
        Remove-PSDrive -Name $Script:MappedDrive -Force -ErrorAction SilentlyContinue
        Write-Log 'Share connection closed.'
    }
    if ($Script:LogFile) { Write-Host "  Log: $Script:LogFile" -ForegroundColor Gray }
}
exit $Script:ExitCode
#endregion
