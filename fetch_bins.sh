#!/usr/bin/env bash
# Install the newest release assets of every public repo in a GitHub org.
# Usage: fetch_bins.sh [org] [dest_dir]
# Requires: curl, python3, tar (+ zstd for .pkg.tar.zst). Set GITHUB_TOKEN to avoid the 60 req/h limit.
set -euo pipefail

org="${1:-dotbins-term}"
dest="${2:-$HOME/.local/bin}"
opt="${XDG_DATA_HOME:-$HOME/.local/share}/dotbins"            # unpacked archives
fonts="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/dotbins"
state="${XDG_STATE_HOME:-$HOME/.local/state}/dotbins/$org"    # installed tag per repo
api="https://api.github.com"
skip_repos=(dotbins-meta)
fonts_changed=0

mkdir -p "$dest" "$opt" "$state"
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
print("\n".join(str(x) for x in r) if isinstance(r, list) else r)
' "$1"
}

list_repos() {
    local page=1 body names
    while :; do
        body=$(gh "$api/orgs/$org/repos?type=public&per_page=100&page=$page") || {
            echo "error listing repos for $org (rate limited? set GITHUB_TOKEN)" >&2
            return 1
        }
        names=$(json "'\n'.join(r['name'] for r in d)" <<< "$body")
        [[ -n "$names" ]] || break
        echo "$names"
        ((page++))
    done
}

# install one downloaded asset: plain binary, archive (link its executables), or font archive
install_asset() {
    local repo="$1" f="$2" name out bins b
    name=$(basename "$f")
    case "$name" in
    *.tar.*|*.txz|*.tgz|*.zip)
        if [[ "$repo" == nerd-fonts ]]; then
            out="$fonts/${name%%.*}"
            fonts_changed=1
        else
            out="$opt/$repo"
        fi
        mkdir -p "$out"
        if [[ "$name" == *.zip ]]; then
            python3 -m zipfile -e "$f" "$out"
        else
            tar -xf "$f" -C "$out"
        fi
        if [[ "$repo" == nerd-fonts ]]; then
            echo "new   $repo -> $out"
            return
        fi
        # link executables: everything under a bin/ dir if present, else shallow executables
        bins=$(find "$out" -path "$out/*bin/*" -type f -executable 2>/dev/null)
        [[ -n "$bins" ]] || bins=$(find "$out" -maxdepth 2 -type f -executable ! -name '*.so*')
        while read -r b; do
            [[ -n "$b" ]] || continue
            ln -sfn "$b" "$dest/$(basename "$b")"
            echo "new   $repo -> $dest/$(basename "$b")"
        done <<< "$bins"
        ;;
    *)
        [[ "$name" == *.AppImage && "$repo" == ImageMagick ]] && name=magick
        install -m 755 "$f" "$dest/$name"
        echo "new   $repo -> $dest/$name"
        ;;
    esac
}

while read -r repo; do
    [[ -n "$repo" ]] || continue
    [[ " ${skip_repos[*]} " == *" $repo "* ]] && { echo "skip  $repo (excluded)"; continue; }

    rels=$(gh "$api/repos/$org/$repo/releases?per_page=20" 2>/dev/null) || {
        echo "skip  $repo (api error)" >&2; continue
    }
    # newest non-draft release that has at least one asset
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
    rm -rf "${opt:?}/$repo"
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" ]] || continue
        if ! gh -o "$tmp/$name" "$url"; then
            echo "fail  $repo $tag: download failed for $name" >&2
            failed=1; continue
        fi
        if [[ ! -s "$tmp/$name" ]] || head -c 15 "$tmp/$name" | grep -qi '<!doctype\|<html'; then
            echo "fail  $repo $tag: $name is empty or HTML" >&2
            failed=1; continue
        fi
        install_asset "$repo" "$tmp/$name"
        ((n++)) || true
    done < <(json "'\n'.join(a['name'] + '\t' + a['browser_download_url'] for a in d[$idx]['assets'])" <<< "$rels")

    # only remember the tag if everything installed, so a partial failure retries next run
    if ((n > 0 && failed == 0)); then
        echo "$tag" > "$state/$repo"
    fi
done < <(list_repos)

if ((fonts_changed)) && command -v fc-cache >/dev/null; then
    fc-cache -f "$fonts"
fi

fontdir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/nerd-fonts"
for f in JetBrainsMono FiraCode Hack NerdFontsSymbolsOnly; do
    mkdir -p "$fontdir/$f"
    curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$f.tar.xz" \
        | tar -xJ -C "$fontdir/$f"
done
fc-cache -f "$fontdir"
