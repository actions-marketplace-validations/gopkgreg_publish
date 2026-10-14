#!/usr/bin/env bash
# publish.sh is the gopkgreg publish action: it downloads the gopkgreg CLI
# for this runner from a GitHub release, verifies its checksum, makes sure
# the release tag is present in a shallow checkout, then runs
# "gopkgreg publish" and reports the result as step outputs and a job
# summary. Inputs arrive as INPUT_* environment variables (see action.yml).
set -euo pipefail

registry=${INPUT_REGISTRY:-https://gopkgreg.com}
directory=${INPUT_DIRECTORY:-.}
version=${INPUT_VERSION:-}
dry_run=${INPUT_DRY_RUN:-false}
cli_version=${INPUT_CLI_VERSION:-latest}
cli_repo=gopkgreg/gopkgreg

# fail prints a message as a GitHub annotation and stops. Annotations
# escape %, CR and LF, so multi-line messages survive.
fail() {
	local msg=$*
	msg=${msg//'%'/'%25'}
	msg=${msg//$'\r'/'%0D'}
	msg=${msg//$'\n'/'%0A'}
	echo "::error title=gopkgreg publish::$msg"
	exit 1
}

case $dry_run in
true | false) ;;
*) fail "dry-run must be true or false, not \"$dry_run\"." ;;
esac

# --- The CLI build for this runner ---------------------------------------

case ${RUNNER_OS:-$(uname -s)} in
Linux) os=linux ;;
macOS | Darwin) os=darwin ;;
Windows | MINGW* | MSYS* | CYGWIN*) os=windows ;;
*) fail "unsupported runner OS ${RUNNER_OS:-$(uname -s)}." ;;
esac
case ${RUNNER_ARCH:-$(uname -m)} in
X64 | x86_64 | amd64) arch=amd64 ;;
ARM64 | arm64 | aarch64) arch=arm64 ;;
*) fail "unsupported runner architecture ${RUNNER_ARCH:-$(uname -m)}." ;;
esac
if [[ $os/$arch == windows/arm64 ]]; then
	fail "the gopkgreg CLI has no windows/arm64 build. Use a Linux or macOS runner, or windows-latest (x64)."
fi
ext=
[[ $os == windows ]] && ext=.exe

