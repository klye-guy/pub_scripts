<#
  Registers the task that runs Provision.ps1 at every startup, as SYSTEM, until it
  finishes and removes itself. Called from the answer file's specialize pass, and again
  from SetupComplete.cmd as a fallback. Safe to run twice.

  A scheduled task, not SetupComplete.cmd alone, because SetupComplete.cmd is skipped
  on client editions with an OEM product key, and can't survive a reboot.
#>
$ErrorActionPreference = 'Stop'
$Root = "$env:SystemDrive\WinImage"
$TaskName = 'WinImage Provision'
if (-not (Test-Path -LiteralPath "$Root\Provision.ps1")) { exit 0 }           # already finished
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { exit 0 }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\Provision.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
