#!/usr/bin/env python3
"""Adds the airflow of 源石流发生装置 (城区 vents) to Resources/data/garrison_maps.json as terrain "airflow_down".

Input: the act3autochess level files from Kengxxiao/ArknightsGameData zh_CN
(gamedata/levels/activities/act3autochess/level_act3autochess_mNN.json). The board inside a level is located the way
StrongholdAssistant data/build_garrison_terrain.py does it (Apache-2.0): our map's defence point and two spawns matched
against the level's tile_end / tile_start tiles.

trap_013_blower (源石流发生装置, skill sktok_blower 「气流」, level 2 on these maps): blows airflow 3 tiles forward.
Operators deployed facing the same way: attack +30 %, the opposite way: −30 %; enemies moving with it: move speed
+50 %, against it: −50 % (skill_table blackboard).

    python3 scripts/build-terrain-devices.py <directory with level_act3autochess_mNN.json>
"""
import json
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "Resources/data/garrison_maps.json"
DIRS = {"UP": (-1, 0), "DOWN": (1, 0), "LEFT": (0, -1), "RIGHT": (0, 1)}   # level grid (y down, x right)


def main(levels: Path):
    data = json.loads(DATA.read_text(encoding="utf-8"))
    first_col = data["columns"][0]
    for m in data["maps"]:
        f = levels / f"level_act3autochess_{m['id']}.json"
        d = json.loads((f if f.exists() else levels / f"{m['id']}.json").read_text(encoding="utf-8"))
        tiles = d["mapData"]["tiles"]
        grid = [[tiles[i]["tileKey"] for i in row] for row in d["mapData"]["map"]]
        H = len(grid)
        ours = {(r, c): ch for r, line in enumerate(m["cells"]) for c, ch in enumerate(line)}
        d_cell = next(k for k, v in ours.items() if v == "D")
        s_cells = [k for k, v in ours.items() if v == "S"]
        found = None
        for y, row in enumerate(grid):
            for x, t in enumerate(row):
                if t != "tile_end":
                    continue
                for flip in (1, -1):
                    oy, ox = y - flip * d_cell[0], x - d_cell[1]
                    def at(r, c):
                        yy, xx = oy + flip * r, ox + c
                        return grid[yy][xx] if 0 <= yy < H and 0 <= xx < len(grid[yy]) else None
                    if all(at(r, c) == "tile_start" for r, c in s_cells):
                        found = (oy, ox, flip)
                        break
                if found: break
            if found: break
        oy, ox, flip = found
        rows, cols = len(m["cells"]), len(m["cells"][0])
        devices = []
        for t in (d.get("predefines") or {}).get("tokenInsts", []):
            key = t["inst"]["characterKey"]
            if key != "trap_013_blower":
                continue
            y, x = H - 1 - t["position"]["row"], t["position"]["col"]
            r, c = (y - oy) * flip, x - ox
            dy, dx = DIRS[t["direction"]]
            dr, dc = dy * flip, dx
            wind = [[c + dc * k + first_col, r + dr * k] for k in (1, 2, 3)
                    if 0 <= r + dr * k < rows and 0 <= c + dc * k < cols]
            if not (0 <= r < rows and 0 <= c < cols) and not wind:
                continue   # another player's board
            if (dr, dc) != (1, 0):
                sys.exit(f"{m['id']}: blower facing {t['direction']} — only downward airflow is modelled")
            devices += [cell for cell in wind if cell not in devices]
        terrain = m.get("terrain") or {}
        if devices:
            terrain["airflow_down"] = sorted(devices)
        else:
            terrain.pop("airflow_down", None)
        if terrain:
            m["terrain"] = terrain
        else:
            m.pop("terrain", None)
        print(m["id"], m["name"], devices or "-", file=sys.stderr)
    DATA.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
