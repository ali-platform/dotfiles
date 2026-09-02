---
name: platform-repo-split
description: Migrate one application from the legacy shared platform repo (ArgoCD resources split between container repo and platform repo, deployed tags held in platform-k8s-apps) to per-component platform repos with a single flat argocd/ chart and a local version.{stack}.yaml, per ADR-010. Runs entirely inside a multi-root workspace that already contains the legacy platform repo, the new per-component platform repos, the container repos and platform-k8s-apps. Use when the user says "migrate {app} to per-component platform repos", "ADR-010 migration", "split the platform repo", "move {app} off platform-k8s-apps tags", or "run the platform repo split for {app}". Cuts over with zero downtime by making the new chart render exactly what is already running, then swapping the ArgoCD Application over so the live workload is adopted rather than replaced. Moves the component's Pulumi resources into the new project by state surgery, so ownership changes without creating or destroying any AWS resource. Fixes configuration, Pulumi and Kubernetes defects found on the way; never touches application source code.
---

# Platform repo split (ADR-010)

Migrate one application to per-component platform repos, one stack at a time, without
downtime.

**Reference material**, when the repo is available in the workspace:
`npm-ali-catalog/docs/design-decisions/ADR-010-*.md` and the pilot log
`npm-ali-catalog/migration/2026-08-31-osa-simulator.md`. This skill is self-contained; read
those only when something here is ambiguous.

## Scope

In scope: seeding the new platform repos, updating the container repos, moving the component's
Pulumi resources out of the legacy project into the new one, cutting over in
`platform-k8s-apps`, verifying, and retiring the legacy component charts.

Out of scope, and must not be attempted:

- Catalog changes and repo provisioning. The new platform repos already exist.
- `argocd/root/` in the legacy platform repo. It stays there. It is not migrated.
- The gateway. It moves to a separate, already-created `platform-{partOf}-gateway` repo under
  its own effort. This skill only *references* whichever gateway a stack actually uses — which
  may belong to another `partOf` — and gates on it. Never edit it.
- Archiving the legacy platform repo. It survives as the root/shared repo.
- Everything `components/root/` creates: the RDS cluster with its instances and its
  parameter, subnet and security groups; the `postgresql-*` SSM parameters and IAM policies;
  the account-sync role; the ACM certificate and its Route53 records. Those are shared across
  components and stay in the legacy Pulumi project permanently.
- Any change to application source code.

## Non-negotiable rules

1. **Never read `.ali/projectInfo.json`.** It is deprecated and frozen at repo creation. All
   discovery comes from `argocd/values.yaml`, `platform-k8s-apps` values, and git remote names.
2. **The legacy platform repo is writable under `docs/migration/**`, `components/{c}/`,
   `components/index.ts`, `index.ts` and `Pulumi.*.yaml`** — the last four only to hand the
   component's Pulumi resources over in Phase 5. `argocd/` and `components/root/` are never
   touched. Assert that at the end of every phase.
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
12. **A Pulumi move must not create or destroy anything in AWS.** Move state; never re-create.
    `pulumi preview` in both projects must come back with no creates, no deletes and no
    replaces before the move is called done. The only accepted diffs are the `pulumi-repo`
    and `pulumi-project` default tags, which necessarily change with the owning repository.
13. **Never `pulumi destroy`. Never remove code from a project whose state still holds the
    resources.** A resource in state but absent from the program is a delete on the next
    `pulumi up`. State always leaves the old stack *before* the code does.
14. **Move by transplanting state, not by `pulumi import`.** Import resolves by name, and
    names are not unique here: stacks sharing an AWS account carry identically named
    AppConfig Applications. It also cannot cleanly reconstruct `ali:pulumi:AssumableRole`,
    which is a component resource with children rather than a cloud resource with an ID.
    Only moving the existing state entries preserves physical IDs unambiguously. Note this
    cannot be done with the `pulumi state move` command — see Phase 5.
