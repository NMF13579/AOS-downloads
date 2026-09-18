#!/bin/sh
# Download this reviewed entry from the fixed AOS-3 source; do not pipe arbitrary scripts.
set -eu
fail() { printf '%s\n' "AOS: $*" >&2; exit 3; }
[ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = arm64 ] || fail 'macOS arm64 required'
operation=${1:-install}
target=${2:-.}
channel=${3:-stable}
case "$operation" in install|update) ;; *) fail 'bootstrap supports install or update';; esac
mode=${4:-apple}
repository=NMF13579/AOS-3
binding=source_commit
case "$mode" in
    apple) ;;
    public-test)
        [ "$channel" = test ] || fail 'public delivery currently supports test only'
        repository=NMF13579/AOS-downloads
        binding=release_commit
        unset AOS_GITHUB_TOKEN
        printf '%s\n' 'AOS PUBLIC TEST: GitHub HTTPS + SHA-256; no Apple notarization.' >&2;;
    *) fail 'unknown distribution mode';;
esac
case "$channel" in stable) branch=main;; test) branch=dev;; *) fail 'unknown channel';; esac
[ -d "$target" ] && [ ! -L "$target" ] || fail 'existing non-symlink project required'
target=$(CDPATH= cd -- "$target" && /bin/pwd -P)
# An interrupted operation keeps its bound package, even when upstream has moved.
if [ -f "$target/.aos-install/pending.json" ] && [ -x "$target/.aos-install/aos" ]; then
    exec "$target/.aos-install/aos" resume --apply
