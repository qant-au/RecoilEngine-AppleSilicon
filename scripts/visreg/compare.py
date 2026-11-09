"""Compare visreg pictures with their baselines (scripts/visreg.sh).

Usage: compare.py <baseline-dir> <run-dir> [--max-mean M] [--max-bad-pct P]
An optional limits.txt in the baseline dir overrides the limits per picture,
one line each: <name.png> <max-mean> <max-bad-pct> (# starts a comment).
Writes <name>-diff.png beside each failing picture and prints VISREG_OK or
VISREG_FAIL with one line per picture.
"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops

ap = argparse.ArgumentParser()
ap.add_argument("base")
ap.add_argument("run")
ap.add_argument("--max-mean", type=float, default=3.0)
ap.add_argument("--max-bad-pct", type=float, default=2.0)
ap.add_argument("--bad-level", type=int, default=40)
a = ap.parse_args()

base, run = Path(a.base), Path(a.run)
fails = 0
limits = {}
lf = base / "limits.txt"
if lf.exists():
    for line in lf.read_text().splitlines():
        f = line.split("#", 1)[0].split()
        if len(f) == 3:
            limits[f[0]] = (float(f[1]), float(f[2]))
names = sorted(p.name for p in base.glob("*.png") if not p.name.endswith("-diff.png"))
if not names:
    print(f"VISREG_FAIL no baselines in {base}")
    sys.exit(1)
for name in names:
    r = run / name
    if not r.exists():
        print(f"  {name}: MISSING from run")
        fails += 1
        continue
    b_img = Image.open(base / name).convert("RGB")
    r_img = Image.open(r).convert("RGB")
    if b_img.size != r_img.size:
        print(f"  {name}: SIZE {r_img.size} vs baseline {b_img.size}")
        fails += 1
        continue
    diff = ImageChops.difference(b_img, r_img)
    hist = diff.histogram()  # 3 x 256
    px = b_img.size[0] * b_img.size[1]
    mean = sum(i * c for ch in range(3) for i, c in enumerate(hist[ch * 256:(ch + 1) * 256])) / (px * 3)
    worst = diff.convert("L").point(lambda v: 255 if v > a.bad_level else 0)
    bad_pct = 100.0 * worst.histogram()[255] / px
    max_mean, max_bad = limits.get(name, (a.max_mean, a.max_bad_pct))
    ok = mean <= max_mean and bad_pct <= max_bad
    print(f"  {name}: mean {mean:.2f}  bad {bad_pct:.2f}%  {'ok' if ok else 'FAIL'}")
    if not ok:
        fails += 1
        diff.point(lambda v: min(255, v * 4)).save(run / name.replace(".png", "-diff.png"))
print("VISREG_OK" if fails == 0 else f"VISREG_FAIL {fails} of {len(names)} pictures - see {run}")
sys.exit(0 if fails == 0 else 1)
