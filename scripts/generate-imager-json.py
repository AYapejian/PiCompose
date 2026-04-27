#!/usr/bin/env python3
"""Generate an rpi-imager catalog JSON for ara-kiosk-image.

Output: a single rpi-imager.json file pointing at the most recent
release on the configured GitHub repo that has an .img.xz asset.
The image is declared with init_format=cloud-init so rpi-imager's
customisation wizard offers hostname, SSH key, Wi-Fi, locale, etc. —
which is the whole point of publishing this catalog (rpi-imager hides
those fields on raw "Use custom image" flows).

Configuration is via env vars so the same script works on forks:
  REPO_OWNER  default: AYapejian
  REPO_NAME   default: PiCompose
  OUTPUT_FILE default: rpi-imager.json
"""

import json
import os
import sys
import urllib.request

OWNER = os.environ.get("REPO_OWNER", "AYapejian")
REPO = os.environ.get("REPO_NAME", "PiCompose")
OUTPUT_FILE = os.environ.get("OUTPUT_FILE", "rpi-imager.json")
RELEASES_URL = f"https://api.github.com/repos/{OWNER}/{REPO}/releases?per_page=50"
SELF_TAG = "rpi-imager-json"

# This image is built specifically for the Pi 5 (the cage/Chromium kiosk
# stack assumes Pi 5 GPU + arm64). Restricting the device list to pi5
# keeps the imager UI from offering it on hardware that won't boot it.
DEVICES = [
    {
        "name": "Raspberry Pi 5",
        "tags": ["pi5-64bit"],
        "default": True,
        "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_5.png",
        "description": "Raspberry Pi 5 (required — the kiosk and reSpeaker stack assume Pi 5 + arm64)",
        "matching_type": "exclusive",
        "capabilities": [],
    },
    {
        "name": "No filtering",
        "tags": [],
        "description": "Show every image regardless of device tag",
        "matching_type": "inclusive",
        "capabilities": [],
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
    """Return (img_asset, sha256_asset) for the release, or (None, None)
    if no .img.xz is attached."""
    img = sha = None
    for asset in release.get("assets") or []:
        if asset["name"].endswith(".img.xz"):
            img = asset
        elif asset["name"].endswith(".img.xz.sha256"):
            sha = asset
    return img, sha


def build_subitem(release, img_asset, sha_asset):
    item = {
        "name": f"ara-kiosk ({release['tag_name']})",
        "description": (
            "Pi 5 + reSpeaker XVF3800 + Linux Voice Assistant + Chromium kiosk. "
            f"Tag: {release['tag_name']}, "
            f"published: {(release.get('published_at') or 'unknown')[:10]}."
        ),
        "url": img_asset["browser_download_url"],
        "release_date": (release.get("published_at") or "")[:10],
        "image_download_size": img_asset["size"],
        # Tells rpi-imager's customisation wizard which scheme to use:
        # cloud-init (custom.toml + user-data on the FAT32 partition).
        "init_format": "cloud-init",
        "devices": ["pi5-64bit"],
        # Fields the wizard should expose. ssh + wifi + hostname + locale
        # are the common ones supported by the cloud-init scheme.
        "capabilities": ["ssh", "wifi", "hostname", "locale"],
    }
    # rpi-imager will skip integrity checks if no sha256 is provided —
    # add the sha256 file URL as a hint when available.
    if sha_asset:
        item["image_download_sha256_url"] = sha_asset["browser_download_url"]
    return item


def main():
    releases = fetch_releases()

    # The catalog itself lives in a release tagged `rpi-imager-json`.
    # Skip it so we don't try to list the catalog as one of our images.
    releases = [r for r in releases if r.get("tag_name") != SELF_TAG]

    # Sort newest first so 'Latest' is unambiguous.
    releases.sort(key=lambda r: r.get("published_at") or "", reverse=True)

    subitems_all = []
    for release in releases:
        img, sha = find_image_asset(release)
        if img is not None:
            subitems_all.append((release, build_subitem(release, img, sha)))

    if not subitems_all:
        print(f"ERROR: no release with an .img.xz asset on {OWNER}/{REPO}", file=sys.stderr)
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
