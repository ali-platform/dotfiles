---
name: platform-repo-split
description: Migrate one application from the legacy shared platform repo (ArgoCD resources split between container repo and platform repo, deployed tags held in platform-k8s-apps) to per-component platform repos with a single flat argocd/ chart and a local version.{stack}.yaml, per ADR-010. Runs entirely inside a multi-root workspace that already contains the legacy platform repo, the new per-component platform repos, the container repos and platform-k8s-apps. Use when the user says "migrate {app} to per-component platform repos", "ADR-010 migration", "split the platform repo", "move {app} off platform-k8s-apps tags", or "run the platform repo split for {app}". Cuts over with zero downtime by standing up a shadow Application in a suffixed namespace, validating it live, and only then retiring the legacy Application. Fixes configuration, Pulumi and Kubernetes defects found on the way; never touches application source code.
---

# Platform repo split (ADR-010)

Migrate one application to per-component platform repos, one stack at a time, without
downtime.

**Reference material**, when the repo is available in the workspace:
`npm-ali-catalog/docs/design-decisions/ADR-010-*.md` and the pilot log
`npm-ali-catalog/migration/2026-08-31-osa-simulator.md`. This skill is self-contained; read
those only when something here is ambiguous.

## Scope

In scope: seeding the new platform repos, updating the container repos, cutting over in
`platform-k8s-apps`, verifying, and retiring the legacy component charts.

Out of scope, and must not be attempted:

- Catalog changes and repo provisioning. The new platform repos already exist.
- `argocd/root/` in the legacy platform repo. It stays there. It is not migrated.
- The gateway. It moves to a separate, already-created `platform-{partOf}-gateway` repo under
  its own effort. This skill only *references* whichever gateway a stack actually uses — which
  may belong to another `partOf` — and gates on it. Never edit it.
- Archiving the legacy platform repo. It survives as the root/shared repo.
- Any Pulumi state move.
- Any change to application source code.

## Non-negotiable rules

1. **Never read `.ali/projectInfo.json`.** It is deprecated and frozen at repo creation. All
   discovery comes from `argocd/values.yaml`, `platform-k8s-apps` values, and git remote names.
2. **The legacy platform repo is writable only under `docs/migration/**`.** Assert that
   `argocd/`, `components/` and `Pulumi.*` are unchanged at the end of every phase.
3. **Never edit `stacks[]`** in `platform-k8s-apps/argocd/projects/{partOf}/{app}/values.yaml`.
   It also drives `app-set-root.yaml` and the AppProject. Gate on a separate list instead.
4. **`preserveResourcesOnDeletion: true` lands in its own earlier PR**, never in the same PR
   that removes a component from the ApplicationSet. Legacy ApplicationSets carry
   `resources-finalizer.argocd.argoproj.io`; removing a component without preserving first
   cascade-deletes the live workload.
5. **One stack at a time.** Finish and bake a stack before starting the next.
6. **Green workflow does not mean the effect happened.** Verify the artefact: the file on the
   branch, the tag in the chart, the pod in the cluster.
7. **No force-push. No direct pushes to protected branches.** Changes land through PRs whose
   titles carry the Jira key. This includes `dev`: the new platform repos are branch-per-env
   with `dev` as the default branch, so all new work starts on a `{JIRA-KEY}-*` feature branch
   cut from `dev` and merges into `dev` by PR. `dev` is not a scratch branch.
8. **Never `pulumi stack export --show-secrets`.** Never commit a state backup.
9. **Fix-forward is limited to** `argocd/**`, `components/**`, `Pulumi.*.yaml` and
   `.github/workflows/**`. Anything wrong in `apps/**` or `src/**` becomes a Jira comment, not
   a commit.
10. **Baseline health may legitimately be Degraded.** Compare to the recorded snapshot, never
    to "Healthy".
11. **The `prod` stack is PR-only.** For `prod`, open the pull request and stop. Never merge
    it, never push to the `prod` branch, and never run a promotion into `prod`. Landing
    production change is a human decision outside this skill's scope. Leave the PR open, link
    it in the Jira issue and in the migration log, and hand it over explicitly. The same
    applies to any `platform-k8s-apps` PR whose effect is limited to `prod`.

## Environment traps

- `yq` and `aws` are snap-confined and **cannot read `/tmp`**. Use `~/.cache/ali-migration/`
  for scratch, and never pass a filename to `yq` — pipe into it:
  `cat f.yaml | yq '.x'`. `aws` needs `XDG_RUNTIME_DIR=/tmp/xdg-1000`.
