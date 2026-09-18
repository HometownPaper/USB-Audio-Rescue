# extras\lexicon-lambda-asio.ps1  --  USB Audio Rescue for Windows 11
#
# FOR LEXICON LAMBDA OWNERS ONLY. Gets Lexicon's own ASIO plug-in ("Lambda ASIO") working
# so Pro Tools, Cubase, Reaper and other ASIO hosts can use the Lambda.
#
# Facts this is built on (checked 2026-09-17):
#   - Lexicon's "Lambda Driver v2.7 (Windows)" from lexiconpro.com contains NO audio
#     driver. It is LambdaAsio.dll, an ASIO plug-in that streams through Windows' own
#     USB audio driver, plus a firmware-update helper. It works on top of the rescue
#     package (or the inbox driver once Microsoft fixes it).
#   - Its installer is a 7-Zip self-extractor signed by Harman International. Its MSI
#     registers the plug-in through custom actions under the fixed COM class
#     {DBBE671F-C4A7-4579-A700-D9C7C45855BA}; regsvr32 on the DLL alone fails ("-101").
#   - Windows 10/11 ship bsdtar (tar.exe), which reads 7-Zip archives.
#
# This script downloads Lexicon's installer from Harman's own server, verifies Harman's
# digital signature on it, extracts the two DLLs WITHOUT running the installer, copies
# them next to this script, and writes the three registry keys Pro Tools looks for.
# Nothing of Lexicon's is redistributed with this repository.
#
# Usage:
#   .\lexicon-lambda-asio.ps1               download, extract, register (one UAC prompt)
#   .\lexicon-lambda-asio.ps1 -ExtractOnly  download and extract only, no registry change
#   .\lexicon-lambda-asio.ps1 -Uninstall    remove the registry keys (one UAC prompt)
#
# Smart App Control: LambdaAsio.dll is not digitally signed (Harman never signed it). If
# Smart App Control is ON, Windows blocks unsigned DLLs and your DAW may fail to start
# with "Bad Image ... 0xc0e90002". Microsoft offers no per-app exception; the script
# warns you if it is on.

param([switch] $ExtractOnly, [switch] $Uninstall)

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSCommandPath
$work  = Join-Path $root 'lexicon'
$log   = Join-Path $root 'lexicon-lambda-asio-log.txt'
$clsid = '{DBBE671F-C4A7-4579-A700-D9C7C45855BA}'
$url   = 'https://adn.harmanpro.com/softwares/wares/65_1331323965/LambdaDriverInstaller.exe'
$knownSha256 = 'D87E8C4C2B8197F9C53EFF7E6DD9A2E14085F56FD17FA1D304E9353C9994BDE9'   # as downloaded 2026-09-17
function Log($s) { $s | Out-File $log -Append -Encoding utf8; Write-Host $s }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Uninstall) {
    if (-not $isAdmin) { Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Uninstall'; exit }
    "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') uninstall ===" | Out-File $log -Encoding utf8
    foreach ($k in "HKLM:\SOFTWARE\Classes\CLSID\$clsid", "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$clsid", 'HKLM:\SOFTWARE\ASIO\Lambda ASIO driver') {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force; Log "removed $k" }
    }
    Log 'DONE. Lambda ASIO is no longer registered. The extracted files stay in the lexicon folder; delete them if you like.'
    exit
}

"=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') lexicon lambda asio ===" | Out-File $log -Encoding utf8
New-Item -ItemType Directory -Force $work | Out-Null

# ---- 1. download and verify ---------------------------------------------------------
$exe = Join-Path $work 'LambdaDriverInstaller.exe'
if (-not (Test-Path $exe)) {
    Log "downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
}
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash
$sig = Get-AuthenticodeSignature $exe
Log "installer: $((Get-Item $exe).Length) bytes, SHA-256 $sha"
Log "signature: $($sig.Status) signer=$($sig.SignerCertificate.Subject)"
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Harman') { throw 'Refusing: the downloaded installer is not validly signed by Harman International. Do not use it.' }
if ($sha -ne $knownSha256) { Log 'NOTE: the file differs from the one this script was written against (Harman may have republished it). The Harman signature is valid, so continuing.' }

