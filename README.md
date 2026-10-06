# workflows

Reusable GitHub Actions workflows shared across my repositories.

Call one by reference:

```yaml
uses: noahkiss/workflows/.github/workflows/<name>.yml@main
```

Every workflow runs on `ubuntu-latest`. The macOS composite actions
(`tauri-macos-build`, `macos-sign-notarize`, `release-attach`) need a macOS
runner. macOS minutes are free for public repositories and metered at 10x for
private ones.

Composite actions live under `actions/`. Call one from a step:

```yaml
uses: noahkiss/workflows/actions/<name>@main
```

**Every action is pinned to a full commit SHA**, with the version it resolved to
in a trailing comment:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

A major tag is a moving pointer. Callers reference these workflows at `@main`, so
a tag repointed upstream reaches every repository on the next run, and nothing in
the caller records which code executed. A SHA is the only reference that answers
"what ran" after the fact. This repository is the one place that matters, because
it is the only place an action version is written.

The trailing comment is not decoration. A bare hash makes the bump diff
unreadable, and this repository's review is the only review those bumps get.
Keep the comment in step with the SHA.

Dependabot raises the bumps here weekly and understands this format natively: it
rewrites both the SHA and the comment. One merge here updates every caller.

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
`jobs.<job_id>.concurrency` form. So `ghcr-build-push`, `node-ci`, `python-ci`
and `cf-pages-deploy` each carry a job-level guard.

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

Replaces the near-identical GHCR build in ten repositories. It builds
`linux/amd64` only by default; a caller whose image runs on an ARM host passes
`platforms: linux/amd64,linux/arm64`.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `image` | no | `''` → `ghcr.io/<owner>/<repo>`, lowercased | Image name |
| `platforms` | no | `linux/amd64` | Platforms for the pushed image |
| `tags` | no | see below | Rules for `docker/metadata-action`, one per line |
| `labels` | no | `''` | Extra `key=value` labels, one per line; each replaces the generated label of the same key |
| `checkout_ref` | no | `''` → the triggering ref | Ref or SHA to check out |
| `context` | no | `.` | Build context |
| `dockerfile` | no | `''` → buildx default | Dockerfile path |
| `build_args` | no | `''` | Build arguments for both builds, one `KEY=value` per line |
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
`IMAGE`. Only then does the build for `platforms` run and push. The second
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

pnpm comes from `pnpm/action-setup` (pinned, v6.0.10), which reads the version from the
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

## `python-ci.yml`

The shared Python test gate. It installs the locked dependency set with uv, then
runs the given commands in order under `uv run`.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `python-version-file` | no | `.python-version` | Version file, relative to `working-directory` |
| `python-version` | no | `''` | Explicit version; wins over the file |
| `working-directory` | no | `.` | Directory holding `pyproject.toml` |
| `install` | no | `uv sync --frozen` | Install command; empty skips the step |
| `commands` | no | `pytest` | Commands run under `uv run`, one per line, in order |

Secrets: none.

Permissions the calling job must grant:

```yaml
permissions:
  contents: read
```

`--frozen` is what makes the committed `uv.lock` authoritative: it installs the
locked set and fails if the lockfile is stale, rather than quietly re-resolving.

The workflow takes commands, not a runner name. Repositories here use both
pytest and unittest, and one gate that forced a single runner would mean
rewriting working suites for no gain.

Each command is run through the shell, so flags and quoting work as written:
`pytest -m 'not integration'` does what it looks like.

`setup-uv` has no version-file input of its own, so the workflow reads the file
and passes the value as `python-version`. A version file under a non-default name
therefore works, which uv's own discovery would not do.

The job fails early if neither `python-version` nor the version file is
available.

