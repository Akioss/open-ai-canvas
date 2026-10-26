#!/usr/bin/env bash
# fork-sync.sh 的本地夹具测试。不访问网络，不修改当前仓库。
# shellcheck shell=bash

set -euo pipefail

unset GITHUB_ACTIONS || true
unset SYNC_TOKEN || true
unset ISSUE_TOKEN || true

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/fork-sync.sh"
# shellcheck source=fork-sync.sh
source "$SCRIPT"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "${label}: 期望 [${expected}] 实际 [${actual}]"
  fi
}

commit_all() {
  local dir="$1" message="$2"
  git -C "$dir" add -A
  GIT_AUTHOR_NAME=test \
    GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=test \
    GIT_COMMITTER_EMAIL=test@example.com \
    git -C "$dir" commit -m "$message" >/dev/null
}

init_repo() {
  local dir="$1"
  git init -b main "$dir" >/dev/null
}

test_resolve_auto_merge() {
  AUTO_MERGE_INPUT="" FORK_SYNC_AUTO_MERGE=""
  assert_eq "$(resolve_auto_merge)" "true" "默认自动合并"
  AUTO_MERGE_INPUT="auto" FORK_SYNC_AUTO_MERGE="false"
  assert_eq "$(resolve_auto_merge)" "false" "auto 沿用变量"
  AUTO_MERGE_INPUT="true" FORK_SYNC_AUTO_MERGE="false"
  assert_eq "$(resolve_auto_merge)" "true" "手动输入优先"
  AUTO_MERGE_INPUT="" FORK_SYNC_AUTO_MERGE="no"
  assert_eq "$(resolve_auto_merge)" "false" "no 视为关闭"
  AUTO_MERGE_INPUT="maybe" FORK_SYNC_AUTO_MERGE=""
  assert_eq "$(resolve_auto_merge)" "invalid" "非法取值"
}

test_classify_push_error() {
  local sample='gh: refusing to allow a GitHub App to create or update workflow `.github/workflows/quality.yml` without `workflows` permission (HTTP 422)'
  assert_eq "$(classify_push_error "$sample")" "workflows_permission" "quality.yml 422"
  sample='remote: error: GH006: Protected branch update failed for refs/heads/main.'
  assert_eq "$(classify_push_error "$sample")" "branch_protection" "分支保护"
  sample='! [rejected] main -> main (non-fast-forward)'
  assert_eq "$(classify_push_error "$sample")" "stale_main" "main 已前进"
  sample='remote: Invalid username or token. Authentication failed.'
  assert_eq "$(classify_push_error "$sample")" "auth" "令牌无效"
}

test_fingerprint() {
  local body='<!-- fork-sync-fingerprint: conflict|abc|2|app.txt -->'
  assert_eq "$(fingerprint_of "$body")" "conflict|abc|2|app.txt" "指纹"
}

