<#
.SYNOPSIS
  PATCH-01 file share scanner 2.0.1, for Vulnerabilities > File shares. Read-only.

.DESCRIPTION
  Installed next to patch-agent.ps1 on the file servers being audited (only there). The agent starts it when
  PATCH-01 asks for a scan; it runs in its own process (a big server can take a while) and sends what it read to
  PATCH-01 itself, over the agent's pinned connection with the agent's token.

  What it reads, and nothing else:
    - the shares (Get-SmbShare), leaving out the administrative ones (C$, ADMIN$, IPC$), print$, SYSVOL,
      NETLOGON and every share on the system drive;
    - each share's permissions (Get-SmbShareAccess);
    - each folder's NTFS permissions and owner, all levels down (folders only, never files);
    - the people in each group named in a permission, from Active Directory (nested groups included) and, for
      the server's own groups, from the server.
  Folders down to the listing depth (3 below the share) are sent; deeper ones only when their permissions are not
  just the folder above's (an entry of their own, inheritance turned off, or inherited entries that differ, as a
  folder's creator gets through CREATOR OWNER), or when the ownership workbook names them. The others are counted
  on the folder above them. A share inside another share is read once, as itself. Links (junctions) are not
  followed. Nothing on the server is ever changed.

  access-scan.ps1 -JobFile <file>      what the agent runs (the job PATCH-01 asked for)
  access-scan.ps1 -DryRun              reads every share and prints what it found; sends NOTHING. Run it once
                                       on a file server, as administrator, before the first scan.
  access-scan.ps1 -DryRun -Share HR$ -MaxFolders 5000   the same, for one share and at most 5,000 folders
#>
[CmdletBinding(DefaultParameterSetName = "Job")]
param(
    [Parameter(ParameterSetName = "Job", Mandatory = $true)][string]$JobFile,
    [Parameter(ParameterSetName = "DryRun", Mandatory = $true)][switch]$DryRun,
    [Parameter(ParameterSetName = "DryRun")][string]$Share = "",
    [Parameter(ParameterSetName = "DryRun")][int]$MaxFolders = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ScannerVersion = "2.0.1"
$DataDir = Join-Path $env:ProgramData "PatchAgent"
$ConfigFile = Join-Path $DataDir "agent.json"
$TokenFile = Join-Path $DataDir "token.bin"
$LogFile = Join-Path $DataDir "access-scan.log"
$PartFolders = 2000                 # folders per part sent
$PartAces = 100000                  # and at most this many permission entries (a part stays far below 64 MB)
$PartSeconds = 60                   # and at least once a minute while the scan runs (PATCH-01 sees it is alive)
$MaxHours = 10                      # a scan stops walking after this long, and sends what it has
$MaxMembers = 50000                 # people per group read from Active Directory
$MaxAces = 1000                     # entries per folder PATCH-01 takes
$MaxShareAces = 200                 # entries per share PATCH-01 takes
$MaxPath = 4000                     # characters of a path PATCH-01 takes
$SkipNames = @("print$", "SYSVOL", "NETLOGON")
$RootSystem = @("system volume information", "`$recycle.bin", "recycler")      # Windows' own, at a volume's root
$Creators = @("S-1-3-0", "S-1-3-1")                                             # CREATOR OWNER / GROUP: placeholders
$script:Cfg = $null
$script:Token = $null
$script:Seq = 0
$script:ScanId = $null
$script:Send = $false
$script:LastSend = Get-Date
$script:SendFailed = $false

# ---------------------------------------------------------------------------
# Logging (never throws)
# ---------------------------------------------------------------------------
function Write-Log([string]$Message, [string]$Level = "INFO") {
    $line = "{0} {1} {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture), $Level, $Message
    if ($DryRun) { Write-Host $line }
    if (-not (Test-Path -LiteralPath $DataDir)) { return }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 2MB)) {
                try { Move-Item -LiteralPath $LogFile -Destination ($LogFile + ".1") -Force -ErrorAction Stop } catch { }
            }
            Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
            return
        } catch { Start-Sleep -Milliseconds 200 }
    }
}

