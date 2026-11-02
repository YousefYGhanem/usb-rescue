# Model check of Copy-Disk's two-pass imaging in Recover-UsbDrive.ps1 (same steps, in Python).
# A simulated drive has bad sectors and disconnects mid-run; after resuming, the image must equal
# the drive's data with zeros exactly at the bad sectors, and no area may be lost.
import os, random, sys, tempfile
CH, SS, SIZE = 1 << 20, 512, 40 << 20

class Drive:
    def __init__(s, bad, drop_after=None):
        rnd = random.Random(1); s.data = bytes(rnd.getrandbits(8) for _ in range(SIZE)); s.bad = bad; s.reads = 0; s.drop_after = drop_after
    def read(s, off, n):  # Read-Into: None on failure
        s.reads += 1
        if s.drop_after is not None and s.reads > s.drop_after: return None
        if any(off <= b < off + n for b in s.bad): return None
        return s.data[off:off + n]

class Dropped(Exception): pass

def copy_disk(dev, img, mp, log):
    pending = set()
    if os.path.exists(mp):
        for l in open(mp).read().splitlines():
            k, _, v = l.partition(' ')
            if k == 'skip': pending.add(int(v))
            elif k == 'done': pending.discard(int(v))
    have = os.path.getsize(img) if os.path.exists(img) else 0
    if have == SIZE + 512 and not pending: return
    last_good = -1
    alive = lambda: last_good < 0 or dev.read(last_good, SS) is not None
    with open(img, 'r+b' if os.path.exists(img) else 'w+b') as dst, open(mp, 'a') as m:
        if have < SIZE + 512:
            pos = min(have // CH * CH, SIZE); dst.truncate(pos); dst.seek(pos); skip = 1
            while pos < SIZE:
                n = min(CH, SIZE - pos); b = dev.read(pos, n)
                if b is not None: dst.write(b); last_good = pos; pos += n; skip = 1
                else:
                    if not alive(): dst.truncate(pos); raise Dropped
                    end = min(pos + skip * CH, SIZE)
                    while pos < end:
                        n = min(CH, end - pos); m.write(f'skip {pos}\n'); m.flush(); pending.add(pos); dst.write(b'\0' * n); pos += n
                    skip = min(skip * 2, 64)
            dst.write(b'F' * 512)
        dead = 0
        for off in sorted(pending):
            n = min(CH, SIZE - off); good = 0; failed = []; b = dev.read(off, n)
            if b is not None: good = 1; last_good = off; buf = bytearray(b)
            else:
                buf = bytearray(n)
                for o in range(0, n, 64 << 10):
                    mm = min(64 << 10, n - o); p = dev.read(off + o, mm)
                    if p is not None: buf[o:o + mm] = p; good += 1; continue
                    for s in range(o, o + mm, SS):
                        p = dev.read(off + s, SS)
                        if p is not None: buf[s:s + SS] = p; good += 1
                        else: failed.append(s)
            if failed and not alive(): raise Dropped
            if good: dead = 0
            else:
                dead += 1
                if dead >= 32 and last_good < 0: raise Dropped
            log.update(off + s for s in failed)
            dst.seek(off); dst.write(buf); dst.flush(); m.write(f'done {off}\n'); m.flush()

bad = {5 * CH + 7 * SS, 5 * CH + 9 * SS, 6 * CH, 20 * CH + 100 * SS, SIZE - SS}
fails = 0
for drop in (None, 30, 60, 120, 400):
    d = tempfile.mkdtemp(); img, mp, log = f'{d}/usb.vhd', f'{d}/usb.vhd.map', set()
    dev = Drive(bad, drop); runs = 0
    while True:
        runs += 1
        try: copy_disk(dev, img, mp, log); break
        except Dropped: dev.drop_after = None; dev.reads = 0   # user replugs the drive and reruns
    got = open(img, 'rb').read()
    want = bytearray(dev.data)
    for b in bad: want[b:b + SS] = bytes(SS)
    ok = got[:SIZE] == bytes(want) and len(got) == SIZE + 512 and log == bad
    fails += not ok
    print(f'drop={drop}: runs={runs} image-correct={got[:SIZE] == bytes(want)} bad-logged={sorted(log) == sorted(bad)}', 'PASS' if ok else 'FAIL')
sys.exit(fails)
