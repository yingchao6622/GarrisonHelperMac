# 素材与数据来源

《明日方舟》的游戏美术、数据、角色与敌人名称、字体，著作权归 **上海鹰角网络科技有限公司（Hypergryph）** 所有。本项目是免费的玩家自制工具，与鹰角网络无关，未获其认可或授权。权利方提出要求时，我们会移除相关内容。

[`LICENSE`](LICENSE)（Apache-2.0）只覆盖本项目的代码，**不覆盖**下面列出的素材和数据。上游项目同样声明它们的许可不覆盖这些素材（StrongholdAssistant `NOTICE`、`ASSETS.md`）。

## 运行必需

识别和推荐要用到这些文件，删掉后对应功能无法工作。

| 位置 | 内容 | 来源 |
| --- | --- | --- |
| `Resources/data/operators.json`、`equipment.json`、`covenants.json`、`covenant_effects.json`、`strategies.json`、`bosses.json`、`round_income.json`、`equipment_categories.json` | 干员、装备、盟约、策略、首领、每回合收入等当期数据（规程 V3_1） | [StrongholdAssistant](https://github.com/LBEILC/StrongholdAssistant) `data/`，它又取自 [bingyunhe/asp-assistant-arknights](https://github.com/bingyunhe/asp-assistant-arknights) `data/`（取自 PRTS、SPDatabase）；盟约效果由上游按游戏内盟约报告手工整理。`bosses.json` 的 `hpByMode`（各模式首领血量）由 `scripts/build-boss-hp.py` 从 [ArknightsGameData](https://github.com/Kengxxiao/ArknightsGameData) `activity_table.json`（`bossInfoDict`）和首领关卡文件生成。`equipment.json` 的 `fuse`（合成）和 `sources`（来源干员）由 `scripts/build-equipment-relations.py` 取自 StrongholdAssistant `data/codex_extra.json`，它又取自 ArknightsGameData `activity_table.json` |
| `Resources/data/mode_pools.json` | 各模式可出现的盟约 | [ASP_Assistant](https://github.com/Moonfair/ASP_Assistant) `data/covenants.json` |
| `Resources/data/operator_profiles.json` | 干员职业、定位、叠层、攻击范围（裁剪） | StrongholdAssistant `data/operator_profiles.json`（由 CarlosDJY 的生成脚本从 [ArknightsGameData](https://github.com/Kengxxiao/ArknightsGameData) 生成） |
| `Resources/data/prototypes.json` | 商店替身卡（Pith 等）对应的真身 | StrongholdAssistant `data/prototypes.json`（从 ArknightsGameData `activity_table.json`、`character_table.json` 生成）；`scripts/build-prototypes.py` 转换 |
| `Resources/data/enemies.json`、`enemy_types.json`、`bounties.json`、`adapt_tactics.json` | 敌人资料、敌人类型、悬赏、战术 | StrongholdAssistant `data/`；敌人资料取自 ArknightsGameData |
| `Resources/data/enemy_routes.json` | 每回合的关卡和敌人路线 | StrongholdAssistant `data/garrison_routes.json`（从 ArknightsGameData 关卡文件生成）；`scripts/build-enemy-routes.py` 转换 |
| `Resources/data/garrison_maps.json` | 10 张地图的格子、地形、镜头角点 | StrongholdAssistant `data/garrison_maps.json`（改编自 CarlosDJY/asp-assistant-arknights，原始数据取自 ArknightsGameData）；城区排风口气流（`terrain.airflow_down`）由 `scripts/build-terrain-devices.py` 从 ArknightsGameData 关卡文件生成 |
| `Resources/data/garrison_board_refs.json` | 认地图用的镜头和颜色样本（样本取自游戏画面） | bingyunhe/asp-assistant-arknights dev 分支（Apache-2.0），经 StrongholdAssistant |
| `Resources/data/covenant_bar_digits.json` | 顶栏层数等数字的游戏字体模板 | StrongholdAssistant（取自其用户的对局录屏） |
| `Resources/data/level_glyphs.json` | 终端等级图形模板 | 本项目从 Mac 客户端截图采集（只含图形掩码） |
| `Resources/field/tier-1..6.png` | 场上阶级角标模板，40×40 | StrongholdAssistant `data/field/`（取自游戏截图和 ArknightsAssets2） |
| `Resources/model/SpriteModel.mlpackage`、`sprite-model-classes.json` | 场上小人识别模型 | StrongholdAssistant `data/sprite-model.onnx`（用游戏小人渲染图训练），`scripts/convert-sprite-model.py` 转成 Core ML |

## 只用于界面显示

| 位置 | 内容 | 来源 |
| --- | --- | --- |
| `Resources/icons/` | 干员、装备、盟约、策略、敌人、首领图标（561 个，约 10 MB），缩到 96px | ASP_Assistant / hongxue-stronghold-companion `data/icons/`（取自 PRTS 和 ArknightsGameResource） |

应用图标 `Resources/AppIcon.png` 是本项目自己画的（`scripts/make-app-icon.swift`，只用几何图形），不含游戏美术，和代码一样以 Apache-2.0 发布。

## 没有使用的数据

- 路标档案馆「卫戍协议出怪预览」的怪组与人数数据：hongxue 写明是获授权使用，StrongholdAssistant 写明不按 Apache 许可再授权。本项目没有用，所以不显示每回合敌人人数。
- MaaFramework（LGPL-3.0）：只在本地对照，没有移植代码。