15. **One PR chain per repo, not one PR per phase.** A new platform repo's PR carries the
    `argocd/` chart and the Pulumi program together; the legacy repo's PR is the matching
    removal. Everything above `dev` is then a promotion of that same chain.
16. **Always include the URL when asking for action on a pull request.** Any time the user is
    asked to review, approve, merge, close or look at a PR, give the full
    `https://github.com/{owner}/{repo}/pull/{n}` link alongside the number. A bare "#3" is
    ambiguous across five repos that all number their PRs from 1. The same applies in Jira
    comments and in the migration log. `gh pr list --json number,title,url,baseRefName,state`
    already returns `url` — use it rather than reconstructing the link by hand.

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
- **`pulumi-up-{stack}.yaml` runs on a daily `0 11 * * *` cron**, in the legacy repo and in
  every new platform repo, on top of push-to-stack-branch. The cron ignores the
  `paths-ignore` list that spares `argocd/**`. So a mismatch between Pulumi code and Pulumi
  state is not a problem that waits for your next push — it has a deadline of the next 11:00
  UTC. Never leave a state move half-finished overnight.
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
| Autoscaling | `hpa.yaml` in the container repo | `hpa.yaml`, carried across unchanged |
| ArgoCD wiring | `argocd/projects/{partOf}/{app}/templates/app-set-{c}.yaml` | `argocd/applications/{partOf}/templates/{app}-{c}.yaml` |
| Pulumi ownership | one stack per application, every component in `platform-{partOf}-{app}` | one stack per component, in `platform-{partOf}-{app}-{c}`; shared resources stay behind |

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
4. Start the migration log as a **directory** at `docs/migration/{YYYY-MM-DD}-{app}/` in the
   **legacy** platform repo, with `000-overview.md` holding only the facts that are fixed at
   the start: the migration variables, the repo roles, the stack list, the Phase 1 snapshot.

   Every later entry is a **new file**, never an edit to an existing one:

   ```
   docs/migration/2026-09-01-reference/
     000-overview.md
     010-preflight.md
     020-snapshot.md
     030-chart-parity.md
     040-pulumi-move-dev.md
   ```

   Number in tens so an entry can be slotted in later without renumbering. One entry per
   phase boundary or per decision: what was done, what was observed, what was decided.

   **The reason is merge conflicts.** A migration spans six repos, five stacks and a long tail
   of promotion PRs, many of them open at once against different branches. A single log file
   is touched by all of them, so every promotion PR conflicts with every other one on that
   file, and resolving those conflicts by hand is where log content gets silently dropped.
   Append-only files in a directory never conflict.

   For the same reason, **do not maintain a table of pull requests in the log.** It is the
   single most conflict-prone thing that could be put there, and it goes stale the moment
   someone merges without updating it. Each entry records the PRs *it* opened, as a fact about
   that step. The live list comes from the source of truth on demand:

   ```bash
   gh pr list --search {KEY} --state all \
     --json number,title,url,baseRefName,state \
     --template '{{range .}}{{.state}}  #{{.number}}  {{.baseRefName}}  {{.title}}  {{.url}}{{"\n"}}{{end}}'
   ```

   Run that whenever the operator asks what has been raised, and at every phase boundary.
   Production PRs are deliberately left open, so call those out explicitly each time — an
   unexplained open prod PR is indistinguishable from one that was forgotten.

   Run it in each of the six repos; `gh` is scoped to the repo you are standing in. Reconcile
   the output against the table and correct the table, not the other way round. Repeat the
   list in the Jira issue at each phase boundary so the ticket alone is enough to hand over.

### What the preflight gates on, and why

- **All five repo roles present.** Legacy `platform-{partOf}-{app}`, one
  `platform-{partOf}-{app}-{c}` per component, one `container-{partOf}-{app}-{c}` per
  component, and `platform-k8s-apps`. A missing repo means a partial migration.
