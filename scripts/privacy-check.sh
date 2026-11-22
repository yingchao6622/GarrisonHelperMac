#!/bin/bash
# Run before every push: looks for personal data in what git would publish.
#  1. emails, home-folder paths, API keys / tokens in tracked and to-be-added files
#  2. other players' in-game names: read from the local debug recordings (dist/卫戍助手调试/, never committed) and
#     searched for in those files and in every commit of the history
#  3. home-folder paths in the packaged app
#  4. commit authors
# Prints what it finds; exits 1 if anything needs a look.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0

files="$(mktemp)"
{ git ls-files; git ls-files --others --exclude-standard; } | sort -u > "$files"

echo "== 1. 邮箱、本机路径、密钥"
if tr '\n' '\0' < "$files" | xargs -0 grep -I -n -i -E \
    "@gmail\.com|@qq\.com|@163\.com|@outlook\.com|/Users/[a-z]|sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN .*PRIVATE KEY" 2>/dev/null \
    | grep -v "scripts/privacy-check.sh"; then status=1; else echo "没有"; fi

echo "== 2. 调试记录里出现过的玩家昵称"
python3 - "$files" <<'PY' || status=1
import glob, json, re, subprocess, sys
names = set()
for f in glob.glob("dist/卫戍助手调试/*/*.json") + glob.glob("../调试文件/对局记录/*/*.json"):
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    for o in d.get("ocr", []):
        t = o.split(" ", 1)[1] if " " in o else o
        m = re.match(r"^(.{2,16}?)\s*#\s*\d{3,5}$", t.strip())
        if m:
            names.add(m.group(1).strip())
names = {n for n in names if len(n) >= 2 and not n.isdigit()}
if not names:
    print("没有找到调试记录（../调试文件/对局记录/ 或 dist/卫戍助手调试/），跳过")
    sys.exit(0)
hits = []
for p in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if not p:
        continue
    try:
        s = open(p, encoding="utf-8").read()
    except Exception:
        continue
    hits += [f"{p}: {n[0]}…" for n in names if n in s]
log = subprocess.run(["git", "log", "--all", "-p", "--format=%H"], capture_output=True, text=True, errors="replace").stdout
hits += [f"git 历史: {n[0]}…" for n in names if n in log]
print(f"从调试记录里读到 {len(names)} 个昵称")
if hits:
    print("\n".join(sorted(set(hits))))  # only the first character is printed
    sys.exit(1)
print("没有")
PY

echo "== 3. 打包的 app"
app="dist/卫戍协议小助手.app/Contents/MacOS/GarrisonHelper"
if [ -f "$app" ]; then
  if strings -a "$app" | grep -i -E "/Users/[a-z]|@gmail\.com"; then status=1; else echo "没有"; fi
else
  echo "还没打包，跳过"
fi

echo "== 4. 提交作者"
git log --all --format='%an <%ae>' | sort -u
if git log --all --format='%ae' | grep -v -q "users.noreply.github.com"; then
  echo "↑ 有不是 GitHub 隐藏邮箱的作者"; status=1
fi

rm -f "$files"
exit $status
