# Shared by every clinic. Copy to _base.psd1 and edit. Clinic files inherit it and
# change only what's different. Abstract = $true means it's never built by itself.
#
# Passwords can be: 'random' (generated, saved next to the media), 'prompt' (asked at
# build time), 'env:NAME' (read from an environment variable), or the password itself.
# Prefer the first three: real passwords don't belong in a file in a git repo.
@{
  Abstract = $true

  Source = @{
    Iso     = '..\iso\Win11_25H2_English_x64.iso'
    Edition = 'Windows 11 Pro'        # exactly as -ListEditions shows it
  }
  Output = @{ Folder = '..\output'; Types = @('ISO') }

  # New PCs arrive with Windows on them, so a rollout needs Wipe, or ALLOW-WIPE.txt on
  # the stick (-AllowWipe). 'Stop' is the safe default: this media leaves any PC that
  # already has partitions alone.
  Disk = @{ IfNotBlank = 'Stop'; IfMultipleDisks = 'Smallest' }

  Identity = @{
    Organization = 'Example Health'
    TimeZone     = 'Central Standard Time'
  }
  Accounts = @{ Admin = @{ Name = 'itadmin'; Password = 'random' } }

  Offline = @{
    RemoveApps = @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GamingApp', 'Microsoft.Xbox*',
      'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Clipchamp.Clipchamp', 'Microsoft.MicrosoftSolitaireCollection',
      'Microsoft.WindowsFeedbackHub', 'Microsoft.YourPhone', 'MicrosoftCorporationII.MicrosoftFamily')
    Oem = @{ Manufacturer = 'Example Health IT'; SupportPhone = '555-0100'; SupportHours = 'Mon-Fri 8-5' }
  }

  Tweaks = @('NoConsumerApps', 'NoFirstLogonScreens', 'NoWidgets', 'NoCopilot', 'NoRecall', 'NoSearchWeb', 'ShowFileExtensions')

  Security = @{
    Firewall          = 'On'
    ScreenLockSeconds = 600
    LegalNotice       = @{ Caption = 'Authorized use only'; Text = 'This system may hold patient information. Use is monitored.' }
    PasswordPolicy    = @{ MinLength = 12; MaxAgeDays = 90; History = 12; LockoutThreshold = 5; LockoutMinutes = 15 }
    AuditPolicy       = 'Recommended'
    DisableSmb1 = $true; RequireSmbSigning = $true; DisableLlmnr = $true; DisableNetBios = $true
    DisableAutorun = $true; DisableGuest = $true; DisableWdigest = $true; PowerShellLogging = $true
    Defender = @{ NetworkProtection = $true; PuaProtection = $true }
  }

  Power   = @{ Plan = 'Balanced'; MonitorMinutes = 15; SleepMinutes = 0; FastStartup = 'Off' }
  Updates = @{ Run = $true; MaxRounds = 6; ActiveHoursStart = 7; ActiveHoursEnd = 19 }

  # Installers on the build PC go into the image. Clinics add theirs with 'Apps+'.
  Apps = @(
    # @{ Name = 'Chrome'; Source = '..\installers\googlechromestandaloneenterprise64.msi'
    #    Detect = 'C:\Program Files\Google\Chrome\Application\chrome.exe' }
    # @{ Name = 'RMM agent'; Source = '..\installers\agent.exe'; Args = '/quiet'; Required = $true }
  )
}
