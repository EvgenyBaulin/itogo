#!/bin/bash
# Makes a release with nobody at the keyboard: the same steps as a release by hand, in the same
# order, each one checked before the next, and nothing public before everything local is done.
#
#   1. checks: the branch, the version not out yet, no release this night already, nothing
#      untracked outside the folders of source code and tests, the author and the hooks;
#   2. make verify — any failure stops here, before a commit;
#   3. the commit of the working tree (files named one by one, never `git add -A`);
#   4. the build, its signature and the Sparkle archive (make release-local), checked as an
#      installed copy would meet it (make release-check CANDIDATE=…);
#   5. main pushed, and CI on that commit waited for: red stops before anything is published;
#   6. the GitHub release, which makes the tag; the entry of the feed as a new commit on
#      gh-pages; the published release read back from outside (make release-check V=…);
#   7. the address of the release printed, a line in the journal, the marker of the night.
#
# There is no notarization: the app is signed with the owner's own certificate or ad-hoc, and
# there is no Developer ID to notarize with.
#
# It never asks: every command reads from /dev/null, git and gh are told not to prompt. It never
# forces a push and never rewrites a commit: a push that is not a fast-forward simply fails. A
# second run after a release of the same night, or of the same version, refuses.
#
# Usage: night-release.sh [--dry-run]
#   --dry-run          prints the checks and the plan; changes nothing, fetches nothing
#   NIGHT_RELEASE_MESSAGE  the subject of the release commit; «Itogo <version>» when not given
#   NIGHT_RELEASE_CI_MINUTES  how long CI is waited for, 90 when not given
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/.." && pwd)"
cd "${root}"

dry_run=""
if [ "${1:-}" = "--dry-run" ]; then dry_run="yes"; fi

repo="EvgenyBaulin/itogo"
branch="main"
author_name="evgenybaulin"
author_email="e.baulin@icloud.com"
archive_dir="${HOME}/Library/Developer/Itogo-archive"
release_dir="${HOME}/Library/Developer/Itogo/release"
journal="${archive_dir}/night-releases.log"
ci_minutes="${NIGHT_RELEASE_CI_MINUTES:-90}"
# A night belongs to the evening it began on: a run at 03:00 on the 6th is the night of the 5th.
night="$(date -v-12H +%F)"
marker="${archive_dir}/night-release-${night}.done"

export GIT_TERMINAL_PROMPT=0 GIT_EDITOR=true GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
exec < /dev/null

say() { printf 'night-release: %s\n' "$1"; }
stop() { printf 'night-release: STOP: %s\n' "$1" >&2; exit 1; }

# Checks collect their findings, so a dry run shows every one of them, not only the first.
problems=""
problem() { problems="${problems}  - $1"$'\n'; printf 'night-release: check failed: %s\n' "$1" >&2; }
ok() { printf 'night-release: ok: %s\n' "$1"; }

# --- 1. Checks -------------------------------------------------------------------------------

version="$("${here}/release-version.sh" version)" || stop "no MARKETING_VERSION in project.yml"
build="$("${here}/release-version.sh" build)" || stop "no CURRENT_PROJECT_VERSION in project.yml"
tag="v${version}"
say "version ${version} (build ${build}), night of ${night}"

current="$(git branch --show-current)"
if [ "${current}" = "${branch}" ]; then ok "on ${branch}"; else problem "on «${current}», not ${branch}"; fi

if [ -e "${marker}" ]; then
  problem "a release already came out this night: ${marker}"
else
  ok "no release this night yet"
fi

# The tags as this clone knows them; a real run fetches first, a dry run fetches nothing.
if [ -z "${dry_run}" ]; then
  git fetch --quiet --tags origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" \
    "+refs/heads/gh-pages:refs/remotes/origin/gh-pages" ||
    stop "could not fetch ${branch}, the tags and gh-pages from origin"
fi
if git rev-parse -q --verify "refs/tags/${tag}" > /dev/null; then
  problem "the tag ${tag} exists already: raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml"
else
  ok "no tag ${tag} yet"
fi

if grep -qF "## [${version}]" CHANGELOG.md; then
  ok "CHANGELOG.md has a section [${version}]"
else
  problem "CHANGELOG.md has no section «## [${version}]»: the release notes come from it"
fi

if grew="$("${here}/release-version.sh" grew 2>&1)"; then ok "${grew}"; else problem "${grew}"; fi

# Untracked files may only be new source code, tests, resources and migrations. Whatever else
# lies around — notes, exports, a database — is not the night's to publish.
allowed='^(Apps/macOS/(App|Shared|Features|Platform|Resources|Tests|UITests)/|Packages/(AppCore|AppDatabase)/(Sources|Tests)/|Schema/[0-9]{4}_[a-z0-9_]+\.sql$)'
personal='\.(sqlite|sqlite-wal|sqlite-shm|numbers|pem|key|p12|itogoarchive)$'
untracked="$(git ls-files --others --exclude-standard)"
outside="$(printf '%s\n' "${untracked}" | grep -vE "${allowed}" | grep -v '^$' || true)"
data="$(printf '%s\n' "${untracked}" | grep -E "${personal}" || true)"
csv="$(printf '%s\n' "${untracked}" | grep -E '\.csv$' | grep -v '/Fixtures/' || true)"
if [ -n "${outside}${data}${csv}" ]; then
  problem "untracked files outside the allowed folders, or personal data:"$'\n'"$(printf '%s\n' "${outside}" "${data}" "${csv}" | grep -v '^$' | sort -u | sed 's/^/      /')"
