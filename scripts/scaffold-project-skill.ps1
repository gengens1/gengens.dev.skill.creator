param(
  [Parameter(Mandatory = $true)][string]$RepoRoot,
  [Parameter(Mandatory = $true)][string]$SkillName,
  [Parameter(Mandatory = $true)][string]$DocsRoot,
  [Parameter(Mandatory = $true)][string]$AnswersJsonPath,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

# This script is deliberately ASCII-only: Windows PowerShell 5.1 decodes BOM-less script
# files with the ANSI code page, so literal CJK here would corrupt on non-UTF-8 locales.
# All user-facing CJK/AI phrases live in the string table below.
$CreatorRoot = Split-Path $PSScriptRoot -Parent
$StringsPath = Join-Path $CreatorRoot "assets\creator-strings.json"
if (-not (Test-Path -LiteralPath $StringsPath)) { throw "string table missing: $StringsPath" }
$S = Get-Content -LiteralPath $StringsPath -Raw -Encoding UTF8 | ConvertFrom-Json

$script:NoneWords = @($S.noneWords | ForEach-Object { [string]$_ })
$script:NoneRegex = [string]$S.noneRegex
$script:TailPunct = @($S.tailPunctuation | ForEach-Object { [char][int]$_ })
$script:NoneFields = New-Object System.Collections.Generic.List[string]

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$utf8Bom = New-Object System.Text.UTF8Encoding $true

function Get-NoneKey([string]$s) {
  if ($null -eq $s) { return "" }
  $t = $s.Trim()
  $t = $t -replace '^[\s"''`]+', ''
  $t = $t -replace '[\s"''`]+$', ''
  if ($t.Length -gt 0 -and $script:TailPunct.Count -gt 0) { $t = $t.TrimEnd($script:TailPunct) }
  return $t
}

# True when the answer means "no such capability". Compared after trimming whitespace,
# surrounding quotes and trailing punctuation, so a trailing full stop, "skip" and "N/A"
# all count as "not provided".
function Test-IsNone([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $true }
  $t = Get-NoneKey $s
  if ($t.Length -eq 0) { return $true }
  foreach ($w in $script:NoneWords) { if ($t -eq $w) { return $true } }
  return ($t -match $script:NoneRegex)
}

# Record answers that were read as "no capability" so the caller can re-check them.
function Test-AnsweredNone([string]$field, [string]$value) {
  if (Test-IsNone $value) {
    if ($script:NoneFields -notcontains $field) { $script:NoneFields.Add($field) | Out-Null }
    return $true
  }
  return $false
}

function Expand-Template([string]$text, [hashtable]$map) {
  $out = $text
  # Several passes on purpose: a substituted value may itself mention another token
  # (the forbidden-rule phrase references {{DOCS_ROOT}}), and hashtable order is not
  # guaranteed. The leftover-token check below catches anything still unresolved.
  for ($pass = 0; $pass -lt 3; $pass++) {
    $before = $out
    foreach ($k in $map.Keys) {
      $out = $out.Replace('{{' + $k + '}}', [string]$map[$k])
    }
    if ($out -eq $before) { break }
  }
  return $out
}

# Markdown keeps no BOM (frontmatter validation + tooling); .ps1 gets one so Windows
# PowerShell 5.1 reads injected non-ASCII with UTF-8 instead of the ANSI code page.
function Copy-Expanded([string]$src, [string]$dst, [hashtable]$map, [switch]$Bom) {
  $raw = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
  $expanded = Expand-Template $raw $map
  $dir = Split-Path $dst -Parent
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $enc = if ($Bom) { $utf8Bom } else { $utf8NoBom }
  [System.IO.File]::WriteAllText($dst, $expanded, $enc)
}

function Test-HasHereString([string]$text) {
  # A here-string opens on a line ending in @" or @' and closes with a terminator that
  # must sit at column 0, so any command containing one is injected without re-indenting.
  return ($text -match '(?m)@("|'')\s*$')
}

function ConvertTo-InjectedPs([string]$cmd, [int]$Indent = 2) {
  $pad = " " * $Indent
  if (Test-IsNone $cmd) {
    return ($pad + 'throw "PROJECT_FAIL: this action is not configured; edit this script."')
  }
  $lines = @($cmd -split "`r?`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($lines.Count -eq 0) {
    return ($pad + 'throw "PROJECT_FAIL: this action is not configured; edit this script."')
  }
  if (Test-HasHereString $cmd) { return ($lines -join "`r`n") }
  return (($lines | ForEach-Object { $pad + $_ }) -join "`r`n")
}

function Normalize-SkillName([string]$name) {
  $raw = $name
  # A non-ASCII argument is mangled by the Windows console code page before it reaches
  # us and arrives as '?'. Without this guard 'CJK-name' silently normalizes to 'a-dev'.
  if ($name -match '\?') {
    throw ("SkillName contains '?': '" + $name + "'. The argument was mangled on the way in " +
      "(non-ASCII names do not survive the command line). Pass an explicit ASCII name " +
      "ending in -dev, e.g. -SkillName app-dev.")
  }
  $n = $name.Trim().ToLowerInvariant()
  $n = $n -replace '[_\s]+', '-'
  $n = $n -replace '[^a-z0-9\-]', ''
  $n = $n -replace '-{2,}', '-'
  $n = $n.Trim('-')
  if ($n -notmatch '-dev$') { $n = $n.TrimEnd('-') + '-dev' }
  if ($n -notmatch '^[a-z0-9-]+$' -or $n.Length -gt 64 -or $n.Length -lt 5) {
    throw ("SkillName invalid after normalize: '" + $n + "' (from '" + $raw + "'). " +
      "Normalization keeps only [a-z0-9-], so a repo name in CJK or another script collapses to nothing. " +
      "Pass an explicit ASCII name ending in -dev, e.g. -SkillName app-dev.")
  }
  return $n
}

function Normalize-ProjectName([string]$name) {
  if ($name -match '\?') {
    throw ("project name contains '?': '" + $name + "'. It was mangled on the way in; use ASCII.")
  }
  $n = $name.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($n)) { $n = [string]$S.defaultProjectName }
  if ($n -eq "all") { throw "project name 'all' is reserved (it means every project)" }
  if ($n -notmatch '^[a-z0-9][a-z0-9_-]*$') {
    throw ("project name must match [a-z0-9][a-z0-9_-]* : '" + $name + "'")
  }
  return $n
}

