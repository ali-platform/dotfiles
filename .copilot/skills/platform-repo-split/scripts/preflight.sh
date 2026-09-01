#!/usr/bin/env bash
# Preflight for the ADR-010 platform repo split. Read-only: touches no repo and no cluster state.
set -euo pipefail

APP=""
PART_OF=""
SEARCH_ROOTS=()
SKIP_CLUSTER=0
GATEWAY_REF=""
HOST_SUFFIX="one.ali-apps.com"

FAILURES=0
WARNINGS=0

readonly C_RESET=$'\033[0m' C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m' C_BOLD=$'\033[1m'

pass() { printf '  %sPASS%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
note() { printf '  %sNOTE%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '  %sFAIL%s  %s\n' "$C_RED" "$C_RESET" "$*"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() {
  cat <<'EOF'
Usage: preflight.sh --application-name <app> [options]

Options:
  --application-name <app>   Application to migrate (e.g. reference). Required.
  --part-of <partOf>         Skip discovery of partOf and use this value.
  --search-root <dir>        Where to look for repos. Repeatable. Default: $HOME/src.
  --host-suffix <suffix>     New hostname suffix. Default: one.ali-apps.com.
  --gateway <ns>/<name>      Shared gateway to check against; '{stack}' is
                             substituted. Default: discovered from the cluster.
  --skip-cluster             Skip every kubectl check (offline use only).
  -h, --help                 This message.

Resolves partOf, components and stacks, locates all five repo roles, checks the toolchain and
gates on the shared gateway. Never reads .ali/projectInfo.json.

On success, prints a sourceable summary block to stdout.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --application-name) APP="$2"; shift 2 ;;
    --part-of) PART_OF="$2"; shift 2 ;;
    --search-root) SEARCH_ROOTS+=("$2"); shift 2 ;;
    --host-suffix) HOST_SUFFIX="$2"; shift 2 ;;
    --gateway) GATEWAY_REF="$2"; shift 2 ;;
    --skip-cluster) SKIP_CLUSTER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$APP" ]] || { printf '%s\n\n' '--application-name is required' >&2; usage >&2; exit 2; }
