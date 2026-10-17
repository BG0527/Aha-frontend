# AGENTS.md — Aha Frontend

> **归属**：本文件只管辖 `Aha/frontend` 仓。后端域见 `Aha/backend/AGENTS.md`。
> **设计事实源**：`D:\Develop\projects\nixiang\study\dev\`（重点：`20-契约/契约-前端课堂架构.md`、`ADR-T01`、`ADR-T20`、`ADR-T23`）。
> **本仓不复制设计文档**。本文件只写「本仓怎么干活」；设计成什么样以 `dev/` 为准，冲突时以 `dev/` 为准并上报。

---

## 0. 仓库身份

| 项 | 值 |
|---|---|
| 仓路径 | `D:\Develop\projects\nixiang\study\Aha\frontend` |
| 部署形态 | 静态 SPA 构建产物（Vite build），由后端或反向代理托管 |
| 上层仓库 | **无**。顶层 `study/` 不是 git 仓；`competitor/` 下的嵌套仓与本仓无关，**不得修改** |

---

## 1. 运行时与依赖锚（版本锁定，不得自行漂移）

| 项 | 锚定值 | 依据 |
|---|---|---|
| **Node.js** | **24.x**（当前实测 `v24.12.0`） | Vite 8 要求 `^20.19.0 \|\| >=22.12.0`；Vitest 5 要求 `^22.12.0 \|\| ^24.0.0 \|\| >=26.0.0`；pnpm 11 要求 `>=22.13`。**三者交集 → Node 24 LTS** |
| **pnpm** | **11.x**（当前实测 `11.8.0`） | 见下方「包管理器纪律」 |
| **React** | 19.x | ADR-T01 |
| **TypeScript** | 5.9.x | 勿自行跳到 7.x（其生态尚不稳） |
| **Vite** | 8.x | 构建基线 |
| **Vitest** | 5.x | 单测基线 |
| **Stryker** | `@stryker-mutator/vitest` | 变异测试（G3/G5 要求） |

> 版本号以 `package.json` 的 `engines` / `devDependencies` 落地为准；本表是**锚**，改动需走 ADR + 人类确认。
> 任何「已实测」表述仅限上表标注「当前实测」的两项；其余是**目标基线**，未实测。

### 1.1 包管理器纪律（硬规则）

- **只用 pnpm。禁止 npm / yarn 混用。** `pnpm-lock.yaml` 必须入库。
- **机器强制**：`.gitignore` 已显式忽略 `package-lock.json` / `npm-shrinkwrap.json` / `yarn.lock` / `bun.lock*`。误用其它包管理器时锁文件**进不了 commit**，会在 review 前暴露。
- 提交前自查仓库根只有 `pnpm-lock.yaml` 一个锁文件。
- 使用 corepack 固定版本，不在文档里写全局安装：

```jsonc
// package.json
{ "packageManager": "pnpm@11.8.0", "engines": { "node": ">=24.0.0 <25", "pnpm": ">=11.0.0 <12" } }
```

---

## 2. 技术基线（人类已冻结，不得重议）

| 决策 | 取值 | 依据 |
|---|---|---|
| 框架 | **React 19 + TypeScript + Vite** | ADR-T01 / P-051 |
| 状态分层 | **Server State / Classroom State / View State** 三层，形状固定 | `契约-前端课堂架构.md` §4.2 |
| Server State | TanStack Query（缓存即加速，**非事实**） | 同上 |
| Classroom State | 状态库**暂不锁定**（Zustand vs Redux Toolkit 判据见 §4.3） | 同上 |
| 渲染 | **只渲染白名单声明式 `TeachingAction`** | ADR-T20 / ADR-T23 |
| 动作消费 | 只有 `action-renderer` 能把 `TeachingAction` 转成 React 节点 | 不变量 I-F4 |
| 路由 | 见 §3；课堂是**独立全屏路由** | `契约-前端课堂架构.md` §4.1 |
| 契约来源 | OpenAPI v1 + WebSocket 课堂事件（**禁止手写类型绕过**） | P-070、`契约-WebSocket课堂事件.md` |

---

## 3. 应用骨架（固定形状，改动需上报）

```
src/
├─ app/
│  ├─ routes/                  # / · /sources · /classroom/:sessionId · /outcomes · /settings · /admin/compliance
│  ├─ providers/               # QueryClient · WS · Auth · ErrorBoundary
│  └─ layouts/                 # 页面骨架（课堂**不共享**此布局）
├─ features/
│  ├─ classroom/
│  │  ├─ stage/                # CanvasStage + CameraLayer
│  │  ├─ source-layer/         # 原资料层（PDF/图片/PPT/网页）—— PDF 页必须虚拟化
│  │  ├─ board-layer/          # 画布层（Teacher/Learner 双层）
│  │  ├─ action-renderer/      # ★ TeachingAction → React 组件（白名单映射，唯一入口）
│  │  ├─ transport/            # WS Adapter（envelope / ACK / 游标）
│  │  └─ state/                # Classroom State
│  ├─ sources/  outcomes/  settings/
└─ shared/
   ├─ ui/                      # 通用组件（不自建设计系统）
   ├─ api/                     # REST client（Problem.code 处理）
   └─ lib/                     # 坐标换算、时间格式