- **Clean working trees.** Uncommitted work will be mixed into generated diffs and lost.
- **The application's current gateway — per stack.** Read it from the live `HTTPRoute`, not
  from the scaffold. The workload stays on whatever gateway serves it today, which is usually
  `Gateway/{app}` in `{partOf}-{app}-root-{stack}`, owned by the legacy root chart. The shared
  `Gateway/{partOf}-gateway` in `{partOf}-gateway-{stack}` is where applications end up
  *eventually*, but moving there is a separate change with its own certificate and DNS work.
  If that move is ever in scope, the shared gateway's listeners must accept the new hostname
  and its `allowedRoutes` selector must admit the component namespace's labels, or the route
  silently fails to attach.

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

Mechanical conversions, and this is the entire list:

- **`values-{stack}.yaml` → `values.{stack}.yaml`.** Hyphen to dot, every stack, in both the
  component chart and anything that references it. The new chart resolves per-stack values by
  the dotted name; a file left as `values-dev.yaml` is simply never loaded, and the render
  silently falls back to `values.yaml` defaults.
- `{{ .Values.{c}.tag }}` → `{{ .Values.tag }}`, fed from `version.{stack}.yaml`

**The generated chart's own opinions are not the target.** It is a generic scaffold, and every
place it differs from the old chart is a change you would be shipping under cover of a
migration. Where they disagree, the old chart wins.

Merge values with `yq ea` and pipe, never by filename:

```bash
cat a.yaml b.yaml | yq ea '. as $i ireduce ({}; . * $i)' -
```

### The gate: byte-parity with the old chart, tag excluded

The new chart must render **byte-identical** to the old chart in every stack, with the
container image tag and the `app.kubernetes.io/version` label as the only permitted
differences. That is the entire contract of this migration: ownership moves, tag resolution
moves, nothing else changes.

**The old chart lives in two repositories.** Rendering only the container half silently omits
whatever the legacy platform repo contributed — typically the istio policies and the
parameter-store resources — and the diff then looks clean while the workload would lose half
its objects. Concatenate both renders before comparing:

```bash
helm template x container-{partOf}-{app}-{c}/argocd/{c} \
  -f .../values.yaml -f .../values-{stack}.yaml --set stackName={stack} >  old.yaml
helm template x platform-{partOf}-{app}/argocd/{c} \
  -f .../values.yaml --set stackName={stack}                            >> old.yaml
```

Compare resource by resource keyed on `(kind, metadata.name)`, never as a text diff — a
renamed resource is a delete plus a create, and a text diff buries that as a pair of unrelated
hunks. **Fail loudly if `helm template` errors.** Redirecting stderr into the render file turns
a template failure into an unparseable document, and a comparison that swallows it will report
"no differences" for a chart that does not render at all.

**Every live stack must be diffed.** A stack whose `values-{stack}.yaml` is missing from the
old chart cannot be rendered, and a stack that cannot be rendered cannot be verified. That is a
gap in the legacy repo, not a stack to skip: the workload is running, so the values it is
running on exist somewhere. Restore the file before diffing.

Known scaffold deviations, all of which are reverted:

| Scaffold emits | Old chart has | Why it matters |
|---|---|---|
| `ScaledObject` (KEDA) | `HorizontalPodAutoscaler` | a different controller takes over replicas |
| `allow-gateway-to-service` with `principals:` | `allow-gateway` with `namespaces:` | the rename is a delete plus a create, and the match mechanism differs |
| shared `{partOf}-gateway` plus `hostnames:` | the app's own gateway in `{partOf}-{app}-root-{stack}`, no `hostnames` | detaches the workload from the gateway actually serving it |
| no `metadata.namespace` on istio objects | explicit `metadata.namespace` | cosmetic under ArgoCD, still a diff |
| `.Values.scaledObject.*` guards | `.Values.hpa.*` | left dangling when the HPA is restored, and renders nil |

