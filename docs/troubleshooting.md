# 排错

## 1. 安装后 OBS 里还是没有 NVIDIA 编码器

按顺序检查：

```bash
# 模块是否真的被换掉了(时间戳应是刚才)
ls -la /usr/lib/obs-modules/core/obs-nvenc.so /usr/bin/obs-nvenc-test

# 自检: 必须 nvenc_supported=true
/usr/bin/obs-nvenc-test | head -8

# 驱动与 NVENC 版本
nvidia-smi --query-gpu=name,driver_version --format=csv
```

若自检里 `reason=` 不是空，对应关系：

| reason | 含义 | 处理 |
|---|---|---|
| `outdated_driver` | 编译用的 API 版本高于驱动支持 | 用 `--api <驱动版本>` 重编 |
| `no_supported_devices` | 显卡本身不支持 NVENC（如 GT 1030、GTX 1050 3GB 等） | 无解，用核显 QSV/VAAPI |
| `session_limit` | 驱动被破解会话数限制 / 多个程序同时占用 | 关掉其它占用 NVENC 的程序 |
| `no_cuda_version` / `no_devices` | 驱动没加载 | 重启，`nvidia-smi` 确认 |

## 2. 只有 H.264，没有 HEVC

说明编译时没开 `-DENABLE_HEVC`（本项目已默认开启）。自己改过编译命令的话补上该宏；再确认显卡本身支持 HEVC 编码（Maxwell 二代之后基本都支持）。

```bash
strings /usr/lib/obs-modules/core/obs-nvenc.so | grep obs_nvenc_
# 期望看到 obs_nvenc_h264_tex 和 obs_nvenc_hevc_tex
```

## 3. `Not running on NVIDIA GPU, falling back to non-texture encoder`

不是错误。OBS 在核显上渲染（PRIME offload 笔记本/台式混显），NVENC 只能用 CUDA 拷贝路径。

想让编码走零拷贝（纹理直通）：

```bash
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia obs
```

或把显示器直接接在 NVIDIA 输出上。代价是 OBS 渲染也跑在独显。

## 4. `pacman -Syu` 升级 OBS 之后又坏了

钩子没装上或被覆盖：

```bash
cat /etc/pacman.d/hooks/99-obs-nvenc-legacy.hook
/usr/local/bin/obs-nvenc-legacy-reinstall   # 手动恢复一次(需 root)
```

若 OBS 大版本升级（例如 33 → 34）导致 ABI 变化，需要重新编译：

```bash
obs-nvenc-legacy --rebuild
```

## 5. ffmpeg 的 `h264_nvenc` 还是失败

本项目只替换 OBS 的插件，**不影响系统 ffmpeg**。ffmpeg 9 同样编译于 13.1 头文件，需要另一条路：

- 降级 ffmpeg（`downgrade ffmpeg` 到 8.x），或
- 用打了 runtime API version 补丁的 ffmpeg 构建（gpu-screen-recorder 使用的做法）。

判断命令：

```bash
ffmpeg -hide_banner -f lavfi -i testsrc=size=320x240:rate=30 -t 1 -c:v h264_nvenc -f null -
```

## 6. 想彻底回到发行版状态

```bash
./uninstall.sh
# 若备份丢失:
sudo pacman -S obs-studio-browser   # 或 obs-studio
```
