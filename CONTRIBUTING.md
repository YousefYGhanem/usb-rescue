# Contributing

Thanks for helping! Bug reports, fixes and documentation improvements are all welcome.

## Ground rules

These keep users' data safe:

1. **Never write to the drive being recovered.** It must only ever be opened read-only. Every repair happens on the copy.
2. **Never lose data on interruption.** Any rerun must resume correctly after Ctrl+C or a disconnect: write the map entry before skipping an area, and save data before marking it done.
3. **Windows PowerShell 5.1 compatible.** That's what every Windows 10/11 PC has. No PowerShell 7-only syntax (`??`, `?.`, ternaries, `-Parallel`).
4. **ASCII only** in `.ps1` files (5.1 reads BOM-less files as ANSI). CI enforces this.
5. **No new downloads or dependencies** without pinning their SHA256 like PhotoRec's.

## Running the tests

| Test | Where | What it checks |
|---|---|---|
| `tests/windows-e2e.ps1` | Windows, Administrator PowerShell | Builds FAT32/exFAT/NTFS virtual disks, wipes their boot sectors, then images, repairs and mounts them with the script's own functions |
| `tests/check_backups.py` | Linux (`dosfstools exfatprogs ntfs-3g mtools`) | Boot-sector repair rules on real file-system images |
| `tests/check_two_pass.py` | Any Python 3 | Two-pass imaging with bad sectors, drive dropouts and resume |

CI runs all of them, plus PSScriptAnalyzer, on every push and pull request.

## The desktop app

`app/` is a [Tauri 2](https://tauri.app) app: a plain HTML/CSS/JS front end (`app/ui`) and a small Rust back end (`app/src-tauri`) that runs `Recover-UsbDrive.ps1` and forwards its `-Events` progress to the window. The script is compiled into the exe, so every recovery change belongs in the script, not the app.

- **UI only:** open `app/ui/index.html` through any local web server. Outside the app it uses a built-in mock that plays a short fake rescue.
- **Build the exe:** install [Rust](https://rustup.rs) and Node.js, then run `npm install` and `npm run build` in `app/`. The output is `app/src-tauri/target/release/usb-rescue.exe`. The exe asks for Administrator rights, so start it from Explorer, not from a non-elevated terminal.

## Pull requests

- Keep each pull request focused on one change, and describe what you tested and on which Windows version.
- Add a line to `CHANGELOG.md` under a new version heading.
- Security problems: see [SECURITY.md](SECURITY.md). Don't open a public pull request for them.
