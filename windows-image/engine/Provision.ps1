<#
  Provision.ps1: the first-boot engine. Runs as SYSTEM from a startup task, works
  through provision.json a step at a time, and records each finished step, so a reboot
  in the middle simply carries on at the next one. When everything is done it removes
  the task, the payload, and every copy of the passwords, keeping only the log and a
  report in C:\ProgramData\WinImage.
#>
$ErrorActionPreference = 'Continue'
$Root = "$env:SystemDrive\WinImage"
$Keep = "$env:ProgramData\WinImage"
$LogFile = "$Keep\provision.log"
$StateFile = "$Keep\state.json"
New-Item -ItemType Directory -Path $Keep -Force | Out-Null

function Log([string]$m) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  Write-Output $line
}

# One copy at a time, even if a startup and a manual run overlap
$Mutex = New-Object Threading.Mutex($false, 'Global\WinImageProvision')
if (-not $Mutex.WaitOne(0)) { exit 0 }

if (-not (Test-Path -LiteralPath "$Root\provision.json")) { Log 'No provision.json: nothing to do.'; exit 0 }
$C = Get-Content -LiteralPath "$Root\provision.json" -Raw -Encoding UTF8 | ConvertFrom-Json

# ------------------------------------------------------------------ state
$State = [pscustomobject]@{ Done = @(); Failed = @(); Items = @(); WuRounds = 0; Started = (Get-Date -Format s) }
if (Test-Path -LiteralPath $StateFile) {
  $s = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
  $State.Done = @($s.Done); $State.Failed = @($s.Failed); $State.Items = @($s.Items); $State.WuRounds = [int]$s.WuRounds; $State.Started = $s.Started
}
function Save-State { $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8 }

function Request-Reboot([string]$why) {
  Log "Restarting: $why"
  Save-State
  & shutdown.exe /r /t 15 /c "Setting up this PC. $why" /d p:4:1
  $Mutex.ReleaseMutex()
  exit 0
}

function Add-Failure([string]$what) {
  Log "FAILED: $what"
  $State.Failed = @($State.Failed) + $what
  Save-State
}

# An item inside a step (one app, one printer) is only done once
function Test-ItemDone([string]$id) { return @($State.Items) -contains $id }
function Set-ItemDone([string]$id) { $State.Items = @($State.Items) + $id; Save-State }

# ------------------------------------------------------------------ helpers
function P([string]$rel) { return (Join-Path $Root $rel) }

function Set-Reg([string]$Key, [string]$Name, $Value, [string]$Type = 'DWord') {
  $names = @{ REG_SZ = 'String'; REG_EXPAND_SZ = 'ExpandString'; REG_DWORD = 'DWord'; REG_QWORD = 'QWord'; REG_MULTI_SZ = 'MultiString'; REG_BINARY = 'Binary' }
  if ($names.ContainsKey($Type)) { $Type = $names[$Type] }
  if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
  New-ItemProperty -Path $Key -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-Model { return (Get-CimInstance Win32_ComputerSystem).Model }

function Test-ModelMatch($patterns) {
  $list = @($patterns | Where-Object { $_ })
  if (-not $list.Count) { return $true }
  $m = Get-Model
  foreach ($p in $list) { if ($m -like $p) { return $true } }
  return $false
}

function Get-ShareDrive {
  # A connection to Network.Share, for those steps that write there
  $sh = $C.Network.Share
  if (-not $sh.Path) { return $null }
  $name = 'WIShare'
  if (Get-PSDrive -Name $name -ErrorAction SilentlyContinue) { return "${name}:" }
  $params = @{ Name = $name; PSProvider = 'FileSystem'; Root = $sh.Path; Scope = 'Script' }
  if ($sh.User) {
    $sec = ConvertTo-SecureString $sh.Password -AsPlainText -Force
    $params.Credential = New-Object Management.Automation.PSCredential($sh.User, $sec)
  }
  New-PSDrive @params | Out-Null
  return "${name}:"
}

function Wait-Network([int]$seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  do {
    $up = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
      Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }
    if ($up) { return $true }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $until)
  return $false
}

function Invoke-Process([string]$File, [string]$ArgLine, [int]$TimeoutMinutes, [string]$WorkDir) {
  $psi = @{ FilePath = $File; PassThru = $true; WindowStyle = 'Hidden' }
  if ($ArgLine) { $psi.ArgumentList = $ArgLine }
  if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
  $p = Start-Process @psi
  [void]$p.Handle   # keeps ExitCode readable after the wait
  if (-not $p.WaitForExit($TimeoutMinutes * 60000)) {
    Log "    timed out after $TimeoutMinutes minutes"
    try { $p.Kill() } catch { }
    return -1
  }
  return $p.ExitCode
}

function Add-AppFailure($a, [string]$what) {
  # An optional app is logged but doesn't count against the build
  if ($a.Required -eq $false) { Log "  Optional app problem: $what" } else { Add-Failure $what }
}

