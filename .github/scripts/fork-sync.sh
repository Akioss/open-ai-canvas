#!/usr/bin/env bash
# 个人 fork 同步上游 ddcat-ai/open-ai-canvas。
# 只允许在 Akioss/open-ai-canvas 的 Actions 中实际推送。设计说明见 .github/FORK_SYNC.md。
# shellcheck shell=bash

set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ddcat-ai/open-ai-canvas.git}"
UPSTREAM_HEAD="${UPSTREAM_HEAD:-main}"
FORK_OWNED_FILES=(
  ".github/workflows/sync-upstream.yml"
  ".github/scripts/fork-sync.sh"
  ".github/scripts/test_fork_sync.sh"
  ".github/FORK_SYNC.md"
)
ALERT_FILE=".github/fork-sync-alert.md"
ALERT_BRANCH="fork-sync/alert"
TRACKING_BRANCH="upstream"
TARGET_BRANCH="main"
ISSUE_TITLE="上游同步需要处理"

WORKFLOW_WARNING_MD=""
ACTIVE_WORKFLOW_PATHS=""
LAST_PUSH_OUTPUT=""
LAST_PR_ERROR=""
RUN_DIR=""

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "fork-sync: fatal: $*"
  exit 1
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

summary_file() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -f "$1" ]]; then
    cat "$1" >>"$GITHUB_STEP_SUMMARY"
    printf '\n' >>"$GITHUB_STEP_SUMMARY"
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_sha() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

redact() {
  printf '%s' "$1" | sed -E \
    -e 's/(ghp_|github_pat_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_]+/[REDACTED]/g' \
    -e 's/x-access-token:[^@[:space:]]+/x-access-token:[REDACTED]/g'
}

short_sha() {
  printf '%s' "${1:0:12}"
}

fingerprint_of() {
  local line
  line=$(printf '%s\n' "$1" | sed -n 's/.*fork-sync-fingerprint: \([^ ]*\).*/\1/p')
  printf '%s' "${line%%$'\n'*}"
}

resolve_auto_merge() {
  local input choice
  input=$(printf '%s' "${AUTO_MERGE_INPUT:-}" | tr '[:upper:]' '[:lower:]')
  if [[ -n "$input" && "$input" != "auto" ]]; then
    choice="$input"
  else
    choice=$(printf '%s' "${FORK_SYNC_AUTO_MERGE:-}" | tr '[:upper:]' '[:lower:]')
  fi
  case "$choice" in
    "" | true | 1 | yes) printf 'true' ;;
    false | 0 | no) printf 'false' ;;
    *) printf 'invalid' ;;
  esac
}

