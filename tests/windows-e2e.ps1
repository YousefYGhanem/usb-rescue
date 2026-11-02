# End-to-end test of the Windows-only parts on a real (virtual) disk: VHD footer, raw read-only
# imaging of \\.\PhysicalDriveN, boot-sector repair and mounting the copy.
# For each file system it builds a disk, writes a file, wipes the boot sector (what makes Windows
# say "RAW"), then recovers the file with the script's own functions. Needs Administrator; used by CI.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Load the script's functions and the RawDisk source without running its interactive main flow.
$ast = [Management.Automation.Language.Parser]::ParseFile("$root\Recover-UsbDrive.ps1", [ref]$null, [ref]$null)
foreach ($n in $ast.EndBlock.Statements) {
    if ($n -is [Management.Automation.Language.FunctionDefinitionAst] -or
        ($n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$rawDiskCs')) {
        . ([scriptblock]::Create($n.Extent.Text))
    }
}

function Assert-SameBytes([string]$a, [string]$b, [long]$n) {
    $x = [IO.File]::OpenRead($a); $y = [IO.File]::OpenRead($b); $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bx = New-Object byte[] 1MB; $by = New-Object byte[] 1MB
        for ($p = 0L; $p -lt $n; $p += 1MB) {
            $k = [int][math]::Min([long]1MB, $n - $p)
            [void](Read-Into $x $bx $p 0 $k); [void](Read-Into $y $by $p 0 $k)
            if ([Convert]::ToBase64String($sha.ComputeHash($bx, 0, $k)) -ne [Convert]::ToBase64String($sha.ComputeHash($by, 0, $k))) { throw "image differs from the disk at byte $p" }
        }
    } finally { $x.Dispose(); $y.Dispose() }
}

function Get-Letter($diskNumber) {
    $p = Get-Partition -DiskNumber $diskNumber | Where-Object Type -NotIn 'Reserved', 'Extended' | Select-Object -First 1
    if ([string]$p.DriveLetter -notmatch '[A-Z]') { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber }
    [string]$p.DriveLetter
}

$work = Join-Path ([IO.Path]::GetTempPath()) "usb-rescue-e2e-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$size = 512MB
$data = New-Object byte[] 3MB; (New-Object Random 1).NextBytes($data)
$fails = 0
foreach ($fsType in 'FAT32', 'exFAT', 'NTFS') {
    $src = "$work\usb-$fsType.vhd"; $out = "$work\copy-$fsType.vhd"
    try {
        # A blank disk built with the script's own VHD footer (also proves Windows accepts the footer).
        $fs = [IO.File]::Create($src); $fs.SetLength($size); $fs.Position = $size; $fs.Write((New-VhdFooter $size), 0, 512); $fs.Dispose()
        $disk = Mount-DiskImage -ImagePath $src -PassThru | Get-Disk
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR
        $p = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $p -FileSystem $fsType -Confirm:$false | Out-Null
        $p = Get-Partition -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber
        [IO.File]::WriteAllBytes("$($p.DriveLetter):\photo.bin", $data)
        $off = [long]$p.Offset; $psize = [long]$p.Size
        Dismount-DiskImage -ImagePath $src | Out-Null

        # Break it like the real drive: wipe the partition's boot sector.
        $fs = [IO.File]::OpenWrite($src); $fs.Position = $off; $fs.Write((New-Object byte[] 512), 0, 512); $fs.Dispose()

        # Image the broken disk through \\.\PhysicalDriveN, exactly as from a USB drive.
        $disk = Mount-DiskImage -ImagePath $src -Access ReadOnly -PassThru | Get-Disk
        Copy-Disk $disk.Number ([long]$disk.Size) 512 $out "$work\bad-$fsType.txt"
        Dismount-DiskImage -ImagePath $src | Out-Null
        Assert-SameBytes $src $out $size
        if ((Get-Item $out).Length -ne $size + 512) { throw 'image has the wrong length' }

        Repair-BootSectors $out @([pscustomobject]@{ Offset = $off; Size = $psize }) 512
        $vd = Mount-DiskImage -ImagePath $out -PassThru | Get-Disk
        try {
            $L = Get-Letter $vd.Number
            $got = [IO.File]::ReadAllBytes("${L}:\photo.bin")
            if ([Convert]::ToBase64String($got) -ne [Convert]::ToBase64String($data)) { throw 'recovered file content differs' }
        } finally { Dismount-DiskImage -ImagePath $out | Out-Null }
        Write-Host "$fsType : PASS (imaged, boot sector repaired, file recovered intact)"
    } catch {
        $fails++
        Write-Host "::error::$fsType : FAIL - $_"
        Get-DiskImage -ImagePath $src -ErrorAction SilentlyContinue | Where-Object Attached | Dismount-DiskImage | Out-Null
        Get-DiskImage -ImagePath $out -ErrorAction SilentlyContinue | Where-Object Attached | Dismount-DiskImage | Out-Null
    }
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
exit $fails