- ArgoCD `Application` objects live on **`ali-k8s-prod`**, namespace `argo-cd`, regardless of
  which stack they deploy. Workloads live on `ali-k8s-dev` (dev, test), `ali-k8s-qa`
  (uat, stg) and `ali-k8s-prod` (prod).
- `workflow-repository-maintenance/shared-updates.yaml@v1` **skips all generation when
  `nx.json` exists and still exits 0**, so its "merge default branch into stack branches" step
  never runs. Propagate between stack branches with explicit PRs titled
  `Promote {from} to {to}`.
- **Branching model for the new platform repos.** Branch-per-env, `dev` is the default
  branch. New work: feature branch off `dev` → PR into `dev`. Promotion chain, strictly in
  order, one PR per hop: `dev → test → uat → stg → prod`. Never promote out of chain order
  and never open a hop before the previous one has merged and baked. Rule 11 stops the chain
  at the final hop: raise `Promote stg to prod` and leave it open.
- `container-v2-pull-request-checks.yaml` fails with "Nx wrote no status record" when
  `@acceleratelearning/nx-plugin` is older than `^0.5.40`, even though every target passed.

## What changes, conceptually

| | Legacy | New |
|---|---|---|
| Chart location | `container-*/argocd/{c}` **and** `platform-*/argocd/{c}` | `platform-*-{c}/argocd` only |
| Values file naming | `values-{stack}.yaml` | `values.{stack}.yaml` |
| ArgoCD `targetRevision` | a git tag on the container repo, held in `platform-k8s-apps` | the platform repo's **stack branch** |
| Deployed image | derived from that git tag | `version.{stack}.yaml` → `tag:`, a **container image tag** |
| Image ref in template | `{{ .Values.{c}.tag }}` | `{{ .Values.tag }}` |
| Autoscaling | `hpa.yaml` | `scaled-object.yaml` (KEDA) |
| ArgoCD wiring | `argocd/projects/{partOf}/{app}/templates/app-set-{c}.yaml` | `argocd/applications/{partOf}/templates/{app}-{c}.yaml` |

The old and new `tag` values mean **different things**. The legacy value is a git ref; the new
one is a container image tag. Never copy one into the other. Seed `version.{stack}.yaml` from
the live workload image.

## Phase 0 — Jira, preflight, branches

Compose the `jira-issue-workflow` skill for the Jira mechanics. One issue covers the whole
migration.

1. Fetch the issue, transition it to In Progress, and post the concrete plan for *this*
   application as a comment before writing any code.
2. Run the preflight:

   ```bash
   scripts/preflight.sh --application-name <app> [--search-root <dir>]...
   ```

   It resolves `partOf`, the component list and the stack list, locates all five repo roles,
   checks the toolchain, and gates on the shared gateway. It exits non-zero and explains
   itself if anything is missing. Do not proceed past a failure by working around it.
3. Create branch `{KEY}-{short-description}` in every repo the migration will write to: each
   new platform repo, each container repo, `platform-k8s-apps`, and the legacy repo (for the
   log only).
4. Start the migration log at `docs/migration/{YYYY-MM-DD}-{app}.md` in the **legacy** platform
   repo. Append to it at every phase boundary: what was done, what was observed, what was
   decided. It is the record for the next person.

   Give it a **Pull requests** table as its second section, and add every PR to it the moment
   it is opened — repo, number, base branch, title, link, state. A migration spans six repos
   and produces a long tail of promotion PRs; without one list nobody can tell what is
   outstanding, and the prod PRs that are deliberately left open look indistinguishable from
   ones that were forgotten. Mark those `OPEN — deliberate, do not merge`.

   Whenever the operator asks what has been raised, or at any phase boundary, list the PRs
   from the live source rather than from memory:

   ```bash
   gh pr list --search {KEY} --state all \
     --json number,title,url,baseRefName,state \
     --template '{{range .}}{{.state}}  #{{.number}}  {{.baseRefName}}  {{.title}}  {{.url}}{{"\n"}}{{end}}'
   ```

   Run it in each of the six repos; `gh` is scoped to the repo you are standing in. Reconcile
   the output against the table and correct the table, not the other way round. Repeat the
   list in the Jira issue at each phase boundary so the ticket alone is enough to hand over.

### What the preflight gates on, and why

- **All five repo roles present.** Legacy `platform-{partOf}-{app}`, one
  `platform-{partOf}-{app}-{c}` per component, one `container-{partOf}-{app}-{c}` per
  component, and `platform-k8s-apps`. A missing repo means a partial migration.
