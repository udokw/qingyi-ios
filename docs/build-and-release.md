# 构建与发布

本文说明如何从源码生成 Xcode 工程、本地运行、用 GitHub Actions 打出无签名 IPA，以及侧载时需要注意的点。

> 工程使用 XcodeGen，`project.yml` 是唯一工程配置来源；`.xcodeproj` 和 `QingYi/Info.plist` 都由它生成，不要手工修改（下次生成会被覆盖）。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS（本地开发需要 Xcode；CI 使用 `macos-15`） |
| Xcode | 15 或更高（部署目标 iOS 16.0，Swift 5.7） |
| XcodeGen | `brew install xcodegen` |
| 设备 | 联机功能需要两台真机在同一局域网；模拟器只能连本机回环，无法验证 mDNS 发现 |

## 生成工程

```bash
cd <仓库根目录>
xcodegen generate            # 生成 QingYi.xcodeproj 与 QingYi/Info.plist
open QingYi.xcodeproj
```

`project.yml` 中与打包相关的关键项：

- `QingYi` target 的 `info.path: QingYi/Info.plist` + `info.properties`：生成 Info.plist，并设置 `GENERATE_INFOPLIST_FILE: "NO"`。
- `NSLocalNetworkUsageDescription`：首次联机会弹出「本地网络」权限，必须允许。
- `NSBonjourServices`：列出 `_qingyi._tcp`、`_qingyi-go._tcp`、`_qingyi-xiangqi._tcp`。按 Apple 要求**不带结尾的点**（Network 框架同样使用不带点的形式）；缺失任意一项，对应类型的房间就发现不到。
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`：版本号，直接写进 Info.plist。

## 本地运行

1. 用 Xcode 打开工程，选择 `QingYi` scheme。
2. 在 target 的 Signing & Capabilities 里选择自己的 Team（工程默认 `CODE_SIGN_STYLE: Automatic`），真机运行需要开发者账号。
3. 运行后进入首页 → 选择围棋或象棋 → 「联机对弈」。
4. 联机自测：
   - 两台设备连同一个 Wi-Fi（关闭 AP 隔离 / 客户端隔离）。
   - 一方「创建房间」，另一方在「附近房间」里点加入；发现不到时可用房主页面显示的 `IP:端口` 手动加入。
   - 首次会弹「允许访问本地网络」，拒绝后只能在系统设置里重新开启，否则发现与连接都会失败。

模拟器注意事项：模拟器与 Mac 共享网络栈，Bonjour 广播能出去但收不到另一台设备的真实回包，探活会失败。验证联机请用真机。

## GitHub Actions

工作流：`.github/workflows/build-ipa.yml`

| 触发 | 说明 |
| --- | --- |
| `push` 到 `main` / `master` | 构建并上传 artifact |
| `push` tag `v*`（如 `v1.0.0`） | 构建 + 上传 artifact + 创建 Release 并附带 IPA |
| `workflow_dispatch` | 在 Actions 页面手动 Run workflow |

流程：

1. `actions/checkout@v4`
2. `brew install xcodegen`
3. `xcodegen generate`
4. `xcodebuild -project QingYi.xcodeproj -scheme QingYi -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS="" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build`
5. 把 `build/Build/Products/Release-iphoneos/QingYi.app` 装进 `Payload/`，压缩成 `QingYi-unsigned.ipa`
6. `actions/upload-artifact@v4` 上传，artifact 名 `QingYi-unsigned-ipa`
7. tag 构建时 `softprops/action-gh-release@v2` 把 IPA 挂到 Release

产物位置：Actions 运行页 → Summary/Artifacts 下载 `QingYi-unsigned-ipa.zip`，解压得到 `QingYi-unsigned.ipa`；打 tag 时也可在 Releases 页面直接下载。

因为引擎（Pikafish / KataGo / Pachi）是源码静态链接进 App 的，CI 首次构建会编译大量 C/C++，耗时通常在 20 分钟以上属正常。

## 无签名 IPA 侧载

无签名 IPA 不能直接安装，需要借助签名工具：

| 工具 | 说明 |
| --- | --- |
| Sideloadly | Windows/macOS 均可，用 Apple ID 免费签名，有效期 7 天，到期需重签；免费账号同时最多 3 个 App |
| AltStore / AltStore PAL | 需要在电脑上装 AltServer 定期续签；PAL 版仅限欧盟区 |
| TrollStore | 仅特定 iOS 版本（依赖内核漏洞）可持久安装，不需要账号；版本不匹配时无法使用 |

通用步骤：下载 `QingYi-unsigned.ipa` → 拖入工具 → 输入 Apple ID 与密码（生成专用密码）→ 安装 → 在「设置 → 通用 → VPN与设备管理」里信任开发者证书。

注意：

- 免费签名不会改变 Bundle ID，但会按账号重新签名，推送/钥匙串共享等能力不可用（本工程未使用）。
- 重装或重签后，已保存的本地棋谱在 App 沙盒内，卸载会一并删除。
- 联机功能在侧载版本上同样可用，但每次重签后首次启动需要重新授予「本地网络」权限。

## 需要同步修改的位置

| 要改的东西 | 位置 |
| --- | --- |
| Bundle ID | `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER`（当前 `com.qingyi.app`） |
| 版本号 | `project.yml` → `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`；`QingYi/UI/MainView.swift` 页脚文案；`QingYi/Net/LanHub.swift` 的 `appVersion`（随 hello 上报） |
| 联机服务类型 | `QingYi/Net/LanProto.swift` 的 `serviceTypeNW` / `serviceTypeMDNS` / `goServiceTypeNW` / `xqServiceTypeNW` / `allServiceTypesNW` / `allServiceTypesMDNS`；`QingYi/Net/LanHost.swift` 的 `publishExtra()` 里两个类型字面量；`project.yml` 的 `NSBonjourServices`；Android 端 `Proto.SERVICE_TYPE` 必须一致 |
| 联机端口 | `LanProto.defaultPort` / `portTries`（与 Android `Proto.DEFAULT_PORT` / `PORT_TRIES` 一致） |
| 协议版本 / 房间码字母表 | `LanProto.version` / `LanProto.newRoomCode()`（与 Android `Proto.VERSION` / `Proto.newRoomCode()` 一致） |
| 首次联机权限文案 | `project.yml` → `NSLocalNetworkUsageDescription` |

改完协议相关字段后，必须同时核对 `docs/lan-protocol-parity.md`，否则 iOS 与 Android 会连不上或状态不同步。

## 常见问题

| 现象 | 排查方向 |
| --- | --- |
| 附近房间一直是空的 | `NSBonjourServices` 是否齐全；本地网络权限是否被拒；两台设备是否同网段；路由器是否开了 AP 隔离 |
| 能看到房间但提示「正在确认房主…」后消失 | 探活在 6 秒宽限内没成功：房主端口不通（防火墙）、`addr` TXT 指向了错误网卡；改用「手动地址」加入 |
| 加入后立刻断开 | 端口被占用（房主会从 41234 起顺延 11 个端口，注意看房主页显示的端口）；版本号/协议版本不一致会收到 `E_VERSION` |
| 对局中频繁提示重连 | Wi-Fi 抖动或息屏断网；链路静默 13 秒（房主）/15 秒（客机）即判断线，宽限期 120 秒 |
| CI 构建失败在引擎编译 | 先本地 `xcodegen generate` 再 `xcodebuild` 复现；确认 `project.yml` 的 excludes 未被改动 |

## 相关文档

- `docs/lan-protocol-parity.md`：与 Android 端的协议逐字段对照。
- `../project.yml`：工程与 Info.plist 的唯一配置来源。
- `.github/workflows/build-ipa.yml`：CI 构建与发布。
