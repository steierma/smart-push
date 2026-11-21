#!/usr/bin/env bash
# Automated test suite for smart-push.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMART_PUSH="${REPO_ROOT}/skills/smart-push/scripts/smart-push.sh"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1" >&2; exit 1; }

setup_fixture_repo() {
  local dir="$1"
  local remote="${dir}-remote.git"
  git init --bare -b main "$remote" >/dev/null
  git init -b main "$dir" >/dev/null
  git -C "$dir" config user.name "Test Bot"
  git -C "$dir" config user.email "bot@example.com"
  git -C "$dir" remote add origin "$remote"
}

# Test 1: Commit + Push with mock provider & metrics JSON
T1="${TMP_BASE}/t1"
setup_fixture_repo "$T1"
echo "export const add = (a, b) => a + b;" > "${T1}/math.js"
SMART_PUSH_MOCK_MSG='```
feat(math): add addition helper.
```' "$SMART_PUSH" --yes --dir "$T1" --provider mock --metrics-json "${T1}/metrics.json" >/dev/null

LAST_MSG="$(git -C "$T1" log -1 --pretty=%s)"
[[ "$LAST_MSG" == "feat(math): add addition helper" ]] || fail "Expected sanitized message, got: $LAST_MSG"
REMOTE_HEAD="$(git --git-dir="${T1}-remote.git" log -1 --pretty=%s)"
[[ "$REMOTE_HEAD" == "feat(math): add addition helper" ]] || fail "Expected remote push, got: $REMOTE_HEAD"
[[ -f "${T1}/metrics.json" ]] || fail "Expected metrics.json to be written"
pass "Sanitizes markdown/period, commits, pushes to origin, and writes metrics JSON"

# Test 2: Secret Leak Guard blocks staged GitHub token BEFORE calling provider
T2="${TMP_BASE}/t2"
setup_fixture_repo "$T2"
# Construct synthetic token at runtime so static secret scanners do not flag this test file
FAKE_PAT="ghp_$(printf '1%.0s' {1..36})"
echo "TOKEN=${FAKE_PAT}" > "${T2}/config.txt"
if "$SMART_PUSH" --yes --dir "$T2" --provider mock >/dev/null 2>&1; then
  fail "Expected secret leak guard to block fake GitHub PAT"
fi
pass "Secret Leak Guard blocks staged tokens before LLM call or commit"

# Test 3: Secret Leak Guard blocks .env files while allowing .env.example
T3="${TMP_BASE}/t3"
setup_fixture_repo "$T3"
echo "API_URL=https://api.example.com" > "${T3}/.env.example"
"$SMART_PUSH" --yes --dir "$T3" --provider mock >/dev/null
echo "SECRET=topsecret" > "${T3}/.env"
if "$SMART_PUSH" --yes --dir "$T3" --provider mock >/dev/null 2>&1; then
  fail "Expected .env file to be blocked"
fi
pass "Secret Leak Guard allows .env.example and blocks .env"

# Test 4: Preserves partial staging when user already ran git add
T4="${TMP_BASE}/t4"
setup_fixture_repo "$T4"
echo "staged" > "${T4}/a.txt"
echo "unstaged" > "${T4}/b.txt"
git -C "$T4" add a.txt
SMART_PUSH_MOCK_MSG="feat: add file a" "$SMART_PUSH" --yes --dir "$T4" --provider mock >/dev/null
[[ -z "$(git -C "$T4" ls-files b.txt)" ]] || fail "Expected unstaged b.txt not to be committed when index was non-empty"
pass "Preserves partial git index when files are already staged"

# Test 5: Multi-repo / Monorepo safety & --all-subrepos support
T5="${TMP_BASE}/t5-meta"
setup_fixture_repo "$T5"
echo "/*
!/.gitignore" > "${T5}/.gitignore"
SMART_PUSH_MOCK_MSG="chore: init meta repo" "$SMART_PUSH" --yes --dir "$T5" --provider mock >/dev/null

setup_fixture_repo "${T5}/service-a"
setup_fixture_repo "${T5}/service-b"
echo "package a" > "${T5}/service-a/main.go"
echo "package b" > "${T5}/service-b/main.go"

# Running in --yes mode on clean parent must NOT silently guess; it must report dirty sub-repos
if "$SMART_PUSH" --yes --dir "$T5" --provider mock >/dev/null 2>&1; then
  fail "Expected clean meta-repo root with dirty subrepos to prompt/exit in non-interactive mode without --dir"
fi

# Positional subrepo path works: smart-push <path>
SMART_PUSH_MOCK_MSG="feat(a): init service a" "$SMART_PUSH" --yes --provider mock "${T5}/service-a" >/dev/null
[[ "$(git --git-dir="${T5}/service-a-remote.git" log -1 --pretty=%s)" == "feat(a): init service a" ]] || fail "Positional path push failed"

# --all-subrepos commits & pushes remaining dirty child repos independently
SMART_PUSH_MOCK_MSG="feat(b): init service b" "$SMART_PUSH" --yes --dir "$T5" --all-subrepos --provider mock >/dev/null
[[ "$(git --git-dir="${T5}/service-b-remote.git" log -1 --pretty=%s)" == "feat(b): init service b" ]] || fail "--all-subrepos push failed"
pass "Handles multi-repo / monorepo boundaries, positional paths, and --all-subrepos safely"

echo "All tests passed."
