#!/usr/bin/env bash
# Requires: git, curl, jq, pass (entry: business/social_networks/codeberg_dotbins_token)
# NOTE: intentionally no top-level `set -e` — this file is meant to be sourced,
# and `set -e` in a sourced file applies to your whole interactive shell.

UPSTREAM_URLS=(
    "https://github.com/gokcehan/lf"
    "https://github.com/zx2c4/password-store"
)

codeberg_build_all() {
    local owner="${1:-xarxaxdev}"
    local url
    for url in "${UPSTREAM_URLS[@]}"; do
        codeberg_build "$url" "$owner" || echo "FAILED: $url" >&2
    done
}

codeberg_build() (
    set -euo pipefail   # subshell: scoped to this function call only
    local upstream_url="$1"
    local owner="${2:-xarxaxdev}"
    local api="https://codeberg.org/api/v1"
    local repo_name target workdir bin_path tag release_id codeberg_token

    codeberg_token=$(pass business/social_networks/codeberg_dotbins_token) || {
        echo "couldn't read token from pass" >&2
        exit 1
    }

    # sanity-check: repos get created under whoever the token belongs to
    local whoami
    whoami=$(curl -s -H "Authorization: token $codeberg_token" "$api/user" | jq -r .login)
    if [[ "$whoami" != "$owner" ]]; then
        echo "note: token is for '$whoami', not '$owner' — using '$whoami'" >&2
        owner="$whoami"
    fi

    repo_name=$(basename "$upstream_url" .git)
    target="$owner/$repo_name"

    # 1. migrate (import) the upstream repo into codeberg under $owner, if missing or broken
    local exists_code
    exists_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: token $codeberg_token" "$api/repos/$target")

    if [[ "$exists_code" == 200 ]]; then
        local is_empty
        is_empty=$(curl -s -H "Authorization: token $codeberg_token" \
            "$api/repos/$target" | jq -r .empty)
        if [[ "$is_empty" != "false" ]]; then
            echo "note: $target exists but is empty (leftover from a failed run) — recreating" >&2
            curl -s -o /dev/null -X DELETE "$api/repos/$target" \
                -H "Authorization: token $codeberg_token"
            exists_code=404
        fi
    fi

    if [[ "$exists_code" == 404 ]]; then
        local mig_resp mig_code
        mig_resp=$(curl -s -w '\n%{http_code}' -X POST "$api/repos/migrate" \
            -H "Authorization: token $codeberg_token" \
            -H "Content-Type: application/json" \
            -d "{\"clone_addr\":\"$upstream_url\",\"repo_owner\":\"$owner\",\"repo_name\":\"$repo_name\",\"mirror\":true,\"service\":\"git\"}")
        mig_code=$(tail -n1 <<< "$mig_resp")
        if [[ "$mig_code" != 201 ]]; then
            echo "failed to migrate $target (HTTP $mig_code): $(sed '$d' <<< "$mig_resp")" >&2
            exit 1
        fi
    elif [[ "$exists_code" != 200 ]]; then
        echo "unexpected response checking $target (HTTP $exists_code)" >&2
        exit 1
    fi

    # migrate returns before the background clone finishes — poll actual branches, not
    # repo metadata (default_branch/empty can lag behind the real clone completing)
    local branches_json branch_count default_branch tries=0
    while :; do
        branches_json=$(curl -s -H "Authorization: token $codeberg_token" \
            "$api/repos/$target/branches")
        branch_count=$(jq 'length' <<< "$branches_json" 2>/dev/null || echo 0)
        (( branch_count > 0 )) && break
        tries=$((tries + 1))
        if (( tries >= 15 )); then
            echo "$target has no branches after migration (timed out waiting for clone)" >&2
            echo "raw response: $branches_json" >&2
            exit 1
        fi
        sleep 2
    done
    default_branch=$(jq -r '.[0].name' <<< "$branches_json")

    # migrate leaves the Releases unit disabled by default — enable it
    local has_releases
    has_releases=$(curl -s -H "Authorization: token $codeberg_token" \
        "$api/repos/$target" | jq -r .has_releases)
    if [[ "$has_releases" != "true" ]]; then
        curl -s -o /dev/null -X PATCH "$api/repos/$target" \
            -H "Authorization: token $codeberg_token" \
            -H "Content-Type: application/json" \
            -d '{"has_releases":true}'
    fi

    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    # 2. build (autodetect toolchain from repo contents)
    git clone --quiet "$upstream_url" "$workdir/src"
    pushd "$workdir/src" >/dev/null
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

    # 3. tag + upload binary as a release asset
    tag="v$(date +%Y%m%d%H%M%S)"
    local rel_resp rel_code
    rel_resp=$(curl -s -w '\n%{http_code}' -X POST "$api/repos/$target/releases" \
        -H "Authorization: token $codeberg_token" \
        -H "Content-Type: application/json" \
        -d "{\"tag_name\":\"$tag\",\"name\":\"$tag\",\"target_commitish\":\"$default_branch\"}")
    rel_code=$(tail -n1 <<< "$rel_resp")
    if [[ "$rel_code" != 201 ]]; then
        echo "failed to create release for $target (HTTP $rel_code): $(sed '$d' <<< "$rel_resp")" >&2
        exit 1
    fi
    release_id=$(sed '$d' <<< "$rel_resp" | jq -r .id)

    local asset_code
    asset_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        "$api/repos/$target/releases/$release_id/assets?name=$(basename "$bin_path")" \
        -H "Authorization: token $codeberg_token" \
        -F "attachment=@$bin_path")
    if [[ "$asset_code" != 201 ]]; then
        echo "failed to upload asset for $target (HTTP $asset_code)" >&2
        exit 1
    fi

    echo "https://codeberg.org/$target/releases/tag/$tag"
)
