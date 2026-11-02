<#
.SYNOPSIS
  Recover files from a USB drive that Windows reports as "corrupted and unreadable" or RAW.

.DESCRIPTION
  Never writes to the USB drive. Everything after step 2 works on a sector-by-sector copy:
    1. Diagnose - show what Windows sees (size, partitions, file system).
    2. Image    - copy every sector to <OutDir>\usb.vhd in two passes, like GNU ddrescue: first
                  everything that reads cleanly (damaged areas are skipped to spare a dying drive),
                  then the damaged areas piece by piece. Unreadable sectors are zero-filled and listed
                  in bad-sectors.txt. If the drive drops out, rerun the script: it resumes.
    3. Repair   - restore the copy's boot sector from the backup every FAT32 / exFAT / NTFS volume
                  keeps (the usual cause of "RAW" / "corrupted and unreadable").
    4. Copy out - mount the copy, run chkdsk on the COPY if files fail, and copy everything to
                  <OutDir>\files with original names and folders.
    5. Carve    - optional PhotoRec deep scan into <OutDir>\carved: finds photos, documents, videos,
                  archives... by their content even when the file system is gone (names are lost).
                  Results are sorted into one folder per file type; photos get their date taken
                  in front of their name.

  Run from an Administrator PowerShell:
    powershell -ExecutionPolicy Bypass -File .\Recover-UsbDrive.ps1

.PARAMETER DiskNumber
  Disk number of the USB drive (as in Disk Management). Asked for if omitted.
.PARAMETER OutDir
  Where the image and recovered files go. Must be on another drive with free space of about
  twice the USB drive's size. Default: <internal drive with most free space>:\UsbRecovery
.PARAMETER SkipCarve
  Don't offer the PhotoRec deep scan.
#>
[CmdletBinding()]
param([int]$DiskNumber = -1, [string]$OutDir, [switch]$SkipCarve)
$ErrorActionPreference = 'Stop'
$Version = '1.1.1'
# SHA256 of testdisk-7.2.win64.zip. The download is refused if it doesn't match (it runs as Administrator).
# CI re-checks this every week against the live download.
$TestDiskSha256 = 'E97E203CE77B6B1A3A37D01BECCF069DC6C4632B579FFBB82AE739CDDA229F38'   # 27,354,549 bytes

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an Administrator PowerShell (right-click Start > Terminal (Admin)).'
}

# .NET Framework's FileStream refuses \\.\ device paths, so open the raw disk through CreateFile.
$rawDiskCs = @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class RawDisk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    public static SafeFileHandle OpenRead(string name) {
        // GENERIC_READ only, share read+write, OPEN_EXISTING: nothing is ever written to the drive
        SafeFileHandle h = CreateFile(name, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }
}
'@

