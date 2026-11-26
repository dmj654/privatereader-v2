# 私阅读 · 开发计划（可直接执行）

| 项 | 内容 |
|---|---|
| 依据 | `PRD.md` v1.0 |
| 版本 | v1.0 |
| 平台 | iOS 16.0+ · iPhone 竖屏 · SwiftUI |
| 形态 | 个人自用 · 侧载安装 |
| 计划类型 | 里程碑 + 任务卡（含验收映射） |

> **怎么用这份文档**：按里程碑顺序做，每个任务卡都有编号、产出文件和「完成标准」。完成标准即验收口径，做到就打勾，不要凭感觉推进。里程碑之间有依赖，不要跳序；但 M8（漫画）与 M5（朗读）可以互换先后。

---

## 1. 技术选型

### 1.1 选型结论

| 层 | 选择 | 理由 | 备选与否决原因 |
|---|---|---|---|
| UI | SwiftUI | 单人维护、迭代快；毛玻璃/圆角/动效原生支持 | UIKit 否决：样板代码多，收益不明显 |
| 最低版本 | iOS 16.0 | 覆盖 iPhone 12 及以上；可用 `NavigationStack`、`Layout` 协议 | iOS 17 否决：SwiftData 迁移能力不足 |
| 数据 | SQLite + **GRDB.swift** | PRD 的 `user_version` 迁移策略与 GRDB 的 `DatabaseMigrator` 一一对应；WAL、外键、事务齐全 | SwiftData 否决：迁移与级联删除不可控；Core Data 否决：样板重 |
| 网络 | URLSession + async/await | 系统自带，够用 | Alamofire 否决：只用到 GET，不值一个依赖 |
| HTML 解析 | **SwiftSoup** | legado 规则绝大多数是 CSS 选择器；SwiftSoup 支持 CSS3 子集 | 自己写解析器否决：选择器语义太多 |
| 图片 | **Kingfisher** | 异步加载 + 内存/磁盘双缓存，漫画场景刚需 | 自研否决：缓存淘汰策略容易踩坑 |
| 压缩包 | **ZIPFoundation** | epub / cbz / 备份 zip 三处复用 | 系统 Archive 否决：不支持流式解压 |
| PDF | PDFKit | 系统自带，按页渲染 | — |
| 朗读 | AVSpeechSynthesizer | PRD 已定：本地、不联网 | 云端 TTS 已排除 |
| 后台播放 | AVAudioSession + MPNowPlayingInfoCenter | 锁屏控制（C6）必需 | — |
| 依赖管理 | Swift Package Manager | 无 Podfile、无 Carthage | CocoaPods 否决：额外工具链 |

**最终依赖清单（4 个）**：`GRDB.swift`、`SwiftSoup`、`Kingfisher`、`ZIPFoundation`。除此之外不引入任何第三方。

### 1.2 工程约束

- **纯 SwiftUI + async/await**，不用 Combine 做数据流（除必要处）。
- **依赖注入**：所有 Repository、Service 挂在 `AppEnvironment`，通过 `@Environment` 注入，禁止单例满天飞（`Database.shared` 例外）。
- **数据层不碰 UI**：Repository 只返回 Model，不返回 View。
- **一眼能看懂文件属于哪个功能**：Feature 目录按页面切，不按类型切。

---

## 2. 工程搭建（M0 前置）

### 2.1 环境要求

| 项 | 要求 |
|---|---|
| 机器 | macOS 13+ |
| Xcode | 15.0+ |
| 真机 | 至少一台 iPhone（模拟器无法验证 TTS 后台播放与侧载签名） |
| 证书 | 免费 Apple ID（7 天重签）或付费开发者账号（1 年） |

### 2.2 目录结构（建工程时一次搭好）

