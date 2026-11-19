#!/usr/bin/env python3
"""Find the published Seven Island DMG for a tag through the GitHub Releases API."""

import json
import os
import re
import sys
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


def find_release_dmg(api_url, repository, tag, token):
    request = Request(
        f"{api_url}/repos/{repository}/releases/tags/{quote(tag, safe='')}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            release = json.load(response)
    except HTTPError as error:
        if error.code == 404:
            return None
        raise

    assets = [
        asset for asset in release["assets"]
        if re.fullmatch(r"Seven-Island-[0-9A-Za-z._+-]+\.dmg", asset["name"])
    ]
    if not assets:
        return None

    expected_name = f"Seven-Island-{tag.removeprefix('v')}.dmg"
    asset = next((asset for asset in assets if asset["name"] == expected_name), None)
    if asset is None:
        if len(assets) != 1:
            raise ValueError(f"Release {tag} has multiple Seven Island DMGs")
        asset = assets[0]
    if asset["state"] != "uploaded" or asset["size"] <= 0:
        raise ValueError(f"Release asset {asset['name']} has an incomplete upload")
    return asset["name"]


def main():
    name = find_release_dmg(
        os.environ["GITHUB_API_URL"],
        os.environ["GITHUB_REPOSITORY"],
        os.environ["RELEASE_TAG"],
        os.environ["GH_TOKEN"],
    )
    if name:
        print(name)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(f"Unable to resolve release DMG: {error}")
