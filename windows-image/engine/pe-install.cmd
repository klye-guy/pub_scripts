@echo off
rem pe-install.cmd: runs inside Setup's WinPE, from the answer file's first command.
rem Chooses the disk, refuses to erase anything it shouldn't, partitions, applies the
rem image, makes it bootable, and reboots. Setup itself never gets past this script.
rem It never returns to Setup: on any problem it stops and shuts the PC down.
setlocal EnableExtensions EnableDelayedExpansion

set "BUILD=@@BUILD_ID@@"
set "TARGET=@@TARGET@@"
set "FIRMWARE=@@FIRMWARE@@"
set "IF_MULTIPLE=@@IF_MULTIPLE@@"
set "MIN_GB=@@MIN_GB@@"
set "IF_NOT_BLANK=@@IF_NOT_BLANK@@"
set "EFI_MB=@@EFI_MB@@"
set "RECOVERY_MB=@@RECOVERY_MB@@"
set "WINDOWS_GB=@@WINDOWS_GB@@"
set "DATA_LABEL=@@DATA_LABEL@@"

set "T=X:\winimage"
set "LOG=%T%\pe-install.log"
title WinImage: preparing this PC
call :say Build %BUILD%

rem ---------------------------------------------------------------- find the media
set "MEDIA="
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist "%%L:\winimage-%BUILD%.id" set "MEDIA=%%L:"
)
if not defined MEDIA call :stop "The install media wasn't found. Is the USB stick or ISO still attached?"
call :say Media is %MEDIA%
set "ALLOW_WIPE=0"
if exist "%MEDIA%\ALLOW-WIPE.txt" set "ALLOW_WIPE=1"

set "IMAGE=%MEDIA%\sources\install.wim"
set "SWM_ARG="
if not exist "%IMAGE%" (
  set "IMAGE=%MEDIA%\sources\install.swm"
  set "SWM_ARG=/SWMFile:%MEDIA%\sources\install*.swm"
)
if not exist "%IMAGE%" call :stop "No install image on the media."

rem ---------------------------------------------------------------- firmware
if /i "%FIRMWARE%"=="Auto" (
  wpeutil UpdateBootInfo >nul 2>&1
  set "FIRMWARE=UEFI"
  for /f "tokens=3" %%v in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType 2^>nul ^| findstr /i PEFirmwareType') do (
    if "%%v"=="0x1" set "FIRMWARE=BIOS"
  )
)
call :say Firmware is %FIRMWARE%

rem ---------------------------------------------------------------- choose the disk
rem Parsed by position, with the column title read from diskpart's own header, so this
rem works on translated media too. A disk it can't read is left out, never guessed at.
set "DISK="
if /i not "%TARGET%"=="Auto" (
  set "DISK=%TARGET%"
  goto :disk_chosen
)
> "%T%\list.txt" echo list disk
diskpart /s "%T%\list.txt" > "%T%\disks.txt"
set "DISK_WORD="
for /f "tokens=1,2" %%a in ('type "%T%\disks.txt"') do (
  if "%%b"=="###" if not defined DISK_WORD set "DISK_WORD=%%a"
)
if not defined DISK_WORD call :stop "Couldn't read diskpart's disk list."

set "COUNT=0"
set "BEST_GB="
for /f "tokens=1,2,4,5" %%a in ('type "%T%\disks.txt"') do (
  if "%%a"=="!DISK_WORD!" if not "%%b"=="###" call :consider %%b %%c %%d
)
if "!COUNT!"=="0" call :stop "No internal disk of at least %MIN_GB% GB. If this PC's disk is missing, it may need a storage driver (Intel VMD/RST): add it to Drivers.Boot."
if "!COUNT!" GTR "1" if /i "%IF_MULTIPLE%"=="Stop" call :stop "This PC has !COUNT! internal disks, and this media is set to stop rather than choose. Set Disk.Target or Disk.IfMultipleDisks."
:disk_chosen
call :say Target is disk %DISK%

rem ---------------------------------------------------------------- is it safe to erase?
> "%T%\parts.txt" (echo select disk %DISK%& echo list partition)
diskpart /s "%T%\parts.txt" > "%T%\partlist.txt"
set "PART_WORD="
set "PARTS=0"
for /f "tokens=1,2" %%a in ('type "%T%\partlist.txt"') do (
  if "%%b"=="###" if not defined PART_WORD set "PART_WORD=%%a"
)
if defined PART_WORD for /f "tokens=1,2" %%a in ('type "%T%\partlist.txt"') do (
  if "%%a"=="!PART_WORD!" if not "%%b"=="###" set /a PARTS+=1
)
call :say Disk %DISK% has %PARTS% partition(s)