- **Clean working trees.** Uncommitted work will be mixed into generated diffs and lost.
- **Shared gateway reachable — per stack.** The target is always `Gateway/{partOf}-gateway` in
  namespace `{partOf}-gateway-{stack}`, from the `platform-{partOf}-gateway` repo, wired by
  `argocd/applications/{partOf}/templates/gateway.yaml` in `platform-k8s-apps`. It must exist
  on the stack's cluster, its listeners must accept the new hostname, and its `allowedRoutes`
  selector must admit the component namespace's labels. Without this the new route silently
  fails to attach and the shadow proves nothing.

**Do not infer the target gateway from what other applications currently do.** Applications
that migrated early are sometimes parked on another `partOf`'s gateway as a temporary measure
— `one-platform` apps sitting on `content-gateway`, for example, which that chart supports
through an explicit `allowedNamespacePartOf` allow-list. Copying that would propagate a
temporary arrangement instead of completing the migration. `preflight.sh` reports such peers
as a NOTE; treat it as information about the estate, never as the target.

Gateway readiness is **per stack, not per application**, because the gateway is rolled out
stack by stack by another effort. A stack whose gateway is not deployed, or whose selector
does not yet admit this `partOf`, is not migratable yet — migrate the ready stacks and stop at
the boundary. Do not edit the gateway to unblock yourself; raise it and wait.

If `argocd/applications/{partOf}/templates/gateway.yaml` does not exist, the gateway
Application is never created and the gateway is not deployed **even though the
`platform-{partOf}-gateway` repo exists and its Pulumi has run**. The repo existing is not
evidence that the gateway is deployed. Stop and raise it.

## Phase 1 — Snapshot

Nothing here is reversible without this. Do it for **every** component and **every** stack,
including the ones you believe are dead.

Per component per stack, on the ArgoCD cluster (`ali-k8s-prod`, ns `argo-cd`):

- the full `Application` spec
- sync status and health status, recorded **as found**

On the stack's workload cluster:

- `kubectl get all,httproute,authorizationpolicy,peerauthentication -n {ns}` inventory
- the running image, from
  `kubectl get deploy {app}-{c} -n {ns} -o jsonpath='{.spec.template.spec.containers[0].image}'`
  — the part after the last `:` is what seeds `version.{stack}.yaml`
- `HTTPRoute` status conditions (`Accepted`, `ResolvedRefs`) and the resolved parent
- restart counts per pod
- an HTTP response from the public hostname

Also back up Pulumi state for every stack. Enumerate stacks **from the backend**
(`pulumi stack ls`), not from the catalog or from the local `Pulumi.*.yaml` files — those
drift. Write backups under `~/.cache/ali-migration/`, never into a repo.

If `npm-ali-catalog` is in the workspace, use its
`migration/00-snapshot.sh` and `migration/00-pulumi-backup.sh` rather than reimplementing
this.

Record everything in the migration log. Expect to find stacks that are deployed but broken —
that is normal and is not something to fix silently.

## Phase 2 — Seed the new platform repos

One component at a time; components are independent and can run in parallel.

Work on the `dev` branch of the new platform repo, then propagate.

### 2a. Carry forward, verbatim

Commit 1 must be a faithful lift-and-shift so that the render diff is meaningful.

From `container-{partOf}-{app}-{c}/argocd/{c}/`:

- `templates/httproute.yaml` → `templates/{c}/http-route.yaml`
- `values.yaml` and `values-{stack}.yaml` → merged into `argocd/values.yaml` and
  `argocd/values.{stack}.yaml`

From `platform-{partOf}-{app}/argocd/{c}/`:

- `templates/parameters/*` → `templates/{c}/` (only present for some components)
- `values.yaml` → merged into `argocd/values.yaml`

Mechanical conversions, all of which are expected diffs:

- `values-{stack}.yaml` → `values.{stack}.yaml`
- `{{ .Values.{c}.tag }}` → `{{ .Values.tag }}`
- `hpa.yaml` → `scaled-object.yaml`, mapping `minReplicas`/`maxReplicas` and the CPU target
  onto the `scaledObject` block the generated chart already carries
- fill the `values.{stack}.yaml` files, which the generator leaves **empty**

Merge values with `yq ea` and pipe, never by filename:

```bash
cat a.yaml b.yaml | yq ea '. as $i ireduce ({}; . * $i)' -
```

