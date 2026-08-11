#!/usr/bin/env bash
# get-repo.sh — idempotent, on-demand fetch + index of an Azure DevOps repo.
#
# Usage:
#   get-repo.sh <project> <repo> [--background] [--force-reindex]
#
# Behavior:
#   - Clones the repo if missing, otherwise `git pull` (fast-forward).
#   - Indexes AdvPL/TLPP sources with plugadvpl and other languages with
#     codegraph (incremental when possible).
#   - Writes progress to $WORKSPACE/.status/<project>__<repo>.json so the
#     orchestrator can poll with repo-status.sh.
#
# Auth: uses AZDO_ORG + AZDO_PAT (read-only). The PAT is the private key
# mounted into the container; it is never written to the repo working tree.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
STATUS_DIR="${WORKSPACE}/.status"

usage() {
    echo "usage: get-repo.sh <project> <repo> [--background] [--force-reindex]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage

PROJECT="$1"; REPO="$2"; shift 2
BACKGROUND=0
FORCE_REINDEX=0
for arg in "$@"; do
    case "$arg" in
        --background) BACKGROUND=1 ;;
        --force-reindex) FORCE_REINDEX=1 ;;
        *) echo "unknown option: $arg" >&2; usage ;;
    esac
done

# Guard against path traversal in names coming from the orchestrator.
sanitize() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid name: $1" >&2; exit 2; }; }
sanitize "$PROJECT"
sanitize "$REPO"

KEY="${PROJECT}__${REPO}"
DEST="${WORKSPACE}/${PROJECT}/${REPO}"
STATUS_FILE="${STATUS_DIR}/${KEY}.json"
LOCK_DIR="${STATUS_DIR}/${KEY}.lock"

mkdir -p "${STATUS_DIR}"

write_status() {
    # $1 state, $2 message
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "${STATUS_FILE}" <<EOF
{
  "project": "${PROJECT}",
  "repo": "${REPO}",
  "path": "${DEST}",
  "state": "$1",
  "message": "$2",
  "updated": "${ts}"
}
EOF
}

do_work() {
    # Serialize concurrent fetches of the same repo.
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        write_status "busy" "another fetch is already running for ${KEY}"
        return 0
    fi
    trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

    if [[ -z "${AZDO_ORG:-}" ]]; then
        write_status "error" "AZDO_ORG is not set"
        return 1
    fi

    # Build an authenticated clone URL without leaking the PAT into git config.
    local base="dev.azure.com/${AZDO_ORG}/${PROJECT}/_git/${REPO}"
    local url
    if [[ -n "${AZDO_PAT:-}" ]]; then
        url="https://pat:${AZDO_PAT}@${base}"
    else
        url="https://${base}"
    fi

    if [[ -d "${DEST}/.git" ]]; then
        write_status "pulling" "updating existing clone"
        git -C "${DEST}" remote set-url origin "${url}"
        if ! git -C "${DEST}" pull --ff-only --quiet; then
            write_status "error" "git pull failed"
            return 1
        fi
        # Never persist the PAT-bearing URL.
        git -C "${DEST}" remote set-url origin "https://${base}"
    else
        write_status "cloning" "clone in progress"
        mkdir -p "${WORKSPACE}/${PROJECT}"
        rm -rf "${DEST}"
        if ! git clone --quiet "${url}" "${DEST}"; then
            write_status "error" "git clone failed"
            return 1
        fi
        git -C "${DEST}" remote set-url origin "https://${base}"
    fi

    write_status "indexing" "building plugadvpl + codegraph indices"
    index_repo || { write_status "error" "indexing failed"; return 1; }

    write_status "ready" "repo cloned and indexed"
}

index_repo() {
    # AdvPL / TLPP index (plugadvpl). Idempotent: init is a no-op if present.
    if compgen -G "${DEST}/**/*.prw" > /dev/null 2>&1 \
       || compgen -G "${DEST}/**/*.tlpp" > /dev/null 2>&1 \
       || compgen -G "${DEST}/**/*.prx" > /dev/null 2>&1 \
       || compgen -G "${DEST}/**/*.apw" > /dev/null 2>&1; then
        plugadvpl init --root "${DEST}" >/dev/null 2>&1 || true
        if [[ "${FORCE_REINDEX}" -eq 1 ]]; then
            plugadvpl reindex --root "${DEST}" || return 1
        else
            plugadvpl ingest --root "${DEST}" || return 1
        fi
    fi

    # Other languages (codegraph). Non-fatal if unsupported for this repo.
    codegraph init --dir "${DEST}" --non-interactive >/dev/null 2>&1 \
        || codegraph init --dir "${DEST}" >/dev/null 2>&1 \
        || true

    return 0
}

if [[ "${BACKGROUND}" -eq 1 ]]; then
    write_status "queued" "background fetch started"
    # Detach: survive the MCP request that triggered it.
    nohup bash -c "$(declare -f write_status do_work index_repo); \
        PROJECT='${PROJECT}' REPO='${REPO}' DEST='${DEST}' KEY='${KEY}' \
        STATUS_FILE='${STATUS_FILE}' LOCK_DIR='${LOCK_DIR}' \
        WORKSPACE='${WORKSPACE}' FORCE_REINDEX='${FORCE_REINDEX}' \
        AZDO_ORG='${AZDO_ORG:-}' AZDO_PAT='${AZDO_PAT:-}' \
        do_work" >> "${STATUS_DIR}/${KEY}.log" 2>&1 &
    echo "Started background fetch for ${KEY}. Poll with: repo-status.sh ${PROJECT} ${REPO}"
    exit 0
fi

do_work
cat "${STATUS_FILE}"
