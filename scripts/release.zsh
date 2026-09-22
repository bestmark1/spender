#!/bin/zsh

# Builds a Developer ID signed, notarized and stapled Spender DMG.
#
# Needs, once per Mac:
#   - a "Developer ID Application" certificate for team NZRRXJA2HB, created in
#     Xcode → Settings → Accounts → Manage Certificates;
#   - notarization credentials stored under a keychain profile:
#       xcrun notarytool store-credentials spender-notary --apple-id … --team-id NZRRXJA2HB
#
# It touches nothing outside .build/release: it does not install the app,
# publish a release or push. The result is .build/release/Spender-<version>.dmg.

set -euo pipefail

repo_root="${0:A:h:h}"
team_id="${TEAM_ID:-NZRRXJA2HB}"
notary_profile="${NOTARY_PROFILE:-spender-notary}"
work="${repo_root}/.build/release"
archive="${work}/Spender.xcarchive"
export_dir="${work}/export"
app="${export_dir}/Spender.app"
signing_identity="Developer ID Application"

step() { print -P "%B==> $1%b"; }
fail() { print -u2 "release.zsh: $1"; exit 1; }

version="$(/usr/bin/xcodebuild -project "${repo_root}/LLMSpendMonitor.xcodeproj" \
    -scheme LLMSpendMonitor -configuration Release -showBuildSettings 2>/dev/null \
    | /usr/bin/awk -F' = ' '/ MARKETING_VERSION = / { print $2; exit }')"
[[ -n "${version}" ]] || fail "could not read MARKETING_VERSION"
dmg="${work}/Spender-${version}.dmg"

if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -q "${signing_identity}: .*(${team_id})"; then
    fail "no '${signing_identity}' certificate for team ${team_id} in the keychain"
fi

if [[ -n "$(/usr/bin/git -C "${repo_root}" status --porcelain)" ]]; then
    print -u2 "warning: the working tree has uncommitted changes; they will be in this build."
fi

step "Spender ${version}: archiving the Release build"
/bin/rm -rf "${work}"
/bin/mkdir -p "${work}"
/usr/bin/xcodebuild \
    -project "${repo_root}/LLMSpendMonitor.xcodeproj" \
    -scheme LLMSpendMonitor \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive}" \
    -allowProvisioningUpdates \
    archive | /usr/bin/grep -E "error:|warning: .*sign|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "${archive}" ]] || fail "archive was not produced"

step "Exporting with Developer ID"
# Automatic signing lets Xcode create the Developer ID provisioning profile
# the keychain-access-groups entitlement needs, from the account signed in
# to Xcode. Without that profile the exported app would not launch.
/bin/cat > "${work}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${team_id}</string>
</dict>
</plist>
EOF
/usr/bin/xcodebuild \
    -exportArchive \
    -archivePath "${archive}" \
    -exportPath "${export_dir}" \
    -exportOptionsPlist "${work}/ExportOptions.plist" \
    -allowProvisioningUpdates | /usr/bin/grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
[[ -d "${app}" ]] || fail "export did not produce Spender.app"

step "Checking the app's signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${app}"
signature="$(/usr/bin/codesign -dvv "${app}" 2>&1)"
print -r -- "${signature}" | /usr/bin/grep -q "Authority=${signing_identity}: .*(${team_id})" \
    || fail "the app is not signed with ${signing_identity} (${team_id})"
print -r -- "${signature}" | /usr/bin/grep -q "flags=.*runtime" \
    || fail "the hardened runtime is off; notarization would reject the app"
entitlements="$(/usr/bin/codesign -d --entitlements - --xml "${app}" 2>/dev/null)"
print -r -- "${entitlements}" | /usr/bin/grep -q "${team_id}.com.bestmark.LLMSpendMonitor" \
    || fail "keychain-access-groups did not survive signing; saved keys would be unreadable"
print "Signed by ${signing_identity} (${team_id}), hardened runtime on, keychain group intact."

notarize() {
    local target="$1"
    step "Notarizing ${target:t} (this usually takes a few minutes)"
    local output
    if ! output="$(/usr/bin/xcrun notarytool submit "${target}" \
        --keychain-profile "${notary_profile}" --wait 2>&1)"; then
        print -r -- "${output}"
        fail "notarytool submit failed for ${target:t}"
    fi
    print -r -- "${output}" | /usr/bin/grep -E "id:|status:" | /usr/bin/head -4
    if ! print -r -- "${output}" | /usr/bin/grep -q "status: Accepted"; then
        local submission
        submission="$(print -r -- "${output}" | /usr/bin/awk '/ id: / { print $2; exit }')"
        [[ -n "${submission}" ]] && /usr/bin/xcrun notarytool log "${submission}" \
            --keychain-profile "${notary_profile}" || true
        fail "Apple did not accept ${target:t}"
    fi
    # A ZIP cannot carry a ticket; the app inside it is stapled instead.
    [[ "${target:e}" == "zip" ]] || /usr/bin/xcrun stapler staple "${target}"
}

# The app is notarized and stapled first, so a copy dragged out of the DMG
# carries its own ticket and opens even offline. Then the DMG itself.
/usr/bin/ditto -c -k --keepParent "${app}" "${work}/Spender.zip"
notarize "${work}/Spender.zip"
/usr/bin/xcrun stapler staple "${app}"
/bin/rm -f "${work}/Spender.zip"

step "Building ${dmg:t}"
staging="${work}/dmg"
/bin/mkdir -p "${staging}"
/usr/bin/ditto "${app}" "${staging}/Spender.app"
/bin/ln -s /Applications "${staging}/Applications"
/usr/bin/hdiutil create -volname "Spender" -srcfolder "${staging}" \
    -fs HFS+ -format UDZO -ov "${dmg}" >/dev/null
/bin/rm -rf "${staging}"
/usr/bin/codesign --sign "${signing_identity}: NIKOLAI SADOVNIKOV (${team_id})" \
    --timestamp "${dmg}"

notarize "${dmg}"

step "Gatekeeper check"
/usr/sbin/spctl --assess --type execute --verbose=2 "${app}"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "${dmg}"
/usr/bin/xcrun stapler validate "${dmg}"

print
print "Ready: ${dmg}"
print "SHA-256: $(/usr/bin/shasum -a 256 "${dmg}" | /usr/bin/awk '{ print $1 }')"
