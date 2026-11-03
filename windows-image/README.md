# windows-image

Build fully unattended Windows install media from a stock ISO and a config file, from Windows. Boot a PC from the result and walk away: it picks the internal disk, installs Windows, skips every setup screen, and sets itself up as SYSTEM, surviving reboots, until it's ready to use.

It's built for one base config with a small overlay per site, so you can keep a separate image for each clinic, office, or lab, and change the shared parts in one place.

| File | Does |
|---|---|
| [`Build-WindowsImage.ps1`](Build-WindowsImage.ps1) | Services the image and writes an ISO, USB stick, WIM, or folder |
| [`engine/pe-install.cmd`](engine/pe-install.cmd) | Runs in WinPE: chooses and partitions the disk, applies the image |
| [`engine/Provision.ps1`](engine/Provision.ps1) | Runs on first boot: apps, accounts, domain, security, updates, and more |
| [`engine/Register-Provision.ps1`](engine/Register-Provision.ps1) | Creates the startup task that runs `Provision.ps1` |
| [`configs/`](configs/) | A commented base, a clinic overlay, and a lab VM |

Works with Windows 10 and 11, and Windows Server 2019, 2022, and 2025.

> **Test status:** version 1.0.0 has had its config handling, generated files, name patterns, and reboot and resume logic tested on PowerShell 7 with the Windows calls stubbed. It has **not yet been run end to end on Windows**: the DISM servicing, `pe-install.cmd`, and USB writing are unproven. Try it on a VM, then on one spare PC, before trusting it with a clinic.

## Requirements

- An administrator Windows PowerShell 5.1 (built in) on Windows 10, 11, or Server. `-Plan` needs neither administrator rights nor Windows.
- `oscdimg.exe` for ISO output, from the Windows ADK's Deployment Tools. `-InstallTools` installs it with winget. USB and WIM output don't need it.
- A Windows ISO, and about three times its size free on a local NTFS drive.

## Usage

```powershell
Copy-Item configs\_base.example.psd1 configs\_base.psd1
Copy-Item configs\clinic-north.example.psd1 configs\north.psd1      # point Inherit at _base.psd1

.\Build-WindowsImage.ps1 -ListEditions D:\iso\Win11.iso    # the exact name for Source.Edition
.\Build-WindowsImage.ps1 configs\north.psd1 -ShowConfig    # the config after inheritance
.\Build-WindowsImage.ps1 configs\north.psd1 -Plan          # validate, write what would go on the media
.\Build-WindowsImage.ps1 configs\north.psd1                # build it
.\Build-WindowsImage.ps1 configs\*.psd1                    # build every clinic (bases are skipped)
.\Build-WindowsImage.ps1 -ListUsb                          # USB disks
.\Build-WindowsImage.ps1 configs\north.psd1 -UsbDisk 3     # build, then write USB disk 3
```

If PowerShell refuses to run it, allow scripts for that window only: `Set-ExecutionPolicy -Scope Process Bypass`.

For a VM, use the ISO with the boot order set to **disk first, then CD**. For a PC, use a USB stick. Each build starts again from the stock ISO, and a build takes roughly 15-60 minutes, depending mostly on how many updates you slipstream.

## Configs

A config is a `.psd1` file: a PowerShell hashtable, with comments, that runs no code. Every setting is optional except `Source`. A misspelled setting stops the build rather than being ignored.

```powershell
@{
  Inherit = '_base.psd1'                 # or several: @('_base.psd1', '_laptops.psd1')
  Name    = 'clinic-north'
  Identity = @{ ComputerName = 'NC-{serial:7}' }
  'Apps+'  = @( @{ Name = 'EMR client'; Source = '..\installers\emr.msi' } )   # adds to the base's list
  'Tweaks-' = @('NoCopilot')                                                   # removes from it
}
```

- **Sections merge** key by key, so an overlay changes one setting and keeps the rest.
- **Lists replace**, unless you write `'Key+'` to add or `'Key-'` to remove. Items are matched by their value or `Name`.
- **Paths** are relative to the file that sets them.
- **Passwords** can be `random` (generated and saved next to the output), `prompt`, `env:NAME`, or the password itself. Prefer the first three.
- **`Abstract = $true`** marks a base, which wildcards skip.

### Settings

