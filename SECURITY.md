# 安全审计（iOS 客户端 + 同步 + 更新通道）

审计方式：静态代码审计（逐文件）+ 威胁建模，参照移动端安全检查表（保存/解包/权限/信任边界/运行时/网络/更新）。
审计时间：2026-11-23；审计对象：本仓库 main 分支（构建 b1003）。

## 1. 资产与信任边界

| 资产 | 位置 | 信任级别 |
|---|---|---|
| 库存流水与批次 | 本机 SQLite（App 沙盒 Documents） | 中：设备丢失即泄露业务数据 |
| MySQL 账号密码 | iOS Keychain（ThisDeviceOnly） | 高 |
| 远程库存库 | 团队自建 MySQL | 高：多端共享 |
| 安装包与更新清单 | 自建 HTTPS 反代 | 高：被换包 = 任意代码执行 |
| 更新地址配置 | 本地设置 | 中：可被改成任意 URL |

边界：设备 ↔ MySQL（原生 TCP）；设备 ↔ 更新服务（HTTPS）；TrollStore ↔ IPA 文件。

## 2. 发现与处置

| ID | 等级 | 发现 | 证据 | 处置 |
|---|---|---|---|---|
| S1 | 高 | 更新包只靠 HTTPS + 清单里的 sha256，清单与包同源；服务端被换或中间人可投毒 | Sources/Update/UpdateChecker.swift | 未实施：建议 Ed25519 签名清单，客户端内置公钥（P1） |
| S2 | 高 | IPA 无 Apple 签名（TrollStore 分发），任何人拿到文件可改包 | .github/workflows/build-ios.yml | 缓解：sha256 校验 + 私有分发；根治需签名清单（同 S1） |
| S3 | 中 | MySQL 链路默认 preferred，服务端不支持 TLS 时降级明文 | Sources/Sync/MySQLClient.swift | 已修：降级时 tlsWarning 上抛 UI 朱红提示；required 直接拒绝明文 |
| S4 | 中 | 数据库账号若给 ALL PRIVILEGES，泄露后可动同实例其它库 | 运维配置 | 已给最小权限脚本（见 §4） |
| S5 | 中 | LWW 合并依赖设备时钟，时间被调快会长期压制他人写入 | Sources/Sync/SyncEngine.swift 顶部注释 | 已文档化；建议设备开启自动时间（NTP） |
| S6 | 中 | 未签名包环境下 Keychain 可能返回 errSecMissingEntitlement | ldid entitlements | 未验证：真机需按 §5 第 4 条验证；失败时退化为每次输入密码 |
| S7 | 低 | 本地 SQLite 明文 | Sources/Data/SQLiteStore.swift | 依赖 iOS 数据保护；建议开启设备密码与加密备份 |
| S8 | 低 | ATS 允许任意加载（用户可填 http 更新地址/内网地址） | Sources/Info.plist | 需求所需；建议 UI 对 http 地址给明文警告 |
| S9 | 低 | 更新地址可由用户改成任意 URL，存在社工诱导面 | Sources/UI/SettingsView.swift | 默认值内置，修改需手动输入；建议后续加"恢复默认" |
| S10 | 信息 | 无第三方 SDK、无遥测、无后台定位/通讯录权限；网络面只有 TCP 3306 与 HTTPS | — | 符合预期 |

## 3. 已落地加固

- 凭据：MySQL 密码只进 Keychain（service `com.yoyulyvw.seafood.mysql`，account = host/user，ThisDeviceOnly）；SQLite 里的 DSN 不含密码；设置页一律打码。
- 错误脱敏：所有同步失败文本经 redact（密码明文替换 + DSN 正则打码），日志不落密码。
- SQL：字面量统一转义（\\ ' \0 \n \r \Z），库名白名单 [A-Za-z0-9_$]{1,64}，表名编译期常量。
- 传输：tls=required 拒绝明文；preferred 降级必须显式告警一次。
- 模式门禁：本地版完全不触网；远程版才自动同步，写入后 2 秒防抖。
- 依赖面：零第三方库（SQLite3 / Network / CryptoKit 均为系统框架）。

## 4. 最小权限（在 MySQL 上执行一次）

```sql
CREATE DATABASE IF NOT EXISTS seafood DEFAULT CHARSET utf8mb4;
CREATE USER IF NOT EXISTS 'seafood'@'%' IDENTIFIED BY '<强密码>';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, INDEX ON seafood.* TO 'seafood'@'%';
REVOKE FILE, SUPER, PROCESS ON *.* FROM 'seafood'@'%';
FLUSH PRIVILEGES;
```

建议再加：MySQL 只监听内网；3307/3306 不对公网暴露；如跨网段，用 stunnel/HAProxy 做 TLS 终结并把 App 的 tls 设为 required。

## 5. 真机验证清单

1. 本地版：开飞行模式，入库/出库/盘点全部可用，首页数字正确。
2. 远程版：两台设备连同一个库；A 入库后 B 下拉刷新能看到；同时改同一条，updated_at 大者胜。
3. TLS：tls=required 连明文 MySQL 应失败并给出中文原因；preferred 应出现朱红降级提示。
4. Keychain：保存密码 → 杀进程 → 重开仍能连；若报权限错误，记录错误码（S6）。
5. 更新：把发布清单 build +1，App 内检查更新 → 下载校验 → 跳 TrollStore 安装成功。
6. 错误面：错密码 / 错库名 / 端口关闭，三种错误都应是中文且不含密码。

## 6. 局限

本次只做静态审计与构建级验证，没有真机运行时观测（无越狱设备直连调试），S1/S2/S6 需实机或后续迭代闭环。