[[ ${#SEARCH_ROOTS[@]} -gt 0 ]] || SEARCH_ROOTS=("$HOME/src")

SCRATCH="$HOME/.cache/ali-migration"
mkdir -p "$SCRATCH"

# ---------------------------------------------------------------------------
section "Toolchain"

for tool in git gh jq yq helm kubectl pnpm; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass "$tool"
  else
    fail "$tool not found on PATH"
  fi
done

for tool in pulumi aws; do
  command -v "$tool" >/dev/null 2>&1 && pass "$tool" || warn "$tool not found (needed only for the Pulumi backup in Phase 1)"
done

if command -v yq >/dev/null 2>&1; then
  # Snap-confined yq cannot read /tmp; the whole script pipes into yq to stay safe either way.
  if [[ "$(readlink -f "$(command -v yq)")" == /snap/* ]]; then
    warn "yq is snap-confined: it cannot read /tmp. Scratch is $SCRATCH and yq is always piped."
  fi
fi

if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && pass "gh authenticated" || fail "gh is not authenticated (run: gh auth login)"
fi

[[ $FAILURES -eq 0 ]] || { printf '\n%sToolchain incomplete. Stopping.%s\n' "$C_RED" "$C_RESET"; exit 1; }

# ---------------------------------------------------------------------------
section "Repository discovery"

declare -A REPO_PATH=()

for root in "${SEARCH_ROOTS[@]}"; do
  [[ -d "$root" ]] || { warn "search root does not exist: $root"; continue; }
  while IFS= read -r gitdir; do
    repo_dir="$(dirname "$gitdir")"
    url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
    [[ -n "$url" ]] || continue
    name="${url##*/}"
    name="${name%.git}"
    # First match wins so a stale duplicate clone deeper in the tree cannot shadow the real one.
    [[ -n "${REPO_PATH[$name]:-}" ]] || REPO_PATH["$name"]="$repo_dir"
  done < <(find "$root" -maxdepth 5 -type d -name .git -prune 2>/dev/null)
done

# partOf and the component list come from argocd/values.yaml in the new per-component platform
# repos. .ali/projectInfo.json is deprecated and must never be consulted.
COMPONENTS=()
for name in "${!REPO_PATH[@]}"; do
  [[ "$name" == platform-*-"$APP"-* ]] || continue
  values="${REPO_PATH[$name]}/argocd/values.yaml"
  [[ -f "$values" ]] || continue
  read -r v_part v_app v_comp < <(cat "$values" | yq -r '[.partOf, .applicationName, .componentName] | @tsv' 2>/dev/null || echo '')
  [[ "$v_app" == "$APP" && -n "$v_comp" && "$v_comp" != "null" ]] || continue
  if [[ -n "$PART_OF" && "$v_part" != "$PART_OF" ]]; then continue; fi
  PART_OF="$v_part"
  COMPONENTS+=("$v_comp")
done

if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
  fail "no platform-<partOf>-$APP-<component> repo with an argocd/values.yaml was found under: ${SEARCH_ROOTS[*]}"
  printf '\n%sCannot continue without at least one new platform repo.%s\n' "$C_RED" "$C_RESET"
  exit 1
fi

IFS=$'\n' COMPONENTS=($(printf '%s\n' "${COMPONENTS[@]}" | sort -u)); unset IFS
pass "partOf=$PART_OF application=$APP components=${COMPONENTS[*]}"

LEGACY_REPO="platform-$PART_OF-$APP"
K8S_APPS="platform-k8s-apps"

check_repo() {
  local name="$1" role="$2"
  if [[ -n "${REPO_PATH[$name]:-}" ]]; then
    pass "$role: $name -> ${REPO_PATH[$name]}"
    return 0
  fi
  fail "$role: $name not found in the workspace"
  return 1
}

check_repo "$LEGACY_REPO" "legacy platform repo" || true
check_repo "$K8S_APPS" "argocd wiring" || true
for c in "${COMPONENTS[@]}"; do
  check_repo "platform-$PART_OF-$APP-$c" "new platform repo ($c)" || true
  check_repo "container-$PART_OF-$APP-$c" "container repo ($c)" || true
done

[[ $FAILURES -eq 0 ]] || { printf '\n%sAdd the missing repositories to the workspace and re-run.%s\n' "$C_RED" "$C_RESET"; exit 1; }

# ---------------------------------------------------------------------------
section "Working trees"

for name in "$LEGACY_REPO" "$K8S_APPS" "${COMPONENTS[@]/#/platform-$PART_OF-$APP-}" "${COMPONENTS[@]/#/container-$PART_OF-$APP-}"; do
  dir="${REPO_PATH[$name]:-}"
  [[ -n "$dir" ]] || continue
  if [[ -z "$(git -C "$dir" status --porcelain)" ]]; then
    pass "$name clean on $(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  else
    fail "$name has uncommitted changes; generated diffs would be unreadable and work could be lost"
  fi
done

# ---------------------------------------------------------------------------
section "Stacks"

PROJECT_VALUES="${REPO_PATH[$K8S_APPS]}/argocd/projects/$PART_OF/$APP/values.yaml"
if [[ ! -f "$PROJECT_VALUES" ]]; then
  fail "no legacy project values at argocd/projects/$PART_OF/$APP/values.yaml"
  exit 1
fi

STACKS=()
declare -A STACK_CLUSTER=()
while IFS=$'\t' read -r s cluster; do
  [[ -n "$s" ]] || continue
  STACKS+=("$s")
  STACK_CLUSTER["$s"]="$cluster"
done < <(cat "$PROJECT_VALUES" | yq -r '.stacks[] | [.stackName, .k8sClusterAccountName] | @tsv')

pass "stacks: ${STACKS[*]}"

# v0.0.0 is a REAL git tag that deploys a real image, so a component pinned to it is very
# often live. Never infer "not deployed" from the declared ref; the cluster check below is
# the only authority. This flag exists purely to say "look closely here".
LOW_TAG=()
for c in "${COMPONENTS[@]}"; do
  deployed=0
  for s in "${STACKS[@]}"; do
    tag="$(cat "$PROJECT_VALUES" | yq -r ".\"$s\".\"$c\" // \"\"")"
    [[ "$tag" == "v0.0.0" || "$tag" == "0.0.0" || -z "$tag" || "$tag" == "null" ]] || deployed=1
  done
  if [[ $deployed -eq 0 ]]; then
    LOW_TAG+=("$c")
    warn "component '$c' is v0.0.0 in every stack. That does NOT mean it is undeployed - v0.0.0 is a real tag. Confirm against the cluster before skipping any phase for it."
  fi
done

for c in "${COMPONENTS[@]}"; do
  for s in "${STACKS[@]}"; do
    printf '        %-6s %-4s declared=%s\n' "$c" "$s" "$(cat "$PROJECT_VALUES" | yq -r ".\"$s\".\"$c\" // \"(none)\"")"
  done
done

# ---------------------------------------------------------------------------
section "Target ArgoCD wiring"

APPS_DIR="${REPO_PATH[$K8S_APPS]}/argocd/applications/$PART_OF"
if [[ -d "$APPS_DIR" ]]; then
  pass "argocd/applications/$PART_OF exists"
  [[ -f "$APPS_DIR/templates/_application.tpl" ]] \
    && pass "_application.tpl present" \
    || fail "_application.tpl missing: the shared Application template is a prerequisite"
  if [[ -f "$APPS_DIR/templates/gateway.yaml" ]]; then
    pass "shared gateway is wired for partOf '$PART_OF'"
  else
    fail "argocd/applications/$PART_OF/templates/gateway.yaml is missing: the $PART_OF-gateway Application is never created, so the gateway is not deployed even though platform-$PART_OF-gateway exists. That is a prerequisite owned by another effort."
  fi
  if grep -q 'nameSuffix' "$APPS_DIR/templates/_application.tpl" 2>/dev/null; then
    pass "_application.tpl already supports nameSuffix"
  else
    warn "_application.tpl has no nameSuffix parameter yet; Phase 4 adds it"
  fi
else
  fail "argocd/applications/$PART_OF does not exist in $K8S_APPS"
fi

# ---------------------------------------------------------------------------
if [[ $SKIP_CLUSTER -eq 1 ]]; then
  section "Cluster checks skipped (--skip-cluster)"
else
  section "Shared gateway"

  # The target gateway is ALWAYS {partOf}-gateway in {partOf}-gateway-{stack},
  # from the platform-{partOf}-gateway repo. Do not infer the target from what
  # peers currently do: applications that migrated early may be parked on
  # another partOf's gateway as a temporary measure, and copying that would
  # propagate the temporary arrangement instead of completing the migration.
  # discover_gateway is therefore only a cross-check, never the authority.
  discover_gateway() {
    local ctx="$1" s="$2"
    kubectl --context "$ctx" get httproute -A -o json 2>/dev/null | jq -r --arg st "$s" --arg po "$PART_OF" '
      [ .items[] as $r
        | select($r.metadata.namespace | startswith($po + "-"))
        | select($r.metadata.namespace | endswith("-" + $st))
        | ( $r.spec.parentRefs[]?
            | select(.namespace != null)
            | select(.namespace != $r.metadata.namespace)
            | select(.namespace | test("-root-" + $st + "$") | not)
            | {gw: "\(.namespace)/\(.name)", ns: $r.metadata.namespace} ) ]
      | group_by(.gw)
      | map({gw: .[0].gw, n: ([.[].ns] | unique | length)})
      | map(select(.n >= 2))
      | sort_by(-.n)
      | .[0].gw // empty'
  }

  # Evaluate a Gateway allowedRoutes namespaceSelector against the exact label
  # set the new Application will stamp on its namespace. A selector that does
  # not match is the single most common reason a migrated route silently never
  # attaches, so this is a FAIL, not a warning.
  selector_admits() {
    local gw_json="$1" labels="$2"
    printf '%s' "$gw_json" | jq -e --argjson l "$labels" '
      def admits($labels):
        if . == null then true
        else
          (((.matchLabels // {}) | to_entries) | all(.value == $labels[.key]))
          and
          (((.matchExpressions // [])) | all(
            . as $e | ($labels[$e.key]) as $v |
            if   $e.operator == "In"           then ($v != null and ($e.values | index($v)) != null)
            elif $e.operator == "NotIn"        then ($v == null or  ($e.values | index($v)) == null)
            elif $e.operator == "Exists"       then ($v != null)
            elif $e.operator == "DoesNotExist" then ($v == null)
            else false end))
        end;
      [ .spec.listeners[]
        | (.allowedRoutes.namespaces.from // "Same") as $from
        | if   $from == "All"      then true
          elif $from == "Selector" then (.allowedRoutes.namespaces.selector | admits($l))
          else false end ]
      | any' >/dev/null 2>&1
  }

  host_matches() {
    # $1 listener hostname (may be empty or a leading wildcard), $2 candidate host
    local listener="$1" host="$2"
    [[ -z "$listener" || "$listener" == "null" ]] && return 0
    [[ "$listener" == "$host" ]] && return 0
    [[ "$listener" == \*.* && "$host" == *"${listener#\*}" ]] && return 0
    return 1
  }

  for s in "${STACKS[@]}"; do
    ctx="${STACK_CLUSTER[$s]}"
    new_host="$s.$APP.$HOST_SUFFIX"

    if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$ctx"; then
      fail "[$s] kube-context '$ctx' is not configured"
      continue
    fi

    if [[ -n "$GATEWAY_REF" ]]; then
      gw_ref="${GATEWAY_REF//\{stack\}/$s}"
    else
      gw_ref="$PART_OF-gateway-$s/$PART_OF-gateway"
    fi

    peer_ref="$(discover_gateway "$ctx" "$s")"
    if [[ -n "$peer_ref" && "$peer_ref" != "$gw_ref" ]]; then
      note "[$s] migrated peers currently attach to $peer_ref, not the target $gw_ref. That is transitional; migrate to the target, not to what peers happen to use."
    fi

    gw_ns="${gw_ref%%/*}"; gw_name="${gw_ref##*/}"
    if ! gw_json="$(kubectl --context "$ctx" -n "$gw_ns" get gateway "$gw_name" -o json 2>/dev/null)"; then
      fail "[$s] Gateway/$gw_name not found in namespace $gw_ns on $ctx: the shared gateway is not deployed for this stack, which is a prerequisite owned by another effort."
      continue
    fi
    pass "[$s] target gateway $gw_ref is deployed"

    matched=0
    while IFS= read -r listener_host; do
      host_matches "$listener_host" "$new_host" && { matched=1; break; }
    done < <(printf '%s' "$gw_json" | jq -r '.spec.listeners[] | .hostname // ""')
    if [[ $matched -eq 1 ]]; then
      pass "[$s] a listener accepts $new_host"
    else
      fail "[$s] no listener accepts $new_host; the new route would never attach"
    fi

    for c in "${COMPONENTS[@]}"; do
      ns_labels="$(jq -nc \
        --arg po "$PART_OF" --arg app "$APP" --arg c "$c" --arg st "$s" \
        '{"app.kubernetes.io/part-of":$po,"app.kubernetes.io/name":$app,"app.kubernetes.io/component":$c,"stack-name":$st,"istio.io/dataplane-mode":"ambient"}')"
      if selector_admits "$gw_json" "$ns_labels"; then
        pass "[$s] $gw_ref admits namespace $PART_OF-$APP-$c-$s"
      else
        sel="$(printf '%s' "$gw_json" | jq -c '[.spec.listeners[] | {from:(.allowedRoutes.namespaces.from // "Same"), selector:.allowedRoutes.namespaces.selector}]')"
        fail "[$s] $gw_ref will NOT admit namespace $PART_OF-$APP-$c-$s. allowedRoutes=$sel. The gateway owner must widen this before stack '$s' can be migrated."
      fi
    done

    if ! getent hosts "$new_host" >/dev/null 2>&1; then
      warn "[$s] $new_host does not resolve in DNS yet"
    else
      pass "[$s] $new_host resolves"
    fi
  done

  section "Legacy hostnames"
  for s in "${STACKS[@]}"; do
    legacy_values="${REPO_PATH[$LEGACY_REPO]}/argocd/root/values-$s.yaml"
    if [[ -f "$legacy_values" ]]; then
      host="$(cat "$legacy_values" | yq -r '.hostName // ""')"
      [[ -n "$host" && "$host" != "null" ]] \
        && pass "[$s] legacy host $host (carry this into values.$s.yaml at Phase 7)" \
        || warn "[$s] argocd/root/values-$s.yaml has no hostName"
    else
      warn "[$s] no argocd/root/values-$s.yaml: this stack has no legacy hostname or ALB and can only route via the shared gateway"
    fi
  done
fi

# ---------------------------------------------------------------------------
section "Summary"

printf 'MIGRATION_PART_OF=%q\n' "$PART_OF"
printf 'MIGRATION_APP=%q\n' "$APP"
printf 'MIGRATION_COMPONENTS=%q\n' "${COMPONENTS[*]}"
printf 'MIGRATION_LOW_TAG=%q\n' "${LOW_TAG[*]:-}"
printf 'MIGRATION_STACKS=%q\n' "${STACKS[*]}"
printf 'MIGRATION_SCRATCH=%q\n' "$SCRATCH"
printf 'MIGRATION_LEGACY_REPO=%q\n' "${REPO_PATH[$LEGACY_REPO]}"
printf 'MIGRATION_K8S_APPS=%q\n' "${REPO_PATH[$K8S_APPS]}"
for c in "${COMPONENTS[@]}"; do
  printf 'MIGRATION_PLATFORM_%s=%q\n' "${c^^}" "${REPO_PATH[platform-$PART_OF-$APP-$c]}"
  printf 'MIGRATION_CONTAINER_%s=%q\n' "${c^^}" "${REPO_PATH[container-$PART_OF-$APP-$c]}"
done

printf '\n'
if [[ $FAILURES -gt 0 ]]; then
  printf '%s%d failure(s), %d warning(s). Do not proceed.%s\n' "$C_RED" "$FAILURES" "$WARNINGS" "$C_RESET"
  exit 1
fi
printf '%sPreflight passed with %d warning(s).%s\n' "$C_GREEN" "$WARNINGS" "$C_RESET"
