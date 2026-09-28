# keycount — 桌面宠物 + 每日键盘计数

一只住在桌面上的宠物，顺便把你「今天敲了多少下键盘、分别是哪些键、现在打多快」表演出来。
本地存储，不外传，**只存计数不存内容**。

形态演进过两次：最初想做命令行 daemon → 改成桌宠 → 技术栈定为 **原生 Godot 4.7.2 + 自写 GDExtension**。
所有决策依据和实测数据都在 [`SPEC.md`](SPEC.md)，那份文件比这份 README 详细。

## 现状（v0：链路已跑通并验证）

| 能力 | 状态 |
|---|---|
| 透明 / 置顶 / 无边框窗口浮在桌面 | ✅ 实测截图 `shots/crop-final.png` |
| 全局键盘钩子（**非焦点**也能抓） | ✅ `dropped=0` |
| 键名归一化（`Shift+A` → `a`） | ✅ 自检 25/25 |
| **不抢键盘焦点** | ✅ `focus_true_frames=0`、`input_keys=0`，`hwndFocus` 始终是别的窗口 |
| 宠物状态机（idle / typing / excited / sleepy） | ✅ 由实时 KPM 驱动 |
| 统计落盘 | ❌ **只在内存，关掉就丢** |
| 点击穿透 | ❌ 扩展里写好了，宠物还没调用 |
| 真素材 / 动画 | ❌ 现在是个占位圆 |
| 托盘图标 / 开机自启 / 中文字体 | ❌ 都没有 |

## 结构

```
native/          平台核心，不依赖 Godot（钩子 + 键名归一化）
  kc_hook.h/.cpp   全局钩子：自己的线程 + 自己的消息循环
  test_hook.cpp    独立验证工具（--selftest / 实机抓键）
gdext/           GDExtension 接线层
  src/kc_gdext.h/.cpp   KeyCountHook / KeyCountWindow
  SConstruct            构建脚本
  api/                  从本机 Godot dump 出来的 extension_api.json
pet/             Godot 工程
  project.godot         透明置顶 + no_focus + gl_compatibility
  pet.gd                占位宠物 + 状态机
  addons/keycount/      扩展的 .gdextension + 编好的 dll
evidence/        验证工具（可重跑）
  run-pet.ps1           **启动器 —— 必须用它启动宠物**
  inject3.ps1           往自测窗口注入按键，验证全局抓键
  fg2.ps1               查「键盘到底在谁手上」（GetGUIThreadInfo）
  screenshot.ps1/crop2.ps1  截图与裁剪
spike-godot/     Godot 透明窗口实测工程（Vulkan 黑方块 vs OpenGL 正常的原始证据）
SPEC.md          全部实测结论与踩坑记录
```

## 环境要求

- **Godot 4.7.2**（GDExtension 的 `api_version` 与 `compatibility_minimum` 都对准它）
- **scons** + **MSVC**（VS 2022 或 Build Tools）—— 编扩展用
- **MinGW g++**（可选）—— 只用来编 `native/` 的独立验证 exe
- `godot-cpp`（构建时自动需要，见下）

## 构建

```bash
# 1) godot-cpp：版本必须与 Godot 对齐
cd gdext
git clone --depth 1 https://github.com/godotengine/godot-cpp.git

# 2) 编扩展
scons platform=windows target=template_debug   api_version=4.7 -j12
scons platform=windows target=template_release api_version=4.7 -j12
cp bin/*.dll ../pet/addons/keycount/bin/

# 3) （可选）平台核心的独立验证
cd ../native
g++ -std=c++17 -O2 -Wall -Wextra -static -static-libgcc -static-libstdc++ \
    -o test_hook.exe kc_hook.cpp test_hook.cpp -luser32
./test_hook.exe --selftest    # 25 条键名断言
```

## 运行

```powershell
# 先过一次导入，否则 GDExtension 不会被加载
godot --headless --editor --quit --path pet

# 必须用启动器 —— 它会记录「宠物出现之前谁持有键盘」，传给宠物用来把焦点还回去
powershell -File evidence/run-pet.ps1
```

**为什么不能直接双击跑**：Godot 在 GDExtension 初始化**之前**就创建并激活了主窗口，
所以在扩展内部永远看不到「原来谁持有键盘」。只有启动器能在拉起宠物前那一瞬记下它。
少了这一步，宠物启动后会攥着 `hwndFocus`，你随手打的字会落进宠物里。
详见 `SPEC.md` 的「抢焦点这件事打了三仗」。

## 两条容易踩的坑

1. **渲染器必须是 `gl_compatibility`。** 本机实测 Vulkan/Forward+ 下透明窗口会渲染成**纯黑方块**，
   把桌面整个遮住（RTX 4060 Laptop + Win11 26200 + 驱动 566.36 复现）。
2. **Godot 默认字体不含中文字形。** 所以占位宠物上写的是 ASCII 文字；
   要显示中文得自带字体（Noto Sans SC 之类，做子集更小）。

## 已验证的环境

Windows 11 build 26200 · RTX 4060 Laptop · 驱动 566.36 · Godot 4.7.2.stable.steam · MSVC/VS 2022 · scons 4.8.1