else
  ok "untracked files: $(printf '%s\n' "${untracked}" | grep -c . || true), all in the allowed folders"
fi

if [ "$(git config user.name)" = "${author_name}" ] && [ "$(git config user.email)" = "${author_email}" ]; then
  ok "author ${author_name} <${author_email}>"
else
  problem "git author is «$(git config user.name) <$(git config user.email)>», not ${author_name} <${author_email}>"
fi
case "$(git config core.hooksPath || true)" in
  scripts/git-hooks | "${root}/scripts/git-hooks") ok "hooks of the repository are on" ;;
  *) problem "the hooks of the repository are off: run make hooks" ;;
esac

if [ -f sparkle-public-key.txt ]; then ok "sparkle-public-key.txt is there"; else problem "no sparkle-public-key.txt"; fi

if [ -n "$(git rev-parse -q --verify "refs/remotes/origin/${branch}" || true)" ] &&
  git merge-base --is-ancestor "origin/${branch}" HEAD; then
  ok "origin/${branch} is behind or at HEAD: the push is a fast-forward"
else
  problem "HEAD does not contain origin/${branch}: the push would not be a fast-forward"
fi

if [ -z "${dry_run}" ]; then
  # Signed in, without printing anything the status says about the token.
  gh auth status --hostname github.com > /dev/null 2>&1 || problem "gh is not signed in to github.com"
fi

changed="$( (git diff --name-only; git diff --cached --name-only; printf '%s\n' "${untracked}") | grep -v '^$' | sort -u || true)"

plan() {
  cat << EOF
night-release: plan
  1. make verify                          — must end with «verify: green» and «pandas: checked»
  2. commit $(printf '%s\n' "${changed}" | grep -c . || true) file(s) as «${NIGHT_RELEASE_MESSAGE:-Itogo ${version}}» (git add -- <files>)
  3. make release-local ARGS=--dry-run, then make release-local
                                          — Release build, signature, ${release_dir##*/}/Itogo-${version}.zip, appcast entry
  4. codesign --verify --deep --strict; sign_update --verify; unzip -l holds Itogo.app only
     make release-check CANDIDATE=${release_dir}/Release/Itogo.app
  5. git push origin ${branch}; wait up to ${ci_minutes} min for CI (build.yml) on that commit
  6. gh release create ${tag} Itogo-${version}.zip --repo ${repo} --target <commit> --title "Itogo ${version}"
     --notes-file <section [${version}] of CHANGELOG.md>
  7. appcast.xml of origin/gh-pages + the entry → new commit on gh-pages → git push origin <commit>:refs/heads/gh-pages
     gh api -X POST repos/${repo}/pages/builds
  8. make release-check V=${version}, every minute for up to 20 min
  9. print the address of the release; a line in ${journal}; marker ${marker}
  notarization: none — no Developer ID, the app is signed locally
EOF
}

if [ -n "${problems}" ]; then
  [ -z "${dry_run}" ] || plan
  stop "the checks failed:"$'\n'"${problems}"
fi
if [ -n "${dry_run}" ]; then
  plan
  say "dry run: every check passed; nothing was changed"
  exit 0
fi

# From here on everything said goes to a log of the night as well.
log="${archive_dir}/night-release-${night}.log"
exec > >(tee -a "${log}") 2>&1
say "log: ${log}"

# --- 2. make verify --------------------------------------------------------------------------

verify_log="$(mktemp -t itogo-night-verify)"
if ! make verify 2>&1 | tee "${verify_log}"; then
  stop "make verify failed; nothing was committed or published"
fi
grep -qx 'verify: green' "${verify_log}" || stop "make verify did not say «verify: green»"
grep -qx 'pandas: checked' "${verify_log}" || stop "make verify did not check the CSV with pandas (make pyenv)"
rm -f "${verify_log}"

# --- 3. Commit -------------------------------------------------------------------------------

# make fmt inside verify may have touched more files; untracked ones are checked again.
untracked="$(git ls-files --others --exclude-standard)"
outside="$(printf '%s\n' "${untracked}" | grep -vE "${allowed}" | grep -v '^$' || true)"
[ -z "${outside}" ] || stop "make verify left untracked files outside the allowed folders:"$'\n'"${outside}"
files="$( (git diff --name-only; git diff --cached --name-only; printf '%s\n' "${untracked}") | grep -v '^$' | sort -u || true)"
if [ -n "${files}" ]; then
  # One name per line into git: names with spaces stay whole.
  printf '%s\n' "${files}" | tr '\n' '\0' | xargs -0 git add --
  make check-privacy
  git commit --quiet -m "${NIGHT_RELEASE_MESSAGE:-Itogo ${version}}"
  say "committed $(printf '%s\n' "${files}" | grep -c .) file(s): $(git rev-parse --short HEAD)"
else
  say "nothing to commit; releasing HEAD $(git rev-parse --short HEAD)"
fi
[ -z "$(git status --porcelain --untracked-files=all)" ] || stop "the tree is not clean after the commit"
commit="$(git rev-parse HEAD)"

# --- 4. Build, sign, package -----------------------------------------------------------------

make release-local ARGS=--dry-run
make release-local
app="${release_dir}/Release/Itogo.app"
zip="${release_dir}/Itogo-${version}.zip"
entry="${release_dir}/appcast-entry-${version}.xml"
[ -d "${app}" ] && [ -f "${zip}" ] && [ -f "${entry}" ] || stop "make release-local left no app, archive or entry"
codesign --verify --deep --strict "${app}" || stop "the signature of the built app does not verify"
signer="${HOME}/Library/Developer/Itogo/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "${signer}" ] || stop "Sparkle's sign_update is not at ${signer}"
signature="$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' "${entry}" | head -n 1)"
length="$(stat -f%z "${zip}")"
[ -n "${signature}" ] || stop "the entry carries no signature"
"${signer}" --verify "${zip}" "${signature}" || stop "the archive does not verify against the signature of its entry"
if unzip -Z1 "${zip}" | grep -vE '^(Itogo\.app/|__MACOSX/)' | grep -q .; then
  stop "the archive holds something besides Itogo.app"
fi
make release-check CANDIDATE="${app}"

notes="$(mktemp -t itogo-night-notes)"
awk -v head="## [${version}]" '
  index($0, head) == 1 { on = 1; next }
  on && /^## / { exit }
  on { print }
' CHANGELOG.md > "${notes}"
[ -s "${notes}" ] || stop "the section [${version}] of CHANGELOG.md is empty"
if grep -qiE 'Co-Authored-By|Generated with|-Session:' "${notes}"; then
  stop "the release notes carry an attribution line"
fi

# --- 5. Push and CI --------------------------------------------------------------------------

git push --quiet origin "${branch}" || stop "git push of ${branch} failed (it is never forced)"
say "pushed ${branch} at $(git rev-parse --short "${commit}"); waiting for CI"
deadline=$(($(date +%s) + ci_minutes * 60))
while :; do
  state="$(gh run list --repo "${repo}" --workflow build.yml --commit "${commit}" \
    --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2> /dev/null || true)"
  case "${state}" in
    "completed success") say "CI is green"; break ;;
    completed*) stop "CI on ${commit} ended «${state#completed }»; nothing was published" ;;
  esac
  [ "$(date +%s)" -lt "${deadline}" ] || stop "CI did not finish in ${ci_minutes} min; nothing was published"
  sleep 60
