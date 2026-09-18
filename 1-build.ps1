# 1-build.ps1  --  USB Audio Rescue for Windows 11
#
# Builds a local driver package for USB Audio Class 1.0 devices that Microsoft's
# usbaudio.sys refuses to start ("This device cannot start (Code 10)") since the
# September 2026 Windows update, or that Windows puts to sleep after 30 seconds of
# silence and never wakes up properly.
#
# What it does, on THIS machine only:
#   1. Finds your USB Audio Class 1.0 interfaces (or takes the ones you name).
#   2. Takes a copy of Microsoft's own usbaudio.sys that is already on your disk
#      (an older version from C:\Windows\WinSxS for the Code 10 bug, or the current
#      one if you only want to stop the sleep), checks Microsoft's signature on it,
#      and renames the copy so it can never collide with the real one.
#   3. Writes a driver INF that binds that copy to your device by exact hardware ID,
#      with idle power-down disabled.
#   4. Builds the package catalog. Signing and trusting it is step 2 (your click).
#
# Nothing is installed by this script and nothing needs administrator rights.
# Nothing from Microsoft is downloaded or redistributed: the file is your own.
#
# Usage:
#   .\1-build.ps1                      auto: every interface failing with Code 10 under usbaudio.sys
#   .\1-build.ps1 -ListOnly            just show the USB audio interfaces Windows sees
#   .\1-build.ps1 -HardwareId 'USB\VID_1210&PID_0009&MI_00','USB\VID_1210&PID_0009&MI_06'
#   .\1-build.ps1 -HardwareId ... -NoSleepOnly    keep the current driver version, only disable idle power-down
#   .\1-build.ps1 -SourceSys C:\path\to\usbaudio.sys   use this Microsoft-signed file instead of searching WinSxS

param(
    [string[]] $HardwareId,
    [string]   $SourceSys,
    [switch]   $NoSleepOnly,
    [switch]   $ListOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$pkg  = Join-Path $root 'package'
$log  = Join-Path $root 'build-log.txt'
function Log($s) { $s | Out-File $log -Append -Encoding utf8; Write-Host $s }
"=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') build ===" | Out-File $log -Encoding utf8

# ---- 0. environment -------------------------------------------------------------
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw "This tool supports 64-bit x64 Windows only (found $env:PROCESSOR_ARCHITECTURE)." }
$os = Get-CimInstance Win32_OperatingSystem
Log "Windows: $($os.Caption) build $($os.BuildNumber) UBR $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
$inboxSys = Get-Item 'C:\Windows\System32\drivers\usbaudio.sys'
$inboxVer = [version]$inboxSys.VersionInfo.FileVersion.Split(' ')[0]
Log "inbox usbaudio.sys: $inboxVer"

