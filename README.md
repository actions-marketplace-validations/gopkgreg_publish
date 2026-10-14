# gopkgreg publish

Publish a Go module to [gopkgreg](https://gopkgreg.com) from GitHub Actions in one step. Push a
version tag and the release is built from that tag, checked with the go command's own rules, and
uploaded. With trusted publishing there's **no API token to store**: GitHub proves which workflow
is publishing.

```yaml
name: Publish
on:
  push:
    tags: ["v*"]

permissions:
  contents: read
  id-token: write # trusted publishing

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: gopkgreg/publish@v1
```

No Go installation is needed: the action downloads the `gopkgreg` CLI for the runner from its
GitHub release and verifies the checksum first.

## Set up trusted publishing once

1. Sign in at [gopkgreg.com](https://gopkgreg.com) with two-factor authentication on.
2. Register the workflow as a trusted publisher:
   - **New module:** your account page → **Publish from GitHub Actions**.
   - **Existing module:** the module's **Manage** tab → **Trusted publishers**.
3. Enter the repository (`owner/name`), the workflow file name (`publish.yml` in the example
   above), and optionally a GitHub environment.

Your module's `go.mod` must say `module gopkgreg.com/<your-username>/<name>`. Then tag and push:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

The run's summary links to the published release and shows the install command.

## Inputs

| Input | Default | Description |
|---|---|---|
| `registry` | `https://gopkgreg.com` | Registry URL, for a self-hosted gopkgreg. |
| `directory` | `.` | Directory inside the module, for a module in a subdirectory. Its tags are prefixed: `sub/v1.0.0`. |
| `version` | the tag on the checked-out commit | Version to publish, such as `v1.2.3`. The action fetches the tag if the checkout doesn't have it. |
| `token` | empty | An API token, for example `${{ secrets.GOPKGREG_TOKEN }}`. Leave empty for trusted publishing. |
| `dry-run` | `false` | Build and check the module zip without uploading. Needs no token. |
| `cli-version` | `latest` | gopkgreg CLI release to run, such as `v0.2.1`. |

## Outputs

| Output | Description |
|---|---|
| `module` | The module path, such as `gopkgreg.com/alice/retry`. |
| `version` | The version published or checked. |
| `url` | The release's page on the registry. Empty for a dry run. |

## Examples

**Check every pull request** builds a valid release, without publishing:

```yaml
on: pull_request
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: git tag v0.0.0-check
      - uses: gopkgreg/publish@v1
        with:
          version: v0.0.0-check
          dry-run: true
```

**Require a human approval** for every release: name a GitHub environment in the trusted publisher
on gopkgreg, protect that environment with required reviewers in your repository settings, and
use it in the job:

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    environment: release
    steps:
      - uses: actions/checkout@v4
      - uses: gopkgreg/publish@v1
```

**A module in a subdirectory**, released with tags like `tools/v1.4.0`:

```yaml
on:
  push:
    tags: ["tools/v*"]
# …
      - uses: gopkgreg/publish@v1
        with:
          directory: tools
```

**With an API token** instead of trusted publishing (create one on your account page and store it
as a repository secret):

```yaml
      - uses: gopkgreg/publish@v1
        with:
          token: ${{ secrets.GOPKGREG_TOKEN }}
```

## Behavior worth knowing

- **Re-running is safe.** Publishing a version that's already on the registry with identical
  content succeeds and changes nothing. Different content under the same version is refused:
  versions are immutable.
- **Trusted publishing tokens** last 15 minutes and can only upload that one module.
- **Runners:** Linux and macOS on x64 or ARM, and Windows on x64.
- **Pinning:** for the strictest supply-chain setup, pin the action to a commit SHA and set
  `cli-version` to a fixed release.

## License

MIT. The gopkgreg registry itself is AGPL-3.0: see
[gopkgreg/gopkgreg](https://github.com/gopkgreg/gopkgreg).