```
PrivateReader/
├── App/
│   ├── PrivateReaderApp.swift        # @main，环境注入
│   ├── RootTabView.swift             # 四个 Tab + 各自 NavigationStack
│   └── AppEnvironment.swift          # 依赖容器
├── DesignSystem/
│   ├── Tokens.swift                  # 颜色/字号/圆角/阴影/间距
│   ├── GlassStyle.swift              # 毛玻璃 modifier
│   └── Components/                   # Card / Chip / Segment / SheetHost / EmptyState / Skeleton / ErrorBanner
├── Data/
│   ├── Database.swift                # GRDB 初始化 + migrations
│   ├── Models/                       # Book / Progress / Bookmark / BookGroup / BookSource / ReadingSession / ChapterCache
│   └── Repositories/                 # 每个实体一个 Repository
├── Core/
│   ├── Import/                       # TxtParser / EpubParser / PdfParser / CbzParser / ImportQueue
│   ├── SourceEngine/                 # LegadoParser / RuleRunner / SourceClient / Purifier
│   ├── TTS/                          # SpeechEngine / SentenceSplitter / NowPlayingCenter
│   ├── Storage/                      # SandboxPaths / CoverStore / CacheStore
│   └── Backup/                       # BackupExporter / BackupImporter
├── Features/
│   ├── Home/  Shelf/  Discover/  Search/  Detail/
│   ├── Reader/
│   │   ├── Novel/                    # Paginator / ReaderView / MenuPanel / TypographySheet
│   │   └── Comic/                    # PageReader / StripReader / DisplaySheet
│   ├── Catalog/                      # 目录抽屉
│   ├── Sources/                      # 书源管理
│   └── Settings/                     # 设置 / 统计
└── Resources/
    ├── Assets.xcassets
    └── TestBooks/                    # 测试素材（见第 6 节）
```

### 2.3 工程配置（一次性设置，出错会连锁）

| 配置项 | 值 | 说明 |
|---|---|---|
| Bundle ID | `com.<你的名字>.privatereader` | 自签必须唯一 |
| Deployment Target | iOS 16.0 | |
| Supported Orientations | **仅 Portrait** | PRD H4 |
| Device Family | iPhone only | |
| Background Modes | `Audio, AirPlay, and Picture in Picture` | 朗读锁屏（C6）必需 |
| File Sharing | 关闭 | 数据不外露 |
| `UIFileSharingEnabled` | NO | 同上 |

---

## 3. 里程碑总览

| 里程碑 | 主题 | 结束后能做什么 | 工作量 |
|---|---|---|---|
| **M0** | 骨架与设计系统 | 四个空 Tab 能跑，所有基础组件可复用 | S |
| **M0.5** | 书源可行性预研 | 知道 legado 规则能覆盖多少，风险提前暴露 | S |
| **M1** | 数据层 | 数据能存能取，迁移可跑 | M |
| **M2** | 本地导入与解析 | 能把 txt/epub/pdf/cbz 变成书架里的书 | L |
| **M3** | 书架与详情 | 能管理、分组、进详情 | M |
| **M4** | 小说阅读器 | **能完整看本地小说**（第一个可用闭环） | L |
| **M5** | 朗读 | **能边听边读**（第二个可用闭环） | M |
| **M6** | 书源引擎 | 能导入书源并搜到书 | L |
| **M7** | 发现 / 搜索 / 在线阅读 / 缓存 | **能追网文，能离线** | L |
| **M8** | 漫画阅读器 | 能看漫画（单页 + 条漫） | M |
| **M9** | 主页与统计 | 首页的「接着读」活起来 | S |
| **M10** | 备份与设置 | 数据可导出可恢复 | M |
| **M11** | 回归与打磨 | 45 条验收全过 | M |

**关键节点**：M4 结束 = 自己已经能用起来；M7 结束 = 双通道打通。这两个点之后不要再加新功能，只补质量。

---

## 4. 各里程碑任务卡

### M0 · 骨架与设计系统

