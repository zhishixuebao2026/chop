#!/usr/bin/env bash
#
# 清理提交署名：把 main 上的提交统一成一个人的名字，并删掉提交信息里的 AI 署名。
#
# 为什么：GitHub 仓库页右侧的「Contributors（贡献者）」一栏是按提交的作者邮箱算的。
# 现在这一栏有两个人（claude 和 xoqnapgf-dot），还夹着会显示头像和
# "Co-Authored-By: Claude ..." 的提交。GitHub 没有开关能隐藏这一栏，
# 唯一的办法就是改写历史，让每个提交都只属于同一个邮箱。
#
# 做什么：
#   1. 把提交的作者、提交者改成同一个人（默认是本仓库站长的账号）；
#   2. 删掉提交信息里的 AI 署名行："Co-Authored-By: Claude ..."、"Claude-Session: ..."、
#      "Co-authored-by: arena-agent ..." 等（人类协作者的 Co-Authored-By 不动）；
#   3. 合并提交里带 "claude/..." 的分支名也一并去掉。
# 文件内容一个字节都不会变，只是提交哈希全部重算，所以必须强制推送。
#
# 用法（在仓库里跑）：
#   bash scripts/clean-credits.sh                      # 演练：改写并打印报告，然后还原，不推送
#   bash scripts/clean-credits.sh --push               # 真正执行，并 git push --force 到 origin/main
#   bash scripts/clean-credits.sh --push --only-agent  # 只改 AI 的提交，其他人的提交原样保留
#   bash scripts/clean-credits.sh --name "张三" --email "you@example.com"
#
# 注意：强制推送后，别人的旧克隆、旧提交链接都会失效，要重新 clone。
# 已经合并过的 Pull Request 页面（refs/pull/*）仍然是旧记录，GitHub 不让你改，
# 想连那些一起消失只能删库重建或把仓库转私有。
set -euo pipefail

NAME="zhishixuebao2026"
EMAIL="336017999+zhishixuebao2026@users.noreply.github.com"
BRANCH="main"
REMOTE="origin"
PUSH=0
ONLY_AGENT=0
AGENT_EMAIL="noreply@anthropic.com"

usage() { sed -n '2,30p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --only-agent) ONLY_AGENT=1 ;;
    --name) NAME="${2:?--name 后面要跟名字}"; shift ;;
    --email) EMAIL="${2:?--email 后面要跟邮箱}"; shift ;;
    --branch) BRANCH="${2:?--branch 后面要跟分支名}"; shift ;;
    --remote) REMOTE="${2:?--remote 后面要跟远端名}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1（试 bash scripts/clean-credits.sh --help）" >&2; exit 2 ;;
  esac
  shift
done

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

# CI 里可能是 detached HEAD，本地没有分支名，从远端补一个
if ! git rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null; then
  git branch "$BRANCH" "refs/remotes/$REMOTE/$BRANCH" || {
    echo "找不到分支 $BRANCH，也没有 refs/remotes/$REMOTE/$BRANCH。" >&2
    exit 1
  }
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "工作区还有没提交的改动，先提交或 stash 再跑。" >&2
  exit 1
fi

OLD=$(git rev-parse "$BRANCH")
echo "分支 $BRANCH：$OLD（$(git rev-list --count "$BRANCH") 个提交）"
echo "改写后的署名：$NAME <$EMAIL>"
if [ "$ONLY_AGENT" = 1 ]; then
  echo "模式：只改 $AGENT_EMAIL 的提交，别人（比如你自己）的提交不动"
else
  echo "模式：所有提交统一成上面这个署名 —— 贡献者名单里只剩这一个人"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/msg-filter.py" <<'PY'
"""filter-branch 的 --msg-filter：删掉 AI 署名行，并去掉合并信息里的 claude/ 分支名。"""
import re
import sys

msg = sys.stdin.read()

# 这些署名一律删掉（AI 工具/代写），正常人类协作者的 Co-Authored-By 保留
AI = re.compile(
    r'^Co-Authored-By:.*('
    r'Claude|Anthropic|arena-agent|Arena Agent|OpenAI|Codex|Copilot|Cursor|Devin|Gemini'
    r')',
    re.I,
)