```yaml
jobs:
  ci:
    uses: noahkiss/workflows/.github/workflows/python-ci.yml@main
    permissions:
      contents: read
    with:
      commands: |
        ruff check .
        pytest
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

---

## Tauri macOS release: `actions/tauri-macos-build` + `actions/release-attach`

The release pipeline for a Tauri app on macOS is three composite actions, run
as steps of **one job in the caller's own repository**:

1. `tauri-macos-build` builds the app for Apple Silicon from the checked-out tag.
2. `macos-sign-notarize` signs, notarizes and staples it (next section).
3. `release-attach` zips it with `ditto`, waits for green CI, and attaches the zip.

A cask bump follows as a `dispatch-and-wait.yml` job.

**Environment secrets do not cross into a reusable workflow from another
repository.** A called workflow's job can name the caller's environment, and
the deployment is created, but the environment's secrets resolve empty there.
That is why this pipeline is a set of actions, not a reusable workflow. Put
the five signing secrets in a GitHub environment (e.g. `release`) limited to
`v*` tags. The caller's job names that environment and passes each secret to
`macos-sign-notarize` as an input. A branch push or a pull request cannot
reach them. Re-run a release by dispatching the caller **on the tag**
(`gh workflow run release.yml --ref vX.Y.Z -f tag=vX.Y.Z`); that run uses the
caller workflow as it stood at the tag.

The jobs run on macOS. macOS minutes are free for public repositories and
metered at 10x for private ones.

### `actions/tauri-macos-build`

Steps: resolve the tag (strict `vX.Y.Z`), fail unless `HEAD` is the tag's
commit, check that `Cargo.toml` and `tauri.conf.json` state the tag's version,
install Rust (and any Homebrew packages), `rust-cache`, pnpm and Node,
`pnpm install --frozen-lockfile`, `tauri build --bundles app`, check the
bundle's `CFBundleShortVersionString`. The caller checks out the tag first.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `tag` | no | `''` → the triggering tag | Release tag, `vX.Y.Z` |
| `app-name` | yes | — | Bundle name without `.app` (`productName`) |
| `asset-prefix` | yes | — | The zip is `<asset-prefix>-<version>-arm64.zip` |
| `tauri-dir` | no | `src-tauri` | Folder with `tauri.conf.json` and `Cargo.toml` |
| `bundle-path` | no | `''` → `<tauri-dir>/target/release/bundle/macos/<app-name>.app` | Built bundle |
| `frontend-dir` | no | `app` | Folder with the frontend's `package.json` (pnpm); empty skips Node |
| `node-version-file` | no | `.node-version` | Node version file |
| `tauri-command` | no | `''` → `<frontend-dir>/node_modules/.bin/tauri` | Tauri CLI command |
| `brew-packages` | no | `''` | Homebrew packages, space-separated |
| `check-versions` | no | `true` | Manifest versions must match the tag |

| Output | Meaning |
|---|---|
| `tag` | The release tag |
| `version` | The tag without its `v` |
| `asset` | File name the zip should get |
| `app` | Path of the built `.app` |

### `actions/release-attach`

Steps: `codesign --verify --deep --strict`, the smoke command, `ditto` zip,
wait for a green run of the CI workflow on `HEAD`, create the tag's release if
missing, attach.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `path` | yes | — | The signed `.app` |
| `tag` | yes | — | Release tag |
| `asset` | yes | — | Zip file name |
| `smoke-command` | no | `''` | Run against the bundle; `$APP` holds its path |
| `require-ci-workflow` | no | `''` → skipped | Workflow file that must be green on `HEAD` |
| `ci-timeout-minutes` | no | `40` | How long to wait for it |
| `token` | no | `github.token` | Token for `gh` |

| Output | Meaning |
|---|---|
| `asset-path` | Absolute path of the zip |
| `sha256` | SHA-256 of the zip that was built |

**Never clobber.** If the tag's release already has the zip, the step keeps it
and succeeds. A cask pins the sha256 of what was published first, and a rebuilt
zip is not byte-identical.

### Caller

The release job needs `contents: write` and `actions: read`. The tap's bump
workflow must follow `dispatch-and-wait.yml`'s target-side contract and take
`{"formula": ..., "tag": ...}`. `tauri-macos-build` rejects any tag outside
`vX.Y.Z`, so the tag is safe inside the JSON string.

```yaml
on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      tag:
        description: Existing tag to release
        required: true

permissions: {}

