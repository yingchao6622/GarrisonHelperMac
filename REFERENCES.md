# 参考项目笔记

三个 Windows 项目的完整源码放在仓库外、和小助手文件夹并列的 `/Users/…/dev/卫戍协议小助手-参考项目/`（下面写成 `卫戍协议小助手-参考项目/…`；不参与编译、不打进 .app、不提交 git）。都是 Apache-2.0，许可与 NOTICE 见 `licenses/`。另有它们用的识别框架 MaaFramework（LGPL-3.0），只用来对照，没有移植任何代码。本文件只记录“哪个功能在哪个文件、我们用了什么”，引用以这里为准。

| 目录 | 上游 | 版本（clone 时） |
| --- | --- | --- |
| `卫戍协议小助手-参考项目/ASP_Assistant` | github.com/Moonfair/ASP_Assistant | 143764f · v3.8.9 · 2026-11-20 |
| `卫戍协议小助手-参考项目/hongxue-stronghold-companion` | github.com/bingyunhe/hongxue-stronghold-companion | e672af0 · v1.9.6 · 2026-11-20 |
| `卫戍协议小助手-参考项目/StrongholdAssistant` | github.com/LBEILC/StrongholdAssistant | 680869d · v1.3.6 · 2026-11-20 |
| `卫戍协议小助手-参考项目/MaaFramework` | github.com/MaaXYZ/MaaFramework（LGPL-3.0） | 86853d1 · 2026-11-18（`--depth 1`，没拉子模块） |

派生关系：ASP_Assistant（原作）→ bingyunhe/asp-assistant-arknights → StrongholdAssistant；hongxue 也直接派生自 ASP_Assistant。三者都用 MaaFramework 做识别，应用本身（C#/.NET、WPF / WebView2、Win32 截图）只支持 Windows。

MaaFramework 本身跨平台（Windows / Linux / macOS / Android），推理走 ONNX Runtime，可选 CPU / DirectML / WebGPU / CUDA / NCNN；macOS 上的 CoreML 已标为废弃、不再随 MaaDeps 提供（`source/binding/Python/maa/resource.py` `use_coreml`、`source/binding/NodeJS/src/apis/resource.d.ts`），所以在 Mac 上只能走 CPU 或 WebGPU，用不到神经网络引擎；CUDA 只有 NVIDIA 显卡能用。

### 路标档案馆数据的授权说明（原文位置）

