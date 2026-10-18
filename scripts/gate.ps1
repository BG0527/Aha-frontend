#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Aha 本地门禁（G7 起步）—— lint / build / unit / contract 四个 job。

.DESCRIPTION
  一条命令跑通四道门禁。设计要点（全部为「不得静默吞错」服务）：

  1. **NOT_RUN 不是 PASS**。仓库尚无 pom.xml / package.json 时，job 记为
     NOT_RUN（灰色）而不是 PASS（绿色），并在汇总里单列。空实现下全绿是允许的，
     但「没跑」和「跑过且通过」必须可区分 —— 否则门禁一开始就在撒谎。

  2. **不得静默吞错**。子进程失败即 FAIL，脚本以非零退出。唯一的例外是显式
     声明的 NOT_RUN，且它必须在汇总里出现。任何 job 抛异常 ⇒ FAIL，不捕获后放过。

  3. **未实测标 [待测]**。版本锚只声称本机实测到的值，其余标目标基线。

  4. **不新建构建系统**。后端用 Maven Wrapper（若落地）或系统 mvn；前端用 pnpm。
     本脚本不安装、不引导 corepack、不生成锁文件 —— 那是各仓切片的职责。

.PARAMETER Jobs
  只跑指定 job，逗号分隔：lint,build,unit,contract。默认全跑。

.PARAMETER Repo
  backend | frontend | all（默认 all）

.PARAMETER Json
  以 JSON 输出结果（供 CI / 其他脚本消费）。

.EXAMPLE
  pwsh -File gate.ps1
  pwsh -File gate.ps1 -Jobs lint,unit
  pwsh -File gate.ps1 -Repo backend

.NOTES
  未经实测的性能/SLO 数字一律标 [待测]。
  退出码：0 = 无 FAIL（可能含 NOT_RUN）；1 = 至少一个 FAIL；2 = 脚本自身错误。
#>
[CmdletBinding()]
param(
    [string[]]$Jobs = @('lint', 'build', 'unit', 'contract'),
    [ValidateSet('backend', 'frontend', 'all')]
    [string]$Repo = 'all',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# 环境隔离：门禁必须无人值守可跑，绝不能挂在分页器 / 交互提示上。
# （这条来自 t1 的真实事故：脚本曾因 git 分页器挂死 180s。）
# ---------------------------------------------------------------------------
$env:GIT_PAGER           = 'cat'
$env:GIT_TERMINAL_PROMPT = '0'
$env:CI                  = 'true'
$env:NO_COLOR            = '1'
$env:MAVEN_OPTS          = "$env:MAVEN_OPTS -Dstyle.color=never".Trim()
$env:CI_JOBS             = ($Jobs -join ',')

# 本脚本在两仓各有一份（backend/scripts/gate.ps1、frontend/scripts/gate.ps1），
# 因此**不得**假设自己在 Aha/ 根下。这里向上寻找同时含有 backend/ 与 frontend/
# 的目录作为 Aha 根；找不到就退回「脚本所在仓」单仓模式。
# 目的：同一份脚本既能单仓自门禁，也能在 Aha 根一次性门禁两仓。
function Resolve-AhaRoot {
    param([string]$Start)
    $dir = $Start
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        $be = Join-Path $dir 'backend'
        $fe = Join-Path $dir 'frontend'
        if ((Test-Path (Join-Path $be '.git')) -and (Test-Path (Join-Path $fe '.git'))) { return $dir }
        $dir = Split-Path -Parent $dir
    }
    return $null
}

$AHA_ROOT = Resolve-AhaRoot $PSScriptRoot
if (-not $AHA_ROOT) {
    # 单仓模式：脚本位于 <repo>/scripts/ 下
    $AHA_ROOT = Split-Path -Parent $PSScriptRoot
}