fi
scratch=$(/usr/bin/mktemp -d -t aos-bootstrap)
scratch=$(CDPATH= cd -- "$scratch" && /bin/pwd -P)
volume="$scratch/mounted"
cleanup() {
    if [ -d "$volume/aos" ]; then /usr/bin/hdiutil detach "$volume" >/dev/null 2>&1 || :; fi
    # Keep failed download/mount evidence; no cleanup of prior user material.
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
curl_api() {
    curl_url=$1
    curl_hops=0
    curl_auth=1
    while :; do
        case "$curl_url" in *[[:space:]]*|*\\*|*'#'*) fail 'invalid download URL';; esac
        case "$curl_url" in
            https://raw.githubusercontent.com/NMF13579/AOS-downloads/main/channels/test.json)
                [ "$mode" = public-test ] && [ "$curl_hops" -eq 0 ] || fail 'download origin refused'
                curl_auth=0;;
            https://api.github.com/repos/"$repository"/*)
                if [ "$curl_hops" -gt 0 ]; then
                    case "$curl_url" in "$api/releases/assets/"*) ;; *) fail 'download origin refused';; esac
                    curl_redirect_id=${curl_url#"$api/releases/assets/"}
                    curl_redirect_id=${curl_redirect_id%%\?*}
                    case "$curl_redirect_id" in *[!0-9]*|'') fail 'download origin refused';; esac
                fi;;
            https://github.com/"$repository"/releases/download/*)
                [ "${curl_url%%\?*}" = "https://github.com/$repository/releases/download/aos-$sha/aos-macos-arm64.dmg" ] || fail 'download origin refused'
                curl_auth=0;;
            https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*)
                curl_auth=0;;
            *) fail 'download origin refused';;
        esac
        # No implicit redirects or curlrc: check every hop before contacting it.
        # Credentials are never reintroduced after leaving the initial API host.
        if [ "$curl_auth" -eq 1 ] && [ -n "${AOS_GITHUB_TOKEN:-}" ]; then
            case "$AOS_GITHUB_TOKEN" in *[!A-Za-z0-9_]*) fail 'invalid explicit credential';; esac
            curl_reply=$(printf 'header = "Authorization: Bearer %s"\n' "$AOS_GITHUB_TOKEN" |
                /usr/bin/curl -q --config - --fail --silent --show-error \
                --proto '=https' --max-time 60 --max-filesize "$4" \
                -H "Accept: $3" -H 'X-GitHub-Api-Version: 2022-11-28' \
                -w '%{http_code} %{redirect_url}' "$curl_url" -o "$2") || return 1
        else
            curl_reply=$(/usr/bin/curl -q --fail --silent --show-error --proto '=https' \
                --max-time 60 --max-filesize "$4" -H "Accept: $3" \
                -H 'X-GitHub-Api-Version: 2022-11-28' -w '%{http_code} %{redirect_url}' \
                "$curl_url" -o "$2") || return 1
        fi
        curl_bytes=$(/usr/bin/stat -f %z "$2") || return 1
        [ "$curl_bytes" -le "$4" ] || fail 'download too large'
        case "${curl_reply%% *}" in
            200) return 0;;
            301|302|303|307|308)
                [ "$3" = application/octet-stream ] || fail 'metadata redirect refused'
                curl_hops=$((curl_hops + 1))
                [ "$curl_hops" -le 5 ] || fail 'too many download redirects'
                curl_url=${curl_reply#* };;
            *) fail 'download HTTP response refused';;
        esac
    done
}
api=https://api.github.com/repos/$repository
# A channel contains published releases; unbuilt branch commits are irrelevant.
page=1
best=''
while [ "$page" -le 10 ]; do
    if [ "$mode" = public-test ]; then
        curl_api "https://raw.githubusercontent.com/$repository/main/channels/test.json" "$scratch/channel.json" application/vnd.github+json 2097152 || fail 'cannot read published public test channel'
        { printf '['; /bin/cat "$scratch/channel.json"; printf ']'; } > "$scratch/releases.json"
    else
    curl_api "$api/releases?per_page=100&page=$page" "$scratch/releases.json" application/vnd.github+json 2097152 || fail 'cannot read published channel; check network and repository access'
    fi
    { printf '{"releases":'; /bin/cat "$scratch/releases.json"; printf '}'; } > "$scratch/page.json"
    count=$(/usr/bin/plutil -extract releases raw -expect array -o - "$scratch/page.json") || fail 'release list invalid'
    [ "$count" -le 100 ] || fail 'release list too large'
    n=0
    while [ "$n" -lt "$count" ]; do
        /usr/bin/plutil -extract "releases.$n" json -expect dictionary -o "$scratch/item.json" "$scratch/page.json" || fail 'release list invalid'
        n=$((n + 1))
        tag=$(/usr/bin/plutil -extract tag_name raw -expect string -o - "$scratch/item.json") || fail 'release tag invalid'
        case "$tag" in aos-*) sha=${tag#aos-};; *) continue;; esac
        case "$sha" in *[!0-9a-f]*|'') continue;; esac
        [ "${#sha}" -eq 40 ] || continue
        draft=$(/usr/bin/plutil -extract draft raw -expect bool -o - "$scratch/item.json") || fail 'release draft flag invalid'
        [ "$draft" = false ] || continue
        prerelease=$(/usr/bin/plutil -extract prerelease raw -expect bool -o - "$scratch/item.json") || fail 'release channel invalid'
        case "$channel:$prerelease" in stable:false|test:true) ;; *) continue;; esac
        published=$(/usr/bin/plutil -extract published_at raw -expect string -o - "$scratch/item.json") || fail 'release date invalid'
        printf '%s\n' "$published" | /usr/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || fail 'release date invalid'
        release_id=$(/usr/bin/plutil -extract id raw -expect integer -o - "$scratch/item.json") || fail 'release identity invalid'
        case "$release_id" in *[!0-9]*|'') fail 'release identity invalid';; esac
        [ "${#release_id}" -le 18 ] && [ "$release_id" -gt 0 ] || fail 'release identity invalid'
        rank=$(printf '%s %018d' "$published" "$release_id")
        if [ -z "$best" ] || [ "$rank" \> "$best" ]; then
            best=$rank
            /bin/cp "$scratch/item.json" "$scratch/release.json"
        fi
    done
    [ "$count" -eq 100 ] || break
    page=$((page + 1))
