#!/usr/bin/env python3
"""Adds each equipment's 合成 (fuse: with + result) and 来源 (operators that bring it) to Resources/data/equipment.json.

Input: StrongholdAssistant data/codex_extra.json (Apache-2.0), whose equipment relations come from Kengxxiao/ArknightsGameData
zh_CN gamedata/excel/activity_table.json (act3autochess V3_1: fuseWith / fuseResult, and the operators whose chess skill
gives the item). See ASSETS.md.

    python3 -I scripts/build-equipment-relations.py <StrongholdAssistant>/data/codex_extra.json
"""
import json
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "Resources/data/equipment.json"


def main(extra_path: Path):
    extra = json.loads(extra_path.read_text(encoding="utf-8"))["equipment"]
    raw = DATA.read_text(encoding="utf-8")
    data = json.loads(raw)
    names = {e["name"] for e in data["equipment"]}
    n_fuse = n_src = 0
    for e in data["equipment"]:
        x = extra.get(e["name"], {})
        e.pop("fuse", None)
        e.pop("sources", None)
        f = x.get("fuse")
        if f and f.get("with") in names and f.get("result") in names:
            e["fuse"] = {"with": f["with"], "result": f["result"]}
            n_fuse += 1
        if x.get("sources"):
            e["sources"] = list(x["sources"])
            n_src += 1
    DATA.write_text(json.dumps(data, ensure_ascii=False, indent=2) + ("\n" if raw.endswith("\n") else ""), encoding="utf-8")
    print(f"fuse {n_fuse}, sources {n_src} of {len(data['equipment'])}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
