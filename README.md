# PocketVM

在 iOS / iPadOS 上运行 Debian ARM64 虚拟机，并通过 Codex CLI 的 app-server 协议提供对话界面。独立项目，与 OpenAI 和 UTM 无隶属关系。

源码：https://github.com/abasbdjasdl/pocketvm-build

## 功能

- QEMU 虚拟机，支持 JIT 和无 JIT 的 TCI 解释模式。
- 下载并校验 Debian 镜像，自动安装 Node.js 和 Codex CLI。
- Codex 设备码登录、账户模型列表、历史对话、流式回复。
- 回复中的中断和引导使用 `turn/interrupt`、`turn/steer` 协议。
- 可调整的串口终端面板。
- 系统照片与文件选择器，附件导入和共享目录。
- 设置中可启用开发 SSH，默认关闭，仅监听本机回环地址。

## 当前状态

这是仍在开发的实验项目。已经在 iPad Pro M4 / iPadOS 18.7.2 上验证过启动、登录和部分协议流程；其他设备尚未验证。工程目前的 `TARGETED_DEVICE_FAMILY` 为 iPad，iPhone 界面和安装支持仍需适配。无 JIT 模式明显较慢。

照片导入、共享目录以及真实回合中的中断与引导仍需更多实机验证。模型及额度取决于登录账户的服务端返回；`gpt-reserve` 出现在模型目录中不代表账户有备用额度。定时任务界面尚未接入真正的调度器。

## 安装与构建

1. 在 [GitHub Actions](https://github.com/abasbdjasdl/pocketvm-build/actions/workflows/build.yml) 选择成功的构建。
2. 下载 `PocketVM-build` artifact，解压得到未签名的 `PocketVM.ipa` 和 `SHA256SUMS`。
3. 校验 SHA-256，用自己的签名工具安装。仓库不包含签名证书。
4. 首次启动需要网络下载系统并安装依赖。登录 Codex 需要自己的账户。

开发构建可 Fork 此仓库，然后在 Actions 中运行 **Build PocketVM**。默认使用工作流中固定的 QEMU 运行时资源；可选择从 UTM 源码重新构建。需要 macOS / Xcode 才能构建 iOS 应用。

本地构建入口：`scripts/build_local.sh`。运行时来源和版本见 `.github/workflows/build.yml`、`NOTICE.md`。

## 共享目录

- 宿主 App：`Documents/Shared`
- Linux 客户机：`/home/codex/Shared`

共享目录通过本机 HTTP 服务与客户机 FUSE 挂载提供实时读写。支持普通文件与目录，不支持符号链接和 Unix 权限修改；软件包、Git 仓库和虚拟环境应放在客户机的其他目录。安装脚本自动维护 `/home/codex/AGENTS.md` 中的英文环境说明，保留已有的其他内容。

## 开发 SSH

在设置中启用 SSH，保存后重启虚拟机。默认转发宿主回环端口 `2222` 到客户机 `22`。用户名 `codex`，密码在设置中查看。

电脑可通过 USB 转发连接：

```sh
python -m pymobiledevice3 usbmux forward 22222 2222 --host 127.0.0.1
# 另一个终端
ssh -p 22222 codex@127.0.0.1
```

不要把设备的 `provision.json`、`proxy.txt`、Codex 登录文件、磁盘镜像或个人附件提交到仓库。

## 开发与测试

```sh
node --test scripts/test-app-server.mjs scripts/test-terminal-replay.cjs scripts/test-boot-services.mjs scripts/test-frontend.cjs scripts/test-repair.cjs
node --check web/app.js
for script in guest/*.sh; do bash -n "$script"; done
```

Swift 的协议、登录、共享目录和运行配置测试在 GitHub Actions 中执行。浏览器预览：

```sh
python -m http.server 4173 --directory web
```

打开 `http://127.0.0.1:4173/?entered=1`。浏览器中的模型数据是预览样例，不代表设备账户的实际权限。

## 结构

- `Sources/`：SwiftUI、WebKit 桥接、QEMU 宿主、协议通道。
- `guest/`：安装、启动、代理、共享目录和 Codex relay。
- `web/`：对话、设置和终端界面。
- `scripts/`：构建工具与回归测试。

## 许可证

项目自身代码采用 **GPL-3.0-or-later**，见 [LICENSE](LICENSE)。第三方组件仍遵循各自许可证，来源见 [NOTICE.md](NOTICE.md)。本项目不授予 OpenAI、Codex 或 UTM 的商标权利。