Then gate:

```bash
scripts/render-diff.py --application-name <app> --component <c> --stack <stack>
```

Differences under `spec.template` or in routing are **blocking** — they mean the workload
would change. Everything else is reported for review. Resolve every blocking difference before
committing.

Expect the gate to surface at least these, because the generated chart cannot know about them:

- `ExternalSecret` and `SecretStore` from the legacy repo's `templates/parameters/` — carry
  them forward or the pod loses its configuration
- environment blocks the container chart injected from its own values, typically the
  `FEATURE_FLAGS_*` group — the generated deployment has no equivalent
- `HTTPRoute` — the generator emits no routing at all
- `AuthorizationPolicy/allow-gateway` replaced by `allow-gateway-to-service` — compare the two
  rather than assuming the rename is equivalent
- resource requests and probe settings that do not match the live workload
- `HorizontalPodAutoscaler` against `ScaledObject`, which is the one difference that is
  expected and correct

### 2b. Fix forward

Commit 2, separate and clearly labelled, so the neutrality proof from commit 1 stays readable.

**Routing must be values-driven.** The generator emits no routing at all, and hardcoding it
breaks both the shadow and any repo with a custom production hostname. Render `parentRefs`
from `.Values.gateways[]` and `hostnames` from `.Values.hostNames[]`:

```yaml
gateways:
  - name: "{partOf}-gateway"
    namespace: "{partOf}-gateway-{stack}"
    serviceAccount: "{partOf}-gateway-istio"
hostNames:
  - "{stack}.{app}.one.ali-apps.com"
```

The service account is Istio's, named after the **Gateway resource**, so it is
`{gatewayName}-istio`.

The legacy gateway and the legacy hostname are **deliberately absent** during the shadow phase
and are appended in Phase 7. The legacy hostname is whatever
`platform-{partOf}-{app}/argocd/root/values-{stack}.yaml` sets as `hostName`; some stacks have
no such file, and some production stacks use a custom hostname that does not follow the
pattern. Read it, do not derive it.

**The istio authorization policy must match the gateway list.** The generated
`templates/istio/allow-gateway-to-service.yaml` is wrong out of the box: it assumes the gateway
lives in `{partOf}-{app}-{stack}` with service account `{partOf}-{app}-istio`. Istio names the
gateway's service account after the **Gateway resource**, and the legacy gateway lives in the
root Application's namespace. Emit one principal per `.Values.gateways[]` entry:

```
cluster.local/ns/{{ .namespace }}/sa/{{ .serviceAccount }}
```

and set `ports` to the **container port**. ztunnel enforces on the container port; a mismatch
returns 503 with no useful error anywhere.

**Seed `version.{stack}.yaml`** from the live image tag captured in Phase 1. The generator
leaves `tag: 0.0.0`, which resolves to nothing.

Fix any other configuration, Pulumi or Kubernetes defect you find here — wrong ports, wrong
probe paths, resources that do not match the live workload, missing stack values. Record each
one in the log with what it was and why it was wrong. Anything in application source code goes
in a Jira comment instead.

### 2c. Propagate

Land the work on `dev` first: feature branch off `dev`, PR into `dev`. Then promote one hop at
a time with PRs titled `Promote {from} to {to}`, in order: `dev → test`, `test → uat`,
`uat → stg`, `stg → prod`. The maintenance workflow will not do this for you. Per rule 11 the
`Promote stg to prod` PR is opened and left open, never merged.

## Phase 3 — Container repos

Independent of Phase 2; can run in parallel.

1. Confirm the working tree is clean, then run `project-update` from the repo root.

   It resolves to
   `pnpm dlx --allow-build=nx @acceleratelearning/nx-generators@<latest> --tags config --execute`.
   Two behaviours matter:

   - Tag selection runs the matching generators **regardless of marker files**, and
     `container-workflows` writes with `OverwriteStrategy.Overwrite`. It *will* clobber hand
     edits to `.github/workflows/*`. This is why the tree must be clean first — the diff is
     your only record of what was destroyed.
   - The container generator registry emits **no argocd generators**, so `argocd/` is never
     recreated.

2. Review the resulting diff hunk by hunk. Revert anything under `apps/**` or `src/**`; only
   configuration is in scope.

