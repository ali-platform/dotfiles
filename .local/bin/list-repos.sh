#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ORGS=(
    "AccelerateLearning"
    "ali-back-office"
    "ali-data-gov"
    "ali-marketing"
    "ali-one-platform"
    "ali-onramp"
    "ali-open"
    "ali-platform"
    "stemscopes-v3"
    "stemscopes-v4"
    "studysocial"
)

list_org_repos() {
    local org="$1"

    if ! gh repo list "$org" --no-archived --json nameWithOwner --limit 1000 | jq -r '.[].nameWithOwner'; then
        echo "Unable to list repos for $org" >&2
        return 1
    fi
}

main() {
    if ! command -v gh > /dev/null 2>&1; then
        echo "Missing dependency: gh" >&2
        exit 1
    fi

    if ! command -v jq > /dev/null 2>&1; then
        echo "Missing dependency: jq" >&2
        exit 1
    fi

    local orgs=()
    if [[ "$#" -gt 0 ]]; then
        orgs=("$@")
    else
        orgs=("${DEFAULT_ORGS[@]}")
    fi

    local org
    for org in "${orgs[@]}"; do
        list_org_repos "$org"
    done
}

main "$@"
