#!/usr/bin/env python3
"""Adds each boss's HP per mode to Resources/data/bosses.json as "hpByMode" ({mode name: HP}).

Inputs from Kengxxiao/ArknightsGameData zh_CN: gamedata/excel/activity_table.json (act3autochess V3_1: bossInfoDict
bloodDataDict, battleDataDict, modeDataDict) and the boss-stage level files it names
(gamedata/levels/activities/act3autochess/level_act3autochess_h07_01.json …), which tell which enemy each boss_N is.

    python3 -I scripts/build-boss-hp.py <activity_table.json> <directory with the level files>
"""
import json
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "Resources/data/bosses.json"


def main(table: Path, levels: Path):
    v = json.loads(table.read_text(encoding="utf-8"))["activity"]["AUTOCHESS"]["act3autochess"]["V3_1"]
    mode_name = {k: m["name"] for k, m in v["modeDataDict"].items()}
    stage = {}
    for rounds in v["battleDataDict"].values():
        for lst in rounds.values():
            for x in lst:
                if x.get("bossId") and "act3autochess_h" in x["levelId"] and not x["levelId"].endswith("_S"):
                    stage.setdefault(x["bossId"], x["levelId"].split("/")[-1])
    data = json.loads(DATA.read_text(encoding="utf-8"))
    ids = {b["enemyId"] for b in data["bosses"]}
    hp = {}
    for boss, level in stage.items():
        f = levels / f"{level}.json"
        if not f.exists():
            print(f"missing {f.name}", file=sys.stderr)
            continue
        keys = {e["id"] for e in json.loads(f.read_text(encoding="utf-8")).get("enemyDbRefs", [])}
        found = sorted(keys & ids)
        if len(found) != 1:
            print(f"{boss} {level}: bosses {found}", file=sys.stderr)
            continue
        blood = v["bossInfoDict"][boss]["bloodDataDict"]
        hp[found[0]] = {mode_name.get(m, m): n for m, n in blood.items()}
    for b in data["bosses"]:
        if b["enemyId"] in hp:
            b["hpByMode"] = hp[b["enemyId"]]
        print(b["name"], "终极模拟", hp.get(b["enemyId"], {}).get("终极模拟", "-"), file=sys.stderr)
    DATA.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
