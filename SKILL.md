---
name: gengens-dev-skill-creator
description: >
  Meta-skill: interview (AskUserQuestion preferred; multi-ask OK when the ask-user tool
  is available, else one question at a time), then scaffold a project `{name}-dev` skill
  under `.agents/skills/` for any git repo, including multi-project repos (frontend +
  backend or more, addressed with `-Project`). Generates a watermark-free PowerShell
  commit flow with a pre-commit verify gate, first-run setup, per-project site
  start/stop/restart with PID + log tracking, status/log triage, build/test/lint verify
  (single-test filtering), optional publish, DB connections in `.runtime`, private docs
  (default private_docs), a code map, domain layers, and an AGENTS.md block with a
  mandatory session Announce. Triggers:
  gengens-dev-skill-creator, create project skill, scaffold -dev skill,
  创建项目skill, 创建项目级skill, 生成-dev skill, 初始化项目开发skill.
---

# gengens-dev-skill-creator

**Announce:** Using gengens-dev-skill-creator.

访谈式生成项目级 skill：`.agents/skills/{项目名}-dev/`。只允许用本 skill 的 scaffold 脚本落盘，禁止手工抄模板。

## 硬规则

1. **访谈提问**：有 `AskUserQuestion`（或环境等价的询问用户工具）时可一次提多题；**仅当询问工具不可用时**，对话内每次只问 1 个问题。
2. **先问项目清单**（多项目仓库的关键）：仓库里有几个可独立运行 / 构建的项目？每个给 name + 目录（+ 可选 URL）。准备、启停、验证、发布都按项目问。只有一个项目也照常列出来。
3. 全部答完后 **预览** → 用户确认 → 再 scaffold；禁止擅自写入。预览里必须复述**判「无」的项**（如 `web.stop = 无`、`api.lint = 无`），避免把自然语言答案误当成命令注入。
4. 默认见 [references/defaults.md](references/defaults.md)；问题见 [references/interview-checklist.md](references/interview-checklist.md)；结构见 [references/project-skill-anatomy.md](references/project-skill-anatomy.md)。
5. Answers 形状见 [references/answers.example.json](references/answers.example.json)。
6. **发布 / 验证**：按 checklist 提问；没给出的环境与目标不生成脚本、不写进文档。只生成已给出的。
7. **skill 名必须是 ASCII**：`-SkillName` 走命令行参数，非 ASCII 会被控制台代码页打烂（脚本会直接报错）。仓库名是中文时让用户给英文名。项目名同理（且不能用 `all`）。
8. **启动命令不要自己包 `Start-Process`**：生成的脚本会后台拉起每个项目并记 PID / 日志；用户只需给前台命令。停止不要按进程名 kill。
9. **测试命令建议带 `%FILTER%` 占位**：这样 `-Filter` 能只跑单个测试；不带占位符的项目在 `-Project all` 下会被跳过。
10. 生成物自带 `Show-ProjectStatus.ps1`（状态+日志尾部）与 `references/architecture.md`（代码地图，首次探索经用户确认后回填）。

## 工作流

1. Announce；读 `defaults.md` + `interview-checklist.md`。
2. 按 checklist 收集答案（提问节奏见硬规则 1）。
3. 若目标 skill 已存在：询问取消或覆盖；覆盖时加 `-Force`。**先提醒用户**：`-Force` 会用模板重写全部脚本（含他自己补全过的 `Publish-Env.ps1` / `Invoke-DbQuery.ps1`），旧目录会整体备份到临时路径（stdout 的 `SKILL_BACKUP=`），但合并回去是他的活。
4. 预览关键参数（含判「无」清单）后确认。
5. answers 写到系统临时目录，再跑 scaffold。**`$CreatorRoot` 必须是本 skill 目录**（含本 `SKILL.md` 的目录；从 available_skills / 附件全路径解析），禁止臆造其它安装路径：

```powershell
$CreatorRoot = "<THIS_SKILL_DIR>"   # 例：.../skills/gengens-dev-skill-creator
$Answers = Join-Path $env:TEMP ("project-dev-answers-" + [guid]::NewGuid().ToString("N") + ".json")
# 写入 $Answers 后：
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CreatorRoot "scripts\scaffold-project-skill.ps1") `
  -RepoRoot "REPO_ROOT" `
  -SkillName "name-dev" `
  -DocsRoot "private_docs" `
  -AnswersJsonPath $Answers `
  [-Force]
```

6. 核对 stdout：`SCAFFOLD_OK`、`PROJECTS=`、`STAGING_VALIDATE_OK`、`SKILL_VALIDATE_OK`、`PROJECT_DEV_CREATOR_OK`；并**转述** `ANSWER_READ_AS_NONE`、`SKILL_BACKUP`、`PUBLISH_ENABLED`、`VERIFY_ENABLED`、`SKILL_VISIBILITY`。勿重复追加 AGENTS/gitignore。
7. 删除临时 answers.json。

## 成功判据

脚本在**暂存目录**完成全部校验后才落入仓库，失败不留半成品 skill。校验包括：frontmatter、残留 `{{TOKEN}}`、
**生成的 `.ps1` 能否通过 PowerShell AST 解析**（挡住注入命令的语法错误）、发布/验证文件与答案是否一致。
stdout 含 `SKILL_VALIDATE_OK`。
