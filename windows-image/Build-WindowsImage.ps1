#Requires -Version 5.1
<#
.SYNOPSIS
  Build fully unattended Windows install media from a stock ISO and a config file.

.DESCRIPTION
  Run in an administrator Windows PowerShell on Windows 10, 11, or Server:

    .\Build-WindowsImage.ps1 -ListEditions D:\iso\Win11.iso    Editions in an ISO
    .\Build-WindowsImage.ps1 configs\north.psd1 -Plan          Check a config and write
                                                               what would go on the media
    .\Build-WindowsImage.ps1 configs\north.psd1                Build it
    .\Build-WindowsImage.ps1 configs\*.psd1                    Build every clinic
    .\Build-WindowsImage.ps1 configs\north.psd1 -UsbDisk 3     Build, then write USB disk 3
    .\Build-WindowsImage.ps1 -ListUsb                          USB disks you can write to
    .\Build-WindowsImage.ps1 -InstallTools                     Install oscdimg (Windows ADK)

  What a build does:
    1. Copies the ISO and keeps only the edition you chose.
    2. Services install.wim offline: updates, drivers, features, capabilities, app
       removal, registry, files, branding, and the first-boot provisioning payload.
    3. Adds drivers and the disk script to Setup's boot image.
    4. Writes autounattend.xml and produces an ISO, USB stick, and/or WIM.

  What the media does: see README.md. In short, it picks the internal disk (never a
  USB disk), applies the image, skips every setup screen, and then a scheduled task
  provisions the PC as SYSTEM, surviving reboots, before removing itself and every
  copy of the passwords.

  A config can Inherit from another, so clinics share a base and differ only where
  they need to. -Plan needs no administrator rights and changes nothing.

.PARAMETER Config
  One or more .psd1 config files. Wildcards work. Files with Abstract = $true (bases)
  are skipped by wildcards.
.PARAMETER Plan
  Validate the config and write the answer file, disk script, and provisioning data
  to <Output.Folder>\<Name>-plan, with passwords masked. Touches no image.
.PARAMETER ShowConfig
  Print the merged config, after inheritance, with passwords masked, and stop.
.PARAMETER UsbDisk
  Disk number to write after building (see -ListUsb). The disk is erased after you
  type its name to confirm.
.PARAMETER AllowWipe
  Put ALLOW-WIPE.txt on the USB stick, so its disk script will erase PCs that already
  have partitions on them, for this stick. Delete the file to turn this off again.
.PARAMETER WorkDir
  Where to unpack and mount. Default: <Output.Folder>\work. Needs about 3x the ISO
  size, on a local NTFS drive.
.PARAMETER OutputFolder
  Overrides Output.Folder from the config.
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
  [Parameter(ParameterSetName = 'Build', Mandatory = $true, Position = 0)][string[]]$Config,
  [Parameter(ParameterSetName = 'Build')][switch]$Plan,
  [Parameter(ParameterSetName = 'Build')][switch]$ShowConfig,
  [Parameter(ParameterSetName = 'Build')][int]$UsbDisk = -1,
  [Parameter(ParameterSetName = 'Build')][switch]$AllowWipe,
  [Parameter(ParameterSetName = 'Build')][string]$WorkDir,
  [Parameter(ParameterSetName = 'Build')][string]$OutputFolder,
  [Parameter(ParameterSetName = 'Editions', Mandatory = $true)][string]$ListEditions,
  [Parameter(ParameterSetName = 'Usb', Mandatory = $true)][switch]$ListUsb,
  [Parameter(ParameterSetName = 'Tools', Mandatory = $true)][switch]$InstallTools
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$Here = $PSScriptRoot
$EngineDir = Join-Path $Here 'engine'
$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