test_missing_token_message() {
  local body
  body=$(render_missing_token "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "40")
  if ! printf '%s\n' "$body" | grep -q 'SYNC_TOKEN'; then
    fail "缺密钥说明应写出 SYNC_TOKEN"
  fi
  if ! printf '%s\n' "$body" | grep -q 'Workflows'; then
    fail "缺密钥说明应写出 Workflows 权限"
  fi
  if ! printf '%s\n' "$body" | grep -q '不要合并这张草稿 PR'; then
    fail "草稿 PR 不应被合并"
  fi
  assert_eq "$(fingerprint_of "$body")" "missing-token|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|40" "缺密钥指纹"
}

test_refspecs_are_fixed() {
  local tracking main_push alert
  tracking=$(awk '/^push_tracking_branch\(\)/{flag=1} flag{print} /^}$/{if(flag) exit}' "$SCRIPT")
  main_push=$(awk '/^push_main_commit\(\)/{flag=1} flag{print} /^}$/{if(flag) exit}' "$SCRIPT")
  alert=$(awk '/^push_alert_commit\(\)/{flag=1} flag{print} /^}$/{if(flag) exit}' "$SCRIPT")
  if ! printf '%s\n' "$tracking" | grep -q -- '--force'; then
    fail "upstream 跟踪分支应强制对齐"
  fi
  if ! printf '%s\n' "$tracking" | grep -q 'refs/heads/upstream'; then
    fail "跟踪分支目标应为 upstream"
  fi
  if printf '%s\n' "$tracking" | grep -q 'refs/heads/main'; then
    fail "跟踪分支推送不能指向 main"
  fi
  if printf '%s\n' "$main_push" | grep -q -- '--force'; then
    fail "main 不能强制推送"
  fi
  if ! printf '%s\n' "$main_push" | grep -q 'refs/heads/main'; then
    fail "自动合并应推送到 main"
  fi
  if ! printf '%s\n' "$alert" | grep -q 'refs/heads/fork-sync/alert'; then
    fail "失败通知分支固定"
  fi
  if printf '%s\n' "$alert" | grep -q 'refs/heads/main'; then
    fail "失败通知不能写入 main"
  fi
}

test_merge_preserves_fork_files_and_skip_ci() {
  local tmp repo base upstream result status sha quality sync_body
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/.github/workflows" "$repo/.github"
  printf 'FORK\n' >"$repo/.github/workflows/sync-upstream.yml"
  printf 'DOC\n' >"$repo/.github/FORK_SYNC.md"
  printf 'v1\n' >"$repo/quality.yml"
  printf 'alert\n' >"$repo/.github/fork-sync-alert.md"
  commit_all "$repo" "base"
  base=$(git -C "$repo" rev-parse HEAD)

  printf 'CLOBBER\n' >"$repo/.github/workflows/sync-upstream.yml"
  printf 'v2\n' >"$repo/quality.yml"
  rm -f "$repo/.github/FORK_SYNC.md"
  commit_all "$repo" "upstream clobber"
  upstream=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/heads/main "$base"

  result=$(attempt_merge "$repo" "$base" "$upstream")
  status=$(printf '%s\n' "$result" | head -n 1)
  sha=$(printf '%s\n' "$result" | tail -n +2 | head -n 1)
  assert_eq "$status" "clean" "干净合并状态"
  assert_merge_commit "$repo" "$base" "$sha" || fail "合并提交不满足 fork 约束"
  quality=$(git -C "$repo" show "${sha}:quality.yml")
  sync_body=$(git -C "$repo" show "${sha}:.github/workflows/sync-upstream.yml")
  assert_eq "$quality" "v2" "上游业务文件应进入合并结果"
  assert_eq "$sync_body" "FORK" "同步工作流应保持 main 的内容"
  if ! git -C "$repo" cat-file -e "${sha}:.github/FORK_SYNC.md" 2>/dev/null; then
    fail "被上游删除的 fork 文档应被恢复"
  fi
  if git -C "$repo" cat-file -e "${sha}:.github/fork-sync-alert.md" 2>/dev/null; then
    fail "通知文件不应进入 main"
  fi
  if git -C "$repo" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    fail "主工作树不应停留在合并中"
  fi
  rm -rf "$tmp"
}

test_conflict_lists_file_and_aborts() {
  local tmp repo base_commit main_sha upstream_sha result status files
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  init_repo "$repo"
  printf 'base\n' >"$repo/app.txt"
  commit_all "$repo" "base"
  base_commit=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" branch upstream "$base_commit"

  printf 'fork\n' >"$repo/app.txt"
  commit_all "$repo" "fork edit"
  main_sha=$(git -C "$repo" rev-parse HEAD)

  git -C "$repo" checkout -q upstream
  printf 'upstream\n' >"$repo/app.txt"
  commit_all "$repo" "upstream edit"
  upstream_sha=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main

  result=$(attempt_merge "$repo" "$main_sha" "$upstream_sha")
  status=$(printf '%s\n' "$result" | head -n 1)
  files=$(printf '%s\n' "$result" | tail -n +2)
  assert_eq "$status" "conflict" "冲突状态"
  if ! printf '%s\n' "$files" | grep -qx 'app.txt'; then
    fail "应列出 app.txt，实际 [${files}]"
  fi
  if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
    fail "冲突测试后工作树应干净"
  fi
  rm -rf "$tmp"
}

run_main() {
  local fork="$1"
  shift
  local output code
  set +e
  output=$(cd "$fork" && env \
    GITHUB_ACTIONS= \
    ISSUE_TOKEN= \
    UPSTREAM_HEAD=main \
    REPO=local/test \
    "$@" \
    bash "$SCRIPT" 2>&1)
  code=$?
  set -e
  printf '%s\n' "$code"
  printf '%s\n' "$output"
}

test_main_dry_run_does_not_push() {
  local tmp src upstream origin fork base_sha before after result code output
  tmp=$(mktemp -d)
  src="$tmp/src"
  init_repo "$src"
  mkdir -p "$src/.github/workflows"
  printf 'FORK\n' >"$src/.github/workflows/sync-upstream.yml"
  printf 'v1\n' >"$src/quality.yml"
  commit_all "$src" "base"
  git clone --quiet "$src" "$tmp/upstream"
  printf 'v2\n' >"$tmp/upstream/quality.yml"
  commit_all "$tmp/upstream" "upstream feature"
  git clone --bare --quiet "$src" "$tmp/origin.git"
  git clone --quiet "$tmp/origin.git" "$tmp/fork"
  before=$(git -C "$tmp/origin.git" rev-parse main)

  result=$(run_main "$tmp/fork" DRY_RUN=1 SYNC_TOKEN=dummy UPSTREAM_URL="$tmp/upstream")
  code=$(printf '%s\n' "$result" | head -n 1)
  output=$(printf '%s\n' "$result" | tail -n +2)
  assert_eq "$code" "0" "干净 dry-run 应成功"
  if ! printf '%s\n' "$output" | grep -q 'result=dry_clean'; then
    fail "dry-run 应报告 dry_clean: ${output}"
  fi
  after=$(git -C "$tmp/origin.git" rev-parse main)
  assert_eq "$after" "$before" "dry-run 不能推送 main"
  if git -C "$tmp/origin.git" rev-parse --verify refs/heads/upstream >/dev/null 2>&1; then
    fail "dry-run 不能创建 upstream 分支"
  fi

  result=$(run_main "$tmp/fork" DRY_RUN=1 SYNC_TOKEN= UPSTREAM_URL="$tmp/upstream")
  code=$(printf '%s\n' "$result" | head -n 1)
  output=$(printf '%s\n' "$result" | tail -n +2)
  assert_eq "$code" "2" "缺少令牌应退出 2"
  if ! printf '%s\n' "$output" | grep -q 'result=missing-token'; then
    fail "应报告 missing-token: ${output}"
  fi
  if ! printf '%s\n' "$output" | grep -q 'SYNC_TOKEN'; then
    fail "缺少令牌的输出应包含密钥名"
  fi

  git -C "$tmp/fork" fetch --quiet origin
  git -C "$tmp/fork" checkout -q main
  printf 'fork-side\n' >"$tmp/fork/quality.yml"
  commit_all "$tmp/fork" "diverge"
  git -C "$tmp/fork" push --quiet origin main
  result=$(run_main "$tmp/fork" DRY_RUN=1 SYNC_TOKEN=dummy UPSTREAM_URL="$tmp/upstream")
  code=$(printf '%s\n' "$result" | head -n 1)
  output=$(printf '%s\n' "$result" | tail -n +2)
  assert_eq "$code" "1" "冲突 dry-run 应失败"
  if ! printf '%s\n' "$output" | grep -q 'result=conflict'; then
    fail "应报告 conflict: ${output}"
  fi
  if ! printf '%s\n' "$output" | grep -q 'quality.yml'; then
    fail "冲突文件应包含 quality.yml"
  fi
  base_sha=$(git -C "$tmp/origin.git" rev-parse main)
  git -C "$tmp/fork" rev-parse HEAD >/dev/null
  assert_eq "$(git -C "$tmp/origin.git" rev-parse main)" "$base_sha" "冲突 dry-run 不能推送"
  rm -rf "$tmp"
}

test_render_many_commits() {
  local tmp repo base i body fp
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  init_repo "$repo"
  printf 'base\n' >"$repo/readme.txt"
  commit_all "$repo" "base"
  base=$(git -C "$repo" rev-parse HEAD)
  for i in $(seq 1 25); do
    printf '%s\n' "$i" >"$repo/readme.txt"
    commit_all "$repo" "upstream $i"
  done
  (
    cd "$repo"
    body=$(render_sync_pr "$(git rev-parse HEAD)" "$base" 25 conflict $'quality.yml\napp.txt')
    printf '%s\n' "$body" >"$tmp/body.md"
  )
  body=$(cat "$tmp/body.md")
  if ! printf '%s\n' "$body" | grep -q '另有 5 个提交未列出'; then
    fail "超过 20 个提交时应截断列表"
  fi
  if ! printf '%s\n' "$body" | grep -q '不要在 `upstream` 分支上提交'; then
    fail "冲突说明应禁止在 upstream 上解决冲突"
  fi
  fp=$(fingerprint_of "$body")
  if [[ "$fp" == *$'\n'* || -z "$fp" ]]; then
    fail "指纹必须是单行且非空: [${fp}]"
  fi
  if [[ "${fp#conflict|}" == "$fp" || "$fp" != *"|25|quality.yml,app.txt" ]]; then
    fail "冲突指纹不正确: [${fp}]"
  fi
  rm -rf "$tmp"
}

test_validate_sha() {
  if ! validate_sha "0123456789abcdef0123456789abcdef01234567"; then
    fail "合法 SHA 被拒绝"
  fi
  if validate_sha "not-a-sha"; then
    fail "非法 SHA 被接受"
  fi
  if validate_sha "refs/heads/main"; then
    fail "分支名不能当作 SHA"
  fi
}

main_tests() {
  test_resolve_auto_merge
  test_classify_push_error
  test_fingerprint
  test_missing_token_message
  test_render_many_commits
  test_refspecs_are_fixed
  test_validate_sha
  test_merge_preserves_fork_files_and_skip_ci
  test_conflict_lists_file_and_aborts
  test_main_dry_run_does_not_push
  if [[ "$FAILURES" -ne 0 ]]; then
    printf '%s\n' "失败 ${FAILURES} 项" >&2
    exit 1
  fi
  printf '%s\n' "fork-sync 测试通过"
}

main_tests
