#!/usr/bin/env python3
"""
Update updater/appcast.xml with a new version entry.

Usage:
  update-appcast.py <appcast_path> <dmg_path> <version> <build_num> <tag_name> <repo>

Environment:
  SPARKLE_PRIVATE_KEY - base64-encoded Ed25519 private key seed (32 bytes)

Output:
  Updates appcast.xml in place. Prints the EdDSA signature to stdout.
"""

import base64
import os
import re
import sys
from datetime import datetime, timezone

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError:
    sys.exit("cryptography library is required. Run: pip install cryptography")


NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sparkle(tag):
    return f"{{{NS}}}{tag}"


def sign_dmg(dmg_path: str, private_key_b64: str) -> str:
    """Sign a DMG file with the Sparkle Ed25519 private key."""
    key_bytes = base64.b64decode(private_key_b64)
    priv = Ed25519PrivateKey.from_private_bytes(key_bytes)
    with open(dmg_path, "rb") as f:
        data = f.read()
    signature = priv.sign(data)
    return base64.b64encode(signature).decode()


def update_appcast(
    appcast_path: str,
    dmg_path: str,
    version: str,
    build_num: str,
    tag_name: str,
    repo: str,
    private_key_b64: str,
):
    import xml.etree.ElementTree as ET

    ET.register_namespace("sparkle", NS)

    # Sign the DMG
    print(f"Signing {dmg_path}...", file=sys.stderr)
    signature = sign_dmg(dmg_path, private_key_b64)

    # Get file size
    dmg_size = os.path.getsize(dmg_path)

    # Generate pubDate
    pub_date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")

    # Download URL
    download_url = (
        f"https://github.com/{repo}/releases/download/{tag_name}/"
        f"Seven-Island-{version}.dmg"
    )

    # Parse existing appcast
    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        print("Error: no <channel> found in appcast", file=sys.stderr)
        sys.exit(1)

    # Build new <item>
    item = ET.Element("item")

    title = ET.SubElement(item, "title")
    title.text = version

    pub = ET.SubElement(item, "pubDate")
    pub.text = pub_date

    link = ET.SubElement(item, "link")
    link.text = f"https://github.com/{repo}/releases/tag/{tag_name}"

    sp_version = ET.SubElement(item, sparkle("version"))
    sp_version.text = build_num

    sp_short = ET.SubElement(item, sparkle("shortVersionString"))
    sp_short.text = version

    sp_min_os = ET.SubElement(item, sparkle("minimumSystemVersion"))
    sp_min_os.text = "14.0"

    # Use fullReleaseNotesLink so Sparkle opens the GitHub release page
    rel_notes = ET.SubElement(item, sparkle("fullReleaseNotesLink"))
    rel_notes.text = f"https://github.com/{repo}/releases/tag/{tag_name}"

    # Brief description (no CDATA needed for plain text)
    desc = ET.SubElement(item, "description")
    desc.text = f"Release {version}. See the GitHub release for details."

    # Enclosure
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", download_url)
    enclosure.set("length", str(dmg_size))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(sparkle("edSignature"), signature)

    # Insert at the top (newest first)
    first_item = channel.find("item")
    if first_item is not None:
        channel.insert(list(channel).index(first_item), item)
    else:
        channel.append(item)

    # Write to file
    tree.write(appcast_path, xml_declaration=True, encoding="UTF-8")
    print(f"Updated {appcast_path}", file=sys.stderr)
    print(signature)


def main():
    if len(sys.argv) != 7:
        print(
            "Usage: update-appcast.py <appcast_path> <dmg_path> "
            "<version> <build_num> <tag_name> <repo>",
            file=sys.stderr,
        )
        sys.exit(1)

    appcast_path = sys.argv[1]
    dmg_path = sys.argv[2]
    version = sys.argv[3]
    build_num = sys.argv[4]
    tag_name = sys.argv[5]
    repo = sys.argv[6]

    private_key_b64 = os.environ.get("SPARKLE_PRIVATE_KEY", "")
    if not private_key_b64:
        print("Error: SPARKLE_PRIVATE_KEY environment variable is not set",
              file=sys.stderr)
        sys.exit(1)

    update_appcast(
        appcast_path, dmg_path, version, build_num,
        tag_name, repo, private_key_b64,
    )


if __name__ == "__main__":
    main()