**目标**：一个能跑的空壳，但视觉基调已经定死，后面所有页面直接拼装。

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M0-T1 | 建 Xcode 工程，配置见 2.3 | `PrivateReader.xcodeproj` | 真机能装上并启动 |
| M0-T2 | 接入 4 个 SPM 依赖 | `Package.resolved` | 编译通过，无版本冲突 |
| M0-T3 | 建目录结构与空文件占位 | 第 2.2 节全部目录 | 每个 Feature 至少一个空 View |
| M0-T4 | `Tokens.swift`：色板、字号阶梯、圆角、阴影、间距 | 1 个文件 | 与 `视觉设计-v1.html` 附录数值一致 |
| M0-T5 | `GlassStyle.swift`：毛玻璃 modifier（blur 24–32 / saturate 180% / 半透明底 + 细描边） | 1 个文件 | 用于 Tab 栏与顶栏，内容下透不出字 |
| M0-T6 | 基础组件：Card / PrimaryButton / Chip / Segment / EmptyState / Skeleton / ErrorBanner | `DesignSystem/Components/` | 每个组件有一个 Preview 页可单独看 |
| M0-T7 | `RootTabView`：四 Tab + 各自 `NavigationStack` | 1 个文件 | 切换 Tab 不重建页面状态 |

**风险**：M0-T5 的毛玻璃在真机上如果过于透明导致文字发灰，把底色调到 0.85 以上再测。

---

### M0.5 · 书源可行性预研（不写进主工程，独立 Playground / 临时 Target）

**目标**：在投入 M6 之前，先知道「legado 的规则我们到底能吃下多少」。

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M0.5-T1 | 挑 3 个真实 legado 书源（小说 2 + 漫画 1） | `Resources/SourceSamples/` | 规则 JSON 能正常打开 |
| M0.5-T2 | 用 SwiftSoup 手写一次「搜索 → 目录 → 正文」全链路 | 一个临时命令行 / Playground | 三个源至少两个能跑通正文 |
| M0.5-T3 | 统计规则类型使用情况（CSS / 正则 / XPath / JS / 内置函数） | 一页报告（写在本文件附录） | 明确「不支持清单」 |
| M0.5-T4 | 判断是否需要降级策略（如 XPath 用正则兜底） | 结论 | 结论写进 M6 的设计前提 |

**为什么要这一步**：legado 规则里有不少 XPath、`@js:`、`{{java.xxx}}` 这类能力，SwiftSoup 只吃 CSS。不预先量化，M6 会变成一个无底洞。

---

### M1 · 数据层

**目标**：PRD 第 5、7 节的数据结构全部落地，并保证迁移可演进。

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M1-T1 | `Database.swift`：GRDB 初始化、WAL、外键开启 | 1 个文件 | 首次启动建库成功，二次启动幂等 |
| M1-T2 | v1 迁移：建表 + 索引（DDL 见第 5 节） | `migrations` | 空库升级到 v1 通过 |
| M1-T3 | 七个 Model（Codable + FetchableRecord + PersistableRecord） | `Data/Models/` | 编译通过 |
| M1-T4 | 七个 Repository：Book / Progress / Bookmark / BookGroup / Source / Session / Cache | `Data/Repositories/` | 每个有 CRUD + 单元测试 |
| M1-T5 | 种子数据：三个内置分组（在追 / 看完 / 弃了） | 迁移内插入 | 首启即有，重复启动不重复插入 |
| M1-T6 | `SandboxPaths`：Books / Covers / Cache / Backups 四目录初始化 | 1 个文件 | 目录不存在时自动创建 |
| M1-T7 | 级联删除验证：删书 → 进度/书签/缓存记录一并消失 | 单元测试 | 外键 `ON DELETE CASCADE` 生效 |

**单元测试清单**：CRUD 各 2 条、级联删除 1 条、内置分组幂等 1 条。

---

### M2 · 本地导入与解析

