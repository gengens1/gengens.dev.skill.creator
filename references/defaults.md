# Defaults

| 项 | 默认 |
|---|---|
| skill 路径 | `.agents/skills/{hyphen-case}-dev/` |
| skill 名 | 必须 ASCII；非 ASCII 参数会被命令行打烂并报错 |
| 项目 | `answers.projects[]`，1–8 个；只有一个也照常列出。老式扁平 answers 会自动折成一个名为 `main` 的项目 |
| 项目名 | ASCII `[a-z0-9][a-z0-9_-]*`，唯一，不能用 `all`（保留字） |
| 项目目录 | 相对仓库根，不得含 `..` 或绝对路径；留空 = 仓库根 |
| 命令执行位置 | 各项目命令都在它自己的 `dir` 下执行 |
| 首次准备 | `Init-Project.ps1 [-Project 名\|all]`；只在有人配了准备命令时生成；未配置的项目跳过 |
| 状态与日志 | `Show-ProjectStatus.ps1`：在不在跑 / PID / 启动时间 / URL；没跑起来的自动打印日志尾部 |
| 单测 | 测试命令里用 `%FILTER%` 占位；`-Filter "…"` 替换、不传则替换为空跑全量；没占位符的项目在 `all` 下跳过、指名则报错 |
| 代码地图 | `references/architecture.md`：访谈给了就写进去，否则留「首次探索经用户确认后回填」 |
| 启动 | `Start-Site.ps1 [-Project 名\|all]`（默认 all）；每个项目在**独立 PowerShell 进程**内后台运行，PID 记 `.runtime/pids.json`，日志 `.runtime/logs/<项目>.{out,err}.log`；1.5 秒内退出会打印日志尾部 |
| 启动命令写法 | 直接写前台命令，**不要**自己包 `Start-Process` |
| 停止 | `Stop-Site.ps1 -Project …`：先跑项目停止命令，再按记录的 PID `taskkill /T` 杀整棵进程树 |
| 停止命令写法 | **不要**按进程名 kill（会误杀同名进程）；按端口/PID，或答「无」交给 PID 清理 |
| 重启 | 固定「先停再启」，无独立命令 |
| 提交消息 | `type(scope):中文摘要`；多项目建议 scope 用项目名 |
| 提交 | `git commit --only -F <消息文件> -- <路径>`：只提交指定路径；预览确认后才跑 |
| 提交身份 | 仓库 `git config user.name / user.email`（不继承上一条提交的作者） |
| 提交附带 | `pre-commit` / `commit-msg` hook 与 `commit.gpgsign` 照常生效 |
| 发布 | 本地/线上按项目；无则该项目不生成对应分支、文档也不写 |
| 其它发布环境 | 仓库级，不按项目分；清单在 `.runtime/publish-targets.json` |
| 验证 | 构建/测试/检查按项目；某目标所有项目都没配 → 直接报错；只有部分项目有 → `all` 跳过没配的、指名则报错 |
| DB writePolicy | `read-only` / `confirm-write` / `allow-write`（中文：只读 / 需确认后可写 / 可写） |
| DB 写保护 | 仅文本拦截（会先剥掉注释与多语句），真正的边界是只读数据库账号 |
| 文档目录 | `private_docs` |
| skill 可见性 | `local`（`.agents/skills/` 进 .gitignore）；`shared` 则随仓库提交，只忽略 `.runtime/` |
| AGENTS | 替换 `begin/end` 之间的块（不是「有就跳过」）；开场 Announce |
| answers.json | 系统临时目录 |
| 已存在 | 询问后 `-Force`；整个旧 skill 目录备份到临时路径并打印 `SKILL_BACKUP=` |
| 访谈节奏 | 有询问工具可多问；无工具时每次一问 |
| CreatorRoot | 本 skill 目录（含 SKILL.md），勿写死其它路径 |
| 编码 | 生成的 `.ps1` 带 UTF-8 BOM（PS 5.1 需要）；`.md`/SKILL.md 不带 BOM |
