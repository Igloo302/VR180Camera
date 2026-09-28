# VR180 Camera (macOS)

原生 macOS 平台的 VR180 3D 双目相机桌面客户端应用（全面兼容 Lenovo Mirage Camera 及采用 Google Daydream VR180 协议的相机设备）。

---

## 核心特性

- **蓝牙低功耗 (BLE) 自动握手与重连**
  - 基于 CoreBluetooth 自动扫描相机并建立连接。
  - 实现 ECDH P-256 密钥协商、HKDF 密钥派生、AES-GCM 加密信道与实体按键物理确认。
  - 配对密钥持久化存入 macOS Keychain，下次启动自动完成静默重连，无需重复按键配对。

- **P2P WebRTC 实时双目取景流 (Live Viewfinder)**
  - 基于官方 Daydream Camera 原生协议，通过 Wi-Fi 建立点对点 WebRTC 双目实时视频通道。
  - 采用 Metal (`RTCMTLNSVideoView`) 硬件加速渲染，毫秒级超低延迟实时取景。
  - 自动管理 SDP 协商、ICE 候选网络打通与会话保活。

- **iOS 风格高保真相机控制界面**
  - **沉浸式取景窗**：双眼 VR180 对齐十字准星、动态闪光动画、录像中呼吸红点及计时器。
  - **模式切换**：视频 (Video)、照片 (Photo)、直播 (Live) 一键平滑切换。
  - **状态徽标**：实时电量指示、SD 卡剩余容量、Wi-Fi/BLE 连接状态显示。
  - **快门遥控**：支持白圈拍照快门、红圈录像快门动态形变动画。

- **Wi-Fi 热点与媒体管理**
  - 远程读取相机内置 Wi-Fi 热点 SSID/密码，并支持一键通过 macOS 系统服务接入相机热点。
  - 基于分帧协议的媒体分页列表拉取，防止一次性拉取过多媒体导致卡顿。
  - 支持单张缩略图预览按需下载与原片高速 HTTPS P2P 下载保存至 Mac 本地。

---

## 项目结构

```text
VR180Camera/
├── Package.swift               # Swift Package 配置文件 (支持 Swift 6 / 5 语言模式)
├── README.md                   # 项目使用与架构说明
├── VALIDATION.md               # Lenovo Mirage 实机通讯校验报告
├── Scripts/
│   └── build_app.sh            # 一键编译与生成 macOS App Bundle 脚本
├── Sources/
│   ├── VR180Protocol/          # 底层通信协议库
│   │   └── Protocol.swift      # Protobuf 编解码、ECDH/HKDF/HMAC 加密及请求体构建
│   └── VR180Camera/            # macOS 应用程序源码
│       ├── App.swift           # 主窗口与操作面板
│       ├── CameraManager.swift # 蓝牙、Wi-Fi、媒体控制核心逻辑
│       ├── CameraViewfinderSheet.swift # iOS 风格取景器视图
│       ├── WebRtcViewfinderManager.swift # WebRTC P2P 引擎与视频渲染
│       └── PairingStore.swift  # Keychain 配对密钥管理
└── VR180Camera.app/            # 预编译生成的独立 macOS 应用程序
```

---

## 快速构建与运行

### 方式一：直接运行预编译 App
直接双击根目录下的 `VR180Camera.app` 即可启动。

### 方式二：一键脚本重新打包
```bash
./Scripts/build_app.sh
```
脚本将自动拉取依赖（`WebRTC.xcframework`）、执行 Release 模式编译、拷贝嵌入式 Frameworks、配置 `@executable_path` 并完成本地代码签名。

### 方式三：命令行开发调试
```bash
swift run VR180Camera
```

---

## 常见问题与操作指引

1. **首次配对**：
   - 相机在关机状态下，长按拍照键直至指示灯蓝绿交替闪烁进入配对模式。
   - 打开本程序，找到相机并点击连接；当界面提示“步骤 2/3: 请短按相机快门”时，在相机本体上短按一次快门键完成确认。
   - 完成后密钥将自动保存到 Keychain，后续直接开机即可秒连。
2. **启动实时取景**：
   - 确保 Mac 已连接到相机的 Wi-Fi（如 `DIRECT-xx-VR180-xxx`）。
   - 在程序中点击“进入实时相机取景模式”，窗口打开时将自动与相机协商建立 WebRTC 双目实时流。
