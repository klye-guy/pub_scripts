# Not a clinic: a Proxmox or KVM lab VM, to show a config with nothing inherited.
# Boot order must be disk first, then CD.
@{
  Name   = 'lab-vm'
  Source = @{ Iso = '..\iso\Win11_25H2_English_x64.iso'; Edition = 'Windows 11 Pro' }
  Output = @{ Folder = '..\output'; Types = @('ISO') }

  # A new virtual disk is blank, so the disk guard has nothing to object to
  Disk     = @{ MinSizeGB = 40; RecoveryMB = 0 }
  License  = @{ ProductKey = 'kms'; UseFirmwareKey = $false }
  Identity = @{ ComputerName = 'LAB-{random:4}'; Organization = 'Lab' }
  Accounts = @{
    Admin = @{ Name = 'labadmin'; Password = 'random' }
    Users = @(@{ Name = 'student1'; Password = 'random'; Groups = @('Users', 'Remote Desktop Users') })
  }
  Drivers  = @{ VirtIoIso = '..\iso\virtio-win.iso' }
  Network  = @{ Proxy = @{ Server = '192.0.2.10:3128'; Bypass = '<local>;*.lab.example' } }
  Security = @{ Rdp = @{ Enabled = $true; AllowFrom = @('192.0.2.0/24') } }
  Tweaks   = @('NoConsumerApps', 'NoFirstLogonScreens')
  Updates  = @{ Run = $false }
}