```

**分层硬规则**：

- `shared/` **不得**依赖 `features/`（防反向依赖）。CI 必须有等价 ArchUnit 的检查。
- `action-renderer` 是**唯一**消费原始 `TeachingAction` 的地方；其他组件不得直接消费。
- `action-renderer` 内是**白名单静态映射表** `kind → Component`；未知 `kind` ⇒ 拒绝并上报 `ActionReject{reason:"UNSUPPORTED_TYPE"}`，**不得**用兜底组件静默渲染。

---

## 4. 前端不变量（违反即 G4 拒绝）

### 4.1 渲染安全（最高优先）

1. **严禁执行模型生成的任意 JS**：禁止 `eval`、`new Function`、`dangerouslySetInnerHTML` 渲染模型产出、`javascript:` URL。
2. **能力协商**：连接时上报 `renderer_capabilities: ["L0","L1","L2",...]`；服务端下发超出能力的动作 ⇒ `ActionReject{reason:"UNSUPPORTED_TYPE"}`，前端**不得**自行降级渲染冒充成功。
3. **渲染分级 L0–L4**（`契约-前端课堂架构.md` §3）：能力不足时**降级并告知**，不伪造理解。L3（PPT 动画）不足时**局部暂停**。L0 文字 / `text_equivalent` 是必选兜底。

### 4.2 状态真实性

4. **Server State 不得**被前端写入后当事实提交（I-F1）；所有「进度」必须是服务端确认的 revision。
5. **Classroom State 的 `sequence` / `generation` 只能由 WS 事件推进**，不得本地自增。
6. **View State 不得**持久化到服务端（相机除外——只持久化 `camera_hint`）。
7. **课堂刷新** ⇒ 走 `ResyncRequest` 恢复，**不从 URL 参数重建状态**。
8. **旧 `generation` 到达** ⇒ 拒绝并 `ActionReject`（无感，记 Trace）。

### 4.3 与后端一致的 12 条不变量

`Aha/backend/AGENTS.md` §3 的 12 条同样约束前端。前端侧最直接的三条：
**受控自主（不替模型发布教学事实）· 证据不足局部暂停并告知缺口 · 未实测不得宣称 SLO**（性能数字一律 `[待测]`）。

---

## 5. 必读 `.agents/skills`（动手前）

**本仓 `.agents/skills/` 是本地技能资产，不入公开仓（`.gitignore` 已整体忽略 `.agents/`），但磁盘必须保留、不得删除。** 实现 UI 前**必须先读**对应 `SKILL.md`：

| 技能 | 何时必读 |
|---|---|
| `.agents/skills/ui-ux/SKILL.md` | 任何组件 / 布局 / 交互实现 |
| `.agents/skills/ui-ux-pro-max-zh/SKILL.md` | 中文界面、视觉规范、配色与字体 |
| `.agents/skills/frontend-design/SKILL.md` | 页面级设计、信息层级、响应式 |
| `.agents/skills/motion-web/SKILL.md` | 任何动效 / 过渡 / 白板动画 |

- 读完再动手，**不要凭记忆**实现视觉。
- 视觉基线：`dev/design/ai-teacher-prototype`（10 页原型 + screenshots + evidence）。
- `ui-ux/scripts/__pycache__` 已被 `.gitignore` 忽略，属正常。

---

## 6. 性能预算（全部 `[待测]`，未实测不得写成结论）

| 指标 | 保守基线 `[待测]` | 测量方式 |
|---|---|---|
| 首屏（Lighthouse，4G） | ≤ 3s | CI 中 Lighthouse |
| 首屏 JS 体积（gzip） | ≤ 300 KB | 构建产物检查 |
| 300 页 PDF 课堂内存 | ≤ 500 MB | Chrome DevTools Memory |
| 动作渲染（单 batch） | ≤ 100 ms | Performance API |
| 缩放/平移帧率 | ≥ 30 fps | requestAnimationFrame 统计 |
| WS 重连恢复 | ≤ 5s（P-028 目标，非保证） | 故障注入 |

**红线（CI 阻断）**：首屏 JS > 500 KB 或 Lighthouse < 2 分 ⇒ 阻断合入。
**内存治理**：`SourceLayer` 的 PDF 页必须虚拟化（只渲染可见页 ± 1）；`BoardLayer` 笔迹按 `generation` 分片，旧分片可卸载。

---

## 7. 开发流程（强制）

```
grill-requirements → doublecheck_spec → red-green-tdd → 实现到绿
  → ponytail 收尾（YAGNI / 浏览器原生 API 优先 / 删掉没人要求的抽象）
    → delivery-review（对抗性自审）→ 上报，等待门禁
