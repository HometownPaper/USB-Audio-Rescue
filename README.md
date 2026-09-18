# USB Audio Rescue for Windows 11

**Your old USB audio interface stopped working after a Windows update, or Windows keeps "turning it off"? This gets it back — using Microsoft's own driver, already on your disk.**

Works for any **USB Audio Class 1.0** device: most audio interfaces, USB mics, DACs and headsets made before roughly 2015, and plenty made since. Not brand-specific. (There is one optional extra for Lexicon Lambda owners in `extras/`.)

Four small PowerShell scripts you can read in full. Nothing is downloaded. Nothing of Microsoft's or anyone else's is redistributed here. Total footprint on your disk: about **300 KB** (one copy of a driver file plus text). Fully reversible with `uninstall.ps1`.

---

## What went wrong

Two separate things, both caused by Windows, both confirmed against Microsoft's own documentation:

**1. The September 2026 update broke the driver.** The Windows security update of September 8, 2026 (KB5124008) ships a new version of `usbaudio.sys`, the driver Windows uses for every USB Audio Class 1.0 device. That version fails to start many of those devices. Device Manager shows **"This device cannot start. (Code 10)"**, there is no sound, and volume controls are dead. Microsoft confirmed it on its Windows release health page; the September 14 out-of-band update (KB5129195) fixed only the multichannel part. Microsoft did the same thing in January 2025 (KB5050009).
Source: <https://learn.microsoft.com/en-us/windows/release-health/status-windows-11-25h2> — "USB audio devices might fail to start or produce no sound".

**2. Windows puts the device to sleep after 30 seconds of silence.** Microsoft's driver settings tell Windows to power a USB audio device down after 30 seconds without audio. Many older interfaces never wake up properly from that: the light goes dark, recordings come back silent, until you unplug and replug. Microsoft's documentation states that a value of 0 disables this timer.
Source: <https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/portcls-registry-power-settings>

## What this does

1. **Finds your device** — lists the USB Audio Class 1.0 interfaces Windows sees and which ones are failing.
2. **Takes a copy of Microsoft's own `usbaudio.sys` that is already on your PC.** Windows keeps earlier versions of its files in `C:\Windows\WinSxS`. The script picks the newest one older than the broken version, **verifies Microsoft's digital signature on it**, and refuses anything that is not Microsoft-signed. The copy is renamed `usbaudio_rescue.sys` so it can never collide with the real one, which every other USB audio device keeps using. Renaming does not change the file's hash, so Windows still verifies it against Microsoft's signature when loading it.
3. **Writes a driver package** (an `.inf` text file you can read) that binds *only your device*, by its exact hardware ID, to that copy, with the 30-second sleep timer disabled. It is a cut-down copy of the install sections of Microsoft's own `wdma_usb.inf`.
4. **Signs the package on your PC with a one-time certificate** created on your PC, trusted on your PC, and whose private key is then destroyed. Windows will not install a driver package without a trusted signature, and Microsoft's own files cannot be re-packaged under Microsoft's signature. This is the same method the well-known open-source tool libwdi/Zadig has used for years to install Microsoft's WinUSB driver for arbitrary devices. Source: <https://github.com/pbatard/libwdi/wiki/FAQ>
5. **Installs it.** Windows prefers a driver that names your exact device over its generic one, so the fix sticks across ports and across future Windows updates.

## What this does NOT do

