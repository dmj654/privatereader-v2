# 私阅读 PrivateReader

个人自用的 iOS 小说 / 漫画阅读器。本地文件 + 在线书源双通道，数据全在手机上，无账号、无后端。

## 文档

| 文件 | 内容 |
|---|---|
| `PRD.md` | 产品需求：范围、数据、验收标准 |
| `DEVPLAN.md` | 开发计划：13 个里程碑、86 张任务卡 |
| `design/` | 页面结构与视觉设计稿（HTML，浏览器直接打开） |

## 环境

- macOS + Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 首次：`xcodegen generate` 生成 `PrivateReader.xcodeproj`，然后打开

## 测试

```bash
# 纯逻辑层（快，不依赖模拟器）
swift test --package-path ReaderCore

# App 编译检查
xcodebuild -project PrivateReader.xcodeproj -scheme PrivateReader \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

CI 在 GitHub Actions 的 macOS runner 上跑上面两条。

## 结构

```
ReaderCore/     纯 Swift 逻辑层（解析、规则引擎、数据、备份），可 swift test
App/            SwiftUI 界面层
project.yml     XcodeGen 配置
```