# ---- 2. carve the 7-Zip payload and extract with Windows' tar ------------------------
$bytes = [IO.File]::ReadAllBytes($exe)
$sig7z = [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)
$off = -1
for ($i = 0; $i -lt $bytes.Length - 6; $i++) {
    if ($bytes[$i] -eq 0x37 -and $bytes[$i+1] -eq 0x7A -and $bytes[$i+2] -eq 0xBC -and $bytes[$i+3] -eq 0xAF -and $bytes[$i+4] -eq 0x27 -and $bytes[$i+5] -eq 0x1C) { $off = $i; break }
}
if ($off -lt 0) { throw 'No 7-Zip payload found inside the installer; Harman may have changed the packaging.' }
$payload = New-Object byte[] ($bytes.Length - $off)
[Array]::Copy($bytes, $off, $payload, 0, $payload.Length)
$p7z = Join-Path $work 'payload.7z'
[IO.File]::WriteAllBytes($p7z, $payload)
Log "7-Zip payload at byte $off, $($payload.Length) bytes"

$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tar) { throw 'tar.exe not found. Windows 10 1803 and later include it; otherwise extract payload.7z with 7-Zip and copy the two LambdaAsio.dll files into the lexicon folder yourself.' }
$x = Join-Path $work 'extracted'
if (Test-Path $x) { Remove-Item $x -Recurse -Force }
New-Item -ItemType Directory -Force $x | Out-Null
& tar.exe -xf $p7z -C $x
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

# ---- 3. pick the x64 and x86 DLLs by their PE machine type ----------------------------
$dll64 = $null; $dll32 = $null
foreach ($f in (Get-ChildItem $x -Recurse -Filter 'LambdaAsio.dll' -File)) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $machine = [BitConverter]::ToUInt16($b, $pe + 4)
    if ($machine -eq 0x8664) { $dll64 = $f } elseif ($machine -eq 0x014C) { $dll32 = $f }
}
if (-not $dll64) { throw 'x64 LambdaAsio.dll not found in the installer.' }
Copy-Item $dll64.FullName (Join-Path $work 'LambdaAsio_x64.dll') -Force
if ($dll32) { Copy-Item $dll32.FullName (Join-Path $work 'LambdaAsio_x86.dll') -Force }
Log "LambdaAsio_x64.dll: $($dll64.Length) bytes, $((Get-Item $dll64.FullName).VersionInfo.FileDescription) $((Get-Item $dll64.FullName).VersionInfo.FileVersion)"
if ($dll32) { Log "LambdaAsio_x86.dll: $($dll32.Length) bytes" }
Remove-Item $x -Recurse -Force
Remove-Item $p7z -Force
if ($ExtractOnly) { Log 'EXTRACT DONE (no registry changes made).'; exit 0 }

# ---- 4. register (elevated) -------------------------------------------------------------
if (-not $isAdmin) {
    Log 'registering (UAC prompt)...'
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}
$d64 = Join-Path $work 'LambdaAsio_x64.dll'
$d32 = Join-Path $work 'LambdaAsio_x86.dll'
foreach ($pair in @(@{ root = 'HKLM:\SOFTWARE\Classes\CLSID'; dll = $d64 }, @{ root = 'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID'; dll = $d32 })) {
    if (-not (Test-Path $pair.dll)) { continue }
    $k = Join-Path $pair.root $clsid
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name '(default)' -Value 'Lambda ASIO'
    $ip = Join-Path $k 'InprocServer32'
    New-Item -Path $ip -Force | Out-Null
    Set-ItemProperty -Path $ip -Name '(default)' -Value $pair.dll
    Set-ItemProperty -Path $ip -Name 'ThreadingModel' -Value 'Apartment'
    Log "registered $($ip.Replace('HKLM:\SOFTWARE\Classes\','')) -> $($pair.dll)"
}
$asio = 'HKLM:\SOFTWARE\ASIO\Lambda ASIO driver'
New-Item -Path $asio -Force | Out-Null
Set-ItemProperty -Path $asio -Name 'CLSID' -Value $clsid
Set-ItemProperty -Path $asio -Name 'Description' -Value 'Lambda ASIO'
Log "registered $asio"

try {
    $o = [Activator]::CreateInstance([type]::GetTypeFromCLSID([guid]$clsid))
    [Runtime.InteropServices.Marshal]::ReleaseComObject($o) | Out-Null
    Log 'smoke test: Windows can create the Lambda ASIO object'
} catch { Log "smoke test FAILED: $($_.Exception.Message)" }

$sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
if ($sac -eq 1) { Log 'WARNING: Smart App Control is ON. It blocks unsigned DLLs like LambdaAsio.dll (and, for example, Pro Tools own BUI.dll). Windows Security > App & browser control > Smart App Control settings > Off, if your DAW fails with "Bad Image 0xc0e90002".' }
Log 'DONE. In your DAW choose "Lambda ASIO". Keep this folder where it is: the registration points at it.'