3. The generated workflow set is `codeql`, `publish-container`, `pull-request-checks`,
   `repository-maintenance`, `slash-command-handlers`, `slash-commands`. It does **not** delete
   files it no longer owns. Delete any leftovers by hand, typically
   `container-slash-commands.yaml`, `promote-release.yaml` and
   `publish-container-dev-test.yaml`.

   The generated `publish-container.yaml` carries
   `with: argocd-application-name-root: {fullName}`. A repo already on v2 but missing that
   `with:` block has been **silently skipping ArgoCD promotion**; running `project-update` is
   the fix.

4. Bump `@acceleratelearning/nx-plugin` to `^0.5.40` or later.

5. Open the PR. **Leave `argocd/{c}/` in place.** It is dead code from the moment the platform
   repo owns the chart, but deleting it here would remove the legacy baseline while the
   migration still depends on it. Deletion is a Phase 9 step.

   Two things still need that folder. The render diff gates every Phase 2 commit against the
   legacy chart, and stays useful for re-verification right up to cutover. More importantly,
   rollback: the legacy Application deploys from a git tag, and tags are immutable, so an
   ordinary rollback is safe — but a rollback that also needs a *fix* means cutting a new
   legacy tag, and that is impossible if the chart is gone from the default branch.

   Do not fix defects found in `argocd/{c}/`. Record them in the log and in the Jira issue;
   the folder is deleted whole at the end, so patching it is churn that has to be reviewed.

## Phase 4 — `platform-k8s-apps`: prepare

One PR, no effect on any running workload. Verify that by rendering before and after.

**Add an optional `nameSuffix` to `argocd/applications/{partOf}/templates/_application.tpl`.**
The template derives the Application name, the destination namespace *and the repo URL* from a
single `$fullName`. The suffix must apply to `metadata.name` and `destination.namespace` only —
applying it to the repo URL would point at a repository that does not exist.

Default it to the empty string and prove the change is inert:

```bash
helm template argocd/applications/{partOf} > after.yaml   # for every partOf, not just yours
```

must be byte-identical to the same render before the change.

**Set `preserveResourcesOnDeletion: true`** on the legacy component ApplicationSets, at
`spec.syncPolicy` on the ApplicationSet itself — not inside `spec.template.spec.syncPolicy`,
which is the Application's own sync policy and does something else entirely. This is what makes
Phase 7 safe.

## Phase 5 — `platform-k8s-apps`: shadow

### Register the new hostname with the gateway first

The shared gateway's chart derives its TLS certificate `dnsNames` — and the DNS record and ALB
listener behind it — from its own `hostNames` list. A gateway listener with no `hostname:` will
happily *accept* a route for `{stack}.{app}.one.ali-apps.com`, so the route reports
`Accepted=True` and everything looks correct, while the name has no certificate and does not
resolve. The shadow then proves nothing.

So before shadowing a stack, raise a PR against `platform-{partOf}-gateway` adding the new
hostname to `argocd/values.{stack}.yaml`:

```yaml
gateways:
  - gatewayName: {partOf}-gateway
    hostNames:
      - "{stack}.{app}.one.ali-apps.com"
```

Note this file uses `gatewayName`, not `name`. This is the one sanctioned change to the
gateway repo; it is additive registration, not configuration of someone else's gateway. Wait
for it to sync and for the name to resolve — `preflight.sh` warns `does not resolve in DNS
yet` until it does — before trusting any shadow result.

**Register the legacy hostname there too.** At cutover the new gateway serves the legacy
hostname as well, and it needs a certificate for it. The listener has no `hostname:` so it
will accept the legacy host regardless, and the route will report `Accepted=True`, but TLS
will fail. Register both names up front:

```yaml
      - "{stack}.{app}.one.ali-apps.com"
      - "<hostName from the legacy root values file>"
```

Add a shadow Application per component per stack, gated to one stack at a time:

```yaml
{{- include "ali-platform.application" (dict
  "root" .
  "applicationName" "{app}"
  "componentName" "{c}"
  "nameSuffix" "-next"
) -}}
```

That produces Application and namespace `{partOf}-{app}-{c}-next-{stack}`, sourced from the
correct `platform-{partOf}-{app}-{c}` repo on its stack branch, containing resources still
named `{app}-{c}` on their normal ports and paths. The legacy Application is untouched.

**Skip Phases 4 through 6 only for a component with no live workload.** Decide this from the
cluster, never from the declared tag. `v0.0.0` is a real, resolvable git tag: a component
pinned to it in every stack is usually deployed and Healthy, running an image tagged `0.0.0`.
Treating that as "never deployed" would take a live workload straight to canonical with no
shadow and no baseline — the exact downtime this skill exists to avoid. The test is whether
the Phase 1 snapshot found a Deployment and running pods.

