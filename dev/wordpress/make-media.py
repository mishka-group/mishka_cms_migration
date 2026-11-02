# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

"""Draws the sample media the seeded WordPress uploads (jpg, png, webp, gif, pdf, svg, mp4).

The files are written to ./media and committed, so `seed.sh` needs neither Pillow nor ffmpeg.
Run it again only to change the samples:  python3 make-media.py   (needs Pillow and ffmpeg)
"""

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent / "media"
OUT.mkdir(exist_ok=True)


def font(size):
    return ImageFont.load_default(size=size)


def gradient(size, top, bottom):
    width, height = size
    img = Image.new("RGB", size)
    px = img.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(width):
            px[x, y] = row
    return img


def label(img, text, shapes=True, size=None):
    draw = ImageDraw.Draw(img)
    width, height = img.size
    if shapes:
        draw.ellipse((width * 0.62, height * 0.12, width * 0.92, height * 0.12 + width * 0.3), fill=(255, 255, 255))
        draw.polygon([(0, height), (width * 0.35, height * 0.55), (width * 0.7, height)], fill=(20, 40, 70))
    size = size or max(height // 9, 14)
    draw.text((width * 0.06, height * 0.08), text, fill=(255, 255, 255), font=font(size))
    return img


def avatar(name, colour, letter):
    img = Image.new("RGB", (256, 256), colour)
    draw = ImageDraw.Draw(img)
    draw.ellipse((78, 40, 178, 140), fill=(255, 255, 255))
    draw.ellipse((38, 150, 218, 330), fill=(255, 255, 255))
    draw.text((104, 70), letter, fill=colour, font=font(56))
    img.save(OUT / name, "PNG", optimize=True)


# jpg: a hero, a wide cover, three gallery images and the Open Graph image
label(gradient((1600, 900), (28, 78, 140), (120, 190, 220)), "Hero image").save(OUT / "hero.jpg", quality=72)
label(gradient((1920, 600), (90, 30, 110), (240, 140, 90)), "Cover image").save(OUT / "cover.jpg", quality=70)
for n, (a, b) in enumerate([((30, 120, 90), (190, 230, 150)), ((150, 50, 50), (250, 190, 120)), ((40, 60, 130), (160, 150, 230))], 1):
    label(gradient((800, 600), a, b), f"Gallery {n}").save(OUT / f"gallery-{n}.jpg", quality=70)
label(gradient((1200, 630), (20, 20, 40), (80, 60, 160)), "Open Graph", size=96).save(OUT / "og-image.jpg", quality=72)

# png: a diagram with transparency, the site logo (wide) and the site icon (square, 512)
diagram = Image.new("RGBA", (1200, 630), (0, 0, 0, 0))
d = ImageDraw.Draw(diagram)
for i, (x, name) in enumerate([(80, "WordPress"), (480, "Normalize"), (880, "Mishka CMS")]):
    d.rounded_rectangle((x, 220, x + 240, 410), 24, fill=(35, 85, 150, 255))
    d.text((x + 24, 290), name, fill=(255, 255, 255, 255), font=font(34))
    if i < 2:
        d.polygon([(x + 260, 300), (x + 360, 300), (x + 360, 270), (x + 400, 315), (x + 360, 360), (x + 360, 330), (x + 260, 330)], fill=(240, 160, 40, 255))
diagram.save(OUT / "diagram.png", optimize=True)

logo = Image.new("RGBA", (400, 120), (0, 0, 0, 0))
d = ImageDraw.Draw(logo)
d.rounded_rectangle((0, 10, 100, 110), 20, fill=(35, 85, 150, 255))
d.text((26, 34), "M", fill=(255, 255, 255, 255), font=font(60))
d.text((120, 36), "Mishka Test", fill=(35, 85, 150, 255), font=font(44))
logo.save(OUT / "site-logo.png", optimize=True)

icon = Image.new("RGB", (512, 512), (35, 85, 150))
d = ImageDraw.Draw(icon)
d.text((150, 130), "M", fill=(255, 255, 255), font=font(260))
icon.save(OUT / "site-icon.png", optimize=True)

# webp and gif
label(gradient((1200, 800), (160, 60, 90), (250, 210, 170)), "WebP photo").save(OUT / "photo.webp", "WEBP", quality=70)
frames = [label(gradient((400, 300), (c, 90, 200 - c), (255 - c, 200, 120)), f"Frame {n}", size=40) for n, c in enumerate([20, 90, 160], 1)]
frames[0].save(OUT / "animated.gif", save_all=True, append_images=frames[1:], duration=350, loop=0, optimize=True)

# avatars for the three authors and the contributor
avatar("avatar-shahryar.png", (35, 85, 150), "S")
avatar("avatar-nadia.png", (150, 60, 100), "N")
avatar("avatar-omid.png", (40, 130, 90), "O")
avatar("avatar-parisa.png", (130, 90, 30), "P")

# svg: WordPress refuses it by default; the seed records that and then imports it once with the type allowed
(OUT / "logo.svg").write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" width="120" height="120">'
    '<title>Mishka mark</title><rect width="120" height="120" rx="24" fill="#235596"/>'
    '<path d="M30 90V30l30 34 30-34v60" fill="none" stroke="#fff" stroke-width="10" stroke-linejoin="round"/></svg>\n'
)


# pdf: a one-page document written by hand (xref offsets are computed)
def pdf():
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        None,
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    text = b"BT /F1 24 Tf 72 740 Td (Migration guide) Tj 0 -36 Td /F1 12 Tf (A sample PDF attached to the seeded WordPress.) Tj ET"
    objs[3] = b"<< /Length %d >>\nstream\n" % len(text) + text + b"\nendstream"
    body, offsets = b"%PDF-1.4\n", []
    for i, obj in enumerate(objs, 1):
        offsets.append(len(body))
        body += b"%d 0 obj\n" % i + obj + b"\nendobj\n"
    xref = len(body)
    body += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    body += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    body += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    (OUT / "guide.pdf").write_bytes(body)


pdf()

# mp4: two seconds of a test pattern, no audio
subprocess.run(
    ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15:duration=2",
     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "34", "-movflags", "+faststart", "-an", str(OUT / "sample.mp4")],
    check=True,
)
print("wrote", len(list(OUT.iterdir())), "files to", OUT)