- It does not download anything (except the optional Lexicon extra, which downloads Lexicon's installer from Harman's server and verifies Harman's signature on it).
- It does not modify any Windows file. The real `usbaudio.sys` is untouched; a renamed **copy** is added next to it.
- It does not touch any device other than the ones listed at the top of the build output.
- It does not turn off Windows Update, Defender, Secure Boot, driver signature enforcement or any other protection. No test-signing mode. No registry hacks beyond the driver's own settings.
- It does not phone home, collect anything, or run in the background. The scripts run when you run them and exit.

## Is this safe? Check it yourself

- Every step is a plain-text PowerShell script. Read them before running them; they are short.
- The only binary that ends up on your system is Microsoft's own `usbaudio.sys`, copied from your own disk. Right-click `package\usbaudio_rescue.sys` after step 1 → Properties → Digital Signatures: it is signed by Microsoft Windows.
- The certificate is generated locally, is only trusted on your own PC, and step 4 destroys its private key. After that it cannot sign anything, ever. `uninstall.ps1` removes it from the trust stores too.
- No account, no installer, no service running in the background. If you want to be sure, upload the `.ps1` files to VirusTotal — they are text.

## Requirements

- Windows 11, 64-bit (x64). Windows 10 x64 should work but is untested. ARM64 is not supported.
- A USB Audio Class 1.0 device. (Class 2.0 devices use a different driver, `usbaudio2.sys`, and are not affected by this bug.)
- PowerShell 5.1, which every Windows 10/11 has. No other tools.
- Administrator rights for steps 2 and 3 (you get a normal UAC prompt).

## How to use it

Download the ZIP of this repository (green **Code** button → **Download ZIP**), extract it anywhere, e.g. `C:\Users\you\Documents\usb-audio-rescue`, and keep it there — the installed package does not depend on the folder, but the uninstall script and your logs live in it.

Open **PowerShell** in that folder (in File Explorer: right-click the folder → *Open in Terminal*, or Shift+right-click → *Open PowerShell window here*). Then, one at a time:

```powershell
powershell -ExecutionPolicy Bypass -File .\1-build.ps1
```
Lists your USB audio interfaces and builds the package for the ones failing with Code 10. No admin needed, nothing installed yet. Read the output.
- Just want to look first? `powershell -ExecutionPolicy Bypass -File .\1-build.ps1 -ListOnly` prints the list and stops.
- If your device works but keeps going to sleep, tell the script which one it is instead:
  `powershell -ExecutionPolicy Bypass -File .\1-build.ps1 -HardwareId "USB\VID_xxxx&PID_yyyy&MI_00" -NoSleepOnly`
  (copy the ID from the list the script prints; several IDs go in one quoted, comma-separated string).

```powershell
powershell -ExecutionPolicy Bypass -File .\2-sign-and-trust.ps1
```
Creates the one-time certificate, signs the package, trusts the certificate on this PC. One UAC prompt.

```powershell
powershell -ExecutionPolicy Bypass -File .\3-install.ps1
```
Installs the package and binds your device to it. One UAC prompt. The last lines show the device state: **problem=0** on every interface means it worked; you should see your device appear in Windows Sound settings within seconds.

```powershell
powershell -ExecutionPolicy Bypass -File .\4-destroy-key.ps1
```
Destroys the signing key. Do this once step 3 says INSTALL DONE.

Each script writes a `*-log.txt` next to itself with everything it did.

## Undo

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```
Removes the package and the certificate, then unplug and replug the device. It comes back on Windows' own driver. Use this once Microsoft ships a fixed `usbaudio.sys` if you prefer the inbox driver — or keep the rescue package; the older Microsoft driver is a complete driver and keeps working.

## If something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| Step 1: "No interface is failing with Code 10" | Your device is not hitting the September bug right now | If it sleeps, use `-HardwareId ... -NoSleepOnly`. If it does not work for another reason, this tool is not the fix. |
| Step 1: "No older usbaudio.sys found in C:\Windows\WinSxS" | This PC never had an older version of the driver on disk | Copy `usbaudio.sys` from another Windows 11 PC's `C:\Windows\System32\drivers` (it must be Microsoft-signed; the script checks) and pass it with `-SourceSys`. |
| Step 3: device shows **problem=52** | The certificate is not trusted | Re-run step 2. |
| Step 3: device shows **problem=10** under `oemNN.inf` | The older driver version also fails on your device | Run `uninstall.ps1`, then rebuild with `-SourceSys` pointing at a different version (see step 1 output). |
| Any app: "Bad Image ... 0xc0e90002" | Windows' **Smart App Control** blocking an unsigned program file. Not caused by this tool (which installs only Microsoft-signed code), but you may meet it on the same day. | Windows Security → App & browser control → Smart App Control settings. There is no per-app exception. |
| A different USB port and the device went back to Code 10 | Should not happen: the package matches by hardware ID on any port | Re-run step 3; it reports what each interface is bound to. |

## Known limitations, stated plainly

- The older `usbaudio.sys` you end up with is whatever earlier version your PC has on disk (on a 24H2/25H2 machine typically 10.0.26100.1 from March 2024). It may lack fixes that came after it. It is still Microsoft's code, verified by Microsoft's signature.
- Disabling idle power-down means the device stays fully powered while plugged in. For an audio interface that is what you want; for a battery laptop it is a few milliwatts.
- Windows Update will not replace this package automatically (that is the point). If Microsoft later ships a driver you would rather have, run `uninstall.ps1`.
- One package covers all the interfaces you build it for. Rebuilding for another device and reinstalling replaces the package (the install script removes the earlier revision first).

## Extras

`extras\lexicon-lambda-asio.ps1` — Lexicon Lambda owners only. Lexicon's official "Lambda Driver v2.7" for Windows contains no audio driver: it is an ASIO plug-in (`LambdaAsio.dll`) that streams through Windows' own USB audio driver, plus a firmware-update helper. This script downloads Lexicon's installer from Harman's own server, verifies Harman's digital signature, extracts the plug-in without running the installer, and registers it so Pro Tools, Cubase, Reaper and other ASIO hosts list "Lambda ASIO". `-Uninstall` removes it. Details in the script header.

## Tested on

One machine so far: Windows 11 Home 25H2, build 26200.9457, AMD USB 3.1 controllers, with a Lexicon Lambda (USB 1.1, two audio interfaces). The full cycle — build, sign, install, replug, record, play, 90 seconds idle, key destroyed — was run there on 2026-09-17 with a device-specific version of these scripts. The generic scripts in this repository were then produced from that version, rebuilt the identical package on the same machine (same Microsoft file, same hash), and were parse-checked; their install and uninstall paths differ from the tested ones only in names. If it works or fails for you, please open an issue with your device's hardware ID and the `*-log.txt` files — that is how the "Tested on" list grows.

## How this was found

Built on 2026-09-17 on a Windows 11 Home 25H2 machine (build 26200.9457) with a Lexicon Lambda that had failed with Code 10 on two ports after the September update. The diagnosis came from Windows' own Kernel-PnP log (event 411, `wdma_usb.inf` 10.0.26100.9457, status 0xC000009C), the sleep problem from the device's reported power state (D3 after 30 seconds) and the driver's `PowerSettings` registry values. Both fixes were verified: recording and playback through the device, and the device still fully powered after 90 seconds idle. Alternatives were checked and ruled out: rolling back the update (drops months of security fixes), third-party drivers (do not list the device), the vendor's own package (rides on the broken Microsoft driver).

## License

MIT. See `LICENSE`. No affiliation with Microsoft, Lexicon, Harman or Avid. Product names belong to their owners.
