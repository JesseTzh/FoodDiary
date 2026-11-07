"""Losslessly compress Web-only assets without changing Android's source assets."""
import argparse
import json
import gzip
from pathlib import Path

try:
    import brotli
    from PIL import Image, features
except ImportError as error:
    raise SystemExit("Install Web build dependencies: python3 -m pip install -r scripts/requirements-web.txt") from error

parser = argparse.ArgumentParser()
parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent / "frontend/build/web")
args = parser.parse_args()
root = args.root.resolve()
if not features.check("webp"):
    raise SystemExit("Pillow needs WebP support for optimized Web builds")

report = {"images": [], "fonts": []}
report_path = root / "web-optimization.json"
for source in sorted((root / "assets/assets/images").glob("*.png")):
    target = source.with_suffix(".webp")
    with Image.open(source) as image:
        if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
            image.save(target, "WEBP", lossless=True, method=6, exact=True)
        with Image.open(target) as compressed:
            if image.convert("RGBA").tobytes() != compressed.convert("RGBA").tobytes():
                raise RuntimeError(f"Image pixels changed: {source}")
    report["images"].append({"source": str(source.relative_to(root)), "target": str(target.relative_to(root)),
                             "before": source.stat().st_size, "after": target.stat().st_size})

# Compress transport bytes instead of converting the font container: WOFF2
# decompression inside Skia caused a first-use main-thread stall in the benchmark.
# Browsers decode HTTP Brotli/gzip before passing the original TTF to Flutter.
for source in sorted(root.rglob('*')):
    if not source.is_file() or source.suffix not in {'.js', '.mjs', '.wasm', '.json', '.ttf', '.otf', '.bin', '.html', '.css'}:
        continue
    if source.name in {'sw.js', 'flutter_service_worker.js', 'web-optimization.json'}:
        continue
    data = source.read_bytes()
    if len(data) < 1024:
        continue
    compressed = brotli.compress(data, quality=7)
    source.with_name(source.name + '.br').write_bytes(compressed)
    source.with_name(source.name + '.gz').write_bytes(gzip.compress(data, compresslevel=6, mtime=0))
    if source.name == 'NotoSansSC.ttf':
        report['fonts'].append({'source': str(source.relative_to(root)), 'target': str(source.relative_to(root)),
                                'encoding': 'br', 'before': len(data), 'after': len(compressed)})
report_path.write_text(json.dumps(report, indent=2))
for kind, rows in report.items():
    before, after = sum(r["before"] for r in rows), sum(r["after"] for r in rows)
    print(f"Web {kind}: {before:,} -> {after:,} bytes ({(1-after/before)*100:.1f}% smaller)" if before else f"Web {kind}: already optimized")
