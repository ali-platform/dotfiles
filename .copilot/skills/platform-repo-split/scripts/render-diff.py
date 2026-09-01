#!/usr/bin/env python3
"""Compare the legacy two-source ArgoCD render against the new flat platform chart.

The legacy composition is `container-<partOf>-<app>-<component>/argocd/<component>` plus
`platform-<partOf>-<app>/argocd/<component>`. The new one is
`platform-<partOf>-<app>-<component>/argocd`. Phase 2a of the migration is only a faithful
lift-and-shift if the two renders agree everywhere that matters.

Differences are bucketed. BLOCKING differences change the running workload or its routing and
must be resolved before committing. REPORT differences are expected consequences of the
migration and are printed for review.
"""

from __future__ import annotations

import argparse
import difflib
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install --user pyyaml")

# Kinds whose spec drives the running pods or the request path.
BLOCKING_KINDS = {
    "Deployment",
    "StatefulSet",
    "Service",
    "HTTPRoute",
    "AuthorizationPolicy",
    "PeerAuthentication",
    "ServiceAccount",
    "ExternalSecret",
    "SecretStore",
    "ConfigMap",
    "Secret",
}

# The image tag moves from a git ref to a container image tag, so this label legitimately differs.
VOLATILE_LABELS = {"app.kubernetes.io/version", "helm.sh/chart"}


def helm_template(chart: Path, release: str, namespace: str, value_files, sets) -> list[dict]:
    if not chart.is_dir():
        raise SystemExit(f"chart directory not found: {chart}")
    cmd = ["helm", "template", release, str(chart), "--namespace", namespace]
    for vf in value_files:
        path = chart / vf
        if path.is_file() and path.stat().st_size > 0:
            cmd += ["-f", str(path)]
    for key, value in sets.items():
        cmd += ["--set-string", f"{key}={value}"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"helm template failed for {chart}:\n{result.stderr.strip()}")
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def resource_key(doc: dict) -> str:
    meta = doc.get("metadata") or {}
    return f"{doc.get('kind', '?')}/{meta.get('name', '?')}"


def normalise(doc: dict) -> dict:
    doc = yaml.safe_load(yaml.safe_dump(doc))

    def strip(node):
        if isinstance(node, dict):
            for scope in ("labels", "annotations"):
                if isinstance(node.get(scope), dict):
                    for label in VOLATILE_LABELS:
                        node[scope].pop(label, None)
            for value in node.values():
                strip(value)
        elif isinstance(node, list):
            for value in node:
                strip(value)

    strip(doc)
    # helm injects the release namespace inconsistently between charts; the Application owns it.
    doc.setdefault("metadata", {}).pop("namespace", None)
    for field in ("creationTimestamp", "status"):
        doc.pop(field, None)
    return doc


def render_text(doc: dict) -> list[str]:
    return yaml.safe_dump(doc, default_flow_style=False, sort_keys=True).splitlines(keepends=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--part-of", required=True)
    parser.add_argument("--application-name", required=True)
    parser.add_argument("--component", required=True)
    parser.add_argument("--stack", required=True)
    parser.add_argument("--container-repo", required=True, type=Path)
    parser.add_argument("--legacy-repo", required=True, type=Path)
    parser.add_argument("--new-repo", required=True, type=Path)
    parser.add_argument("--cluster", default="ali-k8s-dev", help="k8sClusterAccountName for this stack")
    parser.add_argument("--account-name", default="")
    parser.add_argument("--account-id", default="")
    parser.add_argument("--region", default="us-east-2")
    args = parser.parse_args()

    full_name = f"{args.part_of}-{args.application_name}-{args.component}"
    namespace = f"{full_name}-{args.stack}"

    # Mirrors the valuesObject each ApplicationSet / Application injects.
    legacy_sets = {
        "stackName": args.stack,
        "server": "https://kubernetes.default.svc",
        "accountName": args.account_name,
        "accountId": args.account_id,
        "k8sClusterAccountName": args.cluster,
        "k8sClusterAccountId": args.account_id,
        "wafRegionalArn": "",
        "region": args.region,
        "targetRevision": "render-diff",
    }
    new_sets = {
        "stackName": args.stack,
        "accountName": args.account_name,
        "accountId": args.account_id,
        "k8sClusterAccountName": args.cluster,
        "k8sClusterAccountId": args.account_id,
        "region": args.region,
    }

    legacy_docs: list[dict] = []
    legacy_docs += helm_template(
        args.container_repo / "argocd" / args.component,
        namespace,
        namespace,
        [f"values.{args.stack}.yaml", f"values-{args.stack}.yaml"],
        legacy_sets,
    )
    legacy_docs += helm_template(
        args.legacy_repo / "argocd" / args.component,
        namespace,
        namespace,
        [f"values.{args.stack}.yaml", f"values-{args.stack}.yaml"],
        legacy_sets,
    )
    new_docs = helm_template(
        args.new_repo / "argocd",
        namespace,
        namespace,
        [f"values.{args.stack}.yaml", f"version.{args.stack}.yaml"],
        new_sets,
    )

    legacy = {resource_key(d): normalise(d) for d in legacy_docs}
    new = {resource_key(d): normalise(d) for d in new_docs}

    blocking: list[str] = []
    report: list[str] = []

    def bucket(key: str) -> list[str]:
        kind = key.split("/", 1)[0]
        return blocking if kind in BLOCKING_KINDS else report

    for key in sorted(set(legacy) | set(new)):
        if key not in new:
            bucket(key).append(f"{key}: present in the legacy render, missing from the new chart")
            continue
        if key not in legacy:
            bucket(key).append(f"{key}: new in the platform chart, absent from the legacy render")
            continue
        diff = list(
            difflib.unified_diff(
                render_text(legacy[key]), render_text(new[key]), fromfile=f"legacy {key}", tofile=f"new {key}"
            )
        )
        if diff:
            bucket(key).append(f"{key}:\n" + "".join("    " + line for line in diff))

    print(f"== {full_name} / {args.stack} ==")
    print(f"legacy render: {len(legacy)} resource(s)   new render: {len(new)} resource(s)\n")

    if report:
        print("REPORT — review, then accept or fix:")
        for entry in report:
            print(f"  {entry}")
        print()

    if blocking:
        print("BLOCKING — these change the workload or its routing:")
        for entry in blocking:
            print(f"  {entry}")
        print("\nResolve every blocking difference before committing Phase 2a.")
        return 1

    print("No blocking differences. The carry-forward is neutral for this stack.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
