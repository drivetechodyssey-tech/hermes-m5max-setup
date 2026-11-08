
import argparse
from pathlib import Path

from PIL import Image

REPO_DIR = Path(__file__).resolve().parent

parser = argparse.ArgumentParser(description="Convert the logo to a white version for dark headers.")
parser.add_argument("input", nargs="?", type=Path,
                    default=REPO_DIR / "img" / "IMG_2305-removebg-preview.png",
                    help="source PNG (default: img/IMG_2305-removebg-preview.png)")
parser.add_argument("output", nargs="?", type=Path,
                    default=REPO_DIR / "hero-logo-white.png",
                    help="output PNG (default: hero-logo-white.png in the repo root)")
args = parser.parse_args()
input_path = args.input
output_path = args.output

img = Image.open(input_path).convert("RGBA")
print(f"Original size: {img.size}")

# Extract alpha channel and RGB channels
r, g, b, a = img.split()

# Convert to grayscale using luminance
gray_img = Image.merge("RGB", [r, g, b]).convert("L")

# Invert grayscale (dark backgrounds → white text/shapes)
inverted = gray_img.point(lambda p: 255 - p)

# Re-apply alpha
result = Image.merge("RGBA", (inverted, inverted, inverted, a))

# Resize to fit header area (max ~200px wide)
max_width = 200
if result.width > max_width:
    ratio = max_width / result.width
    new_height = int(result.height * ratio)
    result = result.resize((max_width, new_height), Image.LANCZOS)

result.save(output_path, "PNG")
print(f"Saved to: {output_path} ({result.width}x{result.height})")
