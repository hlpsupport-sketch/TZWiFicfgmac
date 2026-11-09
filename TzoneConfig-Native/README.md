# Tzone Config - native Mac app

Swift/SwiftUI app + a small C layer that talks to the logger through macOS's own SCSI
interface (IOKit). No Python, no libusb. It unmounts the logger's disk when you press Read /
Save and remounts it afterwards.

## Get the app (no Mac or Xcode needed)
1. Create a new GitHub repository and upload everything in this folder (keep `.github/`).
2. Open the repo's **Actions** tab -> "Build Mac app" -> wait ~3 minutes (it also runs on every push).
3. Open the finished run, download the **TzoneConfig-Mac** artifact, unzip, and you have `Tzone Config.app`.
4. First launch: right-click the app -> Open -> Open (it is ad-hoc signed, not notarized).
   On macOS 15: System Settings -> Privacy & Security -> "Open Anyway".

## Using it
Plug in the logger, click Read. Edit WiFi name/password, click Save (this also sets the
logger's clock). Supports WF501 / WF501B / WF502 / WF502B config; other models show info only.

## Status
Written without access to a Mac or a logger. If the build fails, the Actions log shows why.
