# obs-nvenc-legacy

让 **Maxwell / Pascal / Volta** 显卡（GTX 900/10xx、Quadro M/P 系列）在 **OBS Studio 33** 上重新用上 **NVIDIA NVENC** 硬件编码。

> 症状：OBS 日志出现 `[NVENC] Test process failed: outdated_driver`，编码器列表里没有「NVIDIA NVENC H.264 / HEVC」。

## 为什么会坏

| 组件 | 要求 |
|---|---|
| OBS 33 / ffmpeg 9 | 用 nv-codec-headers **13.1** 编译，运行时要求驱动 ≥ **610**（NVENC API 13.1） |
| GTX 10xx (Pascal) | **580xx 是 NVIDIA 为 Maxwell/Pascal/Volta 提供的最后一个驱动分支**，只提供 NVENC API **13.0** |
| 610+ 分支 | 已不再支持这些架构 |

于是「驱动没坏、显卡硬件编码好好的」，却因为编译期写死的版本号被门禁拦下，整个 `obs-nvenc.so` 初始化失败。

`ffmpeg` 侧同一问题可直接印证：

```
[h264_nvenc] Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0
[h264_nvenc] The minimum required Nvidia driver for nvenc is 610.00 or newer
```

## 这个项目做什么

**只重编 OBS 的 NVENC 插件**，用与本机驱动匹配的 nv-codec-headers（默认 SDK 13.0.19.1）编译出 `obs-nvenc.so` + `obs-nvenc-test`，覆盖发行版同名文件：

- 不动 OBS 本体、不动 NVIDIA 驱动、不需要降级 ffmpeg；
- 自动探测 OBS 版本（`pkg-config libobs`）与驱动支持的 NVENC API，选对应的 headers tag；
- 安装前自动备份发行版原件，附 `uninstall.sh` 一键还原；
- 安装 pacman 钩子，`obs-studio` 升级后自动把模块放回去，不会再次踩坑。

H.264 **和** HEVC（含 10-bit，取决于硬件）都会回来。

## 环境要求

- Arch / CachyOS 等使用 `/usr/lib/obs-modules/core/` 布局的发行版，OBS Studio 33.x
- 已安装 `obs-studio`（或 `obs-studio-browser`）、`gcc`、`git`、`pkg-config`、`libobs` 头文件（随 obs-studio 包提供）
- 驱动的 NVENC API 版本低于 OBS 编译时使用的版本（脚本会检测并提示）

## 用法

```bash
git clone https://github.com/Eefung/obs-nvenc-legacy.git
cd obs-nvenc-legacy
./build.sh            # 自动检测 → 编译 → 安装(会弹一次授权)
```

完成后重启 OBS，「设置 → 输出 → 编码器」里就能选 **NVIDIA NVENC H.264 / HEVC**。

常用选项：

```bash
./build.sh --force                 # 强制重新编译
./build.sh --no-hook               # 不安装 pacman 钩子
./build.sh --no-install            # 只编译, 产物留在缓存目录
./build.sh --api 13.0 --obs-version 33.0.1
./uninstall.sh [--purge]           # 还原发行版原件并清理
```

首次安装后脚本会把自己装到 `/usr/local/bin/obs-nvenc-legacy`，之后可直接：

```bash
obs-nvenc-legacy --rebuild         # OBS 升级后重新编译安装
```

## 安装位置

| 路径 | 内容 |
|---|---|
| `/usr/lib/obs-modules/core/obs-nvenc.so` | 重编的 NVENC 插件（被 OBS 加载） |
| `/usr/bin/obs-nvenc-test` | 自检程序（OBS 通过它探测 NVENC，必须与 obs 可执行文件同目录） |
| `/var/lib/obs-nvenc-legacy/backup/` | 发行版原件备份、`install.info` |
| `/usr/local/share/obs-nvenc-legacy/` | 构建产物副本，供 pacman 钩子恢复 |
| `/etc/pacman.d/hooks/99-obs-nvenc-legacy.hook` | OBS 升级后自动恢复 |
| `~/.cache/obs-nvenc-legacy/` | 源码与构建缓存 |

## 验证

```bash
# 1. 模块自检: 应输出 nvenc_supported=true 以及 h264/hevc codec_supported=1
/usr/bin/obs-nvenc-test | head -8

# 2. OBS 日志: 应出现 13.0 (compiled) / 13.0 (driver) 且列出 obs_nvenc_*_tex
grep -E "obs-nvenc|NVENC" ~/.config/obs-studio/logs/$(ls -t ~/.config/obs-studio/logs | head -1)
```

## 已验证环境

| 项目 | 版本 |
|---|---|
| 发行版 | CachyOS (Arch 系), KDE Wayland, kernel 7.3.3 |
| GPU | NVIDIA GeForce GTX 1060 6GB (GP106, Pascal) |
| 驱动 | nvidia-580xx 580.196.07（NVENC API 13.0） |
| OBS | obs-studio-browser 33.0.1 |
| 结果 | NVENC H.264 / HEVC 编码器恢复，实际录制 720p30 H.264 与 HEVC 均成功出片 |

## 注意事项

- **OBS 日志里的 `Not running on NVIDIA GPU, falling back to non-texture encoder` 是正常现象**：OBS 用核显渲染（PRIME offload），NVENC 走 CUDA 拷贝路径，依然是硬件编码，只是多一次显存拷贝。想让编码走零拷贝纹理路径，可让 OBS 在 NVIDIA 上渲染（`__NV_PRIME_RENDER_OFFLOAD=1`）。
- **本项目只修 OBS**。系统里的 ffmpeg 9 `h264_nvenc` 仍然是坏的（影响 GPU Screen Recorder、部分转码工具），修法不同（需要给 ffmpeg 打 runtime API version 补丁），不在本项目范围内。
- 逆操作：`./uninstall.sh`；若备份丢了，`pacman -S obs-studio` 重装包即可还原。
- 这是给「厂商已停止支持的老卡」补齐最后一环的权宜方案，不是上游认可的分发方式；在 OBS 35（预计 Pascal 支持彻底移除）上可能不再适用。

## 许可

MIT，见 [LICENSE](LICENSE)。
