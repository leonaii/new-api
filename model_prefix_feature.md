# 模型前缀（Model Prefix）功能实现文档

> **文档状态**: ✅ 已实现  
> **最后更新**: 2026-01-05  
> **实现版本**: 当前版本

## 目录
- [功能概述](#功能概述)
- [实现状态](#实现状态)
- [数据库设计](#数据库设计)
- [核心实现](#核心实现)
  - [数据模型层](#数据模型层)
  - [能力表（Abilities）处理](#能力表abilities处理)
  - [缓存层处理](#缓存层处理)
  - [请求分发层](#请求分发层)
- [前端实现](#前端实现)
- [使用场景](#使用场景)
- [数据流图](#数据流图)
- [实现要点](#实现要点)
- [测试建议](#测试建议)
- [相关文件清单](#相关文件清单)

---

## 功能概述

`model_prefix` 是渠道（Channel）的一个可选配置字段，用于为渠道的所有模型名称添加统一前缀。该功能主要解决以下问题：

1. **区分同名模型**：当多个渠道提供相同模型时，通过前缀区分来源
2. **模型命名空间**：为不同供应商的模型创建命名空间（如 `openai/gpt-4`、`azure/gpt-4`）
3. **灵活路由**：用户可以通过指定带前缀的模型名来选择特定渠道

---

## 实现状态

| 模块 | 状态 | 说明 |
|------|------|------|
| 数据库字段 | ✅ 已实现 | `channels.model_prefix` VARCHAR(64) |
| Channel 模型 | ✅ 已实现 | `ModelPrefix *string` 字段和 `GetModelPrefix()` 方法 |
| Ability 处理 | ✅ 已实现 | `AddAbilities()` 和 `UpdateAbilities()` 支持前缀 |
| 缓存层 | ✅ 已实现 | `InitChannelCache()` 支持带前缀的模型名缓存 |
| 请求分发 | ✅ 已实现 | `SetupContextForSelectedChannel()` 处理前缀移除 |
| 上下文键 | ✅ 已实现 | `ContextKeyChannelModelPrefix` 和 `ContextKeyUpstreamModelName` |
| 标签批量编辑 | ✅ 已实现 | `EditTagChannels()` API 支持批量更新前缀 |
| 前端单渠道编辑 | ✅ 已实现 | `EditChannelModal.jsx` 包含 `model_prefix` 字段 |
| 前端标签编辑 | ✅ 已实现 | `EditTagModal.jsx` 支持批量设置前缀 |

---

## 数据库设计

### channels 表

```sql
-- model_prefix 字段定义
model_prefix VARCHAR(64) COMMENT '模型前缀'
```

**字段说明**：
| 字段名 | 类型 | 说明 |
|--------|------|------|
| model_prefix | VARCHAR(64) | 模型前缀，可选字段，存储如 `openai/`、`my-prefix-` 等前缀字符串 |

### abilities 表

abilities 表存储渠道的模型能力映射，当渠道设置了 `model_prefix` 时，存储的模型名会自动添加前缀：

```sql
-- abilities 表结构
CREATE TABLE abilities (
    `group` VARCHAR(64) NOT NULL,      -- 用户分组
    model VARCHAR(255) NOT NULL,        -- 模型名（包含前缀）
    channel_id INT NOT NULL,            -- 渠道ID
    enabled BOOLEAN,                    -- 是否启用
    priority BIGINT DEFAULT 0,          -- 优先级
    weight INT DEFAULT 0,               -- 权重
    tag VARCHAR(255),                   -- 标签
    PRIMARY KEY (`group`, model, channel_id)
);
```

---

## 核心实现

### 数据模型层

**文件**: [`model/channel.go`](model/channel.go:47)

```go
// Channel 结构体定义（第47行）
type Channel struct {
    Id                 int     `json:"id"`
    // ... 其他字段
    ModelPrefix        *string `json:"model_prefix" gorm:"type:varchar(64);comment:模型前缀"`
    // ... 其他字段
}

// GetModelPrefix 获取模型前缀（第244-249行）
// 返回空字符串表示未设置前缀
func (channel *Channel) GetModelPrefix() string {
    if channel.ModelPrefix == nil {
        return ""
    }
    return *channel.ModelPrefix
}
```

**关键点**：
- `ModelPrefix` 使用指针类型 `*string`，支持 NULL 值
- `GetModelPrefix()` 方法提供安全的访问方式，NULL 时返回空字符串

### 能力表（Abilities）处理

**文件**: [`model/ability.go`](model/ability.go)

#### 添加能力记录（第146-191行）

```go
func (channel *Channel) AddAbilities() error {
    models_ := strings.Split(channel.Models, ",")
    groups_ := strings.Split(channel.Group, ",")
    modelPrefix := channel.GetModelPrefix()  // 获取模型前缀
    
    abilitySet := make(map[string]struct{})
    abilities := make([]Ability, 0, len(models_))
    
    for _, model := range models_ {
        model = strings.TrimSpace(model)
        if model == "" {
            continue
        }
        // 如果设置了模型前缀，则添加前缀
        modelWithPrefix := model
        if modelPrefix != "" {
            modelWithPrefix = modelPrefix + model  // 拼接前缀
        }
        
        for _, group := range groups_ {
            group = strings.TrimSpace(group)
            if group == "" {
                continue
            }
            key := group + "|" + modelWithPrefix
            if _, exists := abilitySet[key]; exists {
                continue
            }
            abilitySet[key] = struct{}{}
            
            ability := Ability{
                Group:     group,
                Model:     modelWithPrefix,  // 存储带前缀的模型名
                ChannelId: channel.Id,
                Enabled:   channel.Status == common.ChannelStatusEnabled,
                Priority:  channel.Priority,
                Weight:    uint(channel.GetWeight()),
                Tag:       channel.Tag,
            }
            abilities = append(abilities, ability)
        }
    }
    // ... 批量插入
}
```

#### 更新能力记录（第199-273行）

```go
func (channel *Channel) UpdateAbilities(tx *gorm.DB) error {
    // 先删除该渠道的所有能力记录
    if tx == nil {
        tx = DB
    }
    err := tx.Where("channel_id = ?", channel.Id).Delete(&Ability{}).Error
    if err != nil {
        return err
    }
    
    // 重新添加（逻辑与 AddAbilities 相同）
    models_ := strings.Split(channel.Models, ",")
    groups_ := strings.Split(channel.Group, ",")
    modelPrefix := channel.GetModelPrefix()
    
    for _, model := range models_ {
        model = strings.TrimSpace(model)
        if model == "" {
            continue
        }
        modelWithPrefix := model
        if modelPrefix != "" {
            modelWithPrefix = modelPrefix + model
        }
        // ... 创建 ability 记录
    }
}
```

### 缓存层处理

**文件**: [`model/channel_cache.go`](model/channel_cache.go:46-59)

```go
func InitChannelCache() {
    // ... 初始化代码
    
    for _, channel := range channels {
        if channel.Status != common.ChannelStatusEnabled {
            continue
        }
        groups := strings.Split(channel.Group, ",")
        modelPrefix := channel.GetModelPrefix()  // 获取前缀
        
        for _, group := range groups {
            group = strings.TrimSpace(group)
            if group == "" {
                continue
            }
            models := strings.Split(channel.Models, ",")
            for _, model := range models {
                model = strings.TrimSpace(model)
                if model == "" {
                    continue
                }
                // 如果设置了模型前缀，则添加前缀（与 abilities 表保持一致）
                modelKey := model
                if modelPrefix != "" {
                    modelKey = modelPrefix + model
                }
                
                // 使用带前缀的模型名作为缓存 key
                if _, ok := newGroup2model2channels[group][modelKey]; !ok {
                    newGroup2model2channels[group][modelKey] = make([]int, 0)
                }
                newGroup2model2channels[group][modelKey] = append(
                    newGroup2model2channels[group][modelKey], 
                    channel.Id,
                )
            }
        }
    }
}
```

### 请求分发层

**文件**: [`middleware/distributor.go`](middleware/distributor.go:326-341)

```go
func SetupContextForSelectedChannel(c *gin.Context, channel *model.Channel, modelName string) *types.NewAPIError {
    c.Set("original_model", modelName)  // 保存原始请求的模型名
    
    // 处理模型前缀：如果渠道设置了前缀，移除前缀得到上游模型名
    modelPrefix := channel.GetModelPrefix()
    if modelPrefix != "" {
        common.SetContextKey(c, constant.ContextKeyChannelModelPrefix, modelPrefix)
        if strings.HasPrefix(modelName, modelPrefix) {
            upstreamModelName := strings.TrimPrefix(modelName, modelPrefix)
            common.SetContextKey(c, constant.ContextKeyUpstreamModelName, upstreamModelName)
        }
    }
    
    // ... 其他上下文设置
}
```

**上下文键定义** ([`constant/context_key.go`](constant/context_key.go:40-41)):

```go
const (
    ContextKeyChannelModelPrefix ContextKey = "channel_model_prefix"  // 渠道模型前缀
    ContextKeyUpstreamModelName  ContextKey = "upstream_model_name"   // 上游模型名（去除前缀后）
)
```

### 批量编辑标签时的处理

**文件**: [`controller/channel.go`](controller/channel.go:753-764)

```go
// 标签编辑请求结构（第753-764行）
type ChannelTag struct {
    Tag            string  `json:"tag"`
    NewTag         *string `json:"new_tag"`
    Priority       *int64  `json:"priority"`
    Weight         *uint   `json:"weight"`
    ModelMapping   *string `json:"model_mapping"`
    ModelPrefix    *string `json:"model_prefix"`   // 模型前缀
    Models         *string `json:"models"`
    Groups         *string `json:"groups"`
    ParamOverride  *string `json:"param_override"`
    HeaderOverride *string `json:"header_override"`
}
```

**文件**: [`model/channel.go`](model/channel.go:710-768)

```go
// EditChannelByTag 批量编辑标签下的渠道（第710-768行）
func EditChannelByTag(tag string, newTag *string, modelMapping *string, 
    modelPrefix *string, models *string, group *string, 
    priority *int64, weight *uint, paramOverride *string, headerOverride *string) error {
    
    updateData := Channel{}
    shouldReCreateAbilities := false
    
    // ... 其他字段处理
    
    if modelPrefix != nil {
        // 模型前缀需要更新 abilities 表
        shouldReCreateAbilities = true
        updateData.ModelPrefix = modelPrefix
    }
    
    // 更新数据库
    err := DB.Model(&Channel{}).Where("tag = ?", tag).Updates(updateData).Error
    
    // 如果需要重建 abilities
    if shouldReCreateAbilities {
        channels, err := GetChannelsByTag(updatedTag, false)
        if err == nil {
            for _, channel := range channels {
                err = channel.UpdateAbilities(nil)  // 重建每个渠道的 abilities
            }
        }
    }
}
```

---

## 前端实现

### 单渠道编辑

**文件**: [`web/src/components/table/channels/modals/EditChannelModal.jsx`](web/src/components/table/channels/modals/EditChannelModal.jsx:140)

```jsx
// 初始值定义（第131-168行）
const originInputs = {
    name: '',
    type: 1,
    key: '',
    // ... 其他字段
    model_prefix: '',  // 模型前缀字段
    // ... 其他字段
};

// 表单组件中包含 model_prefix 字段
// 该字段在表单提交时会自动包含在请求数据中
```

### 批量编辑标签

**文件**: [`web/src/components/table/channels/modals/EditTagModal.jsx`](web/src/components/table/channels/modals/EditTagModal.jsx:67-76)

```jsx
// 初始值定义（第67-76行）
const originInputs = {
    tag: '',
    new_tag: null,
    model_mapping: null,
    model_prefix: null,  // 模型前缀字段
    groups: [],
    models: [],
    param_override: null,
    header_override: null,
};

// 表单组件（第536-563行）
<Form.Input
    field='model_prefix'
    label={t('模型前缀')}
    placeholder={t('请输入模型前缀，留空则不更改')}
    onChange={(value) => handleInputChange('model_prefix', value)}
    showClear
    extraText={
        <Space>
            <Text type='tertiary' size='small'>
                {t('设置后将批量更新该标签下所有渠道的模型前缀')}
            </Text>
            <Text
                className='!text-semi-color-primary cursor-pointer'
                onClick={() => handleInputChange('model_prefix', '')}
            >
                {t('清空前缀')}
            </Text>
            <Text
                className='!text-semi-color-primary cursor-pointer'
                onClick={() => handleInputChange('model_prefix', null)}
            >
                {t('不更改')}
            </Text>
        </Space>
    }
/>
```

### API 提交处理

**文件**: [`web/src/components/table/channels/modals/EditTagModal.jsx`](web/src/components/table/channels/modals/EditTagModal.jsx:179-249)

```jsx
// handleSave 函数（第179-249行）
const handleSave = async (values) => {
    setLoading(true);
    const formVals = values || formApiRef.current?.getValues() || {};
    let data = { tag };
    
    // ... 其他字段处理
    
    // 处理 model_prefix 字段
    if (formVals.model_prefix !== undefined && formVals.model_prefix !== null) {
        data.model_prefix = formVals.model_prefix;
    }
    
    // ... 提交请求
};
```

---

## 使用场景

### 场景1：区分多个 OpenAI 渠道

```
渠道A (官方): model_prefix = "official/"
渠道B (代理): model_prefix = "proxy/"

用户请求 "official/gpt-4" → 路由到渠道A → 上游请求 "gpt-4"
用户请求 "proxy/gpt-4"    → 路由到渠道B → 上游请求 "gpt-4"
```

### 场景2：供应商命名空间

```
OpenAI 渠道: model_prefix = "openai/"
Azure 渠道:  model_prefix = "azure/"
Claude 渠道: model_prefix = "anthropic/"

用户可以明确指定：
- "openai/gpt-4"
- "azure/gpt-4"
- "anthropic/claude-3"
```

### 场景3：测试环境隔离

```
生产渠道: model_prefix = ""（无前缀）
测试渠道: model_prefix = "test-"

测试时使用 "test-gpt-4"，不影响生产环境
```

---

## 数据流图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           用户请求流程                                    │
└─────────────────────────────────────────────────────────────────────────┘

1. 配置阶段
   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
   │   管理员      │────▶│  设置渠道     │────▶│  保存配置    │
   │  配置渠道     │     │ model_prefix │     │              │
   └──────────────┘     │ = "openai/"  │     └──────┬───────┘
                        └──────────────┘            │
                                                    ▼
                        ┌──────────────────────────────────────┐
                        │         abilities 表                  │
                        │  model = "openai/gpt-4"              │
                        │  channel_id = 1                       │
                        └──────────────────────────────────────┘

2. 请求阶段
   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
   │   用户请求    │────▶│  模型匹配     │────▶│  选择渠道    │
   │ "openai/gpt-4"│     │ abilities表  │     │  channel_id=1│
   └──────────────┘     └──────────────┘     └──────┬───────┘
                                                    │
                                                    ▼
                        ┌──────────────────────────────────────┐
                        │       SetupContextForSelectedChannel  │
                        │  modelPrefix = "openai/"              │
                        │  upstreamModelName = "gpt-4"          │
                        └──────────────────────────────────────┘
                                                    │
                                                    ▼
   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
   │   上游API    │◀────│  发送请求     │◀────│  构建请求    │
   │  接收 "gpt-4"│     │  model="gpt-4"│     │              │
   └──────────────┘     └──────────────┘     └──────────────┘
```

---

## 实现要点

### 1. 数据一致性

- **abilities 表同步**：修改 `model_prefix` 时必须重建 abilities 表记录
- **缓存同步**：修改后需要调用 `InitChannelCache()` 刷新内存缓存

### 2. 前缀处理逻辑

```go
// 添加前缀（存储时）
if modelPrefix != "" {
    modelWithPrefix = modelPrefix + model
}

// 移除前缀（请求时）
if modelPrefix != "" && strings.HasPrefix(modelName, modelPrefix) {
    upstreamModelName = strings.TrimPrefix(modelName, modelPrefix)
}
```

### 3. 空值处理

- 使用指针类型 `*string` 区分"未设置"和"空字符串"
- `GetModelPrefix()` 方法统一处理 NULL 情况

### 4. 批量操作

- 通过标签批量修改时，需要遍历所有相关渠道并重建 abilities
- 使用事务确保数据一致性

### 5. 上下文传递

关键上下文键：
- `ContextKeyChannelModelPrefix`: 存储渠道的模型前缀
- `ContextKeyUpstreamModelName`: 存储去除前缀后的上游模型名

---

## 测试建议

### 单元测试

1. **Channel.GetModelPrefix() 测试**
   - 测试 `ModelPrefix` 为 nil 时返回空字符串
   - 测试 `ModelPrefix` 为空字符串时返回空字符串
   - 测试 `ModelPrefix` 有值时返回正确的前缀

2. **AddAbilities() 测试**
   - 测试无前缀时模型名正确存储
   - 测试有前缀时模型名正确拼接
   - 测试多模型、多分组的组合情况

3. **UpdateAbilities() 测试**
   - 测试更新前缀后 abilities 表正确重建
   - 测试清空前缀后 abilities 表正确更新

### 集成测试

1. **API 请求路由测试**
   - 创建带前缀的渠道，验证请求能正确路由
   - 验证上游请求中模型名已移除前缀

2. **缓存一致性测试**
   - 修改渠道前缀后，验证缓存正确更新
   - 验证带前缀的模型名能正确匹配到渠道

3. **批量编辑测试**
   - 通过标签批量设置前缀，验证所有渠道正确更新
   - 验证 abilities 表正确重建

### 前端测试

1. **单渠道编辑**
   - 验证 model_prefix 字段正确显示和保存
   - 验证清空前缀功能正常

2. **标签批量编辑**
   - 验证"清空前缀"和"不更改"按钮功能
   - 验证批量更新后所有渠道前缀正确

---

## 相关文件清单

| 文件路径 | 说明 |
|----------|------|
| [`model/channel.go`](model/channel.go) | Channel 模型定义，包含 `ModelPrefix` 字段和 `GetModelPrefix()` 方法 |
| [`model/ability.go`](model/ability.go) | Ability 模型，处理带前缀模型名的存储 |
| [`model/channel_cache.go`](model/channel_cache.go) | 渠道缓存，处理带前缀模型名的缓存映射 |
| [`middleware/distributor.go`](middleware/distributor.go) | 请求分发，处理前缀移除和上下文设置 |
| [`constant/context_key.go`](constant/context_key.go) | 上下文键定义 |
| [`controller/channel.go`](controller/channel.go) | 渠道 API 控制器，处理标签批量编辑 |
| [`web/src/components/table/channels/modals/EditChannelModal.jsx`](web/src/components/table/channels/modals/EditChannelModal.jsx) | 前端渠道编辑弹窗 |
| [`web/src/components/table/channels/modals/EditTagModal.jsx`](web/src/components/table/channels/modals/EditTagModal.jsx) | 前端标签编辑弹窗 |