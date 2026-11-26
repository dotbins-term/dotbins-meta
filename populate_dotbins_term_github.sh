#!/usr/bin/env bash
# Requires: git, curl, jq, base64, pass (entry: business/social_networks/github_dotbins_term_token)
#   + toolchains for auto-builds: go, cargo, make/autotools, makepkg (Arch)
# Token: fine-grained PAT, Resource owner = dotbins-term, All repositories,
#   Repository permissions: Administration (RW), Contents (RW), Metadata (R)
# NOTE: intentionally no top-level `set -e` — this file is meant to be sourced.

UPSTREAM_URLS=(
    "https://github.com/BurntSushi/ripgrep"
    "https://github.com/ArtifexSoftware/ghostpdl"
    "https://gitlab.archlinux.org/archlinux/packaging/packages/unzip"
    "https://gitlab.archlinux.org/archlinux/packaging/packages/unrar"
    "https://gitlab.archlinux.org/archlinux/packaging/packages/7zip"
    #"https://github.com/ryanoasis/nerd-fonts" # emojis are too big, adding them hardcoded
    "https://github.com/junegunn/fzf"
    "https://github.com/gokcehan/lf"
    "https://github.com/zx2c4/password-store"
    "https://github.com/sharkdp/bat"
    "https://github.com/kovidgoyal/kitty"
    "https://github.com/sdushantha/fontpreview"
    "https://github.com/ImageMagick/ImageMagick"
    "https://github.com/vim/vim"
)

# Optional overrides. Missing key = auto:
#   upstream release asset → makepkg / go / cargo / configure+make → none
#   "cmd:path"          build + upload one file
#   ":path"             upload a repo file as-is
#   "upstream:<regex>"  pick specific upstream release assets
#   "url:<url> [...]"   re-host files from anywhere
#   "none"              never attach assets
declare -A BUILD_RECIPE=(
    [password-store]=":src/password-store.sh"
    [fontpreview]=":fontpreview"
    [nerd-fonts]='upstream:^(JetBrainsMono|FiraCode|Hack|NerdFontsSymbolsOnly)\.tar\.xz$'
)
declare -A ASSET_NAME=( [password-store]=pass )

github_build_all() {
    local owner="${1:-dotbins-term}"
    local url
    for url in "${UPSTREAM_URLS[@]}"; do
        github_build "$url" "$owner" || echo "FAILED: $url" >&2
    done
}