**目标**：任意常见格式丢进来，都能变成书架里一本可读的书。

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M2-T1 | `ImportQueue`：串行队列 + 逐项进度 + 失败原因收集 | `Core/Import/ImportQueue.swift` | 30 个文件不卡 UI，逐个出结果 |
| M2-T2 | `TxtParser`：编码探测（UTF-8 → GB18030）+ 章节正则切分 | `TxtParser.swift` | 300 章测试稿切分误差 ≤ 2（A3） |
| M2-T3 | `EpubParser`：zip → container.xml → opf → spine → 章节文本 + 内嵌封面 | `EpubParser.swift` | 10 本 epub 全部解析成功（A1） |
| M2-T4 | `PdfParser`：PDFKit 按页切章，首页渲染为封面 | `PdfParser.swift` | 5 本 pdf 可翻页阅读 |
| M2-T5 | `CbzParser`：zip → 图片按文件名自然排序（`1,2,10` 不能排成 `1,10,2`） | `CbzParser.swift` | 50 张图顺序正确 |
| M2-T6 | `CoverStore`：内嵌图 / 首图 / 渐变占位，统一裁 400×560 存 jpg | `Core/Storage/CoverStore.swift` | 三种情况各抽查 2 本（A2） |
| M2-T7 | 导入结果页：成功 N / 失败 M + 每项原因 | 一个 Sheet | 坏文件不中断整批（A5） |

**已知坑**：
- txt 编码：先 UTF-8 严格解码，失败再 GB18030，再失败按 Latin1 兜底并标注「编码可能有误」。
- epub 的 XHTML 要用 SwiftSoup `.text()` 取纯文本，别直接正则去标签，会把 `<br>` 丢掉导致段落粘连。
- cbz 排序必须用 `localizedStandardCompare`。

---

### M3 · 书架与详情

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M3-T1 | 封面墙（3 列 `LazyVGrid`）+ 列表视图切换 | `Features/Shelf/ShelfView.swift` | 1000 本滚动流畅（E1） |
| M3-T2 | 筛选 chips（全部 / 小说 / 漫画 / 在追 / 看完） | `ShelfFilterBar.swift` | 与分组联动，空结果显示引导 |
| M3-T3 | 每本卡片：封面、书名、2.5px 进度条、角标 | `BookCell.swift` | 更新章数 / 「新」两种角标正确 |
| M3-T4 | 长按快捷面板（改分组 / 标记读完 / 导出 / 删除） | `BookActionSheet.swift` | 面板不遮挡封面 |
| M3-T5 | 多选模式（批量删除 / 批量分组） | `ShelfSelectionBar.swift` | 全选、取消、计数正确 |
| M3-T6 | 分组管理抽屉（增删改排序） | `GroupManagerSheet.swift` | 删分组后书回到「在追」（E2） |
| M3-T7 | 删除逻辑：默认删记录、二次确认才删文件 | `BookRepository.delete(_:removeFile:)` | 文件 App 可验证（E3） |
| M3-T8 | 详情页：封面、标题、作者、标签、简介、继续阅读、加入书架、目录预览 | `Features/Detail/DetailView.swift` | 主按钮文案随进度变化 |

---

### M4 · 小说阅读器（第一个可用闭环）

**目标**：M4 结束后，自己已经可以用它读本地小说，不再打开别的 App。

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M4-T1 | `Paginator`：TextKit2 按容器尺寸分页，缓存每页起始偏移 | `Reader/Novel/Paginator.swift` | 改字号 / 行距后重新分页位置不跳（B4） |
| M4-T2 | 正文渲染 + 三区热区（左 / 中 / 右 1/3） | `ReaderView.swift` | 点中央开合 ≤ 250ms 且文字不位移（B1、B2） |
| M4-T3 | 双排菜单面板（上一章 — 滑杆 — 下一章 + 五图标） | `MenuPanel.swift` | 与 `页面结构 v1` 一致 |
| M4-T4 | 右侧竖排 5 圆钮（书签 / 搜索 / 目录 / 自动阅读 / 听书） | `SideButtons.swift` | 不占面板格子，不挡正文 |
| M4-T5 | 排版抽屉：字号 / 行距 / 字体 / 翻页方式 / 背景 | `TypographySheet.swift` | 改动即时生效（B4） |
| M4-T6 | 主题：日间 / 护眼 / 夜间 / 纯黑 | `ReaderTheme.swift` | 夜间底 `#0E1116` |
| M4-T7 | 进度节流保存（≤ 1 次/秒）+ 退出写盘 | `ProgressRepository.save` | 退出再进回到原段（B3） |
| M4-T8 | 书签：新增 / 列表 / 跳转 / 删除 | `BookmarkRepository` + UI | 摘录 30 字正确 |
| M4-T9 | 目录抽屉（V1 两栏：目录 / 书签 + 搜索 + 重新分章） | `Features/Catalog/CatalogDrawer.swift` | 打开自动定位当前章 |