The last one bites twice: the same guard also wraps `topologySpreadConstraints` in
`deployment.yaml`, far away from the autoscaler template, so restoring the HPA without fixing
it there fails the render.

Once the old chart is reproduced, the per-stack values files usually have **nothing left in
them** — every name derives from `partOf`, `applicationName`, `componentName` and `stackName`.
An empty `values.{stack}.yaml` is the correct outcome, not a sign that something was missed.

Also expect to carry forward, because the scaffold cannot know about them:

- `ExternalSecret` and `SecretStore` from the legacy repo's `templates/parameters/` — without
  them the pod loses its configuration
- environment blocks the container chart injected from its own values, typically the
  `FEATURE_FLAGS_*` group
- `HTTPRoute` — the scaffold emits routing, but not the routing this application uses

Some live objects belong to neither chart. If the old render does not produce them and the
namespace has them anyway — an image-pull `ExternalSecret`, an injected ConfigMap — they are
provisioned elsewhere and are not yours to reproduce.

### 2b. Fix forward

Commit 2, separate and clearly labelled, so the neutrality proof from commit 1 stays readable.

**Routing is reproduced, not redesigned.** Whatever gateway the application is on today is the
gateway it stays on. Read the parent from the old chart's `httproute.yaml` — typically the
Gateway named after the application, in `{partOf}-{app}-root-{stack}` — and carry the path
match across unchanged. Do not add `hostnames` the old chart did not set: an absent
`hostnames` matches every host the gateway serves, and replacing it with a list silently drops
every name not on that list.

**The istio authorization policy must match.** Whichever form the old chart used — a
`namespaces:` source naming the root namespace, or `principals:` naming the gateway's service
account — is the form to keep. Istio names a gateway's service account after the **Gateway
resource**, so it is `{gatewayName}-istio`, not `{partOf}-{app}-istio`. Set `ports` to the
**container port**: ztunnel enforces on the container port, and a mismatch returns 503 with no
useful error anywhere.

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

While the chart is all that has moved these promotions are inert twice over: nothing consumes
the stack branches until Phase 6, and `pulumi-up-{stack}.yaml` lists `argocd/**` in its
`paths-ignore`. That stops being true the moment Phase 5 puts Pulumi code in the repo — from
then on, merging a promotion PR runs `pulumi up` against that stack. Finish the chart-only
promotions before starting Phase 5.

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
   migration still depends on it. Deletion is a Phase 8 step.

   Two things still need that folder. The render diff gates every Phase 2 commit against the
   legacy chart, and stays useful for re-verification right up to cutover. More importantly,
   rollback: the legacy Application deploys from a git tag, and tags are immutable, so an
   ordinary rollback is safe — but a rollback that also needs a *fix* means cutting a new
   legacy tag, and that is impossible if the chart is gone from the default branch.

   Do not fix defects found in `argocd/{c}/`. Record them in the log and in the Jira issue;
   the folder is deleted whole at the end, so patching it is churn that has to be reviewed.

## Phase 4 — `platform-k8s-apps`: prepare

One PR, no effect on any running workload.

**Set `preserveResourcesOnDeletion: true`** on the legacy component ApplicationSets, at
`spec.syncPolicy` on the ApplicationSet itself — not inside `spec.template.spec.syncPolicy`,
which is the Application's own sync policy and does something else entirely. This is what makes
Phase 6 safe: it lets the legacy Application be removed while its workload keeps running, so
the new Application can adopt the objects instead of recreating them.

Prove the change is inert by rendering `argocd/applications/{partOf}` before and after. The
only difference should be the added sync policy.

## Phase 5 — Move the component's Pulumi resources

Per stack, before that stack's ArgoCD switch. The goal is a change of ownership with no
change in AWS: the same roles, the same AppConfig application, the same physical IDs, managed
by a different Pulumi project.

### What moves and what stays

Read the legacy stack's state and classify every resource in it. For a component `{c}`:

| Moves to `platform-{partOf}-{app}-{c}` | Stays in the legacy project |
|---|---|
| `k8s-app-{partOf}-{app}-{c}-{stack}` AssumableRole, its Role and RolePolicy | RDS cluster, instances, parameter/subnet/security groups |
| `eso-{partOf}-{app}-{c}-{stack}` AssumableRole, its Role and RolePolicy | `postgresql-connection-info*` SSM parameters |
| the component's AppConfig Application, Environment, ConfigurationProfile, DeploymentStrategy | `postgresql-policy-{c}` IAM policy |
| `{c}-rds-policy-attachment` RolePolicyAttachment | account-sync role, ACM certificate, Route53 records |

Anything `components/root/` creates stays, **even when its name carries the component's name**.
`postgresql-policy-{c}` is a root resource parameterised by account; the attachment binding it
to the component's role is not.

### The identical names are the point

The scaffolded `components/roles.ts` in the new repo derives its names from `partOf`,
`applicationName` and `componentName` exactly as the legacy code does, so it generates role
names, namespaces and service accounts byte-identical to the ones already deployed. That is
precisely what makes the move invisible: the workload stays in the same namespace under the
same service account, so the existing OIDC trust policy keeps working untouched. Do not create
parallel roles, and do not edit any trust policy.

The trust policy only becomes a problem in a variant of this migration that moves the workload
to a different namespace, because `k8s-app-*` is an OIDC condition on
`system:serviceaccount:{namespace}:{serviceAccount}`. `eso-*` would still be fine even then:
it is assumed by the cluster's `k8s-external-secrets` role and scoped by SSM parameter path,
with no namespace in it.

### The attachment to the root-owned policy

`{c}-rds-policy-attachment` binds a role that moves to a policy that stays, so the new project
needs that policy's ARN. It does not need a `StackReference` to get it. The root component
gives the policy an explicit `name`, so there is no auto-naming suffix and the ARN is
derivable from config the new stack already holds:

```
arn:aws:iam::{accountId}:policy/{partOf}-{applicationName}-pg-{stackName}-account-{componentName}
```

Check the constructed ARN against the live policy before relying on it. This is a naming
convention rather than a contract, but it fails loudly with `NoSuchEntity` rather than
silently, and it keeps the legacy change to a pure removal with no stack outputs and no
ordering dependency between the two repos.

### `pulumi state move` does not work here

Each per-component repo has its own DIY backend, a sibling of the legacy one:

```
s3://ali-pulumi/{org}/platform-{partOf}-{app}?region=us-east-2
s3://ali-pulumi/{org}/platform-{partOf}-{app}-{c}?region=us-east-2
```

Each is a self-contained `.pulumi/` root with no common parent, and `--dest` resolves only
within the current backend. `pulumi stack ls` from the legacy repo cannot even see the
component stacks. So the move is export, transplant, import — `scripts/build-move.py` does the
transplant. Do not repoint a component repo's backend at the legacy one to make `state move`
work; that defeats the split.

### Three things the transplant has to fix

The script handles all three. They are listed because each one fails in a way that invites a
wrong fix.

**The provider.** An empty destination stack has no provider, so the legacy default `aws`
provider is carried across with its URN rewritten. Its inputs name the legacy `ghr-*` assume
role and the legacy repo URL, so they must be retargeted at the destination repo too.
Otherwise the first `pulumi up` re-registers the default provider with different inputs and
every moved resource shows a provider diff.

**The secrets envelope.** The import fails with `could not deserialize deployment: cipher:
message authentication failed`. Each stack seals state with its own data key, and the moved
ciphertext was sealed with the legacy stack's. Both stacks wrap their key with the *same* KMS
master key, so carrying the legacy `secrets_providers` block into the artifact is sufficient;
the next update re-seals with the destination's own key. Verify the two `state.url` values
match before relying on this.