github_build() (
    SECONDS=0
    ts() { printf '[%s +%ss] %s\n' "$(date +%T)" "$SECONDS" "$*" >&2; }
    set -euo pipefail   # subshell: scoped to this function call only
    local upstream_url="$1"
    local owner="${2:-dotbins-term}"
    local api="https://api.github.com"
    local uploads="https://uploads.github.com"
    local repo_name target workdir tag release_id token default_branch r code
    ts "reading token from pass"
    token=$(pass business/social_networks/github_dotbins_term_token) || {
        echo "couldn't read token from pass" >&2
        exit 1
    }

    # prints "<body>\n<http_code>"
    gh_api() {
        local method="$1" path="$2"; shift 2
        curl -s -w '\n%{http_code}' -X "$method" "$api$path" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" "$@"
    }
    die() { echo "$1 (HTTP $(tail -n1 <<< "$2")): $(sed '$d' <<< "$2")" >&2; exit 1; }

    repo_name=$(basename "$upstream_url" .git)
    target="$owner/$repo_name"
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    # 1. create the repo in the org if missing (org endpoint, not /user/repos)
    ts "checking/creating repo $target"
    r=$(gh_api GET "/repos/$target"); code=$(tail -n1 <<< "$r")
    if [[ "$code" == 404 ]]; then
        r=$(gh_api POST "/orgs/$owner/repos" -d "$(jq -n --arg n "$repo_name" --arg u "$upstream_url" \
            '{name:$n, description:("mirror of "+$u), homepage:$u,
              has_issues:false, has_wiki:false, has_projects:false}')")
        [[ "$(tail -n1 <<< "$r")" == 201 ]] || die "failed to create $target" "$r"
        gh_api PUT "/repos/$target/actions/permissions" -d '{"enabled":false}' >/dev/null
    elif [[ "$code" != 200 ]]; then
        die "unexpected response checking $target" "$r"
    fi

    # 2. mirror: GitHub has no pull-mirrors, so push branches+tags ourselves (re-run = sync).
    #    Explicit refspecs, not `push --mirror`: that would also push refs/pull/*, which GitHub rejects.
    ts "cloning upstream $upstream_url"
    git clone --quiet --bare "$upstream_url" "$workdir/mirror.git"

    # Pushing from a shallow clone fails with "did not receive expected object".
    if [[ "$(git -C "$workdir/mirror.git" rev-parse --is-shallow-repository)" == "true" ]]; then
        ts "clone is shallow; unshallowing before push"
        git -C "$workdir/mirror.git" fetch --quiet --unshallow --tags
    fi
    if [[ "$(git -C "$workdir/mirror.git" rev-parse --is-shallow-repository)" == "true" ]]; then
        echo "refusing to push from a shallow clone: $upstream_url" >&2
        exit 1
    fi

    local auth
    auth=$(printf 'x-access-token:%s' "$token" | base64 -w0)   # header, so the token isn't in argv/URL

    push() {
        git -C "$workdir/mirror.git" -c http.extraHeader="Authorization: Basic $auth" \
            push --quiet --force "https://github.com/$target.git" "$@"
    }

    ts "pushing branches to $target"
    push 'refs/heads/*:refs/heads/*' '^refs/heads/dependabot/*' \
        || { echo "branch push failed for $target" >&2; exit 1; }

    ts "listing remote tags on $target"
    local -a remote_tags=() tags=() new_tags=()
    mapfile -t remote_tags < <(
        git -C "$workdir/mirror.git" -c http.extraHeader="Authorization: Basic $auth" \
            ls-remote --tags "https://github.com/$target.git" \
        | awk '{print $2}' | sed 's#^refs/tags/##; s/\^{}$//' | sort -u
    )
    local -A have_tag=()
    local t
    for t in "${remote_tags[@]}"; do have_tag[$t]=1; done

    mapfile -t tags < <(git -C "$workdir/mirror.git" for-each-ref \
        --format='%(refname):%(refname)' refs/tags)
    for t in "${tags[@]}"; do
        local name="${t%%:*}"; name="${name#refs/tags/}"
        [[ -n "${have_tag[$name]:-}" ]] || new_tags+=("$t")
    done
    ts "pushing ${#new_tags[@]} new tags (${#tags[@]} total) to $target"
    local i
    for ((i = 0; i < ${#new_tags[@]}; i += 500)); do
        push "${new_tags[@]:i:500}" \
            || { echo "tag push failed for $target at $i" >&2; exit 1; }
    done

    ts "setting default branch"
    default_branch=$(git -C "$workdir/mirror.git" symbolic-ref --short HEAD)
    r=$(gh_api PATCH "/repos/$target" -d "$(jq -n --arg b "$default_branch" '{default_branch:$b}')")
    [[ "$(tail -n1 <<< "$r")" == 200 ]] || die "failed to set default branch on $target" "$r"

    # 3. snapshot once: skip if we already host a release with assets (FORCE=1 to redo)
    local spec="${BUILD_RECIPE[$repo_name]-__auto__}"
    local -a assets=()
    if [[ "$spec" != none && "${FORCE:-0}" != 1 ]]; then
        r=$(gh_api GET "/repos/$target/releases?per_page=20")
        if [[ "$(tail -n1 <<< "$r")" == 200 ]] &&
           sed '$d' <<< "$r" | jq -e 'any(.[]; (.assets | length) > 0)' >/dev/null; then
            ts "already hosts a release with assets; skipping (FORCE=1 to redo)"
            echo "https://github.com/$target/releases"
            exit 0
        fi
    fi
    mkdir -p "$workdir/dl"

    # download upstream latest-release assets; $1 = regex, or "auto" for best linux x86_64 asset
    fetch_upstream() {
        local sel="$1" up_repo name url
        [[ "$upstream_url" == https://github.com/* ]] || return 1
        up_repo=$(sed -E 's#^https://github\.com/##; s#\.git$##' <<< "$upstream_url")
        r=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.github+json" "$api/repos/$up_repo/releases/latest")
        [[ "$(tail -n1 <<< "$r")" == 200 ]] || return 1
        while IFS=$'\t' read -r name url; do
            [[ -n "$name" ]] || continue
            ts "downloading upstream asset $name"
            curl -fsSL -o "$workdir/dl/$name" "$url" || return 1
            assets+=("$workdir/dl/$name")
        done < <(sed '$d' <<< "$r" | jq -r --arg sel "$sel" '
            def score: (if test("musl"; "i") then 0 else 10 end)
                     + (if test("\\.(tar\\.[gx]z|txz|tgz)$") then 0 elif test("\\.zip$") then 1 else 2 end);
            [.assets[] | .name as $n
              | if $sel == "auto" then
                    select($n | test("x86_64|amd64|x64"; "i"))
                  | select($n | test("darwin|macos|apple|windows|win(32|64)|freebsd|netbsd|openbsd|android|\\.(exe|msi|dmg|deb|rpm|apk|sig|asc|pem|sbom|sha256|sha512|sha256sum)$"; "i") | not)
                else select($n | test($sel)) end]
            | if $sel == "auto" then sort_by(.name | score) | .[:1] else . end
            | .[] | "\(.name)\t\(.browser_download_url)"')
        ((${#assets[@]}))
    }

    # build from source by detected toolchain; uploads produced executables/packages
    auto_build() {
        [[ -d "$workdir/src" ]] || git clone --quiet "$workdir/mirror.git" "$workdir/src"
        local s="$workdir/src"
        local -a new=() inbin=()
        if [[ -f "$s/PKGBUILD" ]]; then
            ts "auto-build: makepkg"
            (cd "$s" && makepkg --syncdeps --noconfirm --nocheck --skippgpcheck) || return 1
            mapfile -t -O "${#assets[@]}" assets < <(find "$s" -maxdepth 1 -name '*.pkg.tar.*' \
                ! -name '*-debug-*' ! -name '*.sig')
        elif [[ -f "$s/go.mod" ]]; then
            ts "auto-build: go"
            (cd "$s" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$repo_name" .) || return 1
            assets+=("$s/$repo_name")
        elif [[ -f "$s/Cargo.toml" ]]; then
            ts "auto-build: cargo"
            (cd "$s" && cargo build --quiet --release) || return 1
            mapfile -t -O "${#assets[@]}" assets < <(find "$s/target/release" -maxdepth 1 -type f -executable)
        elif [[ -e "$s/configure" || -e "$s/autogen.sh" || -f "$s/Makefile" ]]; then
            ts "auto-build: configure/make"
            touch "$workdir/stamp"
            (
                cd "$s"
                [[ -e configure || ! -e autogen.sh ]] || sh ./autogen.sh   # ghostpdl's also runs configure
                [[ -f Makefile || ! -e configure ]] || sh ./configure
                make -j"$(nproc)"
            ) || return 1
            # new ELF executables from this build, skipping objects/tests/libtool dirs
            mapfile -t new < <(find "$s" -type f -executable -newer "$workdir/stamp" ! -name '*.so*' \
                ! -path '*/obj/*' ! -path '*/.libs/*' ! -path '*/test*' \
                -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print)
            mapfile -t inbin < <(printf '%s\n' "${new[@]}" | grep '/bin/' || true)
            if ((${#inbin[@]})); then assets+=("${inbin[@]}"); else assets+=("${new[@]}"); fi
        else
            return 1
        fi
        ((${#assets[@]}))
    }

    case "$spec" in
    none)
        ts "recipe says none: release without assets"
        ;;
    __auto__)
        if fetch_upstream auto; then
            ts "using upstream release binary"
        elif assets=() && auto_build; then
            ts "built from source"
        else
            assets=()
            ts "nothing to attach for $repo_name: release without assets"
        fi
        ;;
    upstream:*)
        fetch_upstream "${spec#upstream:}" || { echo "no upstream asset matches ${spec#upstream:}" >&2; exit 1; }
        ;;
    url:*)
        local u
        for u in ${spec#url:}; do
            ts "downloading $u"
            curl -fsSL -o "$workdir/dl/$(basename "$u")" "$u" || { echo "download failed: $u" >&2; exit 1; }
            assets+=("$workdir/dl/$(basename "$u")")
        done
        ;;
    *)
        local build_cmd="${spec%%:*}" rel="${spec#*:}"
        git clone --quiet "$workdir/mirror.git" "$workdir/src"
        if [[ -n "$build_cmd" ]]; then
            ts "building $repo_name"
            (cd "$workdir/src" && bash -c "$build_cmd") || { echo "build failed for $repo_name" >&2; exit 1; }
        fi
        [[ -f "$workdir/src/$rel" ]] || { echo "artifact not found: $rel" >&2; exit 1; }
        assets+=("$workdir/src/$rel")
        ;;
    esac

    # 4. tag + release (always), upload all collected assets
    ts "creating release"
    tag="v$(date +%Y%m%d%H%M%S)"
    r=$(gh_api POST "/repos/$target/releases" -d "$(jq -n --arg t "$tag" --arg c "$default_branch" \
        '{tag_name:$t, name:$t, target_commitish:$c}')")
    [[ "$(tail -n1 <<< "$r")" == 201 ]] || die "failed to create release for $target" "$r"
    release_id=$(sed '$d' <<< "$r" | jq -r .id)

    local a asset
    for a in "${assets[@]}"; do
        asset=$(basename "$a")
        ((${#assets[@]} == 1)) && asset="${ASSET_NAME[$repo_name]:-$asset}"
        ts "uploading $asset ($(du -h "$a" | cut -f1))"
        r=$(curl -s -w '\n%{http_code}' -X POST \
            "$uploads/repos/$target/releases/$release_id/assets?name=$(jq -rn --arg s "$asset" '$s|@uri')" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@$a")
        [[ "$(tail -n1 <<< "$r")" == 201 ]] || die "failed to upload $asset for $target" "$r"
    done
    ((${#assets[@]})) || ts "no assets (source archives only)"

    ts "done"
    echo "https://github.com/$target/releases/tag/$tag"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    github_build_all "$@"
fi