- hongxue `NOTICE` 第 39–40 行：「Round-route matching uses enemy groups, gates and templates from the 路标档案馆 Garrison Protocol spawn preview with permission (https://www.lubiao.wiki/tools/garrison-spawn-preview).」
- hongxue `README.md` 第 306 行（致谢）：「感谢路标档案馆授权引用卫戍协议的怪组、出怪口和模板数据。」
- hongxue `data/garrison_round_routes.json` 的 `source`：spawns = lubiao.wiki 出怪预览，生成于 2026-11-11 00:08。
- StrongholdAssistant `NOTICE` 第 50–52 行：`data/garrison_spawns.json` 的怪组来自路标档案馆，「These data are not relicensed under the Apache License.」；`ASSETS.md` 第 70 行同。没有写授权。
- 两边都没有附路标档案馆的授权原文或条款，只有 hongxue 自己写的「with permission / 授权」；授权给的是 hongxue，这里没有用这些数据。

## 各项目定位

- **ASP_Assistant**：开局「确认本局信息」页录入盟约禁用、商店名称栏追踪、干员/装备图鉴、阵容编辑。C# WPF。
- **hongxue**：在 ASP 基础上做「规划」：阵容规划器（CarlosDJY 贡献）、自动推荐路线（先大后小/先小后大、开局→成型五阶段、逐等级运营建议）、购买自动标记、地图模拟。
- **StrongholdAssistant**：重做界面（WebView2 + Svelte），重点是「场上认人」（角标 + 小人模型 + 模板融合 + 跨帧身份追踪）、顶栏盟约读数、站位推荐（战斗模拟）、读取物资调配页。

## 本项目用到的部分

| Mac 版 | 来源文件 | 说明 |
| --- | --- | --- |
| `Resources/data/operators.json` 等 JSON | StrongholdAssistant `data/` | operators / equipment / covenants / covenant_effects / strategies / bosses / round_income |
| `Resources/data/operator_profiles.json` | StrongholdAssistant `data/operator_profiles.json` | 裁剪：只留 profession / position / roles / stack / consumes |
| `Resources/data/mode_pools.json` | ASP_Assistant `data/covenants.json` → `modePools` | 各模式可出现的盟约 |
| 图标 | ASP_Assistant / hongxue `data/icons/` | 缩到 96px |
| `Resources/model/SpriteModel.mlpackage` | StrongholdAssistant `data/sprite-model.onnx`（+ `sprite-model-classes.json`） | `scripts/convert-sprite-model.py` 转成 Core ML（FP16），输入 160×192 RGB，输出 223 类 logits |
| 场上角标模板 | StrongholdAssistant `data/field/tier-1..6.png` | 角标搜索：`src/ASPAssistant.Core/Services/FieldReader.cs`（`ReadBadges`、`Sample/Normalize/Dot`，IV/VI 用 tier-3 外框重绘） |
| 小人裁块几何 | StrongholdAssistant `FieldReader.Sprites.cs` | 脚点 = 角标中心 + (35, 112)，整备区再 +20；裁块 `(脚x−90, 脚y+(棋盘24/整备0)−180, 180, 204)`，送模型前拉伸到 160×192 |
| 非 16:9 画面 | StrongholdAssistant `FieldReader.Viewport.cs` | 按 max(1920/w, 1080/h) 缩放后居中裁成 1920×1080 |
| 商店名称栏 | ASP_Assistant `Services/ShopRecognizer.cs` | 720p 参考：名称栏 h−72s…h−10.8s；卡框 = 名字左 32s、上 145s、164s×184s |
| 准备页盟约禁用 | ASP_Assistant `CoreCovenantRecognizer.cs`、`CovenantGrid.cs` | 图标颜色阈值（青色=可用，灰+白角标=禁用），图标在名字上方 0.075h |
| 干员自动禁用规则 | ASP_Assistant | 有核心盟约：核心全禁才禁；无核心：附加全禁才禁 |
| 回合/资金/等级 | StrongholdAssistant `EconomyReader.cs` | 资金框 1080p 参考 (w−130s, h−273s, 65s, 38s)；Mac 实测要再往上约 15px，改为先找金色徽章 |
| 顶栏盟约 | StrongholdAssistant `CovenantBarReader.cs` | 顶栏区域 (中心±420s, 70s, 860s, 125s)，名字在下、层数在环内、罗马数字在上 |
| 卡价 / 升本价 | StrongholdAssistant `ShopReader.cs`（卡价在卡中心上方、与资金同一行）、`EconomyReader.cs` | Mac 版先在这一行找金色六边形徽章再读数字；升本价是 LEVEL 上方的灰色徽章 |
| 地图、路线、镜头角点 | StrongholdAssistant `data/garrison_maps.json`、`Placement/GarrisonBoard.cs`（CanDeploy） | 10 张图；镜头角点 → 单应变换；按场上角标平移校正（思路来自 `FieldReader.Camera.cs` FitFieldCamera，角标↔格子偏移来自 `FieldReader.ReadCells`） |
| 攻击范围 | StrongholdAssistant `data/operator_profiles.json` → `ranges` | 站位时数每个朝向覆盖的路线格 |
| `Resources/data/enemy_routes.json` | StrongholdAssistant `data/garrison_routes.json`（Apache-2.0；源自 ArknightsGameData act3autochess V3_1 关卡文件）+ `data/garrison_spawns.json` 的 `modes` | `scripts/build-enemy-routes.py` 生成：每个模式每回合打哪一关（领袖回合按领袖 enemyId），每张图每关的路线（地面 / 飞行、人数、领袖，传送处分段）。格子 (c, r) 中心在 (c+0.5, r+0.5)，与 `garrison_maps.json` 同一网格。用法对照 `Placement/EnemyRoutes.cs`、`EnemyRouteStore.cs`（RoundRoutes 的地面 / 飞行人数） |
| 敌人面板 | StrongholdAssistant `Services/RoundEnemyReader.cs` | 那边用标题模板定位、名单在标题右下方左对齐；这里用全屏 OCR 里的「敌人」/「悬赏」标题行定位（图标常被读成一个杂字：令敌人、香敌人），名字在标题右边 0.03h–0.14h、以「•」开头的是能力说明；整行要能对上 `enemies.json` 的名字。`garrison_spawns.json` 的出怪表来自路标档案馆，授权不明，没有拿来用 |
| 小地图补录、攻略悬浮窗 | hongxue-stronghold-companion v1.9.8（Apache-2.0）的「地图内补录」「攻略讲解悬浮窗」 | 只参考功能设计，代码自写 |
| 本局策略识别 | StrongholdAssistant `src/ASPAssistant.Core/Services/MatchStrategyReader.cs`（Apache-2.0） | 方法移植：右上角策略头像、32×32 圆内灰度相关、阈值 0.65 / 差距 0.15。参考特征改为用本项目 `icons/strategies` 现场生成，并在 SA 坐标附近搜索位置和大小；多帧投票 |
| 从森空岛导入战绩 | ASP_Assistant `src/ASPAssistant.Core/Services/GarrisonHistory.cs`、`GarrisonHistoryClient.cs`、`src/ASPAssistant.App/Services/HypergryphPassport.cs`（Apache-2.0）；字段含义参考 StrongholdAssistant `src/StrongholdAssistant.Host/SklandParser.cs`（Apache-2.0） | 流程移植：鹰角官网登录页里取一次性授权码 → 森空岛凭证 → 角色绑定 → 赛季资料 → 战绩，请求签名同 ASP。网页组件换成 WKWebView，凭证不落盘；首领编号对照表来自 SA |
| 特殊格 | StrongholdAssistant `data/garrison_maps.json` → `terrain`（`data/build_garrison_terrain.py` 从关卡文件生成，效果说明也在该脚本） | 活性源石（红地板）、沼泽、隐匿模块、优化模块（蓝箭头）；城区排风口气流（源石流发生装置，skill_table `sktok_blower`）由 Mac 版 `scripts/build-terrain-devices.py` 从 ArknightsGameData 关卡文件生成，棋盘对位方法同 `build_garrison_terrain.py`。站位里的取舍（挡人点放在红地板 / 蓝箭头前面、远程站红地板、谁都不站沼泽）按 `Placement/PlacementPlanner.cs` 注释里的规则，打分是 Mac 版自写 |
| 替身干员（商店 / 棋盘） | StrongholdAssistant `data/prototypes.json` → `slots`、`Services/PrototypeCatalog.cs`（Resolve）、`RosterReader.Prototypes.cs`、`SpriteMatcher.Prototypes.cs` | 没拥有的干员用 Pith / Sharp / 郁金香 等替身显示。`scripts/build-prototypes.py` 生成 `Resources/data/prototypes.json`（替身 → 真身 + 阶级）。上游按卡面盟约图标认真身，Mac 版按卡面印的盟约名（全屏 OCR）+ 终端等级；棋盘上的 Pith 替身在小人模型里是 `char_509_acast` 类（同 `AppearanceName`） |
| 战场 + 镜头识别 | StrongholdAssistant `Services/BoardRecognizer.cs` + `data/garrison_board_refs.json` | 90 个地砖颜色采样比对指纹，同时拟合镜头缩放/平移；首领回合用镜像镜头并排除地形变化格。Mac 版 `BoardRecognizer.swift` |
| 层数/价格等数字 | StrongholdAssistant `CovenantBarReader.cs`（White/Components/Vector）+ `data/covenant_bar_digits.json` | 游戏字体 32×28 模板按汉明距离匹配；Mac 版扩展了金色、青色、青底黑字几种笔色（`DigitReader`） |
| 选择弹窗 | StrongholdAssistant `Services/AdaptReader.cs`、`data/bounties.json`、`data/adapt_tactics.json` | 悬赏决策 / 道具补给 / 机密商店 / 战术决策的标题位置与卡列；推荐打分是 Mac 版自写 |
| 自选编队 | StrongholdAssistant `Services/CustomPickReader.cs` | 标题「确定自选编队」、两排各 6 张；推荐打分是 Mac 版自写。确认后（「已选择自选编队」）右侧结果区列出选中的人（5 阶一行、6 阶一行，各至多 2 个，没选是 NONE），Mac 版按行拼起 OCR 碎片（风 + 笛）再对自选名单，自动写进本局自选 |
| 下回合资金 | StrongholdAssistant `Host/HostApi.Economy.cs`（EconomyRule / Predict） | 下回合 = 基础收入 + 本回合多出来的钱；利滚利继承、得闲饮茶延后、随机资金策略照上游；「剩钱不继承、升本价每回合降 1」用用户 7 局调试记录核实（`Economy.swift`） |
| 装备功能分类 | StrongholdAssistant `data/equipment_categories.json` | 装备推荐（攻击/防御/生存/技力/经济/盟约） |
| 购买识别 | hongxue `ShopPurchaseDetector.cs` | 名字稳定 → 该格连续空两次 → 资金下降 |
| 阵容规划器 | hongxue `Services/LineupPlanner.cs` | DFS + 转职分配 + 调和/独行/奶位规则；策略棋子 Mech/Pith/变形同构见 `Models/LineupPlannerModels.cs` |
| 自动推荐 | hongxue `Services/AutoPlanner.cs` | 每个本家一个候选、先大后小/先小后大判定、逐等级建议（节奏 Rush/Stay/Steady/Max、留牌、关键牌、资金） |
| 路线阶段 | hongxue `Services/LineupRoutePlanner.cs`、`Models/LineupRouteModels.cs` | 阶段：开局(2本,≤2阶,6人)、前期(3,≤3,8)、中期(4,≤4,8)、后期叠层(6)、成型；倒推+正推，贪心填充+交换改进；叠层含放大器 |
| 替补建议 | hongxue v1.9.8 `Services/LineupSubstitutionAdvice.cs`（思路） | 成型阵容缺人时给一个顶替的人和何时换回；挑人规则和文字是 Mac 版自写：必须保住本家盟约、至少同一个路线盟约，优先已有 / 当前终端刷得到，再按覆盖的路线盟约、同定位、阶数接近排序 |

## 没有移植的

2026-11-22 对照 StrongholdAssistant README 的功能表（v1.3.6）：

- **已有**：开局识别（禁用盟约 / 敌方领袖 / 特训敌人，开局页自动读）、回合与资金、场上认人（角标 + 小人模型 + 替身还原 + 按名字计数）、盟约状态（顶栏层数和是否激活）、商店标记、回合阶段、游戏覆盖层（买 / 升本 / 刷新 / 冻结 / 站位 / 选择弹窗）、自选编队推荐、选择弹窗（悬赏 / 补给 / 机密商店 / 战术）、图鉴（干员 / 装备 / 盟约 / 策略 / 敌人）、侧栏贴游戏窗口。
- **只有一部分**：站位推荐（规则打分，没有按怪组和技能 / 模组 / 潜能 / 装备的战斗模拟、没有漏怪数和三种目标）；禁用干员（按禁用盟约推算，不认头像）；阵容（自动路线规划，没有手动编辑、保存多套）；跨帧身份追踪（按名字计数，没有逐格身份）。
- **2026-11-22 补上**：下回合资金预测、自选编队自动记下选了谁；本回合敌人路线（画在游戏画面上，站位按真实路线和人数，远程罩飞行航线）；侧栏小棋盘（路线、场上干员、建议格子，认不准的带「?」；只看不拖）；敌人列表（读游戏里的敌人面板）；特别关注；对局记录与战绩统计（名次手填）；快捷键 ⌃⌥H 隐藏 / 显示；小盟约路线覆盖 13 个可组路线的小盟约（独行、调和、绝技不单独成路线）。
- **还没有**：战斗模拟站位（按怪组算伤害 / 漏怪，技能 / 模组 / 潜能 / 装备）；小棋盘里拖人试摆；待确认问号画在游戏画面的小人头上（只画在小棋盘上）；禁用干员认头像；我的干员（读物资调配页的皮肤 / 技能 / 模组 / 潜能）；单人模式对局详情；分享码 / 森空岛导入；阵容广场；云同步；主题；备份导入导出；自动更新。
- Mac 版另有：AI 教练、联防看清是谁的棋盘、队友在做的本家（玩家列表 / 联防顶栏）、悬赏按阵容强度算期望、替身卡认真身、文字识别独立进程自动重启、画面没变就不读的实时节奏。


- StrongholdAssistant 的小人**模板融合**（`SpriteMatcher*.cs` + `sprite-templates.bin.gz`，30MB）、跨帧身份追踪（`FieldTracker*.cs`）、站位推荐/战斗模拟。Mac 版只用「角标 + Core ML 模型 + 同阶/本局候选过滤 + 替身还原 + 购买记录」，阵容按名字计数做跨帧平滑（`LineupTracker.swift`，自写）。
- StrongholdAssistant 的读取物资调配页、阵容广场、云同步、森空岛导入。
- hongxue 的地图模拟与站位参考（`PlacementPlanner.cs` 模拟退火）。Mac 版的站位是自写的简化规则（`Board.swift` PlacementHeuristic），推荐买/升/刷/冻的资金规则也是自写的（`ActionAdvisor.swift`），只有节奏（抢升本/补牌/稳升/满本）来自 hongxue AutoPlanner.Advise。

## Mac 客户端的实测布局（按 Mac 客户端截图实测）

- 窗口约 16:10，带标题栏；界面元素按 min(w/1920, h/1080) 缩放并贴边，棋盘按 max(1920/w,1080/h) 居中裁切。
- 回合数字：青色文件夹底上的深色数字；终端等级：LEVEL 图下的深色图形（1–3 本是竖条，4–6 本是罗马数字 IV/V/VI），满级显示「已满级」。Mac 版用 `Resources/data/level_glyphs.json`（32×24 掩码，从用户截图采集，`--make-level-templates` 生成）按汉明距离匹配；OCR 会把罗马数字读成 1，所以不用 OCR。
- 资金徽章：左边是三颗金色菱形的金币图标，OCR 会把它读成 8 或 3（9 → 89、5 → 85），只读图标右边的数字；徽章按金色描边的两条长横边定位（下面的金币堆、单位图标会干扰包围盒）。拖干员去出售时徽章移位、LEVEL 图被挡，这几帧不读资金和等级。
- 卡价：卡片右上角六边形，买得起是黑底金字，买不起是灰底白字；位置 = 卡框左上 + (111, 3)×(720p 缩放)，再按六边形金边的重心对正（名字定位会偏几像素，裁掉半个 3 会读成 2）。三合一奖励（高一阶粉卡，出现在商店右侧几格）价格是青色的 0。
- 商店名称栏：左边终端卡的「升级 / 已满级」不参与匹配（「已满级」会被读成「匕酒级」）；卡面上的盟约名（奇迹等）不参与匹配。两字名允许错一个字但只在唯一时匹配（何夜 → 伺夜）。
- 悬赏决策：两排三列共六张，标题以「悬赏 / 特训」结尾，长名字会折成两行；OCR 常把 赏 读成 賞、异 读成 昇、II 读成 川 / ！！，所以按卡上正文写的敌人名 + 奖励资金 + 场数认卡，标题只用来打破平局。
- 升本价：「升级」按钮正上方约 194（1080p）处的六边形，青字或白字。
- 顶栏：名字下、层数在环内底部（名字中心上方约 29）、Ⅰ/Ⅱ 竖线在环顶（约 92）；未激活的环是灰色。
- 作战中顶部是击杀计数（如 16/23）；联防时顶栏出现「层数叠加已禁用」，棋盘下方中间有标签：自己的棋盘是「自己」，队友的是「名字#四位数」；联防开始 / 结束的几帧没有标签，顶栏显示的是棋盘主人的盟约。
- 商店替身卡：卡名是替身名（Pith），名字上方从下往上印着真身的盟约（如 迅捷 / 萨尔贡 / 莱塔尼亚，OCR 前面常带一个图标误读字）。
- 商店展开 / 收起时镜头会推拉，动画中间那一帧地图对不上；沿用上一帧的镜头会把整排干员算错一行（最下一行被当成装备行丢掉）。

## 验证记录

每次改识别后的实测结果引用了开发者本机的对局录像，只保存在本机，不放进仓库。