**Edges that cross the boundary.** `{c}-rds-policy-attachment` records a dependency on
`postgresql-policy-{c}`, which stays behind. The import refuses with `refers to missing
resource` and offers `--force`. Do not use `--force` — drop the edge. The destination program
builds that ARN as a string and genuinely has no dependency on it, so dropping it makes the
state match the program.

### One window per stack

Merging a PR into branch `{stack}` is what runs `pulumi up` for that stack, so the merges and
the state surgery interleave. Split the move into its two halves and merge between them —
that is what keeps the dangerous window short. Per stack, in order, in one sitting:

1. Back up all three stack states under `~/.cache/ali-migration/`. Never into a repo.
2. `pulumi preview` all three and check the arithmetic: the legacy deletes must equal the sum
   of the component creates, URN for URN. That reconciliation is the gate on the port being
   complete. Do not proceed if it does not balance.
3. Import each component's transplanted state, then `pulumi preview` in the component repo on
   its PR branch. Expect tag-only updates.

   ```bash
   # in the legacy repo
   pulumi stack export --stack {stack} > ~/.cache/ali-migration/legacy-{stack}.json
   # in the component repo
   pulumi stack export --stack {stack} > ~/.cache/ali-migration/{c}-{stack}.json
   scripts/build-move.py --legacy-project {partOf}-{app} --component {c} --stack {stack} \
     --legacy ~/.cache/ali-migration/legacy-{stack}.json \
     --dest   ~/.cache/ali-migration/{c}-{stack}.json \
     --out    ~/.cache/ali-migration/move/{c}-{stack}.json
   pulumi stack import --stack {stack} --file ~/.cache/ali-migration/move/{c}-{stack}.json
   pulumi preview --stack {stack}
   ```
4. **Merge each component PR into branch `{stack}`.** Its `pulumi up` applies the tag updates
   and closes the window opened in 3.
5. `pulumi state delete --target-dependents --yes {urn}` in the legacy stack, once per
   top-level component URN. Then `pulumi preview` in the legacy repo on its PR branch, which
   must be a flat "N unchanged".
6. **Merge the legacy PR into branch `{stack}`.**

The window that actually matters is 3 to 4: the component stack holds state while its branch
still has no program, so a `pulumi up` there — from the 11:00 UTC cron, or any push to that
branch — deletes the live roles and the AppConfig application out from under a running
workload. Keep it to minutes and never open it near 11:00 UTC.

Doing 5 or 6 before 3 is the same catastrophe from the other side: the legacy stack still owns
the resources, its program no longer declares them, and its `pulumi up` deletes them.

The gap between 5 and 6 is the recoverable one, but it is **not** harmless, and the obvious
reasoning about it is wrong. It leaves the legacy program declaring resources it no longer
owns, and the tempting conclusion is that every create simply fails `EntityAlreadyExists` and
nothing happens. Two of them do not fail:

- **AppConfig does not enforce unique DeploymentStrategy names.** The create succeeds and
  leaves a real duplicate strategy in the account.
- **`AttachRolePolicy` is idempotent.** The attachment succeeds and enters the legacy state,
  so the later legacy `pulumi up` detaches it — removing the running pod's RDS access.

So step 5 to 6 is still a window. Close it in the same sitting.

Note that `--target-dependents` takes children and dependents with the parent, so later URNs
in the list may report that they no longer exist. That is expected, not an error.

### What "no changes" means here

Every moved resource that carries tags shows the same difference: `aws:defaultTags` sets
`pulumi-repo` and `pulumi-project` to the owning repository and project, and both change with
ownership. Expect the update count to equal the number of *taggable* moved resources — IAM
roles and AppConfig resources — and not the total, because `RolePolicy` and
`RolePolicyAttachment` carry no tags.

Tag-only updates are accepted; record the decision in the log. Anything else — any create,
delete or replace — means the move was wrong. Stop and restore from step 1.

## Phase 6 — Switch ArgoCD to the new repos