function Get-Prop($Object, [string]$Name) {
    # Strict mode refuses a property that is not there: $null instead
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) { if ($Object.ContainsKey($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-Text($Value, [int]$Max = 300) {
    if ($null -eq $Value) { return $null }
    $t = [string]$Value
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

# ---------------------------------------------------------------------------
# PATCH-01: the agent's pinned connection and token (the same code as patch-agent.ps1)
# ---------------------------------------------------------------------------
if (-not ("PatchAgentPin" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class PatchAgentPin {
    public static string Pin = "";
    public static string Seen = "";
    public static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (cert == null) { return false; }
        using (SHA256 sha = SHA256.Create()) {
            Seen = BitConverter.ToString(sha.ComputeHash(cert.GetRawCertData())).Replace("-", "").ToLowerInvariant();
        }
        if (Pin == "system") { return errors == SslPolicyErrors.None; }
        foreach (string one in Pin.Split(',')) { if (one.Length > 0 && Seen == one) { return true; } }
        return false;
    }
    public static void Use(string pin) {
        Pin = pin.Trim().ToLowerInvariant().Replace(":", "").Replace(" ", "");
        ServicePointManager.ServerCertificateValidationCallback = new RemoteCertificateValidationCallback(Check);
    }
}
"@
}

function Get-Config {
    if ($script:Cfg) { return $script:Cfg }
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "The agent is not enrolled on this server (no agent.json)." }
    $script:Cfg = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
    return $script:Cfg
}

function Get-Token {
    Add-Type -AssemblyName System.Security
    if (-not (Test-Path -LiteralPath $TokenFile)) { throw "No agent token on this server." }
    $enc = [IO.File]::ReadAllBytes($TokenFile)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Initialize-Http {
    $cfg = Get-Config
    if ([string]$cfg.server -notmatch '^https://[A-Za-z0-9.-]+(:\d{1,5})?/?$') { throw ("PATCH-01's address must be https://<name>[:port]; '" + $cfg.server + "' was refused") }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [PatchAgentPin]::Use([string]$cfg.pin)
    [Net.WebRequest]::DefaultWebProxy = $null
    $script:Token = Get-Token
}

function Invoke-Api([string]$Path, $Body, [int]$Timeout = 120) {
    $cfg = Get-Config
    $params = @{ Method = "POST"; Uri = ($cfg.server.TrimEnd("/") + $Path); TimeoutSec = $Timeout; UseBasicParsing = $true
                 Headers = @{ "User-Agent" = "access-scan/$ScannerVersion"; "Authorization" = "Bearer " + $script:Token }
                 ContentType = "application/json; charset=utf-8"
                 Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 8 -Compress)) }
    try {
        return Invoke-RestMethod @params
    } catch {
        $detail = $_.Exception.Message
        $code = ""
        # Only web errors carry a response; asking others for one fails under strict mode
        if ($_.Exception.PSObject.Properties["Response"] -and $_.Exception.Response) { $code = "HTTP " + [int]$_.Exception.Response.StatusCode + ": " }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        if ([PatchAgentPin]::Seen -and [PatchAgentPin]::Pin -ne "system" -and ([PatchAgentPin]::Pin.Split(",") -notcontains [PatchAgentPin]::Seen)) {
            $detail = "PATCH-01's certificate does not match the pin. It presented " + [PatchAgentPin]::Seen
        }
        throw ("POST " + $Path + " failed: " + $code + $detail)
    }
}

function Send-Api([string]$Path, $Body, [int]$Timeout = 120) {
    # A part is sent again when its answer did not arrive (PATCH-01 takes a part once): 4 tries over about a minute.
    # A refusal (HTTP 4xx) is not tried again.
    $wait = 5
    for ($try = 1; $try -le 4; $try++) {
        try { return Invoke-Api $Path $Body $Timeout }
        catch {
            $m = [string]$_.Exception.Message
            if ($m -match "HTTP 4\d\d" -or $try -eq 4) { throw }
            Write-Log ("sending failed (try " + $try + "): " + $m + "; again in " + $wait + " s") "WARN"
            Start-Sleep -Seconds $wait
            $wait = $wait * 3
        }
    }
}

function Send-Part($Body) {
    # One part of the scan (shares, folders, counts, accounts, memberships), numbered
    if (-not $script:Send) { $script:LastSend = Get-Date; return }          # a dry run: nothing is sent
    $Body["seq"] = $script:Seq
    try { [void](Send-Api ("/api/v1/agent/file-shares/" + $script:ScanId + "/part") $Body) }
    catch { $script:SendFailed = $true; throw }                              # never taken for an AD failure
    $script:Seq++
    $script:LastSend = Get-Date
}

# ---------------------------------------------------------------------------
# Accounts and groups
# ---------------------------------------------------------------------------
$script:Sids = New-Object 'System.Collections.Generic.HashSet[string]'      # every SID a sent permission names
$script:Principals = @{}                                                     # sid -> as PATCH-01 takes it
$script:Pending = New-Object 'System.Collections.Generic.List[string]'       # principals not sent yet
$script:Members = New-Object 'System.Collections.Generic.List[object]'       # memberships not sent yet
$script:MemberKeys = New-Object 'System.Collections.Generic.HashSet[string]' # every membership, once
$script:MemberCount = 0
$script:AdRoot = $null
$script:GcRoot = $null
$script:AdTried = $false
$script:AdErrors = 0
$script:MachineSid = $null

function Find-NotMapped($Err) {
    # True when the account no longer exists (IdentityNotMappedException somewhere in the chain)
    $e = $Err.Exception
    while ($e) {
        if ($e.GetType().FullName -eq "System.Security.Principal.IdentityNotMappedException") { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Get-SidName([string]$Sid) {
    # @{ name; failed }: failed when the lookup itself failed (a domain controller out of reach), not when the
    # account is gone (then name is $null and failed is $false: an orphaned SID)
    try {
        $id = New-Object Security.Principal.SecurityIdentifier($Sid)
        return @{ name = $id.Translate([Security.Principal.NTAccount]).Value; failed = $false }
    } catch {
        if (Find-NotMapped $_) { return @{ name = $null; failed = $false } }
        $script:AdErrors++
        return @{ name = $null; failed = $true }
    }
}

function Get-AdRoot {
    if ($script:AdTried) { return $script:AdRoot }
    $script:AdTried = $true
    try {
        $rootDse = New-Object DirectoryServices.DirectoryEntry("LDAP://RootDSE")
        $nc = [string]$rootDse.Properties["defaultNamingContext"][0]
        if ($nc) { $script:AdRoot = New-Object DirectoryServices.DirectoryEntry("LDAP://" + $nc) }
    } catch { Write-Log ("Active Directory could not be reached: " + $_.Exception.Message) "WARN"; $script:AdErrors++ }
    try {
        # the whole forest, every tree in it (a GC:// path with a domain's name would search that tree only)
        $gc = [DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().FindGlobalCatalog()
        $script:GcRoot = $gc.GetDirectorySearcher().SearchRoot
    } catch { Write-Log ("no global catalogue answered: other domains' accounts are not looked up (" + $_.Exception.Message + ")") "WARN" }
    return $script:AdRoot
}

function ConvertTo-LdapSid([string]$Sid) {
    $id = New-Object Security.Principal.SecurityIdentifier($Sid)
    $b = New-Object byte[] ($id.BinaryLength)
    $id.GetBinaryForm($b, 0)
    return (($b | ForEach-Object { "\" + $_.ToString("x2") }) -join "")
}

function Get-AdOne([string]$Filter) {
    # The first object the filter finds: in this domain, then in the whole forest (the global catalogue)
    [void](Get-AdRoot)
    foreach ($root in @($script:AdRoot, $script:GcRoot)) {
        if (-not $root) { continue }
        $s = New-Object DirectoryServices.DirectorySearcher($root)
        $s.Filter = $Filter
        $s.SizeLimit = 1
        foreach ($p in @("objectClass", "sAMAccountName", "displayName", "mail", "department", "userAccountControl", "distinguishedName", "objectSid")) { [void]$s.PropertiesToLoad.Add($p) }
        try {
            $r = $s.FindOne()
            if ($r) { return @{ result = $r; global = ($root -eq $script:GcRoot) } }
        } catch { $script:AdErrors++; Write-Log ("an Active Directory search failed: " + $_.Exception.Message) "WARN" }
        finally { $s.Dispose() }
    }
    return $null
}

function Get-ResultValue($Result, [string]$Name) {
    if ($Result.Properties.Contains($Name) -and $Result.Properties[$Name].Count -gt 0) { return $Result.Properties[$Name][0] }
    return $null
}

function Add-Principal($P) {
    # every account with the same keys: strict mode stops the scan on a key a hashtable does not have
    foreach ($k in @("name", "lookup_failed")) { if (-not $P.ContainsKey($k)) { $P[$k] = $null } }
    if ($null -eq $P["lookup_failed"]) { $P["lookup_failed"] = $false }
    $script:Principals[$P.sid] = $P
    $script:Pending.Add($P.sid)
}

function Add-Membership([string]$Group, [string]$User) {
    if ($script:MemberKeys.Add($Group + "|" + $User)) { $script:Members.Add(@{ group = $Group; user = $User }); $script:MemberCount++ }
}

function Send-Accounts([bool]$All) {
    # Accounts and memberships go out as they are read (5,000 / 50,000 a part), and a part at least once a minute
    if (-not $script:Send) { return }
    $due = ((Get-Date) - $script:LastSend).TotalSeconds -ge $PartSeconds
    while ($script:Pending.Count -ge 5000 -or ($All -and $script:Pending.Count -gt 0) -or ($due -and $script:Pending.Count -gt 0)) {
        $n = [Math]::Min(5000, $script:Pending.Count)
        $chunk = @($script:Pending.GetRange(0, $n) | ForEach-Object { $script:Principals[$_] })
        Send-Part @{ principals = $chunk }
        $script:Pending.RemoveRange(0, $n)                 # only once PATCH-01 has them
        $due = $false
    }
    while ($script:Members.Count -ge 50000 -or ($All -and $script:Members.Count -gt 0) -or ($due -and $script:Members.Count -gt 0)) {
        $n = [Math]::Min(50000, $script:Members.Count)
        $chunk = @($script:Members.GetRange(0, $n))
        Send-Part @{ members = $chunk }
        $script:Members.RemoveRange(0, $n)
        $due = $false
    }
    if ($due) { Send-Part @{} }                    # nothing new, but alive
}

function Add-AdUser($Result, $Domain) {
    $raw = Get-ResultValue $Result "objectsid"
    if ($null -eq $raw) { return $null }
    $sid = (New-Object Security.Principal.SecurityIdentifier([byte[]]$raw, 0)).Value
    if (-not $script:Principals.ContainsKey($sid)) {
        $uac = Get-ResultValue $Result "useraccountcontrol"
        $sam = [string](Get-ResultValue $Result "samaccountname")
        Add-Principal @{ sid = $sid; kind = "user"; name = $(if ($sam -and $Domain) { $Domain + "\" + $sam } else { $null })
                         display = Get-Text (Get-ResultValue $Result "displayname"); email = Get-Text (Get-ResultValue $Result "mail")
                         department = Get-Text (Get-ResultValue $Result "department")
                         enabled = $(if ($null -ne $uac) { -not ([int]$uac -band 2) } else { $null }) }
    }
    return $sid
}

function Test-DomainUsers([string]$Sid) {
    # Domain Users of a domain, not this server's own group that also ends in -513 ("None")
    return ($Sid -match '^S-1-5-21-' -and $Sid.EndsWith("-513") -and -not ($script:MachineSid -and $Sid.StartsWith($script:MachineSid + "-")))
}

function Get-AdMembers([string]$GroupSid, [string]$Dn, $Domain, [string]$AlsoIn = "") {
    # Every person in the group, through nested groups as well (LDAP_MATCHING_RULE_IN_CHAIN). A group that holds
    # Domain Users (directly or nested) holds every domain user: the query cannot list those (it does not follow
    # primary groups), so it says so instead. -AlsoIn: a local group of this server that holds this group (its
    # people are in that one too).
    $root = Get-AdRoot
    if (-not $root) { return "not_read" }
    $esc = $Dn.Replace("\", "\5c").Replace("*", "\2a").Replace("(", "\28").Replace(")", "\29")
    $all = $false
    $du = $GroupSid.Substring(0, $GroupSid.LastIndexOf("-")) + "-513"
    try {
        $d = Get-AdOne ("(&(objectClass=group)(objectSid=" + (ConvertTo-LdapSid $du) + ")(memberOf:1.2.840.113556.1.4.1941:=" + $esc + "))")
        if ($d) { $all = $true }
    } catch { }
    $s = New-Object DirectoryServices.DirectorySearcher($root)
    $s.Filter = "(&(objectCategory=person)(objectClass=user)(memberOf:1.2.840.113556.1.4.1941:=" + $esc + "))"
    $s.PageSize = 1000
    foreach ($p in @("sAMAccountName", "displayName", "mail", "department", "userAccountControl", "objectSid")) { [void]$s.PropertiesToLoad.Add($p) }
    $n = 0
    try {
        $found = $s.FindAll()
        try {
            foreach ($r in $found) {
                $u = Add-AdUser $r $Domain
                if ($u) { Add-Membership $GroupSid $u; if ($AlsoIn) { Add-Membership $AlsoIn $u }; $n++ }
                Send-Accounts $false                     # sends in chunks, and a part at least once a minute
                if ($n -ge $MaxMembers) { if ($all) { return "all_domain_users" }; return "too_many" }
            }
        } finally { $found.Dispose() }
    } catch {
        if ($script:SendFailed) { throw }                 # PATCH-01 could not be reached: the scan stops
        $script:AdErrors++
        Write-Log ("the members of " + $Dn + " could not be read: " + $_.Exception.Message) "WARN"
        if ($all) { return "all_domain_users" }
        return "not_read"
    } finally { $s.Dispose() }
    if ($all) { return "all_domain_users" }
    return "read"
}

function Get-Worst([string]$A, [string]$B) {
    $rank = @{ "read" = 0; "too_many" = 1; "not_read" = 2 }
    if ($rank[$B] -gt $rank[$A]) { return $B }
    return $A
}

function Resolve-Local([string]$Sid, [string]$Name) {
    # A group of this server (BUILTIN\Users, or one of its own): its members from the server, domain groups in it
    # read from Active Directory. Says not_read / too_many when any member could not be read in full.
    $short = ($Name -split "\\", 2)[-1]
    $g = [ADSI]("WinNT://./" + $short + ",group")
    $all = $false
    $worst = "read"
    foreach ($m in @($g.Invoke("Members"))) {
        Send-Accounts $false
        $e = [ADSI]$m
        $raw = $null
        try { $raw = $e.Properties["objectSid"].Value } catch { }
        if ($null -eq $raw) { $worst = "not_read"; continue }
        $msid = (New-Object Security.Principal.SecurityIdentifier([byte[]]$raw, 0)).Value
        $class = [string]$e.SchemaClassName
        if ($msid -eq "S-1-5-11" -or $msid -eq "S-1-1-0" -or (Test-DomainUsers $msid)) { $all = $true; continue }   # Authenticated Users, Everyone, Domain Users
        $mine = ($script:MachineSid -and $msid.StartsWith($script:MachineSid + "-"))      # an account of this server
        $sn = $null
        if ($class -eq "User") {
            if (-not $script:Principals.ContainsKey($msid)) {
                $f = $null
                if (-not $mine -and $msid -match '^S-1-5-21-') { $f = Get-AdOne ("(objectSid=" + (ConvertTo-LdapSid $msid) + ")") }
                if ($f) {
                    $sn = Get-SidName $msid
                    [void](Add-AdUser $f.result $(if ($sn.name -and $sn.name.Contains("\")) { ($sn.name -split "\\", 2)[0] } else { $null }))
                }
                if (-not $script:Principals.ContainsKey($msid)) { $sn = Get-SidName $msid; Add-Principal @{ sid = $msid; kind = "user"; name = $sn.name; lookup_failed = $sn.failed } }
            }
            Add-Membership $Sid $msid
        } elseif ($class -eq "Group" -and $msid -match '^S-1-5-21-' -and -not $mine) {
            $f = Get-AdOne ("(objectSid=" + (ConvertTo-LdapSid $msid) + ")")
            if (-not $f -or $f.global) { $worst = "not_read"; continue }           # another domain's group: not read
            $mn = (Get-SidName $msid).name
            $dom = $(if ($mn -and $mn.Contains("\")) { ($mn -split "\\", 2)[0] } else { $null })
            $st = Get-AdMembers $msid ([string](Get-ResultValue $f.result "distinguishedname")) $dom $Sid
            if ($st -eq "all_domain_users") { $all = $true } else { $worst = Get-Worst $worst $st }
        } elseif ($msid -match '^S-1-5-21-') {
            $worst = "not_read"                       # a group of this server inside another: its people are not read
        }                                             # INTERACTIVE, SERVICE and the like: not people's accounts
    }
    if ($all) { return "all_domain_users" }
    return $worst
}

function Resolve-Principals([bool]$WithMembers) {
    $done = 0
    foreach ($sid in @($script:Sids)) {
        if ($script:Principals.ContainsKey($sid)) { continue }         # already read, as a member of a group
        $sn = Get-SidName $sid
        $name = $sn.name
        $p = @{ sid = $sid; name = $name; kind = "unknown"; lookup_failed = $sn.failed }
        if ($sid -match '^S-1-5-32-') {
            $p.kind = "local_group"
        } elseif ($sid -notmatch '^S-1-5-21-') {
            $p.kind = "well_known"
        } elseif ($name -and $script:MachineSid -and $sid.StartsWith($script:MachineSid + "-")) {
            # an account or group of this server itself
            try {
                $e = [ADSI]("WinNT://./" + ($name -split "\\", 2)[1])
                $p.kind = $(if ([string]$e.SchemaClassName -eq "Group") { "local_group" } else { "user" })
            } catch { }
        } elseif (Test-DomainUsers $sid) {
            $p.kind = "group"; $p.members = "all_domain_users"      # known without asking Active Directory
        } elseif ($name) {
            $f = $null
            try { $f = Get-AdOne ("(objectSid=" + (ConvertTo-LdapSid $sid) + ")") } catch { }
            if ($f) {
                $r = $f.result
                $classes = @($r.Properties["objectclass"])
                $p.kind = $(if ($classes -contains "computer") { "computer" } elseif ($classes -contains "group") { "group" } elseif ($classes -contains "user") { "user" } else { "unknown" })
                $p.display = Get-Text (Get-ResultValue $r "displayname")
                $p.email = Get-Text (Get-ResultValue $r "mail")
                $p.department = Get-Text (Get-ResultValue $r "department")
                $uac = Get-ResultValue $r "useraccountcontrol"
                if ($p.kind -eq "user" -and $null -ne $uac) { $p.enabled = -not ([int]$uac -band 2) }
                if ($p.kind -eq "group") {
                    if ($WithMembers -and -not $f.global) { $p.members = Get-AdMembers $sid ([string](Get-ResultValue $r "distinguishedname")) (($name -split "\\", 2)[0]) }
                    else { $p.members = "not_read" }          # another domain's group: its members are not read
                }
            }
        }
        # no name and not failed: an orphaned SID (no account has it any more)
        if ($p.kind -eq "local_group" -and $name -and $WithMembers) {
            try { $p.members = Resolve-Local $sid $name } catch { if ($script:SendFailed) { throw }; $p.members = "not_read"; Write-Log ("local group " + $name + ": " + $_.Exception.Message) "WARN" }
        }
        Add-Principal $p
        $done++
        Send-Accounts $false
    }
    return $done
}

function Get-MachineSid {
    # This server's own accounts start with it (its local groups and users)
    try {
        $c = [ADSI]("WinNT://" + $env:COMPUTERNAME + ",computer")
        $users = $c.Children                       # a new collection each time it is read: keep this one
        [void]$users.SchemaFilter.Add("user")
        foreach ($ch in $users) {
            if ([string]$ch.SchemaClassName -eq "User") {
                $id = New-Object Security.Principal.SecurityIdentifier([byte[]]$ch.Properties["objectSid"].Value, 0)
                return $id.AccountDomainSid.Value
            }
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------
# Shares and folders
# ---------------------------------------------------------------------------
function Get-IoPath([string]$Path) {
    # Long paths need the \\?\ form in Windows PowerShell; short ones are read as they are
    if ($Path.Length -ge 240 -and $Path -notmatch '^\\\\') { return "\\?\" + $Path }
    return $Path
}

function Get-ShareList([string[]]$Only) {
    $sys = $env:SystemDrive.TrimEnd("\").ToUpperInvariant() + "\"
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in @(Get-SmbShare -Special $false -ErrorAction Stop)) {
        $path = [string]$s.Path
        if (-not $path -or [string]$s.ShareType -ne "FileSystemDirectory") { continue }
        if ($SkipNames -contains [string]$s.Name) { continue }
        if (($path.ToUpperInvariant() + "\").StartsWith($sys)) { continue }            # the system drive
        if ($Only.Count -gt 0 -and $Only -notcontains [string]$s.Name) { continue }
        $out.Add($s)
    }
    return ,$out
}

function Get-ShareAcl($s) {
    $acl = New-Object 'System.Collections.Generic.List[object]'
    $errs = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($a in @($s | Get-SmbShareAccess -ErrorAction Stop)) {
            $acct = [string]$a.AccountName
            $sid = $null
            try {
                if ($acct -match '^S-1-[0-9-]+$') { $sid = (New-Object Security.Principal.SecurityIdentifier($acct)).Value }   # an orphaned SID shows as one
                else { $sid = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value }
            } catch { }
            if (-not $sid) { $errs.Add("'" + $acct + "' could not be read"); continue }
            if ($acl.Count -ge $MaxShareAces) { $errs.Add("more than " + $MaxShareAces + " entries: the first " + $MaxShareAces + " are kept"); break }
            [void]$script:Sids.Add($sid)
            $right = [string]$a.AccessRight
            if (@("Full", "Change", "Read", "Custom") -notcontains $right) { $right = "Custom" }
            $acl.Add(@{ sid = $sid; name = Get-Text $acct; allow = ([string]$a.AccessControlType -eq "Allow"); right = $right })
        }
    } catch { $errs.Add("The share permissions could not be read: " + $_.Exception.Message) }
    return @{ acl = $acl; error = $(if ($errs.Count) { Get-Text ($errs -join "; ") 1000 } else { $null }) }
}

function Read-Folder([string]$Path) {
    # @{ acl; protected; explicit; owner; error; partial; inherited (SIDs of inherited entries that apply here);
    #    passes (SIDs its entries hand down to its folders) }
    $r = @{ acl = (New-Object 'System.Collections.Generic.List[object]'); protected = $false; explicit = $false; owner = $null; error = $null
            partial = $false; inherited = (New-Object 'System.Collections.Generic.HashSet[string]'); passes = (New-Object 'System.Collections.Generic.HashSet[string]') }
    try {
        $sec = [IO.Directory]::GetAccessControl((Get-IoPath $Path), [Security.AccessControl.AccessControlSections]"Access, Owner")
        $r.protected = [bool]$sec.AreAccessRulesProtected
        try { $r.owner = $sec.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
        foreach ($a in $sec.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            $sid = $a.IdentityReference.Value
            $mask = [int64][int]$a.FileSystemRights
            if ($mask -lt 0) { $mask += 4294967296 }
            $inh = [bool]$a.IsInherited
            $here = -not ([int]$a.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly)
            $kids = [bool]([int]$a.InheritanceFlags -band [int][Security.AccessControl.InheritanceFlags]::ContainerInherit)
            $noProp = [bool]([int]$a.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::NoPropagateInherit)
            if (-not $inh) { $r.explicit = $true }
            if ($inh -and $here) { [void]$r.inherited.Add($sid) }
            if ($kids -and $Creators -notcontains $sid) { [void]$r.passes.Add($sid) }
            if ($r.acl.Count -ge $MaxAces) { $r.error = "More than " + $MaxAces + " permission entries: the first " + $MaxAces + " are kept"; $r.partial = $true; continue }
            $r.acl.Add(@{ sid = $sid; mask = $mask; allow = ([string]$a.AccessControlType -eq "Allow"); inh = $inh; here = $here; kids = ($kids -and -not $noProp) })
        }
    } catch { $r.error = Get-Text ("The permissions could not be read: " + $_.Exception.Message) }
    return $r
}

function Invoke-Scan($Job) {
    $t0 = Get-Date
    $listDepth = 3; $maxDepth = 64
    if ($null -ne (Get-Prop $Job "depth")) { $listDepth = [Math]::Max(0, [Math]::Min(8, [int](Get-Prop $Job "depth"))) }
    if ($null -ne (Get-Prop $Job "max_depth")) { $maxDepth = [Math]::Max($listDepth, [Math]::Min(64, [int](Get-Prop $Job "max_depth"))) }
    $withMembers = [bool](Get-Prop $Job "members")
    $only = @(@(Get-Prop $Job "shares") | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $asked = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in @(@(Get-Prop $Job "paths") | Where-Object { $_ })) { [void]$asked.Add(([string]$p).TrimEnd("\").ToLowerInvariant()) }
    $found = New-Object 'System.Collections.Generic.HashSet[string]'
    $part = @{ shares = (New-Object 'System.Collections.Generic.List[object]'); folders = (New-Object 'System.Collections.Generic.List[object]'); below = @{}; aces = 0 }
    $tot = @{ shares = 0; walked = 0; listed = 0; unreadable = 0; unreadable_below = 0; links = 0; deeper_than_max = 0; system_skipped = 0
              nested_shares = 0; too_long = 0; attributes_unread = 0; aces_cut = 0; truncated = $false }
    $flush = {
        if ($part.shares.Count -or $part.folders.Count -or $part.below.Count) {
            Send-Part @{ shares = $part.shares; folders = $part.folders; below = $part.below }
        }
        $part.shares = New-Object 'System.Collections.Generic.List[object]'
        $part.folders = New-Object 'System.Collections.Generic.List[object]'
        $part.below = @{}
        $part.aces = 0
    }

    $shares = Get-ShareList $only
    # A share inside another share (D:\Users\jdoe as jdoe$ under D:\Users as Users$) is read once, as itself
    $roots = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in $shares) { [void]$roots.Add(([string]$s.Path).TrimEnd("\").ToLowerInvariant()) }
    $walkedRoots = @{}                                   # root -> the share it was read as
    $samePath = New-Object 'System.Collections.Generic.List[string]'
    # asked paths: met, seen in a folder listing but not opened, or under a folder that was listed in full
    $seenKids = New-Object 'System.Collections.Generic.HashSet[string]'
    $listedOk = New-Object 'System.Collections.Generic.HashSet[string]'
    Write-Log ("" + $shares.Count + " shares to read")
    foreach ($s in $shares) {
        if ($tot.truncated) { break }
        $sname = [string]$s.Name; $root = ([string]$s.Path).TrimEnd("\")
        if ($root.Length -eq 2) { $root += "\" }                         # a share of a whole drive: D:\
        $sa = Get-ShareAcl $s
        $part.shares.Add(@{ name = $sname; path = $root; description = Get-Text $s.Description 500; acl = $sa.acl; error = $sa.error })
        $tot.shares++
        $rk = $root.TrimEnd("\").ToLowerInvariant()
        if ($walkedRoots.ContainsKey($rk)) {             # Data$ and Data on one folder: read once, as the first
            if ($samePath.Count -lt 20) { $samePath.Add(($sname + " = " + $walkedRoots[$rk])) }
            continue
        }
        $walkedRoots[$rk] = $sname
        $stack = New-Object 'System.Collections.Generic.Stack[object]'
        $stack.Push(@{ path = $root; depth = 0; up = $null; passes = $null })
        while ($stack.Count -gt 0) {
            if (((Get-Date) - $t0).TotalHours -ge $MaxHours) { $tot.truncated = $true; Write-Log ("stopped walking after " + $MaxHours + " hours: what was read is sent") "WARN"; break }
            if ($DryRun -and $MaxFolders -gt 0 -and $tot.walked -ge $MaxFolders) { break }
            if (((Get-Date) - $script:LastSend).TotalSeconds -ge $PartSeconds) {
                if ($part.folders.Count -gt 0 -or $part.below.Count -gt 0) { & $flush; Write-Log ("" + $tot.walked + " folders read, " + $tot.listed + " sent") }
                elseif ($script:Send) { Send-Part @{} }   # a long stretch with nothing to send: alive
                else { $script:LastSend = Get-Date }
            }
            $it = $stack.Pop()
            $path = [string]$it.path; $depth = [int]$it.depth
            $tot.walked++
            $key = $path.TrimEnd("\").ToLowerInvariant()
            $f = Read-Folder $path
            $isAsked = $asked.Contains($key)
            if ($isAsked) { [void]$found.Add($key) }
            $bad = [bool]($f.error -and -not $f.partial)          # not read (a folder cut at 1,000 entries was read)
            $differs = ($null -ne $it.passes -and -not $bad -and -not $f.inherited.SetEquals($it.passes))
            $why = $null
            if ($depth -le $listDepth) { $why = "level" }
            elseif ($bad) { $why = "own" }
            elseif ($f.protected) { $why = "protected" }
            elseif ($f.explicit -or $differs) { $why = "own" }
            elseif ($isAsked) { $why = "asked" }
            $kids = @(); $kidsRead = $false
            try {
                $kids = @([IO.Directory]::GetDirectories((Get-IoPath $path)))
                $kidsRead = $true
            } catch {
                $listErr = "Its folders could not be listed: " + $_.Exception.Message
                if ($f.error -and -not $f.partial) { $f.error = Get-Text ($f.error + " " + $listErr) }   # keep why its permissions failed
                else { $f.error = Get-Text $listErr }
                $f.partial = $false
                $bad = $true
                if (-not $why) { $why = "own" }
            }
            if ($bad) { $tot.unreadable++ }
            if ($f.partial) { $tot.aces_cut++ }
            $listedAs = $it.up
            if ($why -and $path.Length -gt $MaxPath) {                    # longer than PATCH-01 takes: left out, with its folders
                $tot.too_long++
                if ($bad) { $tot.unreadable_below++ }                     # unreadable, and not sent: counted here
                continue
            }
            if ($why) {
                foreach ($a in $f.acl) { [void]$script:Sids.Add($a.sid) }
                if ($f.owner) { [void]$script:Sids.Add($f.owner) }
                $part.folders.Add(@{ path = $path; share = $sname; depth = $depth; why = $why; protected = $f.protected; explicit = $f.explicit
                                     owner_sid = $f.owner; acl = $f.acl; below = 0; error = $f.error; partial = $f.partial })
                $part.aces += $f.acl.Count
                $tot.listed++
                $listedAs = $path
            } elseif ($it.up) {
                if ($part.below.ContainsKey($it.up)) { $part.below[$it.up] = [int]$part.below[$it.up] + 1 } else { $part.below[$it.up] = 1 }
            }
            if ($depth -ge $maxDepth) { if ($kids.Count) { $tot.deeper_than_max += $kids.Count }; continue }
            $pass = $null
            if (-not $bad) { $pass = $f.passes }          # the set itself: $( ) would hand on its items, or $null when empty
            if ($kidsRead -and $asked.Count) { [void]$listedOk.Add($key) }      # its folders are all looked at below
            $atRoot = ($path.Length -le 3)                 # D:\ : a volume's root, where Windows keeps its own folders
            foreach ($k in $kids) {
                $kp = [string]$k
                if ($kp.StartsWith("\\?\")) { $kp = $kp.Substring(4) }
                $kname = ([IO.Path]::GetFileName($kp)).ToLowerInvariant()
                if ($asked.Count -and $asked.Contains($kp.ToLowerInvariant())) { [void]$seenKids.Add($kp.ToLowerInvariant()) }
                if ($roots.Contains($kp.ToLowerInvariant())) { $tot.nested_shares++; continue }      # read as its own share
                $attr = $null
                try { $attr = [IO.File]::GetAttributes((Get-IoPath $kp)) } catch { }
                if ($null -eq $attr) { $tot.attributes_unread++; continue }                        # not followed: it may be a link
                if ([int]$attr -band [int][IO.FileAttributes]::ReparsePoint) { $tot.links++; continue }   # a link: not followed
                if ($atRoot -and $RootSystem -contains $kname) { $tot.system_skipped++; continue }
                $hs = [int][IO.FileAttributes]::Hidden -bor [int][IO.FileAttributes]::System
                if ($kname -eq "dfsrprivate" -and ([int]$attr -band $hs) -eq $hs) { $tot.system_skipped++; continue }
                $stack.Push(@{ path = $kp; depth = ($depth + 1); up = $listedAs; passes = $pass })
            }
            if ($part.folders.Count -ge $PartFolders -or $part.aces -ge $PartAces -or $part.below.Count -ge 10000) {
                & $flush
                Write-Log ("" + $tot.walked + " folders read, " + $tot.listed + " sent")
            }
        }
    }
    & $flush
    # the workbook's paths this scan did not meet
    $missing = New-Object 'System.Collections.Generic.List[string]'
    # only a path whose folder above was listed in full, and was not among its folders: not there. One under a
    # folder that could not be read, under a link, too deep, or not reached in time is not said to be missing.
    foreach ($a in $asked) {
        if ($found.Contains($a) -or $seenKids.Contains($a)) { continue }
        $up = $a.Substring(0, [Math]::Max(0, $a.LastIndexOf("\")))       # d:\x -> d: (the keys have no trailing \)
        if ($listedOk.Contains($up)) { $missing.Add($a) }
    }
    Write-Log ("" + $tot.walked + " folders read; reading the accounts and groups (" + $script:Sids.Count + ")")
    $script:MachineSid = Get-MachineSid
    [void](Resolve-Principals $withMembers)
    Send-Accounts $true
    $tot.seconds = [int]((Get-Date) - $t0).TotalSeconds
    $tot.accounts = $script:Principals.Count
    $tot.memberships = $script:MemberCount
    $tot.orphaned_sids = @($script:Principals.Values | Where-Object {
        -not (Get-Prop $_ "name") -and -not (Get-Prop $_ "lookup_failed") -and [string](Get-Prop $_ "sid") -match '^S-1-5-21-' }).Count
    $tot.accounts_not_looked_up = @($script:Principals.Values | Where-Object { Get-Prop $_ "lookup_failed" }).Count
    $tot.missing = @($missing)
    $tot.same_path = @($samePath)
    $tot.ad = $(if (-not (Get-AdRoot)) { "not reached" } elseif ($script:AdErrors) { "partly read (" + $script:AdErrors + " lookups failed)" } else { "read" })
    return $tot
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$mutex = $null
$owned = $false
$job = $null
try {
    try {
        $mutex = New-Object Threading.Mutex($false, "Global\PatchAccessScan")
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }   # the last scan was killed
    } catch { $owned = $false }                    # held by the SYSTEM scan, and not ours to open: another scan runs
    if ($DryRun) {
        if (-not $owned) { Write-Host "A scan is running on this server: try the dry run when it has finished." -ForegroundColor Yellow; exit 1 }
        $job = @{ scan_id = "dry-run"; shares = @($(if ($Share) { $Share })); paths = @(); depth = 3; max_depth = 64; members = $true }
        $tot = Invoke-Scan $job
        Write-Host ""
        Write-Host ("PATCH-01 file share scanner " + $ScannerVersion + ": dry run (nothing was sent)") -ForegroundColor Green
        $tot.GetEnumerator() | Where-Object { $_.Key -ne "missing" } | Sort-Object Key | ForEach-Object { "{0,-24} {1}" -f $_.Key, $_.Value } | Write-Host
        $file = Join-Path $env:TEMP "access-scan-dryrun.json"
        $out = @{ totals = $tot; principals = @($script:Principals.Values | Select-Object -First 200) }
        [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $out -Depth 6), (New-Object Text.UTF8Encoding($false)))
        Write-Host ("The figures and the first 200 accounts are in " + $file + " (read only by you).")
        exit 0
    }
    $job = [IO.File]::ReadAllText($JobFile) | ConvertFrom-Json
    if ([string]$job.scan_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw "the job file has no scan id" }
    $script:ScanId = [string]$job.scan_id
    Initialize-Http
    if (-not $owned) {
        Write-Log ("scan " + $script:ScanId + " not started: another scan is running on this server") "WARN"
        try { [void](Invoke-Api ("/api/v1/agent/file-shares/" + $script:ScanId + "/start") @{ scanner_version = $ScannerVersion }) } catch { }
        try { [void](Invoke-Api ("/api/v1/agent/file-shares/" + $script:ScanId + "/done") @{ ok = $false; error = "Another scan is running on this server: this one did not start." }) } catch { }
        exit 1
    }
    [void](Send-Api ("/api/v1/agent/file-shares/" + $script:ScanId + "/start") @{ scanner_version = $ScannerVersion })
    $script:Send = $true
    Write-Log ("scan " + $script:ScanId + " started (scanner " + $ScannerVersion + ")")
    $tot = $null
    try {
        $tot = Invoke-Scan $job
    } catch {
        $why = [string]$_.Exception.Message
        $where = ""; if ($_.InvocationInfo) { $where = " (line " + $_.InvocationInfo.ScriptLineNumber + ")" }
        $msg = $why + $where
        if ($msg.Length -gt 1900) { $msg = $msg.Substring(0, 1900) }
        Write-Log ("scan " + $script:ScanId + " failed: " + $msg) "ERROR"
        try { [void](Invoke-Api ("/api/v1/agent/file-shares/" + $script:ScanId + "/done") @{ ok = $false; error = $msg }) } catch { }
        exit 1
    }
    # PATCH-01 works out the risks and the matches when the scan is done: it may take a while to answer. A /done
    # whose answer is lost is sent again (taken once); a scan that was read is never reported as failed for it.
    try {
        [void](Send-Api ("/api/v1/agent/file-shares/" + $script:ScanId + "/done") @{ ok = $true; totals = $tot } 600)
        Write-Log ("scan " + $script:ScanId + " done: " + $tot.walked + " folders read, " + $tot.listed + " sent, in " + $tot.seconds + " s")
    } catch {
        Write-Log ("scan " + $script:ScanId + " read, but PATCH-01 did not confirm it: " + $_.Exception.Message + " (the page shows whether it arrived)") "WARN"
        exit 1
    }
} catch {
    Write-Log ("the scanner could not run: " + $_.Exception.Message) "ERROR"
    if ($DryRun) { Write-Host ("Failed: " + $_.Exception.Message) -ForegroundColor Red }
    exit 1
} finally {
    if ($JobFile -and (Test-Path -LiteralPath $JobFile)) { try { Remove-Item -LiteralPath $JobFile -Force } catch { } }
    if ($owned) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