rem This exact build already on the PC means the stick was left in and the PC booted
rem from it again: without this, a USB-first boot order would wipe the PC in a loop.
set "SAME_BUILD=0"
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist "%%L:\WinImage\build.id" (
    findstr /c:"%BUILD%" "%%L:\WinImage\build.id" >nul 2>&1 && set "SAME_BUILD=1"
  )
  if exist "%%L:\ProgramData\WinImage\build.id" (
    findstr /c:"%BUILD%" "%%L:\ProgramData\WinImage\build.id" >nul 2>&1 && set "SAME_BUILD=1"
  )
)
if "%SAME_BUILD%"=="1" if "%ALLOW_WIPE%"=="0" call :stop "This PC already has this build on it. Take the install media out and turn the PC on. To image it again, add ALLOW-WIPE.txt to the stick."
if not "%PARTS%"=="0" if /i not "%IF_NOT_BLANK%"=="Wipe" if "%ALLOW_WIPE%"=="0" call :stop "Disk %DISK% isn't blank, and this media won't erase it. To re-image, add ALLOW-WIPE.txt to the stick, or build with Disk.IfNotBlank = Wipe."

rem ---------------------------------------------------------------- drive letters
set "L_WIN="
set "L_SYS="
set "L_REC="
set "L_DATA="
for %%L in (W V U T S R Q P O N M L K J I H G) do (
  if not exist "%%L:\" (
    if not defined L_WIN (set "L_WIN=%%L") else if not defined L_SYS (set "L_SYS=%%L") else if not defined L_REC (set "L_REC=%%L") else if not defined L_DATA set "L_DATA=%%L"
  )
)
if not defined L_DATA call :stop "No free drive letters in WinPE."

rem ---------------------------------------------------------------- partition
set "DP=%T%\partition.txt"
> "%DP%" echo select disk %DISK%
>> "%DP%" echo online disk noerr
>> "%DP%" echo attributes disk clear readonly noerr
>> "%DP%" echo clean
if /i "%FIRMWARE%"=="UEFI" (
  >> "%DP%" echo convert gpt
  >> "%DP%" echo create partition efi size=%EFI_MB%
  >> "%DP%" echo format quick fs=fat32 label="System"
  >> "%DP%" echo assign letter=%L_SYS%
  >> "%DP%" echo create partition msr size=16
) else (
  >> "%DP%" echo convert mbr
  >> "%DP%" echo create partition primary size=500
  >> "%DP%" echo format quick fs=ntfs label="System Reserved"
  >> "%DP%" echo assign letter=%L_SYS%
  >> "%DP%" echo active
)
if "%WINDOWS_GB%"=="0" (
  >> "%DP%" echo create partition primary
  if not "%RECOVERY_MB%"=="0" >> "%DP%" echo shrink minimum=%RECOVERY_MB%
) else (
  set /a WIN_MB=%WINDOWS_GB%*1024
  >> "%DP%" echo create partition primary size=!WIN_MB!
)
>> "%DP%" echo format quick fs=ntfs label="Windows"
>> "%DP%" echo assign letter=%L_WIN%
if not "%RECOVERY_MB%"=="0" (
  if "%WINDOWS_GB%"=="0" (
    >> "%DP%" echo create partition primary
  ) else (
    >> "%DP%" echo create partition primary size=%RECOVERY_MB%
  )
  >> "%DP%" echo format quick fs=ntfs label="Recovery"
  >> "%DP%" echo assign letter=%L_REC%
  if /i "%FIRMWARE%"=="UEFI" (
    >> "%DP%" echo set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
    >> "%DP%" echo gpt attributes=0x8000000000000001
  ) else (
    >> "%DP%" echo set id=27
  )
)
if not "%WINDOWS_GB%"=="0" (
  >> "%DP%" echo create partition primary
  >> "%DP%" echo format quick fs=ntfs label="%DATA_LABEL%"
  >> "%DP%" echo assign letter=%L_DATA%
)
call :say Erasing and partitioning disk %DISK%
diskpart /s "%DP%" >> "%LOG%" 2>&1
if errorlevel 1 call :stop "diskpart couldn't partition disk %DISK%."
if not exist "%L_WIN%:\" call :stop "The Windows partition didn't appear."

