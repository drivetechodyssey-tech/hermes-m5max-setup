from PIL import Image
import os

input_path = "/Users/sungjunmaing/Projects/IMG_2305-removebg-preview.png"
output_path = "/Users/sungjunmaing/Projects/hermes-m5max-setup/hero-logo-white.png"

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