function Step($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

function Read-At($fs, [long]$off, [int]$n) {
    $b = New-Object byte[] $n
    $fs.Position = $off
    $r = 0
    while ($r -lt $n) { $k = $fs.Read($b, $r, $n - $r); if ($k -le 0) { break }; $r += $k }
    , $b
}

# Which file system a boot sector belongs to, or $null if it is damaged.
function Get-BootFs([byte[]]$b) {
    if ($b.Length -lt 512 -or $b[510] -ne 0x55 -or $b[511] -ne 0xAA) { return $null }
    $a = [Text.Encoding]::ASCII
    if ($a.GetString($b, 3, 8) -eq 'EXFAT   ') { if ($b[108] -ge 9 -and $b[108] -le 12) { return 'exFAT' }; return $null }
    $bps = [BitConverter]::ToUInt16($b, 11)
    if ($bps -notin 512, 1024, 2048, 4096 -or $b[13] -eq 0) { return $null }
    if ($a.GetString($b, 3, 8) -eq 'NTFS    ') { return 'NTFS' }
    if ($a.GetString($b, 82, 5) -eq 'FAT32') { return 'FAT32' }
    if ($a.GetString($b, 54, 3) -eq 'FAT') { return 'FAT' }
    $null
}

# 512-byte footer that turns a raw image into a fixed-size VHD Windows can mount (VHD spec v1.0).
function New-VhdFooter([long]$size) {
    $f = New-Object byte[] 512
    $a = [Text.Encoding]::ASCII
    function BE([int]$off, [byte[]]$le) { [Array]::Reverse($le); $le.CopyTo($f, $off) }
    $a.GetBytes('conectix').CopyTo($f, 0)
    BE 8  ([BitConverter]::GetBytes([uint32]2))            # features
    BE 12 ([BitConverter]::GetBytes([uint32]0x10000))      # format version 1.0
    BE 16 ([BitConverter]::GetBytes([int64]-1))            # data offset: none (fixed disk)
    BE 24 ([BitConverter]::GetBytes([uint32]([DateTime]::UtcNow - [DateTime]'2000-01-01').TotalSeconds))
    $a.GetBytes('rcvr').CopyTo($f, 28)
    BE 32 ([BitConverter]::GetBytes([uint32]0x10000))
    $a.GetBytes('Wi2k').CopyTo($f, 36)
    BE 40 ([BitConverter]::GetBytes([int64]$size))         # original size
    BE 48 ([BitConverter]::GetBytes([int64]$size))         # current size
    $ts = [math]::Min([long]($size / 512), 65535L * 16 * 255)
    if ($ts -ge 65535L * 16 * 63) { $spt = 255; $hd = 16; $cth = [math]::Floor($ts / $spt) }
    else {
        $spt = 17; $cth = [math]::Floor($ts / $spt); $hd = [math]::Max([math]::Floor(($cth + 1023) / 1024), 4)
        if ($cth -ge $hd * 1024 -or $hd -gt 16) { $spt = 31; $hd = 16; $cth = [math]::Floor($ts / $spt) }
        if ($cth -ge $hd * 1024) { $spt = 63; $hd = 16; $cth = [math]::Floor($ts / $spt) }
    }
    BE 56 ([BitConverter]::GetBytes([uint16][math]::Floor($cth / $hd)))
    $f[58] = [byte]$hd; $f[59] = [byte]$spt
    BE 60 ([BitConverter]::GetBytes([uint32]2))            # disk type: fixed
    [guid]::NewGuid().ToByteArray().CopyTo($f, 68)
    $sum = 0L; foreach ($x in $f) { $sum += $x }
    BE 64 ([BitConverter]::GetBytes([uint32]([uint32]::MaxValue - $sum)))   # one's complement checksum
    , $f
}

function Read-Into($src, $buf, [long]$pos, [int]$o, [int]$len) {
    try {
        $src.Position = $pos + $o; $r = 0
        while ($r -lt $len) { $k = $src.Read($buf, $o + $r, $len - $r); if ($k -le 0) { return $false }; $r += $k }
        $true
    } catch { $script:lastReadError = $_.Exception.Message; $false }
}

# Two passes, like GNU ddrescue. Pass 1 copies everything that reads cleanly and skips damaged areas,
# skipping further each time it hits more damage, to spare a dying drive. Pass 2 goes back and scrapes
# the skipped areas piece by piece. Progress is kept in <image>.map, so any rerun resumes.
function Copy-Disk([int]$num, [long]$size, [int]$ss, [string]$img, [string]$log) {
    $chunk = 1MB
    $map = "$img.map"   # "skip <offset>" = 1 MB left for pass 2; "done <offset>" = pass 2 finished it
    $pending = New-Object 'System.Collections.Generic.SortedSet[long]'
    if (Test-Path $map) {
        foreach ($l in Get-Content $map) { $k, $v = $l -split ' '; if ($k -eq 'skip') { [void]$pending.Add([long]$v) } elseif ($k -eq 'done') { [void]$pending.Remove([long]$v) } }
    }
    $have = if (Test-Path $img) { (Get-Item $img).Length } else { 0L }
    if ($have -eq $size + 512 -and $pending.Count -eq 0) { Write-Host "Image already complete: $img"; return }
    if (-not ('RawDisk' -as [type])) { Add-Type -TypeDefinition $rawDiskCs }
    $src = [IO.FileStream]::new([RawDisk]::OpenRead("\\.\PhysicalDrive$num"), [IO.FileAccess]::Read, 1)
    $dst = [IO.FileStream]::new($img, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write)
    $buf = New-Object byte[] $chunk
    $probe = New-Object byte[] $ss
    $lastGood = -1L
    $alive = { $lastGood -lt 0 -or (Read-Into $src $probe $lastGood 0 $ss) }   # can we still read a sector that worked before?
    $dropped = 'The drive stopped responding at {0} MB. Unplug it, wait 10 seconds, plug it into a different port and run the script again - it resumes from here.'
    try {
        if ($have -lt $size + 512) {
            $pos = [math]::Min([long][math]::Floor($have / $chunk) * $chunk, $size)
            if ($pos -gt 0) { Write-Host "Resuming at $([math]::Round($pos / 1MB)) MB" }
            $dst.SetLength($pos); $dst.Position = $pos
            $skip = 1; $i = 0; $start = $pos; $t = [Diagnostics.Stopwatch]::StartNew()
            while ($pos -lt $size) {
                $n = [int][math]::Min([long]$chunk, $size - $pos)   # [long] or PowerShell picks Min(int,int) and overflows on drives > 2 GB
                if (Read-Into $src $buf $pos 0 $n) {
                    $dst.Write($buf, 0, $n); $lastGood = $pos; $pos += $n; $skip = 1
                } else {
                    if (-not (& $alive)) { $dst.SetLength($pos); throw ($dropped -f [math]::Round($pos / 1MB)) }
                    if ($pending.Count -eq 0) { Write-Warning "Damaged area at $([math]::Round($pos / 1MB)) MB ($script:lastReadError). Skipping it for now - damaged areas are retried at the end." }
                    # Leave this 1 MB plus the next ($skip - 1) MB for pass 2; skip twice as far next time (max 64 MB).
                    $end = [math]::Min($pos + [long]$skip * $chunk, $size)
                    [Array]::Clear($buf, 0, $chunk)
                    while ($pos -lt $end) {
                        $n = [int][math]::Min([long]$chunk, $end - $pos)
                        Add-Content $map "skip $pos"   # map first, so a crash can never lose a skipped area
                        [void]$pending.Add($pos); $dst.Write($buf, 0, $n); $pos += $n
                    }
                    $skip = [math]::Min($skip * 2, 64)
                }
                if ((++$i % 32) -eq 0) {
                    $mbs = ($pos - $start) / 1MB / [math]::Max($t.Elapsed.TotalSeconds, 1)
                    Write-Progress -Activity 'Pass 1: copying everything that reads cleanly' -PercentComplete ([int](100 * $pos / $size)) `
                        -Status ('{0:N0} / {1:N0} MB   {2:N1} MB/s   damaged MB left for pass 2: {3}' -f ($pos / 1MB), ($size / 1MB), $mbs, $pending.Count)
                }
            }
            $footer = New-VhdFooter $size
            $dst.Write($footer, 0, 512)
            Write-Progress -Activity 'Pass 1: copying everything that reads cleanly' -Completed
        }
        if ($pending.Count) {
            $todo = @($pending); $j = 0; $bad = 0; $dead = 0
            Write-Host "Pass 2: retrying $($todo.Count) MB of damaged areas piece by piece (this part can be slow)..."
            foreach ($off in $todo) {
                $n = [int][math]::Min([long]$chunk, $size - $off)
                $good = 0; $badHere = @()
                if (Read-Into $src $buf $off 0 $n) { $good = 1; $lastGood = $off }
                else {
                    # 64 KB pieces first, then only the failing pieces sector by sector; zero-fill what can't be read.
                    [Array]::Clear($buf, 0, $n)
                    for ($o = 0; $o -lt $n; $o += 64KB) {
                        $m = [math]::Min(64KB, $n - $o)
                        if (Read-Into $src $buf $off $o $m) { $good++; continue }
                        for ($s = $o; $s -lt $o + $m; $s += $ss) {
                            if (Read-Into $src $buf $off $s $ss) { $good++; continue }
                            [Array]::Clear($buf, $s, $ss); $badHere += $s
                        }
                    }
                }
                # A failure may just mean the drive dropped out mid-way: never save zeros unless it still responds.
                if ($badHere -and -not (& $alive)) { throw ($dropped -f [math]::Round($off / 1MB)) }
                if ($good) { $dead = 0 } elseif (++$dead -ge 32 -and $lastGood -lt 0) { throw ($dropped -f [math]::Round($off / 1MB)) }
                foreach ($s in $badHere) { $bad++; Add-Content $log ('sector {0} (byte offset {1})' -f (($off + $s) / $ss), ($off + $s)) }
                $dst.Position = $off; $dst.Write($buf, 0, $n); $dst.Flush()
                Add-Content $map "done $off"   # only after the data is on disk
                Write-Progress -Activity 'Pass 2: scraping damaged areas' -PercentComplete ([int](100 * ++$j / $todo.Count)) `
                    -Status ('{0} / {1} MB   unreadable sectors: {2}' -f $j, $todo.Count, $bad)
            }
            Write-Progress -Activity 'Pass 2: scraping damaged areas' -Completed
        }
        $bad = if (Test-Path $log) { @(Get-Content $log).Count } else { 0 }
        if ($bad) { Write-Warning "$bad unreadable sectors were zero-filled (list: $log). Files touching them may be partly damaged." }
        else { Write-Host 'Every sector read fine - the drive hardware looks OK, only the file system is damaged.' -ForegroundColor Green }
    } finally { $src.Dispose(); $dst.Dispose() }
}

function Repair-BootSectors([string]$img, $layout, [int]$ss) {
    $fs = [IO.FileStream]::new($img, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
    try {
        foreach ($p in $layout) {
            $off = [long]$p.Offset; $label = "Partition at $([math]::Round($off / 1MB)) MB"
            $cur = Get-BootFs (Read-At $fs $off $ss)
            if ($cur) { Write-Host "$label : $cur boot sector looks OK"; continue }
            $done = $false
            # Backup locations: FAT32 sectors 6-8, exFAT sectors 12-23, NTFS last sector of the partition.
            foreach ($c in @(('FAT32', 6, 3), ('exFAT', 12, 12), ('NTFS', ([long]($p.Size / $ss) - 1), 1))) {
                $at = $off + $c[1] * $ss
                if ((Get-BootFs (Read-At $fs $at $ss)) -eq $c[0]) {
                    $data = Read-At $fs $at ($c[2] * $ss)
                    $fs.Position = $off; $fs.Write($data, 0, $data.Length)
                    Write-Host "$label : boot sector was damaged - restored from the $($c[0]) backup copy" -ForegroundColor Green
                    $done = $true; break
                }
            }
            if (-not $done) { Write-Warning "$label : boot sector damaged and no usable backup found (FAT12/FAT16 keep none). The next steps still try." }
        }
    } finally { $fs.Dispose() }
}

function Copy-Out([string]$from, [string]$to, [string]$log) {
    robocopy $from $to /E /COPY:DT /DCOPY:T /R:0 /W:0 /XJ /NP /NFL /NDL /XD '$RECYCLE.BIN' 'System Volume Information' "/LOG+:$log" /TEE | Out-Host
    $LASTEXITCODE   # 0-7 = fine, 8+ = some files failed
}

# "2023-05-14 18.22.31" from a photo's EXIF date taken, or $null.
function Get-PhotoDate([string]$path) {
    try {
        $s = [IO.File]::OpenRead($path)
        try {
            $im = [Drawing.Image]::FromStream($s, $false, $false)   # no validation: only the metadata is read
            try {
                $raw = [Text.Encoding]::ASCII.GetString($im.GetPropertyItem(0x9003).Value).Trim([char]0)
                [datetime]::ParseExact($raw, 'yyyy:MM:dd HH:mm:ss', $null).ToString('yyyy-MM-dd HH.mm.ss')
            } finally { $im.Dispose() }
        } finally { $s.Dispose() }
    } catch { $null }
}

function Get-TestDisk([string]$dir) {
    $find = { Get-ChildItem $dir -Recurse -Filter photorec_win.exe -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $exe = & $find
    if (-not $exe) {
        Write-Host 'Downloading TestDisk/PhotoRec 7.2 (free, open source, cgsecurity.org)...'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $zip = "$dir.zip"
            Invoke-WebRequest 'https://www.cgsecurity.org/testdisk-7.2.win64.zip' -OutFile $zip -UseBasicParsing
            $h = (Get-FileHash $zip -Algorithm SHA256).Hash
            if ($TestDiskSha256 -and $h -ne $TestDiskSha256) { Remove-Item $zip; throw "integrity check failed (SHA256 $h is not the expected $TestDiskSha256) - not running it" }
            Expand-Archive $zip $dir -Force; Remove-Item $zip
            $exe = & $find
        } catch { Write-Warning "Download failed: $_" }
    }
    if (-not $exe) { Write-Warning "Download TestDisk for Windows from https://www.cgsecurity.org/wiki/TestDisk_Download, unzip it into $dir and run the script again."; return $null }
    $exe.DirectoryName
}

# ---------------------------------------------------------------------------------------------
Write-Host "usb-rescue $Version - https://github.com/YousefYGhanem/usb-rescue"
Step '1/5 Diagnose'
if ($DiskNumber -lt 0) {
    $usb = @(Get-Disk | Where-Object BusType -eq 'USB')
    if (-not $usb) { throw 'No USB disk found. Try another port (back of the PC) or cable, then check Disk Management.' }
    $usb | Format-Table Number, FriendlyName, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 2) } }, PartitionStyle, OperationalStatus -AutoSize | Out-Host
    $DiskNumber = if ($usb.Count -eq 1) { $usb[0].Number } else { [int](Read-Host 'Disk number of the broken USB drive') }
}
$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is your Windows disk, not the USB drive." }
$size = [long]$disk.Size
$ss = [int]$disk.LogicalSectorSize
if ($size -le 0) { throw 'The drive reports 0 bytes / No Media: its controller has failed. Only a data-recovery lab can help now - stop plugging it in.' }
$parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object { $_.Type -notin 'Reserved', 'Extended' })
Write-Host ("Disk {0}: {1}, {2:N2} GB, partition style {3}, {4}-byte sectors, status {5}" -f $DiskNumber, $disk.FriendlyName, ($size / 1GB), $disk.PartitionStyle, $ss, $disk.OperationalStatus)
foreach ($p in $parts) {
    $v = $p | Get-Volume -ErrorAction SilentlyContinue
    Write-Host ("  Partition {0}: starts at {1:N0} MB, {2:N2} GB, letter '{3}', file system '{4}'" -f $p.PartitionNumber, ($p.Offset / 1MB), ($p.Size / 1GB), $p.DriveLetter, $v.FileSystem)
}
if (-not $parts) { Write-Warning 'No partitions visible - the partition table itself is damaged. Imaging anyway; see the TestDisk tip at the end.' }