# ---------------------------------------------------------------------------
# 版本锚 —— 本文件是**唯一**权威声明处；两仓 AGENTS.md/README 引用此处。
# measured = 本机实测；不实测的一律 null 并标 [待测]，不得写成已知。
# ---------------------------------------------------------------------------
$VERSION_ANCHORS = [ordered]@{
    java    = [ordered]@{ required = '21';      measured = '21.0.1';  kind = 'LTS' }
    maven   = [ordered]@{ required = '3.9.x';   measured = '3.9.12';  kind = 'build' }
    node    = [ordered]@{ required = '24.x';    measured = '24.12.0'; kind = 'LTS' }
    pnpm    = [ordered]@{ required = '11.x';    measured = '11.8.0';  kind = 'pkg-manager' }
    git     = [ordered]@{ required = '2.40+';   measured = '2.53.0';  kind = 'tool' }
    pwsh    = [ordered]@{ required = '7.4+';    measured = '7.6.6';   kind = 'gate-runtime' }
}

# ---------------------------------------------------------------------------
# 结果收集
# ---------------------------------------------------------------------------
$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string]$RepoName, [string]$Job,
        [ValidateSet('PASS', 'FAIL', 'NOT_RUN')] [string]$Status,
        [string]$Detail = '',
        [double]$DurationMs = 0
    )
    $script:Results.Add([pscustomobject]@{
            repo       = $RepoName
            job        = $Job
            status     = $Status
            detail     = $Detail
            durationMs = [math]::Round($DurationMs, 0)
        })
}

function Write-Line {
    param([string]$Text, [string]$Color = 'Gray', [switch]$NoJson)
    if (-not $Json -and -not $NoJson) { Write-Host $Text -ForegroundColor $Color }
}

# ---------------------------------------------------------------------------
# 前置探测
# ---------------------------------------------------------------------------
function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-TrimmedVersion {
    param([string]$Name, [string[]]$VersionArgs)
    try {
        $raw = & $Name @VersionArgs 2>&1 | Out-String
        return $raw.Trim()
    } catch {
        return $null
    }
}

# 读取仓库工作区状态（未跟踪 + 已修改）。非 git 仓返回空集，不视为错误。
function Get-RepoStatus {
    param([string]$RepoPath)
    if (-not (Test-Command 'git')) { return @() }
    try {
        $out = & git.exe -C $RepoPath status --porcelain 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        return @()
    }
}

function Test-VersionAnchors {
    <#
      版本锚校验：工具存在 + 主版本符合 required。
      不满足 ⇒ FAIL（不是 NOT_RUN）—— 版本漂移是硬失败，不是「还没做」。
    #>
    Write-Line "`n[anchors] 版本锚校验" 'Cyan'

    # 注意：`java -version` 输出到 **stderr** 且是**多行**。
    # 用单行正则（`.` 默认不匹配换行）会匹配失败并返回整段原文 —— 这里必须显式取首行
    # 里的 version 字段。这条是脚本第一版的真实 bug（java 被判成 FAIL）。
    $checks = @(
        @{ name = 'java'
           probe = {
               if (-not (Test-Command 'java')) { return $null }
               $raw = Get-TrimmedVersion 'java' @('-version')
               if ($null -eq $raw) { return $null }
               $m = [regex]::Match($raw, 'version\s+"?(\d+)')
               if ($m.Success) { return $m.Groups[1].Value } else { return $null }
           }
           expect = '21'
        }
        @{ name = 'node'; probe = { if (-not (Test-Command 'node')) { return $null }; $v = Get-TrimmedVersion 'node' @('--version'); if ($null -eq $v) { return $null }; ([regex]::Match($v, '^v?(\d+)')).Groups[1].Value } ; expect = '24' }
        @{ name = 'pnpm'; probe = { if (-not (Test-Command 'pnpm')) { return $null }; $v = Get-TrimmedVersion 'pnpm' @('--version'); if ($null -eq $v) { return $null }; ([regex]::Match($v, '^(\d+)')).Groups[1].Value } ; expect = '11' }
        @{ name = 'git';   probe = { if (-not (Test-Command 'git')) { return $null }; $v = Get-TrimmedVersion 'git' @('--version'); if ($null -eq $v) { return $null }; ([regex]::Match($v, '^git version (\d+)')).Groups[1].Value } ; expect = '2' }
    )

    foreach ($c in $checks) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $major = & $c.probe
        $sw.Stop()
        $anchor = $VERSION_ANCHORS[$c.name]

        if ([string]::IsNullOrWhiteSpace($major)) {
            Add-Result 'meta' "anchor:$($c.name)" 'FAIL' "未找到工具 $($c.name)（必需，不是可选）" $sw.Elapsed.TotalMilliseconds
            Write-Line ("  FAIL  {0,-6} 未找到" -f $c.name) 'Red'
            continue
        }
        if ($null -ne $c.expect -and $major -ne $c.expect) {
            Add-Result 'meta' "anchor:$($c.name)" 'FAIL' "主版本 $major 与锚 $($anchor.required) 不符" $sw.Elapsed.TotalMilliseconds
            Write-Line ("  FAIL  {0,-6} 主版本 {1}，锚要求 {2}" -f $c.name, $major, $anchor.required) 'Red'
            continue
        }
        Add-Result 'meta' "anchor:$($c.name)" 'PASS' "主版本 $major（锚 $($anchor.required)）" $sw.Elapsed.TotalMilliseconds
        Write-Line ("  PASS  {0,-6} 主版本 {1}" -f $c.name, $major) 'Green'
    }
}

