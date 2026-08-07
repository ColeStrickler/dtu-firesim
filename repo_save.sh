#!/bin/bash

set -Eeuo pipefail

BRANCH="DTU-CR"
COMMIT_MSG="DTU artifact release"

# Set PUSH=1 to push DTU-CR after each commit.
PUSH="${PUSH:-0}"

# Set AUTO_CONFIRM=1 only after you have tested the script once.
AUTO_CONFIRM="${AUTO_CONFIRM:-0}"

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

###############################################################################
# Establish FireSim root
###############################################################################

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

echo "FireSim root: $ROOT"

###############################################################################
# Convert an origin URL to a public HTTPS URL.
#
# We DO NOT modify the local origin. This lets you keep using SSH for pushes.
###############################################################################

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

        https://*)
            echo "$url"
            ;;

        *)
            echo "ERROR: Cannot automatically convert URL to HTTPS:" >&2
            echo "  $url" >&2
            return 1
            ;;
    esac
}

###############################################################################
# Given a parent repository and child path relative to that parent,
# determine the submodule name from .gitmodules.
###############################################################################

find_submodule_name()
{
    local parent="$1"
    local child_rel="$2"

    if [[ ! -f "$parent/.gitmodules" ]]; then
        return 1
    fi

    while read -r key path; do
        if [[ "$path" == "$child_rel" ]]; then
            local name="${key#submodule.}"
            name="${name%.path}"
            echo "$name"
            return 0
        fi
    done < <(
        git -C "$parent" config -f .gitmodules \
            --get-regexp '^submodule\..*\.path$' 2>/dev/null || true
    )

    return 1
}

###############################################################################
# Process repositories deepest -> shallowest
###############################################################################

