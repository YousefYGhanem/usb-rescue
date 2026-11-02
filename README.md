# usb-rescue

[![CI](https://github.com/YousefYGhanem/usb-rescue/actions/workflows/ci.yml/badge.svg)](https://github.com/YousefYGhanem/usb-rescue/actions/workflows/ci.yml) [![Latest release](https://img.shields.io/github/v/release/YousefYGhanem/usb-rescue)](https://github.com/YousefYGhanem/usb-rescue/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**Get your files back from a USB drive or SD card that Windows says is corrupted.**

Use it when Windows shows one of these:

- *"E:\ is not accessible. The file or directory is corrupted and unreadable."*
- *"You need to format the disk in drive E: before you can use it."*
- Disk Management lists the drive's file system as **RAW**.

usb-rescue is a single PowerShell script for Windows 10/11. It needs nothing to install and **never writes to your drive**: it copies the drive sector by sector first, and does all repairs on the copy.

---

## Quick start

1. **Download** the ZIP from the [latest release](https://github.com/YousefYGhanem/usb-rescue/releases/latest), then unzip it.
2. **Plug in the broken drive.** Plug in only that one USB drive, and use a port on the back of the PC.
3. **Double-click `Recover-UsbDrive.bat`** and click **Yes** on the Administrator prompt.
4. Follow the prompts. If Windows offers to **format** anything, click **Cancel**.

You need free space of about **twice the USB drive's size** on another drive. Results go to `<drive with most free space>:\UsbRecovery`.

## What you get

| In `UsbRecovery\` | What it is |
|---|---|
| `files\partitionN\` | Recovered files with their **original names and folders** |
| `carved\jpg\`, `carved\docx\`, ... | Files found by content (deep scan), one folder per type. Original names are lost; photos are named by the **date they were taken**, e.g. `2023-05-14 18.22.31 f0123456.jpg` |
| `usb.vhd` | Full copy of the drive. Delete it once you've checked your files |
| `log.txt` | Full log of the run (attach it when asking for help) |
| `bad-sectors.txt` | Sectors that could not be read (zero-filled in the copy) |
| `robocopy.log` | Files that failed to copy |
| `usb.vhd.map` | Imaging progress, used to resume |

## How it works

| Step | What happens | Why |
|---|---|---|
| 1. Diagnose | Shows the drive's size, partitions and file system | A drive reporting 0 bytes has a dead controller. Only a recovery lab can help, so the script stops |
| 2. Image | Copies the drive into `usb.vhd` in two passes, like [GNU ddrescue](https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html). **Pass 1** copies everything that reads cleanly and skips damaged areas, skipping further (up to 64 MB) each time it hits more damage. **Pass 2** goes back and scrapes the damaged areas in 64 KB pieces, then sector by sector | Gets the healthy data off first, before a dying drive gets worse |
| 3. Repair | If the partition table is gone, finds the file system's boot sector (or its backup) near the start or end of the copy and rebuilds the table. Then restores the copy's boot sector from the backup each file system keeps: FAT32 sectors 6-8, exFAT sectors 12-23, NTFS last sector | A damaged boot sector is the usual reason Windows says "RAW" |
| 4. Copy out | Mounts the copy as a virtual disk, copies files with `robocopy`, and if some fail runs `chkdsk /f` **on the copy** and tries again | Gets files back with their names and folders |
| 5. Deep scan (optional) | Downloads [PhotoRec](https://www.cgsecurity.org/wiki/PhotoRec) and scans the copy for photos, documents, videos and archives by their content | Works even when the file system is completely gone |

If a partition is still unreadable at the end, the script prints how to run **TestDisk** on the copy. TestDisk can find lost partitions and copy files out with their names.

### Safety

- The USB drive is opened **read-only** (`GENERIC_READ`). Nothing in the script can write to it.
- You can stop the script at any time (Ctrl+C) and run it again: imaging resumes from `usb.vhd.map`.
- If the drive disconnects, the script stops and tells you to replug it. It checks that the drive still responds before saving any zeros, so a disconnect is never mistaken for bad sectors.

## Options

Run from an Administrator PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Recover-UsbDrive.ps1 [-DiskNumber 2] [-OutDir D:\UsbRecovery] [-SkipCarve] [-Yes]
```

| Option | Meaning |
|---|---|
| `-DiskNumber` | The drive's number in Disk Management. Asked for if more than one USB drive is plugged in |
| `-OutDir` | Where to save results. Must be on another drive |
| `-SkipCarve` | Don't offer the PhotoRec deep scan |
| `-Yes` | No prompts: take the default answer everywhere (for automation). Needs `-DiskNumber` if several USB disks are plugged in |

## Troubleshooting

**It's very slow (around 1 MB/s).** A healthy stick reads at 10-30 MB/s. About 1 MB/s usually means the drive is connected at USB 1.1 speed through a front port, hub or extension cable. Press Ctrl+C, move the drive to a back port and run the script again; it resumes. If "damaged MB left for pass 2" keeps rising, the flash is failing: let it finish.

**"The drive stopped responding at ... MB".** Unplug the drive, wait 10 seconds, plug it into a different port and run the script again. It continues where it stopped.

**"Not enough space".** Use `-OutDir` to point at a drive with more free space, or an external hard drive.

**Files in `files\` are missing, or the partition is "still unreadable".** Check `carved\` for the deep-scan results, then try TestDisk using the command the script prints.

**PhotoRec download failed.** Download *TestDisk & PhotoRec for Windows 64-bit* from [cgsecurity.org](https://www.cgsecurity.org/wiki/TestDisk_Download), unzip it into `UsbRecovery\testdisk\` and run the script again.

**Disk shows 0 bytes or "No Media".** The drive's controller has failed. Stop plugging it in, and contact a data-recovery lab if the files matter.

## Before you reuse the drive

Cheap "Generic Flash Disk" sticks often **report more capacity than they really have**. Once the real capacity is full, they silently overwrite old data, which causes exactly this kind of corruption. After recovering your files, test the drive with [H2testw](https://www.heise.de/download/product/h2testw-50539) or [f3](https://github.com/AltraMayor/f3). Both tests erase the drive. If the drive fails the test, or gets corrupted again, throw it away.

## Tests and security

Every push is checked by [CI](https://github.com/YousefYGhanem/usb-rescue/actions/workflows/ci.yml):

- **Windows end-to-end test:** builds FAT32, exFAT and NTFS virtual disks, wipes their boot sectors (and, in a second round, their partition tables too), then images, repairs and mounts them with the script's own code, and checks the file comes back intact. It also runs the **whole program unattended** (`-Yes`) on the worst case.
- **Lint:** parse check, ASCII check and PSScriptAnalyzer.
- **Model tests:** boot-sector repair on real file-system images, and two-pass imaging with bad sectors and drive dropouts.
- **Download check:** confirms the PhotoRec download still matches the pinned SHA256 (also runs weekly).

See [CONTRIBUTING.md](CONTRIBUTING.md) to run the tests yourself, and [SECURITY.md](SECURITY.md) for what the script can and can't touch, and how to report a vulnerability.

## Requirements

- Windows 10 or 11, with Windows PowerShell 5.1 (built in)
- Administrator rights
- Internet access only for the optional PhotoRec download

## License

MIT, see [LICENSE](LICENSE). The script downloads [TestDisk/PhotoRec](https://www.cgsecurity.org/) (GPL) at run time; it is not bundled.