classify_push_error() {
  local text="$1"
  if printf '%s\n' "$text" | grep -Eqi 'without `workflows` permission|without `workflow` scope|refusing to allow .+workflow'; then
    printf 'workflows_permission'
  elif printf '%s\n' "$text" | grep -Eqi 'protected branch|must be made through a pull request|required status check|review required|changes must be made through a pull request'; then
    printf 'branch_protection'
  elif printf '%s\n' "$text" | grep -Eqi 'non-fast-forward|fetch first'; then
    printf 'stale_main'
  elif printf '%s\n' "$text" | grep -Eqi 'Bad credentials|Authentication failed|Invalid username or token|401 Unauthorized'; then
    printf 'auth'
  elif printf '%s\n' "$text" | grep -Eqi '403|Resource not accessible|not granted|permission denied'; then
    printf 'permission_denied'
  else
    printf 'other'
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

export_bot_identity() {
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
  export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
  export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
  export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"
}

gh_as() {
  local token="$1"
  shift
  GH_TOKEN="$token" GITHUB_TOKEN="$token" GH_PAGER=cat PAGER=cat gh "$@"
}

git_public() {
  git -c http.extraheader= "$@"
}

git_authenticated() {
  local token="$1"
  shift
  GH_TOKEN="$token" GITHUB_TOKEN="$token" \
    git -c http.extraheader= \
    -c credential.helper= \
    -c 'credential.helper=!gh auth git-credential' \
    "$@"
}

prepare_repo_network() {
  export GIT_TERMINAL_PROMPT=0
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    git remote set-url origin "https://github.com/${REPO}.git"
    git config --local --unset-all http.https://github.com/.extraheader 2>/dev/null || true
  fi
}

fetch_upstream() {
  git_public fetch --no-tags "$UPSTREAM_URL" \
    "+refs/heads/${UPSTREAM_HEAD}:refs/remotes/upstream-src/${UPSTREAM_HEAD}" || return 1
  UPSTREAM_SHA=$(normalize_sha "$(git rev-parse "refs/remotes/upstream-src/${UPSTREAM_HEAD}")") || return 1
  validate_sha "$UPSTREAM_SHA"
}

fetch_origin_main() {
  if [[ -n "${SYNC_TOKEN:-}" && "${DRY_RUN:-0}" != "1" ]]; then
    git_authenticated "$SYNC_TOKEN" fetch --no-tags origin \
      "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" || return 1
  else
    git_public fetch --no-tags origin \
      "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" || return 1
  fi
  BASE_SHA=$(normalize_sha "$(git rev-parse "refs/remotes/origin/${TARGET_BRANCH}")") || return 1
  validate_sha "$BASE_SHA" || return 1
  BEHIND=$(git rev-list --count "${BASE_SHA}..${UPSTREAM_SHA}") || return 1
}

restore_fork_owned() {
  local wt="$1" base_sha="$2" file
  for file in "${FORK_OWNED_FILES[@]}"; do
    if git -C "$wt" cat-file -e "${base_sha}:${file}" 2>/dev/null; then
      git -C "$wt" checkout "$base_sha" -- "$file"
      log "fork-sync: 保持 fork 自有文件 ${file}"
    fi
  done
  if git -C "$wt" ls-files --error-unmatch -- "$ALERT_FILE" >/dev/null 2>&1; then
    git -C "$wt" rm -f -- "$ALERT_FILE"
    log "fork-sync: 从合并结果移除 ${ALERT_FILE}"
  fi
}

merge_commit_message() {
  local upstream_sha="$1" base_sha="$2"
  cat <<EOF
chore(fork): 上游同步 - 合并 ddcat-ai/open-ai-canvas@$(short_sha "$upstream_sha")

将上游 main ${upstream_sha}
合并到 fork main（基线 ${base_sha}）。
fork 自有文件保持 main 上的版本。

[skip ci]
EOF
}

remove_worktree() {
  local repo="$1" wt="$2"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt"
}

# stdout 协议：第一行是 clean|conflict|error，其余是 SHA 或文件列表或错误文本。
attempt_merge() {
  local repo="$1" base_sha="$2" upstream_sha="$3"
  local wt merge_code conflicts new_sha
  export_bot_identity
  wt=$(mktemp -d)
  if ! git -C "$repo" worktree add --detach "$wt" "$base_sha" >&2; then
    rm -rf "$wt"
    printf 'error\n无法创建 worktree\n'
    return 0
  fi
  merge_code=0
  git -C "$wt" merge --no-commit --no-ff "$upstream_sha" >&2 || merge_code=$?
  conflicts=$(git -C "$wt" diff --name-only --diff-filter=U || true)
  if [[ "$merge_code" -ne 0 || -n "$conflicts" ]]; then
    git -C "$wt" merge --abort >&2 || true
    remove_worktree "$repo" "$wt"
    if [[ -n "$conflicts" ]]; then
      printf 'conflict\n%s\n' "$conflicts"
    else
      printf 'error\n合并失败（exit %s）\n' "$merge_code"
    fi
    return 0
  fi
  if ! restore_fork_owned "$wt" "$base_sha" >&2; then
    remove_worktree "$repo" "$wt"
    printf 'error\n恢复 fork 自有文件失败\n'
    return 0
  fi
  if ! git -C "$wt" commit -m "$(merge_commit_message "$upstream_sha" "$base_sha")" >&2; then
    remove_worktree "$repo" "$wt"
    printf 'error\n无法创建合并提交\n'
    return 0
  fi
  new_sha=$(git -C "$wt" rev-parse HEAD)
  remove_worktree "$repo" "$wt"
  printf 'clean\n%s\n' "$new_sha"
}

assert_merge_commit() {
  local repo="$1" base_sha="$2" new_sha="$3" file base_blob new_blob message
  validate_sha "$new_sha" || return 1
  message=$(git -C "$repo" log -1 --format=%B "$new_sha")
  printf '%s\n' "$message" | grep -q '\[skip ci\]' || {
    log "fork-sync: 合并提交缺少 [skip ci]"
    return 1
  }
  for file in "${FORK_OWNED_FILES[@]}"; do
    if git -C "$repo" cat-file -e "${base_sha}:${file}" 2>/dev/null; then
      base_blob=$(git -C "$repo" rev-parse "${base_sha}:${file}")
      if ! new_blob=$(git -C "$repo" rev-parse "${new_sha}:${file}" 2>/dev/null); then
        log "fork-sync: 合并结果缺少 fork 自有文件 ${file}"
        return 1
      fi
      if [[ "$base_blob" != "$new_blob" ]]; then
        log "fork-sync: fork 自有文件被上游改写 ${file}"
        return 1
      fi
    fi
  done
  if git -C "$repo" cat-file -e "${new_sha}:${ALERT_FILE}" 2>/dev/null; then
    log "fork-sync: ${ALERT_FILE} 不应进入 main"
    return 1
  fi
  return 0
}

push_tracking_branch() {
  local sha="$1"
  validate_sha "$sha" || return 1
  local code=0
  LAST_PUSH_OUTPUT=$(git_authenticated "$SYNC_TOKEN" push --force origin "${sha}:refs/heads/upstream" 2>&1) || code=$?
  printf '%s\n' "$(redact "$LAST_PUSH_OUTPUT")" >&2
  return "$code"
}

push_main_commit() {
  local sha="$1"
  validate_sha "$sha" || return 1
  # 只做普通推送。main 上的个人提交不能被强制覆盖。
  local code=0
  LAST_PUSH_OUTPUT=$(git_authenticated "$SYNC_TOKEN" push origin "${sha}:refs/heads/main" 2>&1) || code=$?
  printf '%s\n' "$(redact "$LAST_PUSH_OUTPUT")" >&2
  return "$code"
}

push_alert_commit() {
  local sha="$1"
  validate_sha "$sha" || return 1
  local code=0
  LAST_PUSH_OUTPUT=$(git_authenticated "$ISSUE_TOKEN" push --force origin "${sha}:refs/heads/fork-sync/alert" 2>&1) || code=$?
  printf '%s\n' "$(redact "$LAST_PUSH_OUTPUT")" >&2
  return "$code"
}

truncate_text() {
  local text="$1" limit="${2:-2000}"
  printf '%s' "${text:0:limit}"
}

recent_upstream_commits() {
  local base_sha="$1" upstream_sha="$2" count shown
  count=$(git rev-list --count "${base_sha}..${upstream_sha}")
  shown=$(git log -n 20 --format='%h %s' "${base_sha}..${upstream_sha}" | sed "s/\`/'/g")
  printf '%s\n' "$shown"
  if [[ "$count" -gt 20 ]]; then
    printf '%s\n' "... 另有 $((count - 20)) 个提交未列出"
  fi
}

resolution_steps() {
  cat <<'EOF'
### 如何解决冲突

不要在 `upstream` 分支上提交，也不要点 PR 页面的 Resolve conflicts。那个分支每次同步都会被强制对齐上游，页面上的冲突解决会写到 `upstream`，下一次运行会被覆盖。

在 `main` 上合并：

```bash
git fetch origin
git checkout main
git pull origin main
git fetch origin upstream:refs/remotes/origin/upstream
git merge origin/upstream
```

若冲突落在 fork 自有文件上，保留 main 的版本：

```bash
git checkout --ours -- \
  .github/workflows/sync-upstream.yml \
  .github/scripts/fork-sync.sh \
  .github/scripts/test_fork_sync.sh \
  .github/FORK_SYNC.md
git add -- \
  .github/workflows/sync-upstream.yml \
  .github/scripts/fork-sync.sh \
  .github/scripts/test_fork_sync.sh \
  .github/FORK_SYNC.md
```

解决其余冲突后：

```bash
git commit
git push origin main
```

推送成功后，下一次同步发现 main 已包含上游提交，会关掉这张 PR。
EOF
}

workflow_section() {
  if [[ -n "$WORKFLOW_WARNING_MD" ]]; then
    printf '\n### Actions 工作流\n\n%s\n' "$WORKFLOW_WARNING_MD"
  fi
}

render_missing_token() {
  local upstream_sha="$1" base_sha="$2" behind="$3"
  cat <<EOF
<!-- fork-sync-fingerprint: missing-token|${upstream_sha}|${behind} -->

## 上游同步没有运行：缺少 SYNC_TOKEN

工作流不会回退到 \`github.token\`。2026-10-22 起的连续失败就是因为默认令牌没有 \`workflows\` 权限，上游一旦修改 \`.github/workflows/\`，同步会被 GitHub 拒绝。

- 上游：\`ddcat-ai/open-ai-canvas\` \`${upstream_sha}\`
- 本仓库 \`main\`：\`${base_sha}\`
- \`main\` 落后：${behind} 个提交

### 一次性设置

1. 打开 GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token。
2. Resource owner 选 **Akioss**，Repository access 只选 **open-ai-canvas**。
3. Repository permissions：
   - Contents: Read and write
   - Workflows: Read and write
   - Pull requests: Read and write
4. 本仓库 Settings → Secrets and variables → Actions → Secrets → New repository secret。名称必须是 \`SYNC_TOKEN\`。
5. 确认本 PR 已经合并到 \`main\` 后，打开 Actions → Sync upstream → Run workflow。

classic PAT 需要同时勾选 \`repo\` 和 \`workflow\`。GitHub App 的 installation token 大约一小时过期，不要直接存进 \`SYNC_TOKEN\`。

说明见 [\`.github/FORK_SYNC.md\`](https://github.com/Akioss/open-ai-canvas/blob/main/.github/FORK_SYNC.md)。

**不要合并这张草稿 PR。** 它只用来通知。密钥生效并重新运行后，工作流会关闭它。
$(workflow_section)
EOF
}

render_token_rejected() {
  local upstream_sha="$1" base_sha="$2" behind="$3" kind="$4" detail="$5"
  local advice
  case "$kind" in
    workflows_permission)
      advice='现有 SYNC_TOKEN 不能修改 `.github/workflows/`。请换成带 Contents、Workflows、Pull requests 读写权限的 fine-grained PAT（或同时勾选 `repo` 与 `workflow` 的 classic PAT），更新同名密钥后再运行。'
      ;;
    auth | permission_denied)
      advice='SYNC_TOKEN 被 GitHub 拒绝。请确认密钥未过期、未撤销，并且只授予本仓库的 Contents、Workflows、Pull requests 读写权限。'
      ;;
    *)
      advice='推送 `upstream` 分支失败。请根据下面的错误更新 SYNC_TOKEN 或仓库权限后，再运行 Sync upstream。'
      ;;
  esac
  cat <<EOF
<!-- fork-sync-fingerprint: token-${kind}|${upstream_sha}|${behind} -->

## 上游同步被拒绝

${advice}

- 上游：\`ddcat-ai/open-ai-canvas\` \`${upstream_sha}\`
- 本仓库 \`main\`：\`${base_sha}\`
- \`main\` 落后：${behind} 个提交
- 分类：\`${kind}\`

\`\`\`
$(truncate_text "$(redact "$detail")" 2000)
\`\`\`

说明见 [\`.github/FORK_SYNC.md\`](https://github.com/Akioss/open-ai-canvas/blob/main/.github/FORK_SYNC.md)。

**不要合并这张草稿 PR。**
$(workflow_section)
EOF
}

render_sync_pr() {
  local upstream_sha="$1" base_sha="$2" behind="$3" state="$4" extra="$5"
  local heading note fp_extra
  fp_extra=$(printf '%s' "$extra" | tr '\n' ',' | tr ' ' '_')
  fp_extra=${fp_extra//-->/-}
  case "$state" in
    conflict)
      heading="main 合并上游时有冲突"
      note="自动合并已取消。请按下面的步骤在 \`main\` 上解决冲突。"
      ;;
    needs_review)
      heading="上游可以合并，等待你确认"
      note="没有冲突。\`FORK_SYNC_AUTO_MERGE\` 当前关闭，所以工作流只打开这张 PR。页面上的 Merge 可以合并；提交说明里不会自动带 \`[skip ci]\`，请保持 Publish container images 关闭。"
      ;;
    push_failed)
      heading="自动合并没有写进 main"
      note="本地合并是干净的，但推送 \`main\` 被拒绝。可以在确认分支保护允许后合并这张 PR，或修正权限后重新运行工作流。"
      ;;
    *)
      heading="上游同步需要处理"
      note="$state"
      ;;
  esac
  cat <<EOF
<!-- fork-sync-fingerprint: ${state}|${upstream_sha}|${behind}|${fp_extra} -->

## ${heading}

${note}

- 上游：[\`ddcat-ai/open-ai-canvas@${upstream_sha}\`](https://github.com/ddcat-ai/open-ai-canvas/commit/${upstream_sha})
- 本仓库 \`main\`：\`${base_sha}\`
- \`main\` 落后：${behind} 个提交
- 跟踪分支：\`upstream\`（与上游 main 同一提交，不要在上面开发）

### 上游提交

\`\`\`
$(recent_upstream_commits "$base_sha" "$upstream_sha")
\`\`\`

$(if [[ "$state" == "conflict" ]]; then
    printf '### 冲突文件\n\n```\n%s\n```\n\n%s\n' "$extra" "$(resolution_steps)"
  fi)
$(if [[ "$state" == "push_failed" ]]; then
    printf '### 推送错误\n\n```\n%s\n```\n' "$(truncate_text "$(redact "$extra")" 2000)"
  fi)

说明见 [\`.github/FORK_SYNC.md\`](https://github.com/Akioss/open-ai-canvas/blob/main/.github/FORK_SYNC.md)。
$(workflow_section)
EOF
}

collect_workflow_warnings() {
  local token="${ISSUE_TOKEN:-${SYNC_TOKEN:-}}" raw
  ACTIVE_WORKFLOW_PATHS=""
  if [[ -z "$token" ]]; then
    WORKFLOW_WARNING_MD="未能检查 Actions 工作流状态。"
    return 0
  fi
  if ! raw=$(gh_as "$token" api "repos/${REPO}/actions/workflows?per_page=100" \
    --jq '.workflows[] | select(.state=="active" and .path != ".github/workflows/sync-upstream.yml") | .path' 2>"$RUN_DIR/workflows.err"); then
    WORKFLOW_WARNING_MD="未能读取 Actions 工作流列表。请到 Actions 页面确认 Quality checks 与 Publish container images 已关闭。"
    log "fork-sync: $(cat "$RUN_DIR/workflows.err")"
    return 0
  fi
  ACTIVE_WORKFLOW_PATHS="$raw"
  if [[ -z "$raw" ]]; then
    WORKFLOW_WARNING_MD="除同步工作流外，没有启用中的 Actions 工作流。"
    return 0
  fi
  WORKFLOW_WARNING_MD="以下工作流仍启用。同步 PR 会触发其中的 \`pull_request\` 工作流；推送到 \`main\` 会触发其中的 \`push\` 工作流。建议在 Actions 页面逐个 Disable workflow。手动关闭后，上游更新同名文件不会把它重新打开："
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    WORKFLOW_WARNING_MD+=$'\n'"- \`${path}\`"
    printf '::warning title=上游工作流仍启用::%s 仍是启用状态。请在 Actions 页面关闭，避免 fork 运行上游 CI 或镜像发布。\n' "$path"
  done <<<"$raw"
}

maybe_disable_workflows() {
  local flag line id path status
  flag=$(printf '%s' "${FORK_SYNC_DISABLE_UPSTREAM_WORKFLOWS:-}" | tr '[:upper:]' '[:lower:]')
  case "$flag" in
    true | 1 | yes) ;;
    *) return 0 ;;
  esac
  [[ -n "${SYNC_TOKEN:-}" ]] || return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    id=${line%% *}
    path=${line#* }
    [[ "$path" == ".github/workflows/sync-upstream.yml" ]] && continue
    status=$(gh_as "$SYNC_TOKEN" api --method PUT -i "repos/${REPO}/actions/workflows/${id}/disable" 2>&1 | head -n 1 || true)
    log "fork-sync: 尝试关闭 ${path}（id ${id}）：${status}"
  done < <(gh_as "$SYNC_TOKEN" api "repos/${REPO}/actions/workflows?per_page=100" \
    --jq '.workflows[] | select(.state=="active" and .path != ".github/workflows/sync-upstream.yml") | "\(.id) \(.path)"' || true)
}

update_existing_pr() {
  local token="$1" number="$2" title="$3" body_file="$4"
  local old new old_fp new_fp
  old=$(gh_as "$token" pr view "$number" --repo "$REPO" --json body --jq .body)
  new=$(cat "$body_file")
  old_fp=$(fingerprint_of "$old")
  new_fp=$(fingerprint_of "$new")
  if [[ "$old" == "$new" ]]; then
    log "fork-sync: PR #${number} 无变化"
    return 0
  fi
  gh_as "$token" pr edit "$number" --repo "$REPO" --title "$title" --body-file "$body_file" >/dev/null
  if [[ -n "$new_fp" && -n "$old_fp" && "$old_fp" != "$new_fp" ]]; then
    gh_as "$token" pr comment "$number" --repo "$REPO" \
      --body "上游同步状态有变化（\`${old_fp}\` → \`${new_fp}\`）。处理说明在 PR 正文。" >/dev/null
  fi
}

create_or_update_pr() {
  local token="$1" head="$2" title="$3" body_file="$4" draft="$5"
  local owner number url
  owner="${REPO%%/*}"
  number=$(gh_as "$token" pr list --repo "$REPO" --base "$TARGET_BRANCH" --head "${owner}:${head}" --state open --jq '.[0].number' || true)
  if [[ -n "$number" && "$number" != "null" ]]; then
    update_existing_pr "$token" "$number" "$title" "$body_file"
    gh_as "$token" pr view "$number" --repo "$REPO" --json url --jq .url
    return 0
  fi
  local -a draft_args=()
  if [[ "$draft" == "1" ]]; then
    draft_args=(--draft)
  fi
  if url=$(gh_as "$token" pr create --repo "$REPO" --base "$TARGET_BRANCH" --head "$head" --title "$title" --body-file "$body_file" "${draft_args[@]}" 2>"$RUN_DIR/pr-create.err"); then
    printf '%s\n' "$url"
    return 0
  fi
  LAST_PR_ERROR=$(cat "$RUN_DIR/pr-create.err")
  log "fork-sync: 创建 PR 失败：$(redact "$LAST_PR_ERROR")"
  number=$(gh_as "$token" pr list --repo "$REPO" --base "$TARGET_BRANCH" --head "${owner}:${head}" --state open --jq '.[0].number' || true)
  if [[ -n "$number" && "$number" != "null" ]]; then
    update_existing_pr "$token" "$number" "$title" "$body_file"
    gh_as "$token" pr view "$number" --repo "$REPO" --json url --jq .url
    return 0
  fi
  return 1
}

close_pr_by_head() {
  local head="$1" comment="$2" token number owner
  owner="${REPO%%/*}"
  for token in "${SYNC_TOKEN:-}" "${ISSUE_TOKEN:-}"; do
    [[ -n "$token" ]] || continue
    if ! number=$(gh_as "$token" pr list --repo "$REPO" --base "$TARGET_BRANCH" --head "${owner}:${head}" --state open --jq '.[0].number' 2>"$RUN_DIR/pr-list.err"); then
      log "fork-sync: 用当前令牌列出 ${head} 的 PR 失败，尝试下一个"
      continue
    fi
    if [[ -z "$number" || "$number" == "null" ]]; then
      return 0
    fi
    if gh_as "$token" pr close "$number" --repo "$REPO" --comment "$comment" >/dev/null 2>&1; then
      log "fork-sync: 已关闭 PR #${number}（${head}）"
      return 0
    fi
  done
  return 0
}

issues_are_enabled() {
  local token="${ISSUE_TOKEN:-${SYNC_TOKEN:-}}" flag
  [[ -n "$token" ]] || return 1
  flag=$(gh_as "$token" api "repos/${REPO}" --jq '.has_issues' 2>/dev/null || true)
  [[ "$flag" == "true" ]]
}

upsert_issue() {
  local body_file="$1" token number
  token="${ISSUE_TOKEN:-${SYNC_TOKEN:-}}"
  [[ -n "$token" ]] || return 1
  number=$(gh_as "$token" issue list --repo "$REPO" --state open --limit 50 --json number,title \
    --jq 'first(.[] | select(.title=="上游同步需要处理") | .number)' 2>/dev/null || true)
  if [[ -n "$number" && "$number" != "null" ]]; then
    local old new old_fp new_fp
    old=$(gh_as "$token" issue view "$number" --repo "$REPO" --json body --jq .body)
    new=$(cat "$body_file")
    old_fp=$(fingerprint_of "$old")
    new_fp=$(fingerprint_of "$new")
    if [[ "$old" != "$new" ]]; then
      gh_as "$token" issue edit "$number" --repo "$REPO" --body-file "$body_file" >/dev/null
      if [[ -n "$old_fp" && -n "$new_fp" && "$old_fp" != "$new_fp" ]]; then
        gh_as "$token" issue comment "$number" --repo "$REPO" \
          --body "上游同步状态有变化（\`${old_fp}\` → \`${new_fp}\`）。处理说明在 issue 正文。" >/dev/null
      fi
    fi
    return 0
  fi
  gh_as "$token" issue create --repo "$REPO" --title "$ISSUE_TITLE" --body-file "$body_file" >/dev/null
}

close_issue_if_open() {
  local comment="$1" token number
  token="${ISSUE_TOKEN:-${SYNC_TOKEN:-}}"
  [[ -n "$token" ]] || return 0
  issues_are_enabled || return 0
  number=$(gh_as "$token" issue list --repo "$REPO" --state open --limit 50 --json number,title \
    --jq 'first(.[] | select(.title=="上游同步需要处理") | .number)' 2>/dev/null || true)
  if [[ -z "$number" || "$number" == "null" ]]; then
    return 0
  fi
  gh_as "$token" issue close "$number" --repo "$REPO" --comment "$comment" >/dev/null 2>&1 || true
}

notify_blocked() {
  local reason="$1" body_file="$2"
  local flat
  flat=$(printf '%s' "$reason" | tr '\n' ' ')
  printf '::error title=上游同步未完成::%s\n' "$flat"
  summary "## 上游同步未完成"
  summary_file "$body_file"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "fork-sync: dry-run，不创建通知"
    return 0
  fi
  if issues_are_enabled && upsert_issue "$body_file"; then
    log "fork-sync: 已更新 issue"
    close_pr_by_head "$ALERT_BRANCH" "失败说明改由 issue「${ISSUE_TITLE}」跟踪。" || true
    return 0
  fi
  upsert_alert_pr "$body_file" || die "无法创建失败通知 PR，请查看上面的错误。${reason}"
}

upsert_alert_pr() {
  local body_file="$1" wt old_body new_body sha
  new_body=$(cat "$body_file")
  git_public fetch origin "+refs/heads/${ALERT_BRANCH}:refs/remotes/origin/${ALERT_BRANCH}" >/dev/null 2>&1 || true
  if git rev-parse --verify --quiet "refs/remotes/origin/${ALERT_BRANCH}" >/dev/null; then
    old_body=$(git show "refs/remotes/origin/${ALERT_BRANCH}:${ALERT_FILE}" 2>/dev/null || true)
    if [[ "$old_body" == "$new_body" ]]; then
      log "fork-sync: 失败通知无变化"
      create_or_update_pr "$ISSUE_TOKEN" "$ALERT_BRANCH" "$ISSUE_TITLE" "$body_file" 1 >/dev/null || return 1
      return 0
    fi
  fi
  export_bot_identity
  wt=$(mktemp -d)
  git worktree add --detach "$wt" "$BASE_SHA" >&2
  mkdir -p "$wt/$(dirname "$ALERT_FILE")"
  printf '%s\n' "$new_body" >"$wt/$ALERT_FILE"
  git -C "$wt" add -- "$ALERT_FILE"
  if git -C "$wt" diff --cached --quiet; then
    remove_worktree "$PWD" "$wt"
    create_or_update_pr "$ISSUE_TOKEN" "$ALERT_BRANCH" "$ISSUE_TITLE" "$body_file" 1 >/dev/null
    return 0
  fi
  git -C "$wt" commit -m "$(printf '%s\n' "ci(fork): 上游同步 - 记录失败原因" "" "[skip ci]")" >&2
  sha=$(git -C "$wt" rev-parse HEAD)
  remove_worktree "$PWD" "$wt"
  push_alert_commit "$sha" || return 1
  create_or_update_pr "$ISSUE_TOKEN" "$ALERT_BRANCH" "$ISSUE_TITLE" "$body_file" 1 >/dev/null
}

upsert_sync_pr() {
  local title="$1" body_file="$2" url
  if url=$(create_or_update_pr "$SYNC_TOKEN" "$TRACKING_BRANCH" "$title" "$body_file" 0); then
    log "fork-sync: 同步 PR ${url}"
    close_pr_by_head "$ALERT_BRANCH" "后续说明改由同步 PR 跟踪：${url}" || true
    return 0
  fi
  log "fork-sync: SYNC_TOKEN 创建 PR 失败，改用 Actions 令牌重试"
  if url=$(create_or_update_pr "$ISSUE_TOKEN" "$TRACKING_BRANCH" "$title" "$body_file" 0); then
    log "fork-sync: 同步 PR ${url}"
    close_pr_by_head "$ALERT_BRANCH" "后续说明改由同步 PR 跟踪：${url}" || true
    return 0
  fi
  return 1
}

finish_success() {
  local message="$1"
  summary "$message"
  log "fork-sync: ${message}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  close_pr_by_head "$TRACKING_BRANCH" "$message" || true
  close_pr_by_head "$ALERT_BRANCH" "$message" || true
  close_issue_if_open "$message" || true
}

behind_or_unknown() {
  if [[ -n "${BEHIND:-}" ]]; then
    printf '%s' "$BEHIND"
  else
    printf '未知'
  fi
}

base_or_unknown() {
  if [[ -n "${BASE_SHA:-}" ]]; then
    printf '%s' "$BASE_SHA"
  else
    printf '未知'
  fi
}

refresh_workflow_notes() {
  if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    return 0
  fi
  collect_workflow_warnings || true
  if [[ "${DRY_RUN:-0}" != "1" && -n "${SYNC_TOKEN:-}" ]]; then
    maybe_disable_workflows || true
    collect_workflow_warnings || true
  fi
}

main() {
  local auto body title kind
  RUN_DIR=$(mktemp -d)
  trap 'rm -rf "$RUN_DIR"' EXIT
  REPO="${REPO:-}"
  [[ -n "$REPO" ]] || die "缺少 REPO"
  DRY_RUN="${DRY_RUN:-0}"
  [[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] || die "DRY_RUN 只能是 0 或 1"
  [[ "$UPSTREAM_HEAD" == "main" ]] || die "只允许同步上游 main"
  if [[ "${GITHUB_ACTIONS:-}" == "true" && "$REPO" != "Akioss/open-ai-canvas" ]]; then
    die "此同步只允许在 Akioss/open-ai-canvas 运行"
  fi
  require_cmd git
  if [[ "$DRY_RUN" != "1" ]]; then
    require_cmd gh
  fi
  SYNC_TOKEN=$(trim "${SYNC_TOKEN:-}")
  ISSUE_TOKEN=$(trim "${ISSUE_TOKEN:-}")
  export_bot_identity
  prepare_repo_network

  log "fork-sync: 抓取 ${UPSTREAM_URL} ${UPSTREAM_HEAD}"
  if ! fetch_upstream; then
    die "无法抓取上游 ${UPSTREAM_URL}"
  fi
  log "fork-sync: 上游 ${UPSTREAM_SHA}"

  if ! fetch_origin_main; then
    if [[ -z "$SYNC_TOKEN" ]]; then
      BASE_SHA=""
      BEHIND=""
    else
      die "无法抓取 origin/main"
    fi
  fi
  log "fork-sync: main ${BASE_SHA:-未知}，落后 $(behind_or_unknown) 个提交"

  refresh_workflow_notes
  auto=$(resolve_auto_merge)
  log "fork-sync: auto_merge=${auto} dry_run=${DRY_RUN}"

  if [[ -z "$SYNC_TOKEN" ]]; then
    body="$RUN_DIR/missing.md"
    render_missing_token "$UPSTREAM_SHA" "$(base_or_unknown)" "$(behind_or_unknown)" >"$body"
    log "fork-sync: result=missing-token behind=$(behind_or_unknown)"
    notify_blocked "缺少仓库密钥 SYNC_TOKEN。请按 .github/FORK_SYNC.md 创建 fine-grained PAT，并写入名为 SYNC_TOKEN 的 Actions secret。" "$body"
    exit 2
  fi
  if [[ "$auto" == "invalid" ]]; then
    die "FORK_SYNC_AUTO_MERGE 或手动输入的 auto_merge 不是 true/false"
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    if ! push_tracking_branch "$UPSTREAM_SHA"; then
      kind=$(classify_push_error "$LAST_PUSH_OUTPUT")
      body="$RUN_DIR/rejected.md"
      render_token_rejected "$UPSTREAM_SHA" "$BASE_SHA" "$BEHIND" "$kind" "$LAST_PUSH_OUTPUT" >"$body"
      log "fork-sync: result=tracking-rejected kind=${kind}"
      notify_blocked "更新 upstream 分支被拒绝（${kind}）。" "$body"
      exit 2
    fi
    log "fork-sync: upstream 分支已对齐 ${UPSTREAM_SHA}"
  fi

  local try state merge_result
  state=""
  for try in 1 2; do
    if [[ "$try" == "2" ]]; then
      fetch_origin_main
    fi
    if git merge-base --is-ancestor "$UPSTREAM_SHA" "$BASE_SHA"; then
      state="uptodate"
      break
    fi
    merge_result=$(attempt_merge "$PWD" "$BASE_SHA" "$UPSTREAM_SHA")
    MERGE_STATUS=${merge_result%%$'\n'*}
    if [[ "$merge_result" == *$'\n'* ]]; then
      MERGE_DETAIL=${merge_result#*$'\n'}
    else
      MERGE_DETAIL=""
    fi
    case "$MERGE_STATUS" in
      conflict)
        state="conflict"
        break
        ;;
      error)
        state="merge_error"
        break
        ;;
      clean)
        NEW_SHA=$(normalize_sha "${MERGE_DETAIL%%$'\n'*}")
        if ! assert_merge_commit "$PWD" "$BASE_SHA" "$NEW_SHA"; then
          state="invariant"
          break
        fi
        if [[ "$DRY_RUN" == "1" || "$auto" != "true" ]]; then
          state=$([[ "$DRY_RUN" == "1" ]] && printf 'dry_clean' || printf 'needs_review')
          break
        fi
        if push_main_commit "$NEW_SHA"; then
          state="pushed"
          break
        fi
        kind=$(classify_push_error "$LAST_PUSH_OUTPUT")
        if [[ "$try" == "1" && "$kind" == "stale_main" ]]; then
          log "fork-sync: main 在合并期间前进了，重试一次"
          continue
        fi
        state="push_failed"
        break
        ;;
      *)
        state="merge_error"
        break
        ;;
    esac
  done

  case "$state" in
    uptodate)
      log "fork-sync: result=uptodate"
      finish_success "main 已包含上游 ${UPSTREAM_SHA}，无需合并。"
      exit 0
      ;;
    dry_clean)
      log "fork-sync: result=dry_clean sha=${NEW_SHA} behind=${BEHIND}"
      summary "dry-run：可以干净合并 ${BEHIND} 个提交，合并提交 ${NEW_SHA}。没有推送。"
      exit 0
      ;;
    needs_review)
      body="$RUN_DIR/review.md"
      title="chore(fork): 同步上游 - main 落后 ${BEHIND} 个提交"
      render_sync_pr "$UPSTREAM_SHA" "$BASE_SHA" "$BEHIND" "needs_review" "" >"$body"
      log "fork-sync: result=needs_review behind=${BEHIND}"
      summary_file "$body"
      if ! upsert_sync_pr "$title" "$body"; then
        notify_blocked "无法打开同步 PR。" "$body"
        exit 1
      fi
      exit 0
      ;;
    conflict)
      body="$RUN_DIR/conflict.md"
      title="chore(fork): 同步上游 - main 落后 ${BEHIND} 个提交，存在冲突"
      render_sync_pr "$UPSTREAM_SHA" "$BASE_SHA" "$BEHIND" "conflict" "$MERGE_DETAIL" >"$body"
      log "fork-sync: result=conflict behind=${BEHIND}"
      log "冲突文件:"
      printf '%s\n' "$MERGE_DETAIL" >&2
      printf '::error title=上游同步有冲突::main 落后 %s 个提交，冲突文件已写入同步 PR。\n' "$BEHIND"
      summary_file "$body"
      if [[ "$DRY_RUN" == "1" ]]; then
        exit 1
      fi
      if ! upsert_sync_pr "$title" "$body"; then
        notify_blocked "有冲突，且无法打开同步 PR。" "$body"
      fi
      exit 1
      ;;
    push_failed)
      body="$RUN_DIR/push.md"
      title="chore(fork): 同步上游 - 自动合并未写入 main"
      render_sync_pr "$UPSTREAM_SHA" "$BASE_SHA" "$BEHIND" "push_failed" "$LAST_PUSH_OUTPUT" >"$body"
      kind=$(classify_push_error "$LAST_PUSH_OUTPUT")
      log "fork-sync: result=push_failed kind=${kind}"
      summary_file "$body"
      if ! upsert_sync_pr "$title" "$body"; then
        notify_blocked "推送 main 失败，且无法打开同步 PR。" "$body"
        exit 1
      fi
      if [[ "$kind" == "branch_protection" ]]; then
        printf '::warning title=自动合并被分支保护拒绝::已改为打开同步 PR。若 main 需要评审，请把 FORK_SYNC_AUTO_MERGE 设为 false。\n'
        exit 0
      fi
      printf '::error title=自动合并未能写入 main::分类 %s。已打开同步 PR。\n' "$kind"
      exit 1
      ;;
    invariant)
      die "合并结果破坏了 fork 自有文件，已取消推送"
      ;;
    merge_error)
      die "合并上游失败：${MERGE_DETAIL:-未知错误}"
      ;;
    *)
      die "未知同步状态: ${state:-空}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
