#!/bin/zsh

# Builds a Spender release.
#
#   scripts/release.zsh            Developer ID: signed, notarized, stapled DMG,
#                                  signed for Sparkle and added to site/appcast.xml.
#   scripts/release.zsh appstore   Mac App Store: archive of the SpenderAppStore
#                                  target (no Sparkle), exported for App Store Connect.
#   scripts/release.zsh appstore --upload
#                                  The same, uploaded to App Store Connect.
#
# Needs, once per Mac:
#   - "Developer ID Application" (and, for the App Store, "Apple Distribution")
#     certificates for team NZRRXJA2HB; Xcode creates them from Settings → Accounts;
#   - notarization credentials stored under a keychain profile:
#       xcrun notarytool store-credentials spender-notary --apple-id … --team-id NZRRXJA2HB
#   - the Sparkle signing key in the login keychain (account com.bestmark1.Spender),
#     created once with Sparkle's generate_keys.
#
# Without --upload it touches nothing outside .build/release and site/appcast.xml:
# it does not install the app, publish a GitHub release, push, or deploy the site.

set -euo pipefail

mode="${1:-developer-id}"
upload="${2:-}"
repo_root="${0:A:h:h}"
team_id="${TEAM_ID:-NZRRXJA2HB}"
notary_profile="${NOTARY_PROFILE:-spender-notary}"
sparkle_account="${SPARKLE_ACCOUNT:-com.bestmark1.Spender}"
packages="${repo_root}/.build/SourcePackages"
work="${repo_root}/.build/release"
appcast="${repo_root}/site/appcast.xml"
signing_identity="Developer ID Application"

step() { print -P "%B==> $1%b"; }
fail() { print -u2 "release.zsh: $1"; exit 1; }

case "${mode}" in
    developer-id) scheme="LLMSpendMonitor"; work="${work}" ;;
    appstore) scheme="SpenderAppStore"; work="${work}/appstore" ;;
    *) fail "unknown mode '${mode}' (use no argument, or 'appstore')" ;;
esac
[[ -z "${upload}" || ( "${mode}" == "appstore" && "${upload}" == "--upload" ) ]] \
    || fail "--upload applies only to 'appstore'"

archive="${work}/Spender.xcarchive"
export_dir="${work}/export"

build_setting() {
    /usr/bin/xcodebuild -project "${repo_root}/LLMSpendMonitor.xcodeproj" \
        -scheme "${scheme}" -configuration Release -showBuildSettings 2>/dev/null \
        | /usr/bin/awk -F' = ' -v key="$1" '{ sub(/^ +/, "", $1) } $1 == key { print $2; exit }'
}
version="$(build_setting MARKETING_VERSION)"
build="$(build_setting CURRENT_PROJECT_VERSION)"
[[ -n "${version}" && -n "${build}" ]] || fail "could not read the version from the project"

if [[ -n "$(/usr/bin/git -C "${repo_root}" status --porcelain -- LLMSpendMonitor LLMSpendMonitor.xcodeproj)" ]]; then
    print -u2 "warning: the app has uncommitted changes; they will be in this build."
fi

if [[ "${mode}" == "developer-id" ]]; then
    /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/grep -q "${signing_identity}: .*(${team_id})" \
        || fail "no '${signing_identity}' certificate for team ${team_id} in the keychain"
    # Sparkle offers an update only when its build number is higher than the
    # installed one, so a release that does not raise it reaches nobody.
    latest="$(/usr/bin/grep -o '<sparkle:version>[0-9]*</sparkle:version>' "${appcast}" \
        | /usr/bin/grep -o '[0-9]*' | /usr/bin/sort -n | /usr/bin/tail -1 || true)"
    if [[ -n "${latest}" && "${build}" -le "${latest}" ]]; then
        fail "build ${build} is not above ${latest}, the newest in appcast.xml; raise CURRENT_PROJECT_VERSION"
    fi
fi

step "Spender ${version} (${build}), ${mode}: archiving"
/bin/rm -rf "${work}"
/bin/mkdir -p "${work}"
/usr/bin/xcodebuild \
    -project "${repo_root}/LLMSpendMonitor.xcodeproj" \
    -scheme "${scheme}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive}" \
    -clonedSourcePackagesDirPath "${packages}" \
    -allowProvisioningUpdates \
    archive | /usr/bin/grep -E "error:|warning: .*sign|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "${archive}" ]] || fail "archive was not produced"

if [[ "${mode}" == "appstore" ]]; then
    step "Exporting for the App Store"
    destination="export"
    [[ "${upload}" == "--upload" ]] && destination="upload"
    /bin/cat > "${work}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>${destination}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${team_id}</string>
</dict>
</plist>
EOF
    /usr/bin/xcodebuild -exportArchive -archivePath "${archive}" -exportPath "${export_dir}" \
        -exportOptionsPlist "${work}/ExportOptions.plist" -allowProvisioningUpdates \
        | /usr/bin/grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)" || true
    [[ -d "${archive}/Products/Applications/Spender.app/Contents/Frameworks/Sparkle.framework" ]] \
        && fail "the App Store build contains Sparkle; App Review would reject it"
    if [[ "${upload}" == "--upload" ]]; then
        print "Uploaded Spender ${version} (${build}) to App Store Connect."
    else
        print "Ready: $(/bin/ls "${export_dir}"/*.pkg 2>/dev/null || print "${export_dir}")"
    fi
    exit 0
fi

app="${export_dir}/Spender.app"
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
print -r -- "${entitlements}" | /usr/bin/grep -q -- "-spki" \
    || fail "Sparkle's installer exception is missing; updates could not install"
[[ -d "${app}/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is not embedded"
print "Signed by ${signing_identity} (${team_id}), hardened runtime on, keychain group and Sparkle intact."

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

dmg="${work}/Spender.dmg"
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

step "Signing for Sparkle and updating appcast.xml"
sign_update="${packages}/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "${sign_update}" ]] || fail "Sparkle's sign_update was not found at ${sign_update}"
# Prints: sparkle:edSignature="…" length="…"
sparkle_attributes="$("${sign_update}" --account "${sparkle_account}" "${dmg}")"
[[ "${sparkle_attributes}" == *'sparkle:edSignature="'* ]] \
    || fail "sign_update did not return a signature (is the Sparkle key in this keychain?)"
download_url="https://github.com/bestmark1/spender/releases/download/v${version}/Spender.dmg"
/usr/bin/python3 - "${appcast}" "${version}" "${build}" "${download_url}" "${sparkle_attributes}" <<'PY'
import sys
from email.utils import formatdate
path, version, build, url, attributes = sys.argv[1:]
feed = open(path, encoding="utf-8").read()
if f"<sparkle:version>{build}</sparkle:version>" in feed:
    sys.exit(f"appcast.xml already lists build {build}")
item = f"""    <item>
      <title>Spender {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/bestmark1/spender/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="{url}" type="application/octet-stream" {attributes} />
    </item>
"""
marker = "    <!-- scripts/release.zsh adds each release here, newest first. -->\n"
if marker not in feed:
    sys.exit("appcast.xml lost its insertion marker")
open(path, "w", encoding="utf-8").write(feed.replace(marker, marker + item, 1))
PY
/usr/bin/xmllint --noout "${appcast}" || fail "appcast.xml is no longer valid XML"

print
print "Ready: ${dmg}"
print "SHA-256: $(/usr/bin/shasum -a 256 "${dmg}" | /usr/bin/awk '{ print $1 }')"
print "Next: publish GitHub release v${version} with this Spender.dmg, then commit and"
print "push site/appcast.xml. The appcast points at the release, so release first."
