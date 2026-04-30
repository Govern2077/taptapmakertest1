# 开发踩坑记录：球球培养 UI

> 本文档整理了球球培养（CultivationPage）及相关 UI 开发中遇到的两类核心问题：
> **内存溢出（OOM）** 和 **按钮显示异常**，详细记录原因、解决方法和代码逻辑。

---

## 问题一：OOM（内存溢出）

### 1.1 NanoVG 上下文未释放导致内存累积

**现象**：在菜单页 ↔ 游戏页 ↔ 培养页之间反复切换后，内存持续增长，最终 OOM 崩溃。

**根因**：NanoVG 上下文（`nvgCreate`）会分配 GPU 显存和内部缓冲区。如果在页面切换时不销毁，每次进入新页面时创建新上下文，旧的上下文持续占用显存。

**代码位置**：`scripts/network/Standalone.lua`

**错误写法**（每次进入游戏页都创建，但从不销毁）：

```lua
function StartGame()
    vg_ = nvgCreate(1)  -- ❌ 如果之前的 vg_ 没有 nvgDelete，显存泄漏
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/MiSans-Regular.ttf")
end
```

**正确写法**（菜单页销毁、游戏页按需创建）：

```lua
function ShowMenu()
    gamePhase_ = "menu"
    -- ✅ 返回菜单时销毁 NanoVG，释放显存
    if vg_ then
        nvgDelete(vg_)
        vg_ = nil
        fontNormal_ = -1
    end
    EnsureUIInit()
    StartPage.Show({ ... })
end

function StartGame()
    -- ✅ 按需创建，不会重复创建
    if not vg_ then
        SetupNanoVG()
    end
end
```

**关键原则**：

| 操作 | 说明 |
|------|------|
| `nvgCreate()` | 分配 GPU 资源，**必须**有对应的 `nvgDelete()` |
| `nvgDelete()` | 释放 GPU 资源，之后 `vg_` 必须置 nil |
| `nvgCreateFont()` | 加载字体到显存，**只调用一次**，句柄可复用。每帧调用会显存泄漏 |
| 页面切换 | 如果新页面不用 NanoVG（如纯 UI 页面），应先 `nvgDelete` 释放 |

---

### 1.2 UI 组件树重建未清理旧实例

**现象**：反复进出培养页（菜单 → 培养 → 返回 → 培养 → …），内存持续增长。

**根因**：`CultivationPage.Show()` 每次调用都会创建全新的 UI 组件树（DragDropContext、ItemSlot、Panel 等），通过 `UI.SetRoot()` 替换根节点。但旧的组件树中的对象（尤其是 DragDropContext 内部维护的 `dropTargets_` 列表）可能仍被引用，无法被 GC 回收。

**代码位置**：`scripts/ui/CultivationPage.lua`

**问题代码逻辑**：

```lua
function CultivationPage.Show(data, callbacks)
    equipSlots_ = {}  -- 旧的 equipSlots_ 引用被丢弃
    
    -- 每次都新建 DragDropContext
    dragCtx_ = DragDropContext { ... }
    
    -- 每次都新建所有 ItemSlot
    for _, def in ipairs(TIER_DEFS) do
        table.insert(tierRows, buildTierRow(def, dragCtx_))
        -- buildTierRow 内部又创建 N 个 ItemSlot
        -- 每个 ItemSlot 会调用 dragContext:RegisterDropTarget(self)
    end
    
    -- UI.SetRoot 替换根节点，但旧的 dragCtx_ 内部的
    -- dropTargets_ 列表仍然持有旧 ItemSlot 的引用
    UI.SetRoot(root)
end
```

**内存泄漏链路**：

```
第1次 Show():
  dragCtx_A.dropTargets_ = [slot1, slot2, slot3, ...]

第2次 Show():
  dragCtx_B.dropTargets_ = [slot4, slot5, slot6, ...]
  -- dragCtx_A 被 dragCtx_ 变量覆盖，但如果有其他引用则不会 GC
  -- 旧 root 被 SetRoot 替换，但 Lua GC 未必立即回收
```

