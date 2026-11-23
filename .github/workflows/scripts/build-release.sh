#!/usr/bin/env bash
set -euo pipefail

signing_args=(CODE_SIGN_IDENTITY=-)
team_id=""
if [[ -n "${DEVELOPER_ID_CERTIFICATE_BASE64:-}" ]]; then
    signing_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/seven-island-signing.XXXXXXXX")
    keychain="$signing_dir/release.keychain-db"
    saved_keychains=()
    while IFS= read -r entry; do
        if [[ "$entry" =~ \"([^\"]+)\" ]]; then saved_keychains+=("${BASH_REMATCH[1]}"); fi
    done < <(security list-keychains -d user)

    cleanup() {
        security list-keychains -d user -s "${saved_keychains[@]}" || true
        security delete-keychain "$keychain" >/dev/null 2>&1 || true
        rm -rf -- "$signing_dir"
    }
    trap cleanup EXIT

    keychain_password=$(openssl rand -hex 32)
    certificate="$signing_dir/developer-id.p12"
    printf '%s' "$DEVELOPER_ID_CERTIFICATE_BASE64" | base64 -D > "$certificate"
    security create-keychain -p "$keychain_password" "$keychain"
    security set-keychain-settings -lut 3600 "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    security import "$certificate" -k "$keychain" -P "${DEVELOPER_ID_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign
    rm -f -- "$certificate"
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
    security list-keychains -d user -s "$keychain" "${saved_keychains[@]}"

    identities=$(security find-identity -v -p codesigning "$keychain")
    identity=$(printf '%s\n' "$identities" | awk '/"Developer ID Application:/{print $2}')
    team_id=$(printf '%s\n' "$identities" | sed -nE 's/.*"Developer ID Application:.*\(([A-Z0-9]{10})\)"$/\1/p')
    if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ || ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "The release certificate must contain one valid Developer ID Application identity." >&2
        exit 1
    fi
    signing_args=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team_id")
elif [[ -n "${DEVELOPER_ID_CERTIFICATE_PASSWORD:-}" ]]; then
    echo "Set DEVELOPER_ID_CERTIFICATE_BASE64 alongside the certificate password." >&2
    exit 1
fi
unset DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD

xcodebuild -version
xcodebuild \
    -project boringNotch.xcodeproj \
    -scheme boringNotch \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    "${signing_args[@]}" \
    build

if [[ -n "$team_id" ]]; then
    app="build/DerivedData/Build/Products/Release/Seven Island.app"
    requirement="anchor apple generic and identifier \"com.local.seven-island\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team_id\""
    codesign --verify --deep --strict "$app"
    codesign --verify -R "=$requirement" "$app"
fi
