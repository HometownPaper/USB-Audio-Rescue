# uninstall.ps1  --  USB Audio Rescue for Windows 11
#
# Puts everything back: removes the rescue driver package from Windows, removes the
# one-time certificate from the trust stores, and lets Windows re-pick its own driver
# for the device. Re-launches itself elevated (one UAC prompt). Log: uninstall-log.txt
#
# Use this if the rescue did not help, or once Microsoft has shipped a fixed
# usbaudio.sys and you want the device back on the inbox driver.

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}

$root = Split-Path -Parent $PSCommandPath
$log  = Join-Path $root 'uninstall-log.txt'
function Log($s) { $s | Out-File $log -Append -Encoding utf8; Write-Host $s }
"=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') uninstall ===" | Out-File $log -Encoding utf8

# 1. Remove the package (uninstalls it from the devices first).
$enum = & pnputil.exe /enum-drivers 2>&1
$removed = 0; $cand = $null
for ($i = 0; $i -lt $enum.Count; $i++) {
    if ($enum[$i] -match '^Published Name:\s*(\S+)') { $cand = $Matches[1] }
    if ($enum[$i] -match '^Original Name:\s*usbaudio_rescue\.inf') {
        Log "removing $cand"
        & pnputil.exe /delete-driver $cand /uninstall /force 2>&1 | ForEach-Object { Log "  $_" }
        $removed++
    }
}
if ($removed -eq 0) { Log 'rescue package not found in the driver store; nothing to remove' }

# 2. Un-trust the certificate.
$thumbFile = Join-Path $root 'cert-thumbprint.txt'
if (Test-Path $thumbFile) {
    $thumb = (Get-Content $thumbFile).Trim()
    foreach ($store in 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPublisher', 'Cert:\CurrentUser\My') {
        $c = Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb }
        if ($c) { $c | Remove-Item -ErrorAction SilentlyContinue; Log "removed certificate from $store" }
    }
}

# 3. Let Windows re-pick a driver.
& pnputil.exe /scan-devices 2>&1 | ForEach-Object { Log "  $_" }
Log 'DONE. Unplug and replug the device; it comes back on the inbox Microsoft driver.'