**解决方法**：在 `Show()` 开头重置状态时，将旧引用显式清空，帮助 GC：

```lua
function CultivationPage.Show(data, callbacks)
    -- ✅ 显式清空旧引用，辅助 GC
    if dragCtx_ then
        dragCtx_ = nil
    end
    equipSlots_ = {}
    ballPreview_ = nil
    colorLabel_ = nil
    
    -- ... 重新创建 ...
end
```

**更彻底的方案**：如果需要频繁切换页面，可以只创建一次组件树，后续用 `SetItem()` / `SetStyle()` 更新数据，避免重建。

---

### 1.3 nvgCreateFont 每帧调用导致显存泄漏

**现象**：游戏运行一段时间后显存耗尽，NanoVG 渲染变慢或崩溃。

**根因**：`nvgCreateFont()` 每次调用都会将字体文件加载到 GPU 显存。如果放在渲染循环中，每帧都加载一次字体，显存线性增长。

**错误写法**：

```lua
function HandleNanoVGRender(eventType, eventData)
    nvgBeginFrame(vg, w, h, 1.0)
    nvgCreateFont(vg, "sans", "Fonts/MiSans-Regular.ttf")  -- ❌ 每帧加载！
    nvgFontFace(vg, "sans")
    nvgText(vg, 100, 100, "Hello")
    nvgEndFrame(vg)
end
```

**正确写法**：

```lua
-- ✅ 初始化时只创建一次
function SetupNanoVG()
    vg_ = nvgCreate(1)
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/MiSans-Regular.ttf")
end

-- 渲染时只引用字体名
function HandleNanoVGRender(eventType, eventData)
    nvgBeginFrame(vg_, w, h, 1.0)
    nvgFontFace(vg_, "sans")     -- ✅ 引用已创建的字体名
    nvgFontSize(vg_, 24)
    nvgText(vg_, 100, 100, "Hello")
    nvgEndFrame(vg_)
end
```

---

## 问题二：按钮显示异常

### 2.1 Button.props.variant 直接赋值不生效

**现象**：游戏中点击"AI 代理"按钮，文本正确切换为"手动射击"，但按钮颜色/样式没有变化，始终保持初始外观。

**根因**：UrhoX UI 的 Button 组件没有 `SetVariant()` 方法。直接修改 `self.props.variant` 只改变了 Lua table 中的值，**不会触发组件的重新渲染**。Button 的视觉样式（背景色、边框等）在 `Render()` 中根据 `props.variant` 计算，但 Render 需要 Widget 标记为"脏"才会重新执行。

**代码位置**：`scripts/network/Standalone.lua:238`

**Button 组件可用的更新方法**（`urhox-libs/UI/Widgets/Button.lua`）：

| 方法 | 作用 | 触发重渲染？ |
|------|------|-------------|
| `SetText(text)` | 更新按钮文本 | ✅ 是 |
| `SetStyle(styleTable)` | 更新任意样式属性 | ✅ 是 |
| `SetDisabled(bool)` | 更新禁用状态 | ✅ 是 |
| `self.props.xxx = yyy` | 直接改 props | ❌ **不触发重渲染** |

**错误写法**：

```lua
onClick = function(self)
    isAIProxy_ = not isAIProxy_
    self:SetText(isAIProxy_ and "手动射击" or "AI 代理")       -- ✅ 文本更新了
    self.props.variant = isAIProxy_ and "outline" or "primary"  -- ❌ 样式没更新！
end
```

**正确写法**：

```lua
onClick = function(self)
    isAIProxy_ = not isAIProxy_
    self:SetText(isAIProxy_ and "手动射击" or "AI 代理")
    -- ✅ 用 SetStyle 触发重渲染
    self:SetStyle({
        variant = isAIProxy_ and "outline" or "primary",
    })
end
```

