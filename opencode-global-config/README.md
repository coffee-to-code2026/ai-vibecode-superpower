# opencode 适配包

本目录把 `ai-vibecode-superpower` 的全局行为规范、agent 角色与 standalone skills 适配为 [opencode](https://opencode.ai) 可用的独立分发，目标模型为 deepseek（默认 `merge-ai/deepseek-v4-flash`，可替换）。Codex 版、ZCode 版与 opencode 版并存，互不覆盖。

## 内容与映射

| 本目录 | 对应 Codex 版 | 说明 |
| --- | --- | --- |
| `AGENTS.md` | `codex-global-config/AGENTS.md` | 全局行为规范，加入 `<OPENCODE_HOME>/docs` 系统文档路由，保留沟通语言、效率策略与开发规范。 |
| `opencode.json` | `codex-global-config/config.toml` | 默认模型与入口设置；已有 `opencode.json` 时安装器不覆盖。 |
| `agents/ai-vibecode-superpower/*.md` | `codex-global-config/agents/ai-vibecode-superpower/*.toml` | 12 个 role 一一对应的 subagent；只读角色用 `permission.edit: deny` 表达读边界。角色命名沿用统一公式 `模型_版本_类型_思考档`，如 `deepseek_v4_flash_luna_high`。安装器把这些文件逐个放入 `~/.config/opencode/agent/`，不覆盖用户自建 agent。 |
| `skills/orchestrate-model-workflow/SKILL.md` | `skills/orchestrate-model-workflow/SKILL.md` | 同一五阶段流程；subagent 创建、上下文、通信和汇总由 opencode 原生 `task` 工具负责。 |
| `skills/agent-toolchain/` | `shared/skills/agent-toolchain/` | CodeGraph/RTK 接入与维护；opencode 版 `configure` 用 `--config opencode` 把 MCP 写入项目 `opencode.json`，其余命令与驱动逻辑共用仓库脚本。 |

角色继承 `opencode.json` 顶层的 `model` 字段作为主会话默认；12 个 subagent 各自在 frontmatter 显式声明 `model` 与 `options.reasoningEffort`，对齐 Codex 版的"模型档 × 思考长度"分层。安装器只管理 `AGENTS.md`、`docs/`、`agent/*.md` 和受管的 skills，不修改 opencode 的全局状态或用户自建 agent。

## 模型与思考长度分层

每个角色直接声明自己的模型与推理档位（agent 级 `options` 会覆盖 provider 级默认）：

| 角色 | model | reasoningEffort |
| --- | --- | --- |
| `deepseek_v4_flash_luna_high` / `deepseek_v4_flash_luna_high_executor` | `merge-ai/deepseek-v4-flash` | high |
| `deepseek_v4_flash_luna_xhigh` / `deepseek_v4_flash_luna_xhigh_executor` | `merge-ai/deepseek-v4-flash` | xhigh |
| `deepseek_v4_pro_terra_high` | `merge-ai/deepseek-v4-pro` | high |
| `deepseek_v4_pro_terra_xhigh` | `merge-ai/deepseek-v4-pro` | xhigh |
| `deepseek_v4_pro_terra_xhigh_readonly` | `merge-ai/deepseek-v4-pro` | xhigh |
| `deepseek_v4_pro_terra_low_readonly` | `merge-ai/deepseek-v4-pro` | low |
| `deepseek_v4_pro_terra_medium_readonly` | `merge-ai/deepseek-v4-pro` | medium |
| `deepseek_v4_pro_sol_high` | `merge-ai/deepseek-v4-pro` | high |
| `deepseek_v4_pro_sol_xhigh` | `merge-ai/deepseek-v4-pro` | xhigh |
| `deepseek_v4_pro_sol_max` | `merge-ai/deepseek-v4-pro` | max |

- **换模型**：改各 agent frontmatter 的 `model` 行即可；`opencode.json` 的顶层 `model` 只控制主会话（build）默认。
- **生效层级**：agent 级 `options.reasoningEffort` 覆盖 provider 级 `models.<id>.options`；未显式声明的角色才落到全局 provider 默认。
- **单角色覆盖**：直接编辑该 agent frontmatter。
- **分层意图**：Luna(flash，常规取证/受控写入) → pro 更高档给 Terra/Sol(定案、保护执行、独立复审)；`reasoningEffort` 从 low 到 max 递增，低成本经济替代角色用 low/medium。

## 安装与部署

```sh
sh ./install.sh opencode
```

安装器解析 opencode 全局配置目录（默认 `~/.config/opencode`，可用 `OPENCODE_HOME` 覆盖），替换文档中的 `<OPENCODE_HOME>` 占位符，并备份已有受管文件。部署完成后完全重启 opencode，在新会话中使用 `orchestrate-model-workflow` 与 `agent-toolchain`。若目标目录已存在 `opencode.json`，安装器不会覆盖，需按提示手动合并 `model` 字段。

> 参考实现（独立安装脚本）安装的旧版 `avsp-*` 角色与本版本文件名不同；升级前请先手动清理旧版受管文件，避免两个角色体系并存。