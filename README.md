# usb-rescue

Recover files from a USB drive or SD card that Windows reports as
**"The file or directory is corrupted and unreadable"**, **RAW**, or **"You need to format the disk"**.

It **never writes to your drive**. It makes a sector-by-sector copy first and does all repairs on the copy.

## Use it

1. Download this repo (Code > Download ZIP) and unzip it.
2. Plug in the broken drive (only that one USB drive). Use a port on the back of the PC.
3. Double-click **`Recover-UsbDrive.bat`** and accept the Administrator prompt.
4. If Windows offers to format anything, click **Cancel**.

Results go to `<drive with most free space>:\UsbRecovery` (you need free space of about twice the USB drive's size):

| Folder / file | What it is |
|---|---|
| `files\` | Files recovered with original names and folders |
| `carved\recup.N\` | Files found by content (PhotoRec); names and folders are lost |
| `usb.vhd` | The full copy of the drive. Delete it once you've checked your files |
| `bad-sectors.txt`, `robocopy.log` | What could not be read |

Command-line options (from an Administrator PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\Recover-UsbDrive.ps1 -DiskNumber 2 -OutDir D:\UsbRecovery -SkipCarve
```

## What it does

1. **Diagnose**: shows the size, partitions and file system Windows sees. If the drive reports 0 bytes, it stops, because only a recovery lab can help.
2. **Image**: copies every sector to `usb.vhd`. Unreadable sectors are zero-filled and logged. If the drive drops out, run it again and it resumes.
3. **Repair**: restores the copy's boot sector from the backup that FAT32 (sectors 6-8), exFAT (sectors 12-23) and NTFS (last sector) keep. This is the usual cause of "RAW".
4. **Copy out**: mounts the copy, runs `chkdsk` on the copy if files fail, and copies everything out with `robocopy`.
5. **Carve** (optional): downloads [PhotoRec](https://www.cgsecurity.org/wiki/PhotoRec) and scans the copy for files by content.

If a partition is still unreadable at the end, it prints how to run TestDisk on the copy, which can find lost partitions and copy files out with their names.

## Speed

A healthy stick reads at 10-30 MB/s. If it's around 1 MB/s, the stick is probably connected at USB 1.1 speed: press Ctrl+C, move it to a back port and run it again (it resumes). If "MB needing retries" keeps rising, the flash is failing; let it finish.

## Tests

`tests/check_backups.py` (Linux; needs `dosfstools`, `exfatprogs`, `ntfs-3g`, `mtools`) builds real FAT32/exFAT/NTFS images, wipes their boot sectors, and checks that the script's repair rules make them readable again.

## Requirements

Windows 10/11, Windows PowerShell 5.1 (built in), Administrator rights. Internet access only for the optional PhotoRec download.