done
[ "$page" -le 10 ] || fail 'release history limit: refusing partial-history selection'
[ -n "$best" ] || fail 'selected channel has no published AOS release'
sha=$(/usr/bin/plutil -extract tag_name raw -o - "$scratch/release.json")
sha=${sha#aos-}
i=0
found=0
while [ "$i" -lt 64 ]; do
    name=$(/usr/bin/plutil -extract "assets.$i.name" raw -o - "$scratch/release.json" 2>/dev/null) || break
    if [ "$name" = aos-macos-arm64.dmg ]; then
        [ "$found" -eq 0 ] || fail 'duplicate release asset'
        found=1
        digest=$(/usr/bin/plutil -extract "assets.$i.digest" raw -o - "$scratch/release.json")
        asset_id=$(/usr/bin/plutil -extract "assets.$i.id" raw -o - "$scratch/release.json")
        asset_url=$(/usr/bin/plutil -extract "assets.$i.browser_download_url" raw -o - "$scratch/release.json")
        asset_size=$(/usr/bin/plutil -extract "assets.$i.size" raw -o - "$scratch/release.json")
    fi
    i=$((i + 1))
done
if /usr/bin/plutil -extract assets.64 json -o /dev/null "$scratch/release.json" 2>/dev/null; then
    fail 'too many release assets'
fi
[ "$found" -eq 1 ] || fail 'macOS arm64 artifact not ready'
[ "$asset_url" = "https://github.com/$repository/releases/download/aos-$sha/aos-macos-arm64.dmg" ] || fail 'artifact publisher mismatch'
case "$digest" in sha256:*) digest=${digest#sha256:};; *) fail 'artifact digest unavailable';; esac
case "$digest" in *[!0-9a-f]*|'') fail 'invalid digest';; esac
[ "${#digest}" -eq 64 ] || fail 'invalid digest'
case "$asset_id" in *[!0-9]*|'') fail 'invalid asset identity';; esac
case "$asset_size" in *[!0-9]*|'') fail 'invalid asset size';; esac
[ "${#asset_size}" -le 10 ] && [ "$asset_size" -gt 0 ] && [ "$asset_size" -le 1073741824 ] || fail 'invalid asset size'
[ "${#asset_id}" -le 18 ] && [ "$asset_id" -gt 0 ] || fail 'invalid asset identity'
image="$scratch/aos-macos-arm64.dmg"
download_url="$api/releases/assets/$asset_id"
[ "$mode" != public-test ] || download_url="$asset_url"
curl_api "$download_url" "$image" application/octet-stream 1073741824 || fail 'package download failed'
[ "$(/usr/bin/stat -f %z "$image")" -eq "$asset_size" ] || fail 'package size mismatch'
actual=$(/usr/bin/shasum -a 256 "$image")
[ "${actual%% *}" = "$digest" ] || fail 'package checksum mismatch'
if [ "$mode" = apple ]; then
/usr/bin/codesign --verify --strict "$image" >/dev/null 2>&1 || fail 'image signature invalid'
/usr/bin/codesign --display --verbose=4 "$image" 2> "$scratch/signature.txt" || fail 'image signer unavailable'
/usr/bin/grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' "$scratch/signature.txt" || fail 'image requires an identified distribution signer'
/usr/sbin/spctl --assess --type open --context context:primary-signature "$image" >/dev/null 2>&1 ||
    fail 'Apple distribution signature/notarization not accepted; current project preserved'
fi
/bin/mkdir "$volume"
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$volume" "$image" >/dev/null || fail 'package mount failed'
# Check the source/profile before executing even the bundled interpreter.
for entry in bundle.json python python/bin python/bin/python3.12 aos aos/src aos/src/aos aos/src/aos/application aos/src/aos/application/project_installer.py; do
    [ -e "$volume/$entry" ] && [ ! -L "$volume/$entry" ] || fail 'bundle entry missing or linked'
done
[ -f "$volume/bundle.json" ] && [ "$(/usr/bin/stat -f %z "$volume/bundle.json")" -le 2097152 ] || fail 'bundle metadata invalid'
[ "$(/usr/bin/plutil -extract "$binding" raw -o - "$volume/bundle.json")" = "$sha" ] || fail 'bundle source commit mismatch'
[ "$(/usr/bin/plutil -extract schema raw -o - "$volume/bundle.json")" = AOS_STANDALONE_MACOS_ARM64_V1 ] || fail 'bundle profile unsupported'
[ "$(/usr/bin/plutil -extract data_schema raw -o - "$volume/bundle.json")" = AOS_PROJECT_MEMORY_V1 ] || fail 'bundle data schema unsupported'
[ "$(/usr/bin/plutil -extract python raw -o - "$volume/bundle.json")" = python/bin/python3.12 ] || fail 'bundle runtime invalid'
if [ "$mode" = public-test ]; then
    [ "$(/usr/bin/plutil -extract distribution raw -o - "$volume/bundle.json")" = PUBLIC_TEST_UNNOTARIZED ] || fail 'public test profile mismatch'
    set -- --public-test
else
    set --
fi
unset PYTHONHOME PYTHONPATH PYTHONSTARTUP
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
# The bundled manager independently rechecks this exact release and digest via HTTPS.
# Bootstrap images are not labelled official just because a local path was supplied.
"$volume/python/bin/python3.12" -I -B "$volume/aos/src/aos/application/project_installer.py" \
    "$operation" --target "$target" --channel "$channel" --resolved-commit "$sha" \
    --downloaded-image "$image" --apply "$@"