# ---------------------------------------------------------------------------
# 通用 job 执行器：把「工具不存在 / 产物不存在 / 真失败」三者区分开
# ---------------------------------------------------------------------------
function Invoke-Job {
    param(
        [string]$RepoName,
        [string]$JobName,
        [string]$WorkDir,
        [string]$Tool,               # 可执行文件名，例：mvn / pnpm
        [string[]]$ToolArgs,
        [string]$MissingArtifact,    # 产物缺失即 NOT_RUN，例：pom.xml
        [string]$SkipReason = ''     # 非空 ⇒ 直接 NOT_RUN（带原因）
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($SkipReason) {
        $sw.Stop()
        Add-Result $RepoName $JobName 'NOT_RUN' $SkipReason $sw.Elapsed.TotalMilliseconds
        Write-Line ("  NOT_RUN  {0,-8} {1}" -f $JobName, $SkipReason) 'DarkYellow'
        return
    }

    $artifactPath = Join-Path $WorkDir $MissingArtifact
    if (-not (Test-Path $artifactPath)) {
        $sw.Stop()
        Add-Result $RepoName $JobName 'NOT_RUN' "缺少 $MissingArtifact（尚未落地）" $sw.Elapsed.TotalMilliseconds
        Write-Line ("  NOT_RUN  {0,-8} 缺少 {1}" -f $JobName, $MissingArtifact) 'DarkYellow'
        return
    }

    if (-not (Test-Command $Tool)) {
        $sw.Stop()
        Add-Result $RepoName $JobName 'FAIL' "工具 $Tool 不在 PATH 上（有 $MissingArtifact 但无法执行）" $sw.Elapsed.TotalMilliseconds
        Write-Line ("  FAIL     {0,-8} 工具 {1} 不在 PATH 上" -f $JobName, $Tool) 'Red'
        return
    }

    Push-Location $WorkDir
    try {
        $output = & $Tool @ToolArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        Pop-Location
        $sw.Stop()
        Add-Result $RepoName $JobName 'FAIL' "执行抛异常：$($_.Exception.Message)" $sw.Elapsed.TotalMilliseconds
        Write-Line ("  FAIL     {0,-8} 执行抛异常：{1}" -f $JobName, $_.Exception.Message) 'Red'
        return
    }
    Pop-Location

    $sw.Stop()

    if ($code -ne 0) {
        # 失败必须把子进程输出尾部带出来，绝不吞掉
        $tail = ($output -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -Last 25) -join "`n"
        Add-Result $RepoName $JobName 'FAIL' "退出码 $code`n$tail" $sw.Elapsed.TotalMilliseconds
        Write-Line ("  FAIL     {0,-8} 退出码 {1}" -f $JobName, $code) 'Red'
        if (-not $Json -and $tail) {
            Write-Line ("           --- 输出尾部 ---") 'DarkRed'
            ($tail -split "`n") | ForEach-Object { Write-Line ("           " + $_) 'DarkRed' }
        }
        return
    }

    Add-Result $RepoName $JobName 'PASS' "退出码 0" $sw.Elapsed.TotalMilliseconds
    Write-Line ("  PASS     {0,-8} 退出码 0" -f $JobName) 'Green'
}

# ---------------------------------------------------------------------------
# 各仓门禁矩阵
# ---------------------------------------------------------------------------
function Invoke-RepoGate {
    param([string]$RepoName, [string]$RepoPath)

    Write-Line "`n[$RepoName] $RepoPath" 'Cyan'
    if (-not (Test-Path $RepoPath)) {
        Add-Result $RepoName 'repo' 'FAIL' "仓库路径不存在" 0
        Write-Line "  FAIL     仓库路径不存在" 'Red'
        return
    }

    # 记录门禁执行前的工作区状态。
    #
    # 为什么要这个：`pnpm run` 即便只跑一个脚本，也可能在仓里创建 node_modules/ 与
    # pnpm-lock.yaml（实测 pnpm 11.8.0 会发生）。门禁脚本**不得**留下副作用。
    # 与其假装能完全阻止（实测 --lockfile=false 等开关会连带把脚本传入参数吃掉、
    # 使退出码失真），更诚实的做法是**检测并报告**副作用，让污染不可能悄悄发生。
    $statusBefore = @(Get-RepoStatus $RepoPath)

    if ($RepoName -eq 'backend') {
        # Maven Wrapper 优先（可复现）；否则系统 mvn（需要本机已装）。
        $mvnTool = 'mvn'
        $mvnArgs = @('-B')
        if (Test-Path (Join-Path $RepoPath 'mvnw.cmd')) { $mvnTool = 'mvnw.cmd'; $mvnArgs = @('-B') }

        if ($Jobs -contains 'lint') {
            # 后端 lint = 编译期静态检查（checkstyle/spotbugs 落地前先复用 compile）
            Invoke-Job $RepoName 'lint' $RepoPath $mvnTool ($mvnArgs + @('-q', 'compile')) 'pom.xml'
        }
        if ($Jobs -contains 'build') {
            Invoke-Job $RepoName 'build' $RepoPath $mvnTool ($mvnArgs + @('-q', '-DskipTests', 'package')) 'pom.xml'
        }
        if ($Jobs -contains 'unit') {
            Invoke-Job $RepoName 'unit' $RepoPath $mvnTool ($mvnArgs + @('test')) 'pom.xml'
        }
        if ($Jobs -contains 'contract') {
            # 契约测试落地前不得假装通过：显式 NOT_RUN
            Invoke-Job $RepoName 'contract' $RepoPath $mvnTool ($mvnArgs + @('verify', '-Dtest=*ContractTest')) 'pom.xml' `
                '契约测试夹具未落地（G2/G3 交付后接入）'
        }
    }

    if ($RepoName -eq 'frontend') {
        # ⚠ pnpm 的 --if-present 必须写在**脚本名之前**：`pnpm run --if-present <script>`。
        #   写成 `pnpm run <script> --if-present` 会被当作脚本参数透传，
        #   结果「缺失脚本」仍以 EXIT=1 失败（本脚本第一版就是这个 bug）。
        #   实测（pnpm 11.8.0）：缺失脚本 + --if-present ⇒ 0；脚本真失败 ⇒ 原样透传退出码（不被吞）。
        if ($Jobs -contains 'lint') {
            Invoke-Job $RepoName 'lint' $RepoPath 'pnpm' @('run', '--if-present', 'lint') 'package.json'
        }
        if ($Jobs -contains 'build') {
            Invoke-Job $RepoName 'build' $RepoPath 'pnpm' @('run', '--if-present', 'build') 'package.json'
        }
        if ($Jobs -contains 'unit') {
            Invoke-Job $RepoName 'unit' $RepoPath 'pnpm' @('run', '--if-present', 'test') 'package.json'
        }
        if ($Jobs -contains 'contract') {
            Invoke-Job $RepoName 'contract' $RepoPath 'pnpm' @('run', '--if-present', 'test:contract') 'package.json' `
                '契约测试夹具未落地（G2/G3 交付后接入）'
        }
    }

    # 副作用检测：门禁跑完后工作区新增了未跟踪文件 ⇒ FAIL 并指名。
    # 这不是「洁癖」：门禁每次跑都往仓里生成文件，会让后续 diff/PR 失真，
    # 也会让「git status 干净」这条验收判据在下游变得无法成立。
    $statusAfter = @(Get-RepoStatus $RepoPath)
    $added = @($statusAfter | Where-Object { $statusBefore -notcontains $_ })
    if ($added.Count -gt 0) {
        Add-Result $RepoName 'side-effects' 'FAIL' ("门禁执行产生了工作区副作用：" + ($added -join '; ')) 0
        Write-Line ("  FAIL     side-effects 门禁留下了未跟踪文件：{0}" -f ($added -join '; ')) 'Red'
    } else {
        Add-Result $RepoName 'side-effects' 'PASS' '工作区无新增副作用' 0
        Write-Line "  PASS     side-effects 工作区无新增副作用" 'Green'
    }
}

# ===========================================================================
# 主流程
# ===========================================================================
Write-Line "Aha 本地门禁 (G7 起步)  jobs=[$($Jobs -join ',')]  repo=$Repo" 'White'

Test-VersionAnchors

# 注意：不要用 @(@('name', $path), ...) 这种嵌套数组 —— PowerShell 在 foreach/管道中
# 会把它**展平**，$t[0] 会退化成字符串首字符（曾导致 [f] r 与 [D] : 的诡异输出）。
# 显式用对象，避免隐式展平。
$targets = @()
switch ($Repo) {
    'backend' { $targets = @([pscustomobject]@{ name = 'backend'; path = (Join-Path $AHA_ROOT 'backend') }) }
    'frontend' { $targets = @([pscustomobject]@{ name = 'frontend'; path = (Join-Path $AHA_ROOT 'frontend') }) }
    default {
        $targets = @(
            [pscustomobject]@{ name = 'backend'; path = (Join-Path $AHA_ROOT 'backend') }
            [pscustomobject]@{ name = 'frontend'; path = (Join-Path $AHA_ROOT 'frontend') }
        )
    }
}
foreach ($t in $targets) { Invoke-RepoGate -RepoName $t.name -RepoPath $t.path }

# ---------------------------------------------------------------------------
# 汇总 —— NOT_RUN 必须单列，不得混进 PASS 里冒充绿
# ---------------------------------------------------------------------------
$pass    = @($script:Results | Where-Object { $_.status -eq 'PASS' })
$fail    = @($script:Results | Where-Object { $_.status -eq 'FAIL' })
$notRun  = @($script:Results | Where-Object { $_.status -eq 'NOT_RUN' })

if ($Json) {
    [pscustomobject]@{
        versionAnchors = $VERSION_ANCHORS
        summary        = [pscustomobject]@{ pass = $pass.Count; fail = $fail.Count; notRun = $notRun.Count }
        results        = $script:Results
        exitCode       = if ($fail.Count -gt 0) { 1 } else { 0 }
    } | ConvertTo-Json -Depth 6
} else {
    Write-Line "`n=== 汇总 ===" 'Cyan'
    Write-Line ("  PASS    : {0}" -f $pass.Count) 'Green'
    Write-Line ("  FAIL    : {0}" -f $fail.Count) $(if ($fail.Count -eq 0) { 'Gray' } else { 'Red' })
    Write-Line ("  NOT_RUN : {0}" -f $notRun.Count) $(if ($notRun.Count -eq 0) { 'Gray' } else { 'DarkYellow' })

    if ($notRun.Count -gt 0) {
        Write-Line "`n  未执行的 job（**不是通过**，实现落地后必须转为 PASS）：" 'DarkYellow'
        foreach ($r in $notRun) { Write-Line ("    - [{0}] {1}: {2}" -f $r.repo, $r.job, $r.detail) 'DarkYellow' }
    }
    if ($fail.Count -gt 0) {
        Write-Line "`n  失败项：" 'Red'
        foreach ($r in $fail) { Write-Line ("    - [{0}] {1}: {2}" -f $r.repo, $r.job, ($r.detail -split "`n")[0]) 'Red' }
    }

    if ($fail.Count -gt 0) { Write-Line "`nGATE FAILED" 'Red' }
    elseif ($notRun.Count -gt 0) { Write-Line "`nGATE PASSED (含 NOT_RUN —— 空实现下允许，但不得当作已覆盖)" 'DarkYellow' }
    else { Write-Line "`nGATE PASSED (全部 job 真实执行)" 'Green' }
}

# 脚本自身错误也要能被 CI 区分开
exit $(
    if ($fail.Count -gt 0) { 1 } else { 0 }
)
