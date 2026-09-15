# DeepSeek Harness（dsh）适配包

本目录把 `ai-vibecode-superpower` 的全局行为规范与 `orchestrate-model-workflow` skill 适配为 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`，npm 包 `@deepseek-ai/dsh`）可用。Codex、ZCode 与 opencode 版不受影响。

## 内容与映射

| 本目录 | 对应 opencode 版 | 说明 |
| --- | --- | --- |
| `AGENTS.md` | `opencode-global-config/AGENTS.md` | 全局行为规范；安装到 `$DSH_HOME/AGENTS.md`，由 `dsh-agent-instructions` 在会话首请求加载，加入 `<DSH_HOME>/docs` 系统文档路由。 |
| `docs/README.md` | `opencode-global-config/docs/README.md` | 系统命令按需路由、平台差异和工具安装说明；与共享 `docs/system/` 组合安装。 |
| `skills/orchestrate-model-workflow/SKILL.md` | `opencode-global-config/skills/orchestrate-model-workflow/SKILL.md` | 同一五阶段流程；subagent 调度交给 dsh 的 `subagent` 工具（spawn/fork 后端），角色路由表达为模型与思考档选择。 |

dsh 没有独立 subagent 角色文件机制（区别于 Codex/opencode 的 role/agent 文件），因此 12 个角色不在 dsh 中以文件形式分发，而是由 skill 的角色选择段落描述职责、并用 `$DSH_HOME/settings.yaml` 的模型与其 `reasoningEfforts` 落地模型与思考档分层。

## 模型与思考档分层

角色分层复用 `~/.dsh/settings.yaml` 的 provider（参考默认 `qpt`），要求声明模型 `deepseek-v4.1-flash`，并在该模型条目上声明 `reasoningEfforts`；所有角色共用该模型，差异来自职责、权限与 `reasoning_effort`：

| 角色分组 | provider/model | 思考档 | 角色 |
| --- | --- | --- | --- |
| Luna | `qpt` / `deepseek-v4.1-flash` | `low`、`high` | 取证、预审、受控写入等常规与低成本路径。 |
| Terra | `qpt` / `deepseek-v4.1-flash` | `high`、`max` | 受保护执行、风险分流、集成与常规复审。 |
| Sol | `qpt` / `deepseek-v4.1-flash` | `high`、`max` | 复杂定案、升级调查与最高强度独立复审。 |

该模型不支持 `medium` 与 `xhigh`；dsh 对不支持的档位直接以 `UNSUPPORTED_REASONING_EFFORT` 拒绝派发、不做钳制，因此 12 个角色已收敛到 `low` / `high` / `max`。模型条目需要形如：

```yaml
{ id: deepseek-v4.1-flash, name: deepseek-v4.1-flash, input: [text, image], reasoningEfforts: { off: null, low: low, high: high, max: max } }
```

安装脚本只探测并提示模型档与 `reasoningEfforts` 是否已声明，**不写入或覆盖** `settings.yaml`。

## 明确不做

- **`agent-toolchain` 不适配**：它通过 `configure` 写入 `.codex/config.toml`、`.zcode/config.json` 或项目 `opencode.json` 的 `mcp`；dsh 没有项目级配置文件落点（MCP 由 cordis patch 声明），因此不纳入 dsh 分发，需要在 dsh 中接入 MCP 时另行按 `@deepseek-ai/dsh-mcp-client` 配置。
- **`project-doc-planner` 不纳入**：保持最小分发，仅提供全局行为规范与工作流 skill。
- **不创建 agent preset**：`orchestrate-model-workflow` 是行为级 skill，不复制 `standard` preset 或改 `~/.dsh/.agent-presets`。

## 安装与部署

```sh
sh ./install.sh dsh
```

安装器解析 dsh 配置目录（默认 `~/.dsh`，可用 `DSH_HOME` 覆盖），替换 `AGENTS.md`、`docs/` 中的 `<DSH_HOME>` 占位符，并备份已有受管文件。安装前需已安装 `@deepseek-ai/dsh`（脚本会检查 `dsh` 命令可用）并运行过一次 `dsh web`；`settings.yaml` 保留不动。安装成功后完全重启 dsh web，在新会话中使用。