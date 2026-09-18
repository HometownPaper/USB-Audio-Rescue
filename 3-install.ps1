# 3-install.ps1  --  USB Audio Rescue for Windows 11
#
# Installs the signed package from 1-build.ps1 / 2-sign-and-trust.ps1 and binds it to
# the interfaces named in the INF. Re-launches itself elevated (one UAC prompt).
# Safe to run again after a rebuild: it removes the earlier revision of this package
# first (the device falls back to the inbox driver for a second, then comes back).
#
# Log: install-log.txt

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}

$root = Split-Path -Parent $PSCommandPath
$pkg  = Join-Path $root 'package'
$inf  = Join-Path $pkg  'usbaudio_rescue.inf'
$cat  = Join-Path $pkg  'usbaudio_rescue.cat'
$log  = Join-Path $root 'install-log.txt'
function Log($s) { $s | Out-File $log -Append -Encoding utf8; Write-Host $s }
"=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') install ===" | Out-File $log -Encoding utf8

if (-not (Test-Path $inf)) { Log "STOP: $inf not found (run 1-build.ps1 first)"; exit 1 }
$sig = Get-AuthenticodeSignature $cat
Log "catalog signature: $($sig.Status) - $($sig.StatusMessage)"
if ($sig.Status -ne 'Valid') { Log 'STOP: the catalog is not signed and trusted yet. Run 2-sign-and-trust.ps1 first.'; exit 1 }

# Hardware IDs come from the INF's model section, so this script never guesses.
$hwids = @(Get-Content $inf | Where-Object { $_ -match '^%Rescue\.DeviceDesc%\s*=\s*USBAudio_Rescue,\s*(USB\\\S+)' } | ForEach-Object { $Matches[1] })
Log "interfaces in the package: $($hwids -join ', ')"

function Find-RescuePackage {
    $enum = & pnputil.exe /enum-drivers 2>&1
    $found = @(); $cand = $null
    for ($i = 0; $i -lt $enum.Count; $i++) {
        if ($enum[$i] -match '^Published Name:\s*(\S+)') { $cand = $Matches[1] }
        if ($enum[$i] -match '^Original Name:\s*usbaudio_rescue\.inf') { $found += $cand }
    }
    return $found
}

# 0. Remove an earlier revision so only one copy of this package exists.
foreach ($old in Find-RescuePackage) {
    Log "--- removing earlier revision $old ---"
    & pnputil.exe /delete-driver $old /uninstall /force 2>&1 | ForEach-Object { Log "  $_" }
}

# 1. Add to the driver store and install on matching devices.
Log '--- pnputil /add-driver /install ---'
& pnputil.exe /add-driver "$inf" /install 2>&1 | ForEach-Object { Log "  $_" }
Start-Sleep -Seconds 3
$oem = Find-RescuePackage | Select-Object -First 1
Log "package published as: $oem"
if (-not $oem) { Log 'STOP: pnputil did not add the package. Read the lines above; the usual causes are a catalog that is not trusted (rerun step 2) or an INF error.'; exit 1 }

# 2. Force any named interface that is still on another driver.
Add-Type -Namespace UsbAudioRescue -Name NewDev -MemberDefinition @'
[DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent, string HardwareId, string FullInfPath, uint InstallFlags, out bool bRebootRequired);
'@
foreach ($hwid in $hwids) {
    $dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "$hwid\*" } | Select-Object -First 1
    if (-not $dev) { Log "not present right now: $hwid (it will pick this package up when plugged in)"; continue }
    $curInf = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_DriverInfPath -ErrorAction SilentlyContinue).Data
    if ($curInf -ieq $oem) { Log "$hwid is on $oem"; continue }
    $reboot = $false
    $ok = [UsbAudioRescue.NewDev]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, $hwid, $inf, 0x1, [ref]$reboot)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Log ("force {0} -> ok={1} lastError=0x{2:X8} reboot={3}" -f $hwid, $ok, ($err -band 0xFFFFFFFF), $reboot)
}
Start-Sleep -Seconds 3

# 3. Report.
Log '--- device state ---'
$bad = 0
foreach ($hwid in $hwids) {
    foreach ($dev in (Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "$hwid\*" })) {
        $p = Get-PnpDeviceProperty -InstanceId $dev.InstanceId -ErrorAction SilentlyContinue
        $prob = ($p | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
        if ($prob -ne 0) { $bad++ }
        Log ("{0,-8} {1,-28} {2}  problem={3}  inf={4}  ver={5}  svc={6}" -f $dev.Status, $dev.FriendlyName, $dev.InstanceId, $prob,
            ($p | Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data,
            ($p | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion').Data,
            ($p | Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data)
    }
}
Log '--- audio endpoints now present ---'
Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { Log ("  {0,-6} {1}" -f $_.Status, $_.FriendlyName) }
$svc = Get-CimInstance Win32_SystemDriver -Filter "Name='usbaudio_rescue'" -ErrorAction SilentlyContinue
Log ("service usbaudio_rescue: " + $(if ($svc) { "$($svc.State) ($($svc.PathName))" } else { 'not present' }))
Log ''
if ($bad -eq 0) {
    Log 'INSTALL DONE. Your device is on the rescue package. Now run 4-destroy-key.ps1.'
    Log 'Problem codes to know if it ever shows one: 52 = the certificate is not trusted (rerun step 2); 10 = this older driver version also fails on your device (try -SourceSys with another version, then rebuild).'
} else {
    Log 'One or more interfaces still show a problem code. See the note above; uninstall.ps1 puts everything back.'
}
