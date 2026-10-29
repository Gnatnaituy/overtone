# 视觉风格 v6「棱镜 Prism」

> 状态：**已实施**（2026-10-29）。参考对象是 Primuse（猿音）的 macOS 界面：
> 浅色白卡 + 紫色强调 + 彩色侧栏图标 + 大标题 + 密集列表 + 半透明播放条；
> 深色下则是 Primuse 沉浸播放页那种「近黑底 + 封面取色霓虹」的质感。
>
> 本文件记录**取舍与令牌**，不重复 v3 / v4 的完整规范。

## 1. 一句话

**保留 Overtone 的布局与信息架构，只换材质、颜色、圆角与强调色**：
玻璃是「磨砂 + 光」，纸墨是「纸 + 细线」，棱镜是「白卡 + 大圆角 + 紫调」。
它复用玻璃的视图结构（`Theme.isPaper == false`），所以不需要为页面写第三套布局。

## 2. 与另外两套的差异

| 维度 | 玻璃 v3 | 纸墨 v4 | 棱镜 v6 |
|---|---|---|---|
| 表面 | 半透明材质 / `glassEffect` | 不透明纸面 | **纯白（深色：#151822）实底** |
| 层级 | 材质 + 投影 + 1px 玻璃描边 | 零投影 + 1px 墨线 | **柔和投影 + 1px 冷灰细线** |
| 圆角 | 4/6/10/14/20 | 2/3/3/4/6 | **6/8/12/16/22** |
| 强调色 | 原色 | 墨色 / 提亮 | **高饱和（紫 / 靛 / 青 / 玫红）** |
| 氛围层 | 四色 wash | 不渲染 | **紫罗兰 / 青 / 粉 wash（浅色约玻璃一半浓度，深色保留霓虹）** |
| 高光 | 顶部 1px 镜面 | 无 | 无 |
| 封面 | 圆角 10 | 直角 2 | 圆角 10 |

## 3. 令牌

`Theme.swift` 里新增 `PrismTokens`，与 `GlassTokens` 字段一一对应；
`StyleState` 三套同时构造，`state.active` 只换引用（令牌实例稳定，原因见 `AccentTokens`）。

### 3.1 表面 / 文字（浅色 / 深色）

| 令牌 | 浅色 | 深色 |
|---|---|---|
| `canvas` | `#F3F4FA` | `#0B0C12` |
| `surface` | `#FFFFFF` | `#151822` |
| `surfaceSunken` | `#ECEEF6` | `#1C202C` |
| `surfaceHover` | `#E7E9F4` | `#242936` |
| `borderSubtle` | `#E6E8F1` | `#262C3A` |
| `textPrimary` | `#11131B` | `#F4F6FB` |
| `textSecondary` | `#5A6072` | `#AAB2C4` |
| `textTertiary` | `#8A90A2` | `#7C859A` |
| `favorite` / `warning` / `danger` | `#EC4899` / `#B45309` / `#DC2626` | `#F472B6` / `#FBBF24` / `#F87171` |

### 3.2 强调色（`AccentRamp.forChoice(_:style: .prism)`）

| 选择 | 500 主色（浅） | 深色主色 | 备注 |
|---|---|---|---|
| 靛蓝（默认） | `#5B5BF0` | `#8A88FF` | 最接近 Primuse 的紫蓝 |
| 紫 | `#8B5CF6` | `#A78BFA` | 棱镜签名色 |
| 青 | `#06B6D4` | `#22D3EE` | 冷色变体 |
| 信号红 | `#F43F5E` | `#FB7185` | 暖色变体 |

染色浓度比玻璃高：`brandTint` 浅 12% / 深 22%，`surfaceSelected` 浅 14% / 深 24%。

### 3.3 材质

`glassPanel` / `glassControl` 在棱镜下**不调用任何 Material / glassEffect**：

- 面板：`surface` 实底 + `borderSubtle` 描边 + 更「浮」的柔和投影
  （e1 6/3 → e3 28/16，半径更大、透明度更低）；
- 控件：`thin` 档用 `surfaceSunken`（分段容器 / 输入框），其余用 `surface`；
- 无顶部镜面高光（那是玻璃的「厚度」语言）。

### 3.4 氛围层

`AmbientWash` 对玻璃与棱镜都渲染；棱镜的 wash 颜色由 `PrismTokens` 提供：
浅色是极淡的紫 / 青 / 粉（不抢白卡），深色保留更强的霓虹（接近 Primuse 沉浸页）。
纸墨仍然完全不渲染。

## 4. 页面接入规则

1. **默认什么都不用改**：页面读 `Theme.surface` / `textPrimary` / `Radius` / `brandGradient`
   即可自动跟随三套风格。
2. 需要「棱镜专属结构」时读 `Theme.isPrism`（例如将来做全出血封面播放页）；
   现有页面不需要，保持 `Theme.isPaper ? 纸墨 : 玻璃` 的两分支即可。
3. 新增颜色 / 圆角 / 投影一律进 `Theme`，不要在页面里写死。

## 5. 已知取舍

- 棱镜没有做 Primuse 的「播放页样式可配置 / 主题色跟随封面」；Overtone 的强调色仍是用户
  从四色里选，封面取色只作用于 Now Playing 的氛围层（与玻璃一致）。
- 浅色氛围比 Primuse 的近乎中性灰略有色偏（保留一点 Overtone 的「泛音」气质）；
  若想更接近 Primuse，可把 `PrismTokens.ambient*` 的浅色 alpha 再降一半。
- 深色主题的霓虹感依赖 OLED / 高对比屏；低亮度下若觉得发灰，优先调 `ambientIndigo` 的深色 alpha。