github_api() {
	local auth=()
	[[ -n ${GH_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
	# ${auth[@]+…}: bash 3.2 (macOS) treats an empty array as unset under set -u.
	curl -fsSL --retry 3 --retry-all-errors ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" "$1"
}

if [[ $cli_version == latest ]]; then
	cli_version=$(github_api "https://api.github.com/repos/$cli_repo/releases/latest" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1) ||
		fail "couldn't look up the latest gopkgreg CLI release. Set cli-version, such as v0.2.1."
fi
[[ $cli_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	fail "cli-version must look like v1.2.3 or be \"latest\", not \"$cli_version\"."

work=${RUNNER_TEMP:-$(mktemp -d)}/gopkgreg-publish
mkdir -p "$work"
asset=gopkgreg-$cli_version-$os-$arch$ext
base=https://github.com/$cli_repo/releases/download/$cli_version
curl -fsSL --retry 3 --retry-all-errors -o "$work/$asset" "$base/$asset" ||
	fail "couldn't download $asset from the $cli_version release."
curl -fsSL --retry 3 --retry-all-errors -o "$work/SHA256SUMS" "$base/SHA256SUMS" ||
	fail "couldn't download SHA256SUMS from the $cli_version release."

want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$work/SHA256SUMS")
if command -v sha256sum >/dev/null; then
	got=$(sha256sum "$work/$asset" | awk '{ print $1 }')
else
	got=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
fi
[[ -n $want && $got == "$want" ]] ||
	fail "checksum mismatch for $asset: SHA256SUMS lists ${want:-nothing}, the download hashes to $got."
chmod +x "$work/$asset"
cli=$work/$asset
echo "Using $("$cli" version) ($os/$arch, checksum verified)"

# --- The release tag -----------------------------------------------------

# actions/checkout fetches one commit and, on a tag push, that tag. When the
# version comes from an input, or the run wasn't started by the tag, fetch
# the tag so the CLI can build the release from it.
[[ -d $directory ]] || fail "directory \"$directory\" doesn't exist."
mod_root=$directory
while [[ ! -f $mod_root/go.mod ]]; do
	parent=$(cd "$mod_root/.." && pwd)
	[[ $parent != "$(cd "$mod_root" && pwd)" ]] || fail "no go.mod in \"$directory\" or any directory above it."
	mod_root=$parent
done
if git -C "$mod_root" rev-parse --git-dir >/dev/null 2>&1; then
	prefix=$(git -C "$mod_root" rev-parse --show-prefix)
	if [[ -n $version ]]; then
		tag=$prefix$version
		if ! git -C "$mod_root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
			git -C "$mod_root" fetch -q --depth=1 origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null || true
		fi
	elif [[ -z $(git -C "$mod_root" tag --points-at HEAD) ]]; then
		head=$(git -C "$mod_root" rev-parse HEAD)
		# Tags on HEAD, from the remote: lightweight tags list the commit,
		# annotated ones list it on their peeled "^{}" line.
		while read -r sha ref; do
			[[ $sha == "$head" ]] || continue
			ref=${ref%'^{}'}
			git -C "$mod_root" fetch -q --depth=1 origin "$ref:$ref" 2>/dev/null || true
		done < <(git -C "$mod_root" ls-remote --tags origin "${prefix}v*" 2>/dev/null || true)
	fi
fi

# --- Publish -------------------------------------------------------------

args=(publish --registry "$registry" --dir "$directory")
[[ $dry_run == true ]] && args+=(--dry-run)
[[ -n $version ]] && args+=("$version")

# A private credentials file, so nothing from the runner leaks in.
export GOPKGREG_CONFIG=$work/credentials.json
if [[ -n ${INPUT_TOKEN:-} ]]; then
	echo "::add-mask::$INPUT_TOKEN"
	export GOPKGREG_TOKEN=$INPUT_TOKEN
fi

status=0
"$cli" "${args[@]}" >"$work/stdout" 2>"$work/stderr" || status=$?
cat "$work/stdout"
cat "$work/stderr" >&2
if ((status != 0)); then
	fail "$(sed -E 's/^gopkgreg( publish)?: //' "$work/stderr")"
fi

module=$(sed -nE 's/^(Checked|Publishing) ([^@[:space:]]+)@([^[:space:]]+)$/\2/p' "$work/stdout" | head -n 1)
published=$(sed -nE 's/^(Checked|Publishing) ([^@[:space:]]+)@([^[:space:]]+)$/\3/p' "$work/stdout" | head -n 1)
url=$(sed -nE 's/^  view +([^[:space:]]+)$/\1/p' "$work/stdout" | head -n 1)
install=$(sed -nE 's/^  install +(.+)$/\1/p' "$work/stdout" | head -n 1)

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
	{
		echo "module=$module"
		echo "version=$published"
		echo "url=$url"
	} >>"$GITHUB_OUTPUT"
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
	{
		if [[ $dry_run == true ]]; then
			echo "### Checked $module@$published"
			echo
			echo "Dry run: the module zip builds and passes the go command's checks. Nothing was uploaded."
		elif grep -q 'already published with identical content' "$work/stdout"; then
			echo "### $module@$published was already published"
			echo
			echo "The registry has this release with identical content. Nothing changed."
		else
			echo "### Published [$module@$published]($url)"
		fi
		if [[ -n $install ]]; then
			echo
			echo '```sh'
			echo "$install"
			echo '```'
		fi
	} >>"$GITHUB_STEP_SUMMARY"
fi
