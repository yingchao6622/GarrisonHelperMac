#!/bin/bash
# Release notes for a tag, in the style of immich's releases: a one-line intro, 更新内容 grouped by kind, every commit
# with its author and link, 新贡献者, and the full comparison.
#   scripts/release-notes.sh v0.4.2 [owner/repo] [private]   → stdout
#   scripts/release-notes.sh HEAD                             → preview: the 「## 未发布」 section and commits since the last tag
# Sources:
#   - CHANGELOG.md, section 「## 0.4.2 — date」: the paragraph before the first heading or bullet is the intro, then
#     「### 🚀 新功能」「### ✨ 改进」「### 🐛 修复」… subsections (written by hand, user-facing). Copied as they are.
#   - git log previous-tag..tag: one line per commit (version-only commits such as 「0.4.2」 are left out). The author is
#     the GitHub login: read from a noreply address, else asked from the GitHub API (gh), else the commit's name.
#   - 新贡献者: authors with no commit before the previous tag, with their first commit.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?tag, e.g. v0.4.2}"
REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo yingchao6622/GarrisonHelperMac)}"
PRIVATE="${3:-false}"
URL="https://github.com/$REPO"
VERSION="${TAG#v}"
if [ "$TAG" = HEAD ]; then
  VERSION="未发布"
  PREV="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
else
  PREV="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
fi

# --- CHANGELOG section
section="$(awk -v v="## $VERSION" '($0 == v || index($0, v " ") == 1) && !on {on=1; next} /^## / && on {exit} on' CHANGELOG.md)"
if [ -z "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
  echo "CHANGELOG.md 里没有「## $VERSION 」这一节" >&2
  exit 1
fi
intro="$(printf '%s\n' "$section" | awk 'NF == 0 && !started {next} /^(#|- )/ {exit} {started=1; print}')"
body="$(printf '%s\n' "$section" | awk 'started || /^(#|- )/ {started=1; print}')"

# --- GitHub login of a commit author
# (bash 3.2 on macOS has no associative arrays: a cache file of 「email<TAB>who」 lines.)
CACHE="$(mktemp)"
trap 'rm -f "$CACHE"' EXIT
login_of() {   # sha email name
  local sha="$1" email="$2" name="$3" login="" hit
  hit="$(awk -F'\t' -v e="$email" '$1 == e {print $2; exit}' "$CACHE")"
  if [ -n "$hit" ]; then echo "$hit"; return; fi
  if [[ "$email" =~ ^([0-9]+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com$ ]]; then
    login="${BASH_REMATCH[2]}"
  elif command -v gh >/dev/null; then
    login="$(gh api "repos/$REPO/commits/$sha" --jq '.author.login // empty' 2>/dev/null || true)"
  fi
  local who
  if [ -n "$login" ]; then who="@$login"; else who="$name"; fi
  printf '%s\t%s\n' "$email" "$who" >> "$CACHE"
  echo "$who"
}

link_pr() {   # subject: 「… (#12)」 → link to the pull request
  sed -E "s|\(#([0-9]+)\)|([#\1]($URL/pull/\1))|g" <<<"$1"
}

{
  if [ -n "$intro" ]; then printf '%s\n\n' "$intro"; fi
  echo "## 更新内容"
  echo
  printf '%s\n' "$body"

  if [ -n "$PREV" ]; then
    echo
    echo "## 提交"
    # Grouped like immich's 「What's Changed」: a conventional prefix (feat: / fix: / docs: / ci: / build:) wins, else
    # words in the subject.
    lines="$(mktemp)"
    while IFS=$'\t' read -r sha short email name subject; do
      [[ "$subject" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] && continue
      kind=feat
      case "$subject" in
        fix:*|fix\(*) kind=fix ;;
        docs:*|docs\(*) kind=docs ;;
        ci:*|ci\(*|build:*|build\(*|chore:*|chore\(*) kind=build ;;
        feat:*|feat\(*|perf:*|perf\(*) kind=feat ;;
        发版*|发布*|*签名*|*workflow*|*GitHub\ Actions*) kind=build ;;
        修复*|修正*|*bug*|*Bug*) kind=fix ;;
        文档*|README*|开发记录*|CHANGELOG*|版本号规则*) kind=docs ;;
      esac
      printf '%s\t- %s by %s in [`%s`](%s/commit/%s)\n' "$kind" "$(link_pr "$subject")" "$(login_of "$sha" "$email" "$name")" "$short" "$URL" "$sha" >> "$lines"
    done < <(git log --reverse --no-merges --format=$'%H\t%h\t%ae\t%an\t%s' "$PREV..$TAG")
    for k in "feat|🚀 新功能与改进" "fix|🐛 修复" "build|🔧 构建与发布" "docs|📚 文档"; do
      key="${k%%|*}" title="${k#*|}"
      if grep -q "^$key"$'\t' "$lines"; then
        echo
        echo "### $title"
        echo
        grep "^$key"$'\t' "$lines" | cut -f2-
      fi
    done
    rm -f "$lines"

    # Authors whose first commit is in this release.
    new=""
    seen=$'\n'
    while IFS=$'\t' read -r sha short email name; do
      [[ "$seen" == *$'\n'"$email"$'\n'* ]] && continue
      seen+="$email"$'\n'
      if [ -z "$(git log -1 --format=%h --author="<$email>" "$PREV" 2>/dev/null)" ]; then
        new+="- $(login_of "$sha" "$email" "$name") 第一次贡献：[\`$short\`]($URL/commit/$sha)"$'\n'
      fi
    done < <(git log --reverse --no-merges --format=$'%H\t%h\t%ae\t%an' "$PREV..$TAG")
    if [ -n "$new" ]; then
      echo
      echo "## 新贡献者"
      echo
      printf '%s' "$new"
    fi
  fi

  echo
  echo "---"
  echo
  echo "**安装**：下载 dmg，双击打开，把「卫戍协议小助手」拖到旁边的「Applications」文件夹。应用没有 Apple 开发者签名，第一次打开会提示无法验证开发者：到 系统设置 → 隐私与安全性，点「仍要打开」。之后在「屏幕与系统录音」里勾选它，再重新打开。从 0.4.2 起每个版本用同一张证书签名，以后更新不用再勾（从 0.4.1 或更早版本更新时还要再勾最后一次）。"
  echo
  check='**校验**：`shasum -a 256 -c SHA256SUMS.txt`'
  if [ "$PRIVATE" != "true" ]; then check="$check；构建来源：\`gh attestation verify <dmg> --repo $REPO\`"; fi
  echo "$check"
  if [ -n "$PREV" ]; then
    echo
    echo "**完整改动**：[$PREV...$TAG]($URL/compare/$PREV...$TAG)"
  fi
}
