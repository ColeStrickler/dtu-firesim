#!/bin/bash
set -Eeuo pipefail

BRANCH="DTU-CR"

# Run from the root of the FireSim repository.
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REPOS=(
    "target-design/chipyard/generators/rocket-chip/src/main/scala/subsystem/RME-Firesim/dtu_agu"
    "target-design/chipyard/generators/rocket-chip/src/main/scala/subsystem/RME-Firesim"
    "target-design/chipyard/generators/rocket-chip"
    "target-design/chipyard/generators/bar-fetchers"
    "target-design/chipyard/generators/diplomacy"
    "target-design/chipyard/generators/rocket-chip-inclusive-cache"
    "target-design/chipyard/software/firemarshal/boards/firechip/base-workloads/workloads/matmul"
    "target-design/chipyard/software/firemarshal"
    "target-design/chipyard"
)

to_https()
{
    local url="$1"

    case "$url" in
        git@github.com:*)
            echo "https://github.com/${url#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            echo "https://github.com/${url#ssh://git@github.com/}"
            ;;
        https://github.com/*)
            echo "$url"
            ;;
        *)
            echo "ERROR: unsupported origin URL: $url" >&2
            return 1
            ;;
    esac
}

push_repo()
{
    local repo="$1"

    echo
    echo "============================================================"
    echo "Repository: $repo"
    echo "============================================================"

    if [[ ! -d "$repo" ]]; then
        echo "ERROR: directory does not exist."
        exit 1
    fi

    # Verify DTU-CR exists locally.
    if ! git -C "$repo" show-ref \
        --verify --quiet "refs/heads/$BRANCH"; then

        echo "ERROR: local branch '$BRANCH' does not exist."
        echo "Current branches:"
        git -C "$repo" branch
        exit 1
    fi

    local_sha="$(
        git -C "$repo" rev-parse "$BRANCH"
    )"

    origin="$(
        git -C "$repo" remote get-url origin
    )"

    public_url="$(to_https "$origin")"

    echo "Local branch:"
    echo "  $BRANCH @ $local_sha"

    echo "Push remote:"
    echo "  $origin"

    echo "Public URL:"
    echo "  $public_url"

    echo
    echo "Pushing..."

    git -C "$repo" push -u origin "$BRANCH"

    echo
    echo "Verifying public branch..."

    remote_sha="$(
        GIT_TERMINAL_PROMPT=0 \
        git -c credential.helper= \
            ls-remote "$public_url" \
            "refs/heads/$BRANCH" \
            2>/dev/null |
        awk '{print $1}'
    )"

    if [[ -z "$remote_sha" ]]; then
        echo "ERROR: Could not find public branch $BRANCH at:"
        echo "  $public_url"
        exit 1
    fi

    if [[ "$remote_sha" != "$local_sha" ]]; then
        echo "ERROR: Public branch does not match local branch."
        echo "Local:  $local_sha"
        echo "Remote: $remote_sha"
        exit 1
    fi

    echo "OK: public DTU-CR branch verified."
}

###############################################################################
# Push submodules deepest -> shallowest
###############################################################################

for repo in "${REPOS[@]}"; do
    push_repo "$repo"
done

echo
echo "============================================================"
echo "All nested DTU-CR repositories pushed successfully."
echo "============================================================"
echo
echo "Now checking top-level FireSim repository..."

###############################################################################
# Top-level FireSim
###############################################################################

if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo
    echo "ERROR: top-level FireSim does not yet have DTU-CR."
    echo
    echo "Create and commit it first:"
    echo
    echo "  git switch -c DTU-CR"
    echo "  git add target-design/chipyard .gitmodules"
    echo "  git commit -m 'DTU artifact release'"
    echo
    exit 1
fi

# Refuse to push FireSim if it still has an uncommitted Chipyard pointer.
if ! git diff --quiet -- target-design/chipyard ||
   ! git diff --cached --quiet -- target-design/chipyard; then

    echo
    echo "ERROR: top-level FireSim still has an uncommitted Chipyard change."
    echo
    echo "Inspect and commit it first:"
    echo
    echo "  git status"
    echo "  git diff"
    echo "  git add target-design/chipyard .gitmodules"
    echo "  git commit -m 'DTU artifact release'"
    exit 1
fi

push_repo "."

echo
echo "============================================================"
echo "SUCCESS"
echo "============================================================"
echo
echo "All DTU-CR branches, including FireSim, are publicly visible."