function Install-App($a) {
  $id = "app:$($a.Name)"
  if (Test-ItemDone $id) { return }
  if (-not (Test-ModelMatch $a.OnlyModels)) { Log "  $($a.Name): not for this model"; Set-ItemDone $id; return }
  if ($a.Detect -and (Test-Path -LiteralPath $a.Detect)) { Log "  $($a.Name): already there"; Set-ItemDone $id; return }

  $timeout = if ($a.TimeoutMinutes) { [int]$a.TimeoutMinutes } else { 30 }
  $okCodes = @(0, 3010, 1641) + @($a.SuccessCodes | Where-Object { $null -ne $_ })
  $src = "$($a.Source)"
  $code = 0
  try {
    if ($src -like 'winget:*') {
      $winget = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1
      if (-not $winget) { throw 'winget is not available yet on this PC' }
      $line = "install --id $($src.Substring(7)) --exact --silent --scope machine --accept-package-agreements --accept-source-agreements $($a.Args)"
      $code = Invoke-Process $winget.FullName $line $timeout $winget.DirectoryName
    } else {
      $file = $src
      if ($src -match '^https?://') {
        $file = Join-Path $Keep ('dl-' + [IO.Path]::GetFileName(([Uri]$src).LocalPath))
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $src -OutFile $file -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($hash -ne "$($a.Sha256)".ToUpper()) { Remove-Item -LiteralPath $file -Force; throw "SHA-256 mismatch: got $hash" }
      } else {
        $file = P $src
      }
      if ((Get-Item -LiteralPath $file).PSIsContainer) {
        if (-not $a.Run) { throw 'Source is a folder, so it needs Run' }
        $file = Join-Path $file $a.Run
      }
      $dir = Split-Path -Parent $file
      switch -Wildcard ($file.ToLower()) {
        '*.msi' { $code = Invoke-Process 'msiexec.exe' "/i `"$file`" /qn /norestart $($a.Args)" $timeout $dir }
        '*.msu' { $code = Invoke-Process 'wusa.exe' "`"$file`" /quiet /norestart" $timeout $dir }
        '*.ps1' { $code = Invoke-Process 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$file`" $($a.Args)" $timeout $dir }
        '*.cmd' { $code = Invoke-Process 'cmd.exe' "/c `"`"$file`" $($a.Args)`"" $timeout $dir }
        '*.bat' { $code = Invoke-Process 'cmd.exe' "/c `"`"$file`" $($a.Args)`"" $timeout $dir }
        '*.msix*' { Add-AppxProvisionedPackage -Online -PackagePath $file -SkipLicense -ErrorAction Stop | Out-Null }
        '*.appx*' { Add-AppxProvisionedPackage -Online -PackagePath $file -SkipLicense -ErrorAction Stop | Out-Null }
        default { $code = Invoke-Process $file "$($a.Args)" $timeout $dir }
      }
    }
  } catch {
    Add-AppFailure $a "$($a.Name): $($_.Exception.Message)"
    Set-ItemDone $id
    return
  }

  # Arguments can hold licence keys, so the log shows only the result
  if ($okCodes -notcontains $code) {
    Add-AppFailure $a "$($a.Name): exit code $code"
  } else {
    Log "  $($a.Name): installed (exit code $code)"
    if ($a.Detect -and -not (Test-Path -LiteralPath $a.Detect)) { Add-AppFailure $a "$($a.Name): installer succeeded, but $($a.Detect) isn't there" }
  }
  Set-ItemDone $id
  if ($a.Reboot -eq $true -or ($a.Reboot -ne $false -and ($code -eq 3010 -or $code -eq 1641))) { Request-Reboot "$($a.Name) needs a restart" }
}

function Invoke-UserScript($s) {
  $id = "script:$($s.Path)"
  if (Test-ItemDone $id) { return }
  $code = Invoke-Process 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$(P $s.Path)`" $($s.Args)" 60 $Root
  Log "  $(Split-Path -Leaf $s.Path): exit code $code"
  if ($code -ne 0 -and $code -ne 3010) { Add-Failure "$(Split-Path -Leaf $s.Path): exit code $code" }
  Set-ItemDone $id
  if ($s.Reboot -eq $true -or $code -eq 3010) { Request-Reboot "$(Split-Path -Leaf $s.Path) needs a restart" }
}

function Get-TargetName {
  $bios = Get-CimInstance Win32_BIOS
  $serial = ("$($bios.SerialNumber)" -replace '[^A-Za-z0-9]', '').ToUpper()
  $mac = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object ifIndex | Select-Object -First 1).MacAddress -replace '[^A-Fa-f0-9]', ''
  # Generic boards report a placeholder or a blank instead of a real serial
  if ($serial.Length -lt 4 -or $serial -match '^(DEFAULTSTRING|TOBEFILLEDBYOEM|SYSTEMSERIALNUMBER|NONE|0+)$') { $serial = $mac.ToUpper() }

  if ($C.Identity.NameMap) {
    $row = Import-Csv -LiteralPath (P $C.Identity.NameMap) | Where-Object { ($_.Serial -replace '[^A-Za-z0-9]', '').ToUpper() -eq $serial } | Select-Object -First 1
    if ($row) { return $row.Name }
    Log "  Serial $serial isn't in the name map; using the pattern"
  }
  $n = "$($C.Identity.ComputerName)"
  if ($n -notmatch '[{]') { if ($C.Identity.NameMap) { return $n } else { return $null } }
  $tail = { param($s, $len) if ($s.Length -gt $len) { $s.Substring($s.Length - $len) } else { $s } }
  $n = [regex]::Replace($n, '\{serial:(\d+)\}', { param($m) & $tail $serial ([int]$m.Groups[1].Value) })
  $n = $n.Replace('{serial}', $serial).Replace('{mac}', $mac.ToUpper()).Replace('{name}', "$($C.Name)".ToUpper())
  $n = [regex]::Replace($n, '\{random:(\d+)\}', {
      param($m) -join (1..[int]$m.Groups[1].Value | ForEach-Object { 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[(Get-Random -Maximum 32)] })
    })
  $n = ($n -replace '[^A-Za-z0-9-]', '').Trim('-')
  if ($n.Length -gt 15) {
    Log "  '$n' is over 15 characters; keeping the first 15"
    $n = $n.Substring(0, 15).TrimEnd('-')
  }
  return $n
}

$GroupSids = @{
  'Administrators' = 'S-1-5-32-544'; 'Users' = 'S-1-5-32-545'; 'Guests' = 'S-1-5-32-546'
  'Power Users' = 'S-1-5-32-547'; 'Remote Desktop Users' = 'S-1-5-32-555'; 'Remote Management Users' = 'S-1-5-32-580'
  'Event Log Readers' = 'S-1-5-32-573'; 'Performance Log Users' = 'S-1-5-32-559'; 'Backup Operators' = 'S-1-5-32-551'
}
function Resolve-Group([string]$g) {
  if ($GroupSids.ContainsKey($g)) { return (Get-LocalGroup -SID $GroupSids[$g]).Name }
  return $g
}

# Tweaks are named bundles of settings: Hive 'U' goes to the default user profile
$TweakTable = @{
  NoConsumerApps      = @(@('M', 'SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', 1), @('M', 'SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableSoftLanding', 1), @('M', 'SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableCloudOptimizedContent', 1))
  NoFirstLogonScreens = @(@('M', 'SOFTWARE\Policies\Microsoft\Windows\OOBE', 'DisablePrivacyExperience', 1), @('M', 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'EnableFirstLogonAnimation', 0), @('M', 'SOFTWARE\Policies\Microsoft\Windows\System', 'EnableFirstLogonAnimation', 0))
  NoLockScreenCamera  = @(, @('M', 'SOFTWARE\Policies\Microsoft\Windows\Personalization', 'NoLockScreenCamera', 1))
  NoWidgets           = @(, @('M', 'SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0))
  NoCopilot           = @(@('M', 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1), @('U', 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1))
  NoRecall            = @(, @('M', 'SOFTWARE\Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', 1))
  NoSearchWeb         = @(@('M', 'SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'DisableWebSearch', 1), @('M', 'SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'ConnectedSearchUseWeb', 0))
  NoTelemetryExtras   = @(@('M', 'SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 1), @('M', 'SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo', 'DisabledByGroupPolicy', 1))
  NoOneDriveSetup     = @(, @('M', 'SOFTWARE\Policies\Microsoft\Windows\OneDrive', 'DisableFileSyncNGSC', 1))
  NoDeviceEncryption  = @(, @('M', 'SYSTEM\CurrentControlSet\Control\BitLocker', 'PreventDeviceEncryption', 1))
  ShowFileExtensions  = @(, @('U', 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'HideFileExt', 0))
  ShowHiddenFiles     = @(, @('U', 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Hidden', 1))
  TaskbarLeft         = @(, @('U', 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'TaskbarAl', 0))
  ClassicContextMenu  = @(, @('U', 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32', '(Default)', ''))
  NoTaskbarSearchBox  = @(, @('U', 'Software\Microsoft\Windows\CurrentVersion\Search', 'SearchboxTaskbarMode', 0))
  NoTaskView          = @(, @('U', 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowTaskViewButton', 0))
}

function Set-DefaultUserValues($Items) {
  # Writes into the profile every new user is copied from
  $list = @($Items)
  if (-not $list.Count) { return }
  $hive = 'HKU\WI_DEFAULT'
  & reg.exe load $hive "$env:SystemDrive\Users\Default\NTUSER.DAT" | Out-Null
  if ($LASTEXITCODE -ne 0) { Add-Failure 'Could not load the default user profile'; return }
  try {
    foreach ($i in $list) {
      $type = if ($i.Type) { $i.Type } else { 'REG_DWORD' }
      if ($i.Name -eq '(Default)') { & reg.exe add "$hive\$($i.Key)" /ve /t REG_SZ /d "$($i.Value)" /f | Out-Null }
      else { & reg.exe add "$hive\$($i.Key)" /v $i.Name /t $type /d "$($i.Value)" /f | Out-Null }
      if ($LASTEXITCODE -ne 0) { Add-Failure "Default user value $($i.Key)\$($i.Name)" }
    }
  } finally {
    [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Seconds 2
    & reg.exe unload $hive | Out-Null
  }
}

# ------------------------------------------------------------------ steps
function Step-WaitForSetup {
  # The task first fires while OOBE is still running. Rebooting then would break it.
  $until = (Get-Date).AddMinutes(30)
  do {
    $s = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
    $image = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState
    if ($image -eq 'IMAGE_STATE_COMPLETE' -or ($s.SystemSetupInProgress -eq 0 -and $s.OOBEInProgress -eq 0)) { return }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $until)
  Log 'Setup still reports running after 30 minutes; carrying on'
}

function Step-Holdscreen {
  # Keep people off the PC until it's ready
  $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  Set-Reg $k 'legalnoticecaption' 'This PC is still being set up' 'String'
  Set-Reg $k 'legalnoticetext' 'Please leave it on and wait. It will restart when it is ready to use.' 'String'
}

function Step-PerModelDrivers {
  $model = Get-Model
  Log "  Model: $model"
  foreach ($d in @($C.PerModelDrivers)) {
    if ($d -and $model -like $d.Match) {
      Log "  Drivers for $($d.Match)"
      & pnputil.exe /add-driver "$(P $d.Path)\*.inf" /subdirs /install | Out-Null
    }
  }
}

function Step-Network {
  foreach ($w in @($C.Network.Wifi)) {
    if ($w) { & netsh.exe wlan add profile filename="$(P $w)" user=all | Out-Null }
  }
  foreach ($h in @($C.Network.Hosts)) {
    if ($h) { Add-Content -LiteralPath "$env:SystemRoot\System32\drivers\etc\hosts" -Value "$($h.Ip)`t$($h.Name)" }
  }
  $net = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
  if (@($C.Network.DnsServers).Count) { foreach ($n in $net) { Set-DnsClientServerAddress -InterfaceIndex $n.ifIndex -ServerAddresses @($C.Network.DnsServers) } }
  if ($C.Network.DnsSuffix) { Set-DnsClientGlobalSetting -SuffixSearchList @($C.Network.DnsSuffix) }
  if ($C.Network.Proxy.Server) {
    $proxy = $C.Network.Proxy.Server; $bypass = $C.Network.Proxy.Bypass
    & netsh.exe winhttp set proxy proxy-server="$proxy" bypass-list="$bypass" | Out-Null
    try { Set-MpPreference -ProxyServer "http://$proxy" -ProxyBypass @($bypass -split ';' | Where-Object { $_ -ne '<local>' }) } catch { }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
    Log "  Proxy $proxy"
  }
  if (Wait-Network ([int]$C.Network.WaitSeconds)) { Log '  Network is up' } else { Log '  No network yet; steps that need it may fail' }
}

function Step-Rename {
  $name = Get-TargetName
  if (-not $name -or $name -eq $env:COMPUTERNAME) { return }
  Log "  Renaming to $name"
  Rename-Computer -NewName $name -Force -ErrorAction Stop
  Set-StepDone 'Rename'
  Request-Reboot "New name: $name"
}

function Step-Recovery {
  $out = (& reagentc.exe /enable 2>&1 | Out-String)
  Log "  Recovery: $($out.Trim())"
}

function Step-Certificates {
  foreach ($cert in @($C.Security.Certificates)) {
    if (-not $cert) { continue }
    $store = if ($cert.Store) { $cert.Store } else { 'Root' }
    $file = P $cert.File
    if ($file -match '\.(pfx|p12)$') {
      $sec = ConvertTo-SecureString "$($cert.Password)" -AsPlainText -Force
      Import-PfxCertificate -FilePath $file -CertStoreLocation "Cert:\LocalMachine\$store" -Password $sec | Out-Null
    } else {
      Import-Certificate -FilePath $file -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    }
    Log "  $(Split-Path -Leaf $file) into $store"
  }
}

function Step-Accounts {
  Set-LocalUser -Name $C.Accounts.Admin.Name -PasswordNeverExpires $true -ErrorAction SilentlyContinue
  foreach ($u in @($C.Accounts.Users)) {
    if (-not $u) { continue }
    $sec = ConvertTo-SecureString $u.Password -AsPlainText -Force
    if (Get-LocalUser -Name $u.Name -ErrorAction SilentlyContinue) {
      Set-LocalUser -Name $u.Name -Password $sec
    } else {
      $p = @{ Name = $u.Name; Password = $sec; AccountNeverExpires = $true }
      $p.FullName = if ($u.FullName) { $u.FullName } else { $u.Name }
      if ($u.Description) { $p.Description = $u.Description }
      if ($u.PasswordNeverExpires) { $p.PasswordNeverExpires = $true }
      New-LocalUser @p | Out-Null
    }
    $groups = @($u.Groups | Where-Object { $_ })
    if (-not $groups.Count) { $groups = @('Users') }
    foreach ($g in $groups) { Add-LocalGroupMember -Group (Resolve-Group $g) -Member $u.Name -ErrorAction SilentlyContinue }
    if ($u.MustChangePassword) { & net.exe user $u.Name /logonpasswordchg:yes | Out-Null }
    if ($u.Disabled) { Disable-LocalUser -Name $u.Name }
    Log "  $($u.Name)"
  }
}

function Step-Activation {
  $l = $C.License
  $slmgr = "$env:SystemRoot\System32\slmgr.vbs"
  $key = $l.ActivationKey
  if (-not $key -and $l.UseFirmwareKey) {
    $key = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey
    if ($key) { Log '  Using the key stored in this PC''s firmware' }
  }
  if ($l.KmsHost) { & cscript.exe //nologo $slmgr /skms $l.KmsHost | Out-Null }
  if ($key) { & cscript.exe //nologo $slmgr /ipk $key | Out-Null }
  if ($key -or $l.KmsHost) { & cscript.exe //nologo $slmgr /ato | Out-Null }
  $st = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Select-Object -First 1
  Log "  Licence status: $($st.LicenseStatus) (1 means activated)"
}

function Step-Domain {
  $d = $C.Domain
  foreach ($p in @($d.Ppkg)) {
    if ($p) {
      Install-ProvisioningPackage -PackagePath (P $p) -QuietInstall -ForceInstall -ErrorAction Stop | Out-Null
      Log "  Provisioning package $(Split-Path -Leaf $p)"
    }
  }
  if ($d.Mode -eq 'AD') {
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { return }
    $cred = New-Object Management.Automation.PSCredential($d.User, (ConvertTo-SecureString $d.Password -AsPlainText -Force))
    $p = @{ DomainName = $d.Name; Credential = $cred; Force = $true; ErrorAction = 'Stop' }
    if ($d.OU) { $p.OUPath = $d.OU }
    $tries = 0
    while ($true) {
      $tries++
      try { Add-Computer @p; break }
      catch {
        if ($tries -ge 5) { throw }
        Log "  Join attempt $tries failed: $($_.Exception.Message)"
        Start-Sleep -Seconds 30
      }
    }
    Log "  Joined $($d.Name)"
    Set-StepDone 'Domain'
    Request-Reboot 'Joined the domain'
  }
}

function Step-Security {
  $s = $C.Security
  if ($s.PasswordPolicy.MinLength) { & net.exe accounts /minpwlen:$($s.PasswordPolicy.MinLength) | Out-Null }
  if ($s.PasswordPolicy.MaxAgeDays) { & net.exe accounts /maxpwage:$($s.PasswordPolicy.MaxAgeDays) | Out-Null }
  if ($s.PasswordPolicy.MinAgeDays) { & net.exe accounts /minpwage:$($s.PasswordPolicy.MinAgeDays) | Out-Null }
  if ($s.PasswordPolicy.History) { & net.exe accounts /uniquepw:$($s.PasswordPolicy.History) | Out-Null }
  if ($s.PasswordPolicy.LockoutThreshold) {
    & net.exe accounts /lockoutthreshold:$($s.PasswordPolicy.LockoutThreshold) | Out-Null
    if ($s.PasswordPolicy.LockoutMinutes) { & net.exe accounts /lockoutwindow:$($s.PasswordPolicy.LockoutMinutes) /lockoutduration:$($s.PasswordPolicy.LockoutMinutes) | Out-Null }
  }
  if ($s.SecurityTemplate) {
    & secedit.exe /configure /db "$env:windir\security\database\winimage.sdb" /cfg (P $s.SecurityTemplate) /quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Failure 'Security template didn''t apply' }
  }
  if ($s.AuditPolicy -eq 'Recommended') {
    foreach ($sub in '{0CCE923F-69AE-11D9-BED3-505054503030}', '{0CCE9235-69AE-11D9-BED3-505054503030}', '{0CCE9237-69AE-11D9-BED3-505054503030}',
      '{0CCE9215-69AE-11D9-BED3-505054503030}', '{0CCE9217-69AE-11D9-BED3-505054503030}', '{0CCE922F-69AE-11D9-BED3-505054503030}',
      '{0CCE9230-69AE-11D9-BED3-505054503030}', '{0CCE9210-69AE-11D9-BED3-505054503030}', '{0CCE9211-69AE-11D9-BED3-505054503030}') {
      & auditpol.exe /set /subcategory:$sub /success:enable /failure:enable | Out-Null
    }
    & wevtutil.exe sl Security /ms:1073741824 | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' 'ProcessCreationIncludeCmdLine_Enabled' 1
  }

  $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  if ($s.DisableSmb1) {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
  }
  if ($s.RequireSmbSigning) {
    Set-SmbServerConfiguration -RequireSecuritySignature $true -EnableSecuritySignature $true -Force -ErrorAction SilentlyContinue
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' 'RequireSecuritySignature' 1
  }
  if ($s.DisableLlmnr) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0 }
  if ($s.DisableNetBios) {
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue |
      ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name NetbiosOptions -Value 2 }
  }
  if ($s.DisableAutorun) { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255 }
  if ($s.DisableGuest) { Get-LocalUser | Where-Object { $_.SID.Value -like '*-501' } | Disable-LocalUser }
  if ($s.BlockUsbStorage) { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' 'Start' 4 }
  if ($s.DisableWdigest) { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential' 0 }
  if ($s.LsaProtection) { Set-Reg $lsa 'RunAsPPL' 1 }
  if ($s.PowerShellLogging) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging' 1 }
  if ($s.ScreenLockSeconds) { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'InactivityTimeoutSecs' ([int]$s.ScreenLockSeconds) }

  if ($s.Firewall -eq 'On') { Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow }
  foreach ($r in @($s.FirewallRules)) {
    if (-not $r) { continue }
    $p = @{ DisplayName = $r.Name; Direction = 'Inbound'; Action = 'Allow'; Enabled = 'True' }
    foreach ($k in 'Direction', 'Action', 'Protocol', 'Program', 'Profile') { if ($r.$k) { $p[$k] = $r.$k } }
    if ($r.Port) { $p.LocalPort = @($r.Port) }
    if ($r.RemoteAddress) { $p.RemoteAddress = @($r.RemoteAddress) }
    New-NetFirewallRule @p | Out-Null
    Log "  Firewall: $($r.Name)"
  }

  if ($s.Rdp.Enabled) {
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    $nla = if ($s.Rdp.Nla -eq $false) { 0 } else { 1 }
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value $nla
    # This group name works in every language
    $rules = Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752'
    $allow = @($s.Rdp.AllowFrom | Where-Object { $_ })
    if ($allow.Count) { $rules | Set-NetFirewallRule -Enabled True -RemoteAddress $allow } else { $rules | Set-NetFirewallRule -Enabled True }
    Log "  Remote Desktop on$(if ($allow.Count) { ", from $($allow -join ', ')" })"
  }

  $m = $s.Defender
  foreach ($e in @($m.Exclusions)) { if ($e) { Add-MpPreference -ExclusionPath $e -ErrorAction SilentlyContinue } }
  foreach ($e in @($m.ProcessExclusions)) { if ($e) { Add-MpPreference -ExclusionProcess $e -ErrorAction SilentlyContinue } }
  foreach ($id in @($m.AsrRules)) { if ($id) { Add-MpPreference -AttackSurfaceReductionRules_Ids $id -AttackSurfaceReductionRules_Actions Enabled -ErrorAction SilentlyContinue } }
  if ($m.NetworkProtection) { Set-MpPreference -EnableNetworkProtection Enabled -ErrorAction SilentlyContinue }
  if ($m.PuaProtection) { Set-MpPreference -PUAProtection Enabled -ErrorAction SilentlyContinue }

  if ($s.Laps.Enabled) {
    $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LAPS'
    Set-Reg $k 'BackupDirectory' $(if ($s.Laps.Backup -eq 'Entra') { 1 } else { 2 })
    Set-Reg $k 'PasswordAgeDays' ([int]$s.Laps.AgeDays)
    Set-Reg $k 'PasswordLength' ([int]$s.Laps.Length)
    Set-Reg $k 'PasswordComplexity' 4
    if ($s.Laps.AccountName) { Set-Reg $k 'AdministratorAccountName' $s.Laps.AccountName 'String' }
    Log '  Windows LAPS policy set'
  }
}

function Step-System {
  foreach ($file in @($C.Registry.Import)) { if ($file) { & reg.exe import (P $file) 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { Add-Failure "reg import $file" } } }
  foreach ($r in @($C.Registry.Machine)) {
    if (-not $r) { continue }
    $type = if ($r.Type) { $r.Type } else { 'DWord' }
    Set-Reg "HKLM:\$($r.Key)" $r.Name $r.Value $type
  }
  $userItems = New-Object System.Collections.ArrayList
  foreach ($r in @($C.Registry.DefaultUser)) { if ($r) { [void]$userItems.Add($r) } }
  foreach ($t in @($C.Tweaks)) {
    if (-not $t) { continue }
    if (-not $TweakTable.ContainsKey($t)) { Add-Failure "Unknown tweak: $t"; continue }
    foreach ($e in $TweakTable[$t]) {
      if ($e[0] -eq 'M') { Set-Reg "HKLM:\$($e[1])" $e[2] $e[3] }
      else {
        $type = if ($e[3] -is [string]) { 'REG_SZ' } else { 'REG_DWORD' }
        [void]$userItems.Add([pscustomobject]@{ Key = $e[1]; Name = $e[2]; Type = $type; Value = $e[3] })
      }
    }
    Log "  Tweak: $t"
  }
  Set-DefaultUserValues $userItems

  foreach ($svc in @($C.Services.Disable)) {
    if ($svc) { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue; Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue }
  }
  foreach ($svc in @($C.Services.Enable)) {
    if ($svc) { Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name $svc -ErrorAction SilentlyContinue }
  }

  $p = $C.Power
  $plans = @{ High = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'; Saver = 'a1841308-3541-4fab-bc81-f71556f20b4a' }
  if ($p.Plan) { & powercfg.exe /setactive $plans[$p.Plan] | Out-Null }
  if ($p.MonitorMinutes -ge 0) { & powercfg.exe /change monitor-timeout-ac $p.MonitorMinutes | Out-Null }
  if ($p.SleepMinutes -ge 0) { & powercfg.exe /change standby-timeout-ac $p.SleepMinutes | Out-Null }
  if ($p.Hibernate) { & powercfg.exe /hibernate $p.Hibernate.ToLower() | Out-Null }
  if ($p.FastStartup -eq 'Off') { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0 }
}

function Step-Updates-Policy {
  $u = $C.Updates
  $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  if ($u.Wsus) {
    Set-Reg $wu 'WUServer' $u.Wsus 'String'; Set-Reg $wu 'WUStatusServer' $u.Wsus 'String'
    Set-Reg "$wu\AU" 'UseWUServer' 1
    if ($u.WsusGroup) { Set-Reg $wu 'TargetGroupEnabled' 1; Set-Reg $wu 'TargetGroup' $u.WsusGroup 'String' }
  }
  if ($u.PauseFeatureUpdatesDays -gt 0) { Set-Reg $wu 'DeferFeatureUpdates' 1; Set-Reg $wu 'DeferFeatureUpdatesPeriodInDays' ([int]$u.PauseFeatureUpdatesDays) }
  if ($u.ActiveHoursStart -ge 0 -and $u.ActiveHoursEnd -ge 0) {
    Set-Reg $wu 'SetActiveHours' 1; Set-Reg $wu 'ActiveHoursStart' ([int]$u.ActiveHoursStart); Set-Reg $wu 'ActiveHoursEnd' ([int]$u.ActiveHoursEnd)
  }
}

function Step-Apps { foreach ($a in @($C.Apps)) { if ($a) { Install-App $a } } }
function Step-ScriptsEarly { foreach ($s in @($C.Scripts.Early)) { if ($s) { Invoke-UserScript $s } } }
function Step-ScriptsLate { foreach ($s in @($C.Scripts.Late)) { if ($s) { Invoke-UserScript $s } } }

function Step-Printers {
  foreach ($p in @($C.Printers)) {
    if (-not $p) { continue }
    if ($p.DriverPath) {
      $path = P $p.DriverPath
      if ((Get-Item -LiteralPath $path).PSIsContainer) { $path = "$path\*.inf" }
      & pnputil.exe /add-driver $path /subdirs /install | Out-Null
    }
    Add-PrinterDriver -Name $p.Driver -ErrorAction Stop
    $portName = "IP_$($p.Address)"
    if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
      if ($p.Lpr) { Add-PrinterPort -Name $portName -LprHostAddress $p.Address -LprQueueName "$($p.Lpr)" -ErrorAction Stop }
      else {
        $port = if ($p.Port) { [int]$p.Port } else { 9100 }
        Add-PrinterPort -Name $portName -PrinterHostAddress $p.Address -PortNumber $port -ErrorAction Stop
      }
    }
    if (-not (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue)) { Add-Printer -Name $p.Name -DriverName $p.Driver -PortName $portName -ErrorAction Stop }
    if ($p.Default) {
      $printer = Get-CimInstance Win32_Printer -Filter "Name='$($p.Name -replace "'", "\'")'"
      Invoke-CimMethod -InputObject $printer -MethodName SetDefaultPrinter | Out-Null
    }
    Log "  $($p.Name) at $($p.Address)"
  }
}

function Step-UserSetup {
  $u = $C.UserSetup
  $wsh = New-Object -ComObject WScript.Shell
  foreach ($s in @($u.Shortcuts)) {
    if (-not $s) { continue }
    $dir = if ($s.Folder -eq 'Start') { "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" } else { "$env:PUBLIC\Desktop" }
    if ($s.Url) {
      Set-Content -LiteralPath "$dir\$($s.Name).url" -Value "[InternetShortcut]`r`nURL=$($s.Url)" -Encoding Ascii
    } else {
      $l = $wsh.CreateShortcut("$dir\$($s.Name).lnk")
      $l.TargetPath = $s.Target
      if ($s.Arguments) { $l.Arguments = $s.Arguments }
      if ($s.Icon) { $l.IconLocation = $s.Icon }
      $l.Save()
    }
    Log "  Shortcut: $($s.Name)"
  }

  # Per-user work runs at each person's first sign-in, through Active Setup
  $drives = @($u.MappedDrives | Where-Object { $_ })
  $scripts = @($u.Scripts | Where-Object { $_ })
  if ($drives.Count -or $scripts.Count) {
    $dir = "$env:ProgramData\WinImage\user"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $lines = @('# Runs once for each user, at first sign-in')
    foreach ($d in $drives) {
      $letter = "$($d.Letter)".TrimEnd(':')
      $lines += "& net.exe use ${letter}: `"$($d.Path)`" /persistent:yes"
    }
    foreach ($s in $scripts) {
      $name = Split-Path -Leaf $s
      Copy-Item -LiteralPath (P $s) -Destination (Join-Path $dir $name) -Force
      $lines += "& `"`$PSScriptRoot\$name`""
    }
    Set-Content -LiteralPath "$dir\FirstSignIn.ps1" -Value $lines -Encoding UTF8
    $k = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\WinImageUserSetup'
    Set-Reg $k '(Default)' 'WinImage user setup' 'String'
    Set-Reg $k 'Version' '1,0' 'String'
    Set-Reg $k 'StubPath' "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\FirstSignIn.ps1`"" 'ExpandString'
  }
}

function Step-WindowsUpdate {
  if (-not $C.Updates.Run) { return }
  $max = [int]$C.Updates.MaxRounds
  while ($State.WuRounds -lt $max) {
    $State.WuRounds = [int]$State.WuRounds + 1; Save-State
    Log "  Round $($State.WuRounds) of $max"
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
    if ($C.Updates.Drivers) { $criteria = "IsInstalled=0 and IsHidden=0" }
    $found = $searcher.Search($criteria)
    if ($found.Updates.Count -eq 0) { Log '  Up to date'; return }
    $list = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
      if (-not $u.EulaAccepted) { $u.AcceptEula() }
      [void]$list.Add($u)
      Log "    $($u.Title)"
    }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $list; [void]$dl.Download()
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $list; $inst.ForceQuiet = $true
    $res = $inst.Install()
    Log "  Result code $($res.ResultCode) (2 means all succeeded)"
    if ($res.RebootRequired) { Request-Reboot 'Windows updates' }
    if ($res.ResultCode -ne 2) { Add-Failure "Windows Update result $($res.ResultCode)"; return }
  }
  Log '  Reached Updates.MaxRounds; anything left will install on the normal schedule'
}

function Step-BitLocker {
  $b = $C.Security.BitLocker
  if (-not $b.Enabled) { return }
  if ($b.Escrow -eq 'None') { Add-Failure 'BitLocker skipped: no Escrow set, so nothing would keep the recovery key'; return }
  $tpm = Get-Tpm -ErrorAction SilentlyContinue
  if (-not ($tpm -and $tpm.TpmReady)) { Add-Failure 'BitLocker skipped: no ready TPM'; return }
  $v = Get-BitLockerVolume -MountPoint $env:SystemDrive
  if ($v.ProtectionStatus -eq 'On') { Log '  Already on'; return }

  # The recovery key must be safely stored before the disk is locked
  $rp = ($v.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1)
  if (-not $rp) { $rp = (Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector -WarningAction SilentlyContinue).KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1 }
  try {
    switch ($b.Escrow) {
      'AD' { Backup-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $rp.KeyProtectorId -ErrorAction Stop | Out-Null }
      'Entra' { BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $rp.KeyProtectorId -ErrorAction Stop | Out-Null }
      'Share' {
        $drive = Get-ShareDrive
        Set-Content -LiteralPath "$drive\$env:COMPUTERNAME-bitlocker.txt" -Value "Computer: $env:COMPUTERNAME`r`nSerial: $((Get-CimInstance Win32_BIOS).SerialNumber)`r`nKey ID: $($rp.KeyProtectorId)`r`nRecovery key: $($rp.RecoveryPassword)" -ErrorAction Stop
      }
    }
  } catch {
    Add-Failure "BitLocker not turned on: couldn't save the recovery key ($($_.Exception.Message))"
    return
  }
  $p = @{ MountPoint = $env:SystemDrive; EncryptionMethod = $b.Method; TpmProtector = $true; SkipHardwareTest = $true; ErrorAction = 'Stop' }
  if ($b.UsedSpaceOnly) { $p.UsedSpaceOnly = $true }
  Enable-BitLocker @p | Out-Null
  Log "  BitLocker on ($($b.Method)), recovery key saved to $($b.Escrow)"
}

function Step-AutoLogon {
  $a = $C.Accounts.AutoLogon
  if (-not $a.User) { return }
  $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  Set-Reg $k 'AutoAdminLogon' '1' 'String'
  Set-Reg $k 'DefaultUserName' $a.User 'String'
  Set-Reg $k 'DefaultPassword' "$($a.Password)" 'String'
  Log "  Auto logon as $($a.User). Its password stays in the registry: use it only for a restricted account."
}

function Set-StepDone([string]$name) {
  if (@($State.Done) -notcontains $name) { $State.Done = @($State.Done) + $name; Save-State }
}

function Invoke-Finish {
  $failed = @($State.Failed)
  $stop = ($C.Finish.StopOnError -and $failed.Count)

  # Lift the "being set up" notice, unless the config set a legal notice of its own
  $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  $n = $C.Security.LegalNotice
  if ($stop) {
    Set-Reg $k 'legalnoticecaption' 'This PC needs attention' 'String'
    Set-Reg $k 'legalnoticetext' "Setup finished with $($failed.Count) problem(s). See C:\ProgramData\WinImage\provision.log" 'String'
  } else {
    Set-Reg $k 'legalnoticecaption' "$($n.Caption)" 'String'
    Set-Reg $k 'legalnoticetext' "$($n.Text)" 'String'
  }

  $bios = Get-CimInstance Win32_BIOS
  $report = [ordered]@{
    Image = $C.Name; Build = $C.BuildId; Computer = $env:COMPUTERNAME; Serial = "$($bios.SerialNumber)"
    Model = (Get-Model); Started = $State.Started; Finished = (Get-Date -Format s)
    Failures = @($failed); Steps = @($State.Done)
  }
  $json = $report | ConvertTo-Json -Depth 4
  Set-Content -LiteralPath "$Keep\report.json" -Value $json -Encoding UTF8
  if ($C.Finish.ReportToShare) {
    try {
      $drive = Get-ShareDrive
      Set-Content -LiteralPath "$drive\$env:COMPUTERNAME-report.json" -Value $json -ErrorAction Stop
      Log 'Report saved to the share'
    } catch { Log "Couldn't save the report to the share: $($_.Exception.Message)" }
  }

  Log 'Cleaning up: removing the payload and every copy of the passwords'
  Copy-Item -LiteralPath "$Root\build.id" -Destination "$Keep\build.id" -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath "$Root\pe-install.log" -Destination "$Keep\pe-install.log" -Force -ErrorAction SilentlyContinue
  foreach ($f in "$env:SystemRoot\Panther\unattend.xml", "$env:SystemRoot\Panther\Unattend\unattend.xml", "$env:SystemRoot\Panther\autounattend.xml",
    "$env:SystemRoot\Panther\unattend-original.xml", "$env:SystemRoot\System32\Sysprep\unattend.xml", "$env:SystemDrive\autounattend.xml") {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Log "  Removed $f" }
  }
  Remove-Item -LiteralPath "$env:SystemRoot\Setup\Scripts\SetupComplete.cmd" -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
  Get-ChildItem $Keep -Filter 'dl-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName 'WinImage Provision' -Confirm:$false -ErrorAction SilentlyContinue
  Log "Finished with $($failed.Count) problem(s)"
  $action = if ($stop) { 'None' } else { $C.Finish.Action }

  # PowerShell can delete the folder it was started from: the script is already loaded
  Set-Location $env:SystemRoot
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $Root) { Log "Couldn't fully remove $Root"; }
  switch ($action) {
    'Reboot' { & shutdown.exe /r /t 30 /c 'This PC is ready.' /d p:4:1 }
    'Shutdown' { & shutdown.exe /s /t 30 /c 'This PC is ready.' /d p:4:1 }
  }
}

