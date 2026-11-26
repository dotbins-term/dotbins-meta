#!/usr/bin/env bash
# Requires: git, curl, jq, base64, pass (entry: business/social_networks/github_dotbins_term_token)
# Token: fine-grained PAT, Resource owner = dotbins-term, All repositories,
#   Repository permissions: Administration (RW), Contents (RW), Metadata (R)
# NOTE: intentionally no top-level `set -e` — this file is meant to be sourced.

UPSTREAM_URLS=(
    "https://github.com/gokcehan/lf"
    "https://github.com/vim/vim"
    "https://github.com/zx2c4/password-store"
    "https://github.com/ryanoasis/nerd-fonts"
    "https://github.com/junegunn/fzf"
    "https://github.com/BurntSushi/ripgrep"
    "https://github.com/sharkdp/bat"
    "https://github.com/kovidgoyal/kitty"
    "https://github.com/ArtifexSoftware/ghostpdl"
    "https://gitlab.archlinux.org/archlinux/packaging/packages/unzip"
    "https://gitlab.archlinux.org/archlinux/packaging/packages/unrar"
    "https://gitlab.archlinux.org/archlinux/packaging/packages/7zip"
    "https://github.com/sdushantha/fontpreview"
    "https://github.com/ImageMagick/ImageMagick"
)

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
    local repo_name target workdir bin_path tag release_id token default_branch r code
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
        gh_api PUT "/repos/$target/actions/permissions" -d '{"enabled":false}' >/dev/null
        [[ "$(tail -n1 <<< "$r")" == 201 ]] || die "failed to create $target" "$r"
    elif [[ "$code" != 200 ]]; then
        die "unexpected response checking $target" "$r"
    fi

    # 2. mirror: GitHub has no pull-mirrors, so push branches+tags ourselves (re-run = sync).
    #    Explicit refspecs, not `push --mirror`: that would also push refs/pull/*, which GitHub rejects.
    ts "cloning upstream $upstream_url"
    git clone --quiet --bare "$upstream_url" "$workdir/mirror.git"
    local auth
    auth=$(printf 'x-access-token:%s' "$token" | base64 -w0)   # header, so the token isn't in argv/URL

    #ts "pushing mirror to $target"
    #git -C "$workdir/mirror.git" -c http.extraHeader="Authorization: Basic $auth" \
    #    push --quiet --force "https://github.com/$target.git" \
    #    'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' '^refs/heads/dependabot/*' \
    #    || { echo "push failed for $target" >&2; exit 1; }
    push() {
        git -C "$workdir/mirror.git" -c http.extraHeader="Authorization: Basic $auth" \
            push --quiet --force "https://github.com/$target.git" "$@"
    }

    ts "pushing branches to $target"
    push 'refs/heads/*:refs/heads/*' '^refs/heads/dependabot/*' \
        || { echo "branch push failed for $target" >&2; exit 1; }

    mapfile -t tags < <(git -C "$workdir/mirror.git" for-each-ref \
        --format='%(refname):%(refname)' refs/tags)
    for ((i = 0; i < ${#tags[@]}; i += 500)); do
        ts "pushing tags $i/${#tags[@]} to $target"
        push "${tags[@]:i:500}" \
            || { echo "tag push failed for $target at $i" >&2; exit 1; }
    done



    ts "setting default branch"
    default_branch=$(git -C "$workdir/mirror.git" symbolic-ref --short HEAD)
    r=$(gh_api PATCH "/repos/$target" -d "$(jq -n --arg b "$default_branch" '{default_branch:$b}')")
    [[ "$(tail -n1 <<< "$r")" == 200 ]] || die "failed to set default branch on $target" "$r"

    # 3. build (autodetect toolchain from repo contents)
    ts "local clone for build"
    git clone --quiet "$workdir/mirror.git" "$workdir/src"
    pushd "$workdir/src" >/dev/null
    ts "building $repo_name"
    if [[ -f go.mod ]]; then
        CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$repo_name" .
        bin_path="$workdir/src/$repo_name"
    elif [[ -f Cargo.toml ]]; then
        cargo build --quiet --release
        bin_path="$workdir/src/target/release/$repo_name"
    elif [[ -f Makefile ]]; then
        make --silent
        bin_path=$(find . -maxdepth 1 -type f -executable | head -n1)
    elif [[ -f setup.py || -f pyproject.toml ]]; then
        pip install --quiet --target dist .
        bin_path=$(find dist/bin -maxdepth 1 -type f 2>/dev/null | head -n1)
    else
        echo "don't know how to build $repo_name" >&2
        popd >/dev/null
        return 1
    fi
    popd >/dev/null

    if [[ -z "${bin_path:-}" || ! -f "$bin_path" ]]; then
        echo "no binary produced for $repo_name (script-only repo?)" >&2
        return 1
    fi

    # 4. tag + upload binary as a release asset
    ts "creating release"
    tag="v$(date +%Y%m%d%H%M%S)"
    r=$(gh_api POST "/repos/$target/releases" -d "$(jq -n --arg t "$tag" --arg c "$default_branch" \
        '{tag_name:$t, name:$t, target_commitish:$c}')")
    [[ "$(tail -n1 <<< "$r")" == 201 ]] || die "failed to create release for $target" "$r"
    release_id=$(sed '$d' <<< "$r" | jq -r .id)

    # assets go to uploads.github.com as a raw body (not multipart like Gitea/Codeberg)
    ts "uploading asset"
    r=$(curl -s -w '\n%{http_code}' -X POST \
        "$uploads/repos/$target/releases/$release_id/assets?name=$(basename "$bin_path")" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$bin_path")
    [[ "$(tail -n1 <<< "$r")" == 201 ]] || die "failed to upload asset for $target" "$r"
    ts "done"
    echo "https://github.com/$target/releases/tag/$tag"
)


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    github_build_all "$@"
fi
