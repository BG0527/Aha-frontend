# Aha — 可视化 AI 私人教师（前端）

资料驱动的个性化学习系统的前端仓。学习者上传资料后，系统生成**可核对来源**的可视化课堂，
并通过声明式动作渲染讲解过程。

> **状态：仅仓库基础设施，无业务实现。**
> 本仓当前只有 `AGENTS.md`、`.gitignore`、`.gitattributes` 三个文件。
> 尚无 `package.json`、`src/`、任何组件或测试。前端切片 1 才建立脚手架。

---

## 技术基线

| 项 | 取值 |
|---|---|
| 框架 | React 19 + TypeScript 5.9 + Vite 8 |
| 单测 | Vitest 5 |
| 变异测试 | Stryker（`@stryker-mutator/vitest`） |
| 包管理器 | pnpm（**仅此一种**，`pnpm-lock.yaml` 入库） |
| 渲染 | 只渲染白名单声明式 `TeachingAction`，**不执行模型生成的任意 JS** |

### 版本锚（本机实测）

| 工具 | 实测版本 |
|---|---|
| Node.js | `v24.12.0` |
| pnpm | `11.8.0` |

Node 24 由三方 engines 求交集得出：Vite 8 `^20.19.0||>=22.12.0` ∩ Vitest 5
`^22.12.0||^24.0.0||>=26.0.0` ∩ pnpm 11 `>=22.13`。

---

## 命令（尚未可用）

以下命令是**约定口径**，`package.json` 尚未落地，**从未执行过**：

```bash
pnpm install --frozen-lockfile
pnpm run typecheck
pnpm run lint
pnpm run test
pnpm run build
pnpm run mutation
```

---

## 分支模型

```
main      生产，仅 human 审批后合入
release   发布候选，仅 human 审批后合入
dev       集成分支，PR 目标
feat/*    从 dev 切出，如 feat/classroom-renderer
```

`main` / `release` / `dev` 均为受保护分支，禁止直推。

---

## 先读什么

- **`AGENTS.md`** —— 本仓唯一作业说明：模块边界、渲染安全不变量、性能预算、门禁 G0–G9、提交纪律。

设计文档**不在本仓**。契约与架构决策记录在项目外部的 `dev/` 目录（本仓只引用，不复制）。

---

## 许可证

尚未选定。
