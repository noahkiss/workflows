# workflows

Reusable GitHub Actions workflows shared across my repositories.

Call one by reference:

```yaml
uses: noahkiss/workflows/.github/workflows/<name>.yml@main
```

Every workflow runs on `ubuntu-latest`. Action versions are pinned to major tags
and Dependabot raises the bumps here weekly, so one merge in this repository
updates every caller.

## Rules that apply to all of them

**Secrets never flow implicitly.** A called workflow sees only the secrets the
caller passes. Name each one under `secrets:`, or pass `secrets: inherit` to
hand over all of the caller's secrets. `inherit` works only when caller and
called workflow are in the same organization or enterprise.

**Caller `env` does not reach the called workflow.** Workflow-level `env` in the
caller is invisible here. Pass values as inputs.

**Token permissions can only shrink.** A called workflow cannot hold more
`GITHUB_TOKEN` permission than its caller granted. Each section below states the
`permissions:` the calling job needs.

**Where the concurrency guard lives: at job level, inside the called workflow.**
A called workflow's jobs run inside the *caller's* workflow run, so there is no
separate run for a workflow-level `concurrency:` block here to scope to. GitHub's
own reusable-workflow reference discusses the guard only in its
`jobs.<job_id>.concurrency` form. So `ghcr-build-push`, `node-ci` and
`cf-pages-deploy` each carry a job-level guard.

Each group name starts with a literal unique to its file. That is deliberate.
The docs warn:

> A called workflow uses the name of its caller workflow in `${{ github.workflow }}`,
> so using this context as the value of `jobs.<job_id>.concurrency.group` in both
> caller and called workflows will cause the caller workflow to be cancelled when
> the called workflow runs.

If you add a guard in your calling job, give it a different group name from the
one used here.

---

## `komodo-deploy.yml`

Replaces the inline deploy step copied into four repositories. It posts a signed
synthetic push event to a Komodo webhook listener, which then redeploys one
stack.

The listener URL is a required input with no default. Keep it in a repository or
organization variable.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `stack` | yes | — | Komodo stack name |
| `listener_url` | yes | — | Listener base URL, no trailing slash |
| `ref` | no | `refs/heads/main` | Git ref sent in the payload |

| Secret | Required | Meaning |
|---|---|---|
| `webhook_secret` | yes | Shared secret; must match the listener's |

Permissions: none. The job declares `permissions: {}`.

It signs the payload with HMAC-SHA256 and sends the hex digest in
`X-Hub-Signature-256`. A non-2xx reply fails the job. The secret and the
signature are never printed.

The post is attempted twice, 75 seconds apart, but only when the first failure
is one a fresh runner can clear — a transport error, a 429, a 5xx, or a 403
carrying an HTML error page from a CDN or WAF. A 401 or any other 4xx is a real
rejection and fails at once.

**Gate the branch yourself.** This workflow does not check which branch you are
on.

```yaml
jobs:
  deploy:
    if: github.ref == 'refs/heads/main'
    uses: noahkiss/workflows/.github/workflows/komodo-deploy.yml@main
    with:
      stack: my-stack
      listener_url: https://hooks.example.com/listener/github
    secrets:
      webhook_secret: ${{ secrets.KOMODO_WEBHOOK_SECRET }}
```

Deploy after the image is published, not on push — the image is still building
at push time:

```yaml
jobs:
  build:
    uses: noahkiss/workflows/.github/workflows/ghcr-build-push.yml@main
    permissions:
      contents: read
      packages: write
  deploy:
    needs: build
    if: github.ref == 'refs/heads/main'
    uses: noahkiss/workflows/.github/workflows/komodo-deploy.yml@main
    with:
      stack: my-stack
      listener_url: ${{ vars.KOMODO_LISTENER_URL }}
    secrets:
      webhook_secret: ${{ secrets.KOMODO_WEBHOOK_SECRET }}
```

---

## `ghcr-build-push.yml`