One `platform-k8s-apps` PR per stack. It removes that stack from the legacy component
ApplicationSet's gate and adds the new-style Application, in the same commit. The two cannot
coexist: both render `metadata.name` and `destination.namespace` as
`{partOf}-{app}-{c}-{stack}`, which is also why there is no shadow and no parallel run in this
migration. There is no name left to run one under.

Because Phase 4 set `preserveResourcesOnDeletion`, the workload survives the legacy
Application's removal and is adopted by the new Application through `ServerSideApply`. If the
render is neutral, nothing restarts.

```yaml
{{- include "ali.application" (dict
  "root" .
  "applicationName" "{app}"
  "componentName" "{c}"
) -}}
```

One stack at a time, `dev` first. For `prod`, open the PR and leave it open per rule 11.

### The render must be neutral against *live*, not against the legacy chart

This is the gate that decides whether the switch is safe, and it is **not** the same check as
the Phase 2a render diff. That one compares the new chart to the legacy chart. This one
compares the new chart to the objects actually running:

```bash
kubectl -n {partOf}-{app}-{c}-{stack} get httproute,authorizationpolicy,deployment -o yaml
```

The workload objects — Deployment, Service, ServiceAccount, ScaledObject, PDB — normally match
already. The two that routinely do not are the edge objects, because the new scaffold assumes
the shared gateway while the legacy application is often still fronted by its own:

- `HTTPRoute` — `parentRefs` and `hostnames`. A workload attached to its own gateway in
  `{partOf}-{app}-root-{stack}` with `hostnames: null` gets **detached from the gateway that
  is actually serving it** the moment the new values point somewhere else. The route still
  reports `Accepted=True` against the new parent, so nothing looks wrong.
- `AuthorizationPolicy` — its principals derive from the same `gateways` list, so a wrong
  gateway there denies exactly the traffic a wrong `parentRef` was still admitting.

Set `values.{stack}.yaml` to reproduce what is live. Note also that the legacy chart may name
the policy something else (`allow-gateway` vs `allow-gateway-to-service`); the old object is
left behind by `preserveResourcesOnDeletion` and belongs on the decommission list.

### The version tag is the one thing that must be right

`version.{stack}.yaml` decides what image the new Application deploys. If it disagrees with
what is running, the switch stops being neutral: ArgoCD rolls the workload to a different
version at the moment of handover, which is a deployment disguised as a migration.

Take the value from the **running image**, never from the tag the legacy Application declares.
The two diverge in practice — a stack pinned to git tag `v0.0.7` can be running image `0.0.5`,
because the chart at that git tag set a different image tag. Re-check it immediately before
the switch, not just when the file was seeded.

### Skip a component only if it has no live workload

Decide from the cluster, never from the declared tag. `v0.0.0` is a real, resolvable git tag: a
component pinned to it in every stack is usually deployed and Healthy, running an image tagged
`0.0.0`. The test is whether the Phase 1 snapshot found a Deployment and running pods.

### Moving to the shared gateway is a separate change

Out of scope by default. It changes the hostname, and a hostname needs a certificate and a DNS
record before anything can reach it — bundling that into the switch turns a neutral ownership
change into a routing migration. What follows is for when that change is made on its own.

The shared gateway's chart derives its TLS certificate `dnsNames` — and the DNS record and ALB
listener behind it — from its own `hostNames` list. A gateway listener with no `hostname:` will
happily *accept* a route for `{stack}.{app}.one.ali-apps.com`, so the route reports
`Accepted=True` and everything looks correct, while the name has no certificate and does not
resolve.

So first raise a PR against `platform-{partOf}-gateway` adding the new hostname to
`argocd/values.{stack}.yaml`:

```yaml
gateways:
  - gatewayName: {partOf}-gateway
    hostNames:
      - "{stack}.{app}.one.ali-apps.com"
```

Note this file uses `gatewayName`, not `name`. This is the one sanctioned change to the
gateway repo; it is additive registration, not configuration of someone else's gateway. Wait
for it to sync and for the name to resolve — `preflight.sh` warns `does not resolve in DNS
yet` until it does.