for repo in "${REPOS[@]}"; do

    echo
    echo "================================================================"
    echo "Processing:"
    echo "  $repo"
    echo "================================================================"

    repo_abs="$(realpath "$ROOT/$repo")"

    ###########################################################################
    # Sanity checks
    ###########################################################################

    if [[ ! -d "$repo_abs" ]]; then
        echo "ERROR: Directory does not exist:"
        echo "  $repo_abs"
        exit 1
    fi

    actual_root="$(
        git -C "$repo_abs" rev-parse --show-toplevel 2>/dev/null || true
    )"

    if [[ -z "$actual_root" ]]; then
        echo "ERROR: Not a Git repository:"
        echo "  $repo"
        exit 1
    fi

    actual_root="$(realpath "$actual_root")"

    if [[ "$actual_root" != "$repo_abs" ]]; then
        echo "ERROR: $repo is not the root of an independent Git repository."
        echo
        echo "Git reports its root as:"
        echo "  $actual_root"
        exit 1
    fi

    ###########################################################################
    # Verify that this really is a registered submodule.
    ###########################################################################

    parent="$(
        git -C "$repo_abs" rev-parse \
            --show-superproject-working-tree 2>/dev/null || true
    )"

    if [[ -z "$parent" ]]; then
        echo "ERROR: $repo does not appear to be a registered Git submodule."
        echo
        echo "Do not continue until this is fixed."
        exit 1
    fi

    parent="$(realpath "$parent")"

    child_rel="$(realpath --relative-to="$parent" "$repo_abs")"

    submodule_name="$(
        find_submodule_name "$parent" "$child_rel" || true
    )"

    if [[ -z "$submodule_name" ]]; then
        echo "ERROR: Could not find this submodule in:"
        echo "  $parent/.gitmodules"
        echo
        echo "Expected path:"
        echo "  $child_rel"
        exit 1
    fi

    echo "Parent repository:"
    echo "  $parent"
    echo
    echo "Submodule name:"
    echo "  $submodule_name"

    ###########################################################################
    # Determine the public URL for this repository.
    ###########################################################################

    origin_url="$(
        git -C "$repo_abs" remote get-url origin 2>/dev/null || true
    )"

    if [[ -z "$origin_url" ]]; then
        echo "ERROR: Repository has no origin remote:"
        echo "  $repo"
        exit 1
    fi

    public_url="$(to_https "$origin_url")"

    echo
    echo "Local origin:"
    echo "  $origin_url"
    echo
    echo "Public submodule URL:"
    echo "  $public_url"

    ###########################################################################
    # Update the PARENT'S .gitmodules.
    #
    # This is important. The parent must point to the repository containing
    # the new DTU-CR commit.
    ###########################################################################

    git -C "$parent" config -f .gitmodules \
        "submodule.${submodule_name}.url" \
        "$public_url"

    echo
    echo "Updated parent .gitmodules:"
    echo "  $child_rel -> $public_url"

    ###########################################################################
    # Create DTU-CR safely.
    ###########################################################################

    current_branch="$(
        git -C "$repo_abs" symbolic-ref --short -q HEAD || true
    )"

    if git -C "$repo_abs" show-ref \
        --verify --quiet "refs/heads/$BRANCH"; then

        if [[ "$current_branch" != "$BRANCH" ]]; then
            echo
            echo "ERROR: $BRANCH already exists, but is not checked out."
            echo
            echo "Current branch:"
            echo "  ${current_branch:-DETACHED HEAD}"
            echo
            echo "Refusing to switch automatically because this repository"
            echo "contains working-tree changes."
            exit 1
        fi

        echo
        echo "Already on $BRANCH."

    else

        echo
        echo "Creating $BRANCH at current HEAD..."
        git -C "$repo_abs" switch -c "$BRANCH"

    fi

    ###########################################################################
    # Show EXACTLY what will be committed.
    ###########################################################################

    echo
    echo "Current status:"
    echo "----------------------------------------------------------------"
    git -C "$repo_abs" status --short
    echo "----------------------------------------------------------------"

    if [[ "$AUTO_CONFIRM" != "1" ]]; then
        echo
        read -r -p "Commit ALL changes shown above in $repo? [y/N] " answer

        case "$answer" in
            y|Y|yes|YES)
                ;;
            *)
                echo "Aborting without staging this repository."
                exit 1
                ;;
        esac
    fi

    ###########################################################################
    # Stage and commit.
    ###########################################################################

    git -C "$repo_abs" add -A

    if git -C "$repo_abs" diff --cached --quiet; then

        echo "No changes to commit."

    else

        echo
        echo "Staged diff summary:"
        git -C "$repo_abs" diff --cached --stat

        git -C "$repo_abs" commit \
            -m "$COMMIT_MSG"

        echo
        echo "Created commit:"
        git -C "$repo_abs" log -1 --oneline

    fi

    ###########################################################################
    # Optionally push.
    ###########################################################################

    if [[ "$PUSH" == "1" ]]; then

        echo
        echo "Pushing $BRANCH to origin..."

        git -C "$repo_abs" push -u origin "$BRANCH"

        local_sha="$(git -C "$repo_abs" rev-parse HEAD)"

        #######################################################################
        # Verify that the public HTTPS repository actually exposes the SHA.
        #######################################################################

        echo
        echo "Checking public HTTPS access..."

        remote_sha="$(
            GIT_TERMINAL_PROMPT=0 \
            git -c credential.helper= \
                ls-remote "$public_url" "refs/heads/$BRANCH" \
                2>/dev/null |
            awk '{print $1}'
        )"

        if [[ "$remote_sha" != "$local_sha" ]]; then
            echo
            echo "ERROR: Public DTU-CR branch does not resolve to local HEAD."
            echo
            echo "Local:"
            echo "  $local_sha"
            echo
            echo "Public:"
            echo "  ${remote_sha:-NOT FOUND}"
            echo
            echo "URL:"
            echo "  $public_url"
            exit 1
        fi

        echo "Public branch verified."

    fi

done

###############################################################################
# Final status
###############################################################################

echo
echo "================================================================"
echo "All requested submodules processed."
echo "================================================================"

echo
echo "Top-level FireSim status:"
git status --short

echo
echo "Recursive submodule state:"
git submodule status --recursive
