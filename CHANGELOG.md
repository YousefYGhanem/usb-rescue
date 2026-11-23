# Changelog

## 1.3.0 - unreleased

### Added
- **USB Rescue desktop app** (`USB-Rescue.exe`): one portable file with nothing to install. Pick the drive, press one button, and follow the copy, repair and file recovery in plain language. A "What's happening" panel shows each step, the speed, damaged areas and the full technical log. The app follows the Windows light/dark theme and the reduced-motion setting.
- The app runs the same script underneath. The script is compiled into the exe and passed to PowerShell through stdin, never written to disk, so nothing can swap it before it runs as Administrator.
- New script options for the app: `-Events` (progress as JSON lines), `-ListDrives` (USB drives and the default output folder) and `-Carve` (run the deep scan without asking).

## 1.2.0 - 2026-11-02

### Added
- **Rebuilds a destroyed partition table** on the copy. When Windows sees no partitions at all, the script searches the first and last 64 MB for a FAT/exFAT/NTFS boot sector or its backup, works out where the partition started from the sector's own fields, and writes a new partition table into the copy. Previously this case needed manual TestDisk steps.
- `-Yes` option: runs with no prompts, taking the default answer everywhere (for automation).
- CI now runs the whole program unattended on a disk whose partition table and boot sector are both wiped, and tests partition-table rebuilding on FAT32, exFAT and NTFS.

## 1.1.1 - 2026-11-02

### Security
- The PhotoRec/TestDisk download is checked against a pinned SHA256 before it is unzipped or run. A mismatched file is deleted.
- Added a security policy (`SECURITY.md`) with private vulnerability reporting.

### Quality
- CI on every push and pull request: Windows end-to-end test on real virtual disks (FAT32/exFAT/NTFS), PSScriptAnalyzer, parse and ASCII checks, the Python model tests, and a weekly check of the PhotoRec download.
- Dependabot keeps the CI actions up to date; actions are pinned to commit SHAs.
- Contributing guide, issue templates (with a privacy note for logs), and a pull request checklist.
- `.bat` files are always checked out with Windows (CRLF) line endings.

## 1.1.0 - 2026-11-02

### Added
- **Two-pass imaging, like GNU ddrescue.** Pass 1 copies everything that reads cleanly and skips damaged areas, skipping further each time it hits more damage. Pass 2 then scrapes the damaged areas in 64 KB pieces and finally sector by sector. This gets the healthy data off a dying drive first.
- Imaging progress is saved in `usb.vhd.map`, so both passes resume after Ctrl+C or a disconnect.
- Deep-scan results are sorted into one folder per file type (`carved\jpg`, `carved\docx`, ...).
- Recovered photos are named by the date they were taken (from EXIF), e.g. `2023-05-14 18.22.31 f0123456.jpg`.
- Full run log in `UsbRecovery\log.txt`.
- Advice to test the drive for fake capacity (H2testw / f3) before reusing it.
- `Recover-UsbDrive.bat` double-click launcher, which asks for Administrator rights.
- Version number shown at start-up.
- MIT license, full README, and a test of the two-pass imaging.

### Fixed
- If the drive disconnected partway through a damaged area, its sectors were saved as zeros and logged as bad. Now nothing is saved until the drive is confirmed to still respond.
- Rerunning the deep scan no longer tries to re-sort files that were already sorted.

## 1.0.0 - 2026-11-01

- First release. Diagnose, read-only imaging to VHD with bad-sector handling, boot-sector repair from backups (FAT32/exFAT/NTFS), mount and copy out with chkdsk on the copy, and an optional PhotoRec deep scan.
- Fixed: crash on drives larger than 2 GB.
- Fixed: very slow retry path after read errors.
