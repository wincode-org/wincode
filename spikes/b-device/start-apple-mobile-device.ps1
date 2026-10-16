# Spike B: make Apple's device service (Apple Devices app) listen on 127.0.0.1:27015.
#
# The Microsoft Store "Apple Devices" app runs its device stack as a startup task
# (AppleMobileDeviceLauncher.exe -> AppleMobileDeviceProcess.exe) at sign-in, not as
# a Windows service. Right after installing the app it is not running yet; this
# starts it inside the app's package context without signing out.
#
# Prerequisites: Apple Devices installed (winget install --id 9NP83LWLPZ9K --source msstore),
# the iPhone NOT attached to WSL with usbipd, and WSL in mirrored networking mode.

$pkg = Get-AppxPackage AppleInc.AppleDevices
if (-not $pkg) { throw 'Apple Devices is not installed: winget install --id 9NP83LWLPZ9K --source msstore' }

function Get-Listener { Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue }

if (-not (Get-Listener)) {
    $exe = Join-Path $pkg.InstallLocation 'AppleMobileDeviceLauncher.exe'
    # Invoke-CommandInDesktopPackage lives in the Windows PowerShell Appx module.
    powershell.exe -NoProfile -Command "Invoke-CommandInDesktopPackage -PackageFamilyName '$($pkg.PackageFamilyName)' -AppId 'App' -Command '$exe' -PreventBreakaway"
    $deadline = (Get-Date).AddSeconds(45)
    while (-not (Get-Listener) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
}

$listener = Get-Listener
if (-not $listener) { throw 'Apple mobile device process is not listening on 127.0.0.1:27015' }
$listener | ForEach-Object {
    "$($_.LocalAddress):$($_.LocalPort) $((Get-Process -Id $_.OwningProcess).ProcessName)"
}