**本质原因解析**（Button.lua 渲染流程）：

```
用户点击
  ↓
onClick 回调
  ↓
self.props.variant = "outline"   ← 只改了 Lua table，没通知渲染系统
  ↓
下一帧 Render() → 检查 isDirty_ → false → 跳过重绘
  ↓
按钮外观不变 ❌

── 对比 ──

self:SetStyle({ variant = "outline" })
  ↓
Widget:SetStyle() → 更新 props + 标记 isDirty_ = true
  ↓
下一帧 Render() → 检查 isDirty_ → true → 重新计算样式 → 按钮外观更新 ✅
```

---

### 2.2 ItemSlot 装备槽：dragContext 拦截 onSlotClick

**现象**：装备槽（equip slot）中已有技能时，点击该槽位想卸下技能，但点击无反应。技能无法通过点击卸下，只有新的拖拽才能替换。

**根因**：当 ItemSlot 同时设置了 `dragContext` 和 `item` 时，`OnPointerDown` 会立即启动拖拽并返回 `true`（捕获指针），导致后续的 `OnClick` → `onSlotClick` 永远不会触发。

**代码位置**：`urhox-libs/UI/Components/ItemSlot.lua:206`

**ItemSlot 事件处理链**：

```
用户点击装备槽（有 dragContext + 有 item）
  ↓
OnPointerDown()
  ↓
检查: item ~= nil AND dragCtx ~= nil → 都满足
  ↓
dragCtx:StartDrag(item, self, ...) → 启动拖拽
return true → 捕获指针 ← ⚠️ 指针被捕获
  ↓
OnPointerUp() → dragCtx:EndDrag()  → 拖拽结束（没有目标，取消）
  ↓
OnClick() → 永远不会执行！❌ onSlotClick 无法触发

── 对比 ──

无 dragContext 的装备槽
  ↓
OnPointerDown() → item ~= nil BUT dragCtx == nil → 不启动拖拽，不捕获
  ↓
OnPointerUp() → 正常
  ↓
OnClick() → 触发 onSlotClick ✅
```

**错误写法**（equip slot 同时传了 dragContext）：

```lua
local equipSlot = ItemSlot {
    slotId       = "equip_" .. def.tier,
    slotCategory = "equipment",
    slotType     = def.tier,
    size         = SLOT_SIZE,
    item         = nil,
    dragContext  = dragContext,  -- ❌ 有 dragContext = 有 item 时点击触发拖拽
    onSlotClick  = function(slot, item)
        -- ❌ 当 item 存在时，这个回调永远不会被调用！
        if item then
            currentData_.skills[def.tier] = nil
            updateEquipSlots()
        end
    end,
}
```

**正确写法**（equip slot 不传 dragContext，手动注册 drop target）：

```lua
local equipSlot = ItemSlot {
    slotId       = "equip_" .. def.tier,
    slotCategory = "equipment",
    slotType     = def.tier,
    size         = SLOT_SIZE,
    item         = nil,
    -- ✅ 故意不传 dragContext → OnPointerDown 不会启动拖拽
    borderRadius = 8,
    onSlotClick  = function(slot, item)
        -- ✅ 现在点击可以正常触发
        if item then
            currentData_.skills[def.tier] = nil
            updateEquipSlots()
        end
    end,
}
-- ✅ 手动注册为 drop target，使 FindDropTargetAt 能找到它
dragContext:RegisterDropTarget(equipSlot)
```

**交互效果对比**：

| 操作 | 错误写法（传 dragContext） | 正确写法（不传 + 手动注册） |
|------|--------------------------|--------------------------|
| 拖技能到装备槽 | ✅ 可拖入 | ✅ 可拖入 |
| 点击装备槽卸下 | ❌ 无反应（启动了无意义拖拽） | ✅ 点击卸下 |
| 从装备槽拖出 | 启动拖拽（无意义） | 不可拖出（符合预期） |

