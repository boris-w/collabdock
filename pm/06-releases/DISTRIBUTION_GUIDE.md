# 06 · 团队分发与发布 SOP（Distribution Guide）

> **关联需求**：[REQ-011](../02-product/PRD.md#req-011--团队分发团队模板与自动更新p1) | **关联决策**：[ADR-004](../03-architecture/decisions/ADR-004-pending-review-and-distribution.md)

本文档定义 CollabDock 从**内部开发试跑**到**全团队正式分发与持续自动更新**的标准发布流程。

---

## 1. 团队分发前置兼容性基线

- **系统要求**：macOS 14.0 (Sonoma) 及以上，支持 Apple Silicon (`arm64`) 与 Intel (`x86_64`)（正式分发构建 Universal Binary）。
- **本机前置依赖**：团队成员需本机已安装所需连接器凭据（V1 为 GitHub CLI `gh auth login` 或 PAT），以及 `claude`、`codex`、`agy` 中的任意一款或多款。

---

## 2. 阶段 A：团队早期内测分发（无 Apple 开发者证书阶段）

适用于 M1–M3 阶段快速发给小范围同事试用：

1. 本地构建 `.app` 并压缩：
   ```bash
   make app
   ditto -c -k --sequesterRsrc --keepParent build/CollabDock.app build/CollabDock-dev.zip
   ```
2. 同事解压后拖入 `/Applications`。
3. 如首次打开提示 macOS Gatekeeper 拦截（因尚未公证），执行一次解除隔离属性后启动：
   ```bash
   xattr -dr com.apple.quarantine /Applications/CollabDock.app
   open /Applications/CollabDock.app
   ```

---

## 3. 阶段 B：团队正式分发（免 Gatekeeper 告警 + 自动更新）

适用于 M4 及正式版本面向全团队推广：

### 3.1 Universal Binary 构建与代码签名
```bash
# 构建 arm64 + x86_64 通用二进制
swift build -c release --arch arm64 --arch x86_64

# 打包并启用 Hardened Runtime 签名
SIGN_IDENTITY="Developer ID Application: Your Team (TEAMID)" make app
```

### 3.2 Apple Notarization 公证与装订
```bash
ditto -c -k --keepParent build/CollabDock.app build/CollabDock.zip
xcrun notarytool submit build/CollabDock.zip \
  --keychain-profile "collabdock-notary" \
  --wait
xcrun stapler staple build/CollabDock.app
spctl --assess --type execute --verbose build/CollabDock.app
```

### 3.3 制作 DMG 与团队 Homebrew Cask 分发
推荐团队内部维护一个 GitHub 仓库（如 `your-org/homebrew-tap`），发布 `Casks/collabdock.rb`：

```ruby
cask "collabdock" do
  version "0.1.0"
  sha256 "<SHA256_OF_DMG>"

  url "https://github.com/<your-org>/collabdock/releases/download/v#{version}/CollabDock-#{version}.dmg"
  name "CollabDock"
  desc "macOS menu bar collaboration dock for local AI agents (Claude Code, Codex, Antigravity)"
  homepage "https://github.com/<your-org>/collabdock"

  depends_on macos: ">= :sonoma"

  app "CollabDock.app"
end
```

团队成员只需一条命令完成安装与升级：
```bash
brew install --cask your-org/tap/collabdock
```

### 3.4 Sparkle 2 自动更新（M4 接入）
1. 在 `Package.swift` 引入 `https://github.com/sparkle-project/Sparkle`。
2. 生成 EdDSA 公私钥（私钥仅存于 CI/发布者 Keychain，`SUPublicEDKey` 写入 `Info.plist`）。
3. 每次发版通过 `generate_appcast` 更新托管在 GitHub Releases / 团队静态站点的 `appcast.xml`，团队成员即可在菜单栏一键自动升级。

---

## 4. 团队统一配置包分发（Team Preset）

团队负责人可在设置页导出 `team-preset.json` 放到团队文档或仓库根目录，包含：
- 默认监听的组织/仓库白名单（如 `acme/*`）
- 约定的 `@mention` 触发词（如 `review`, `cr`, `帮忙看`）
- 团队统一的 Review Checklist Prompt 模板

新同事导入时**仅合并团队规范项，不覆盖个人 GitHub 账号、本地代码路径与个人偏好的 AI 模型**。
