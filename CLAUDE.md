# moonlight-ios（kiyor fork）

## 北极星
主人在 iPhone 上串流自己的 PC，阿西西安卓版里他用得到的痛点功能逐个落到 iOS。
判据：每个痛点在主人真机上串流实测好用，不以「跟安卓版一样」为准。

## 入口
- 上游 moonlight-stream/moonlight-ios（remote `upstream`），fork `kiyor/moonlight-ios`
- 参考实现：Axixi2233/moonlight-android（Java，clone 在 /tmp/mla，可重新 clone）
- 真机编译安装：`scripts/run-device.sh`（默认 iPhone19,3，`MODEL=` 可改；Bundle ID `me.kiyor.moonlight`，Team 取自 novel-reader-ios）
- 签名用命令行覆盖，不改 pbxproj，方便 rebase 上游

## 痛点清单
- ✅ 右侧侧边栏（边缘拉出）：虚拟手柄档位、键盘、Windows 组合键、断开连接
- 侧栏排版照阿西西 `dialog_game_menu.xml`：外侧常用键竖列 + 磁贴格子（点按开关、长按进二级页）+ 二级页（快捷键/性能/手柄/触控）；控件自绘（`MLOptionGroup`），不用系统 UISegmentedControl（4edba8f，待主人实测）
- 串流中调画质（分辨率/帧率/码率）：侧栏「画质」页，改 `streamConfig` 后停流+重建 StreamManager 重连，只改本次不改默认（c0b845b，待主人实测）
- 性能信息「详细」模式 9 项可单独开关，存在 NSUserDefaults `moonlight.statsItems`（da33ff2）

## 待主人真机实测（2026-10-16 夜间做完，只验过编译安装启动）
- 解码耗时（VT 自解码，fee4153 可切回「原版直出」）：画面/HDR/后台回来是否正常
- 画质页重连、回前台自动重连：比例、点触位置、手柄/浮层是否还在
- 虚拟鼠标按键、手柄当鼠标、自定义按键布局（编辑/拖动/删除/WASD 摇杆）

## 阿西西特色功能移植队列（按性价比排序，做完打 ✅）
| # | 功能 | 成本 | 备注 |
|---|---|---|---|
| ✅1 | 串流中开关性能信息（精简中文版） | 低 | iOS 已有统计，只缺开关和精简格式 |
| ✅2 | 串流中切换触控模式（触控板 / 直接点击） | 低-中 | 原版只能在设置里改，要重建 touchHandler |
| ✅3 | 自定义快捷组合键（增删、排序、持久化） | 中 | 在现有组合键面板上扩展 |
| ✅4 | 自定义虚拟按键布局（可拖拽的键鼠按钮、摇杆映射 WASD） | 中-高 | 748b28d；侧栏「自定义按键」，NSUserDefaults `moonlight.keyLayout`，位置按屏幕比例 |
| ✅5 | 虚拟鼠标（屏上左/中/右键 + 滚轮） | 中 | 742a47f；触控模式页开关 |
| ✅6 | 手柄键鼠模式（手柄摇杆当鼠标） | 中 | ca124c3；左摇杆光标、右摇杆滚轮、A/B/X 三键 |
| ✅7 | 后台回前台自动重连 | 中 | f6bf033；画质页开关，默认开 |
| ✅8 | 音频震动 | 中 | 18198a8；低通取低音电平驱动 UIImpactFeedback，手柄页开关，默认关 |
| 9 | 竖屏串流 + 竖屏快捷键栏 | 中 | |
| 10 | 外接显示器输出 | 中 | UIScene 外屏 |
| 11 | FSR 超分（Metal 移植 GLSL） | 高 | 渲染要从 AVSampleBufferDisplayLayer 改 Metal |
| 12 | 麦克风上行 | 高 | 依赖阿西西版 Sunshine 协议扩展 |
| 13 | SBS 3D / AR 眼镜 | 高 | 小众 |
| — | USB 手柄驱动 | 不做 | iOS GameController 原生支持 DS4/DS5/Pro |
