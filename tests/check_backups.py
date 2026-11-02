# Self-check for the boot-sector repair rules used in Recover-UsbDrive.ps1 (same offsets/checks, in Python).
import os, struct, subprocess, sys
os.chdir(os.path.dirname(os.path.abspath(__file__)))
SS = 512
def boot_fs(b):
    if b[510:512] != b'\x55\xaa': return None
    if b[3:11] == b'EXFAT   ': return 'exFAT' if 9 <= b[108] <= 12 else None
    bps = struct.unpack_from('<H', b, 11)[0]
    if bps not in (512, 1024, 2048, 4096) or b[13] == 0: return None
    if b[3:11] == b'NTFS    ': return 'NTFS'
    if b[82:87] == b'FAT32': return 'FAT32'
    if b[54:57] == b'FAT': return 'FAT'
def repair(path, off, size):
    with open(path, 'r+b') as f:
        rd = lambda o, n: (f.seek(o), f.read(n))[1]
        if boot_fs(rd(off, SS)): return 'ok'
        for fs, at, n in (('FAT32', 6, 3), ('exFAT', 12, 12), ('NTFS', size // SS - 1, 1)):
            if boot_fs(rd(off + at * SS, SS)) == fs:
                data = rd(off + at * SS, n * SS); f.seek(off); f.write(data); return 'fixed ' + fs
    return 'no backup'
sh = lambda c: subprocess.run(c, shell=True, capture_output=True, text=True)
tests = {
  'FAT32': ('mkfs.vfat -F32 {i}', 'mcopy -i {i} hello.txt ::/', 'mtype -i {i} ::/hello.txt'),
  'exFAT': ('mkfs.exfat {i}', None, 'fsck.exfat -n {i}'),
  'NTFS':  ('mkfs.ntfs -F -f -q {i}', None, 'ntfsls {i}'),
}
open('hello.txt', 'w').write('hi\n')
fail = 0
for fs, (mk, put, chk) in tests.items():
    i = f'{fs}.img'; sh(f'rm -f {i}; truncate -s 300M {i}'); sh(mk.format(i=i))
    if put: sh(put.format(i=i))
    size = 300 * 2**20
    assert repair(i, 0, size) == 'ok', fs
    with open(i, 'r+b') as f: f.write(b'\0' * SS)          # destroy primary boot sector -> Windows shows RAW
    broken = sh(chk.format(i=i)).returncode
    r = repair(i, 0, size); good = sh(chk.format(i=i))
    ok = broken != 0 and r == 'fixed ' + fs and good.returncode == 0
    fail += not ok
    print(f'{fs}: broken-check rc={broken}, repair={r}, after-repair rc={good.returncode}', 'PASS' if ok else 'FAIL\n' + good.stdout + good.stderr)
sys.exit(fail)
