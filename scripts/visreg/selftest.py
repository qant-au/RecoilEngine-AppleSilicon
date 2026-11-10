"""Self-test for compare.py. Run: python3 scripts/visreg/selftest.py

Uses the baselines under testkit/visreg/ and, when present, the past runs
under logs/local/visreg-*/. Everything is compared in a temporary folder, so
no picture or diff is written into the checkout. Prints SELFTEST_OK or the
checks that failed.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LIMITS = ["--max-mean", "2.0", "--max-bad-pct", "1.0"]  # the defaults visreg.sh passes
WRONG = (255, 0, 255)
failed = []


def check(what, ok):
    print(f"{'pass' if ok else 'FAIL'}  {what}")
    if not ok:
        failed.append(what)


def compare(base, run):
    """Run compare.py; return (exit code, {picture: (mean, bad, tile, verdict)})."""
    p = subprocess.run([sys.executable, str(HERE / "compare.py"), str(base), str(run)] + LIMITS,
                       capture_output=True, text=True)
    rows = re.findall(r"^  (\S+): mean ([\d.]+)  bad ([\d.]+)%  tile ([\d.]+)% .*?(ok|FAIL)$", p.stdout, re.M)
    return p.returncode, {n: (float(m), float(b), float(t), v) for n, m, b, t, v in rows}


def pictures(folder):
    return sorted(p for p in folder.glob("*.png") if not p.name.endswith("-diff.png"))


def link(files, folder):
    folder.mkdir()
    for f in files:
        (folder / f.name).symlink_to(f)
    return folder


def old_pass(base, run):
    """The earlier whole-picture check: same mean, bad pixels from a luma mix."""
    limits = {}
    if (base / "limits.txt").exists():
        for line in (base / "limits.txt").read_text().splitlines():
            f = line.split("#", 1)[0].split()
            if len(f) >= 3:
                limits[f[0]] = (float(f[1]), float(f[2]))
    for b in pictures(base):
        if not (run / b.name).exists():
            return False
        b_img, r_img = Image.open(b).convert("RGB"), Image.open(run / b.name).convert("RGB")
        if b_img.size != r_img.size:
            return False
        diff = ImageChops.difference(b_img, r_img)
        px = b_img.size[0] * b_img.size[1]
        hist = diff.histogram()
        mean = sum((i % 256) * c for i, c in enumerate(hist)) / (px * 3)
        bad = 100.0 * diff.convert("L").point(lambda v: 255 if v > 40 else 0).histogram()[255] / px
        max_mean, max_bad = limits.get(b.name, (2.0, 1.0))
        if mean > max_mean or bad > max_bad:
            return False
    return True


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    bases = [d for d in sorted(ROOT.glob("testkit/visreg/*/*")) if pictures(d)]
    check("baselines found under testkit/visreg", bool(bases))
    for n, base in enumerate(bases):
        label = base.relative_to(ROOT / "testkit/visreg")
        # (a) a baseline compared with itself
        rc, rows = compare(base, link(pictures(base), tmp / f"self{n}"))
        check(f"{label}: baselines pass against themselves", rc == 0 and len(rows) == len(pictures(base)))

        # (b) past runs that passed the earlier check still pass
        runs = sorted(d for d in ROOT.glob("logs/local/visreg-*") if pictures(d))
        kept = 0
        for run in runs:
            if not old_pass(base, run):
                continue
            kept += 1
            rc, rows = compare(base, link(pictures(run), tmp / f"run{n}-{run.name}"))
            tiles = " ".join(f"{rows[k][2]:.1f}" for k in sorted(rows))
            check(f"{label}: {run.name} still passes (tile % per picture: {tiles})", rc == 0)
        print(f"note  {label}: {kept} of {len(runs)} past runs passed the earlier check")

        # (c) and (d) on single pictures, each in a baseline folder of its own
        for pic in pictures(base):
            one = link([pic], tmp / f"base{n}-{pic.stem}")
            img = Image.open(pic).convert("RGB")
            px = img.size[0] * img.size[1]
            # (c) a flat wrong region, placed off the window grid (the worst case)
            for side in (85, 64):
                out = tmp / f"wrong{n}-{pic.stem}-{side}"
                out.mkdir()
                bad = img.copy()
                bad.paste(WRONG, (404, 212, 404 + side, 212 + side))
                bad.save(out / pic.name)
                rc, rows = compare(one, out)
                mean, badpct, tile, verdict = rows[pic.name]
                check(f"{label}/{pic.name}: {side}x{side} wrong region fails "
                      f"(mean {mean}, bad {badpct}%, tile {tile}%)",
                      rc == 1 and verdict == "FAIL" and mean <= 2.0 and badpct <= 1.0)
            # a fourth limits.txt number loosens the window limit for one picture
            # (out still holds the 64 px case: 87.9 percent of a window)
            (one / "limits.txt").write_text(f"{pic.name} 2.0 1.0 95\n")
            rc, rows = compare(one, out)
            check(f"{label}/{pic.name}: limits.txt window override is honoured", rc == 0)
            (one / "limits.txt").unlink()
            # (d) blue alone moved by 60 over 32 x 32 px: every pixel there is bad
            out = tmp / f"blue{n}-{pic.stem}"
            out.mkdir()
            box = (404, 212, 436, 244)
            red, green, blue = img.crop(box).split()
            blue = blue.point(lambda v: v + 60 if v < 196 else v - 60)
            shifted = img.copy()
            shifted.paste(Image.merge("RGB", (red, green, blue)), box)
            shifted.save(out / pic.name)
            rc, rows = compare(one, out)
            luma = ImageChops.difference(img, shifted).convert("L").point(lambda v: 255 if v > 40 else 0)
            check(f"{label}/{pic.name}: blue-only change counts as bad pixels "
                  f"(bad {rows[pic.name][1]}%, luma mix sees {luma.histogram()[255]} pixels)",
                  rows[pic.name][1] == round(100.0 * 32 * 32 / px, 2) and luma.histogram()[255] == 0)

print("SELFTEST_OK" if not failed else f"SELFTEST_FAIL {len(failed)} checks")
sys.exit(1 if failed else 0)