Replaces the near-identical multi-architecture GHCR build in ten repositories.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `image` | no | `''` → `ghcr.io/<owner>/<repo>`, lowercased | Image name |
| `platforms` | no | `linux/amd64,linux/arm64` | Platforms for the pushed image |
| `tags` | no | see below | Rules for `docker/metadata-action`, one per line |
| `labels` | no | `''` | Extra `key=value` labels, one per line; each replaces the generated label of the same key |
| `checkout_ref` | no | `''` → the triggering ref | Ref or SHA to check out |
| `context` | no | `.` | Build context |
| `dockerfile` | no | `''` → buildx default | Dockerfile path |
| `smoke_command` | no | `''` → skipped | Command run against a pre-push build |

Default `tags`:

```
type=ref,event=branch
type=semver,pattern={{version}}
type=sha,prefix=sha-
type=raw,value=latest,enable={{is_default_branch}}
```

Secrets: none. It logs in with `github.actor` and the job's `GITHUB_TOKEN`.

| Output | Meaning |
|---|---|
| `digest` | Digest of the pushed image |
| `tags` | Tags that were applied, one per line |

Permissions the calling job must grant:

```yaml
permissions:
  contents: read
  packages: write
```

`image` has no expression in its default because `workflow_call` input defaults
cannot use the `github` context. The fallback is computed in a step and
lowercased, which GHCR requires.

`docker/metadata-action` supplies the OCI labels, including
`org.opencontainers.image.revision`. Layer cache is `type=gha` in both
directions.

```yaml
jobs:
  build:
    uses: noahkiss/workflows/.github/workflows/ghcr-build-push.yml@main
    permissions:
      contents: read
      packages: write
```

### `smoke_command`

Set it and the build runs twice. First an amd64-only build with `load: true`,
tagged locally; your command runs against it with the image reference in
`IMAGE`. Only then does the multi-platform build and push happen. The second
build reuses the same `gha` cache, so it is cheap.

Use it to prove the image actually works before it reaches the registry — for
example, that every import resolves inside it:

```yaml
jobs:
  build:
    uses: noahkiss/workflows/.github/workflows/ghcr-build-push.yml@main
    permissions:
      contents: read
      packages: write
    with:
      smoke_command: docker run --rm "$IMAGE" python -c "import myapp"
```

### Building from a `workflow_run` event

A `workflow_run` job checks out the default branch, not the commit that
triggered the upstream run. Pin it:

```yaml
jobs:
  build:
    uses: noahkiss/workflows/.github/workflows/ghcr-build-push.yml@main
    permissions:
      contents: read
      packages: write
    with:
      checkout_ref: ${{ github.event.workflow_run.head_sha }}
```

`checkout_ref` alone is not enough. `docker/metadata-action` derives
`org.opencontainers.image.revision` from `github.sha`, which on a `workflow_run`
event is the default branch head, not the commit you just built. The two
diverge whenever another commit lands mid-build, and the image then claims a
revision it does not contain. Set the label too:

```yaml
    with:
      checkout_ref: ${{ github.event.workflow_run.head_sha }}
      labels: |
        org.opencontainers.image.revision=${{ github.event.workflow_run.head_sha }}
```

A `labels` entry replaces the generated label of the same key, so the last
value wins. Note that `annotations` still come from `github.sha`; only the
image config labels are corrected here.

---

## `node-ci.yml`

The shared Node test gate. It detects the package manager, installs from the
lockfile, then runs the named package scripts in order.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `node-version-file` | no | `.node-version` | Version file, relative to `working-directory` |
| `node-version` | no | `''` | Explicit version; wins over the file |
| `package-manager` | no | `auto` | `auto`, `npm` or `pnpm` |
| `working-directory` | no | `.` | Directory holding `package.json` |
| `scripts` | no | `test` | Script names, one per line, run in order |
| `audit` | no | `false` | Gate on `npm audit --omit=dev --audit-level=high` |