**取舍说明**：不传 dragContext 的代价是装备槽在拖拽悬停时**不会显示绿色/红色边框反馈**（因为 OnPointerEnter 中的高亮代码检查 `self.props.dragContext`）。这是可接受的视觉妥协——功能正确性优先于悬停反馈。

---

### 2.3 Button 选中态的"按下"视觉效果

**现象**：技能按钮、Tab 按钮被选中后，外观与未选中状态相同，用户无法区分当前选中了哪个。

**根因**：UrhoX Button 组件的 `variant` 只控制默认主题色（primary/outline/danger 等），没有内置的"选中态"样式。需要手动通过 `SetStyle` 叠加视觉效果。

**解决方法**：创建 `applySelectedStyle` 函数，通过改变背景色、添加边框、偏移 margin 模拟"按下"效果。

```lua
--- 保存按钮原始 margin 值（只保存一次）
local function storeOrigMargins(btn)
    if btn._origMarginTop == nil then
        btn._origMarginTop    = btn.props.marginTop or 0
        btn._origMarginBottom = btn.props.marginBottom or 6
    end
end

--- 应用/移除选中态样式
local function applySelectedStyle(btn, selected)
    storeOrigMargins(btn)
    if selected then
        -- 选中态：深色背景 + 内边框 + 向下偏移 2px 模拟按下
        btn:SetStyle({
            variant         = "primary",
            backgroundColor = { 60, 90, 200, 255 },
            borderWidth     = 2,
            borderColor     = { 30, 50, 140, 255 },
            marginTop       = btn._origMarginTop + 2,
            marginBottom    = math.max(0, btn._origMarginBottom - 2),
        })
    else
        -- 未选中态：恢复 outline 默认样式
        btn:SetStyle({
            variant         = "outline",
            backgroundColor = nil,  -- 清除自定义背景，回退到主题色
            borderWidth     = nil,
            borderColor     = nil,
            marginTop       = btn._origMarginTop,
            marginBottom    = btn._origMarginBottom,
        })
    end
end
```

**视觉效果**：

```
未选中 (outline):          选中 (pressed):
┌──────────┐              ┌──────────┐  ← marginTop + 2
│  技能名  │              │▓▓技能名▓▓│  ← 深蓝背景 + 边框
└──────────┘              └──────────┘  ← marginBottom - 2
      ↕ 6px                    ↕ 4px    (总高度不变，视觉下沉)
```

**使用示例**（在按钮组中单选）：

```lua
local buttons = {}

for i, option in ipairs(options) do
    local btn = UI.Button {
        text = option.name,
        variant = "outline",
        marginBottom = 6,
        onClick = function(self)
            -- 取消所有按钮的选中态
            for _, b in ipairs(buttons) do
                applySelectedStyle(b, false)
            end
            -- 选中当前
            applySelectedStyle(self, true)
            selectedIndex = i
        end,
    }
    table.insert(buttons, btn)
end
```

---

## 总结：核心规则速查

| 类别 | 规则 | 违反后果 |
|------|------|---------|
| NanoVG 内存 | `nvgCreate` 必须配对 `nvgDelete` | 显存泄漏 → OOM |
| NanoVG 字体 | `nvgCreateFont` 只在初始化调用一次 | 每帧调用 → 显存线性增长 → OOM |
| UI 页面切换 | 切换页面时清空旧 UI 引用 | 旧组件无法 GC → 内存累积 |
| Button 样式更新 | 用 `SetStyle()` 而非直接改 `props` | 样式不刷新，按钮外观不变 |
| ItemSlot 点击 | 需要点击回调的槽位不要传 `dragContext` | `onSlotClick` 永远不触发 |
| ItemSlot drop target | 不传 dragContext 时需手动 `RegisterDropTarget()` | 拖拽放不进去 |
| Button 选中态 | 没有内置选中态，需手动用 `SetStyle` 实现 | 用户无法区分选中项 |
