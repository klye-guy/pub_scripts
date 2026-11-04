# Civil Air Patrol squadron workstations, built to CAPR 120-1, Information Technology
# Security (1 Oct 2017, through ICL 26-03, 7 May 2026).
#
#   [120-1 x.x]  needed by that paragraph of the regulation
#   [extra]      not required by CAP: good practice, safe to drop
#
# CHANGE before building: every line marked EDIT.
# CHECK your wing's supplement to CAPR 120-1, and show this to your IT Officer.
# Wing supplements add their own rules (New Mexico's sets encryption and local admin
# rules, for example), and 120-1 para 3 sends waivers to the CAP CIO.
#
# This is a standalone file: it inherits nothing, so all of it is in front of you.
@{
  Name = 'cap-squadron'

  Source = @{
    Iso     = '..\iso\Win11_25H2_English_x64.iso'     # EDIT
    Edition = 'Windows 11 Pro'                        # EDIT if needed, see -ListEditions
  }
  Output = @{ Folder = '..\output'; Types = @('ISO') }

  # Existing machines have partitions, so this media leaves them alone unless the stick
  # has ALLOW-WIPE.txt (-AllowWipe). Back up CAP data first, and ask your IT Officer about
  # machines that hold PII: 120-1 para 11.4 covers disposal of data on CAP-owned devices.
  Disk = @{ IfNotBlank = 'Stop'; IfMultipleDisks = 'Smallest'; MinSizeGB = 60 }

  # [120-1 6.11] Installed software needs an active licence, Windows included. 'generic'
  # installs, then a PC with a digital licence or firmware key activates by itself. Any
  # other PC needs a real key in ActivationKey. Check the licence line in provision.log.
  License = @{ ProductKey = 'generic'; UseFirmwareKey = $true; ActivationKey = '' }

  Identity = @{
    ComputerName = 'CAP-{serial:7}'                   # EDIT: your unit's naming, 15 characters at most
    Organization = 'Civil Air Patrol'
    Owner        = 'Civil Air Patrol'
    TimeZone     = 'Central Standard Time'            # EDIT
  }

  Accounts = @{
    # For technical use only, not daily work. 'prompt' asks at build time.
    # Deployment passwords are temporary. Nothing forces this one to change, so change it
    # on each PC after imaging, and store it in a password manager [120-1 8.2].
    Admin = @{ Name = 'capadmin'; Password = 'prompt' }  # EDIT the name if you like

    # [120-1 6.14, 8.2, 8.7] No shared accounts: one account per member. There is
    # deliberately no generic "squadron" or "cadet" login, and no auto logon.
    # Standard users, so members can't install software [120-1 6.17].
    Users = @(
      # EDIT: one line per member. The temporary password is changed at first sign-in.
      @{ Name = 'jsmith'; FullName = 'J. Smith'; Password = 'prompt'; Groups = @('Users'); MustChangePassword = $true }
    )
  }

  Offline = @{
    # [120-1 6.17] Keeps software that doesn't serve the mission off CAP equipment.
    # Media Player and Movies & TV stay, for training videos.
    RemoveApps = @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GamingApp', 'Microsoft.Xbox*',
      'Clipchamp.Clipchamp', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.WindowsFeedbackHub',
      'Microsoft.YourPhone', 'MicrosoftCorporationII.MicrosoftFamily')
    Oem = @{ Manufacturer = 'Civil Air Patrol' }
  }

  Network = @{
    # Where BitLocker recovery keys are written. It's needed because BitLocker won't
    # start until its key is saved somewhere. Use storage that is itself encrypted,
    # readable only by IT staff [120-1 11.2], and an account that can only write here.
    # Its password is on the media: disable the account or reset it after the rollout.
    Share = @{ Path = '\\SERVER\capkeys$'; User = 'SERVER\imaging-drop'; Password = 'prompt' }  # EDIT
  }

  Security = @{
    # [120-1 10.1.1.3, 11.2] Full-disk encryption. Required on new CAP laptops; used on
    # every machine here so stored CAP data is encrypted too. A PC with no ready TPM
    # can't be encrypted this way, and the build then reports it as a problem.
    BitLocker = @{ Enabled = $true; Method = 'XtsAes256'; UsedSpaceOnly = $false; Escrow = 'Share' }

    # [120-1 11.5] Locks after 10 minutes at most
    ScreenLockSeconds = 600

    PasswordPolicy = @{
      MaxAgeDays = 180                 # [120-1 8.10] changed at least every 180 days
      MinLength  = 12                  # [120-1 8.1] "accepted business standards"; 12 is my choice
      History    = 12                  # [extra] supports 8.3 and 8.10
      LockoutThreshold = 5             # [extra]
      LockoutMinutes   = 15            # [extra]
    }

    # [120-1 7.2] A software firewall on every network
    Firewall = 'On'

    # [120-1 11.7] Anti-virus must be operational. Microsoft Defender is that default
    # protection: this image leaves it on and adds the two settings below [extra].
    Defender = @{ NetworkProtection = $true; PuaProtection = $true }

    # CAPR 120-1 doesn't require a banner. Optional, so reword or blank it. [extra]
    LegalNotice = @{ Caption = 'Civil Air Patrol'; Text = 'Authorized CAP use only. Use your own account. Do not share your password.' }

    # [extra] Low-risk hardening. RequireSmbSigning and DisableNetBios are left off because
    # they can break old squadron printers and NAS boxes.
    AuditPolicy = 'Recommended'
    DisableSmb1 = $true; DisableLlmnr = $true; DisableAutorun = $true
    DisableGuest = $true; DisableWdigest = $true; PowerShellLogging = $true
  }

  # 120-1 sets no patch rule, but 7.2 expects up-to-date protection
  Updates = @{ Run = $true; MaxRounds = 6 }

  # [extra] Also supports 6.17
  Tweaks = @('NoConsumerApps', 'NoFirstLogonScreens', 'NoWidgets', 'NoSearchWeb', 'ShowFileExtensions')

  Power = @{ Plan = 'Balanced'; MonitorMinutes = 10; SleepMinutes = 0; FastStartup = 'Off' }

  # Add licensed, mission-related software only [120-1 6.11, 6.17], such as:
  # Apps = @( @{ Name = 'Chrome'; Source = '..\installers\googlechromestandaloneenterprise64.msi' } )
  Apps = @()

  # A PC that misses a requirement (no TPM, a failed install) doesn't restart ready for
  # use: its sign-in screen says it needs attention. Check provision.log before issuing it.
  Finish = @{ Action = 'Reboot'; StopOnError = $true; ReportToShare = $true }
}
