# 2-sign-and-trust.ps1  --  USB Audio Rescue for Windows 11
#
# Creates a one-time code-signing certificate on THIS PC, signs the package catalog
# built by 1-build.ps1, and marks that certificate trusted on this PC so Windows will
# accept the package. Re-launches itself elevated (one UAC prompt).
#
# Why a certificate at all: Windows only installs driver packages whose catalog is
# signed by a publisher the machine trusts. The kernel binary inside the package is
# still Microsoft's own, verified by Microsoft's signature; this certificate only vouches
# for the INF and catalog around it. The private key is non-exportable, lives only in
# your user store, and 4-destroy-key.ps1 deletes it, after which the trusted certificate
# can never sign anything again. (libwdi / Zadig use the same method.)
#
# Log: sign-and-trust-log.txt

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}

$root = Split-Path -Parent $PSCommandPath
$pkg  = Join-Path $root 'package'
$cat  = Join-Path $pkg  'usbaudio_rescue.cat'
$cer  = Join-Path $root 'UsbAudioRescue-Trust.cer'
$log  = Join-Path $root 'sign-and-trust-log.txt'

Start-Transcript -Path $log -Force | Out-Null
try {
    if (-not (Test-Path $cat)) { throw "catalog not found: $cat  (run 1-build.ps1 first)" }

    $existing = Get-AuthenticodeSignature $cat
    if ($existing.Status -eq 'Valid') { 'The catalog is already signed and trusted on this PC. Nothing to do.'; exit 0 }

    # Reuse the certificate if a previous run left it in the user store (re-build case).
    $thumbFile = Join-Path $root 'cert-thumbprint.txt'
    $cert = $null
    if (Test-Path $thumbFile) {
        $t = (Get-Content $thumbFile).Trim()
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $t -and $_.HasPrivateKey }
    }
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert `
            -Subject 'CN=USB Audio Rescue local signing (this PC only)' `
            -CertStoreLocation Cert:\CurrentUser\My `
            -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(20)
        $cert.Thumbprint | Out-File $thumbFile -Encoding ascii
        "certificate created: $($cert.Subject)  thumbprint $($cert.Thumbprint)"
    } else {
        "reusing certificate $($cert.Thumbprint)"
    }

    try {
        $sig = Set-AuthenticodeSignature -FilePath $cat -Certificate $cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
    } catch {
        'timestamp server unreachable, signing without a timestamp'
        $sig = Set-AuthenticodeSignature -FilePath $cat -Certificate $cert -HashAlgorithm SHA256
    }
    "signed: $($sig.Status) - $($sig.StatusMessage)"
    if ($sig.Status -notin @('Valid', 'UnknownError')) { throw "signing failed: $($sig.Status) $($sig.StatusMessage)" }

    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    'certificate trusted on this PC (LocalMachine Root + TrustedPublisher)'

    $check = Get-AuthenticodeSignature $cat
    "catalog signature now: $($check.Status) - $($check.StatusMessage)"
    if ($check.Status -ne 'Valid') { throw 'the catalog still does not verify after trusting the certificate' }
    ''
    'DONE. Next: run 3-install.ps1 (one UAC prompt).'
}
finally {
    Stop-Transcript | Out-Null
}
