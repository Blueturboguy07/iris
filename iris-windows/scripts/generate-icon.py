"""Generate Clicky Windows app icon — blue glowing cursor on dark background."""

from PIL import Image, ImageDraw, ImageFilter
import math
import os

SIZE = 512

def draw_icon(size):
    """Create the icon at a given size."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Dark circular background
    margin = int(size * 0.04)
    draw.ellipse(
        [margin, margin, size - margin, size - margin],
        fill=(12, 12, 20, 255),
    )

    # Blue glow behind cursor — draw on separate layer and blur
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)

    cx, cy = size * 0.48, size * 0.46
    glow_r = size * 0.28
    # Layered glow circles
    for i in range(8):
        r = glow_r * (1 + i * 0.15)
        alpha = max(10, 80 - i * 10)
        glow_draw.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            fill=(59, 130, 246, alpha),
        )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=size * 0.06))
    img = Image.alpha_composite(img, glow)
    draw = ImageDraw.Draw(img)

    # Draw cursor pointer (classic arrow shape)
    # Scale all points relative to size
    s = size / 512.0

    # Cursor arrow vertices — pointing top-left
    cursor_points = [
        (155 * s, 115 * s),   # tip (top-left)
        (155 * s, 365 * s),   # bottom of left edge
        (210 * s, 310 * s),   # inner notch left
        (280 * s, 400 * s),   # bottom-right tail end
        (320 * s, 370 * s),   # bottom-right tail top
        (250 * s, 280 * s),   # inner notch right
        (330 * s, 280 * s),   # right wing tip
    ]

    # White cursor body
    draw.polygon(cursor_points, fill=(255, 255, 255, 240))

    # Dark border around cursor
    for i in range(len(cursor_points)):
        p1 = cursor_points[i]
        p2 = cursor_points[(i + 1) % len(cursor_points)]
        draw.line([p1, p2], fill=(30, 30, 50, 200), width=max(2, int(3 * s)))

    # Small blue dot at cursor tip (the "buddy" glow)
    dot_cx, dot_cy = 155 * s, 115 * s
    dot_r = 14 * s
    # Outer glow
    for i in range(5):
        r = dot_r * (1 + i * 0.6)
        alpha = max(10, 120 - i * 25)
        draw.ellipse(
            [dot_cx - r, dot_cy - r, dot_cx + r, dot_cy + r],
            fill=(59, 130, 246, alpha),
        )
    # Inner bright dot
    draw.ellipse(
        [dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r],
        fill=(100, 160, 255, 230),
    )

    return img


def main():
    assets_dir = os.path.join(os.path.dirname(__file__), "..", "assets")
    os.makedirs(assets_dir, exist_ok=True)

    # Generate 512px master
    icon_512 = draw_icon(512)
    icon_512.save(os.path.join(assets_dir, "icon.png"))
    print("Created assets/icon.png (512x512)")

    # Generate .ico with multiple sizes for Windows
    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    ico_images = []
    for s in ico_sizes:
        resized = icon_512.resize((s, s), Image.LANCZOS)
        ico_images.append(resized)

    ico_path = os.path.join(assets_dir, "icon.ico")
    ico_images[0].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
        append_images=ico_images[1:],
    )
    print(f"Created assets/icon.ico ({', '.join(str(s) for s in ico_sizes)})")

    # Tray icon (smaller, 32px PNG)
    tray = icon_512.resize((32, 32), Image.LANCZOS)
    tray.save(os.path.join(assets_dir, "tray-icon.png"))
    print("Created assets/tray-icon.png (32x32)")


if __name__ == "__main__":
    main()
