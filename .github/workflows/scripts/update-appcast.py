#!/usr/bin/env python3
"""Update the Appcast entry for the published DMG of a GitHub release tag.

Usage: update-appcast.py <appcast_path> <dmg_path> <version> <build_num> <tag_name> <repo>
SPARKLE_PRIVATE_KEY contains the base64-encoded Ed25519 seed.
"""

import base64
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime, parsedate_to_datetime
from pathlib import Path
from urllib.parse import quote, unquote

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sparkle(tag):
    return f"{{{NS}}}{tag}"


def is_release_item(item, release_url, download_directory):
    for field in ("link", sparkle("fullReleaseNotesLink")):
        if unquote(item.findtext(field, "").strip()) == unquote(release_url):
            return True
    enclosure = item.find("enclosure")
    if enclosure is None:
        return False
    directory = enclosure.get("url", "").rsplit("/", 1)[0]
    return unquote(directory) == unquote(download_directory)


def publication_date(item):
    try:
        value = parsedate_to_datetime(item.findtext("pubDate", ""))
    except (TypeError, ValueError):
        return datetime.max.replace(tzinfo=timezone.utc)
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def update_item(item, fields, enclosure_attributes):
    changed = False
    for tag, value in fields.items():
        field = item.find(tag)
        if field is None:
            field = ET.SubElement(item, tag)
        if field.text != value:
            field.text = value
            changed = True

    enclosure = item.find("enclosure")
    if enclosure is None:
        enclosure = ET.SubElement(item, "enclosure")
    for key, value in enclosure_attributes.items():
        if enclosure.get(key) != value:
            enclosure.set(key, value)
            changed = True
    return changed


def update_appcast(appcast_path, dmg_path, version, build_num, tag_name, repo, private_key_b64):
    ET.register_namespace("sparkle", NS)
    tree = ET.parse(appcast_path)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("no <channel> found in Appcast")

    dmg = Path(dmg_path).read_bytes()
    key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(private_key_b64))
    signature = base64.b64encode(key.sign(dmg)).decode("ascii")
    repository_url = f"https://github.com/{repo}/releases"
    tag_path = quote(tag_name, safe="")
    release_url = f"{repository_url}/tag/{tag_path}"
    download_directory = f"{repository_url}/download/{tag_path}"
    download_url = f"{download_directory}/{quote(f'Seven-Island-{version}.dmg')}"

    items = channel.findall("item")
    matching = [item for item in items if is_release_item(item, release_url, download_directory)]
    changed = False
    if matching:
        item = min(matching, key=publication_date)
        if len(matching) > 1:
            index = list(channel).index(matching[0])
            for duplicate in matching:
                channel.remove(duplicate)
            channel.insert(index, item)
            changed = True
    else:
        item = ET.Element("item")
        index = list(channel).index(items[0]) if items else len(channel)
        channel.insert(index, item)
        changed = True

    fields = {
        "title": version,
        "pubDate": item.findtext("pubDate") or format_datetime(datetime.now(timezone.utc)),
        "link": release_url,
        sparkle("version"): build_num,
        sparkle("shortVersionString"): version,
        sparkle("minimumSystemVersion"): "14.0",
        sparkle("fullReleaseNotesLink"): release_url,
        "description": f"Release {version}. See the GitHub release for details.",
    }
    enclosure = {
        "url": download_url,
        "length": str(len(dmg)),
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    }
    if update_item(item, fields, enclosure) or changed:
        tree.write(appcast_path, xml_declaration=True, encoding="UTF-8")
        print(f"Updated {appcast_path} for {tag_name}.", file=sys.stderr)
    return signature


def main():
    if len(sys.argv) != 7:
        sys.exit("Usage: update-appcast.py <appcast_path> <dmg_path> <version> <build_num> <tag_name> <repo>")
    key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not key:
        sys.exit("SPARKLE_PRIVATE_KEY is required to sign the published DMG.")
    print(update_appcast(*sys.argv[1:], key))


if __name__ == "__main__":
    main()
