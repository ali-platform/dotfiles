---
name: jira-issue-workflow
description: 'Handle an Accelerate Learning Jira issue end-to-end: fetch the issue from acceleratelearning.atlassian.net, transition it to In Progress, cut a feature branch named after the issue key, post the implementation plan as a Jira comment before writing code, implement, commit with a Conventional Commit message carrying the issue key, open the PR with gh, and after the merge transition the issue to Done with a summary comment. Use when the user names a Jira issue key (e.g. CE-1234, APD-16682) and says "start work on", "work on", "pick up", "take", or "implement" it; also use when finishing up — "the PR merged, close out CE-1234" — to run the Done transition and closing comment.'
---

# Jira Issue Workflow

Follow these steps every time you are asked to "start work on" or "work on" a Jira
issue key (e.g. `CE-1234`).

## 1 — Fetch the issue

Call `mcp_atlassian-mcp_getJiraIssue` with `cloudId: acceleratelearning.atlassian.net`
and the issue key. Read the summary and description thoroughly before doing anything else.

## 2 — Transition to "In Progress"

Call `mcp_atlassian-mcp_getTransitionsForJiraIssue` to list available transitions,
then call `mcp_atlassian-mcp_transitionJiraIssue` with the transition ID that
corresponds to **"In Progress"** (look for `name` containing "Progress").

## 3 — Create a feature branch

Branch name convention: `{ISSUE_KEY}-{short-kebab-description}`
e.g. `CE-7748-fix-app-id-to-client-id`.

```bash
git checkout -b {branch-name}
```

## 4 — Post the plan to the Jira issue

Before writing any code, call `mcp_atlassian-mcp_addCommentToJiraIssue` to post a
brief implementation plan as a comment on the issue. Format:

```
**Plan**
- Step 1: ...
- Step 2: ...
- Step N: ...
```

## 5 — Implement the changes

Make the code changes on the feature branch following the plan.

## 6 — Commit and push

Commit message must follow Conventional Commits:

```
{type}({scope}): {ISSUE_KEY} - {description}
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `revert`, `chore`. In repos that release on merge (e.g.
`workflow-shared-workflows`), this title becomes the squash-merge commit and
determines the semantic version bump — check that repo's release instructions before
choosing the type.

Push the branch to `origin`.

## 7 — Open the Pull Request

Create the PR using `gh pr create`:

```bash
gh pr create \
  --base main \
  --title "{type}({scope}): {ISSUE_KEY} - {description}" \
  --body "..."
```

Use the repository's actual default/target branch for `--base` — several
`platform-*` repos are branch-per-env and do **not** use `main`.

## 8 — After the PR is merged and branch cleanup is done

Once you have confirmed the PR is merged (via `gh pr view`) and have deleted the local
branch and pulled the latest default branch, call `mcp_atlassian-mcp_transitionJiraIssue`
to move the issue to **"Done"** and then call `mcp_atlassian-mcp_addCommentToJiraIssue`
with a brief summary of what was delivered:

```
**Done** — PR #{number} merged as {version}.
```

Use `mcp_atlassian-mcp_getTransitionsForJiraIssue` to look up the transition ID for
"Done" dynamically; do not hardcode it.