done

# --- 6. Release, feed ------------------------------------------------------------------------

gh release create "${tag}" "${zip}" --repo "${repo}" --target "${commit}" \
  --title "Itogo ${version}" --notes-file "${notes}" > /dev/null || stop "gh release create failed"
rm -f "${notes}"
git fetch --quiet --tags origin
say "released ${tag}"

# The feed: a new commit on gh-pages without a working tree, every other file of the branch kept.
git fetch --quiet origin "+refs/heads/gh-pages:refs/remotes/origin/gh-pages"
feed="$(mktemp -t itogo-night-appcast)"
git show origin/gh-pages:appcast.xml > "${feed}"
"${here}/release-entry.sh" into "${feed}" "${version}" "${build}" "${length}" "${signature}"
xmllint --noout "${feed}" || stop "the new feed does not parse; the release is out, the feed is not"
blob="$(git hash-object -w "${feed}")"
tree="$( (git ls-tree origin/gh-pages | grep -v $'\tappcast.xml$'; printf '100644 blob %s\tappcast.xml\n' "${blob}") | git mktree)"
pages="$(git commit-tree "${tree}" -p origin/gh-pages -m "Announce Itogo ${version}")"
git push --quiet origin "${pages}:refs/heads/gh-pages" || stop "git push of gh-pages failed; the release is out, the feed is not"
rm -f "${feed}"
gh api -X POST "repos/${repo}/pages/builds" > /dev/null 2>&1 || say "Pages build not asked for; it starts on the push"

checked=""
for _ in $(seq 1 20); do
  if make release-check V="${version}"; then checked="yes"; break; fi
  sleep 60
done
[ -n "${checked}" ] || say "warning: the live feed did not pass make release-check in 20 min; check by hand"

# --- 7. Done ---------------------------------------------------------------------------------

url="$(gh release view "${tag}" --repo "${repo}" --json url --jq .url)"
printf '%s %s (%s) %s %s%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${tag}" "${build}" \
  "$(git rev-parse --short "${commit}")" "${url}" "${checked:+ checked}" >> "${journal}"
printf '%s %s\n' "${tag}" "${url}" > "${marker}"
say "release: ${url}"