**性能红线**：5MB txt 首屏 ≤ 2s（A4）。若达不到，把分页改成懒加载——只算当前章前后各 2 章。

---

### M5 · 朗读

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M5-T1 | `SpeechEngine`：AVSpeechSynthesizer 封装（播 / 停 / 续 / 换音色 / 调速） | `Core/TTS/SpeechEngine.swift` | 点耳机 ≤ 1s 出声（C1） |
| M5-T2 | `SentenceSplitter`：按中文标点切句，引号内不切 | 单元测试 20 条用例 | 切分准确率 ≥ 95% |
| M5-T3 | 句级高亮 + 自动滚动跟随 | `NovelReaderView` 内 | 偏差 ≤ 1 句（C2） |
| M5-T4 | 朗读面板（上排 5 / 下排 5）+ 点中间收起 | `TTS Panel` | 收起后朗读不中断（C4） |
| M5-T5 | 章末自动接下一章 | `SpeechCoordinator` | 无需点击（C5） |
| M5-T6 | 后台音频 + 锁屏控制（`MPNowPlayingInfoCenter` + `RemoteCommand`） | `NowPlayingCenter.swift` | 锁屏 10 分钟不中断（C6） |
| M5-T7 | 定时关闭（15 / 30 / 60 分钟） | 面板内 | 到点淡出停止，不报错 |
| M5-T8 | 手动翻页时朗读跟随 | `SpeechCoordinator` | 不回到原处（C7） |

**已知坑**：`AVAudioSession` 必须设 `.playback` + `.spokenAudio`，且 Info.plist 打开 Background Modes → Audio，否则锁屏即停。

---

### M6 · 书源引擎

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M6-T1 | `LegadoParser`：解析 JSON，单条 / 数组两种结构，拆包为多条 | `Core/SourceEngine/LegadoParser.swift` | 50 源测试包展开 50 条（F1） |
| M6-T2 | `RuleRunner`：CSS 选择器（SwiftSoup）+ 正则 + `{{变量}}` 替换 | `RuleRunner.swift` | 覆盖 `ruleSearch/BookInfo/Toc/Content` |
| M6-T3 | `SourceClient`：搜索 / 详情 / 目录 / 正文四个接口，带超时与重试 | `SourceClient.swift` | 单源失败隔离（F3） |
| M6-T4 | 并发搜索调度：多源并行、谁先回谁先出、可取消 | `SearchCoordinator.swift` | 首条 ≤ 2s（F2） |
| M6-T5 | `Purifier`：按源内规则正则替换，返回命中条目数 | `Purifier.swift` | 开关前后命中数可对比（B5） |
| M6-T6 | 书源管理页：列表 / 开关 / 状态 / 测一下 / 删除 / 导入 | `Features/Sources/` | 状态区分正常 / 超时 / 关闭 |
| M6-T7 | 编码兜底：源站 GBK 时正确转码 | `SourceClient` 内 | 用 GBK 站点验证不乱码 |

---

### M7 · 发现 / 搜索 / 在线阅读 / 缓存

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M7-T1 | 发现页：书源切换 chips、榜单（周/月/总）、分类网格 | `Features/Discover/` | 无源时显示导入引导，不显示空榜单 |
| M7-T2 | 搜索页：历史、书架命中（永远第一组）、各源分组、骨架、失败重试 | `Features/Search/` | 分组逐个填充，不整页等待 |
| M7-T3 | 在线书籍详情：简介、目录、加入书架 | 复用 Detail | 在线书进「在追」 |
| M7-T4 | 在线正文阅读：边下边读，先到先显示 | `SourceClient.fetchContent` | 弱网可读（F4） |
| M7-T5 | `CacheStore`：单章 / 整本下载、占用统计、清理 | `Core/Storage/CacheStore.swift` | 存储管理页数据准确 |
| M7-T6 | 离线策略：已缓存可读，未缓存明确提示 + 列出已缓存章 | `ReaderView` | 飞行模式验证（D5） |
| M7-T7 | 更新检测：打开 App 时扫描书架在线书 | `UpdateChecker` | 角标与「有更新」一致（F5） |

