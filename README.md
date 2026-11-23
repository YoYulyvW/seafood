# 海鲜台账 iOS

海鲜仓库库存管理的原生 iOS 客户端：SwiftUI + 本地 SQLite，可选远程 MySQL 同步，内置更新检测（TrollStore 安装）。

- 目标系统：**iOS 16.4+**
- 依赖：零第三方库（SQLite3 系统库、Network.framework、CryptoKit）
- 构建：GitHub Actions 无签名 IPA → TrollStore 安装

## 功能

| 模块 | 说明 |
|---|---|
| 库存首页 | 在库总量、今日出入、品类列表、点行展开批次、低库存标记、搜索与筛选 |
| 入库 | 按斤/公斤录入，现场新建品类并选活鲜/冰鲜/冷冻 |
| 出库 | 多品类一单，按批次先进先出扣减，库存不足行内提示 |
| 流水 | 按日/类型/品类筛选，展示损耗与盘点 |
| 设置 | 操作员、远程 MySQL 同步、从远程覆盖本地、检查更新、清空数据 |
| 更新 | 请求 `设置页里的更新地址`，发现新版下载校验后跳转 TrollStore |

## 远程 MySQL 同步

设置页填 `mysql://用户:密码@主机:3306/库名` 后：

- 每次写入后 2 秒防抖自动同步（先推后拉，按 `updated_at` 做 LWW 合并）
- 首次连接自动建表：`sf_category` / `sf_batch` / `sf_movement` / `sf_meta`
- “从远程覆盖本地”会清空本地后全量拉取（需二次确认）

## 本地开发

```bash
brew install xcodegen
xcodegen generate
open SeafoodInventory.xcodeproj
```

## 构建

推送到 `main` 触发 Actions；产物为 `Seafood-<version>-b<build>.ipa`，同时发布到 Release `seafood-latest`。

## 目录

```
Sources/
  App/      入口与 Tab
  Model/    类型与单位换算
  Data/     SQLite 本地库（流水为唯一真相）
  Sync/     MySQL 协议客户端 + 同步引擎
  Update/   更新检测与 TrollStore 跳转
  UI/       五个页面与设计 token
```