keep = []
for line in msg.splitlines():
    if AI.match(line):
        continue
    if re.match(r'^Claude-Session:', line):
        continue
    if re.match(r'^🤖\s*Generated with', line):
        continue
    keep.append(line)
msg = '\n'.join(keep)

# "Merge pull request #96 from xoqnapgf-dot/claude/xxx" -> "Merge pull request #96"
msg = re.sub(r' from \S*/claude/\S+', '', msg)
# "Merge remote-tracking branch 'origin/main' into claude/xxx"
msg = re.sub(r' into claude/\S+', '', msg)

print(msg.rstrip())
PY

NEW_NAME="$NAME" NEW_EMAIL="$EMAIL" AGENT_EMAIL="$AGENT_EMAIL" ONLY_AGENT="$ONLY_AGENT" \
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --env-filter "$(cat <<'EOS'
if [ "${ONLY_AGENT:-0}" = "1" ]; then
  if [ "$GIT_AUTHOR_EMAIL" = "$AGENT_EMAIL" ]; then
    GIT_AUTHOR_NAME="$NEW_NAME"; GIT_AUTHOR_EMAIL="$NEW_EMAIL"; export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
  fi
  if [ "$GIT_COMMITTER_EMAIL" = "$AGENT_EMAIL" ]; then
    GIT_COMMITTER_NAME="$NEW_NAME"; GIT_COMMITTER_EMAIL="$NEW_EMAIL"; export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  fi
else
  GIT_AUTHOR_NAME="$NEW_NAME"; GIT_AUTHOR_EMAIL="$NEW_EMAIL"; export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
  GIT_COMMITTER_NAME="$NEW_NAME"; GIT_COMMITTER_EMAIL="$NEW_EMAIL"; export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
fi
EOS
)" \
  --msg-filter "python3 '$TMP/msg-filter.py'" \
  -- "$BRANCH"

NEW=$(git rev-parse "$BRANCH")

echo
echo "===== 改写结果 ====="
echo "新提交：$NEW，仍然 $(git rev-list --count "$NEW") 个提交，文件内容与改写前逐字节相同"
echo "现在的作者（提交数）："
git log --format='%an <%ae>' "$NEW" | sort | uniq -c | sort -rn | sed 's/^/    /'
LEFT=$(git log --format='%B' "$NEW" | grep -ci 'anthropic\|claude\|Claude-Session' || true)
echo "提交信息里还剩 $LEFT 处 Claude / Anthropic 字样"
if [ "$LEFT" != 0 ]; then
  git log --format='%h %s' --grep='claude' --grep='anthropic' -i "$NEW" | head -5 | sed 's/^/    /'
fi
echo "改写后的信息示例："
git log -1 --format='    %s%n%b' "$NEW" | sed '/^$/d' | head -6

if [ "$PUSH" = 1 ]; then
  git push --force "$REMOTE" "$BRANCH"
  git update-ref -d "refs/original/refs/heads/$BRANCH"
  echo
  echo "已强制推送到 $REMOTE/$BRANCH（改写前的提交是 $OLD）。"
  echo "推错了要回退：git push --force $REMOTE $OLD:refs/heads/$BRANCH（趁旧提交还没被清理）。"
  echo "GitHub 的贡献者名单会重新算：REST API（repos/<owner>/<repo>/contributors）通常几分钟就对了，"
  echo "但仓库首页右侧那一栏是另一个缓存，可能要等一两天；一直不变可以去 GitHub 社区讨论帖请官方刷一下缓存。"
  echo "站点内容没变，不重新部署也能继续访问；要重跑部署：Actions → 部署到 GitHub Pages → Run workflow。"
else
  git update-ref "refs/heads/$BRANCH" "$OLD"
  git update-ref -d "refs/original/refs/heads/$BRANCH"
  git reset -q --hard "$OLD"
  echo
  echo "演练结束，已经还原，什么都没推送。确认报告没问题后，加 --push 再跑一次。"
fi
