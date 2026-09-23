# Interview checklist

答案形状见 `answers.example.json`。

**提问节奏**：有 `AskUserQuestion`（或等价询问用户工具）时可一次提多题；仅当询问工具不可用时，对话内每次只问 1 题。

**判「无」的规则**：回答里的 `无 / 没有 / 暂无 / 不需要 / 跳过 / 忽略 / none / no / n/a / skip`（含结尾句号、空格、引号）都算「没有该能力」。脚本会归一化后判定，并把结果打进 `ANSWER_READ_AS_NONE`；**预览时必须把这个结果复述给用户**。

---

## 仓库级

### Q1 — 仓库根路径

> 目标仓库根目录绝对路径？

### Q2 — skill 名

探测根目录名 → `{name}-dev`（将规范为小写 hyphen-case）。

> 是否采用建议名？否则给出名称（须以 `-dev` 结尾）。

**必须给 ASCII 名**：`-SkillName` 走命令行参数，非 ASCII 会被控制台代码页打烂，脚本会直接报错。仓库名是中文时，请用户给一个英文名（如 `订单` → `order-dev`）。

### Q2b — 已存在

若目录已存在：

> 取消 / 覆盖重建（`-Force`）？覆盖会**用模板重写全部脚本**，包括用户自己补全过的 `Publish-Env.ps1`、`Invoke-DbQuery.ps1`；旧目录会整体备份到临时路径（stdout 的 `SKILL_BACKUP=`），但用户仍需自行合并回去。

### Q3 — 提交消息格式

先 `git log -10 --oneline`，展示历史 + 默认 `type(scope):中文摘要`。

> 采用默认还是其它规则？

多项目仓库建议约定 scope 用项目名（`feat(web): …`）。

### Q4 — 主分支

> 主分支名？

### Q4b — 提交身份

默认取仓库 `git config user.name / user.email`（不继承上一条提交的作者）。

> 用仓库配置的身份提交即可吗？需要固定成别的身份则给出 name + email。

### Q5 — 日常分支命名

> 有无约定？（无 / 没有 / 暂无 均可）

### Q6 — skill 是否随仓库提交

> 生成的 skill 是本机专用（`.agents/skills/` 加进 `.gitignore`，默认），还是随仓库提交、团队共享？

选「共享」时：`.gitignore` 只排除 `.runtime/`，提交脚本也不再拦截 skill 路径。

### Q7 — 文档目录名

> 默认 `private_docs`？

### Q7b — 现有架构说明

> 有没有现成的架构/代码地图（要点或文件路径）？没有就答「无」。

有则原样写进 `references/architecture.md`；没有也不生成空话——文件里会留「首次探索时填」的规则。

### Q8 — DB 连接（仓库级，不按项目分）

扫描配置后展示候选（密码可打码）。

> 写入哪些连接？每项给出 **name + engine**。

### Q8b — 连接串

对每个连接：

> 连接 `{name}` 的 connectionString？（可确认沿用探测到的原文）

### Q9 — 写权限

> 连接 `{name}` 的 writePolicy？`read-only`（只读） / `confirm-write`（需确认后可写） / `allow-write`（可写）。

只读需求请同时用**只读数据库账号**：`writePolicy` 只是脚本里的文本拦截，不是安全边界。

### Q10 — AGENTS.md

展示片段后：

> 是否追加？

### Q11 — 其它硬约束

> 有则说明，否则「无」。

---

## 项目级

### Q12 — 项目清单

> 仓库里有几个可独立运行 / 构建的项目？各给一个 **name + 目录 + URL（可选）**。

- 只有一个项目也照常列出来（`dir` 可留空 = 仓库根）
- name 必须 ASCII 小写（如 `web` / `api` / `admin`），会出现在命令行参数里；非 ASCII 会被打烂并报错
- name 不能用 `all`（保留字，表示全部）
- URL 只用于状态展示（`http://localhost:5173` 这类），可留空

### Q13 — 首次准备命令（每个项目，可选）

> `{项目}` 新克隆后要跑什么才能跑起来？

装依赖、从 `.env.example` 复制 `.env`、初始化数据库都放这里，可多行。命令在该项目的 `dir` 下执行。
没有就答「无」——那样不会生成 `Init-Project.ps1`。

### Q14 — 启动命令（每个项目）

> `{项目}` 怎么启动？

**直接写前台命令**（如 `npm run dev`）——命令在该项目的 `dir` 下执行，脚本会**后台拉起**每次启动并记 PID + 日志到 `.runtime/`。
**不要**自己写 `Start-Process`，那是脚本的活。多行 OK（含 here-string 也行）。

### Q15 — 停止命令（每个项目，可选）

> `{项目}` 怎么停？

**不要**按进程名 kill——`Get-Process node | Stop-Process` 会把机器上同名进程全杀掉。按端口/PID 写，或答「无」：脚本会按启动时记录的 PID 杀整棵进程树。

重启固定是「先停再启」，不需要单独给命令；要特殊处理就改生成的脚本。

### Q16 — 构建 / 测试 / 静态检查（每个项目）

> `{项目}` 的构建、测试、静态检查分别怎么跑？各自可答「无」。

测试命令**建议**用 `%FILTER%` 标出插入点（把参数一起写进去），例如 `dotnet test %FILTER%` 或 `npm test -- %FILTER%`：

- 传 `-Filter "--filter OrderTests"` → 只跑该测试
- 不传 `-Filter` → 占位符替换为空，即跑全量

不写占位符也能用，只是该项目不支持 `-Filter`（`-Project all` 时会被跳过）。

只生成答过的目标。某目标在所有项目都没配置时，跑它会直接报错；只有部分项目配置时，`-Project all` 跳过没配的、指名项目则报错。

### Q17 — 本地发布（每个项目，可选）

> `{项目}` 本地发布命令/步骤？无则答「无」。

### Q18 — 线上发布（每个项目，可选）

> `{项目}` 线上发布？无则答「无」。

### Q19 — 其它发布环境（仓库级）

> 除本地/线上外的环境（如 staging）？给出「名称 + 策略」；无则「无」。这一层不按项目分。

---

## 预览

把所有答案归一化后逐项复述，**特别是被判为「无」的项**（例：`web.stop = 无`、`api.lint = 无`、`web.publishOnline = 无`），再请用户确认。

## 预览后

写临时 answers.json → scaffold → 核对 stdout：`SCAFFOLD_OK`、`PROJECTS=`、`STAGING_VALIDATE_OK`、`SKILL_VALIDATE_OK`、`PROJECT_DEV_CREATOR_OK`，并复述 `ANSWER_READ_AS_NONE` / `SKILL_BACKUP` / `PUBLISH_ENABLED` / `VERIFY_ENABLED` / `SKILL_VISIBILITY`。