function Normalize-ProjectDir([string]$d) {
  if ([string]::IsNullOrWhiteSpace($d)) { return "" }
  $x = $d.Trim().Replace('\', '/').Trim('/')
  if ($x.Contains('..') -or [System.IO.Path]::IsPathRooted($x)) {
    throw ("project dir must be a relative path inside the repo: '" + $d + "'")
  }
  if ($x -notmatch '^[A-Za-z0-9_\-./]+$') {
    throw ("project dir has illegal characters: '" + $d + "'")
  }
  return $x
}

function Normalize-ProjectUrl([string]$u) {
  if ([string]::IsNullOrWhiteSpace($u)) { return "" }
  $x = $u.Trim()
  if ($x -notmatch '^[A-Za-z0-9_.:/?&=#%~+-]+$') {
    throw ("project url has characters that are not safe in a script string: '" + $u + "'")
  }
  return $x
}

function Get-DirExpression([string]$dir) {
  if ([string]::IsNullOrWhiteSpace($dir)) { return '$RepoRoot' }
  return ('(Get-ProjectDir $RepoRoot "' + $dir + '")')
}

function Read-TextPreserveBom([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($bom) { $text = $text.Substring(1) }
  return @{ Text = $text; Bom = $bom }
}

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
if (-not (Test-Path -LiteralPath $AnswersJsonPath)) { throw "AnswersJsonPath not found: $AnswersJsonPath" }

$DocsRoot = $DocsRoot.Trim().TrimEnd('/', '\')
if ([string]::IsNullOrWhiteSpace($DocsRoot)) { throw "DocsRoot required" }
if ($DocsRoot.Contains('..') -or [System.IO.Path]::IsPathRooted($DocsRoot)) {
  throw "DocsRoot must be a simple relative directory name (no .. or absolute path): $DocsRoot"
}
if ($DocsRoot -notmatch '^[A-Za-z0-9_-]+$') {
  throw "DocsRoot contains illegal characters: $DocsRoot"
}

$SkillName = Normalize-SkillName $SkillName
Write-Host "SKILL_NAME_NORMALIZED=$SkillName"

$answers = Get-Content -LiteralPath $AnswersJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tplRoot = Join-Path $CreatorRoot "assets\project-skill-template"
if (-not (Test-Path -LiteralPath $tplRoot)) { throw "template missing: $tplRoot" }

# ---- resolve the project list ------------------------------------------------------
# Preferred shape: answers.projects[]. Legacy flat answers collapse into one project.
$rawProjects = New-Object System.Collections.Generic.List[hashtable]
if ($answers.projects) {
  foreach ($p in @($answers.projects)) {
    $rawProjects.Add(@{
      name          = [string]$p.name
      dir           = [string]$p.dir
      url           = [string]$p.url
      init          = [string]$p.init
      start         = [string]$p.start
      stop          = [string]$p.stop
      build         = [string]$p.build
      test          = [string]$p.test
      lint          = [string]$p.lint
      publishLocal  = [string]$p.publishLocal
      publishOnline = [string]$p.publishOnline
    }) | Out-Null
  }
} else {
  $rawProjects.Add(@{
    name          = [string]$S.defaultProjectName
    dir           = ""
    url           = [string]$answers.siteUrl
    init          = [string]$answers.initCommand
    start         = [string]$answers.siteStart
    stop          = [string]$answers.siteStop
    build         = [string]$answers.verifyBuild
    test          = [string]$answers.verifyTest
    lint          = [string]$answers.verifyLint
    publishLocal  = [string]$answers.publishLocal
    publishOnline = [string]$answers.publishOnline
  }) | Out-Null
}
if ($rawProjects.Count -eq 0) { throw "answers.projects is empty" }
if ($rawProjects.Count -gt 8) { throw ("too many projects: " + $rawProjects.Count + " (max 8)") }

$projects = New-Object System.Collections.Generic.List[pscustomobject]
$seenNames = @{}
foreach ($rp in $rawProjects) {
  $nm = Normalize-ProjectName ([string]$rp.name)
  if ($seenNames.ContainsKey($nm)) { throw ("duplicate project name: '" + $nm + "'") }
  $seenNames[$nm] = $true
  $dir = Normalize-ProjectDir ([string]$rp.dir)
  $projects.Add([pscustomobject]@{
    Name          = $nm
    Dir           = $dir
    Url           = Normalize-ProjectUrl ([string]$rp.url)
    Init          = [string]$rp.init
    Start         = [string]$rp.start
    Stop          = [string]$rp.stop
    Build         = [string]$rp.build
    Test          = [string]$rp.test
    Lint          = [string]$rp.lint
    PublishLocal  = [string]$rp.publishLocal
    PublishOnline = [string]$rp.publishOnline
  }) | Out-Null
}
$multiProject = ($projects.Count -gt 1)
$projectNamesPs = ('"' + (($projects | ForEach-Object { $_.Name }) -join '", "') + '"')
Write-Host ("PROJECTS=" + (($projects | ForEach-Object { $_.Name }) -join ","))

# per-project capability flags (recording what was read as "no capability")
$cap = @{}
foreach ($p in $projects) {
  $cap[$p.Name] = @{
    Init          = -not (Test-AnsweredNone ($p.Name + ".init") $p.Init)
    Start         = -not (Test-AnsweredNone ($p.Name + ".start") $p.Start)
    Stop          = -not (Test-AnsweredNone ($p.Name + ".stop") $p.Stop)
    Build         = -not (Test-AnsweredNone ($p.Name + ".build") $p.Build)
    Test          = -not (Test-AnsweredNone ($p.Name + ".test") $p.Test)
    Lint          = -not (Test-AnsweredNone ($p.Name + ".lint") $p.Lint)
    PublishLocal  = -not (Test-AnsweredNone ($p.Name + ".publishLocal") $p.PublishLocal)
    PublishOnline = -not (Test-AnsweredNone ($p.Name + ".publishOnline") $p.PublishOnline)
  }
}

$hasLocal = $false
$hasOnline = $false
foreach ($p in $projects) {
  if ($cap[$p.Name].PublishLocal) { $hasLocal = $true }
  if ($cap[$p.Name].PublishOnline) { $hasOnline = $true }
}
$publishOther = [string]$answers.publishOther
$hasOther = -not (Test-AnsweredNone "publishOther" $publishOther)
$publishEnabled = $hasLocal -or $hasOnline -or $hasOther

$script:anyBuild = $false
$script:anyTest = $false
$script:anyLint = $false
foreach ($p in $projects) {
  if ($cap[$p.Name].Build) { $script:anyBuild = $true }
  if ($cap[$p.Name].Test) { $script:anyTest = $true }
  if ($cap[$p.Name].Lint) { $script:anyLint = $true }
}
$verifyEnabled = ($script:anyBuild -or $script:anyTest -or $script:anyLint)

$skillVisibility = if ($answers.skillVisibility) { ([string]$answers.skillVisibility).Trim().ToLowerInvariant() } else { "local" }
if ($skillVisibility -notin @("local", "shared")) {
  throw "skillVisibility must be 'local' or 'shared', got: $skillVisibility"
}
$skillLocal = ($skillVisibility -eq "local")

# ---- generate per-project code fragments -------------------------------------------
function New-SpecCases([string]$Field) {
  # $Field: 'Start' or 'Stop' - which action the returned spec hashtable carries
  $out = ""
  foreach ($p in $projects) {
    $dirExpr = Get-DirExpression $p.Dir
    $out += '    "' + $p.Name + '" {' + "`r`n"
    if ($Field -eq 'Start') {
      if ($cap[$p.Name].Start) {
        $out += '      return @{' + "`r`n"
        $out += '        Dir  = ' + $dirExpr + "`r`n"
        $out += '        Body = {' + "`r`n"
        $out += (ConvertTo-InjectedPs $p.Start 10) + "`r`n"
        $out += '        }' + "`r`n"
        $out += '      }' + "`r`n"
      } else {
        $msg = ([string]$S.projects.startMissing).Replace('%NAME%', $p.Name)
        $out += '      throw "' + $msg + '"' + "`r`n"
      }
    } elseif ($Field -eq 'Init') {
      # a project with nothing to install is a normal steady state, not an error
      if ($cap[$p.Name].Init) {
        $out += '      return @{' + "`r`n"
        $out += '        Dir  = ' + $dirExpr + "`r`n"
        $out += '        Body = {' + "`r`n"
        $out += (ConvertTo-InjectedPs $p.Init 10) + "`r`n"
        $out += '        }' + "`r`n"
        $out += '      }' + "`r`n"
      } else {
        $out += '      return @{ Dir = ' + $dirExpr + '; Body = $null }' + "`r`n"
      }
    } else {
      if ($cap[$p.Name].Stop) {
        $out += '      return @{' + "`r`n"
        $out += '        Dir  = ' + $dirExpr + "`r`n"
        $out += '        Body = {' + "`r`n"
        $out += (ConvertTo-InjectedPs $p.Stop 10) + "`r`n"
        $out += '        }' + "`r`n"
        $out += '      }' + "`r`n"
      } else {
        $out += ([string]$S.site.stopNoneComment) + "`r`n"
        $out += '      return @{ Dir = ' + $dirExpr + '; Body = $null }' + "`r`n"
      }
    }
    $out += '    }' + "`r`n"
  }
  return $out
}

function New-StatusCases {
  # one case per project for Show-ProjectStatus.ps1: where it lives and what URL to print
  $out = ""
  foreach ($p in $projects) {
    $out += '    "' + $p.Name + '" {' + "`r`n"
    $out += '      return @{ Dir = ' + (Get-DirExpression $p.Dir) + '; Url = "' + $p.Url + '" }' + "`r`n"
    $out += '    }' + "`r`n"
  }
  return $out
}

function New-ActionCases([string]$Action, [string]$MissingKey, [string]$Label, [switch]$AsTemplate) {
  # $Action: Build/Test/Lint/PublishLocal/PublishOnline
  # $Label: what the missing-capability message calls this action (build / local / ...)
  # -AsTemplate: wrap the command in a here-string so %FILTER% can be substituted at run time
  $out = ""
  foreach ($p in $projects) {
    $dirExpr = Get-DirExpression $p.Dir
    $has = $cap[$p.Name].$Action
    $cmd = $p.$Action
    $out += '    "' + $p.Name + '" {' + "`r`n"
    if ($has) {
      $out += '      Push-Location ' + $dirExpr + "`r`n"
      $out += '      try {' + "`r`n"
      if ($AsTemplate) {
        # the closing '@ must sit at column 0, so this block is deliberately not indented
        $out += '        Invoke-ProjectCommand -Name "' + $p.Name + '" -Filter $Filter -Explicit $Explicit -Template @''' + "`r`n"
        $out += ((@($cmd -split "`r?`n") | ForEach-Object { $_.TrimEnd() } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n") + "`r`n"
        $out += "'@" + "`r`n"
      } else {
        $out += (ConvertTo-InjectedPs $cmd 8) + "`r`n"
      }
      $out += '      } finally { Pop-Location }' + "`r`n"
      $out += '      return' + "`r`n"
    } else {
      $missing = ([string]$S.projects.$MissingKey).
        Replace('%NAME%', $p.Name).
        Replace('%TARGET%', $Label).
        Replace('%ENV%', $Label)
      $out += '      if ($Explicit) { throw "' + $missing + '" }' + "`r`n"
      $out += ('      Write-Host "PROJECT_SKIP project=' + $p.Name + ' action=' + $Action + ' reason=not-configured"') + "`r`n"
      $out += '      return' + "`r`n"
    }
    $out += '    }' + "`r`n"
  }
  return $out
}

# ---- documentation bodies ----------------------------------------------------------
$siteDocBody = ""
foreach ($p in $projects) {
  if ($cap[$p.Name].Start) {
    $siteDocBody += ([string]$S.projects.docStart).Replace('%NAME%', $p.Name).Replace('%CMD%', $p.Start)
  } else {
    $siteDocBody += ([string]$S.projects.docStartNone).Replace('%NAME%', $p.Name)
  }
  if ($cap[$p.Name].Stop) {
    $siteDocBody += ([string]$S.projects.docStop).Replace('%NAME%', $p.Name).Replace('%CMD%', $p.Stop)
  } else {
    $siteDocBody += ([string]$S.projects.docStopNone).Replace('%NAME%', $p.Name)
  }
}

$verifyDocBody = ""
foreach ($p in $projects) {
  foreach ($t in @("build", "test", "lint")) {
    $action = @{ build = "Build"; test = "Test"; lint = "Lint" }[$t]
    if ($cap[$p.Name].$action) {
      $verifyDocBody += ([string]$S.projects.docVerify).
        Replace('%NAME%', $p.Name).
        Replace('%LABEL%', [string]$S.verify.targetLabels.$t).
        Replace('%CMD%', $p.$action)
    }
  }
}

$publishDocBody = ""
foreach ($p in $projects) {
  if ($cap[$p.Name].PublishLocal) {
    $publishDocBody += ([string]$S.projects.docPublish).
      Replace('%NAME%', $p.Name).
      Replace('%ENV%', [string]$S.publish.envLabels.local).
      Replace('%CMD%', $p.PublishLocal)
  }
  if ($cap[$p.Name].PublishOnline) {
    $publishDocBody += ([string]$S.projects.docPublish).
      Replace('%NAME%', $p.Name).
      Replace('%ENV%', [string]$S.publish.envLabels.online).
      Replace('%CMD%', $p.PublishOnline)
  }
}
$publishOtherSection = ""
if ($hasOther) {
  $publishOtherSection = ([string]$S.publish.otherSection).Replace('%CMD%', $publishOther)
}

$projectFlag = if ($multiProject) { [string]$S.projects.routeFlag } else { "" }
$projectFlagExample = if ($multiProject) { " -Project " + $projects[0].Name } else { "" }
$projectNote = if ($multiProject) {
  [string]$S.projects.docIntro
} else {
  ([string]$S.projects.docIntroSingle).Replace('%NAME%', $projects[0].Name)
}
$commitScopeHint = if ($multiProject) { [string]$S.projects.commitScopeHint } else { "" }

$setupEnabled = $false
foreach ($p in $projects) { if ($cap[$p.Name].Init) { $setupEnabled = $true } }

$setupDocBody = ""
foreach ($p in $projects) {
  if ($cap[$p.Name].Init) {
    $setupDocBody += ([string]$S.setup.docSection).Replace('%NAME%', $p.Name).Replace('%CMD%', $p.Init)
  } else {
    $setupDocBody += ([string]$S.setup.docSectionNone).Replace('%NAME%', $p.Name)
  }
}

$docsTaskNote = if ($multiProject) {
  ([string]$S.docs.taskNoteMulti).Replace('%PROJECTS%', (($projects | ForEach-Object { $_.Name }) -join [string]$S.docs.taskSeparator))
} else {
  [string]$S.docs.taskNoteSingle
}

$architectureBody = ""
if ($answers.architecture) {
  $architectureBody = ([string]$S.architecture.header) + "`n`n" + ([string]$answers.architecture).Trim() + "`n`n"
}
$architectureRows = ""
foreach ($p in $projects) {
  $dirShown = if ($p.Dir) { $p.Dir } else { "(repo root)" }
  $architectureRows += ('| ' + $p.Name + ' | `' + $dirShown + '` | (to fill) |') + "`n"
}

$commitVerifyNote = ""
if ($verifyEnabled) {
  $commitVerifyNote = ([string]$S.commit.verifyNote).Replace('%PROJECTFLAG%', $projectFlag)
}

$verifyFilterNote = ""
if ($script:anyTest) {
  $verifyFilterNote = ([string]$S.verify.filterHint) + "`n`n"
}

# ---- route rows + sections ---------------------------------------------------------
$sections = New-Object System.Collections.Generic.List[string]
$routeRows = New-Object System.Collections.Generic.List[string]
$docLines = New-Object System.Collections.Generic.List[string]

$publishDesc = ""
$publishAgents = ""
$publishTrigger = ""
if ($publishEnabled) {
  $publishDesc = [string]$S.publish.descPhrase
  $publishAgents = [string]$S.publish.agentsPhrase
  $publishTrigger = [string]$S.publish.triggerPhrase
  if ($hasLocal) {
    $routeRows.Add(([string]$S.publish.routeRows.local).Replace('%PROJECTFLAG%', $projectFlag))
  }
  if ($hasOnline) {
    $routeRows.Add(([string]$S.publish.routeRows.online).Replace('%PROJECTFLAG%', $projectFlag))
  }
  if ($hasOther) {
    $routeRows.Add(([string]$S.publish.routeRows.other).Replace('%PROJECTFLAG%', $projectFlag))
  }
  $sections.Add([string]$S.publish.section) | Out-Null
  $docLines.Add([string]$S.docLines.publish) | Out-Null
}

$verifyDesc = ""
$verifyAgents = ""
$verifyTrigger = ""
if ($verifyEnabled) {
  $verifyDesc = [string]$S.verify.descPhrase
  $verifyAgents = [string]$S.verify.agentsPhrase
  $verifyTrigger = [string]$S.verify.triggerPhrase
  $routeRows.Add(([string]$S.verify.routeRow).Replace('%PROJECTFLAG%', $projectFlag))
  $sections.Add([string]$S.verify.section) | Out-Null
  $docLines.Add([string]$S.docLines.verify) | Out-Null
}

if ($setupEnabled) { $docLines.Insert(0, [string]$S.docLines.setup) }

$routeExtraRows = ""
if ($routeRows.Count -gt 0) {
  $routeExtraRows = (($routeRows | ForEach-Object { $_ }) -join "`n") + "`n"
}
# setup row goes first: a fresh clone needs it before anything else
if ($setupEnabled) {
  $routeExtraRows = ([string]$S.setup.routeRow).Replace('%PROJECTFLAG%', $projectFlag) + "`n" + $routeExtraRows
}

$forbiddenRule = if ($skillLocal) { [string]$S.skillVisibility.forbiddenLocal } else { [string]$S.skillVisibility.forbiddenShared }
$visibilityNote = if ($skillLocal) { [string]$S.skillVisibility.agentsLocal } else { [string]$S.skillVisibility.agentsShared }
$commitExcludeExtra = if ($skillLocal) { [string]$S.skillVisibility.commitExcludeLocal } else { [string]$S.skillVisibility.commitExcludeShared }
$skillGuardPs = if ($skillLocal) { [string]$S.skillVisibility.guardPs } else { "" }
$noneWord = [string]$S.noneWord

$map = @{
  SKILL_NAME            = $SkillName
  DOCS_ROOT             = $DocsRoot
  COMMIT_FORMAT         = $(if ($answers.commitMessageFormat) { [string]$answers.commitMessageFormat } else { [string]$S.defaultCommitFormat })
  MAIN_BRANCH           = $(if ($answers.mainBranch) { [string]$answers.mainBranch } else { "main" })
  DEV_BRANCH_NOTES      = $(if ($answers.devBranchNotes) { [string]$answers.devBranchNotes } else { [string]$S.defaultDevBranchNotes })
  PROJECT_LIST_PS       = $projectNamesPs
  PROJECT_NOTE          = $projectNote
  PROJECT_DOC_INTRO     = $projectNote
  PROJECT_FLAG          = $projectFlag
  PROJECT_FLAG_EXAMPLE  = $projectFlagExample
  PROJECTS_DESC_PHRASE  = $(if ($multiProject) { [string]$S.projects.descPhrase } else { "" })
  COMMIT_SCOPE_HINT     = $commitScopeHint
  ROUTE_EXTRA_ROWS      = $routeExtraRows
  SECTIONS              = (($sections | ForEach-Object { $_ }) -join "`n`n")
  DOC_LINES             = $(if ($docLines.Count -gt 0) { (($docLines | ForEach-Object { $_ }) -join "`n") + "`n" } else { "" })
  FORBIDDEN_RULE        = $forbiddenRule
  SKILL_VISIBILITY_NOTE = $visibilityNote
  COMMIT_EXCLUDE_EXTRA  = $commitExcludeExtra
  SKILL_GUARD_PS        = $skillGuardPs
  EXTRA_CONSTRAINTS     = $(if ($answers.extraConstraints) { [string]$answers.extraConstraints } else { $noneWord })
  PUBLISH_DESC_PHRASE   = $publishDesc
  PUBLISH_AGENTS_PHRASE = $publishAgents
  PUBLISH_TRIGGER       = $publishTrigger
  PUBLISH_DOC_BODY      = $publishDocBody
  PUBLISH_OTHER_SECTION = $publishOtherSection
  VERIFY_DESC_PHRASE    = $verifyDesc
  VERIFY_AGENTS_PHRASE  = $verifyAgents
  VERIFY_TRIGGER        = $verifyTrigger
  VERIFY_DOC_BODY       = $verifyDocBody
  SITE_DOC_BODY         = $siteDocBody
  START_SPEC_CASES      = (New-SpecCases "Start")
  STOP_SPEC_CASES       = (New-SpecCases "Stop")
  VERIFY_BUILD_CASES    = (New-ActionCases "Build" "verifyMissing" "build")
  VERIFY_TEST_CASES     = (New-ActionCases "Test" "verifyMissing" "test" -AsTemplate)
  VERIFY_LINT_CASES     = (New-ActionCases "Lint" "verifyMissing" "lint")
  PUBLISH_LOCAL_CASES   = (New-ActionCases "PublishLocal" "publishMissing" "local")
  PUBLISH_ONLINE_CASES  = (New-ActionCases "PublishOnline" "publishMissing" "online")
  BUILD_CONFIGURED      = $(if ($script:anyBuild) { "`$true" } else { "`$false" })
  TEST_CONFIGURED       = $(if ($script:anyTest) { "`$true" } else { "`$false" })
  LINT_CONFIGURED       = $(if ($script:anyLint) { "`$true" } else { "`$false" })
  STATUS_INFO_CASES     = (New-StatusCases)
  INIT_SPEC_CASES       = (New-SpecCases "Init")
  SETUP_DOC_BODY        = $setupDocBody
  SETUP_DESC_PHRASE     = $(if ($setupEnabled) { [string]$S.setup.descPhrase } else { "" })
  SETUP_AGENTS_PHRASE   = $(if ($setupEnabled) { [string]$S.setup.agentsPhrase } else { "" })
  SETUP_TRIGGER         = $(if ($setupEnabled) { [string]$S.setup.triggerPhrase } else { "" })
  DOCS_TASK_NOTE        = $docsTaskNote
  ARCHITECTURE_BODY     = $architectureBody
  ARCHITECTURE_FILL_RULE = [string]$S.architecture.fillRule
  ARCHITECTURE_PROJECT_ROWS = $architectureRows
  COMMIT_VERIFY_NOTE    = $commitVerifyNote
  VERIFY_FILTER_NOTE    = $verifyFilterNote
}

$finalSkillDir = Join-Path $RepoRoot ".agents\skills\$SkillName"
$stagingRoot = Join-Path $env:TEMP ("project-dev-scaffold-" + [guid]::NewGuid().ToString("N"))
$skillDir = Join-Path $stagingRoot $SkillName
$runtimeBackup = $null

# ---- back up the existing skill BEFORE any mutation --------------------------------
if ((Test-Path -LiteralPath $finalSkillDir) -and (-not $Force)) {
  throw "Skill dir already exists: $finalSkillDir (pass -Force after user approval)"
}
if (Test-Path -LiteralPath $finalSkillDir) {
  # Whole-dir backup: the generated docs tell users to edit these scripts, and re-running
  # with -Force rewrites every one of them.
  $skillBackup = Join-Path $env:TEMP ("project-dev-skill-bak-" + [guid]::NewGuid().ToString("N"))
  Copy-Item -LiteralPath $finalSkillDir -Destination $skillBackup -Recurse -Force
  Write-Host "SKILL_BACKUP=$skillBackup"
  Write-Host "SKILL_BACKUP_NOTE=previous skill dir (including your script edits) copied there"
  $runtimeBackup = Join-Path $skillBackup ".runtime"
}

New-Item -ItemType Directory -Force -Path $skillDir | Out-Null

try {
Copy-Expanded (Join-Path $tplRoot "SKILL.md.tmpl") (Join-Path $skillDir "SKILL.md") $map
foreach ($pair in @(
  @("references\commit-workflow.md.tmpl", "references\commit-workflow.md"),
  @("references\site-dev.md.tmpl", "references\site-dev.md"),
  @("references\docs.md.tmpl", "references\docs.md"),
  @("references\db.md.tmpl", "references\db.md"),
  @("references\architecture.md.tmpl", "references\architecture.md")
)) {
  Copy-Expanded (Join-Path $tplRoot $pair[0]) (Join-Path $skillDir $pair[1]) $map
}
if ($setupEnabled) {
  Copy-Expanded (Join-Path $tplRoot "references\setup.md.tmpl") (Join-Path $skillDir "references\setup.md") $map
}
if ($publishEnabled) {
  Copy-Expanded (Join-Path $tplRoot "references\publish.md.tmpl") (Join-Path $skillDir "references\publish.md") $map
}
if ($verifyEnabled) {
  Copy-Expanded (Join-Path $tplRoot "references\verify.md.tmpl") (Join-Path $skillDir "references\verify.md") $map
}
Copy-Item -LiteralPath (Join-Path $tplRoot "references\domain") -Destination (Join-Path $skillDir "references\domain") -Recurse -Force

foreach ($pair in @(
  @("scripts\common.ps1.tmpl", "scripts\common.ps1"),
  @("scripts\Invoke-ProjectCommit.ps1.tmpl", "scripts\Invoke-ProjectCommit.ps1"),
  @("scripts\Start-Site.ps1.tmpl", "scripts\Start-Site.ps1"),
  @("scripts\Stop-Site.ps1.tmpl", "scripts\Stop-Site.ps1"),
  @("scripts\Restart-Site.ps1.tmpl", "scripts\Restart-Site.ps1"),
  @("scripts\Show-ProjectStatus.ps1.tmpl", "scripts\Show-ProjectStatus.ps1"),
  @("scripts\Invoke-DbQuery.ps1.tmpl", "scripts\Invoke-DbQuery.ps1")
)) {
  Copy-Expanded (Join-Path $tplRoot $pair[0]) (Join-Path $skillDir $pair[1]) $map -Bom
}
if ($setupEnabled) { Copy-Expanded (Join-Path $tplRoot "scripts\Init-Project.ps1.tmpl") (Join-Path $skillDir "scripts\Init-Project.ps1") $map -Bom }
if ($hasLocal) { Copy-Expanded (Join-Path $tplRoot "scripts\Publish-Local.ps1.tmpl") (Join-Path $skillDir "scripts\Publish-Local.ps1") $map -Bom }
if ($hasOnline) { Copy-Expanded (Join-Path $tplRoot "scripts\Publish-Online.ps1.tmpl") (Join-Path $skillDir "scripts\Publish-Online.ps1") $map -Bom }
if ($hasOther) { Copy-Expanded (Join-Path $tplRoot "scripts\Publish-Env.ps1.tmpl") (Join-Path $skillDir "scripts\Publish-Env.ps1") $map -Bom }
if ($verifyEnabled) { Copy-Expanded (Join-Path $tplRoot "scripts\Invoke-Verify.ps1.tmpl") (Join-Path $skillDir "scripts\Invoke-Verify.ps1") $map -Bom }

$runtimeDir = Join-Path $skillDir ".runtime"
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
$connObj = @{ connections = @() }
if ($answers.dbConnections) {
  foreach ($c in @($answers.dbConnections)) {
    $connObj.connections += @{
      name             = [string]$c.name
      engine           = [string]$c.engine
      connectionString = [string]$c.connectionString
      writePolicy      = [string]$c.writePolicy
    }
  }
}
[System.IO.File]::WriteAllText((Join-Path $runtimeDir "connections.json"), ($connObj | ConvertTo-Json -Depth 6), $utf8NoBom)

if ($hasOther) {
  $targets = @()
  if ($answers.publishOtherTargets) {
    foreach ($t in @($answers.publishOtherTargets)) {
      $targets += @{ name = [string]$t.name; strategy = [string]$t.strategy }
    }
  } else {
    $targets += @{ name = [string]$S.publish.otherTargetFallback; strategy = $publishOther }
  }
  [System.IO.File]::WriteAllText((Join-Path $runtimeDir "publish-targets.json"), ((@{ targets = $targets }) | ConvertTo-Json -Depth 6), $utf8NoBom)
}

if ($runtimeBackup -and (Test-Path -LiteralPath $runtimeBackup)) {
  $skipNames = @("connections.json", "publish-targets.json", "commit-msg.txt")
  Get-ChildItem -LiteralPath $runtimeBackup -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($runtimeBackup.Length).TrimStart('\', '/')
    if ($skipNames -contains $_.Name) { return }
    $dest = Join-Path $runtimeDir $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
  }
  Write-Host "RUNTIME_RESTORE_EXTRA_FROM_BACKUP_OK"
}

# ---- validate the staging copy BEFORE touching the repo -----------------------------
$skillMd = Join-Path $skillDir "SKILL.md"
$bytes = [System.IO.File]::ReadAllBytes($skillMd)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
  throw "SKILL_VALIDATE_FAIL: SKILL.md has UTF-8 BOM"
}
$text = [System.IO.File]::ReadAllText($skillMd, $utf8NoBom)
if (-not $text.StartsWith("---")) { throw "SKILL_VALIDATE_FAIL: missing YAML frontmatter" }
$fm = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
if (-not $fm.Success) { throw "SKILL_VALIDATE_FAIL: frontmatter block not closed" }
$front = $fm.Groups[1].Value
$frontCheck = [regex]::Replace($front, '(?m)^(\s*\w[\w-]*:\s*)[>|](\s*)$', '$1')
if ($frontCheck -match 'Co-authored-by' -or $frontCheck -match '<cursor' -or $frontCheck -match '<[^\s>]+@') {
  throw "SKILL_VALIDATE_FAIL: description contains cursor trailer or email angle brackets"
}
if ($frontCheck -match '[<>]') {
  throw "SKILL_VALIDATE_FAIL: description contains angle brackets (rejected by skill validators)"
}

# any leftover {{TOKEN}} means a template and the scaffold drift apart
Get-ChildItem -LiteralPath $skillDir -Recurse -File | ForEach-Object {
  $body = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
  $leftover = [regex]::Match($body, '\{\{[A-Z][A-Z0-9_]*\}\}')
  if ($leftover.Success) {
    throw ("SKILL_VALIDATE_FAIL: unexpanded template token " + $leftover.Value + " in " + $_.Name)
  }
  # %NAME%-style placeholders used inside the string table
  $leftover2 = [regex]::Match($body, '%(PROJECTFLAG|CMD|NAME|LABEL|ENV|TARGET)%')
  if ($leftover2.Success) {
    throw ("SKILL_VALIDATE_FAIL: unsubstituted placeholder " + $leftover2.Value + " in " + $_.Name)
  }
}

# injected commands come from free-text answers: they must at least parse
$psFiles = @(Get-ChildItem -LiteralPath (Join-Path $skillDir "scripts") -Filter *.ps1 -File)
if ($psFiles.Count -eq 0) { throw "SKILL_VALIDATE_FAIL: no scripts generated" }
foreach ($f in $psFiles) {
  $parseErrors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors)
  if ($parseErrors -and $parseErrors.Count -gt 0) {
    $first = $parseErrors[0]
    throw ("SKILL_VALIDATE_FAIL: generated script does not parse: " + $f.Name + " line " + $first.Extent.StartLineNumber + " => " + $first.Message +
      " (check the commands you gave in the interview, or edit the script afterwards)")
  }
}

# every project must appear in every generated per-project script
$projScoped = @("Start-Site.ps1", "Stop-Site.ps1", "Show-ProjectStatus.ps1")
if ($verifyEnabled) { $projScoped += "Invoke-Verify.ps1" }
if ($setupEnabled) { $projScoped += "Init-Project.ps1" }
if ($hasLocal) { $projScoped += "Publish-Local.ps1" }
if ($hasOnline) { $projScoped += "Publish-Online.ps1" }
foreach ($n in $projScoped) {
  $body = [System.IO.File]::ReadAllText((Join-Path $skillDir ("scripts\" + $n)), [System.Text.Encoding]::UTF8)
  foreach ($p in $projects) {
    if ($body -notmatch ('(?m)^\s*"' + [regex]::Escape($p.Name) + '"\s*\{')) {
      throw ("SKILL_VALIDATE_FAIL: " + $n + " has no case for project '" + $p.Name + "'")
    }
  }
}

if (-not $publishEnabled) {
  if (Test-Path (Join-Path $skillDir "scripts\Publish-Local.ps1")) { throw "SKILL_VALIDATE_FAIL: unexpected Publish-Local" }
  if (Test-Path (Join-Path $skillDir "references\publish.md")) { throw "SKILL_VALIDATE_FAIL: unexpected publish.md" }
} else {
  if ($hasLocal -and -not (Test-Path (Join-Path $skillDir "scripts\Publish-Local.ps1"))) { throw "SKILL_VALIDATE_FAIL: missing Publish-Local" }
  if ($hasOnline -and -not (Test-Path (Join-Path $skillDir "scripts\Publish-Online.ps1"))) { throw "SKILL_VALIDATE_FAIL: missing Publish-Online" }
  if ($hasOther -and -not (Test-Path (Join-Path $skillDir "scripts\Publish-Env.ps1"))) { throw "SKILL_VALIDATE_FAIL: missing Publish-Env" }
  $publishDoc = [System.IO.File]::ReadAllText((Join-Path $skillDir "references\publish.md"), [System.Text.Encoding]::UTF8)
  if (-not $hasLocal -and $publishDoc -match 'Publish-Local\.ps1') { throw "SKILL_VALIDATE_FAIL: publish.md references ungenerated Publish-Local" }
  if (-not $hasOnline -and $publishDoc -match 'Publish-Online\.ps1') { throw "SKILL_VALIDATE_FAIL: publish.md references ungenerated Publish-Online" }
  if (-not $hasOther -and $publishDoc -match 'Publish-Env\.ps1') { throw "SKILL_VALIDATE_FAIL: publish.md references ungenerated Publish-Env" }
  if ($publishDoc -match '(?m)^```\s*$[\r\n]+\s*```\s*$') { throw "SKILL_VALIDATE_FAIL: publish.md has an empty command block" }
}
if (-not $verifyEnabled) {
  if (Test-Path (Join-Path $skillDir "scripts\Invoke-Verify.ps1")) { throw "SKILL_VALIDATE_FAIL: unexpected Invoke-Verify.ps1" }
  if (Test-Path (Join-Path $skillDir "references\verify.md")) { throw "SKILL_VALIDATE_FAIL: unexpected verify.md" }
}
if (-not $setupEnabled) {
  if (Test-Path (Join-Path $skillDir "scripts\Init-Project.ps1")) { throw "SKILL_VALIDATE_FAIL: unexpected Init-Project.ps1" }
  if (Test-Path (Join-Path $skillDir "references\setup.md")) { throw "SKILL_VALIDATE_FAIL: unexpected setup.md" }
} else {
  if (-not (Test-Path (Join-Path $skillDir "scripts\Init-Project.ps1"))) { throw "SKILL_VALIDATE_FAIL: missing Init-Project.ps1" }
  if (-not (Test-Path (Join-Path $skillDir "references\setup.md"))) { throw "SKILL_VALIDATE_FAIL: missing setup.md" }
}

$stopBody = [System.IO.File]::ReadAllText((Join-Path $skillDir "scripts\Stop-Site.ps1"), [System.Text.Encoding]::UTF8)
if ($stopBody -match '(?m)^\s*' + [regex]::Escape($noneWord) + '\s*$') {
  throw "SKILL_VALIDATE_FAIL: Stop-Site injected literal none word"
}
Write-Host "STAGING_VALIDATE_OK"

# ---- commit staging into the repo --------------------------------------------------
$parentAgents = Join-Path $RepoRoot ".agents\skills"
if (-not (Test-Path -LiteralPath $parentAgents)) {
  New-Item -ItemType Directory -Force -Path $parentAgents | Out-Null
}
if (Test-Path -LiteralPath $finalSkillDir) {
  Remove-Item -LiteralPath $finalSkillDir -Recurse -Force
}
Move-Item -LiteralPath $skillDir -Destination $finalSkillDir
$skillDir = $finalSkillDir
Write-Host "PROMOTED_TO_REPO skill=$skillDir"

foreach ($sub in @("task", "tmp", "resource", "sql")) {
  $p = Join-Path $RepoRoot "$DocsRoot\$sub"
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

$gi = Join-Path $RepoRoot ".gitignore"
$linesToEnsure = @()
if ($skillLocal) {
  $linesToEnsure += ".agents/skills/"
} else {
  # shared skill: the skill itself is committed, but its runtime state must not be
  $linesToEnsure += (".agents/skills/" + $SkillName + "/.runtime/")
}
$linesToEnsure += ($DocsRoot + "/")
$existing = ""
if (Test-Path -LiteralPath $gi) { $existing = (Read-TextPreserveBom $gi).Text }
$append = @()
foreach ($line in $linesToEnsure) {
  $escaped = [regex]::Escape($line)
  if ($existing -notmatch ("(?m)^" + $escaped)) { $append += $line }
}
if ($append.Count -gt 0) {
  # append bytes instead of Add-Content: Windows PowerShell 5.1 writes a BOM when it
  # creates the file, and a BOM in .gitignore breaks the first pattern.
  $block = "# gengens-dev-skill-creator`r`n" + ($append -join "`r`n") + "`r`n"
  if ($existing.Trim().Length -eq 0) {
    [System.IO.File]::WriteAllText($gi, $block, $utf8NoBom)
  } else {
    [System.IO.File]::AppendAllText($gi, "`r`n" + $block, $utf8NoBom)
  }
  Write-Host ("GITIGNORE_ADDED=" + ($append -join ","))
}

$beginMark = '<!-- gengens-dev-skill-creator:begin -->'
$endMark = '<!-- gengens-dev-skill-creator:end -->'
$snippet = (Expand-Template ([System.IO.File]::ReadAllText((Join-Path $CreatorRoot "references\agents-md-snippet.md"), [System.Text.Encoding]::UTF8)) $map).Trim()
$agentsPath = Join-Path $RepoRoot "AGENTS.md"
if (Test-Path -LiteralPath $agentsPath) {
  $agentsFile = Read-TextPreserveBom $agentsPath
  $agentsBody = $agentsFile.Text
  $enc = if ($agentsFile.Bom) { $utf8Bom } else { $utf8NoBom }
  $pattern = '(?s)' + [regex]::Escape($beginMark) + '.*?' + [regex]::Escape($endMark)
  if ($agentsBody -match $pattern) {
    # replace, never skip: a re-run with a different skill name must not leave the old
    # skill name in AGENTS.md
    $replaced = [regex]::Replace($agentsBody, $pattern, { param($m) $snippet })
    [System.IO.File]::WriteAllText($agentsPath, $replaced, $enc)
    Write-Host "AGENTS_BLOCK_REPLACED"
  } else {
    [System.IO.File]::WriteAllText($agentsPath, $agentsBody + "`r`n`r`n" + $snippet + "`n", $enc)
    Write-Host "AGENTS_BLOCK_APPENDED"
  }
} else {
  [System.IO.File]::WriteAllText($agentsPath, $snippet + "`n", $utf8NoBom)
  Write-Host "AGENTS_BLOCK_CREATED"
}

Write-Host "SCAFFOLD_OK skill=$skillDir"
Write-Host "DOCS_OK root=$(Join-Path $RepoRoot $DocsRoot)"
Write-Host "PUBLISH_ENABLED=$publishEnabled local=$hasLocal online=$hasOnline other=$hasOther"
Write-Host "VERIFY_ENABLED=$verifyEnabled"
Write-Host "SKILL_VISIBILITY=$skillVisibility"
Write-Host ("ANSWER_READ_AS_NONE=" + (($script:NoneFields | ForEach-Object { $_ }) -join ","))
Write-Host "SKILL_VALIDATE_OK"
Write-Host "PROJECT_DEV_CREATOR_OK"
}
catch {
  if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "STAGING_CLEANED_ON_FAIL"
  }
  throw
}
finally {
  if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