| Section | Settings |
|---|---|
| `Source` | `Iso`, or `Folder` for an unpacked ISO; `Edition` |
| `Output` | `Folder`; `Types` (`ISO`, `USB`, `WIM`, `Folder`); `VolumeLabel` |
| `Boot` | `PressAnyKey`; `BypassChecks` (hardware checks; `Setup` method only, since `Script` never runs them) |
| `Disk` | `Method`; `Target`; `Firmware`; `IfMultipleDisks`; `MinSizeGB`; `IfNotBlank`; `EfiMB`; `RecoveryMB`; `WindowsSizeGB` and `DataLabel` (a size leaves the rest as a data partition) |
| `License` | `ProductKey` (`generic`, `kms`, `none`, or a key); `UseFirmwareKey`; `ActivationKey`; `KmsHost` |
| `Identity` | `ComputerName`; `NameMap`; `Organization`; `Owner`; `TimeZone`; `Locale`; `Keyboard` |
| `Accounts` | `Admin` (`Name`, `Password`, `FullName`); `Users` (`Name`, `Password`, `FullName`, `Description`, `Groups`, `PasswordNeverExpires`, `MustChangePassword`, `Disabled`); `AutoLogon` (`User`, `Password`) |
| `Drivers` | `Boot` (storage and network, for Setup); `Image` (all PCs); `PerModel` (`Match`, `Path`: installed only on matching models); `VirtIoIso` |
| `Offline` | `RemoveApps` (wildcards); `RemoveCapabilities`; `AddCapabilities` with `CapabilitySource`; `EnableFeatures`; `DisableFeatures`; `Updates` (`.msu` files or a folder); `ResetBase`; `Registry` (`Hive` is `SOFTWARE`, `SYSTEM` or `NTUSER`; `Key`, `Name`, `Type`, `Value`); `Files` (`Source`, `Target`); `AppAssociations`; `StartLayout`; `TaskbarLayout`; `Wallpaper`; `LockScreen`; `Oem` |
| `Network` | `WaitSeconds`; `Wifi` (exported profile XML); `DnsServers`; `DnsSuffix`; `Hosts` (`Ip`, `Name`); `Proxy` (`Server`, `Bypass`); `Share` (`Path`, `User`, `Password`) |
| `Domain` | `Mode` (`None`, `AD`, `Ppkg`); `Name`; `OU`; `User`; `Password`; `Ppkg` (provisioning packages, for example Entra ID bulk enrolment) |
| `Security` | `Firewall = 'On'`; `FirewallRules`; `Rdp`; `BitLocker`; `Laps`; `ScreenLockSeconds`; `LegalNotice`; `PasswordPolicy`; `AuditPolicy = 'Recommended'`; `SecurityTemplate` (a secedit `.inf`); `Defender`; `Certificates` (`File`, `Store`, `Password`); and switches `DisableSmb1`, `RequireSmbSigning`, `DisableLlmnr`, `DisableNetBios`, `DisableAutorun`, `DisableGuest`, `BlockUsbStorage`, `DisableWdigest`, `LsaProtection`, `PowerShellLogging` |
| `Updates` | `Run`; `Drivers`; `MaxRounds`; `Wsus`; `WsusGroup`; `PauseFeatureUpdatesDays`; `ActiveHoursStart`; `ActiveHoursEnd` |
| `Apps` | `Name`; `Source`; `Run` (the file, when `Source` is a folder); `Args`; `Sha256`; `Detect`; `SuccessCodes`; `Reboot`; `TimeoutMinutes`; `Required`; `OnlyModels` |
| `Printers` | `Name`; `Address`; `Driver`; `DriverPath`; `Default`; `Port`; `Lpr` |
| `Registry` | `Machine` and `DefaultUser` (`Key`, `Name`, `Type`, `Value`); `Import` (`.reg` files) |
| `Services` | `Disable`; `Enable` |
| `Tweaks` | `NoConsumerApps`, `NoFirstLogonScreens`, `NoLockScreenCamera`, `NoWidgets`, `NoCopilot`, `NoRecall`, `NoSearchWeb`, `NoTelemetryExtras`, `NoOneDriveSetup`, `NoDeviceEncryption`, `ShowFileExtensions`, `ShowHiddenFiles`, `TaskbarLeft`, `ClassicContextMenu`, `NoTaskbarSearchBox`, `NoTaskView` |
| `Power` | `Plan` (`High`, `Balanced`, `Saver`); `MonitorMinutes`; `SleepMinutes`; `Hibernate` (`On`, `Off`); `FastStartup = 'Off'` |
| `UserSetup` | `Shortcuts` (`Name`, then `Target` or `Url`; `Arguments`, `Icon`, `Folder = 'Start'`); `MappedDrives` (`Letter`, `Path`); `Scripts` (run at each user's first sign-in) |
| `Scripts` | `Early` and `Late` (`Path`, `Args`, `Reboot`), run as SYSTEM |
| `Finish` | `Action` (`Reboot`, `Shutdown`, `None`); `StopOnError`; `ReportToShare` |

`Get-Defaults` at the top of `Build-WindowsImage.ps1` shows every default. Registry `Type` takes `REG_SZ`, `REG_DWORD`, and so on, and defaults to `REG_DWORD`.

**App sources.** A local file or folder goes into the image. Installer type comes from the extension: `.msi`, `.exe`, `.msu`, `.ps1`, `.cmd`, `.bat`, `.msix`, `.appx`. A URL is fetched on first boot and needs a `Sha256`. `winget:Package.Id` uses winget, which may not be ready on a new install, so use a local installer for anything that must work.

**Computer names.** `ComputerName` is `*` (random), a fixed name, or a pattern with `{serial}`, `{serial:7}` (its last 7 characters), `{mac}`, `{random:4}`, or `{name}`. PCs that report a placeholder instead of a serial use their MAC address. `NameMap` is a CSV with `Serial,Name` columns, for exact names; PCs not in it fall back to the pattern.

## What the media does

1. **Picks the disk.** With `Disk.Target = 'Auto'`, it lists disks, skips USB, SD, and anything under `MinSizeGB`, and takes the smallest of what's left (`IfMultipleDisks`). Windows Setup's own disk numbering can't be relied on: on real hardware, disk 0 can be the USB stick.
2. **Checks it's safe to erase** (see below).
3. **Partitions and applies the image** with diskpart, DISM, and bcdboot, handling UEFI and BIOS. On any failure it stops and shuts the PC down, and never falls through to Setup's screens.
4. **Skips every setup screen,** creating the admin account from the answer file.
5. **Provisions on first boot.** A startup task runs `Provision.ps1` as SYSTEM, in this order, restarting wherever a step needs it and carrying on after: per-model drivers, network, rename, recovery tools, certificates, accounts, activation, domain join, update policy, early scripts, apps, printers, system settings, user setup, Windows Update, security, late scripts, BitLocker, auto logon. The sign-in screen shows a "being set up" notice meanwhile.
6. **Cleans up.** It deletes the payload, the task, and every copy of the answer file, then restarts. A failed step is logged and the rest carry on. With `Finish.StopOnError`, the PC doesn't restart and the sign-in notice says it needs attention.

It uses a scheduled task rather than `SetupComplete.cmd` because [Microsoft documents](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup) that `SetupComplete.cmd` is skipped with OEM product keys on client editions, and can't resume after a reboot.

### When it will erase a disk

| The target disk | Result |
|---|---|
| Blank | Installs |
| Has partitions, `IfNotBlank = 'Stop'` (the default) | Stops, unless `ALLOW-WIPE.txt` is on the stick |
| Has partitions, `IfNotBlank = 'Wipe'` | Erases with no prompt |
| Already has this exact build (the stick was left in) | Stops, unless `ALLOW-WIPE.txt` is on the stick |

**New PCs ship with Windows on them, so for a rollout you need one of the two overrides.** `-AllowWipe` puts `ALLOW-WIPE.txt` on the stick; delete it when the rollout is done. `IfNotBlank = 'Wipe'` is the fully hands-off choice, and makes the media dangerous to leave lying around: any PC that boots from it is erased.

`Disk.Method = 'Setup'` is the fallback: it hands the disk to Windows Setup, as a plain answer file would. It needs a fixed `Disk.Target` and has **none** of these safety checks.

## Where it writes files

| Where | What |
|---|---|
| `<Output.Folder>\<Name>.iso`, `.wim`, `.unattend.xml`, `<Name>-media\` | The output |
| `<Output.Folder>\<Name>.passwords.txt` | Generated passwords, readable by you and administrators only |
| `<Output.Folder>\<Name>.build.log` | Every tool run and its output |
| `<Output.Folder>\<Name>-plan\` | What `-Plan` wrote, with passwords masked |
| `<Output.Folder>\work\` or `-WorkDir` | Scratch space, removed after a good build |
| On the PC: `C:\ProgramData\WinImage\` | `provision.log`, `report.json`, `pe-install.log`, `build.id` |
| On the share, with `Network.Share` | `<computer>-bitlocker.txt`, `<computer>-report.json` |
| On the USB stick | `winimage-last-stop.log`, if the disk script stopped |

The `.gitignore` here keeps output, passwords, installers, and any config not named `*.example.psd1` out of git. This is a public repo: keep your real configs somewhere else.

## Caveats

- **The media holds secrets.** Local passwords, and any domain, share, or certificate passwords, sit on it in recoverable form. Base64 in the answer file is not encryption. Store media like a key to the building, use a join-only account limited to one OU, and a share account that can only write to its one share. The installed PC doesn't keep them.
- **Security settings are a baseline, not compliance.** The example settings suit a clinic workstation, but they don't make anything HIPAA compliant. Test them against your EMR software before rollout: SMB signing, LLMNR, and USB blocking are the likeliest to break something.
- **Missing disk on a real PC.** Laptops with Intel VMD or RST need that storage driver in `Drivers.Boot`, or the disk won't appear. Use the x64 `.inf` driver, not the vendor's installer.
- **Encrypted disks.** The check for this build looks at every volume it can read, but a BitLockered disk can't be read. A finished, encrypted PC with the stick left in and `ALLOW-WIPE.txt` or `Wipe` set can be erased. UEFI normally boots Windows first after install. Take the stick out anyway.
- **Secure Boot.** PCs that have had the Boot Manager revocations applied can refuse older media. If yours won't boot, run Microsoft's [`Make2023BootableMedia.ps1`](https://support.microsoft.com/help/5053484) on the ISO first and build from the result.
- **Activation.** `generic` installs without activating, and a PC with a digital licence or firmware key activates by itself. A firmware key for a different edition (Home on a Pro image) won't work.
- **Unattended rules change.** This uses the answer file and DISM, not OOBE tricks, but a new Windows build can add a screen.
- **USB sticks.** USB output splits the image for FAT32, and uses at most 32 GB of the stick.
