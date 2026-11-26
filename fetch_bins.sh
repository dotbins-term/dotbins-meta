#!/usr/bin/env bash
# Download the latest release binaries of every public repo in a GitHub org.
# Usage: fetch_dotbins.sh [org] [dest_dir]
# Requires: curl, python3. No token needed (public org); set GITHUB_TOKEN only if you hit the
# 60 requests/hour unauthenticated API limit.
set -euo pipefail

org="${1:-dotbins-term}"
dest="${2:-$HOME/.local/bin}"
state="${XDG_STATE_HOME:-$HOME/.local/state}/dotbins/$org"   # remembers installed tag per repo
api="https://api.github.com"
skip_repos=(dotbins-meta)

mkdir -p "$dest" "$state"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gh() {
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$@"
}

json() {
    python3 -c '
import sys, json
d = json.load(sys.stdin)
r = eval(sys.argv[1])
if isinstance(r, list):
    print("\n".join(str(x) for x in r))
else:
    print(r)
' "$1"
}

# list all repo names (paginated, 100 per page)
list_repos() {
    local page=1 names
    while :; do
        names=$(gh "$api/orgs/$org/repos?type=public&per_page=100&page=$page" \
            | json "'\n'.join(r['name'] for r in d)")
        [[ -n "$names" ]] || break
        echo "$names"
        ((page++))
    done
}

while read -r repo; do
    [[ -n "$repo" ]] || continue
    [[ " ${skip_repos[*]} " == *" $repo "* ]] && { echo "skip  $repo (excluded)"; continue; }
    rels=$(gh "$api/repos/$org/$repo/releases?per_page=20" 2>/dev/null) || {
        echo "skip  $repo (api error)" >&2; continue
    }
    idx=$(json "next((i for i, r in enumerate(d) if r['assets'] and not r['draft']), -1)" <<< "$rels")
    if [[ "$idx" == -1 ]]; then
        echo "skip  $repo (no release with assets)" >&2; continue
    fi
    tag=$(json "d[$idx]['tag_name']" <<< "$rels")

    if [[ -f "$state/$repo" && "$(<"$state/$repo")" == "$tag" ]]; then
        echo "ok    $repo ($tag)"
        continue
    fi

    n=0 failed=0

        while IFS=$'\t' read -r name url; do
        [[ -n "$name" ]] || continue
        if ! gh -o "$tmp/$name" "$url"; then
            echo "fail  $repo $tag: download failed for $name" >&2
            failed=1; continue
        fi

        [[ -s "$tmp/$name" ]] || { echo "fail  $repo $tag: $name is empty" >&2; failed=1; continue; }
        if head -c 15 "$tmp/$name" | grep -qi '<!doctype\|<html'; then
            echo "fail  $repo $tag: $name is HTML, not a binary" >&2
            failed=1; continue
        fi
        install -m 755 "$tmp/$name" "$dest/$name"
        echo "new   $repo $tag -> $dest/$name"
        ((n++)) || true
    done < <(json "'\n'.join(a['name'] + '\t' + a['browser_download_url'] for a in d[$idx]['assets'])" <<< "$rels")


    if ((n > 0 && failed == 0)); then
        echo "$tag" > "$state/$repo"
    fi

done < <(list_repos)