---

### M8 · 漫画阅读器

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M8-T1 | 单页模式：白页居中、底 `#F1F3F6`、页边细线 | `Reader/Comic/PageReader.swift` | 与 `视觉设计 v1` 一致 |
| M8-T2 | 双击 / 双指缩放 + 放大后单指拖动 | `ZoomablePageView` | 不误触翻页（D2） |
| M8-T3 | 条漫连续：长图分段拼接、高度未知先占位 | `StripReader.swift` | 滚动不跳、不白屏（D4） |
| M8-T4 | 三行面板（P1 / 1-4、翻页滑杆、收藏 / 下载 / 目录 / 自动） | `ComicPanel.swift` | 与设计稿一致 |
| M8-T5 | 显示设置抽屉：模式 / 翻向 / 适应 / 背景 / 自动翻页 | `DisplaySheet.swift` | 模式按书保存 |
| M8-T6 | 预加载：前后各 2 页，下一话倒数第 3 页预取 | `ComicPrefetcher` | 翻页 ≤ 300ms（D1） |
| M8-T7 | 图片下采样，避免大图撑爆内存 | `ImageDownsampler` | 连读 1 小时内存 ≤ 300MB（H2） |

---

### M9 · 主页与统计

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M9-T1 | 主页四区块（问候 / 接着读 / 最近添加 / 统计卡 / 有更新） | `Features/Home/` | 空书架显示双按钮引导 |
| M9-T2 | 接着读直达上次位置 | 路由 | 不经过详情页 |
| M9-T3 | 会话计时：进阅读器开始，切后台 / 退出结算 | `SessionRepository` | 读 10 分钟统计 +10±1（验收 10.8 补充） |
| M9-T4 | 统计页：本周 / 本月时长、读完本数、日均、7 日柱状图 | `Features/Settings/StatsView.swift` | 数字与 Session 表一致 |

---

### M10 · 备份与设置

| ID | 任务 | 产出 | 完成标准 |
|---|---|---|---|
| M10-T1 | `BackupExporter`：打包 manifest + db + covers + sources（书文件可选） | `Core/Backup/` | zip 结构符合 PRD 7.3（G1） |
| M10-T2 | `BackupImporter`：校验版本 → 二次确认 → 覆盖 → 重建索引 | `BackupImporter.swift` | 恢复后数据 100% 一致（G2） |
| M10-T3 | 版本不兼容拦截 | 同上 | 拒绝并说明，不动现有数据（G4） |
| M10-T4 | 设置页：排版默认值 / 音色 / 存储管理 / 备份恢复 / 关于 | `Features/Settings/` | 与设计稿一致 |
| M10-T5 | 备份提醒：30 天未备份在设置页显示提示 | 同上 | 不打扰、可关闭 |

---

### M11 · 回归与打磨

| ID | 任务 | 完成标准 |
|---|---|---|
| M11-T1 | 三态补齐：每页空 / 加载 / 出错（I5） | 断网 + 空数据各走一遍，无白屏 |
| M11-T2 | 按 PRD 第 10 章 45 条逐项回归 | 全部打勾，未过项记录原因 |
| M11-T3 | 性能：冷启动 ≤ 1.5s、内存峰值 ≤ 300MB（H1、H2） | Instruments 记录截图 |
| M11-T4 | 视觉一致性核对（I1–I4） | 对照 `视觉设计-v1.html` 逐页比对 |
| M11-T5 | 真机侧载 + 备份演练 | 删 App 重装 → 恢复 → 数据完整 |

---