# ---- 1. find USB Audio Class 1.0 interfaces ---------------------------------------
Log '--- USB audio interfaces present ---'
$all = @()
foreach ($d in (Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_*' })) {
    $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_CompatibleIds','DEVPKEY_Device_HardwareIds','DEVPKEY_Device_ProblemCode','DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_DriverVersion','DEVPKEY_Device_Service' -ErrorAction SilentlyContinue
    $compat = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_CompatibleIds').Data
    if (-not ($compat -match '^USB\\Class_01(&|$)')) { continue }           # USB Audio Class only
    if ($compat -match '^USB\\Class_01&SubClass_0[1-3]&Prot_20') { continue } # Class 2.0 uses usbaudio2.sys, not affected
    $hw = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_HardwareIds').Data
    $id = ($hw | Where-Object { $_ -notmatch '&REV_' } | Select-Object -First 1)
    if (-not $id) { $id = ($hw | Select-Object -First 1) -replace '&REV_[0-9A-Fa-f]{4}', '' }
    $o = [pscustomobject]@{
        Name     = $d.FriendlyName
        Instance = $d.InstanceId
        Id       = $id
        Problem  = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        Inf      = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data
        Version  = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion').Data
        Service  = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data
    }
    $all += $o
    Log ("  {0,-30} {1,-40} problem={2,-3} inf={3,-14} ver={4,-16} svc={5}" -f $o.Name, $o.Id, $o.Problem, $o.Inf, $o.Version, $o.Service)
}
if (-not $all) { Log 'No USB Audio Class 1.0 interface is connected. Plug the device in and run again.'; exit 1 }
if ($ListOnly) { exit 0 }

# ---- 2. choose the interfaces ------------------------------------------------------
if ($HardwareId) {
    # accept -HardwareId 'a','b'  and  -HardwareId 'a,b'  (a command line hands the list over as one string)
    $HardwareId = @($HardwareId | ForEach-Object { $_ -split ',' } | ForEach-Object { ($_.Trim() -replace '&REV_[0-9A-Fa-f]{4}', '') } | Where-Object { $_ })
    $chosen = @()
    foreach ($h in $HardwareId) {
        $m = $all | Where-Object { $_.Id -ieq $h }
        if (-not $m) { throw "No present device with hardware ID '$h'. Run with -ListOnly to see the IDs." }
        $chosen += $m
    }
} else {
    $chosen = @($all | Where-Object { $_.Problem -eq 10 -and $_.Inf -ieq 'wdma_usb.inf' })
    if (-not $chosen) {
        Log 'No interface is failing with Code 10 under Microsoft usbaudio.sys right now.'
        Log 'If your device works but goes to sleep, name it: .\1-build.ps1 -HardwareId <id from the list above> -NoSleepOnly'
        exit 1
    }
}
$mode = if ($NoSleepOnly) { 'no-sleep (current driver version, idle power-down disabled)' } else { 'rescue (older Microsoft usbaudio.sys, idle power-down disabled)' }
Log "mode: $mode"
Log "interfaces: $(($chosen | ForEach-Object { $_.Id }) -join ', ')"

# ---- 3. pick the Microsoft binary ------------------------------------------------
if ($SourceSys) {
    $src = Get-Item $SourceSys
} elseif ($NoSleepOnly) {
    $src = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'wdma_usb.inf_amd64_*' | ForEach-Object { Get-ChildItem $_.FullName -Filter 'usbaudio.sys' -File } | Sort-Object { [version]$_.VersionInfo.FileVersion.Split(' ')[0] } -Descending | Select-Object -First 1
    if (-not $src) { $src = $inboxSys }
} else {
    $cands = Get-ChildItem 'C:\Windows\WinSxS' -Directory -Filter 'amd64_dual_wdma_usb.inf_31bf3856ad364e35_*' | ForEach-Object {
        $f = Get-ChildItem $_.FullName -Filter 'usbaudio.sys' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { [pscustomobject]@{ File = $f; Version = [version]$f.VersionInfo.FileVersion.Split(' ')[0] } }
    } | Where-Object { $_.Version -lt $inboxVer } | Sort-Object Version -Descending
    Log ("older Microsoft usbaudio.sys on this disk: " + $(if ($cands) { ($cands | ForEach-Object { $_.Version }) -join ', ' } else { 'none' }))
    if (-not $cands) {
        Log 'No older usbaudio.sys found in C:\Windows\WinSxS. Options: copy a Microsoft-signed usbaudio.sys from another PC or from Windows install media and pass it with -SourceSys, or use -NoSleepOnly if the device starts.'
        exit 1
    }
    $src = $cands[0].File
}
$sig = Get-AuthenticodeSignature $src.FullName
$srcVer = $src.VersionInfo.FileVersion.Split(' ')[0]
Log "source: $($src.FullName) version $srcVer signature=$($sig.Status) signer=$($sig.SignerCertificate.Subject)"
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Refusing: the source usbaudio.sys is not a validly Microsoft-signed file. Only a Microsoft-signed copy is safe to load.' }

# ---- 4. stage the package -------------------------------------------------------
New-Item -ItemType Directory -Force $pkg | Out-Null
Get-ChildItem $pkg -File | ForEach-Object { [IO.File]::Delete($_.FullName) }
$sysDst = Join-Path $pkg 'usbaudio_rescue.sys'
Copy-Item $src.FullName $sysDst -Force
$sig2 = Get-AuthenticodeSignature $sysDst
if ($sig2.Status -ne 'Valid') { throw 'The copied file no longer verifies. Aborting.' }
Log "staged: $sysDst (signature still $($sig2.Status) after the rename; SHA-256 $((Get-FileHash $sysDst -Algorithm SHA256).Hash))"

# ---- 5. write the INF -------------------------------------------------------------
$models = ($chosen | ForEach-Object { "%Rescue.DeviceDesc% = USBAudio_Rescue, $($_.Id)" }) -join "`r`n"
$idList = ($chosen | ForEach-Object { $_.Id }) -join ', '
$today  = Get-Date -Format 'MM/dd/yyyy'
$ver    = "$srcVer"
$inf = @"
; usbaudio_rescue.inf  --  generated $today by USB Audio Rescue (1-build.ps1)
;
; Binds these USB Audio Class 1.0 interfaces, by exact hardware ID, to a renamed copy
; of Microsoft's own usbaudio.sys $srcVer taken from this machine:
;   $idList
; The copy runs as service "usbaudio_rescue" so it never collides with the inbox
; usbaudio.sys that every other USB audio device keeps using. A hardware-ID match
; outranks the inbox driver's USB\Class_01 match, so Windows keeps this package on any
; port and across cumulative updates.
;
; Idle power-down is DISABLED: Microsoft's INF sets PortCls PowerSettings to 0x1e
; (30 s) then D3; many older interfaces never come back from that. Per Microsoft's
; "PortCls Registry Power Settings" documentation, 0 disables idle management.
;
; Install sections are a cut-down copy of the [USBAudio] sections of Microsoft's
; wdma_usb.inf: no SysFx APO, "EP\" endpoint key instead of the reserved "MSEP\".
; Undo: uninstall.ps1 (pnputil /delete-driver oemNN.inf /uninstall), then replug.

[Version]
Signature   = "`$WINDOWS NT`$"
Class       = MEDIA
ClassGUID   = {4d36e96c-e325-11ce-bfc1-08002be10318}
Provider    = %Provider%
CatalogFile = usbaudio_rescue.cat
DriverVer   = $today,$ver
PnpLockdown = 1

[SourceDisksNames]
1 = %DiskName%,,,""

[SourceDisksFiles]
usbaudio_rescue.sys = 1

[DestinationDirs]
USBAudio_Rescue.CopyList = 12   ; %SystemRoot%\system32\drivers

[Manufacturer]
%Mfg% = Rescue, NTamd64

[Rescue.NTamd64]
$models

;============================================================================

[USBAudio_Rescue]
Include   = ks.inf, wdmaudio.inf
Needs     = KS.Registration, WDMAUDIO.Registration, mssysfx.CopyFilesAndRegisterCapX
CopyFiles = USBAudio_Rescue.CopyList
AddReg    = USBAudio_Rescue.AddReg
PreferDeviceInfo = 1

[USBAudio_Rescue.Interfaces]
AddInterface = %KSCATEGORY_AUDIO%,   "GLOBAL", USBAudio_Rescue.Interface,
AddInterface = %KSCATEGORY_RENDER%,  "GLOBAL", USBAudio_Rescue.Interface,
AddInterface = %KSCATEGORY_CAPTURE%, "GLOBAL", USBAudio_Rescue.Interface,

[USBAudio_Rescue.Interface]
AddReg = USBAudio_Rescue.Interface.AddReg, USBAudio_Rescue.EPProperties.AddReg

[USBAudio_Rescue.Interface.AddReg]
HKR,,FriendlyName,,%Rescue.DeviceDesc%
HKR,,CurveType,1,01,00,00,00
HKR,,CLSID,,%Proxy.CLSID%

[USBAudio_Rescue.EPProperties.AddReg]
HKR,"EP\\0",%PKEY_AudioEndpoint_Association%,,%KSNODETYPE_ANY%
HKR,"EP\\0",%PKEY_AudioEndpoint_Supports_EventDriven_Mode%,0x00010001,0x1

[USBAudio_Rescue.AddReg]
HKR,,AssociatedFilters,,"wdmaud,redbook"
HKR,,Driver,,usbaudio_rescue.sys
HKR,,NTMPDriver,,"usbaudio_rescue.sys,sbemul.sys"
; 0 = idle power management disabled (Microsoft: PortCls Registry Power Settings)
HKR,PowerSettings, ConservationIdleTime,%REG_BINARY%,00,00,00,00
HKR,PowerSettings, PerformanceIdleTime,%REG_BINARY%,00,00,00,00
HKR,PowerSettings, IdlePowerState,%REG_BINARY%,3,00,00,00

HKR,,CLSID,,%Proxy.CLSID%

HKR,Drivers,SubClasses,,"wave,midi,mixer,aux"

HKR,Drivers\wave\wdmaud.drv, Driver,,wdmaud.drv
HKR,Drivers\midi\wdmaud.drv, Driver,,wdmaud.drv
HKR,Drivers\mixer\wdmaud.drv,Driver,,wdmaud.drv
HKR,Drivers\aux\wdmaud.drv,Driver,,wdmaud.drv

HKR,Drivers\wave\wdmaud.drv,Description,,%Rescue.DeviceDesc%
HKR,Drivers\midi\wdmaud.drv,Description,,%WDM_MIDI%
HKR,Drivers\mixer\wdmaud.drv,Description,,%Rescue.DeviceDesc%
HKR,Drivers\aux\wdmaud.drv,Description,,%Rescue.DeviceDesc%

HKLM,%MediaCategories%\%USBGUID.BassBoost%,Name,,%USBNode.BassBoost%
HKLM,%MediaCategories%\%USBGUID.BassBoost%,Display,1,00,00,00,00
HKLM,%MediaCategories%\%USBGUID.StereoExtend%,Name,,%USBNode.StereoExtend%
HKLM,%MediaCategories%\%USBGUID.StereoExtend%,Display,1,00,00,00,00

[USBAudio_Rescue.CopyList]
usbaudio_rescue.sys

[USBAudio_Rescue.Services]
AddService = usbaudio_rescue, 0x00000002, usbaudio_rescue_Service_Inst

[usbaudio_rescue_Service_Inst]
DisplayName    = %USBAudio_Rescue.SvcDesc%
ServiceType    = 1                  ; SERVICE_KERNEL_DRIVER
StartType      = 3                  ; SERVICE_DEMAND_START
ErrorControl   = 1                  ; SERVICE_ERROR_NORMAL
ServiceBinary  = %12%\usbaudio_rescue.sys

;============================================================================

[Strings]
Provider   = "USB Audio Rescue (local package around Microsoft usbaudio.sys $srcVer)"
Mfg        = "USB Audio Rescue"
DiskName   = "USB Audio Rescue package"
Rescue.DeviceDesc       = "USB Audio Device (rescue)"
USBAudio_Rescue.SvcDesc = "USB Audio Driver (WDM) $srcVer, USB Audio Rescue"
WDM_MIDI   = "WDM MIDI Device"
REG_BINARY = 0x00000001

MediaCategories = "SYSTEM\CurrentControlSet\Control\MediaCategories"
USBGUID.BassBoost    = "{1A71EBE0-959E-11D1-B448-00A0C9255AC1}"
USBGUID.StereoExtend = "{FD4F0300-9632-11D1-B448-00A0C9255AC1}"
USBNode.BassBoost    = "Bass Boost"
USBNode.StereoExtend = "Stereo Extender"

Proxy.CLSID        = "{17CCA71B-ECD7-11D0-B908-00A0C9223196}"
KSCATEGORY_AUDIO   = "{6994ad04-93ef-11d0-a3cc-00a0c9223196}"
KSCATEGORY_RENDER  = "{65E8773E-8F56-11D0-A3B9-00A0C9223196}"
KSCATEGORY_CAPTURE = "{65E8773D-8F56-11D0-A3B9-00A0C9223196}"

PKEY_AudioEndpoint_Association               = "{1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E},2"
PKEY_AudioEndpoint_Supports_EventDriven_Mode = "{1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E},7"
KSNODETYPE_ANY = "{00000000-0000-0000-0000-000000000000}"
"@
$infPath = Join-Path $pkg 'usbaudio_rescue.inf'
[IO.File]::WriteAllText($infPath, $inf, [Text.Encoding]::ASCII)

# parse-check with Windows' own INF parser
Add-Type -Namespace UsbAudioRescue -Name SetupApi -MemberDefinition @'
[DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SetupOpenInfFileW(string FileName, string InfClass, uint InfStyle, out uint ErrorLine);
[DllImport("setupapi.dll")]
public static extern void SetupCloseInfFile(IntPtr InfHandle);
'@
$line = 0
$h = [UsbAudioRescue.SetupApi]::SetupOpenInfFileW($infPath, 'MEDIA', 2, [ref]$line)
if ($h -eq [IntPtr]-1) { throw ("Windows rejected the generated INF at line {0}, error 0x{1:X8}" -f $line, ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -band 0xFFFFFFFF)) }
[UsbAudioRescue.SetupApi]::SetupCloseInfFile($h)
Log "INF written and parse-checked: $infPath"

# ---- 6. catalog ----------------------------------------------------------------
$cat = New-FileCatalog -Path $pkg -CatalogFilePath (Join-Path $pkg 'usbaudio_rescue.cat') -CatalogVersion 2
$t = Test-FileCatalog -Path $pkg -CatalogFilePath $cat.FullName -Detailed
Log "catalog: $($cat.FullName) covers $($t.CatalogItems.Keys -join ', ') status=$($t.Status)"

Log ''
Log 'BUILD DONE. Next: run 2-sign-and-trust.ps1 (one UAC prompt), then 3-install.ps1.'
