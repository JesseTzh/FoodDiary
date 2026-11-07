"""Prepare identical, deterministic photo sizes for before/after browser runs."""
import argparse
from pathlib import Path
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
with Image.open(args.source) as source:
    for name, side in {"original": 1254, "thumbnail": 384, "medium": 640, "preview": 1024}.items():
        image = source.convert("RGB")
        image.thumbnail((side, side), Image.Resampling.BILINEAR)
        image.save(args.output / f"{name}.jpg", quality=82)
