# One clinic: only what differs from _base. Copy to clinic-north.psd1 and edit.
@{
  Inherit = '_base.example.psd1'
  Name    = 'clinic-north'

  # NC-7H2KD9F from the serial number. Or list exact names in a CSV (columns Serial,Name)
  # with Identity.NameMap.
  Identity = @{ ComputerName = 'NC-{serial:7}'; Organization = 'Example Health North Clinic' }

  Network = @{
    DnsServers = @('10.20.0.10', '10.20.0.11')
    # Wifi    = @('..\clinic-north\wifi-staff.xml')    # netsh wlan export profile key=clear
    Hosts     = @(@{ Ip = '10.20.0.50'; Name = 'emr.north.example.org' })
    # Holds the BitLocker keys and reports. Give this account write access to this share only.
    Share     = @{ Path = '\\10.20.0.20\imaging$'; User = 'north\imaging-drop'; Password = 'env:NORTH_SHARE_PASSWORD' }
  }

  # Domain = @{ Mode = 'AD'; Name = 'north.example.org'; OU = 'OU=Workstations,DC=north,DC=example,DC=org'
  #             User = 'north\join-only'; Password = 'env:NORTH_JOIN_PASSWORD' }

  Accounts = @{
    Users = @(
      @{ Name = 'frontdesk'; Password = 'random'; FullName = 'Front Desk'; Groups = @('Users'); MustChangePassword = $true }
    )
  }

  # 'Apps+' adds to the base list. 'Apps-' = @('Name') would remove from it.
  'Apps+' = @(
    @{ Name = 'PowerShell 7'; Source = 'winget:Microsoft.PowerShell'; Required = $false }
  )

  Printers = @(
    @{ Name = 'Front Desk'; Address = '10.20.0.31'; Driver = 'Microsoft IPP Class Driver'; Default = $true }
  )

  UserSetup = @{
    Shortcuts    = @(@{ Name = 'EMR'; Url = 'https://emr.north.example.org' })
    MappedDrives = @(@{ Letter = 'S'; Path = '\\10.20.0.20\shared' })
  }

  Security = @{
    BitLocker = @{ Enabled = $true; Escrow = 'Share' }
    Rdp       = @{ Enabled = $true; AllowFrom = @('10.20.0.0/24') }
  }

  Finish = @{ ReportToShare = $true }
}
