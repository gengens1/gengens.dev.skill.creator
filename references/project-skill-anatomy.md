# Generated `{project}-dev` anatomy

落盘只通过 `scripts/scaffold-project-skill.ps1`。字符串表在 `assets/creator-strings.json`
（脚本自身保持 ASCII-only：PS 5.1 会用 ANSI 代码页读无 BOM 的 `.ps1`，脚本里写中文会烂）。

## 项目模型

`answers.projects[]`（1–8 个）决定一切按项目分的动作。老式扁平 answers 会折成一个名为 `main`
的项目，行为与单项目时代一致。每个项目展开成一段 `switch` case，注入到各脚本里：

- `Start-Site.ps1` / `Stop-Site.ps1` → `Get-StartSpec` / `Get-StopSpec` 返回 `@{ Dir; Body }`
- `Invoke-Verify.ps1` → 每个 target 一个 `Invoke-Verify<Build|Test|Lint>` 函数；test 的命令以 here-string
  模板注入，运行时按 `%FILTER%` 展开（见 common.ps1 的 `Invoke-ProjectCommand`）
- `Init-Project.ps1` / `Show-ProjectStatus.ps1` → `Get-InitSpec` / `Get-ProjectInfo`
- `Publish-Local/Online.ps1` → `Invoke-Publish<Local|Online>` 函数
- `Restart-Site.ps1` 不生成 case：固定按项目「先停再启」

启动时把该项目的启动块落成 `.runtime/start-<项目>.ps1`，再经 `cmd.exe` 以 `UseShellExecute` 拉起
（**不能**用 `Start-Process`：子进程会继承调用方的 stdout 句柄，捕获输出的调用方会一直等到服务退出）。
PID 记 `.runtime/pids.json`，日志写 `.runtime/logs/<项目>.{out,err}.log`。

## 目录

必生成：`SKILL.md`、`references/{commit-workflow,site-dev,docs,db}.md`、`references/domain/`、
`scripts/{common,Invoke-ProjectCommit,Start-Site,Stop-Site,Restart-Site,Invoke-DbQuery}.ps1`、
`.runtime/connections.json`。

按答案生成：`references/publish.md` + `scripts/Publish-{Local,Online,Env}.ps1`（有发布策略时）；
`references/verify.md` + `scripts/Invoke-Verify.ps1`（有构建/测试/检查命令时）；
`references/setup.md` + `scripts/Init-Project.ps1`（有准备命令时）；
`.runtime/publish-targets.json`（有其它环境时）。
另必生成 `references/architecture.md`、`scripts/Show-ProjectStatus.ps1`。

运行期产生：`.runtime/pids.json`、`.runtime/logs/`、`.runtime/start-<项目>.ps1`。

`-Force` 覆盖时先整目录备份到临时路径并打印 `SKILL_BACKUP=`；`.runtime` 下的额外文件（递归，除
`connections.json` / `publish-targets.json` / `commit-msg.txt`）会还原回新目录。

## `$map` 占位符

仓库级：`SKILL_NAME` `DOCS_ROOT` `COMMIT_FORMAT` `MAIN_BRANCH` `DEV_BRANCH_NOTES` `EXTRA_CONSTRAINTS`

项目：`PROJECT_LIST_PS`（注入 `common.ps1` 的已知项目数组）`PROJECT_NOTE`（SKILL.md 提示）
`PROJECT_DOC_INTRO`（references 提示）`PROJECT_FLAG` / `PROJECT_FLAG_EXAMPLE`（`-Project 名` 片段）
`PROJECTS_DESC_PHRASE` `COMMIT_SCOPE_HINT`

注入脚本正文：`START_SPEC_CASES` `STOP_SPEC_CASES` `VERIFY_{BUILD,TEST,LINT}_CASES`
`PUBLISH_{LOCAL,ONLINE}_CASES` `INIT_SPEC_CASES` `STATUS_INFO_CASES` `SKILL_GUARD_PS`
`BUILD_CONFIGURED` `TEST_CONFIGURED` `LINT_CONFIGURED`

整段拼装：`SITE_DOC_BODY` `VERIFY_DOC_BODY` `PUBLISH_DOC_BODY` `PUBLISH_OTHER_SECTION`
`ROUTE_EXTRA_ROWS` `SECTIONS` `DOC_LINES` `FORBIDDEN_RULE` `SKILL_VISIBILITY_NOTE` `COMMIT_EXCLUDE_EXTRA`
`SETUP_DOC_BODY` `ARCHITECTURE_BODY` `ARCHITECTURE_FILL_RULE` `ARCHITECTURE_PROJECT_ROWS`
`DOCS_TASK_NOTE` `COMMIT_VERIFY_NOTE` `VERIFY_FILTER_NOTE`

条件短语：`PUBLISH_DESC_PHRASE` `PUBLISH_AGENTS_PHRASE` `PUBLISH_TRIGGER`
`VERIFY_DESC_PHRASE` `VERIFY_AGENTS_PHRASE` `VERIFY_TRIGGER`
`SETUP_DESC_PHRASE` `SETUP_AGENTS_PHRASE` `SETUP_TRIGGER`

字符串表内部另用 `%NAME%` / `%CMD%` / `%LABEL%` / `%ENV%` / `%TARGET%` / `%PROJECTFLAG%` 占位，
由 scaffold 先替换再入 map。`{{}}` 做多轮替换（值里可能再引用别的 token）。

## 落盘前校验（暂存目录内完成）

1. `SKILL.md` 无 BOM、有 frontmatter、纯 ASCII/无尖括号/无水印文案
2. 所有产出文件无残留 `{{TOKEN}}`，也无残留 `%NAME%` 类占位符
3. 所有生成的 `.ps1` 能通过 PowerShell AST 解析（拦住注入命令的语法错误）
4. 每个生成的项目级脚本里，**每个项目都有对应 case**
5. 发布 / 验证的脚本与文档必须与答案一致（未生成的脚本不得被文档引用、不得有空代码块）
6. `Stop-Site.ps1` 不得出现裸露的「无」字（未配置要走注释 + PID 清理）

任一失败即删暂存目录，仓库里不会留半成品。