Secrets: none.

Permissions the calling job must grant:

```yaml
permissions:
  contents: read
```

`auto` picks pnpm when `pnpm-lock.yaml` sits in `working-directory`, otherwise
npm. Install is `pnpm install --frozen-lockfile` or `npm ci`. `setup-node`
caches for the detected manager, and only when the matching lockfile exists.

pnpm comes from `pnpm/action-setup@v6`, which reads the version from the
`packageManager` field of your `package.json`. Set that field in any pnpm repo.

`audit` is npm only. It is skipped, with a note in the log, when the manager is
pnpm.

The job fails early if neither `node-version` nor the version file is available.

```yaml
jobs:
  ci:
    uses: noahkiss/workflows/.github/workflows/node-ci.yml@main
    permissions:
      contents: read
    with:
      scripts: |
        lint
        typecheck
        test
      audit: true
```

---

## `dispatch-and-wait.yml`

Starts a `workflow_dispatch` run in another repository and fails unless that run
succeeds. Generalizes the hardened cross-repository release handshake.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `repo` | yes | — | Target repository, `owner/name` |
| `workflow` | yes | — | Target workflow file name |
| `inputs_json` | no | `{}` | JSON object of inputs; `request_id` is merged in |
| `timeout_minutes` | no | `60` | Deadline for finding and awaiting the run |
| `poll_seconds` | no | `30` | Seconds between polls |

| Secret | Required | Meaning |
|---|---|---|
| `token` | yes | PAT with `actions: write` on the target repository |

| Output | Meaning |
|---|---|
| `run_id` | Numeric id of the target run |
| `run_url` | Web URL of the target run |

Permissions: none. The job declares `permissions: {}` and acts entirely through
`token`. The caller's `GITHUB_TOKEN` cannot dispatch another repository, so a
PAT is required.

### Target-side contract

`workflow_dispatch` returns nothing that identifies the run it created. So this
workflow generates a `request_id`, passes it as a dispatch input, and finds the
run by matching that id in the run's `displayTitle`.

**The target workflow must accept a `request_id` input and echo it in its
`run-name:`.** Without that the run is never found and the caller times out.

```yaml
# in the TARGET repository
name: Release
run-name: Release (request ${{ inputs.request_id }})

on:
  workflow_dispatch:
    inputs:
      request_id:
        description: Correlation id from the calling workflow.
        required: false
        type: string
```

The dispatch itself is retried up to six times with exponential backoff.

```yaml
jobs:
  release:
    uses: noahkiss/workflows/.github/workflows/dispatch-and-wait.yml@main
    with:
      repo: noahkiss/other-repo
      workflow: release.yml
      inputs_json: '{"version":"1.2.3"}'
      timeout_minutes: 30
    secrets:
      token: ${{ secrets.DISPATCH_PAT }}
```

---

## `cf-pages-deploy.yml`

Replaces three inconsistent Cloudflare Pages deploys.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `project` | yes | — | Cloudflare Pages project name |
| `directory` | yes | — | Build output directory, relative to `working-directory` |
| `working-directory` | no | `.` | Directory holding `package.json` |
| `build-command` | no | `npm run build` | Command that produces the output |
| `node-version-file` | no | `.node-version` | Version file, relative to `working-directory` |

| Secret | Required | Meaning |
|---|---|---|
| `cloudflare_api_token` | yes | Token with the Pages edit permission |
| `cloudflare_account_id` | yes | Account that owns the project |

Permissions the calling job must grant:

```yaml
permissions:
  contents: read
```

Steps: checkout, `setup-node` with npm cache, `npm ci`, build, then
`wrangler pages deploy <directory> --project-name=<project>`.

```yaml
jobs:
  deploy:
    uses: noahkiss/workflows/.github/workflows/cf-pages-deploy.yml@main
    permissions:
      contents: read
    with:
      project: my-site
      directory: dist
    secrets:
      cloudflare_api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      cloudflare_account_id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```
