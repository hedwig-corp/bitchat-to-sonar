#!/usr/bin/env python3
"""Regenerate the metadata-laden fixtures for sonar-media-privacy.

    python3 -I core/sonar-media-privacy/tests/fixtures/generate.py

Needs Pillow (with WebP) and, on macOS, `sips` for the HEIC fixture. Every
piece of metadata a fixture carries contains the ASCII marker LEAK, so a test
can assert that nothing of it survives with a plain substring search. GPS
coordinates are numbers, not text: tests check those by asserting the Exif
segment that remains is the minimal Orientation-only one.
"""

import io
import os
import struct
import subprocess
import sys

from PIL import Image, ImageCms, PngImagePlugin, TiffImagePlugin
from PIL.ExifTags import IFD

HERE = os.path.dirname(os.path.abspath(__file__))
XMP = (
    b'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF '
    b'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    b'<rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" '
    b'exif:GPSLatitude="45,30.25N" exif:GPSLongitude="9,11.5E" '
    b'exif:UserComment="LEAKXMP"/></rdf:RDF></x:xmpmeta>'
)


def frame(seed):
    """A 24x16 image (landscape, so a 90-degree rotation is visible)."""
    img = Image.new("RGB", (24, 16))
    img.putdata(
        [((x * 10 + seed) % 256, (y * 15) % 256, (x * y + seed * 7) % 256) for y in range(16) for x in range(24)]
    )
    return img


def exif(orientation=6):
    e = Image.Exif()
    e[0x010F] = "LEAKMAKE"
    e[0x0110] = "LEAKMODEL"
    e[0x0131] = "LEAKSOFTWARE"
    e[0x0112] = orientation
    sub = e.get_ifd(IFD.Exif)
    sub[0x9003] = "2026:11:02 13:11:20"
    sub[0xA431] = "LEAKSERIAL"
    gps = e.get_ifd(IFD.GPSInfo)
    rational = TiffImagePlugin.IFDRational
    gps[1] = "N"
    gps[2] = (rational(45, 1), rational(30, 1), rational(1525, 100))
    gps[3] = "E"
    gps[4] = (rational(9, 1), rational(11, 1), rational(3000, 100))
    gps[6] = rational(1200, 10)
    return e.tobytes()


def segment(marker, payload):
    return b"\xff" + bytes([marker]) + struct.pack(">H", len(payload) + 2) + payload


def located_jpeg(icc):
    buf = io.BytesIO()
    frame(0).save(buf, "JPEG", quality=90, exif=exif(), comment=b"LEAKCOMMENT", icc_profile=icc)
    data = buf.getvalue()
    extra = (
        segment(0xE1, b"http://ns.adobe.com/xap/1.0/\x00" + XMP)
        + segment(0xED, b"Photoshop 3.0\x008BIM\x04\x04\x00\x00\x00\x00\x00\x0cLEAKIPTC....")
        + segment(0xE2, b"MPF\x00LEAKMPF")
        + segment(0xEB, b"JP\x00\x00LEAKJUMBF")
    )
    # Secondary image after EOI, as MPF depth maps and gain maps are stored.
    trailer = b"\xff\xd8" + segment(0xFE, b"LEAKTRAILER") + b"\xff\xd9"
    return data[:2] + extra + data[2:] + trailer


def png_info():
    info = PngImagePlugin.PngInfo()
    info.add_text("Comment", "LEAKTEXT")
    info.add_text("Software", "LEAKZTXT", zip=True)
    info.add_itxt("XML:com.adobe.xmp", XMP.decode())
    return info


def gif_with_xmp(data):
    """Insert an `XMP DataXMP` application extension before the trailer."""
    assert data.endswith(b"\x3b")
    blocks = b"".join(bytes([len(XMP[i : i + 255])]) + XMP[i : i + 255] for i in range(0, len(XMP), 255))
    ext = b"\x21\xff\x0bXMP DataXMP" + blocks + b"\x00"
    return data[:-1] + ext + b"\x3b"


def save(name, data):
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(data)
    print(f"{name}: {len(data)} bytes")


def encode(img, fmt, **kw):
    buf = io.BytesIO()
    img.save(buf, fmt, **kw)
    return buf.getvalue()


def main():
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    save("located.jpg", located_jpeg(icc))
    save("located.png", encode(frame(1), "PNG", pnginfo=png_info(), exif=exif(), icc_profile=icc))
    save(
        "located-animated.png",
        encode(frame(2), "PNG", save_all=True, append_images=[frame(3)], duration=100, loop=0, pnginfo=png_info()),
    )
    gif = encode(
        frame(4).convert("P"),
        "GIF",
        save_all=True,
        append_images=[frame(5).convert("P")],
        duration=100,
        loop=0,
        comment=b"LEAKCOMMENT",
    )
    save("located.gif", gif_with_xmp(gif))
    save("located.webp", encode(frame(6), "WEBP", quality=90, exif=exif(), xmp=XMP, icc_profile=icc))
    save(
        "located-animated.webp",
        encode(
            frame(7),
            "WEBP",
            save_all=True,
            append_images=[frame(8)],
            duration=100,
            loop=0,
            lossless=True,
            exif=exif(),
            xmp=XMP,
        ),
    )
    save("located.tiff", encode(frame(9), "TIFF", exif=exif()))
    if sys.platform == "darwin":
        jpg = os.path.join(HERE, "located.jpg")
        heic = os.path.join(HERE, "located.heic")
        subprocess.run(["sips", "-s", "format", "heic", jpg, "--out", heic], check=True, capture_output=True)
        print(f"located.heic: {os.path.getsize(heic)} bytes")


if __name__ == "__main__":
    main()
