# Fork 上游同步

本仓库是 [ddcat-ai/open-ai-canvas](https://github.com/ddcat-ai/open-ai-canvas)（影策，MIT）的个人 fork。业务代码跟随上游；个人改动只放在 `main`。本文只说明这套 fork 自己的同步方式。

说明放在 `.github/FORK_SYNC.md`，而不是 `docs/`。仓库的 `.gitignore` 忽略了 `docs/*` 里大多数新文件，放在 `.github/` 才能跟同步工作流一起被提交，也不会在上游改文档站时产生冲突。

## 分支

| 分支 | 谁可以写 | 内容 |
| --- | --- | --- |
| `upstream` | 同步工作流，每次强制对齐 | 与上游 `main` 同一个提交，上面没有个人提交 |
| `main` | 你，以及无冲突时的自动合并 | 个人改动，加上已经吸收的上游 |
| `fork-sync/alert` | 同步工作流 | 只有在无法推送 `upstream` 时才会出现，用来挂一张失败草稿 PR |

`upstream` 和 `main` 分开，是为了让上游跟踪和个人改动不要抢同一条历史。强制更新只发生在 `upstream`。`main` 永远用普通推送或 PR 合并，不会被 force-push。冲突留在 `main` 上解决；下一次同步仍可以把 `upstream` 对准最新上游。

个人提交放在 `main`，或从 `main` 拉出的功能分支。不要往 `upstream` 上提交。那个分支下一次同步会被覆盖。

## 每次运行做什么

定时为 UTC 每周一 02:17 一次（`17 2 * * 1`，约等于 Asia/Shanghai 周一 10:17）。也可以在 Actions 里手动运行 Sync upstream。

1. 抓取 `ddcat-ai/open-ai-canvas` 的 `main`。
2. 把本仓库的 `upstream` 分支强制对齐到那个提交。这一步要改上游的 workflow 文件，所以必须使用密钥 `SYNC_TOKEN`。
3. 若 `main` 已经包含该提交，结束。
4. 在临时工作树里尝试合并。干净合并会保留下面的 fork 自有文件，并生成带 `[skip ci]` 的合并提交。
5. 变量允许自动合并时，把该提交普通推送到 `main`。推送若因分支保护被拒绝，就改成打开 PR，本次运行记为成功。
6. 有冲突时不推送 `main`。打开或更新从 `upstream` 到 `main` 的 PR，运行标红。
7. 没有 `SYNC_TOKEN`，或令牌不能更新 workflow 文件时，不回退到 `github.token`。打开或更新一张草稿 PR（仓库若重新打开 Issues，则改为 issue），运行以失败结束。

手动运行有两个输入：

- `auto_merge`：`auto` 沿用仓库变量，`true` / `false` 只影响这一次。
- `dry_run`：只报告落后多少、能否干净合并，不推送也不建 PR。有冲突或缺密钥时这次运行仍会失败，方便在日志里看到原因。

## 一次性设置

按这个顺序做。新的工作流文件合并到 `main` 之后才会取代现在这版直接调用 `merge-upstream` 的工作流。

### 1. 创建令牌

推荐 fine-grained personal access token：

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token。
2. Resource owner 选 **Akioss**。
3. Repository access 选 **Only select repositories**，只选 **open-ai-canvas**。
4. Repository permissions：
   - **Contents**: Read and write
   - **Workflows**: Read and write
   - **Pull requests**: Read and write
5. 过期时间最长一年。到期前更换密钥；到期后下一次同步会打开失败草稿 PR。

classic PAT 也可以：必须同时勾选 **`repo`** 和 **`workflow`**。它能访问你账号下的所有仓库，所以 fine-grained PAT 更合适。

不要把 GitHub App installation token 直接存进密钥。那种令牌大约一小时过期。本工作流不会用 App 私钥换票。

`workflows` 权限不能省。上游只要改了 `.github/workflows/` 里的文件，没有这个权限的令牌会被 GitHub 拒绝，错误类似：

```text
refusing to allow a GitHub App to create or update workflow `.github/workflows/quality.yml` without `workflows` permission
```

Actions 自带的 `github.token` 即使在工作流里声明 `contents: write` 也没有这项权限。同步脚本发现密钥为空时会直接失败，不会再退回 `github.token`。

### 2. 写入仓库密钥

本仓库 → Settings → Secrets and variables → Actions → Secrets → New repository secret。

名称必须是 **`SYNC_TOKEN`**。值是上一步的令牌。不要写进代码、日志或 PR 正文。

### 3. 关闭上游的 CI 和镜像发布

这些文件来自上游，fork 里不修改它们，避免每次同步都冲突。请在 Actions 页面关闭：

| 工作流 | 文件 | 触发 | 当前建议 |
| --- | --- | --- | --- |
| Quality checks | `.github/workflows/quality.yml` | `pull_request`、`workflow_call` | 关闭，除非你要在自己的 PR 上跑上游测试 |
| Publish container images | `.github/workflows/publish-images.yml` | 推送到 `main`、`v*` tag、手动 | 保持关闭。fork 不发布镜像 |

操作：Actions → 左侧点开该工作流 → 右侧 `...` → **Disable workflow**。

手动关闭后的状态是 `disabled_manually`。上游以后修改同名文件，不会把它重新打开。上游如果新增别的工作流文件，它会以启用状态出现；同步运行时若发现除 `sync-upstream.yml` 以外还有启用的工作流，会在日志里打出 warning。

自动合并写入 `main` 的提交带有 `[skip ci]`，因此不会触发 `push` 工作流。从 `upstream` 打开的同步 PR 用的是上游自己的提交，**不会**带 `[skip ci]`。Quality checks 若仍启用，这种 PR 会跑完整质量检查。

可选：把 Actions variable `FORK_SYNC_DISABLE_UPSTREAM_WORKFLOWS` 设为 `true`。同步时会尝试调用 API 关闭其他工作流。fine-grained PAT 做这件事通常还需要 **Administration: Read and write**；没有该权限时这一步失败，同步继续，你仍需按上面的页面操作关闭。默认不设置该变量，避免每次同步把你故意打开的质量检查再关掉。

同步不会镜像上游 tag，避免 `v*` 触发镜像发布，也避免把上游版本重新发到 fork 的 GHCR。

### 4. 决定要不要自动合并

Actions → Secrets and variables → Actions → Variables。

| 变量 | 取值 | 作用 |
| --- | --- | --- |
| `FORK_SYNC_AUTO_MERGE` | 不设置或 `true` | 无冲突时自动把合并提交推到 `main` |
| `FORK_SYNC_AUTO_MERGE` | `false` | 只打开 PR，由你点 Merge |
| `FORK_SYNC_DISABLE_UPSTREAM_WORKFLOWS` | `true` | 尝试用 API 关闭除同步以外的工作流 |

开始在 `main` 上长期放自己的改动、并且希望每次亲眼看 diff 时，把 `FORK_SYNC_AUTO_MERGE` 设为 `false`。

### 5. 分支设置

- 默认分支保持 **`main`**。
- 不要给 `upstream` 加禁止强制推送的保护，否则跟踪分支无法对齐上游。
- `main` 可以要求通过 PR。这样自动推送会被拒绝，工作流会改开同步 PR，并把该次运行记为成功。这时建议把 `FORK_SYNC_AUTO_MERGE` 设为 `false`，避免每次先尝试推送再失败。
- 仓库目前关闭了 Issues。失败通知走草稿 PR `fork-sync/alert`。若希望改用 issue：Settings → General → Features → Issues。工作流发现 Issues 可用后，会改写 issue「上游同步需要处理」，并关掉草稿 PR。

### 6. 合并本次改造并追平上游

1. 合并改造同步流程的 PR，使 `main` 上的工作流换成新脚本。
2. 确认 `SYNC_TOKEN` 已保存，Publish 保持关闭，并按上面的建议处理 Quality checks。
3. Actions → Sync upstream → **Run workflow**。`auto_merge` 留在 `auto`，`dry_run` 先打开跑一次也可以。
4. 确认运行成功后，`main` 包含上游最新提交，并且存在 `upstream` 分支。

在这之前，旧工作流仍会按原计划每 6 小时失败一次。那是预期现象，合并并配好密钥后会停。

## 失败时看哪里

| 情况 | 你会看到 | 运行结果 |
| --- | --- | --- |
| 没配 `SYNC_TOKEN`，或令牌不能改 workflow | 草稿 PR「上游同步需要处理」，或同名 issue | 失败 |
| `main` 与上游有冲突 | PR「同步上游 … 存在冲突」，正文有冲突文件 | 失败，直到冲突消失 |
| 无冲突，但关闭了自动合并 | 同一张同步 PR，可以点 Merge | 成功 |
| 无冲突且自动合并 | `main` 上多一个带 `[skip ci]` 的合并提交 | 成功 |
| `main` 要求 PR，自动推送被拒绝 | 同步 PR，日志里有 warning | 成功 |

同一状态重复出现时，工作流只更新正文，不每周追加一条评论。上游 SHA 或冲突文件变了，才会再评论一次。

不要合并草稿 PR `fork-sync/alert`。它只包含 `.github/fork-sync-alert.md`。即便合并进了 `main`，下一次成功的自动合并也会删掉这个文件。

## 解决冲突

冲突 PR 的头分支是 `upstream`。不要点页面上的 **Resolve conflicts**，那个按钮会把结果提交到 `upstream`，下一次强制对齐会丢掉它。

```bash
git fetch origin
git checkout main
git pull origin main
git fetch origin upstream:refs/remotes/origin/upstream
git merge origin/upstream
```

这些路径是 fork 自有文件。冲突时保留 `main` 的版本：

- `.github/workflows/sync-upstream.yml`
- `.github/scripts/fork-sync.sh`
- `.github/scripts/test_fork_sync.sh`
- `.github/FORK_SYNC.md`

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

然后处理其余业务文件冲突，`git commit`，再 `git push origin main`。下一次同步发现 `main` 已包含上游提交后，会关掉同步 PR。

干净合并时，脚本也会把上表里的文件恢复成合并前 `main` 的内容，所以上游即使新增了同名文件，也不会在自动合并里悄悄改掉同步脚本。

## 自己的改动放哪里

从最新的 `main` 拉功能分支，改完再合并回 `main`。不要提交到 `upstream`，不要删除上表中的文件，也不要把这些文件提回上游仓库。

只改文档或 fork 工作流时，上游业务文件通常不会冲突。一旦你修改了上游也在改的业务文件，同步就会停在冲突 PR，直到你按上一节处理。这是故意的：冲突不能被静默跳过。