jobs:
  release:
    runs-on: macos-26
    environment: release
    permissions:
      contents: write
      actions: read
    concurrency:
      group: release-${{ inputs.tag || github.ref }}
      cancel-in-progress: false
    outputs:
      tag: ${{ steps.build.outputs.tag }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ inputs.tag || github.ref }}
      - id: build
        uses: noahkiss/workflows/actions/tauri-macos-build@main
        with:
          tag: ${{ inputs.tag }}
          app-name: MyApp
          asset-prefix: myapp
      - uses: noahkiss/workflows/actions/macos-sign-notarize@main
        with:
          path: ${{ steps.build.outputs.app }}
          identity: 'Developer ID Application: Example Inc. (ABCDE12345)'
          team-id: ABCDE12345
          entitlements: src-tauri/Entitlements.plist
          certificate-p12: ${{ secrets.MAC_CERT_P12 }}
          certificate-password: ${{ secrets.MAC_CERT_PASSWORD }}
          notary-key-p8: ${{ secrets.ASC_KEY_P8 }}
          notary-key-id: ${{ secrets.ASC_KEY_ID }}
          notary-issuer-id: ${{ secrets.ASC_ISSUER_ID }}
      - uses: noahkiss/workflows/actions/release-attach@main
        with:
          path: ${{ steps.build.outputs.app }}
          tag: ${{ steps.build.outputs.tag }}
          asset: ${{ steps.build.outputs.asset }}
          require-ci-workflow: ci.yml

  bump-tap:
    needs: release
    permissions: {}
    uses: noahkiss/workflows/.github/workflows/dispatch-and-wait.yml@main
    with:
      repo: example/homebrew-tap
      workflow: bump.yml
      inputs_json: '{"formula":"myapp","tag":"${{ needs.release.outputs.tag }}"}'
      timeout_minutes: 45
    secrets:
      token: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```

The former reusable workflow `tauri-macos-release.yml` is gone. It could not
read the caller's environment secrets, and a version that took them as repo
secrets would drop the tag-only protection.

---

## `actions/macos-sign-notarize`

A composite action, usable on its own in any macOS job. It signs a `.app`
bundle or a bare Mach-O binary with a Developer ID identity, notarizes it, and
verifies the result. The Tauri macOS release uses it between
`tauri-macos-build` and `release-attach`.

1. Imports the `.p12` into a throwaway keychain.
2. Signs with `--options runtime --timestamp`. A bundle is signed inside out:
   loose Mach-O files, then nested `.framework`, `.app`, `.xpc` and `.appex`
   bundles, deepest first, then the bundle. Executables and nested apps get the
   entitlements; libraries and frameworks do not.
3. Checks `codesign --verify --deep --strict`, the team ID, the hardened-runtime
   flag and the timestamp.
4. Zips with `ditto` and runs `notarytool submit --wait`. A rejection prints the
   notary log and fails.
5. A bundle: `stapler staple`, `stapler validate`, `spctl --assess --type execute`.
   A bare binary cannot hold a ticket; Gatekeeper fetches it online.
6. Both: `codesign --verify -R=notarized --check-notarization`.
7. Deletes the keychain and the key file, and restores the keychain search list.

| Input | Required | Default | Meaning |
|---|---|---|---|
| `path` | yes | — | `.app` bundle or Mach-O binary |
| `identity` | yes | — | Full signing identity |
| `team-id` | yes | — | Team ID the signature must carry |
| `entitlements` | no | `''` | Entitlements plist |
| `identifier` | no | `''` | Code identifier for a bare binary |
| `notarize` | no | `true` | Submit and wait |
| `certificate-p12` | yes | — | Base64 `.p12` |
| `certificate-password` | yes | — | Its password |
| `notary-key-p8` | to notarize | `''` | App Store Connect API key, `.p8` PEM text |
| `notary-key-id` | to notarize | `''` | Its key ID |
| `notary-issuer-id` | to notarize | `''` | Its issuer ID |

| Output | Meaning |
|---|---|
| `submission-id` | Notary submission ID |
| `status` | Notary verdict, e.g. `Accepted` |

No secret is printed. Use the Developer-role API key for notarization, never
an Admin key.

```yaml
      - uses: noahkiss/workflows/actions/macos-sign-notarize@main
        with:
          path: target/release/mytool
          identity: 'Developer ID Application: Example Inc. (ABCDE12345)'
          team-id: ABCDE12345
          identifier: com.example.mytool
          certificate-p12: ${{ secrets.MAC_CERT_P12 }}
          certificate-password: ${{ secrets.MAC_CERT_PASSWORD }}
          notary-key-p8: ${{ secrets.ASC_KEY_P8 }}
          notary-key-id: ${{ secrets.ASC_KEY_ID }}
          notary-issuer-id: ${{ secrets.ASC_ISSUER_ID }}
```

`sign-notarize.sh` runs on a Mac by hand, with the same values as environment
variables (`SIGN_PATH`, `SIGN_IDENTITY`, `SIGN_TEAM_ID`, `SIGN_ENTITLEMENTS`,
`SIGN_IDENTIFIER`, `SIGN_NOTARIZE`, `ASC_KEY_P8`, `ASC_KEY_ID`,
`ASC_ISSUER_ID`). Leave `MAC_CERT_P12` unset and it signs with the identity in
the login keychain.