function Ok($m)      { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn($m)    { Write-Host "  [!]  $m" -ForegroundColor Yellow; $script:Warnings.Add($m) | Out-Null }
function Info($m)    { Write-Host "  .    $m" -ForegroundColor DarkGray }
function Section($m) { Write-Host ""; Write-Host "== $m ==" -ForegroundColor White }
function Die($m)     { throw $m }
$script:Warnings = New-Object System.Collections.ArrayList

# ------------------------------------------------------------------ defaults and schema
# Every setting and its default. A key that isn't here is rejected as a typo, so a
# misspelled setting fails the build instead of being quietly ignored.
function Get-Defaults {
  @{
    Name     = ''
    Abstract = $false
    Source   = @{ Iso = ''; Folder = ''; Edition = '' }
    Output   = @{ Folder = 'output'; Types = @('ISO'); VolumeLabel = '' }
    Boot     = @{ PressAnyKey = $false; BypassChecks = $false }
    Disk     = @{
      Method = 'Script'; Target = 'Auto'; Firmware = 'Auto'; IfMultipleDisks = 'Smallest'
      MinSizeGB = 60; IfNotBlank = 'Stop'; EfiMB = 300; RecoveryMB = 1024
      WindowsSizeGB = 0; DataLabel = 'Data'
    }
    License  = @{ ProductKey = 'generic'; UseFirmwareKey = $true; ActivationKey = ''; KmsHost = '' }
    Identity = @{
      ComputerName = '*'; NameMap = ''; Organization = ''; Owner = ''
      TimeZone = 'Central Standard Time'; Locale = 'en-US'; Keyboard = '0409:00000409'
    }
    Accounts = @{
      Admin = @{ Name = 'localadmin'; Password = 'random'; FullName = '' }
      Users = @()
      AutoLogon = @{ User = ''; Password = '' }
    }
    Drivers  = @{ Boot = @(); Image = @(); PerModel = @(); VirtIoIso = '' }
    Offline  = @{
      RemoveApps = @(); RemoveCapabilities = @(); AddCapabilities = @(); CapabilitySource = ''
      EnableFeatures = @(); DisableFeatures = @(); Updates = @(); ResetBase = $false
      Registry = @(); Files = @(); AppAssociations = ''; StartLayout = ''; TaskbarLayout = ''
      Wallpaper = ''; LockScreen = ''
      Oem = @{ Manufacturer = ''; Model = ''; SupportUrl = ''; SupportPhone = ''; SupportHours = ''; Logo = '' }
    }
    Network  = @{
      WaitSeconds = 180; Wifi = @(); DnsServers = @(); DnsSuffix = ''; Hosts = @()
      Proxy = @{ Server = ''; Bypass = '<local>' }
      Share = @{ Path = ''; User = ''; Password = '' }
    }
    Domain   = @{ Mode = 'None'; Name = ''; OU = ''; User = ''; Password = ''; Ppkg = @() }
    Security = @{
      Firewall = ''; FirewallRules = @()
      Rdp = @{ Enabled = $false; AllowFrom = @(); Nla = $true }
      BitLocker = @{ Enabled = $false; Method = 'XtsAes256'; UsedSpaceOnly = $true; Escrow = 'None' }
      Laps = @{ Enabled = $false; Backup = 'AD'; AccountName = ''; AgeDays = 30; Length = 16 }
      ScreenLockSeconds = 0
      LegalNotice = @{ Caption = ''; Text = '' }
      PasswordPolicy = @{ MinLength = 0; MaxAgeDays = 0; MinAgeDays = 0; History = 0; LockoutThreshold = 0; LockoutMinutes = 0 }
      AuditPolicy = ''; SecurityTemplate = ''
      DisableSmb1 = $false; RequireSmbSigning = $false; DisableLlmnr = $false; DisableNetBios = $false
      DisableAutorun = $false; DisableGuest = $false; BlockUsbStorage = $false; DisableWdigest = $false
      LsaProtection = $false; PowerShellLogging = $false
      Defender = @{ Exclusions = @(); ProcessExclusions = @(); AsrRules = @(); NetworkProtection = $false; PuaProtection = $false }
      Certificates = @()
    }
    Updates  = @{
      Run = $true; Drivers = $false; MaxRounds = 6; Wsus = ''; WsusGroup = ''
      PauseFeatureUpdatesDays = 0; ActiveHoursStart = -1; ActiveHoursEnd = -1
    }
    Apps     = @()
    Printers = @()
    Registry = @{ Machine = @(); DefaultUser = @(); Import = @() }
    Services = @{ Disable = @(); Enable = @() }
    Tweaks   = @()
    Power    = @{ Plan = ''; MonitorMinutes = -1; SleepMinutes = -1; Hibernate = ''; FastStartup = '' }
    UserSetup = @{ Shortcuts = @(); MappedDrives = @(); Scripts = @() }
    Scripts  = @{ Early = @(); Late = @() }
    Finish   = @{ Action = 'Reboot'; StopOnError = $false; ReportToShare = $false }
  }
}

# Allowed keys for the items in each list of hashtables
$ItemSchema = @{
  'Accounts.Users'           = 'Name', 'Password', 'FullName', 'Description', 'Groups', 'PasswordNeverExpires', 'MustChangePassword', 'Disabled'
  'Drivers.PerModel'         = 'Match', 'Path'
  'Offline.Registry'         = 'Hive', 'Key', 'Name', 'Type', 'Value'
  'Offline.Files'            = 'Source', 'Target'
  'Network.Hosts'            = 'Ip', 'Name'
  'Security.FirewallRules'   = 'Name', 'Direction', 'Action', 'Protocol', 'Port', 'RemoteAddress', 'Program', 'Profile'
  'Security.Certificates'    = 'File', 'Store', 'Password'
  'Apps'                     = 'Name', 'Source', 'Run', 'Args', 'Sha256', 'Detect', 'SuccessCodes', 'Reboot', 'TimeoutMinutes', 'Required', 'OnlyModels'
  'Printers'                 = 'Name', 'Address', 'Driver', 'DriverPath', 'Default', 'Port', 'Lpr'
  'Registry.Machine'         = 'Key', 'Name', 'Type', 'Value'
  'Registry.DefaultUser'     = 'Key', 'Name', 'Type', 'Value'
  'UserSetup.Shortcuts'      = 'Name', 'Target', 'Url', 'Arguments', 'Icon', 'Folder'
  'UserSetup.MappedDrives'   = 'Letter', 'Path'
  'Scripts.Early'            = 'Path', 'Args', 'Reboot'
  'Scripts.Late'             = 'Path', 'Args', 'Reboot'
}

# Settings that hold paths on the build machine. They're relative to the file that
# sets them, so a base config in another folder keeps working when it's inherited.
$PathSettings = @(
  'Source.Iso', 'Source.Folder', 'Output.Folder', 'Identity.NameMap',
  'Drivers.Boot', 'Drivers.Image', 'Drivers.VirtIoIso', 'Drivers.PerModel[].Path',
  'Offline.Updates', 'Offline.CapabilitySource', 'Offline.Files[].Source', 'Offline.AppAssociations',
  'Offline.StartLayout', 'Offline.TaskbarLayout', 'Offline.Wallpaper', 'Offline.LockScreen', 'Offline.Oem.Logo',
  'Network.Wifi', 'Domain.Ppkg', 'Security.Certificates[].File', 'Security.SecurityTemplate',
  'Apps[].Source', 'Printers[].DriverPath', 'Registry.Import', 'UserSetup.Scripts',
  'Scripts.Early[].Path', 'Scripts.Late[].Path'
)

# ------------------------------------------------------------------ config loading
function Test-PathIsLocal([string]$p) {
  if (-not $p) { return $false }
  return ($p -notmatch '^(https?://|winget:)')
}

function Resolve-RelPath([string]$p, [string]$dir) {
  if (-not (Test-PathIsLocal $p)) { return $p }
  if (-not $OnWindows) { $p = $p -replace '\\', '/' }
  if ([IO.Path]::IsPathRooted($p) -or $p -match '^\\\\') { return $p }
  return [IO.Path]::GetFullPath((Join-Path $dir $p))
}

function Resolve-AtPath($node, [string[]]$parts, [string]$dir) {
  if ($null -eq $node -or $parts.Count -eq 0) { return }
  $seg = $parts[0]; $isList = $seg.EndsWith('[]'); $key = $seg -replace '\[\]$', ''
  foreach ($k in @($key, "$key+")) {
    if ($node -isnot [hashtable] -or -not $node.ContainsKey($k)) { continue }
    if ($isList) {
      foreach ($item in @($node[$k])) { Resolve-AtPath $item @($parts[1..($parts.Count - 1)]) $dir }
    } elseif ($parts.Count -gt 1) {
      Resolve-AtPath $node[$k] @($parts[1..($parts.Count - 1)]) $dir
    } elseif ($node[$k] -is [array]) {
      $node[$k] = @($node[$k] | ForEach-Object { Resolve-RelPath $_ $dir })
    } elseif ($node[$k] -is [string] -and $node[$k]) {
      $node[$k] = Resolve-RelPath $node[$k] $dir
    }
  }
}

function Merge-Config([hashtable]$Base, [hashtable]$Over) {
  # Hashtables merge key by key. Anything else replaces. 'Key+' appends to a list and
  # 'Key-' removes entries from it, by value or by their Name.
  foreach ($k in @($Over.Keys)) {
    $v = $Over[$k]
    if ($k.EndsWith('+')) {
      $real = $k.TrimEnd('+')
      $Base[$real] = @($Base[$real]) + @($v) | Where-Object { $null -ne $_ }
      $Base[$real] = @($Base[$real])
    } elseif ($k.EndsWith('-')) {
      $real = $k.TrimEnd('-'); $drop = @($v)
      $Base[$real] = @(@($Base[$real]) | Where-Object {
          $id = if ($_ -is [hashtable]) { $_.Name } else { $_ }
          $drop -notcontains $id
        })
    } elseif ($v -is [hashtable] -and $Base[$k] -is [hashtable]) {
      Merge-Config $Base[$k] $v | Out-Null
    } else {
      $Base[$k] = $v
    }
  }
  return $Base
}

function Read-ConfigFile([string]$File, [string[]]$Seen = @()) {
  $full = [IO.Path]::GetFullPath($File)
  if ($Seen -contains $full) { Die "Config inheritance loops back to $full" }
  if (-not (Test-Path -LiteralPath $full)) { Die "Config not found: $full" }
  try { $data = Import-PowerShellDataFile -LiteralPath $full }
  catch { Die "$full isn't a valid config: $($_.Exception.Message)" }
  $dir = Split-Path -Parent $full
  foreach ($p in $PathSettings) { Resolve-AtPath $data @($p -split '\.') $dir }

  $merged = @{}
  $parents = @()
  if ($data.ContainsKey('Inherit')) { $parents = @($data.Inherit); $data.Remove('Inherit') }
  foreach ($parent in $parents) {
    $pf = Resolve-RelPath $parent $dir
    Merge-Config $merged (Read-ConfigFile $pf ($Seen + $full)) | Out-Null
  }
  # Abstract never passes down: a clinic that inherits a base isn't itself a base
  $merged.Remove('Abstract')
  return (Merge-Config $merged $data)
}

function Test-Schema($Value, $Default, [string]$Where, [System.Collections.ArrayList]$Errors) {
  foreach ($k in @($Value.Keys)) {
    $bare = $k.TrimEnd('+', '-')
    $here = if ($Where) { "$Where.$bare" } else { $bare }
    if (-not $Default.ContainsKey($bare)) {
      [void]$Errors.Add("Unknown setting '$here'")
      continue
    }
    if ($Default[$bare] -is [hashtable]) {
      if ($Value[$k] -isnot [hashtable]) { [void]$Errors.Add("'$here' should be a @{ } section"); continue }
      Test-Schema $Value[$k] $Default[$bare] $here $Errors
    } elseif ($ItemSchema.ContainsKey($here)) {
      foreach ($item in @($Value[$k])) {
        if ($null -eq $item) { continue }
        if ($item -isnot [hashtable]) { [void]$Errors.Add("Entries of '$here' should be @{ } items"); continue }
        foreach ($ik in @($item.Keys)) {
          if ($ItemSchema[$here] -notcontains $ik) { [void]$Errors.Add("Unknown setting '$ik' in an entry of '$here'") }
        }
      }
    }
  }
}

function New-EffectiveConfig([string]$File) {
  $over = Read-ConfigFile $File
  $errors = New-Object System.Collections.ArrayList
  $defaults = Get-Defaults
  Test-Schema $over $defaults '' $errors
  if ($errors.Count) { Die ("$File has problems:`n    " + ($errors -join "`n    ")) }
  $cfg = Merge-Config (Get-Defaults) $over
  if (-not $cfg.Name) { $cfg.Name = [IO.Path]::GetFileNameWithoutExtension($File) -replace '\.example$', '' }
  return $cfg
}

function Test-Config($c) {
  $e = New-Object System.Collections.ArrayList
  if ($c.Name -notmatch '^[A-Za-z0-9._-]+$') { [void]$e.Add("Name '$($c.Name)' may only use letters, digits, dots, dashes, underscores") }
  if (-not $c.Source.Iso -and -not $c.Source.Folder) { [void]$e.Add('Set Source.Iso (or Source.Folder for an unpacked ISO)') }
  if (-not $c.Source.Edition) { [void]$e.Add('Set Source.Edition (see -ListEditions)') }
  foreach ($t in $c.Output.Types) { if ('ISO', 'USB', 'WIM', 'Folder' -notcontains $t) { [void]$e.Add("Output.Types: unknown type '$t'") } }
  $d = $c.Disk
  if ('Script', 'Setup' -notcontains $d.Method) { [void]$e.Add('Disk.Method must be Script or Setup') }
  if ("$($d.Target)" -notmatch '^(Auto|\d+)$') { [void]$e.Add('Disk.Target must be Auto or a disk number') }
  if ($d.Method -eq 'Setup' -and "$($d.Target)" -eq 'Auto') { [void]$e.Add('Disk.Method = Setup needs a fixed Disk.Target number (Setup has no way to choose a disk itself)') }
  if ('Auto', 'UEFI', 'BIOS' -notcontains $d.Firmware) { [void]$e.Add('Disk.Firmware must be Auto, UEFI or BIOS') }
  if ('Smallest', 'Largest', 'Stop' -notcontains $d.IfMultipleDisks) { [void]$e.Add('Disk.IfMultipleDisks must be Smallest, Largest or Stop') }
  if ('Stop', 'Wipe' -notcontains $d.IfNotBlank) { [void]$e.Add('Disk.IfNotBlank must be Stop or Wipe') }
  $cn = $c.Identity.ComputerName
  $literal = $cn -notmatch '[{]' -and $cn -ne '*'
  if ($literal -and ($cn -notmatch '^[A-Za-z0-9-]{1,15}$' -or $cn -match '^\d+$')) { [void]$e.Add("Identity.ComputerName '$cn' must be up to 15 letters, digits, and dashes, and not all digits") }
  if ($cn -match '[{]' -and (Get-NameTokens $cn).Count -eq 0) { [void]$e.Add("Identity.ComputerName '$cn' has no known token: use {serial}, {serial:6}, {mac}, {random:4}, {name}") }
  if ($c.Accounts.Admin.Name -notmatch '^[A-Za-z0-9._-]{1,20}$') { [void]$e.Add('Accounts.Admin.Name must be 1-20 letters, digits, dots, dashes or underscores') }
  foreach ($u in $c.Accounts.Users) {
    if ($u.Name -notmatch '^[A-Za-z0-9._-]{1,20}$') { [void]$e.Add("Accounts.Users: bad name '$($u.Name)'") }
    if ($u.Name -eq $c.Accounts.Admin.Name) { [void]$e.Add("Accounts.Users: '$($u.Name)' is the same as Accounts.Admin") }
    if (-not $u.Password) { [void]$e.Add("Accounts.Users: '$($u.Name)' needs a Password (or 'random')") }
  }
  if ('None', 'AD', 'Ppkg' -notcontains $c.Domain.Mode) { [void]$e.Add('Domain.Mode must be None, AD or Ppkg') }
  if ($c.Domain.Mode -eq 'AD' -and -not ($c.Domain.Name -and $c.Domain.User -and $c.Domain.Password)) { [void]$e.Add('Domain.Mode = AD needs Domain.Name, Domain.User and Domain.Password') }
  if ($c.Domain.Mode -eq 'Ppkg' -and -not @($c.Domain.Ppkg).Count) { [void]$e.Add('Domain.Mode = Ppkg needs Domain.Ppkg') }
  $bl = $c.Security.BitLocker
  if ('None', 'AD', 'Entra', 'Share' -notcontains $bl.Escrow) { [void]$e.Add('Security.BitLocker.Escrow must be None, AD, Entra or Share') }
  if ($bl.Escrow -eq 'Share' -and -not $c.Network.Share.Path) { [void]$e.Add('Security.BitLocker.Escrow = Share needs Network.Share.Path') }
  if ($bl.Enabled -and $bl.Escrow -eq 'AD' -and $c.Domain.Mode -ne 'AD') { [void]$e.Add('Security.BitLocker.Escrow = AD needs Domain.Mode = AD') }
  if ($c.Finish.ReportToShare -and -not $c.Network.Share.Path) { [void]$e.Add('Finish.ReportToShare needs Network.Share.Path') }
  if ('Reboot', 'Shutdown', 'None' -notcontains $c.Finish.Action) { [void]$e.Add('Finish.Action must be Reboot, Shutdown or None') }
  foreach ($a in $c.Apps) {
    if (-not $a.Name) { [void]$e.Add('Every entry in Apps needs a Name') }
    if (-not $a.Source) { [void]$e.Add("Apps '$($a.Name)' needs a Source") }
    if ($a.Source -match '^https?://' -and -not $a.Sha256) { [void]$e.Add("Apps '$($a.Name)' downloads from a URL, so it needs a Sha256") }
  }
  foreach ($p in $c.Printers) { if (-not ($p.Name -and $p.Address -and $p.Driver)) { [void]$e.Add('Every printer needs Name, Address and Driver') } }
  foreach ($r in $c.Offline.Registry) { if ('SOFTWARE', 'SYSTEM', 'NTUSER' -notcontains $r.Hive) { [void]$e.Add("Offline.Registry Hive must be SOFTWARE, SYSTEM or NTUSER, not '$($r.Hive)'") } }
  $key = $c.License.ProductKey
  if ('generic', 'kms', 'none' -notcontains $key -and $key -notmatch '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$') { [void]$e.Add('License.ProductKey must be generic, kms, none, or a key') }
  if ($e.Count) { Die ("$($c.Name): the config has problems:`n    " + ($e -join "`n    ")) }

  if ($d.IfNotBlank -eq 'Wipe') { Warn "Disk.IfNotBlank = Wipe: this media erases any PC it boots on with no prompt. Keep it locked up." }
  if ($literal -and 'USB', 'ISO' -contains @($c.Output.Types)[0]) { Warn "Identity.ComputerName is the fixed name '$cn': every PC from this image gets it. Use a pattern like $($c.Name.ToUpper().Substring(0, [Math]::Min(3, $c.Name.Length)))-{serial:7} for more than one PC." }
  if ($c.Domain.Mode -eq 'AD') { Warn "The domain join password goes on the media. Use an account that can only join computers to this OU." }
  if ($c.Network.Share.Password) { Warn "Network.Share's password goes on the media. Give that account write access to its one share only." }
  if ($bl.Enabled -and $bl.Escrow -eq 'None') { Warn "Security.BitLocker has Escrow = None, so nothing keeps the recovery key. BitLocker will be skipped unless you set AD, Entra or Share." }
}

function Get-NameTokens([string]$pattern) {
  return @([regex]::Matches($pattern, '\{(serial(:\d+)?|mac|random:\d+|name)\}') | ForEach-Object { $_.Value })
}

function Get-ConfigFiles([string[]]$patterns) {
  $files = New-Object System.Collections.ArrayList
  foreach ($p in $patterns) {
    $hits = @(Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.psd1')
    if (-not $hits.Count) { Die "No config matches $p" }
    foreach ($h in $hits) {
      if ([WildcardPattern]::ContainsWildcardCharacters($p)) {
        $raw = Import-PowerShellDataFile -LiteralPath $h.FullName
        if ($raw.Abstract) { Info "$($h.Name) is a base (Abstract); skipping it"; continue }
      }
      [void]$files.Add($h.FullName)
    }
  }
  return $files
}

# ------------------------------------------------------------------ secrets
$script:Credentials = New-Object System.Collections.ArrayList

function New-Password {
  $alpha = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  do {
    $bytes = New-Object byte[] 15
    $rng.GetBytes($bytes)
    $p = -join ($bytes | ForEach-Object { $alpha[$_ % $alpha.Length] })
  } until ($p -cmatch '[A-Z]' -and $p -cmatch '[a-z]' -and $p -match '[0-9]')
  return $p.Substring(0, 7) + '-' + $p.Substring(7)
}

function Resolve-Secret([string]$Value, [string]$Label) {
  # A password setting can be: random, prompt, env:NAME, or the password itself
  if (-not $Value) { return '' }
  if ($Plan) { [void]$script:Credentials.Add(@{ Label = $Label; Value = '(not generated in -Plan)' }); return 'PLAN-ONLY-MASKED' }
  $out = switch -Regex ($Value) {
    '^random$' { New-Password; break }
    '^prompt$' {
      $sec = Read-Host -AsSecureString "Password for $Label"
      $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
      break
    }
    '^env:(.+)$' {
      $v = [Environment]::GetEnvironmentVariable($Matches[1])
      if (-not $v) { Die "$Label reads environment variable $($Matches[1]), which isn't set." }
      $v; break
    }
    default { $Value }
  }
  if (-not $out) { Die "$Label has an empty password." }
  [void]$script:Credentials.Add(@{ Label = $Label; Value = $out })
  return $out
}

function Hide-Secrets($node) {
  if ($node -is [hashtable]) {
    $copy = @{}
    foreach ($k in $node.Keys) {
      if ($k -eq 'Password' -and $node[$k]) { $copy[$k] = '(hidden)' } else { $copy[$k] = Hide-Secrets $node[$k] }
    }
    return $copy
  }
  if ($node -is [array]) { return , @($node | ForEach-Object { Hide-Secrets $_ }) }
  return $node
}

# ------------------------------------------------------------------ product keys
function Get-SetupKey($c) {
  $mode = $c.License.ProductKey; $ed = $c.Source.Edition
  if ($mode -eq 'none' -or $ed -match 'Evaluation') { return '' }
  if ($mode -notin 'generic', 'kms') { return $mode }
  $name = ($ed -replace ' \(Desktop Experience\)$', '') -replace '^Windows 1[01] ', ''
  # Generic install keys: they install but never activate on their own. A PC with a
  # digital licence or firmware key still activates. Published by Microsoft.
  $generic = @{
    'Home' = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'; 'Home N' = '4CPRK-NM3K3-X6XXQ-RXX86-WXCHW'
    'Pro' = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'; 'Pro N' = '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT'
    'Pro for Workstations' = 'DXG7C-N36C4-C4HTG-X4T3X-2YV77'; 'Pro Education' = '8PTT6-RNW4C-6V7J2-C2D3X-MHBPB'
    'Education' = 'YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY'; 'Enterprise' = 'XGVPP-NMH47-7TTHJ-W3FW7-8HV2C'
  }
  # KMS client setup keys: for PCs that activate against your own KMS host
  $kms = @{
    'Pro' = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'; 'Pro N' = 'MH37W-N47XK-V7XM9-C7227-GCQG9'
    'Pro for Workstations' = 'NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J'; 'Education' = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
    'Enterprise' = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'; 'Home' = 'TX9XD-98N7V-6WMQ6-BX7FG-H8Q99'
    'Windows Server 2019 Standard' = 'N69G4-B89J2-4G8F4-WWYCC-J464C'; 'Windows Server 2019 Datacenter' = 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'
    'Windows Server 2022 Standard' = 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H'; 'Windows Server 2022 Datacenter' = 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33'
    'Windows Server 2025 Standard' = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'; 'Windows Server 2025 Datacenter' = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
  }
  $table = if ($mode -eq 'kms' -or $ed -match 'Server') { $kms } else { $generic }
  if ($table.ContainsKey($name)) { return $table[$name] }
  Warn "No published install key for '$ed'. Set License.ProductKey if Setup asks for one."
  return ''
}

# ------------------------------------------------------------------ answer file
function X([string]$s) { return [Security.SecurityElement]::Escape($s) }

function New-AnswerFile($c, [string]$Arch, [string]$BuildId) {
  $isClient = $c.Source.Edition -notmatch 'Server'
  $key = Get-SetupKey $c
  $scripted = $c.Disk.Method -eq 'Script'
  $sb = New-Object Text.StringBuilder
  function W([string]$l) { [void]$sb.AppendLine($l) }
  function Comp([string]$n) {
    W ('    <component name="{0}" processorArchitecture="{1}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' -f $n, $Arch)
  }
  function Pwd64([string]$p, [string]$suffix) { return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($p + $suffix)) }
  $L = X $c.Identity.Locale; $K = X $c.Identity.Keyboard; $TZ = X $c.Identity.TimeZone
  $Org = X $c.Identity.Organization; $Owner = X $(if ($c.Identity.Owner) { $c.Identity.Owner } else { $c.Identity.Organization })
  # Fixed names go straight in. Patterns are worked out on the PC, by the engine.
  $cn = if ($c.Identity.ComputerName -match '[{]' -or $c.Identity.NameMap) { '*' } else { $c.Identity.ComputerName }

  W '<?xml version="1.0" encoding="utf-8"?>'
  W "<!-- Written by Build-WindowsImage.ps1 for $(X $c.Name), build $BuildId. Holds passwords. Deleted from the PC after provisioning. -->"
  W '<unattend xmlns="urn:schemas-microsoft-com:unattend">'
  W '  <settings pass="windowsPE">'
  Comp 'Microsoft-Windows-International-Core-WinPE'
  W "      <SetupUILanguage><UILanguage>$L</UILanguage></SetupUILanguage>"
  W "      <InputLocale>$K</InputLocale><SystemLocale>$L</SystemLocale><UILanguage>$L</UILanguage><UserLocale>$L</UserLocale>"
  W '    </component>'
  Comp 'Microsoft-Windows-Setup'
  $order = 0
  $needsRun = $scripted -or $c.Boot.BypassChecks
  if ($needsRun) { W '      <RunSynchronous>' }
  if ($scripted) {
    $order++
    W "        <RunSynchronousCommand wcm:action=`"add`"><Order>$order</Order><Path>cmd.exe /c X:\winimage\pe-install.cmd</Path></RunSynchronousCommand>"
  } elseif ($c.Boot.BypassChecks) {
    foreach ($v in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck') {
      $order++
      W "        <RunSynchronousCommand wcm:action=`"add`"><Order>$order</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v $v /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"
    }
  }
  if ($needsRun) { W '      </RunSynchronous>' }
  if (-not $scripted) {
    $disk = [int]$c.Disk.Target
    W "      <DiskConfiguration><Disk wcm:action=`"add`"><DiskID>$disk</DiskID><WillWipeDisk>true</WillWipeDisk>"
    if ($c.Disk.Firmware -eq 'BIOS') {
      W '        <CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>500</Size></CreatePartition><CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions>'
      W '        <ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>System Reserved</Label><Active>true</Active></ModifyPartition><ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition></ModifyPartitions>'
      $part = 2
    } else {
      W "        <CreatePartitions><CreatePartition wcm:action=`"add`"><Order>1</Order><Type>EFI</Type><Size>$($c.Disk.EfiMB)</Size></CreatePartition><CreatePartition wcm:action=`"add`"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition><CreatePartition wcm:action=`"add`"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions>"
      W '        <ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition><ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition><ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition></ModifyPartitions>'
      $part = 3
    }
    W '      </Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>'
    W '      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>'
    W "        <InstallTo><DiskID>$disk</DiskID><PartitionID>$part</PartitionID></InstallTo></OSImage></ImageInstall>"
  }
  $keyXml = if ($key -and -not $scripted) { "<ProductKey><Key>$key</Key><WillShowUI>Never</WillShowUI></ProductKey>" } else { '' }
  W "      <UserData><AcceptEula>true</AcceptEula><FullName>$Owner</FullName><Organization>$Org</Organization>$keyXml</UserData>"
  W '    </component>'
  W '  </settings>'

  W '  <settings pass="specialize">'
  Comp 'Microsoft-Windows-Shell-Setup'
  $specializeKey = if ($key -and $scripted) { "<ProductKey>$key</ProductKey>" } else { '' }
  W "      <ComputerName>$(X $cn)</ComputerName><TimeZone>$TZ</TimeZone><RegisteredOrganization>$Org</RegisteredOrganization><RegisteredOwner>$Owner</RegisteredOwner>$specializeKey"
  W '    </component>'
  Comp 'Microsoft-Windows-Deployment'
  W '      <RunSynchronous>'
  $n = 0
  $cmds = New-Object System.Collections.ArrayList
  [void]$cmds.Add('cmd.exe /c icacls %SystemDrive%\WinImage /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F')
  if ($isClient) { [void]$cmds.Add('reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f') }
  [void]$cmds.Add('cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File %SystemDrive%\WinImage\Register-Provision.ps1')
  foreach ($cmd in $cmds) { $n++; W "        <RunSynchronousCommand wcm:action=`"add`"><Order>$n</Order><Path>$(X $cmd)</Path></RunSynchronousCommand>" }
  W '      </RunSynchronous>'
  W '    </component>'
  W '  </settings>'

  W '  <settings pass="oobeSystem">'
  Comp 'Microsoft-Windows-International-Core'
  W "      <InputLocale>$K</InputLocale><SystemLocale>$L</SystemLocale><UILanguage>$L</UILanguage><UserLocale>$L</UserLocale>"
  W '    </component>'
  Comp 'Microsoft-Windows-Shell-Setup'
  W '      <OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>'
  if ($isClient) { W '        <HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>' }
  W '        <HideLocalAccountScreen>true</HideLocalAccountScreen><ProtectYourPC>3</ProtectYourPC></OOBE>'
  $an = X $c.Accounts.Admin.Name
  $afn = X $(if ($c.Accounts.Admin.FullName) { $c.Accounts.Admin.FullName } else { $c.Accounts.Admin.Name })
  $pw = Pwd64 $script:AdminPassword 'Password'
  W "      <UserAccounts><LocalAccounts><LocalAccount wcm:action=`"add`"><Name>$an</Name><DisplayName>$afn</DisplayName><Group>Administrators</Group><Password><Value>$pw</Value><PlainText>false</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>"
  W "      <TimeZone>$TZ</TimeZone>"
  W '    </component>'
  W '  </settings>'
  W '</unattend>'
  $text = $sb.ToString()
  try { [void][xml]$text } catch { Die "The generated answer file isn't valid XML: $($_.Exception.Message)" }
  return $text
}

function New-PeScript($c, [string]$BuildId) {
  $tpl = Get-Content -LiteralPath (Join-Path $EngineDir 'pe-install.cmd') -Raw -Encoding UTF8
  $d = $c.Disk
  $map = @{
    '@@BUILD_ID@@' = $BuildId; '@@TARGET@@' = "$($d.Target)"; '@@FIRMWARE@@' = $d.Firmware
    '@@IF_MULTIPLE@@' = $d.IfMultipleDisks; '@@MIN_GB@@' = "$($d.MinSizeGB)"; '@@IF_NOT_BLANK@@' = $d.IfNotBlank
    '@@EFI_MB@@' = "$($d.EfiMB)"; '@@RECOVERY_MB@@' = "$($d.RecoveryMB)"; '@@WINDOWS_GB@@' = "$($d.WindowsSizeGB)"
    '@@DATA_LABEL@@' = ($d.DataLabel -replace '[^A-Za-z0-9 _-]', '')
  }
  foreach ($k in $map.Keys) { $tpl = $tpl.Replace($k, $map[$k]) }
  if ($tpl -match '@@[A-Z_]+@@') { Die "pe-install.cmd has an unfilled token: $($Matches[0])" }
  return $tpl
}

# ------------------------------------------------------------------ provisioning payload
function Write-TextFile([string]$Path, [string]$Text, [switch]$Crlf) {
  if ($Crlf) { $Text = ($Text -replace "`r?`n", "`r`n") }
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

$script:StageCount = 0
function Add-Payload([string]$PayloadDir, [string]$Source, [string]$Sub) {
  # Copy a file or folder into the payload. Returns its path relative to the payload.
  if (-not $Source) { return '' }
  if (-not (Test-Path -LiteralPath $Source)) { Die "File or folder not found: $Source" }
  $script:StageCount++
  $name = Split-Path -Leaf $Source
  $rel = Join-Path $Sub ('{0:d3}-{1}' -f $script:StageCount, $name)
  if (-not $Plan) {
    $dest = Join-Path $PayloadDir $rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force
  }
  return ($rel -replace '/', '\')
}

function ConvertTo-PlainData($node) {
  # A deep copy that JSON can carry, keeping one-item lists as lists
  if ($node -is [hashtable]) {
    $o = [ordered]@{}
    foreach ($k in ($node.Keys | Sort-Object)) { $o[$k] = ConvertTo-PlainData $node[$k] }
    return $o
  }
  if ($node -is [array]) { return , @($node | ForEach-Object { ConvertTo-PlainData $_ }) }
  return $node
}

function New-ProvisionData($c, [string]$PayloadDir, [string]$BuildId) {
  $d = ConvertTo-PlainData $c
  # What the PC doesn't need
  foreach ($k in 'Source', 'Output', 'Boot', 'Disk', 'Offline', 'Drivers', 'Abstract') { [void]$d.Remove($k) }
  $d['BuildId'] = $BuildId
  $d['Built'] = (Get-Date -Format s)

  # Every local file the PC will need moves into the payload
  $d.Identity.NameMap = Add-Payload $PayloadDir $c.Identity.NameMap 'data'
  $d.Network.Wifi = @(@($c.Network.Wifi) | Where-Object { $_ } | ForEach-Object { Add-Payload $PayloadDir $_ 'wifi' })
  $d.Domain.Ppkg = @(@($c.Domain.Ppkg) | Where-Object { $_ } | ForEach-Object { Add-Payload $PayloadDir $_ 'ppkg' })
  $d.Registry.Import = @(@($c.Registry.Import) | Where-Object { $_ } | ForEach-Object { Add-Payload $PayloadDir $_ 'registry' })
  $d.UserSetup.Scripts = @(@($c.UserSetup.Scripts) | Where-Object { $_ } | ForEach-Object { Add-Payload $PayloadDir $_ 'user' })
  $d.Security.SecurityTemplate = Add-Payload $PayloadDir $c.Security.SecurityTemplate 'data'
  foreach ($cert in @($d.Security.Certificates)) { if ($cert) { $cert.File = Add-Payload $PayloadDir $cert.File 'certs' } }
  foreach ($p in @($d.Printers)) { if ($p -and $p.DriverPath) { $p.DriverPath = Add-Payload $PayloadDir $p.DriverPath 'printers' } }
  foreach ($stage in 'Early', 'Late') {
    foreach ($s in @($d.Scripts[$stage])) { if ($s) { $s.Path = Add-Payload $PayloadDir $s.Path 'scripts' } }
  }
  foreach ($a in @($d.Apps)) {
    if ($a -and (Test-PathIsLocal $a.Source)) { $a.Source = Add-Payload $PayloadDir $a.Source 'apps' }
  }
  $d['PerModelDrivers'] = @(@($c.Drivers.PerModel) | Where-Object { $_ } | ForEach-Object {
      @{ Match = $_.Match; Path = (Add-Payload $PayloadDir $_.Path 'drivers') }
    })
  return $d
}

# ------------------------------------------------------------------ tools (Windows only)
function Test-Admin {
  $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-Oscdimg {
  $c = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
  $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
  foreach ($r in $roots) {
    $p = Join-Path $r "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$arch\Oscdimg\oscdimg.exe"
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Invoke-Tool([string]$Exe, [string[]]$ToolArgs, [int[]]$OkCodes = @(0)) {
  Info "$([IO.Path]::GetFileName($Exe)) $($ToolArgs -join ' ')"
  # Under 'Stop', Windows PowerShell treats a tool's stderr as a terminating error
  $ErrorActionPreference = 'Continue'
  $out = & $Exe @ToolArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  Add-Content -LiteralPath $script:BuildLog -Value ("> $Exe " + ($ToolArgs -join ' ')), ($out | Out-String)
  if ($OkCodes -notcontains $code) {
    ($out | Select-Object -Last 12) | ForEach-Object { Write-Host "    $_" }
    Die "$([IO.Path]::GetFileName($Exe)) failed with exit code $code. See $($script:BuildLog)"
  }
}

function Dism([string[]]$ToolArgs) {
  Invoke-Tool "$env:SystemRoot\System32\dism.exe" (@('/English') + $ToolArgs)
}

function Get-WimImages([string]$Wim) {
  $ErrorActionPreference = 'Continue'
  $out = & "$env:SystemRoot\System32\dism.exe" /English /Get-WimInfo "/WimFile:$Wim" 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($code -ne 0) { Die "dism can't read $Wim" }
  $images = @(); $idx = $null
  foreach ($l in $out) {
    if ("$l" -match '^Index : (\d+)') { $idx = [int]$Matches[1] }
    elseif ("$l" -match '^Name : (.+)$' -and $idx) { $images += [pscustomobject]@{ Index = $idx; Name = $Matches[1].Trim() } }
  }
  return $images
}

function Find-InstallImage([string]$Root) {
  foreach ($n in 'install.wim', 'install.esd') {
    $p = Join-Path $Root "sources\$n"
    if (Test-Path -LiteralPath $p) { return $p }
  }
  Die "No sources\install.wim or install.esd in $Root. Is it a Windows install ISO?"
}

function Mount-Iso([string]$Iso) {
  $img = Mount-DiskImage -ImagePath $Iso -PassThru
  $letter = ($img | Get-Volume).DriveLetter
  if (-not $letter) { Dismount-DiskImage -ImagePath $Iso | Out-Null; Die "Couldn't mount $Iso" }
  return "${letter}:\"
}

function Get-WindowsFamilyFolder([string]$Edition) {
  switch -Regex ($Edition) {
    'Server 2025' { return '2k25' } 'Server 2022' { return '2k22' } 'Server 2019' { return '2k19' }
    'Windows 11' { return 'w11' } 'Windows 10' { return 'w10' }
  }
  Warn "Couldn't tell the Windows version from '$Edition'; using Windows 11 VirtIO drivers."
  return 'w11'
}

# ------------------------------------------------------------------ offline servicing
function Set-OfflineReg($Mount, $Items) {
  $hives = @{ SOFTWARE = 'Windows\System32\config\SOFTWARE'; SYSTEM = 'Windows\System32\config\SYSTEM'; NTUSER = 'Users\Default\NTUSER.DAT' }
  $root = @{ SOFTWARE = 'WI_SOFTWARE'; SYSTEM = 'WI_SYSTEM'; NTUSER = 'WI_NTUSER' }
  foreach ($h in @($Items | ForEach-Object { $_.Hive } | Sort-Object -Unique)) {
    Invoke-Tool "$env:SystemRoot\System32\reg.exe" @('load', "HKLM\$($root[$h])", (Join-Path $Mount $hives[$h]))
    try {
      foreach ($r in @($Items | Where-Object { $_.Hive -eq $h })) {
        $key = "HKLM\$($root[$h])\$($r.Key)"
        $type = if ($r.Type) { $r.Type } else { 'REG_DWORD' }
        Invoke-Tool "$env:SystemRoot\System32\reg.exe" @('add', $key, '/v', $r.Name, '/t', $type, '/d', "$($r.Value)", '/f')
      }
    } finally {
      [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Seconds 2
      Invoke-Tool "$env:SystemRoot\System32\reg.exe" @('unload', "HKLM\$($root[$h])")
    }
  }
}

function Invoke-OfflineServicing($c, [string]$Mount, [string]$PayloadDir, [string]$DriverStage) {
  $o = $c.Offline
  foreach ($u in @($o.Updates | Where-Object { $_ })) {
    # A folder is handed to DISM whole, so checkpoint updates install in the right order
    Section "Update: $(Split-Path -Leaf $u)"
    Dism @("/Image:$Mount", '/Add-Package', "/PackagePath:$u")
  }
  if (@($o.Updates | Where-Object { $_ }).Count -and $o.ResetBase) {
    Dism @("/Image:$Mount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
  }

  $drv = @(@($c.Drivers.Image) | Where-Object { $_ })
  if ($DriverStage) { $drv += $DriverStage }
  if ($drv.Count) {
    Section 'Drivers'
    foreach ($p in $drv) { Dism @("/Image:$Mount", '/Add-Driver', "/Driver:$p", '/Recurse') }
    Ok "$($drv.Count) driver source(s) added"
  }

  $patterns = @($o.RemoveApps | Where-Object { $_ })
  if ($patterns.Count) {
    Section 'Removing built-in apps'
    $apps = Get-AppxProvisionedPackage -Path $Mount
    foreach ($a in $apps) {
      foreach ($p in $patterns) {
        if ($a.DisplayName -like $p) {
          Remove-AppxProvisionedPackage -Path $Mount -PackageName $a.PackageName | Out-Null
          Ok $a.DisplayName
          break
        }
      }
    }
  }

  foreach ($cap in @($o.RemoveCapabilities | Where-Object { $_ })) { Dism @("/Image:$Mount", '/Remove-Capability', "/CapabilityName:$cap") }
  foreach ($cap in @($o.AddCapabilities | Where-Object { $_ })) {
    if (-not $o.CapabilitySource) { Die "Offline.AddCapabilities needs Offline.CapabilitySource (the Languages and Optional Features ISO, unpacked)." }
    Dism @("/Image:$Mount", '/Add-Capability', "/CapabilityName:$cap", "/Source:$($o.CapabilitySource)", '/LimitAccess')
  }
  foreach ($f in @($o.DisableFeatures | Where-Object { $_ })) { Dism @("/Image:$Mount", '/Disable-Feature', "/FeatureName:$f") }
  foreach ($f in @($o.EnableFeatures | Where-Object { $_ })) {
    $src = Join-Path $script:MediaDir 'sources\sxs'
    $a = @("/Image:$Mount", '/Enable-Feature', "/FeatureName:$f", '/All')
    if (Test-Path -LiteralPath $src) { $a += "/Source:$src"; $a += '/LimitAccess' }
    Dism $a
  }
  if ($o.AppAssociations) { Dism @("/Image:$Mount", "/Import-DefaultAppAssociations:$($o.AppAssociations)") }

  Section 'Files and branding'
  foreach ($f in @($o.Files | Where-Object { $_ })) {
    $dest = Join-Path $Mount ($f.Target -replace '^[A-Za-z]:\\', '' -replace '^\\', '')
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath $f.Source -Destination $dest -Recurse -Force
    Ok $f.Target
  }
  $shell = Join-Path $Mount 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
  if ($o.StartLayout -or $o.TaskbarLayout) { New-Item -ItemType Directory -Path $shell -Force | Out-Null }
  if ($o.StartLayout) { Copy-Item -LiteralPath $o.StartLayout -Destination (Join-Path $shell 'LayoutModification.json') -Force }
  if ($o.TaskbarLayout) { Copy-Item -LiteralPath $o.TaskbarLayout -Destination (Join-Path $shell 'LayoutModification.xml') -Force }

  $reg = New-Object System.Collections.ArrayList
  foreach ($r in @($o.Registry | Where-Object { $_ })) { [void]$reg.Add($r) }
  $brand = Join-Path $Mount 'Windows\Web\Brand'
  $csp = 'Microsoft\Windows\CurrentVersion\PersonalizationCSP'
  function Add-Reg($hive, $key, $name, $type, $value) { [void]$reg.Add(@{ Hive = $hive; Key = $key; Name = $name; Type = $type; Value = $value }) }
  if ($o.Wallpaper) {
    New-Item -ItemType Directory -Path $brand -Force | Out-Null
    $n = 'wallpaper' + [IO.Path]::GetExtension($o.Wallpaper)
    Copy-Item -LiteralPath $o.Wallpaper -Destination (Join-Path $brand $n) -Force
    Add-Reg SOFTWARE $csp 'DesktopImagePath' 'REG_SZ' "C:\Windows\Web\Brand\$n"
    Add-Reg SOFTWARE $csp 'DesktopImageUrl' 'REG_SZ' "C:\Windows\Web\Brand\$n"
    Add-Reg SOFTWARE $csp 'DesktopImageStatus' 'REG_DWORD' 1
  }
  if ($o.LockScreen) {
    New-Item -ItemType Directory -Path $brand -Force | Out-Null
    $n = 'lockscreen' + [IO.Path]::GetExtension($o.LockScreen)
    Copy-Item -LiteralPath $o.LockScreen -Destination (Join-Path $brand $n) -Force
    Add-Reg SOFTWARE $csp 'LockScreenImagePath' 'REG_SZ' "C:\Windows\Web\Brand\$n"
    Add-Reg SOFTWARE $csp 'LockScreenImageUrl' 'REG_SZ' "C:\Windows\Web\Brand\$n"
    Add-Reg SOFTWARE $csp 'LockScreenImageStatus' 'REG_DWORD' 1
  }
  $oemKey = 'Microsoft\Windows\CurrentVersion\OEMInformation'
  foreach ($f in 'Manufacturer', 'Model', 'SupportUrl', 'SupportPhone', 'SupportHours') {
    if ($o.Oem[$f]) { Add-Reg SOFTWARE $oemKey $f 'REG_SZ' $o.Oem[$f] }
  }
  if ($o.Oem.Logo) {
    Copy-Item -LiteralPath $o.Oem.Logo -Destination (Join-Path $Mount 'Windows\System32\oemlogo.bmp') -Force
    Add-Reg SOFTWARE $oemKey 'Logo' 'REG_SZ' 'C:\Windows\System32\oemlogo.bmp'
  }
  if ($reg.Count) { Set-OfflineReg $Mount $reg; Ok "$($reg.Count) registry value(s) set offline" }

  # The payload, and a SetupComplete.cmd as a second way to start provisioning
  Copy-Item -Path (Join-Path $PayloadDir '*') -Destination (New-Item -ItemType Directory -Path (Join-Path $Mount 'WinImage') -Force).FullName -Recurse -Force
  $sc = "@echo off`r`nrem Written by Build-WindowsImage.ps1. A fallback: the task normally comes from the specialize pass.`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%SystemDrive%\WinImage\Register-Provision.ps1`"`r`n"
  Write-TextFile (Join-Path $Mount 'Windows\Setup\Scripts\SetupComplete.cmd') $sc
  Ok 'Provisioning payload in C:\WinImage'
}

function Invoke-BootServicing($c, [string]$MediaDir, [string]$WorkRoot, [string]$PeScript, [string]$DriverStage) {
  $bootWim = Join-Path $MediaDir 'sources\boot.wim'
  $images = @(Get-WimImages $bootWim)
  $index = if ($images.Count -ge 2) { 2 } else { 1 }
  $mount = Join-Path $WorkRoot 'mount-boot'
  New-Item -ItemType Directory -Path $mount -Force | Out-Null
  $script:Mounted = $mount
  Dism @('/Mount-Image', "/ImageFile:$bootWim", "/Index:$index", "/MountDir:$mount")
  $drv = @(@($c.Drivers.Boot) | Where-Object { $_ })
  if ($DriverStage) { $drv += $DriverStage }
  foreach ($p in $drv) { Dism @("/Image:$mount", '/Add-Driver', "/Driver:$p", '/Recurse') }
  if ($c.Disk.Method -eq 'Script') { Write-TextFile (Join-Path $mount 'winimage\pe-install.cmd') $PeScript -Crlf }
  Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit')
  $script:Mounted = $null
  Ok "Setup's boot image: $($drv.Count) driver source(s)$(if ($c.Disk.Method -eq 'Script') { ', disk script' })"
}

# ------------------------------------------------------------------ output
function Write-Iso($c, [string]$MediaDir, [string]$Out, [string]$Oscdimg) {
  $etfs = Join-Path $MediaDir 'boot\etfsboot.com'
  $efiName = if ($c.Boot.PressAnyKey) { 'efisys.bin' } else { 'efisys_noprompt.bin' }
  $efi = Join-Path $MediaDir "efi\microsoft\boot\$efiName"
  if (-not (Test-Path -LiteralPath $efi)) {
    $efi = Join-Path $MediaDir 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path -LiteralPath $efi)) { Die 'No UEFI boot image in the ISO.' }
    Warn 'No efisys_noprompt.bin in this ISO: UEFI boot will still ask for a key press.'
  }
  if (-not $c.Boot.PressAnyKey) { Remove-Item (Join-Path $MediaDir 'boot\bootfix.bin') -Force -ErrorAction SilentlyContinue }
  $label = if ($c.Output.VolumeLabel) { $c.Output.VolumeLabel } else { ($c.Name.ToUpper() -replace '[^A-Z0-9_]', '_') }
  if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
  $bootdata = if (Test-Path -LiteralPath $etfs) { "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi" } else { "-bootdata:1#pEF,e,b$efi" }
  Invoke-Tool $Oscdimg @('-m', '-o', '-u2', '-udfver102', $bootdata, "-l$label", $MediaDir, $Out)
  Ok "$([math]::Round((Get-Item -LiteralPath $Out).Length / 1GB, 2)) GB written to $Out"
}

function Get-UsbDisks { return @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem }) }

function Write-Usb($c, [string]$MediaDir, [int]$Number) {
  $disk = Get-Disk -Number $Number
  if ($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem) { Die "Disk $Number is not a USB disk this tool will write to (bus $($disk.BusType))." }
  $need = (Get-ChildItem -LiteralPath $MediaDir -Recurse -File | Measure-Object Length -Sum).Sum
  if ($disk.Size -lt ($need * 1.05)) { Die "Disk $Number is too small: it needs $([math]::Ceiling($need / 1GB)) GB." }

  Section "USB disk $Number"
  Write-Host "  $($disk.FriendlyName), $([math]::Round($disk.Size / 1GB)) GB. Everything on it will be erased." -ForegroundColor Yellow
  $ans = Read-Host "  Type the disk's number ($Number) followed by ERASE, like ${Number}ERASE"
  if ($ans -cne "${Number}ERASE") { Die 'Cancelled. The USB disk was not touched.' }

  $disk | Set-Disk -IsReadOnly $false -ErrorAction SilentlyContinue
  $disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
  Initialize-Disk -Number $Number -PartitionStyle MBR -ErrorAction SilentlyContinue
  # Windows only formats FAT32 up to 32 GB, and UEFI firmware only reads FAT32
  $size = [uint64][Math]::Min([double]$disk.Size - 1MB, [double]32GB)
  $part = New-Partition -DiskNumber $Number -Size $size -IsActive -AssignDriveLetter
  $label = ($c.Name.ToUpper() -replace '[^A-Z0-9]', '') + 'WINIMAGE'
  $label = $label.Substring(0, [Math]::Min(11, $label.Length))
  Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $label -Confirm:$false | Out-Null
  $letter = (Get-Partition -DiskNumber $Number -PartitionNumber $part.PartitionNumber).DriveLetter
  if (-not $letter) { Die 'The USB partition got no drive letter.' }
  $root = "${letter}:\"

  $wim = Join-Path $MediaDir 'sources\install.wim'
  $tmp = Join-Path (Split-Path -Parent $MediaDir) 'swm'
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $split = (Get-Item -LiteralPath $wim).Length -ge 3900MB
  if ($split) {
    # FAT32 can't hold a 4 GB file. The disk script and Setup both read split images.
    Dism @('/Split-Image', "/ImageFile:$wim", "/SWMFile:$(Join-Path $tmp 'install.swm')", '/FileSize:3800')
  }
  $rcArgs = @($MediaDir, $root, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1')
  if ($split) { $rcArgs += @('/XF', 'install.wim') }
  Invoke-Tool "$env:SystemRoot\System32\robocopy.exe" $rcArgs @(0, 1, 2, 3)
  if ($split) { Invoke-Tool "$env:SystemRoot\System32\robocopy.exe" @($tmp, (Join-Path $root 'sources'), 'install*.swm', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1') @(0, 1, 2, 3) }
  Remove-Item -LiteralPath $tmp -Recurse -Force
  $bootsect = Join-Path $MediaDir 'boot\bootsect.exe'
  if (Test-Path -LiteralPath $bootsect) { Invoke-Tool $bootsect @('/nt60', "${letter}:", '/mbr') }
  if ($AllowWipe) {
    Write-TextFile (Join-Path $root 'ALLOW-WIPE.txt') "While this file exists, this stick erases PCs that already have partitions.`r`nDelete it to turn that off.`r`n"
    Warn "ALLOW-WIPE.txt is on the stick: it will erase any PC it boots on. Delete the file once the rollout is done."
  }
  Ok "USB disk $Number ready (${letter}:)"
}

# ------------------------------------------------------------------ one build
function Save-Credentials($c, [string]$Folder, [string]$Id) {
  if (-not $script:Credentials.Count) { return }
  $f = Join-Path $Folder "$($c.Name).passwords.txt"
  $lines = @("# $($c.Name), build $Id, $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Keep this private.")
  $lines += @($script:Credentials | ForEach-Object { '{0,-44} {1}' -f $_.Label, $_.Value })
  Set-Content -LiteralPath $f -Value $lines -Encoding UTF8
  if ($OnWindows) {
    # Only the person building, SYSTEM, and administrators can read it
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & "$env:SystemRoot\System32\icacls.exe" $f /inheritance:r /grant:r "*${me}:F" '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
  }
  Ok "Passwords saved to $f, readable by you and administrators only"
}

function Invoke-Build([string]$File) {
  $script:Credentials.Clear(); $script:StageCount = 0; $script:Warnings.Clear()
  $c = New-EffectiveConfig $File
  if ($ShowConfig) {
    Section "$($c.Name): merged config"
    (ConvertTo-PlainData (Hide-Secrets $c)) | ConvertTo-Json -Depth 20 | Write-Host
    return
  }
  Section "$($c.Name): checking the config"
  Test-Config $c
  Ok 'Config is valid'

  $outDir = if ($OutputFolder) { $OutputFolder } else { $c.Output.Folder }
  $outDir = [IO.Path]::GetFullPath($outDir)
  $buildId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmm'), ([guid]::NewGuid().ToString('N').Substring(0, 6))

  $script:AdminPassword = Resolve-Secret $c.Accounts.Admin.Password "Local account $($c.Accounts.Admin.Name)"
  foreach ($u in @($c.Accounts.Users)) { if ($u) { $u.Password = Resolve-Secret $u.Password "Local account $($u.Name)" } }
  if ($c.Accounts.AutoLogon.Password) { $c.Accounts.AutoLogon.Password = Resolve-Secret $c.Accounts.AutoLogon.Password "Auto logon $($c.Accounts.AutoLogon.User)" }
  if ($c.Domain.Password) { $c.Domain.Password = Resolve-Secret $c.Domain.Password "Domain join $($c.Domain.User)" }
  if ($c.Network.Share.Password) { $c.Network.Share.Password = Resolve-Secret $c.Network.Share.Password "Share $($c.Network.Share.User)" }
  foreach ($cert in @($c.Security.Certificates)) { if ($cert -and $cert.Password) { $cert.Password = Resolve-Secret $cert.Password "Certificate $(Split-Path -Leaf $cert.File)" } }
  # The admin account is created by the answer file; the engine only keeps it non-expiring
  $c.Accounts.Admin.Password = ''

  if ($Plan) {
    $planDir = Join-Path $outDir "$($c.Name)-plan"
    Section "Plan: writing what would go on the media to $planDir"
    $arch = 'amd64'
    $payload = Join-Path $planDir 'WinImage'
    Write-TextFile (Join-Path $planDir 'autounattend.xml') (New-AnswerFile $c $arch $buildId) -Crlf
    if ($c.Disk.Method -eq 'Script') { Write-TextFile (Join-Path $planDir 'pe-install.cmd') (New-PeScript $c $buildId) -Crlf }
    $data = New-ProvisionData $c $payload $buildId
    Write-TextFile (Join-Path $payload 'provision.json') ($data | ConvertTo-Json -Depth 20)
    Ok "autounattend.xml$(if ($c.Disk.Method -eq 'Script') { ', pe-install.cmd' }), WinImage\provision.json"
    Info 'Nothing was mounted or changed. Passwords in these files are masked.'
    return
  }

  # A real build needs Windows, and mounting images needs an administrator
  if (-not $OnWindows) { Die 'Building needs Windows. On this system only -Plan and -ShowConfig work.' }
  if (-not (Test-Admin)) { Die 'Run this in an administrator PowerShell (mounting images needs it). -Plan works without.' }
  $oscdimg = $null
  if (@($c.Output.Types) -contains 'ISO') {
    $oscdimg = Find-Oscdimg
    if (-not $oscdimg) { Die 'oscdimg.exe not found. Run .\Build-WindowsImage.ps1 -InstallTools, which installs the Deployment Tools from the Windows ADK.' }
  }

  $work = if ($WorkDir) { Join-Path $WorkDir $c.Name } else { Join-Path $outDir "work\$($c.Name)" }
  $media = Join-Path $work 'media'; $mount = Join-Path $work 'mount'; $payload = Join-Path $work 'payload'
  $script:MediaDir = $media
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  New-Item -ItemType Directory -Path $media, $mount, $payload -Force | Out-Null
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  $script:BuildLog = Join-Path $outDir "$($c.Name).build.log"
  Set-Content -LiteralPath $script:BuildLog -Value "Build-WindowsImage.ps1 $Version, $($c.Name), build $buildId, $(Get-Date -Format s)"
  $script:Mounted = $null; $isoMounted = $null

  try {
    Section 'Copying the source'
    $src = $c.Source.Folder
    if ($c.Source.Iso) {
      if (-not (Test-Path -LiteralPath $c.Source.Iso)) { Die "ISO not found: $($c.Source.Iso)" }
      $src = Mount-Iso $c.Source.Iso; $isoMounted = $c.Source.Iso
    }
    Invoke-Tool "$env:SystemRoot\System32\robocopy.exe" @($src, $media, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1', '/XF', 'install.wim', 'install.esd') @(0, 1, 2, 3)
    & "$env:SystemRoot\System32\attrib.exe" -r "$media\*" /s /d | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $media 'sources\boot.wim'))) { Die 'No sources\boot.wim in the source.' }
    $srcImage = Find-InstallImage $src
    $found = @(Get-WimImages $srcImage)
    $pick = $found | Where-Object { $_.Name -eq $c.Source.Edition } | Select-Object -First 1
    if (-not $pick) {
      $found | ForEach-Object { Info $_.Name }
      Die "Edition '$($c.Source.Edition)' isn't in the source."
    }
    $wim = Join-Path $work 'install.wim'
    Dism @('/Export-Image', "/SourceImageFile:$srcImage", "/SourceIndex:$($pick.Index)", "/DestinationImageFile:$wim", '/Compress:max', '/CheckIntegrity')
    Ok "Kept only '$($c.Source.Edition)'"
    if ($isoMounted) { Dismount-DiskImage -ImagePath $isoMounted | Out-Null; $isoMounted = $null }

    $archNum = (Get-WindowsImage -ImagePath $wim -Index 1).Architecture
    $arch = if ($archNum -eq 12) { 'arm64' } else { 'amd64' }

    # VirtIO: drivers for this Windows, and the guest tools as first apps
    $virtStage = $null
    if ($c.Drivers.VirtIoIso) {
      Section 'VirtIO'
      $vl = Mount-Iso $c.Drivers.VirtIoIso; $isoMounted = $c.Drivers.VirtIoIso
      $folder = Get-WindowsFamilyFolder $c.Source.Edition
      $virtStage = Join-Path $work 'virtio'
      $archDir = if ($arch -eq 'arm64') { 'ARM64' } else { 'amd64' }
      foreach ($d in 'viostor', 'vioscsi', 'NetKVM', 'Balloon', 'vioserial', 'qxldod', 'viogpudo') {
        $from = Join-Path $vl "$d\$folder\$archDir"
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (New-Item -ItemType Directory -Path (Join-Path $virtStage $d) -Force).FullName -Recurse -Force }
      }
      $msis = @()
      foreach ($m in 'virtio-win-gt-x64.msi', 'guest-agent\qemu-ga-x86_64.msi') {
        $mf = Join-Path $vl $m
        if (Test-Path -LiteralPath $mf) {
          $cp = Join-Path $work (Split-Path -Leaf $mf); Copy-Item -LiteralPath $mf -Destination $cp -Force
          $msis += @{ Name = (Split-Path -Leaf $mf); Source = $cp; Required = $false }
        }
      }
      $c.Apps = @($msis) + @($c.Apps | Where-Object { $_ })
      Dismount-DiskImage -ImagePath $isoMounted | Out-Null; $isoMounted = $null
      Ok "VirtIO drivers for $folder, $($msis.Count) guest tool installer(s)"
    }

    Section 'Provisioning payload'
    $data = New-ProvisionData $c $payload $buildId
    Write-TextFile (Join-Path $payload 'provision.json') ($data | ConvertTo-Json -Depth 20)
    Copy-Item -LiteralPath (Join-Path $EngineDir 'Provision.ps1'), (Join-Path $EngineDir 'Register-Provision.ps1') -Destination $payload -Force
    Set-Content -LiteralPath (Join-Path $payload 'build.id') -Value $buildId -Encoding Ascii
    Ok "$(@($c.Apps).Count) app(s), $(@($c.Printers).Count) printer(s), $(@($c.Accounts.Users).Count) extra account(s)"

    Section 'Servicing install.wim'
    $script:Mounted = $mount
    Dism @('/Mount-Image', "/ImageFile:$wim", '/Index:1', "/MountDir:$mount")
    Invoke-OfflineServicing $c $mount $payload $virtStage
    Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit')
    $script:Mounted = $null

    Section 'Compacting'
    $final = Join-Path $media 'sources\install.wim'
    Dism @('/Export-Image', "/SourceImageFile:$wim", '/SourceIndex:1', "/DestinationImageFile:$final", '/Compress:max')
    Remove-Item -LiteralPath $wim -Force
    Ok "install.wim is $([math]::Round((Get-Item -LiteralPath $final).Length / 1GB, 2)) GB"

    Section "Setup's boot image"
    $pe = if ($c.Disk.Method -eq 'Script') { New-PeScript $c $buildId } else { '' }
    Invoke-BootServicing $c $media $work $pe $virtStage

    Section 'Answer file'
    Write-TextFile (Join-Path $media 'autounattend.xml') (New-AnswerFile $c $arch $buildId) -Crlf
    Set-Content -LiteralPath (Join-Path $media "winimage-$buildId.id") -Value $c.Name -Encoding Ascii
    Ok "autounattend.xml, disk method $($c.Disk.Method)"

    Section 'Output'
    $types = @($c.Output.Types)
    if ($types -contains 'ISO') { Write-Iso $c $media (Join-Path $outDir "$($c.Name).iso") $oscdimg }
    if ($types -contains 'WIM') {
      Copy-Item -LiteralPath $final -Destination (Join-Path $outDir "$($c.Name).wim") -Force
      Copy-Item -LiteralPath (Join-Path $media 'autounattend.xml') -Destination (Join-Path $outDir "$($c.Name).unattend.xml") -Force
      Ok "$($c.Name).wim and .unattend.xml, for WDS, MDT, or DISM"
    }
    if ($UsbDisk -ge 0 -or $types -contains 'USB') {
      if ($UsbDisk -lt 0) { Warn 'Output.Types has USB, but no -UsbDisk was given. Run with -UsbDisk N to write one.' }
      else { Write-Usb $c $media $UsbDisk }
    }
    Save-Credentials $c $outDir $buildId
    if ($types -contains 'Folder') {
      $dest = Join-Path $outDir "$($c.Name)-media"
      if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
      Move-Item -LiteralPath $media -Destination $dest
      Ok "Media folder: $dest"
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  } finally {
    if ($script:Mounted) {
      Write-Host '  Discarding the open image...' -ForegroundColor DarkGray
      & "$env:SystemRoot\System32\dism.exe" /English /Quiet /Unmount-Image "/MountDir:$script:Mounted" /Discard | Out-Null
    }
    if ($isoMounted) { Dismount-DiskImage -ImagePath $isoMounted -ErrorAction SilentlyContinue | Out-Null }
  }

  Section "$($c.Name) is ready"
  Info "Build $buildId. Log: $script:BuildLog"
  Info 'The media holds passwords. Store it like a key to the clinic.'
  if ($script:Warnings.Count) { Write-Host "  $($script:Warnings.Count) warning(s) above." -ForegroundColor Yellow }
}

# ------------------------------------------------------------------ entry
try {
  switch ($PSCmdlet.ParameterSetName) {
    'Editions' {
      if (-not $OnWindows) { Die 'This needs Windows.' }
      $iso = (Resolve-Path -LiteralPath $ListEditions).Path
      $root = Mount-Iso $iso
      try { Get-WimImages (Find-InstallImage $root) | Format-Table Index, Name -AutoSize | Out-String | Write-Host }
      finally { Dismount-DiskImage -ImagePath $iso | Out-Null }
    }
    'Usb' {
      if (-not $OnWindows) { Die 'This needs Windows.' }
      Get-UsbDisks | Select-Object Number, FriendlyName, @{ n = 'GB'; e = { [math]::Round($_.Size / 1GB) } } | Format-Table -AutoSize | Out-String | Write-Host
    }
    'Tools' {
      if (-not $OnWindows) { Die 'This needs Windows.' }
      if (Find-Oscdimg) { Ok 'oscdimg is already installed.'; break }
      if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { Die 'winget not found. Install the Windows ADK by hand and tick only Deployment Tools.' }
      & winget.exe install --id Microsoft.WindowsADK --exact --accept-package-agreements --accept-source-agreements --override '/quiet /norestart /features OptionId.DeploymentTools'
      if (Find-Oscdimg) { Ok 'oscdimg installed.' } else { Die 'oscdimg still not found after installing the ADK.' }
    }
    default {
      foreach ($f in (Get-ConfigFiles $Config)) { Invoke-Build $f }
    }
  }
} catch {
  Write-Host "  [x]  $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
