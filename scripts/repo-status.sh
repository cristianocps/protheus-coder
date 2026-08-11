#!/usr/bin/env bash
# repo-status.sh — prints the current fetch/index state of a repo as JSON.
#
# Usage: repo-status.sh <project> <repo>
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"

[[ $# -eq 2 ]] || { echo "usage: repo-status.sh <project> <repo>" >&2; exit 2; }

PROJECT="$1"; REPO="$2"
KEY="${PROJECT}__${REPO}"
STATUS_FILE="${WORKSPACE}/.status/${KEY}.json"

if [[ -f "${STATUS_FILE}" ]]; then
    cat "${STATUS_FILE}"
else
    cat <<EOF
{
  "project": "${PROJECT}",
  "repo": "${REPO}",
  "state": "absent",
  "message": "not fetched yet; run get-repo.sh ${PROJECT} ${REPO}"
}
EOF
fi