# ------------------------------------------------------------------ run
$Steps = @(
  @{ Name = 'WaitForSetup'; Run = { Step-WaitForSetup } }
  @{ Name = 'Holdscreen'; Run = { Step-Holdscreen } }
  @{ Name = 'PerModelDrivers'; Run = { Step-PerModelDrivers } }
  @{ Name = 'Network'; Run = { Step-Network } }
  @{ Name = 'Rename'; Run = { Step-Rename } }
  @{ Name = 'Recovery'; Run = { Step-Recovery } }
  @{ Name = 'Certificates'; Run = { Step-Certificates } }
  @{ Name = 'Accounts'; Run = { Step-Accounts } }
  @{ Name = 'Activation'; Run = { Step-Activation } }
  @{ Name = 'Domain'; Run = { Step-Domain } }
  @{ Name = 'UpdatePolicy'; Run = { Step-Updates-Policy } }
  @{ Name = 'ScriptsEarly'; Run = { Step-ScriptsEarly } }
  @{ Name = 'Apps'; Run = { Step-Apps } }
  @{ Name = 'Printers'; Run = { Step-Printers } }
  @{ Name = 'System'; Run = { Step-System } }
  @{ Name = 'UserSetup'; Run = { Step-UserSetup } }
  @{ Name = 'WindowsUpdate'; Run = { Step-WindowsUpdate } }
  @{ Name = 'Security'; Run = { Step-Security } }
  @{ Name = 'ScriptsLate'; Run = { Step-ScriptsLate } }
  @{ Name = 'BitLocker'; Run = { Step-BitLocker } }
  @{ Name = 'AutoLogon'; Run = { Step-AutoLogon } }
)

Log "Provisioning $($C.Name), build $($C.BuildId). $(@($State.Done).Count) of $($Steps.Count) steps already done."
foreach ($s in $Steps) {
  if (@($State.Done) -contains $s.Name) { continue }
  Log "== $($s.Name)"
  try {
    & $s.Run
  } catch {
    Add-Failure "$($s.Name): $($_.Exception.Message)"
  }
  Set-StepDone $s.Name
}

Log '== Finish'
Invoke-Finish
$Mutex.ReleaseMutex()