## Phase 6 — Validate the shadow

Against the Phase 1 snapshot, for the stack being migrated:

- The shadow Application is Synced and Healthy.
- The running image tag equals `version.{stack}.yaml`.
- The `HTTPRoute` reports `Accepted=True` and `ResolvedRefs=True`, with the shared gateway as
  the resolved parent.
- The new hostname returns the expected response, served by pods in the shadow namespace.
- **The legacy namespace is unchanged**: same ReplicaSet, same pod names, same restart counts,
  same Service ClusterIP as the snapshot. Any change here means the shadow is interfering and
  must be rolled back immediately.
- The legacy hostname still serves traffic.

Let it bake. Do not proceed on the strength of a green sync alone.

## Phase 7 — Cut over

Two changes, in this order, in one window per stack.

First, on the platform repo's stack branch, append the legacy gateway and the legacy hostname
to `values.{stack}.yaml`, so the canonical Application will serve both hostnames:

```yaml
gateways:
  - name: "{partOf}-gateway"
    namespace: "{partOf}-gateway-{stack}"
    serviceAccount: "{partOf}-gateway-istio"
  - name: "{app}"
    namespace: "{partOf}-{app}-root-{stack}"
    serviceAccount: "{app}-istio"
hostNames:
  - "{stack}.{app}.one.ali-apps.com"
  - "<hostName from the legacy root values file>"
```

Serving both hostnames from both gateways is the whole point of the cutover: it is what lets
DNS move without a break. This dual-host, dual-gateway shape is exactly what the already
migrated applications run in production today.

Then one atomic `platform-k8s-apps` PR that does all three of:

- removes this stack from the legacy component ApplicationSet's stack gate,
- removes the shadow Application,
- adds the canonical Application (no `nameSuffix`).

All three must land together. The canonical Application has the same name and the same
destination namespace as the legacy one, so they cannot coexist; and leaving the shadow up
alongside the canonical would put two routes with the same hostname and path on the same
gateway.

Because Phase 4 set `preserveResourcesOnDeletion`, the workload in the canonical namespace
survives the legacy Application's removal and is adopted by the canonical Application through
`ServerSideApply`. If the render is neutral, no pod restarts.

**For `prod`, both of these are prepared as pull requests and left open.** Do not merge the
platform repo PR, do not merge the `platform-k8s-apps` PR, and do not move DNS. Because the
two must land together in one window, sequencing them is the reviewer's call, not this
skill's. Record both PR links in the migration log and the Jira issue, state plainly that
production is not cut over, and stop.

## Phase 8 — Verify and bake

- No new ReplicaSet in the canonical namespace: `kubectl get rs -n {ns}` matches the snapshot.
- The canonical Application is Synced and Healthy.
- Both hostnames serve.
- The root Application is still Synced.
- `update-tag.yaml` round-trips: a container publish writes the new tag into
  `version.{stack}.yaml` and ArgoCD deploys it.

Delete the shadow namespace if it lingers. Update the log. Then start the next stack.

## Phase 9 — Decommission

Once every stack of every component has cut over and baked:

- Delete `argocd/projects/{partOf}/{app}/templates/app-set-{c}.yaml` for each migrated
  component, and remove the now-unused `{stack}.{c}` tag keys from that project's `values.yaml`.
  Leave `app-set-root.yaml`, the AppProject and `stacks[]` alone.
- Delete `argocd/{c}/` from each container repo, in its own commit. This is the last step that
  can be taken, because until it happens a legacy tag can still be cut for a rollback that
  needs a fix. Any defect recorded against that folder earlier in the migration is resolved by
  the deletion rather than by a patch.
- Merge the container repo PRs if they are still open.
- Confirm `argocd/root/` and the legacy platform repo are untouched outside `docs/migration/`.
- Post a summary comment on the Jira issue listing every defect found and fixed, and every
  application-level issue that was found but deliberately not fixed. Transition the issue to
  Done.

## Rollback

Per stack, at any point before Phase 7 the migration is free: delete the shadow Application and
nothing else has changed.

After Phase 7, revert the `platform-k8s-apps` PR. The legacy ApplicationSet is restored and
adopts the preserved resources back. The platform repo and container repo changes are inert
without the k8s-apps wiring, so they can stay.

The dangerous window is Phase 7 itself. Do not start it without the Phase 1 snapshot in hand
and `preserveResourcesOnDeletion` already merged and synced.
