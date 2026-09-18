# 4-destroy-key.ps1  --  USB Audio Rescue for Windows 11
#
# Deletes the one-time signing certificate AND its private key from your user store.
# The public certificate stays trusted on this PC (so the installed package keeps
# verifying) but nothing can ever be signed with it again. No elevation needed.
# Run this once 3-install.ps1 reports INSTALL DONE.
#
# If you later rebuild the package (1-build.ps1 again), step 2 simply makes a new
# certificate; nothing depends on the old one.

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSCommandPath
$thumbFile = Join-Path $root 'cert-thumbprint.txt'
if (-not (Test-Path $thumbFile)) { 'no cert-thumbprint.txt here; nothing to destroy'; exit 0 }
$thumb = (Get-Content $thumbFile).Trim()

$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $thumb }
if (-not $cert) { "no certificate $thumb in your user store; the key is already gone"; exit 0 }

"deleting $($cert.Subject) ($thumb) and its private key"

# Windows PowerShell 5.1 has no Remove-Item -DeleteKey on the certificate provider:
# delete the CNG key container first, then remove the certificate from the store.
$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
if ($rsa -and $rsa.Key) { $name = $rsa.Key.KeyName; $rsa.Key.Delete(); "key container '$name' deleted" } else { 'no private key handle found (already gone?)' }
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
$store.Open('ReadWrite'); $store.Remove($cert); $store.Close()

if (Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $thumb }) { throw 'certificate still present' }
'DONE. Private key destroyed. The public certificate remains trusted so the installed package keeps verifying.'