Only once the name resolves does it make sense to point the application's `HTTPRoute` at the
shared gateway. Register the legacy hostname there too and serve both for a while, so DNS can
move without a break; the listener has no `hostname:` so it will accept the legacy host
regardless, and the route will report `Accepted=True`, but TLS fails without a certificate:

```yaml
      - "{stack}.{app}.one.ali-apps.com"
      - "<hostName from the legacy root values file>"
```

The legacy hostname is whatever `platform-{partOf}-{app}/argocd/root/values-{stack}.yaml` sets
as `hostName`. Some stacks have no such file at all, and some production stacks use a custom
name that does not follow the pattern. Read it, do not derive it.

## Phase 7 — Verify and bake

Against the Phase 1 snapshot, for the stack just switched:

- **No new ReplicaSet**: `kubectl get rs -n {ns}` matches the snapshot. A new one means the
  render was not neutral after all.
- Same pod names and restart counts. Same Service ClusterIP.
- The new Application is Synced and Healthy.
- The hostname still serves, on the same path.
- The root Application is still Synced.
- The workload's pods can still assume their IAM role.
- `update-tag.yaml` round-trips: a container publish writes the new tag into
  `version.{stack}.yaml` and ArgoCD deploys it.

Let it bake. Do not proceed to the next stack on the strength of a green sync alone. Update the
log, then start the next stack.

**For `prod`, the switch is prepared as a pull request and left open.** Do not merge the
`platform-k8s-apps` PR and do not move DNS. Record the PR link in the migration log and the
Jira issue, state plainly that production is not cut over, and stop.

## Phase 8 — Decommission

**Out of scope by default.** When the last stack has cut over and baked, the migration is
done. Decommissioning is a separate change raised as its own PR once someone has watched the
migrated shape run in production. Do not fold any of it into the migration PRs. What it
covers:

- Delete `argocd/projects/{partOf}/{app}/templates/app-set-{c}.yaml` for each migrated
  component, and remove the now-unused `{stack}.{c}` tag keys from that project's `values.yaml`.
  Leave `app-set-root.yaml`, the AppProject and `stacks[]` alone.
- Delete `argocd/{c}/` from each container repo, in its own commit. This is the last step that
  can be taken, because until it happens a legacy tag can still be cut for a rollback that
  needs a fix. Any defect recorded against that folder earlier in the migration is resolved by
  the deletion rather than by a patch.
- Merge the container repo PRs if they are still open.
- Delete the objects the old chart owned under a different name that
  `preserveResourcesOnDeletion` left orphaned in the namespace — in practice none, if Phase 2
  achieved byte-parity, but check rather than assume.
- Confirm `argocd/root/` and `components/root/` are untouched, and that the only remaining
  legacy Pulumi change is the component removal.

The migration's own Jira issue closes when the last stack has baked, not when decommissioning
happens. Post a summary comment listing every defect found and fixed and every application
level issue found but deliberately not fixed, transition the issue to Done, and raise a
follow-up issue for the decommission.

## Rollback

Per stack, at any point before Phase 6 the migration is free: nothing in Kubernetes has
changed yet. The new repos are populated but unreferenced, and the Pulumi move is invisible to
the cluster.

After Phase 6, revert the `platform-k8s-apps` PR. The legacy ApplicationSet is restored and
adopts the preserved resources back. The platform repo and container repo changes are inert
without the k8s-apps wiring, so they can stay.

The dangerous window is Phase 6 itself. Do not start it without the Phase 1 snapshot in hand
and `preserveResourcesOnDeletion` already merged and synced.

A Pulumi move rolls back by the same route it went forward: restore the two stack states from
the step 1 backups, then put the code back where the state is. Never reach for `pulumi up` to
reconcile a half-moved stack — it resolves the mismatch by deleting.