$usbLetters = @($parts | ForEach-Object { [string]$_.DriveLetter } | Where-Object { $_ -match '[A-Z]' })
if (-not $OutDir) {
    $best = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and [string]$_.DriveLetter -match '[A-Z]' -and [string]$_.DriveLetter -notin $usbLetters } |
        Sort-Object SizeRemaining -Descending | Select-Object -First 1
    $OutDir = "$($best.DriveLetter):\UsbRecovery"
}
if ($OutDir -notmatch '^[A-Za-z]:\\') { throw 'OutDir must be a local path like D:\UsbRecovery' }
if ([string]$OutDir[0] -in $usbLetters) { throw 'OutDir must NOT be on the USB drive you are recovering.' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$img = Join-Path $OutDir 'usb.vhd'
$need = $size + 512 - $(if (Test-Path $img) { (Get-Item $img).Length } else { 0 })
$free = (Get-PSDrive $OutDir.Substring(0, 1)).Free
if ($free -lt $need) { throw ("Not enough space in {0}: need {1:N1} GB free for the image, have {2:N1} GB. Use -OutDir on a bigger drive." -f $OutDir, ($need / 1GB), ($free / 1GB)) }
if ($free -lt $need + $size) { Write-Warning 'There may not be enough free space for both the image and the recovered files.' }
Start-Transcript -Path (Join-Path $OutDir 'log.txt') -Append | Out-Null   # full log to share when asking for help
Write-Host "Output folder: $OutDir"

Step '2/5 Image the drive (read-only)'
Copy-Disk $DiskNumber $size $ss $img (Join-Path $OutDir 'bad-sectors.txt')

Step '3/5 Repair boot sectors on the copy'
$layout = if ($parts) { $parts } else { , [pscustomobject]@{ Offset = 0L; Size = $size } }
Repair-BootSectors $img $layout $ss

Step '4/5 Mount the copy and copy files out'
Write-Host 'Unplug the USB drive now - the rest works on the copy (this also avoids a disk-signature clash).' -ForegroundColor Yellow
Write-Host 'If Windows pops up "You need to format the disk", click CANCEL.' -ForegroundColor Yellow
Read-Host 'Press Enter when it is unplugged' | Out-Null
$filesDir = Join-Path $OutDir 'files'
$rlog = Join-Path $OutDir 'robocopy.log'
$failed = $false
$vhd = Mount-DiskImage -ImagePath $img -StorageType VHD -Access ReadWrite -PassThru
try {
    $vdisk = $vhd | Get-Disk
    if ($vdisk.IsOffline) { Set-Disk -Number $vdisk.Number -IsOffline $false }
    if ($vdisk.IsReadOnly) { Set-Disk -Number $vdisk.Number -IsReadOnly $false }
    Start-Sleep 2
    $vparts = @(Get-Partition -DiskNumber $vdisk.Number -ErrorAction SilentlyContinue | Where-Object { $_.Type -notin 'Reserved', 'Extended' })
    if (-not $vparts) { Write-Warning 'Windows sees no partitions on the copy (partition table destroyed).'; $failed = $true }
    foreach ($p in $vparts) {
        if ([string]$p.DriveLetter -notmatch '[A-Z]') {
            try { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $vdisk.Number -PartitionNumber $p.PartitionNumber } catch {}
        }
        $L = [string]$p.DriveLetter
        if ($L -notmatch '[A-Z]') { Write-Warning "Partition $($p.PartitionNumber): could not assign a drive letter."; $failed = $true; continue }
        $fsName = (Get-Volume -DriveLetter $L).FileSystem
        if (-not $fsName -or $fsName -eq 'RAW') { Write-Warning "Partition $($p.PartitionNumber) (${L}:): file system still unreadable."; $failed = $true; continue }
        $dest = Join-Path $filesDir "partition$($p.PartitionNumber)"
        Write-Host "Copying ${L}: ($fsName) -> $dest"
        $rc = Copy-Out "${L}:\" $dest $rlog
        if ($rc -ge 8) {
            Write-Host 'Some files could not be read. Running chkdsk on the COPY (your USB drive is not touched)...' -ForegroundColor Yellow
            cmd /c "echo Y| chkdsk ${L}: /f /x" | Out-Host   # "Y" = save lost chains as files in FOUND.000
            $rc = Copy-Out "${L}:\" $dest $rlog
        }
        if ($rc -ge 8) { $failed = $true; Write-Warning "Some files still failed - they are listed in $rlog" }
    }
} finally {
    Dismount-DiskImage -ImagePath $img | Out-Null
}
$count = @(Get-ChildItem $filesDir -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host "Recovered with names and folders: $count files in $filesDir" -ForegroundColor Green

$td = $null; $carve = $null
if (-not $SkipCarve) {
    Step '5/5 Deep scan with PhotoRec (optional)'
    $def = if ($count -and -not $failed) { 'n' } else { 'y' }
    $ans = Read-Host "Scan the whole copy for lost or deleted files by content? Names/folders are lost; can take hours. (y/n) [$def]"
    if (-not $ans) { $ans = $def }
    if ($ans -match '^y') {
        $td = Get-TestDisk (Join-Path $OutDir 'testdisk')
        if ($td) {
            $carve = Join-Path $OutDir 'carved'
            New-Item -ItemType Directory -Force $carve | Out-Null   # PhotoRec fails if the parent folder is missing
            Push-Location $OutDir
            try { & (Join-Path $td 'photorec_win.exe') /log /d (Join-Path $carve 'recup') /cmd $img 'partition_none,fileopt,everything,enable,search' }
            finally { Pop-Location }
            $new = @(Get-ChildItem $carve -Directory -Filter 'recup.*' | Get-ChildItem -File | Where-Object Name -ne 'report.xml')
            $n = $new.Count
            # Sort new PhotoRec output into one folder per file type (jpg, docx, mp4...), and put the date
            # taken in front of photo names. PhotoRec names are unique, so nothing clashes.
            Add-Type -AssemblyName System.Drawing
            foreach ($f in $new) {
                $ext = if ($f.Extension) { $f.Extension.TrimStart('.').ToLower() } else { 'no-extension' }
                $d = Join-Path $carve $ext
                New-Item -ItemType Directory -Force $d | Out-Null
                $name = $f.Name
                if ($ext -in 'jpg', 'jpeg') { $taken = Get-PhotoDate $f.FullName; if ($taken) { $name = "$taken $name" } }
                Move-Item -LiteralPath $f.FullName -Destination (Join-Path $d $name)
            }
            Get-ChildItem $carve -Directory -Filter 'recup.*' | Where-Object { -not (Get-ChildItem $_.FullName -File | Where-Object Name -ne 'report.xml') } | Remove-Item -Recurse
            Write-Host "PhotoRec recovered $n files into $carve, sorted into one folder per file type" -ForegroundColor Green
        }
    }
}

Step 'Done'
Write-Host "Files with original names : $filesDir"
if ($carve) { Write-Host "Files found by deep scan  : $carve" }
Write-Host "Drive image               : $img"
Write-Host '  Keep the image until you have checked your files, then delete it. You can reformat the USB drive after that'
Write-Host '  Before trusting the drive again, test its real capacity with H2testw or f3: cheap "Generic Flash Disk" sticks often'
Write-Host '  fake their size and silently overwrite old files once full - a classic cause of exactly this corruption.'
Write-Host "  Full log of this run: $OutDir\log.txt"
Stop-Transcript | Out-Null
if ($failed) {
    $tdExe = if ($td) { Join-Path $td 'testdisk_win.exe' } else { "$OutDir\testdisk\...\testdisk_win.exe" }
    Write-Host "`nA partition was still unreadable. TestDisk can search the image for lost partitions and copy files out:" -ForegroundColor Yellow
    Write-Host "  & '$tdExe' '$img'"
    Write-Host '  Proceed > Intel (or EFI GPT) > Analyse > Quick Search (then Deeper Search) > highlight the partition > P to list files > C to copy.'
}
