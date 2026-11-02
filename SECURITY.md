# Security Policy

usb-rescue runs **as Administrator** and reads raw disks, so security matters. Thank you for helping keep it safe.

## Supported versions

Only the [latest release](https://github.com/YousefYGhanem/usb-rescue/releases/latest) receives fixes.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub: **Security > [Report a vulnerability](https://github.com/YousefYGhanem/usb-rescue/security/advisories/new)**. Include:

- the version (shown when the script starts)
- what an attacker could do, and how
- steps to reproduce, or a proof of concept

You can expect a first response within 7 days. Fixes are released as soon as possible, and you'll be credited in the advisory unless you prefer not to be.

## Security design

What the script does, and doesn't do, so you can check it before running it as Administrator:

| Area | Behaviour |
|---|---|
| The drive being recovered | Opened with `GENERIC_READ` only (`CreateFile` in `RawDisk.OpenRead`). The script has no code path that writes to it. |
| Writes | Only inside the output folder (`-OutDir`, default `<drive>:\UsbRecovery`). The script refuses an output folder on the drive being recovered. `chkdsk /f` runs only on the mounted **copy**. |
| Network | One optional download: TestDisk/PhotoRec 7.2 from `https://www.cgsecurity.org`, only when you accept the deep scan. Its **SHA256 is pinned** in the script; a mismatched file is deleted and never run. CI re-checks the pinned hash every week. |
| Telemetry | None. Nothing about you, your drive or your files leaves your PC. |
| Administrator rights | Needed for raw disk reads, mounting the VHD copy and `chkdsk`. |

## Staying safe as a user

- Download only from this repository's [Releases](https://github.com/YousefYGhanem/usb-rescue/releases) page or the green Code button. Copies hosted elsewhere may be modified.
- The script is plain text; read it before running it as Administrator.
- `log.txt` and `robocopy.log` can contain folder and file names from your drive. Review them before attaching them to a public issue.
