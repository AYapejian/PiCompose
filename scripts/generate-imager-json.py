#!/usr/bin/env python3
"""Generate an rpi-imager catalog JSON for ara-kiosk-image.

Output: a single rpi-imager.json file pointing at the most recent
release on the configured GitHub repo that has an .img.xz asset. The
image declares init_format=cloudinit-rpi so rpi-imager's customisation
wizard offers hostname, SSH, Wi-Fi, locale.

Schema notes (cross-checked against the official RPi catalog at
https://downloads.raspberrypi.com/os_list_imagingutility_v3.json):

  - init_format must be "cloudinit-rpi" or "systemd". "cloud-init"
    (with a hyphen) is not recognised and silently filters the entry.
  - extract_size is effectively required; rpi-imager won't list an
    OS entry without it because the SD-card-space precheck depends
    on the decompressed size.
  - extract_sha256 is optional but recommended; gives the imager an
    integrity check after decompression.
  - capabilities is for special features like "rpi_connect", NOT
    customisation-wizard fields. Those are inferred from init_format.

Configuration via env vars:
  REPO_OWNER  default: AYapejian
  REPO_NAME   default: PiCompose
  OUTPUT_FILE default: rpi-imager.json
"""

import hashlib
import json
import lzma
import os
import sys
import urllib.request

OWNER = os.environ.get("REPO_OWNER", "AYapejian")
REPO = os.environ.get("REPO_NAME", "PiCompose")
OUTPUT_FILE = os.environ.get("OUTPUT_FILE", "rpi-imager.json")
RELEASES_URL = f"https://api.github.com/repos/{OWNER}/{REPO}/releases?per_page=50"
SELF_TAG = "rpi-imager-json"

DEVICES = [
    {
        "name": "Raspberry Pi 5",
        "tags": ["pi5-64bit"],
        "default": True,
        "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_5.png",
        "description": "Raspberry Pi 5 (required — the kiosk and reSpeaker stack assume Pi 5 + arm64)",
        "matching_type": "exclusive",
    },
    {
        "name": "No filtering",
        "tags": [],
        "description": "Show every image regardless of device tag",
        "matching_type": "inclusive",
    },
]


def fetch_releases():
    req = urllib.request.Request(
        RELEASES_URL,
        headers={"User-Agent": "ara-kiosk-imager-json/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def find_image_asset(release):
    img = sha = None
    for asset in release.get("assets") or []:
        if asset["name"].endswith(".img.xz"):
            img = asset
        elif asset["name"].endswith(".img.xz.sha256"):
            sha = asset
    return img, sha


def fetch_xz_metrics(img_xz_url):
    """Stream-download the .img.xz, decompress on the fly, return
    (extract_size, extract_sha256_hex). Never writes to disk; memory
    use is one 1 MB chunk at a time."""
    print(f"  -> streaming {img_xz_url} for extract size/sha256 …", file=sys.stderr)
    sha = hashlib.sha256()
    size = 0
    decompressor = lzma.LZMADecompressor()
    req = urllib.request.Request(
        img_xz_url, headers={"User-Agent": "ara-kiosk-imager-json/1.0"}
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        while True:
            chunk = r.read(1024 * 1024)
            if not chunk:
                break
            decompressed = decompressor.decompress(chunk)
            if decompressed:
                sha.update(decompressed)
                size += len(decompressed)
    if not decompressor.eof:
        raise RuntimeError("xz stream did not end at EOF — incomplete download?")
    print(f"     extract_size={size} extract_sha256={sha.hexdigest()}", file=sys.stderr)
    return size, sha.hexdigest()


def fetch_xz_sha256_sidecar(sha_asset_url):
    """Fetch and parse a `<hash>  <filename>` sidecar file."""
    if not sha_asset_url:
        return None
    try:
        with urllib.request.urlopen(sha_asset_url, timeout=30) as r:
            text = r.read().decode("utf-8", errors="replace").strip()
        return text.split()[0] if text else None
    except Exception as e:
        print(f"  -> sha256 sidecar fetch failed ({e}); skipping", file=sys.stderr)
        return None


def build_subitem(release, img_asset, sha_asset):
    extract_size, extract_sha256 = fetch_xz_metrics(img_asset["browser_download_url"])
    image_download_sha256 = fetch_xz_sha256_sidecar(
        sha_asset["browser_download_url"] if sha_asset else None
    )

    item = {
        "name": f"ara-kiosk ({release['tag_name']})",
        "description": (
            "Pi 5 + reSpeaker XVF3800 + Linux Voice Assistant + Chromium kiosk. "
            f"Tag: {release['tag_name']}, "
            f"published: {(release.get('published_at') or 'unknown')[:10]}."
        ),
        "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_5.png",
        "url": img_asset["browser_download_url"],
        "release_date": (release.get("published_at") or "")[:10],
        # Compressed .img.xz stats
        "image_download_size": img_asset["size"],
        # Decompressed .img stats — both required for rpi-imager to
        # display the entry and verify the SD card has enough space.
        "extract_size": extract_size,
        "extract_sha256": extract_sha256,
        # Tells rpi-imager's customisation wizard which scheme to use.
        # cloudinit-rpi consumes /boot/firmware/custom.toml on first boot.
        "init_format": "cloudinit-rpi",
        "devices": ["pi5-64bit"],
    }
    if image_download_sha256:
        item["image_download_sha256"] = image_download_sha256
    return item


def main():
    releases = fetch_releases()
    releases = [r for r in releases if r.get("tag_name") != SELF_TAG]
    releases.sort(key=lambda r: r.get("published_at") or "", reverse=True)

    subitems_all = []
    for release in releases:
        img, sha = find_image_asset(release)
        if img is None:
            continue
        print(f"==> processing release {release['tag_name']}", file=sys.stderr)
        try:
            subitems_all.append((release, build_subitem(release, img, sha)))
        except Exception as e:
            print(f"  -> skipping {release['tag_name']}: {e}", file=sys.stderr)

    if not subitems_all:
        print(f"ERROR: no usable .img.xz on {OWNER}/{REPO}", file=sys.stderr)
        sys.exit(1)

    latest_release, latest_item = subitems_all[0]
    os_list = [
        {
            "name": "ara-kiosk (Latest)",
            "description": "Most recent ara-kiosk-image build",
            "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_5.png",
            "subitems": [latest_item],
        }
    ]

    if len(subitems_all) > 1:
        os_list.append(
            {
                "name": "ara-kiosk (All Versions)",
                "description": "Every published ara-kiosk-image build",
                "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_5.png",
                "subitems": [item for _, item in subitems_all],
            }
        )

    catalog = {
        "imager": {
            "latest_version": (latest_release.get("tag_name") or "0.0.0").lstrip("v"),
            "url": f"https://github.com/{OWNER}/{REPO}",
            "devices": DEVICES,
        },
        "os_list": os_list,
    }

    with open(OUTPUT_FILE, "w") as f:
        json.dump(catalog, f, indent=2)
    print(
        f"wrote {OUTPUT_FILE}: latest={latest_release['tag_name']} "
        f"({len(subitems_all)} image(s) total)"
    )


if __name__ == "__main__":
    main()