```

- **先红后绿**：红必须是**真断言失败**。
- **ponytail 是收尾必做项**，结论写进交付说明。
- 交付判据是「**可被验证的行为成立**」，不是「页面能打开」。

### 7.1 用户硬性约束（三句话）

1. **不要重复造轮子**：能用成熟库 / 框架内置 / 浏览器原生 API 就用。不自写状态管理、请求层、表单、虚拟列表、动画引擎、diff/parser、日期库。自研前必须举证「找不到能用的」；**优先采用 `.agents/skills` 已资产化的方案**。
2. **不要以实现为目的**：以「可被验证的行为成立」为完成。
3. **实在做不了就停下来上报**（captain → 人类 grill）。**不得造假实现、不得静默降级。**

### 7.2 命令（可复跑）

```bash
pnpm install --frozen-lockfile
pnpm run typecheck      # tsc --noEmit
pnpm run lint
pnpm run test           # vitest run
pnpm run test:cov       # vitest run --coverage
pnpm run build          # vite build（含产物体积检查）
pnpm run mutation       # stryker run
```

> 上述脚本名是**约定口径**；`package.json` 尚未落地（见 §10），**不代表已跑过**。

---

## 8. 门禁 G0–G9

| 门 | 名称 | 守门人 | 本仓要交什么 |
|---|---|---|---|
| **G0** | 需求门 | product-scope | 切片范围与可机器判定的验收标准 |
| **G1** | 架构安全门 | arch-contract | 分层落点、层间依赖方向 |
| **G2** | 契约门 | arch-contract | 消费 OpenAPI / WS Schema，**不得手写类型绕过** |
| **G3** | 测试就绪门 | test-lead | 测试方案、需求级变异体、对抗性自审清单 |
| **G4** | 代码 Review 门 | code-reviewer | 可评审的 diff + 复跑命令 + 真实输出 |
| **G5** | 集成门 | integration-qa | 真实前后端集成/E2E 证据，不许 mock 冒充集成 |
| **G6** | 专项门 | integration-qa | 可访问性、性能、兼容性专项 |
| **G7** | 环境 / CI 门 | platform-release | typecheck、lint、单测、构建体积、敏感信息扫描、依赖漏洞 |
| **G8** | 发布门 | platform-release | 证据包 + CHANGELOG + 回滚预案 + PR 材料 |
| **G9** | 生产验证门 | platform-release | 部署后真实验证；未实测不得宣称 SLO |

---

## 9. 分支模型（四级）与提交纪律

```
main      ← 只接受来自 release 的合入；受保护，仅人类审批后合并
release   ← 只接受来自 dev 的合入；仅人类审批后合并
dev       ← 集成分支；feat/* 的 PR 目标
feat/*    ← 从 dev 切出，如 feat/classroom-renderer、feat/action-whitelist
```

- `feat/*` **必须**从 `dev` 切出，PR 回 `dev`；`dev → release → main` **仅人类审批后**执行。
- 禁止直推 `main` / `release` / `dev`。
- **禁止频繁 commit**：粒度为「功能点实现切片」，切片完整（含测试与复跑证据）后才提交一次。
- **commit 前与 PR 前都必须先向人类报审**，人工通过后才执行。**不得先斩后奏。**
- 提交信息：`<type>(<scope>): <中文摘要>`，scope 用 `features/*` 或 `shared/*` 名称（如 `classroom`、`action-renderer`）。

---

## 10. 目录约定（当前状态）

```
Aha/frontend/
├─ AGENTS.md                     ← 本文件
├─ .gitignore / .gitattributes
└─ .agents/skills/               ← ★ 本地技能资产，不入库（磁盘保留）
   ├─ frontend-design/            (SKILL.md + LICENSE.txt)
   ├─ motion-web/                 (SKILL.md)
   ├─ ui-ux/                      (SKILL.md + data/*.csv + scripts/*.py + templates/)
   └─ ui-ux-pro-max-zh/           (SKILL.md + README.md + _meta.json)
```

> 本仓当前**只有仓库基础设施与技能资产**，没有 `package.json` / `src/`。
> 前端切片 1 负责建立脚手架。任何「已完成」的表述都必须先有代码与测试证据。

---

## 11. 引用纪律

- 引用设计结论必须带 `文件路径` + `内容锚`；**只写行号不算引用**。
- 无法判定的写「信息不足」，不要猜。
- 发现 `dev/` 与本仓实现冲突：**停下来上报**，不得自行改契约或放宽约束。
- **不往本仓写设计文档**。`dev/` 是唯一事实源；本文件是例外（写「怎么干活」而非「设计成什么样」）。
