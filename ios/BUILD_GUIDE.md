# iOS 打包指南

## 方式一：GitHub Actions 自动打包（推荐，无需 Mac）

### 1. 推送代码到 GitHub

```bash
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/yourusername/remote_control_app.git
git push -u origin main
```

### 2. 触发构建

- 每次推送代码到 `main` 分支会自动触发构建
- 或手动触发：GitHub 仓库 -> Actions -> Build iOS IPA -> Run workflow

### 3. 下载 IPA

- 构建完成后，在 Actions 页面点击最新运行记录
- 找到 Artifacts 部分，下载 `ios-release-ipa`

---

## 方式二：本地 Mac 打包

### 前提条件

- macOS 电脑
- Xcode 15.0+
- Flutter SDK
- CocoaPods

### 步骤

```bash
# 1. 安装依赖
flutter pub get

# 2. 进入 iOS 目录
cd ios

# 3. 安装 CocoaPods 依赖
pod install --repo-update

# 4. 返回项目根目录
cd ..

# 5. 构建 Release 版本
flutter build ios --release

# 6. 创建 IPA
cd build/ios/iphoneos
mkdir -p Payload
cp -r Runner.app Payload/
zip -r app.ipa Payload
```

---

## 方式三：使用 Codemagic 云服务打包

Codemagic 提供每月 500 分钟免费构建时间，支持 Flutter iOS 打包。

### 1. 注册 Codemagic

访问 https://codemagic.io/ 用 GitHub 账号登录

### 2. 配置构建

```yaml
# codemagic.yaml
workflows:
  ios-workflow:
    name: iOS Workflow
    instance_type: mac_mini_m1
    max_build_duration: 60
    environment:
      flutter: stable
      xcode: latest
      cocoapods: default
    scripts:
      - name: Get Flutter packages
        script: flutter packages pub get
      - name: Install pods
        script: find . -name "Podfile" -execdir pod install \;
      - name: Build IPA
        script: flutter build ios --release --no-codesign
    artifacts:
      - build/ios/iphoneos/*.ipa
```

### 3. 触发构建

连接 GitHub 仓库后，每次推送会自动触发构建。

---

## 安装 IPA 到 iPhone

### 方法一：AltStore（免费，推荐）

1. 在电脑上下载 [AltServer](https://altstore.io/)
2. 用数据线连接 iPhone 到电脑
3. 安装 AltStore 到 iPhone
4. 在 iPhone 上打开 AltStore
5. 点击 "+" 号，选择下载的 IPA 文件
6. 输入 Apple ID 密码（仅用于签名）

**注意**：每 7 天需要重新签名，AltStore 可以自动续签

### 方法二：Sideloadly（免费）

1. 下载 [Sideloadly](https://sideloadly.io/)
2. 连接 iPhone 到电脑
3. 拖拽 IPA 文件到 Sideloadly
4. 输入 Apple ID
5. 点击 Start 安装

### 方法三：TestFlight（需要 Apple Developer，$99/年）

1. 注册 [Apple Developer Program](https://developer.apple.com/programs/)
2. 在 App Store Connect 创建应用
3. 上传 IPA 到 TestFlight
4. 邀请测试人员

### 方法四：App Store（正式发布）

1. 注册 Apple Developer Program（$99/年）
2. 准备应用截图、描述等
3. 使用 Xcode 或 Transporter 上传
4. 等待 Apple 审核（通常 1-3 天）

---

## 常见问题

### Q: 没有 Apple Developer 账号怎么办？
A: 使用 AltStore 或 Sideloadly，完全免费，不需要开发者账号。

### Q: 7 天续签太麻烦？
A: 可以购买 Apple Developer 账号（$99/年），或使用 TestFlight 分发。

### Q: 构建失败 "No signing certificate"？
A: 这是正常的，使用 `--no-codesign` 参数构建后，安装工具会自动签名。

### Q: 应用闪退？
A: 检查 Info.plist 中的权限声明是否完整，特别是摄像头和麦克风权限。
