# SahelFlow PC check - how to run it (one page)

**What it is for.** We have numbers for how SahelFlow starts on our datacenter test machine, but never on a real slow PC. This check measures the start on YOUR PC (for example a laptop with a hard disk and 4 GB RAM) and gives us ONE small text file to compare. The numbers we want are: **(1) the first launch after Windows has just started** and **(2) the second launch**.

**It uses the SahelFlow that is already installed.** Do not install anything new. The report says which version it found (for example `1.0.0.47`).

## The 5 steps

1. Copy these two files into a new folder `C:\sf-check` (USB stick or WhatsApp): `sahelflow-pc-check.ps1` and `run-launch-twice.cmd`. Both must stay in the same folder.
2. Click Start > Power > **Restart** (not "Shut down"; Windows keeps old state after "Shut down"). After Windows is back, **wait 2 minutes** and open nothing else. Do not open SahelFlow.
3. Open the folder `C:\sf-check` and **double-click `run-launch-twice.cmd`**. A black window opens. If Windows shows a warning about the file, choose More info > Run anyway (the file only reads and measures; see the top of `sahelflow-pc-check.ps1`).
   (Backup way: Start > type `powershell` > Enter, then type: `powershell -ExecutionPolicy Bypass -File C:\sf-check\sahelflow-pc-check.ps1 -Launch -Twice`)
4. Follow the screen. It asks you to close SahelFlow, press Enter, then it starts SahelFlow itself and waits (up to 4 minutes; do not touch the PC). When it says "ready", close SahelFlow when asked and press Enter. This happens twice. Then a disk test runs (one to two minutes).
5. At the end it prints the name of the report file: `sahelflow-pc-check-<computername>-<date>-<time>.txt` in `C:\sf-check`. **Send us only this one file** (WhatsApp).

**Run it a second time later** (another day, again after Restart + 2 minutes), so we have two readings.

Optional, only if we ask you: add `-ReadWebView2` at the end of the typed command. It reads Microsoft's WebView2 files once to time the disk (10 to 60 seconds, the PC will be slow meanwhile). Run it right after Restart, without opening SahelFlow first.

## What it does and does not do

- It only reads: facts about the PC (Windows, processor, memory, disk type, WebView2, Defender) and two small files SahelFlow writes about its own start (`startup-trace.json`, `runtime-ui-diagnostic.json` in `%APPDATA%\com.sahelflow.desktop`).
- It writes the one report file and temporary disk-test files in `%TEMP%` that it deletes at once. It starts SahelFlow itself; it never closes or deletes anything.
- No internet, no upload, no administrator rights. It does not open the shop database, customers, keys or passwords. The report has the computer name but not your user name (your profile folder shows as `%USERPROFILE%`).
- **Not measured:** the real work of a seller (sales, stock, printing, WhatsApp, a big shop database, a power cut). It only sees the START of the app, on one PC, in one or two launches. If the first launch is slower than 4 minutes, it says "no answer in 4 minutes".
- If the black window says that running scripts is disabled, tell us what it says; do not change any Windows setting.
- If it says it cannot find the start-up file: start SahelFlow once, wait until it is open, close it, and run again.

Other languages: `LISEZMOI-fr.txt` (Francais), `README-ar.txt` (Arabic).