## 5. 数据库 DDL（v1）

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE book_group (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  builtin   INTEGER NOT NULL DEFAULT 0,
  sort      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE book (
  id                 TEXT PRIMARY KEY,
  type               TEXT NOT NULL,              -- novel | comic
  origin             TEXT NOT NULL,              -- local | remote
  title              TEXT NOT NULL,
  author             TEXT,
  cover_path         TEXT,
  file_path          TEXT,
  source_id          TEXT REFERENCES source(id) ON DELETE SET NULL,
  source_book_id     TEXT,
  source_url         TEXT,
  group_id           TEXT REFERENCES book_group(id) ON DELETE SET NULL,
  status             TEXT NOT NULL DEFAULT 'reading',
  chapter_count      INTEGER NOT NULL DEFAULT 0,
  new_chapter_count  INTEGER NOT NULL DEFAULT 0,
  added_at           INTEGER NOT NULL,
  last_read_at       INTEGER
);
CREATE INDEX idx_book_group    ON book(group_id);
CREATE INDEX idx_book_lastread ON book(last_read_at DESC);

CREATE TABLE progress (
  book_id        TEXT PRIMARY KEY REFERENCES book(id) ON DELETE CASCADE,
  chapter_index  INTEGER NOT NULL,
  offset         INTEGER NOT NULL,
  percent        REAL NOT NULL,
  updated_at     INTEGER NOT NULL
);

CREATE TABLE bookmark (
  id             TEXT PRIMARY KEY,
  book_id        TEXT NOT NULL REFERENCES book(id) ON DELETE CASCADE,
  chapter_index  INTEGER NOT NULL,
  offset         INTEGER NOT NULL,
  excerpt        TEXT,
  note           TEXT,
  created_at     INTEGER NOT NULL
);
CREATE INDEX idx_bookmark_book ON bookmark(book_id, chapter_index);

CREATE TABLE source (
  id                 TEXT PRIMARY KEY,
  name               TEXT NOT NULL,
  type               INTEGER NOT NULL DEFAULT 0,   -- 0 小说 1 漫画
  enabled            INTEGER NOT NULL DEFAULT 1,
  raw_json           TEXT NOT NULL,
  last_check_at      INTEGER,
  last_check_result TEXT
);

CREATE TABLE reading_session (
  id            TEXT PRIMARY KEY,
  book_id       TEXT NOT NULL REFERENCES book(id) ON DELETE CASCADE,
  started_at    INTEGER NOT NULL,
  duration_sec  INTEGER NOT NULL
);
CREATE INDEX idx_session_time ON reading_session(started_at);

CREATE TABLE chapter_cache (
  book_id        TEXT NOT NULL REFERENCES book(id) ON DELETE CASCADE,
  chapter_index  INTEGER NOT NULL,
  kind           TEXT NOT NULL,                   -- text | images
  local_path     TEXT NOT NULL,
  size_bytes     INTEGER NOT NULL,
  PRIMARY KEY (book_id, chapter_index)
);

CREATE TABLE search_history (
  keyword     TEXT PRIMARY KEY,
  created_at  INTEGER NOT NULL
);

PRAGMA user_version = 1;
```

**迁移规则**：每次改表新增一个 `migrator.registerMigration("vN")`，只增不改；`user_version` 由 GRDB 维护。

---

## 6. 测试素材与测试计划

### 6.1 必须先准备好的素材（M2 之前）

| 素材 | 数量 | 用途 |
|---|---|---|
| txt（300 章 / 5MB / 含中英混排） | 3 | A3、A4、分章正则 |
| txt（GB18030 编码） | 1 | 编码探测 |
| epub（含内嵌封面 / 无封面 / 目录嵌套） | 3 | A1、A2 |
| pdf（扫描版 / 文字版） | 2 | 按页切章 |
| cbz（50 图 / 文件名含 1,2,10） | 2 | 排序 |
| 超长图（高 > 10000px） | 1 | D4 |
| legado 书源包（50 源） | 1 | F1 |
| GBK 编码的书源站点 | 1 | M6-T7 |
| 含「请记住本站」的测试书 | 1 | B5 净化 |

### 6.2 测试分层

| 层 | 覆盖 | 工具 |
|---|---|---|
| 单元测试 | 解析器、规则引擎、句子切分、备份打包 | XCTest |
| 集成测试 | Repository + 数据库、导入队列、恢复流程 | XCTest |
| 手工回归 | PRD 第 10 章 45 条 | 真机 + 秒表 + Instruments |

**原则**：解析器与规则引擎必须有单元测试，因为它们是「输入不可控」的部分；UI 不做自动化测试，单人项目收益太低。

---

## 7. 签名与发布流程

| 步骤 | 操作 | 注意 |
|---|---|---|
| 1 | Xcode 登录 Apple ID，自动管理签名 | 免费账号 7 天过期 |
| 2 | 首次真机安装 | 需在设置 → 通用 → VPN与设备管理中信任 |
| 3 | 重签前**必须导出备份** | 见 PRD 7.6 |
| 4 | 重签周期 | 免费 7 天 / 付费 1 年，到期前 App 打不开 |
| 5 | 不上架 App Store | 个人自用，无需审核 |

**建议**：把「今天距离上次备份 N 天」做成设置页的一行，比任何提醒都管用。

---

## 8. 风险登记

| 风险 | 影响 | 概率 | 应对 |
|---|---|---|---|
| legado 规则含 XPath / JS，SwiftSoup 吃不下 | M6 工作量翻倍 | 高 | **M0.5 预研先行**；只承诺 CSS 子集，不支持的在源列表标注 |
| txt 分章正则覆盖不全（「第1章」「第一章」「1.」混用） | 章节错乱 | 中 | 三级正则 + 兜底按固定字数切；提供「重新分章」入口 |
| 条漫长图高度计算错 | 滚动乱跳 | 中 | 先占位后回填；用真实超长图在 M8 首日验证 |
| 朗读与翻页抢滚动位置 | 高亮飘 | 中 | 朗读滚动只做 `scrollToVisible`，不重建视图 |
| 自签过期导致数据丢失 | 数据归零 | 确定性事件 | 备份功能优先做（M10 不能挪到最后一天） |
| 大文件内存占用 | 崩溃 | 中 | 图片下采样 + 分页懒加载 |
| 免费证书 7 天重签打断开发 | 节奏 | 高 | 开发期用模拟器 + 每周固定重签一次真机包 |

---

## 9. 验收项与里程碑映射（防漏项）

| 验收组 | 条目 | 主要在哪个里程碑完成 |
|---|---|---|
| A 导入与解析（A1–A5） | 5 | M2 |
| B 小说阅读器（B1–B4） | 4 | M4 |
| B5 净化 | 1 | M6（引擎）+ M4（开关） |
| C 朗读（C1–C7） | 7 | M5 |
| D 漫画（D1–D5） | 5 | M8（D5 需 M7 缓存） |
| E 书架（E1–E4） | 4 | M3 |
| F 在线书源（F1–F5） | 5 | M6（F1/F3）+ M7（F2/F4/F5） |
| G 备份恢复（G1–G4） | 4 | M10 |
| H 性能稳定（H1–H4） | 4 | 贯穿，M11 收口 |
| I 视觉一致（I1–I5） | 5 | 贯穿，M11 收口 |
| **合计** | **44** | 另有 1 条（统计准确度）在 M9 |

---

## 10. 开工顺序（第一周做什么）

1. 建工程、配 2.3 的六项设置、接 4 个依赖（M0-T1、T2）
2. `Tokens.swift` + `GlassStyle.swift`（M0-T4、T5）——先把颜色和玻璃定死，后面所有页面直接引用
3. `RootTabView` + 四个空页面（M0-T7）
4. 准备第 6.1 的测试素材（可与 1–3 并行）
5. 跑 M0.5 预研：三个源、一条链路，先撞墙

**第一个可验证的成果**：四个 Tab 能切、Tab 栏是毛玻璃、颜色和设计稿对得上。这一步过了，剩下都是往里填东西。

---

## 附录 · M0.5 预研结论（完成后回填）

| 规则能力 | 支持 | 备注 |
|---|---|---|
| CSS 选择器 | 待验证 | SwiftSoup |
| 正则 `##` 替换 | 待验证 | |
| XPath `@XPath:` | 预计不支持 | 需降级或跳过 |
| JS `@js:` / `{{java.}}` | 预计不支持 | 跳过并标注 |
| 变量 `{{key}}` | 待验证 | |
| GBK 编码 | 待验证 | |