rem ---------------------------------------------------------------- apply
call :say Applying Windows, this takes a while
dism /Apply-Image /ImageFile:"%IMAGE%" %SWM_ARG% /Index:1 /ApplyDir:%L_WIN%:\
if errorlevel 1 call :stop "DISM couldn't apply the image. The media may be damaged."

md "%L_WIN%:\Windows\Panther" >nul 2>&1
copy /y "%MEDIA%\autounattend.xml" "%L_WIN%:\Windows\Panther\unattend.xml" >nul
if errorlevel 1 call :stop "Couldn't copy the answer file."

call :say Making the disk bootable
if /i "%FIRMWARE%"=="UEFI" (
  "%L_WIN%:\Windows\System32\bcdboot.exe" %L_WIN%:\Windows /s %L_SYS%: /f UEFI >> "%LOG%" 2>&1
) else (
  "%L_WIN%:\Windows\System32\bcdboot.exe" %L_WIN%:\Windows /s %L_SYS%: /f BIOS >> "%LOG%" 2>&1
)
if errorlevel 1 call :stop "bcdboot couldn't make the disk bootable."

if not "%RECOVERY_MB%"=="0" (
  set "RE=%L_WIN%:\Windows\System32\Recovery\Winre.wim"
  if exist "!RE!" (
    attrib -h -s "!RE!"
    md "%L_REC%:\Recovery\WindowsRE" >nul 2>&1
    copy /y "!RE!" "%L_REC%:\Recovery\WindowsRE\" >nul
    "%L_WIN%:\Windows\System32\reagentc.exe" /setreimage /path %L_REC%:\Recovery\WindowsRE /target %L_WIN%:\Windows >> "%LOG%" 2>&1
    if errorlevel 1 call :say Recovery tools weren't registered; the provisioning log will show it
  )
)

copy /y "%LOG%" "%L_WIN%:\WinImage\pe-install.log" >nul 2>&1
call :say Done. Restarting into Windows.
wpeutil reboot
goto :hold

rem ---------------------------------------------------------------- helpers
:consider
rem %1 disk number, %2 size, %3 unit (GB or TB; MB is too small to matter)
set "N=%~1"
set "SIZE=%~2"
set "UNIT=%~3"
for /f "delims=0123456789" %%x in ("%N%%SIZE%") do goto :eof
if /i "%UNIT%"=="TB" (set /a GB=SIZE*1024) else if /i "%UNIT%"=="GB" (set /a GB=SIZE) else (goto :eof)
if !GB! LSS %MIN_GB% goto :eof
(echo select disk %N%& echo detail disk) > "%T%\detail.txt"
diskpart /s "%T%\detail.txt" > "%T%\detail%N%.txt"
findstr /r /i /c:": *USB *$" /c:": *SD *$" /c:": *MMC *$" /c:": *1394 *$" /c:": *File Backed Virtual *$" "%T%\detail%N%.txt" >nul 2>&1
if not errorlevel 1 (
  call :say Disk %N% is removable, skipping it
  goto :eof
)
set /a COUNT+=1
call :say Disk %N%: !GB! GB
set "TAKE=0"
if not defined BEST_GB set "TAKE=1"
if defined BEST_GB (
  if /i "%IF_MULTIPLE%"=="Largest" (if !GB! GTR !BEST_GB! set "TAKE=1") else (if !GB! LSS !BEST_GB! set "TAKE=1")
)
if "!TAKE!"=="1" (
  set "BEST_GB=!GB!"
  set "DISK=%N%"
)
goto :eof

:say
echo %*
>> "%LOG%" echo %*
goto :eof

:stop
echo.
echo   ==============================================================
echo   STOPPED. Nothing further was changed.
echo   %~1
echo   ==============================================================
>> "%LOG%" echo STOPPED: %~1
if defined MEDIA copy /y "%LOG%" "%MEDIA%\winimage-last-stop.log" >nul 2>&1
echo   This PC will turn off in 5 minutes.
ping -n 300 127.0.0.1 >nul
wpeutil shutdown
:hold
ping -n 3600 127.0.0.1 >nul
goto :hold
