$script:AgentMemoryIntegrationCommit = 'd60652a7058773fa9428fa720eda38942f12f014'
$script:AgentMemoryIntegrationFiles = @{
    'integrations/pi/index.ts' = '1e978990097ece72036b30eb0d24b3a26022a0d8276ea645fb47380c691d5f31'
    'integrations/pi/security.ts' = 'aec844b77a517f901c6ef88a67af673500485ffa428ceffd9142b9b9f3fe689f'
    'integrations/hermes/__init__.py' = '93929bce2b52f2f0740afdb4afd4b40b43fa8b8b7cbf7729ca4572ffa47ee7a8'
    'integrations/hermes/plugin.yaml' = '2cab5245618ac108f7271e54fe88d4efaeabf0c148ce1b4b7600b8d31afe132c'
    'plugin/plugin.json' = 'e183cd6e2363d4cd0f044f3092702772a8d6667c4059d272b40680e247df66a5'
    'plugin/hooks/hooks.copilot.json' = 'aa4d8ebb3ed83d4cef6aebf7aab5621846b8a60f8bf17f293a93126c55e2345b'
    'plugin/scripts/session-start.mjs' = 'e49a70368a3a21d0155bd3abcd0ff6d7b6dab2b7365c3d318bbfe7daa3b9a201'
    'plugin/scripts/prompt-submit.mjs' = '1a58ef754b1d81c9504c46d881a3dcb89ad2fc28d45a79f1025c0647f5f46fcc'
    'plugin/scripts/pre-tool-use.mjs' = '930f671169187ad50dfe0cdc14d9d25725f10083fd6e3915435493bdec197510'
    'plugin/scripts/post-tool-use.mjs' = '1c637ae4d30990405fcbda50d29d2c4956247142cf820c224c357c1407fa5d74'
    'plugin/scripts/post-tool-failure.mjs' = '3832c53f2aa99b26157811b0c78b76431e7e5d68d0c24c55f7ccb9a34d30bc8a'
    'plugin/scripts/pre-compact.mjs' = '4f0328ec0ffae1317f69b05701c3918a96679e180bcbf7f6e9113b6f3e0894ae'
    'plugin/scripts/stop.mjs' = '470b6116a24afaaeb67da98a599fa802b1e57ca00f0c65174d10edead071dd22'
    'plugin/scripts/session-end.mjs' = '5f6cbe370c3c5690c4d623da3aa705328be47b6d41ee48ab222cbc456bbc56c8'
    'plugin/scripts/subagent-start.mjs' = '3a1b3327a2f00f1fb8856f93a944a19eeccac53266ebb4266fc1b5b80c4e09d4'
    'plugin/scripts/subagent-stop.mjs' = '00bb1087d41c11fb26593cafa5a1b46d3a6f80e58ba418d7262379da59467a73'
    'plugin/scripts/notification.mjs' = '18fe4b5c2f546f115df75603f145c438de9640eaec44704ca6ceb630102aa024'
}
$script:CopilotHookScripts = @(
    'session-start.mjs',
    'prompt-submit.mjs',
    'pre-tool-use.mjs',
    'post-tool-use.mjs',
    'post-tool-failure.mjs',
    'pre-compact.mjs',
    'stop.mjs',
    'session-end.mjs',
    'subagent-start.mjs',
    'subagent-stop.mjs',
    'notification.mjs'
)
$script:PiManagedIndexSha256 = 'aaa362686d945eb8b05ed2261c9c97811cb48c97129c61c0ff62dfd2cd43ad42'
$script:HermesManagedProviderSha256 = 'eef0d03337ec6d6cb34b254f3b1ace9daa7b9135942f1c973be59af292e52467'
$script:AgentMemorySkillManifestSha256 = '45c8efb8bc65bbc0c4625ca5361b7f1e6f587d55e170cea4f19650064c993a8d'

function Get-AiStackTextSha256 {
    param([Parameter(Mandatory)][string]$Content)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Get-AiStackPinnedIntegration {
    param([Parameter(Mandatory)][string]$Path)

    $expectedHash = $script:AgentMemoryIntegrationFiles[$Path]
    if (-not $expectedHash) {
        throw "No pinned hash is registered for AgentMemory integration '$Path'."
    }

    $uri = "https://raw.githubusercontent.com/rohitg00/agentmemory/$($script:AgentMemoryIntegrationCommit)/$Path"
    $content = (Invoke-WebRequest -UseBasicParsing -Uri $uri).Content
    $actualHash = Get-AiStackTextSha256 -Content $content
    if ($actualHash -ne $expectedHash) {
        throw "AgentMemory integration '$Path' failed SHA-256 verification. Expected $expectedHash, received $actualHash."
    }
    return $content
}

function Get-AiStackGitBlobSha1 {
        param([Parameter(Mandatory)][string]$Content)

        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("blob $($contentBytes.Length)`0")
        $bytes = New-Object byte[] ($headerBytes.Length + $contentBytes.Length)
        [System.Buffer]::BlockCopy($headerBytes, 0, $bytes, 0, $headerBytes.Length)
        [System.Buffer]::BlockCopy($contentBytes, 0, $bytes, $headerBytes.Length, $contentBytes.Length)
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
        }
        finally {
            $sha.Dispose()
        }
    }

    function Get-AiStackPinnedSkills {
        $uri = "https://api.github.com/repos/rohitg00/agentmemory/git/trees/$($script:AgentMemoryIntegrationCommit)?recursive=1"
        $tree = Invoke-RestMethod -UseBasicParsing -Uri $uri
        $entries = @($tree.tree | Where-Object {
            $_.type -eq 'blob' -and $_.path -like 'plugin/skills/*'
        } | Sort-Object path)
        $manifest = (@($entries | ForEach-Object { "$($_.path)=$($_.sha)" }) -join "`n") + "`n"
        if ((Get-AiStackTextSha256 -Content $manifest) -ne $script:AgentMemorySkillManifestSha256) {
            throw 'The pinned AgentMemory skill tree did not match the reviewed manifest.'
        }

        $files = New-Object System.Collections.ArrayList
        foreach ($entry in $entries) {
            $content = (Invoke-WebRequest -UseBasicParsing -Uri (
                "https://raw.githubusercontent.com/rohitg00/agentmemory/$($script:AgentMemoryIntegrationCommit)/$($entry.path)"
            )).Content
            if ((Get-AiStackGitBlobSha1 -Content $content) -ne [string]$entry.sha) {
                throw "AgentMemory skill '$($entry.path)' failed Git blob verification."
            }
            [void]$files.Add([pscustomobject]@{
                RelativePath = $entry.path.Substring('plugin/skills/'.Length).Replace('/', '\')
                Content = $content
                BlobSha = [string]$entry.sha
            })
        }
        return [pscustomobject]@{ Files = @($files); Manifest = $manifest }
    }

    function Sync-AiStackPinnedSkills {
        param([Parameter(Mandatory)][string]$PluginRoot)

        $pinned = Get-AiStackPinnedSkills
        $skillsRoot = Join-Path $PluginRoot 'skills'
        $currentFiles = if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
            @(Get-ChildItem -LiteralPath $skillsRoot -Recurse -File | ForEach-Object {
                $_.FullName.Substring($skillsRoot.Length + 1)
            } | Where-Object { $_ -ne '.ai-stack-pinned-manifest' } | Sort-Object)
        }
        else {
            @()
        }
        $expectedFiles = @($pinned.Files.RelativePath | Sort-Object)
        $currentMatches = ($currentFiles -join "`n") -ceq ($expectedFiles -join "`n")
        if ($currentMatches) {
            foreach ($file in $pinned.Files) {
                $path = Join-Path $skillsRoot $file.RelativePath
                if ((Get-AiStackGitBlobSha1 -Content (
                    Get-Content -LiteralPath $path -Raw -Encoding UTF8
                )) -ne $file.BlobSha) {
                    $currentMatches = $false
                    break
                }
            }
        }
        $manifestPath = Join-Path $skillsRoot '.ai-stack-pinned-manifest'
        if ($currentMatches -and
            (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
            (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8) -ceq $pinned.Manifest) {
            return
        }

        if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            Copy-Item -LiteralPath $skillsRoot -Destination "$skillsRoot.ai-stack-backup-$stamp" -Recurse
            Remove-Item -LiteralPath $skillsRoot -Recurse -Force
        }
        foreach ($file in $pinned.Files) {
            Set-AiStackManagedFile `
                -Path (Join-Path $skillsRoot $file.RelativePath) `
                -Content $file.Content | Out-Null
        }
        Set-AiStackManagedFile -Path $manifestPath -Content $pinned.Manifest | Out-Null
    }

    function Test-AiStackPinnedSkills {
        param([Parameter(Mandatory)][string]$PluginRoot)

        $skillsRoot = Join-Path $PluginRoot 'skills'
        $manifestPath = Join-Path $skillsRoot '.ai-stack-pinned-manifest'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            return $false
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
        if ((Get-AiStackTextSha256 -Content $manifest) -ne $script:AgentMemorySkillManifestSha256) {
            return $false
        }
        $entries = @($manifest -split '\r?\n' | Where-Object { $_ } | ForEach-Object {
            $parts = $_ -split '=', 2
            [pscustomobject]@{
                RelativePath = $parts[0].Substring('plugin/skills/'.Length).Replace('/', '\')
                BlobSha = $parts[1]
            }
        })
        $actualFiles = @(Get-ChildItem -LiteralPath $skillsRoot -Recurse -File | ForEach-Object {
            $_.FullName.Substring($skillsRoot.Length + 1)
        } | Where-Object { $_ -ne '.ai-stack-pinned-manifest' } | Sort-Object)
        if (($actualFiles -join "`n") -cne (($entries.RelativePath | Sort-Object) -join "`n")) {
            return $false
        }
        foreach ($entry in $entries) {
            if ((Get-AiStackGitBlobSha1 -Content (
                Get-Content -LiteralPath (Join-Path $skillsRoot $entry.RelativePath) -Raw -Encoding UTF8
            )) -ne $entry.BlobSha) {
                return $false
            }
        }
        return $true
    }

function Set-AiStackManagedFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) -ceq $Content) {
        return $false
    }

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Backup-File -Path $Path
    Write-Utf8NoBom -Path $Path -Content $Content
    return $true
}

function Protect-AiStackSecretFile {
    param([Parameter(Mandatory)][string]$Path)

    if ($env:OS -ne 'Windows_NT') {
        return
    }
    $icacls = Get-Command icacls.exe -ErrorAction SilentlyContinue
    if (-not $icacls) {
        throw "Cannot protect '$Path' because icacls.exe is unavailable."
    }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = @(
        $Path,
        '/inheritance:r',
        '/grant:r',
        "*${currentSid}:F",
        '*S-1-5-18:F',
        '*S-1-5-32-544:F',
        '/Q'
    )
    & $icacls.Source @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not protect '$Path'."
    }
}

function Set-AiStackAgentMemoryEnvironment {
    param(
        [Parameter(Mandatory)][string]$Home,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][int]$Port,
        [switch]$SkipWindowsAcl
    )

    $path = Join-Path $Home '.agentmemory\.env'
    $content = @(
        "AGENTMEMORY_URL=http://localhost:$Port"
        "AGENTMEMORY_SECRET=$Secret"
        ''
    ) -join "`n"
    $existingBackups = @(
        Get-ChildItem -Path "$path.ai-stack-backup-*" -File -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    )
    $changed = Set-AiStackManagedFile -Path $path -Content $content
    if (-not $SkipWindowsAcl) {
        try {
            foreach ($secretFile in @(
                $path
                Get-ChildItem -Path "$path.ai-stack-backup-*" -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName
            )) {
                Protect-AiStackSecretFile -Path $secretFile
            }
        }
        catch {
            if ($changed) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                Get-ChildItem -Path "$path.ai-stack-backup-*" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notin $existingBackups } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    }
    return [pscustomobject]@{ Path = $path; Changed = $changed }
}

function Add-AiStackPiEnvironmentBootstrap {
    param([Parameter(Mandatory)][string]$Content)

    if ($Content.Contains('loadAiStackAgentMemoryEnv();')) {
        return $Content
    }

    $importAnchor = 'import crypto from "node:crypto";'
    if (-not $Content.Contains($importAnchor)) {
        throw 'The pinned pi integration does not contain the expected import anchor.'
    }
    $Content = $Content.Replace(
        $importAnchor,
        @'
import crypto from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
'@
    )

    $typeAnchor = 'type TextBlock = { type?: string; text?: string };'
    if (-not $Content.Contains($typeAnchor)) {
        throw 'The pinned pi integration does not contain the expected type anchor.'
    }
    $bootstrap = @'
function loadAiStackAgentMemoryEnv(): void {
  const envPath = path.join(homedir(), ".agentmemory", ".env");
  if (!existsSync(envPath)) return;

  for (const rawLine of readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator <= 0) continue;
    const key = line.slice(0, separator).trim();
    const value = line.slice(separator + 1).trim();
    if (!(key in process.env)) process.env[key] = value;
  }
}

loadAiStackAgentMemoryEnv();

'@
    return $Content.Replace($typeAnchor, "$bootstrap$typeAnchor")
}

function Get-AiStackCopilotEnvironmentRunner {
    return @'
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const scriptName = process.argv[2] || "";
if (!/^[a-z0-9-]+\.mjs$/i.test(scriptName) || scriptName === "ai-stack-runner.mjs") {
  throw new Error("Invalid AgentMemory hook script name.");
}

const envPath = path.join(homedir(), ".agentmemory", ".env");
if (existsSync(envPath)) {
  for (const rawLine of readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator <= 0) continue;
    const key = line.slice(0, separator).trim();
    const value = line.slice(separator + 1).trim();
    if (!(key in process.env)) process.env[key] = value;
  }
}

await import(new URL(`./${scriptName}`, import.meta.url));
'@
}

function Add-AiStackCopilotEnvironmentRunner {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$RunnerPath
    )

    $document = $Content | ConvertFrom-Json
    $changed = $false
    $managed = $false
    foreach ($event in $document.hooks.PSObject.Properties) {
        foreach ($hook in @($event.Value)) {
            $command = [string]$hook.command
            if ($command -match '^node \$\{COPILOT_PLUGIN_ROOT\}/scripts/(?<script>[a-z0-9-]+\.mjs)$') {
                $hook.command = 'node "{0}" {1}' -f $RunnerPath, $Matches['script']
                $changed = $true
            }
            elseif ($command -match '^node \$\{COPILOT_PLUGIN_ROOT\}/scripts/ai-stack-runner\.mjs (?<script>[a-z0-9-]+\.mjs)$') {
                $hook.command = 'node "{0}" {1}' -f $RunnerPath, $Matches['script']
                $changed = $true
            }
            elseif ($command.StartsWith(('node "{0}" ' -f $RunnerPath), [System.StringComparison]::Ordinal)) {
                $managed = $true
            }
        }
    }
    if (-not $changed -and -not $managed) {
        throw 'The installed Copilot AgentMemory hooks do not contain the expected commands.'
    }
    if (-not $changed) {
        return $Content
    }
    return ($document | ConvertTo-Json -Depth 20) + [Environment]::NewLine
}

function Get-AiStackCopilotPluginMcpConfig {
    param([Parameter(Mandatory)][string]$LauncherPath)

    $config = [ordered]@{
        mcpServers = [ordered]@{
            agentmemory = [ordered]@{
                type = 'local'
                command = 'powershell.exe'
                args = @(
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-File',
                    $LauncherPath
                )
                tools = @('*')
            }
        }
    }
    return ($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine
}

function Install-AiStackCopilotCapture {
    param(
        [Parameter(Mandatory)][string]$ClientHome,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][int]$Port,
        [switch]$SkipIfUnavailable
    )

    Install-AiStackClients -Client Copilot
    Set-AiStackAgentMemoryEnvironment -Home $ClientHome -Secret $Secret -Port $Port | Out-Null

    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $ClientHome '.copilot' }
    $configPath = Join-Path $copilotHome 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        if ($SkipIfUnavailable) {
            Write-Warning 'Copilot was not detected; skipping its capture integration.'
            return
        }
        throw "Copilot plugin configuration was not found at '$configPath'."
    }
    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $configText = [regex]::Replace($configText, '(?m)^\s*//.*(?:\r?\n|$)', '')
    $config = $configText | ConvertFrom-Json
    $pluginEntry = @($config.installedPlugins | Where-Object {
        $_.name -eq 'agentmemory' -and $_.enabled -ne $false
    } | Select-Object -First 1)
    if ($pluginEntry.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$pluginEntry[0].cache_path)) {
        throw 'The enabled Copilot AgentMemory plugin installation could not be located.'
    }

    $pluginRoot = [string]$pluginEntry[0].cache_path
    $manifestPath = Join-Path $pluginRoot 'plugin.json'
    $hooksPath = Join-Path $pluginRoot 'hooks\hooks.copilot.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $hooksPath -PathType Leaf)) {
        throw "The Copilot AgentMemory plugin at '$pluginRoot' is incomplete."
    }
    Set-AiStackManagedFile `
        -Path $manifestPath `
        -Content (Get-AiStackPinnedIntegration -Path 'plugin/plugin.json') | Out-Null
    $pluginMcpConfig = Get-AiStackCopilotPluginMcpConfig -LauncherPath $script:McpLauncherPath
    foreach ($mcpFile in @('.mcp.copilot.json', '.mcp.json')) {
        Set-AiStackManagedFile `
            -Path (Join-Path $pluginRoot $mcpFile) `
            -Content $pluginMcpConfig | Out-Null
    }
    Sync-AiStackPinnedSkills -PluginRoot $pluginRoot
    foreach ($scriptName in $script:CopilotHookScripts) {
        Set-AiStackManagedFile `
            -Path (Join-Path $pluginRoot "scripts\$scriptName") `
            -Content (Get-AiStackPinnedIntegration -Path "plugin/scripts/$scriptName") | Out-Null
    }

    $runnerPath = Join-Path $pluginRoot 'scripts\ai-stack-runner.mjs'
    Set-AiStackManagedFile `
        -Path $runnerPath `
        -Content (Get-AiStackCopilotEnvironmentRunner) | Out-Null
    $hooks = Get-AiStackPinnedIntegration -Path 'plugin/hooks/hooks.copilot.json'
    Set-AiStackManagedFile `
        -Path $hooksPath `
        -Content (Add-AiStackCopilotEnvironmentRunner -Content $hooks -RunnerPath $runnerPath) | Out-Null

    Write-Host 'Copilot AgentMemory hooks configured for authenticated live capture.'
    Write-Host 'Restart Copilot CLI/app; the app may require one-time plugin trust confirmation.'
}

function Merge-AiStackHermesMemoryProvider {
    param([Parameter(Mandatory)][string]$Content)

    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($Content -match '(?m)^memory:[ \t]*(?!#)\S') {
        throw 'Hermes uses an unsupported flow-style memory mapping. Convert it to a block mapping before installing AgentMemory.'
    }
    $memoryMatch = [regex]::Match(
        $Content,
        '(?m)^(?<header>memory:[ \t]*(?:#.*)?)\r?\n(?<body>(?:(?:^[ \t]+.*|^[ \t]*#.*|^[ \t]*$)(?:\r?\n|$))*)'
    )
    if (-not $memoryMatch.Success) {
        $prefix = if ($Content -and -not $Content.EndsWith("`n")) { $newline } else { '' }
        return "$Content${prefix}memory:${newline}  provider: agentmemory$newline"
    }

    $body = $memoryMatch.Groups['body'].Value
    $firstSetting = [regex]::Match($body, '(?m)^(?<indent>[ \t]+)[A-Za-z0-9_.-]+\s*:')
    $indent = if ($firstSetting.Success) { $firstSetting.Groups['indent'].Value } else { '  ' }
    $providerPattern = '(?m)^' + [regex]::Escape($indent) + 'provider\s*:.*$'
    $providerMatches = [regex]::Matches($body, $providerPattern)
    if ($providerMatches.Count -gt 1) {
        throw 'Hermes memory configuration contains duplicate provider keys. Resolve them before installing AgentMemory.'
    }
    if ($providerMatches.Count -eq 1) {
        $providerLine = [regex]::Match($body, $providerPattern).Value
        $providerValue = ($providerLine -split ':', 2)[1].Trim()
        if ($providerValue.StartsWith('>') -or $providerValue.StartsWith('|')) {
            throw 'Hermes uses an unsupported block-scalar memory provider. Replace it with a single-line provider value before installing AgentMemory.'
        }
        $updatedBody = [regex]::Replace(
            $body,
            $providerPattern,
            "${indent}provider: agentmemory",
            1
        )
    }
    else {
        $updatedBody = "${indent}provider: agentmemory$newline$body"
    }
    return $Content.Substring(0, $memoryMatch.Index) +
        $memoryMatch.Groups['header'].Value + $newline + $updatedBody +
        $Content.Substring($memoryMatch.Index + $memoryMatch.Length)
}

function Get-AiStackHermesMemoryProvider {
    param([Parameter(Mandatory)][string]$Content)

    if ($Content -match '(?m)^memory:[ \t]*(?!#)\S') {
        return $null
    }
    $memoryMatch = [regex]::Match(
        $Content,
        '(?m)^(?<header>memory:[ \t]*(?:#.*)?)\r?\n(?<body>(?:(?:^[ \t]+.*|^[ \t]*#.*|^[ \t]*$)(?:\r?\n|$))*)'
    )
    if (-not $memoryMatch.Success) {
        return $null
    }
    $body = $memoryMatch.Groups['body'].Value
    $firstSetting = [regex]::Match($body, '(?m)^(?<indent>[ \t]+)[A-Za-z0-9_.-]+\s*:')
    if (-not $firstSetting.Success) {
        return $null
    }
    $pattern = '(?m)^' + [regex]::Escape($firstSetting.Groups['indent'].Value) +
        'provider\s*:\s*(?<value>[^#\r\n]*?)\s*(?:#.*)?$'
    $providers = [regex]::Matches($body, $pattern)
    if ($providers.Count -ne 1) {
        return $null
    }
    $provider = $providers[0]
    $value = $provider.Groups['value'].Value.Trim()
    if ($value.StartsWith('>') -or $value.StartsWith('|')) {
        return $null
    }
    return $value.Trim('"').Trim("'")
}

function Add-AiStackHermesWindowsHome {
    param([Parameter(Mandatory)][string]$Content)

    $managed = 'candidates: list[Path] = [Path.home() / ".agentmemory" / ".env"]'
    if ($Content.Contains($managed)) {
        return $Content
    }
    $official = 'candidates: list[Path] = []'
    if (-not $Content.Contains($official)) {
        throw 'The pinned Hermes integration does not contain the expected environment-file candidate list.'
    }
    return $Content.Replace($official, $managed)
}

function Get-AiStackWslHomes {
    if ($env:AI_STACK_TEST_DISABLE_WSL -eq '1') {
        return @()
    }
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        return @()
    }
    $listResult = Invoke-AiStackNative -Command $wsl.Source -Arguments @('--list', '--quiet')
    if ($listResult.ExitCode -ne 0) {
        Write-Warning 'WSL distributions could not be listed; pi capture will only be installed on Windows.'
        return @()
    }

    $homes = New-Object System.Collections.ArrayList
    $distributions = @($listResult.Output | ForEach-Object {
        ([regex]::Replace([string]$_, "`0", '')).Trim()
    } | Where-Object {
        $_ -and $_ -notmatch '^docker-desktop' -and $_ -notmatch '[\\/:*?"<>|]'
    } | Select-Object -Unique)

    foreach ($distribution in $distributions) {
        $homeResult = Invoke-AiStackNative -Command $wsl.Source -Arguments @(
            '--distribution', $distribution, '--', 'sh', '-c',
            'printf "__AI_STACK_HOME__%s" "$HOME"'
        )
        if ($homeResult.ExitCode -ne 0) {
            Write-Warning "Cannot resolve the home directory for WSL distribution '$distribution'; skipping it."
            continue
        }
        $homeLine = @($homeResult.Output | ForEach-Object {
            ([regex]::Replace([string]$_, "`0", '')).Trim()
        } | Where-Object {
            $_ -match '^__AI_STACK_HOME__/'
        } | Select-Object -Last 1)
        if ($homeLine.Count -ne 1) {
            continue
        }
        $linuxHome = $homeLine[0].Substring('__AI_STACK_HOME__'.Length)
        if ($linuxHome -notmatch '^/[^\r\n]*$') {
            continue
        }
        $relativeHome = $linuxHome.Replace('/', '\')
        $windowsHome = "\\wsl.localhost\$distribution$relativeHome"
        if (-not (Test-Path -LiteralPath $windowsHome -PathType Container)) {
            $windowsHome = "\\wsl$\$distribution$relativeHome"
        }
        if (Test-Path -LiteralPath $windowsHome -PathType Container) {
            [void]$homes.Add([pscustomobject]@{
                Distribution = $distribution
                LinuxHome = $linuxHome
                WindowsHome = $windowsHome
            })
        }
    }
    return @($homes)
}

function Test-AiStackWslAgentMemoryReachable {
    param(
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][int]$Port
    )

    $probe = "curl -fsS --max-time 3 http://localhost:$Port/agentmemory/livez >/dev/null 2>/dev/null"
    $result = Invoke-AiStackNative -Command 'wsl.exe' -Arguments @(
        '--distribution', $Distribution, '--', 'sh', '-c', $probe
    )
    return ($result.ExitCode -eq 0)
}

function Protect-AiStackWslSecretFiles {
    param(
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$LinuxHome
    )

    $command = "chmod 600 `"$LinuxHome/.agentmemory/.env`" `"$LinuxHome/.agentmemory`"/.env.ai-stack-backup-* 2>/dev/null || chmod 600 `"$LinuxHome/.agentmemory/.env`""
    $result = Invoke-AiStackNative -Command 'wsl.exe' -Arguments @(
        '--distribution', $Distribution, '--', 'sh', '-c', $command
    )
    if ($result.ExitCode -ne 0) {
        throw "Could not protect the AgentMemory environment file in WSL distribution '$Distribution'."
    }
}

function Install-AiStackPiCapture {
    param(
        [Parameter(Mandatory)][string]$ClientHome,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][int]$Port
    )

    $index = Add-AiStackPiEnvironmentBootstrap -Content (
        Get-AiStackPinnedIntegration -Path 'integrations/pi/index.ts'
    )
    $security = Get-AiStackPinnedIntegration -Path 'integrations/pi/security.ts'
    $installed = New-Object System.Collections.ArrayList

    $windowsAgentRoot = Join-Path $ClientHome '.pi\agent'
    if (Test-Path -LiteralPath $windowsAgentRoot -PathType Container) {
        Set-AiStackAgentMemoryEnvironment -Home $ClientHome -Secret $Secret -Port $Port | Out-Null
        $extension = Join-Path $windowsAgentRoot 'extensions\agentmemory'
        Set-AiStackManagedFile -Path (Join-Path $extension 'index.ts') -Content $index | Out-Null
        Set-AiStackManagedFile -Path (Join-Path $extension 'security.ts') -Content $security | Out-Null
        [void]$installed.Add("Windows: $extension")
    }

    foreach ($home in @(Get-AiStackWslHomes)) {
        $agentRoot = Join-Path $home.WindowsHome '.pi\agent'
        if (-not (Test-Path -LiteralPath $agentRoot -PathType Container)) {
            continue
        }
        if (-not (Test-AiStackWslAgentMemoryReachable -Distribution $home.Distribution -Port $Port)) {
            Write-Warning "WSL distribution '$($home.Distribution)' cannot reach AgentMemory on Windows localhost. Enable WSL mirrored networking and start the stack before rerunning install-capture -Agent Pi."
            continue
        }
        $wslEnvironmentPath = Join-Path $home.WindowsHome '.agentmemory\.env'
        $hadEnvironment = Test-Path -LiteralPath $wslEnvironmentPath -PathType Leaf
        $previousEnvironment = if ($hadEnvironment) {
            Get-Content -LiteralPath $wslEnvironmentPath -Raw -Encoding UTF8
        }
        else {
            $null
        }
        $existingBackups = @(
            Get-ChildItem -Path "$wslEnvironmentPath.ai-stack-backup-*" -File -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName
        )
        try {
            Set-AiStackAgentMemoryEnvironment `
                -Home $home.WindowsHome `
                -Secret $Secret `
                -Port $Port `
                -SkipWindowsAcl | Out-Null
            Protect-AiStackWslSecretFiles `
                -Distribution $home.Distribution `
                -LinuxHome $home.LinuxHome
            $extension = Join-Path $agentRoot 'extensions\agentmemory'
            Set-AiStackManagedFile -Path (Join-Path $extension 'index.ts') -Content $index | Out-Null
            Set-AiStackManagedFile -Path (Join-Path $extension 'security.ts') -Content $security | Out-Null
        }
        catch {
            $failure = $_
            Get-ChildItem -Path "$wslEnvironmentPath.ai-stack-backup-*" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notin $existingBackups } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if ($hadEnvironment) {
                Write-Utf8NoBom -Path $wslEnvironmentPath -Content $previousEnvironment
                try {
                    Protect-AiStackWslSecretFiles `
                        -Distribution $home.Distribution `
                        -LinuxHome $home.LinuxHome
                }
                catch {
                    Remove-Item -LiteralPath $wslEnvironmentPath -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                Remove-Item -LiteralPath $wslEnvironmentPath -Force -ErrorAction SilentlyContinue
            }
            throw $failure.Exception
        }
        [void]$installed.Add("WSL $($home.Distribution): $extension")
    }

    if ($installed.Count -eq 0) {
        Write-Warning 'No pi installation was detected. Install pi first, then rerun install-capture -Agent Pi.'
        return
    }
    Write-Host 'pi AgentMemory capture installed:'
    $installed | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Restart pi to activate the extension.'
}

function Get-AiStackHermesHome {
    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_HOME)) {
        return [System.IO.Path]::GetFullPath($env:HERMES_HOME)
    }
    $localAppData = if ($env:AI_STACK_TEST_ROOT) {
        Join-Path $env:AI_STACK_TEST_ROOT 'local'
    }
    else {
        $env:LOCALAPPDATA
    }
    return Join-Path $localAppData 'hermes'
}

function Install-AiStackHermesCapture {
    param(
        [Parameter(Mandatory)][string]$ClientHome,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][int]$Port
    )

    $hermesHome = Get-AiStackHermesHome
    $configPath = Join-Path $hermesHome 'config.yaml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-Warning "Hermes was not detected at '$hermesHome'. Install Hermes first, then rerun install-capture -Agent Hermes."
        return
    }

    Set-AiStackAgentMemoryEnvironment -Home $ClientHome -Secret $Secret -Port $Port | Out-Null
    $plugin = Join-Path $hermesHome 'plugins\agentmemory'
    Set-AiStackManagedFile `
        -Path (Join-Path $plugin '__init__.py') `
        -Content (Add-AiStackHermesWindowsHome -Content (
            Get-AiStackPinnedIntegration -Path 'integrations/hermes/__init__.py'
        )) | Out-Null
    Set-AiStackManagedFile `
        -Path (Join-Path $plugin 'plugin.yaml') `
        -Content (Get-AiStackPinnedIntegration -Path 'integrations/hermes/plugin.yaml') | Out-Null

    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $updated = Merge-AiStackHermesMemoryProvider -Content $config
    Set-AiStackManagedFile -Path $configPath -Content $updated | Out-Null

    Write-Host "Hermes AgentMemory capture installed at '$plugin'."
    Write-Host 'Restart Hermes to activate the memory provider.'
}

function Install-AiStackCapture {
    param(
        [ValidateSet('All', 'Copilot', 'Pi', 'Hermes')]
        [string]$Agent = 'All',
        [string]$ClientHome = $script:ClientHome
    )

    Assert-AiStackEnvExists
    if (-not (Test-Path -LiteralPath $script:AgentMemorySecretPath -PathType Leaf)) {
        throw 'AgentMemory secret is missing. Run setup before install-capture.'
    }
    $secret = [System.IO.File]::ReadAllText($script:AgentMemorySecretPath).Trim()
    if ([string]::IsNullOrWhiteSpace($secret)) {
        throw 'AgentMemory secret is empty. Run setup before install-capture.'
    }
    $values = Get-DotEnvValues -Path $script:EnvPath
    $port = if ($values.ContainsKey('AGENTMEMORY_REST_PORT')) {
        [int]$values['AGENTMEMORY_REST_PORT']
    }
    else {
        3111
    }
    $targets = if ($Agent -eq 'All') { @('Copilot', 'Pi', 'Hermes') } else { @($Agent) }

    foreach ($target in $targets) {
        try {
            switch ($target) {
                'Copilot' {
                    Install-AiStackCopilotCapture `
                        -ClientHome $ClientHome `
                        -Secret $secret `
                        -Port $port `
                        -SkipIfUnavailable:($Agent -eq 'All')
                }
                'Pi' {
                    Install-AiStackPiCapture -ClientHome $ClientHome -Secret $secret -Port $port
                }
                'Hermes' {
                    Install-AiStackHermesCapture -ClientHome $ClientHome -Secret $secret -Port $port
                }
            }
        }
        catch {
            if ($Agent -ne 'All') {
                throw
            }
            Write-Warning "$target capture could not be installed; continuing with the other agents. $($_.Exception.Message)"
        }
    }
}

function Test-AiStackCaptureEnvironment {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][int]$Port
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $values = Get-DotEnvValues -Path $Path
    return $values['AGENTMEMORY_URL'] -eq "http://localhost:$Port" -and
        $values['AGENTMEMORY_SECRET'] -ceq $Secret
}

function Get-AiStackCaptureDoctorResults {
    $results = New-Object System.Collections.ArrayList
    $environmentPath = Join-Path $script:ClientHome '.agentmemory\.env'
    $stackValues = Get-DotEnvValues -Path $script:EnvPath
    $port = if ($stackValues.ContainsKey('AGENTMEMORY_REST_PORT')) {
        [int]$stackValues['AGENTMEMORY_REST_PORT']
    }
    else {
        3111
    }
    $secret = if (Test-Path -LiteralPath $script:AgentMemorySecretPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($script:AgentMemorySecretPath).Trim()
    }
    else {
        ''
    }

    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $script:ClientHome '.copilot' }
    $copilotConfigPath = Join-Path $copilotHome 'config.json'
    if (-not (Test-Path -LiteralPath $copilotConfigPath -PathType Leaf)) {
        [void]$results.Add((New-DoctorResult -Name 'Copilot capture' -Status 'WARN' -Detail 'Copilot plugin installation not detected'))
    }
    else {
        try {
            $configText = Get-Content -LiteralPath $copilotConfigPath -Raw -Encoding UTF8
            $configText = [regex]::Replace($configText, '(?m)^\s*//.*(?:\r?\n|$)', '')
            $config = $configText | ConvertFrom-Json
            $entry = @($config.installedPlugins | Where-Object {
                $_.name -eq 'agentmemory' -and $_.enabled -ne $false
            } | Select-Object -First 1)
            $pluginRoot = if ($entry.Count -eq 1) { [string]$entry[0].cache_path } else { '' }
            $runner = if ($pluginRoot) { Join-Path $pluginRoot 'scripts\ai-stack-runner.mjs' } else { '' }
            $hooks = if ($pluginRoot) { Join-Path $pluginRoot 'hooks\hooks.copilot.json' } else { '' }
            $pluginMcpPaths = if ($pluginRoot) {
                @('.mcp.copilot.json', '.mcp.json') | ForEach-Object {
                    Join-Path $pluginRoot $_
                }
            }
            else {
                @()
            }
            $runnerValid = $runner -and
                (Test-Path -LiteralPath $runner -PathType Leaf) -and
                (Get-Content -LiteralPath $runner -Raw -Encoding UTF8) -ceq (Get-AiStackCopilotEnvironmentRunner)
            $expectedMcpConfig = Get-AiStackCopilotPluginMcpConfig -LauncherPath $script:McpLauncherPath
            $mcpValid = $pluginMcpPaths.Count -eq 2 -and
                @($pluginMcpPaths | Where-Object {
                    -not (Test-Path -LiteralPath $_ -PathType Leaf) -or
                    (Get-Content -LiteralPath $_ -Raw -Encoding UTF8) -cne $expectedMcpConfig
                }).Count -eq 0
            $hooksValid = $false
            if ($runnerValid -and (Test-Path -LiteralPath $hooks -PathType Leaf)) {
                $hooksDocument = Get-Content -LiteralPath $hooks -Raw -Encoding UTF8 | ConvertFrom-Json
                $commands = @($hooksDocument.hooks.PSObject.Properties | ForEach-Object {
                    $_.Value | ForEach-Object { [string]$_.command }
                })
                $expectedCommands = @($script:CopilotHookScripts | ForEach-Object {
                    'node "{0}" {1}' -f $runner, $_
                })
                $hooksValid = ($commands | Sort-Object) -join "`n" -ceq
                    (($expectedCommands | Sort-Object) -join "`n")
            }
            $scriptsValid = $pluginRoot -and (@($script:CopilotHookScripts | Where-Object {
                $path = Join-Path $pluginRoot "scripts\$_"
                -not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-AiStackTextSha256 -Content (Get-Content -LiteralPath $path -Raw -Encoding UTF8)) -ne
                    $script:AgentMemoryIntegrationFiles["plugin/scripts/$_"]
            }).Count -eq 0)
            $manifestValid = $pluginRoot -and
                (Get-AiStackTextSha256 -Content (
                    Get-Content -LiteralPath (Join-Path $pluginRoot 'plugin.json') -Raw -Encoding UTF8
                )) -eq $script:AgentMemoryIntegrationFiles['plugin/plugin.json']
            $skillsValid = $pluginRoot -and (Test-AiStackPinnedSkills -PluginRoot $pluginRoot)
            $environmentValid = $secret -and
                (Test-AiStackCaptureEnvironment -Path $environmentPath -Secret $secret -Port $port)
            if ($runnerValid -and $mcpValid -and $hooksValid -and $scriptsValid -and
                $manifestValid -and $skillsValid -and $environmentValid) {
                [void]$results.Add((New-DoctorResult -Name 'Copilot capture' -Status 'PASS' -Detail 'authenticated pinned AgentMemory hooks are installed'))
            }
            else {
                [void]$results.Add((New-DoctorResult -Name 'Copilot capture' -Status 'WARN' -Detail 'run install-capture -Agent Copilot'))
            }
        }
        catch {
            [void]$results.Add((New-DoctorResult -Name 'Copilot capture' -Status 'WARN' -Detail 'Copilot capture files could not be validated'))
        }
    }

    $piHomes = New-Object System.Collections.ArrayList
    $windowsPi = Join-Path $script:ClientHome '.pi\agent'
    if (Test-Path -LiteralPath $windowsPi -PathType Container) {
        [void]$piHomes.Add([pscustomobject]@{
            AgentRoot = $windowsPi
            Environment = $environmentPath
            Distribution = ''
        })
    }
    foreach ($home in @(Get-AiStackWslHomes)) {
        $agentRoot = Join-Path $home.WindowsHome '.pi\agent'
        if (Test-Path -LiteralPath $agentRoot -PathType Container) {
            [void]$piHomes.Add([pscustomobject]@{
                AgentRoot = $agentRoot
                Environment = Join-Path $home.WindowsHome '.agentmemory\.env'
                Distribution = $home.Distribution
            })
        }
    }
    if ($piHomes.Count -eq 0) {
        [void]$results.Add((New-DoctorResult -Name 'pi capture' -Status 'WARN' -Detail 'pi profile not detected'))
    }
    else {
        $incompletePi = @($piHomes | Where-Object {
            $indexPath = Join-Path $_.AgentRoot 'extensions\agentmemory\index.ts'
            $securityPath = Join-Path $_.AgentRoot 'extensions\agentmemory\security.ts'
            -not (Test-Path -LiteralPath $indexPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $securityPath -PathType Leaf) -or
            (Get-AiStackTextSha256 -Content (Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8)) -ne
                $script:PiManagedIndexSha256 -or
            (Get-AiStackTextSha256 -Content (Get-Content -LiteralPath $securityPath -Raw -Encoding UTF8)) -ne
                $script:AgentMemoryIntegrationFiles['integrations/pi/security.ts'] -or
            -not (Test-AiStackCaptureEnvironment -Path $_.Environment -Secret $secret -Port $port) -or
            ($_.Distribution -and -not (Test-AiStackWslAgentMemoryReachable -Distribution $_.Distribution -Port $port))
        })
        if ($incompletePi.Count -eq 0) {
            [void]$results.Add((New-DoctorResult -Name 'pi capture' -Status 'PASS' -Detail "installed in $($piHomes.Count) reachable profile(s)"))
        }
        else {
            [void]$results.Add((New-DoctorResult -Name 'pi capture' -Status 'WARN' -Detail 'run install-capture -Agent Pi'))
        }
    }

    $hermesHome = Get-AiStackHermesHome
    $hermesConfig = Join-Path $hermesHome 'config.yaml'
    if (-not (Test-Path -LiteralPath $hermesConfig -PathType Leaf)) {
        [void]$results.Add((New-DoctorResult -Name 'Hermes capture' -Status 'WARN' -Detail 'Hermes installation not detected'))
    }
    else {
        $provider = Join-Path $hermesHome 'plugins\agentmemory\__init__.py'
        $pluginManifest = Join-Path $hermesHome 'plugins\agentmemory\plugin.yaml'
        $config = Get-Content -LiteralPath $hermesConfig -Raw -Encoding UTF8
        if ((Test-Path -LiteralPath $provider -PathType Leaf) -and
            (Get-AiStackTextSha256 -Content (Get-Content -LiteralPath $provider -Raw -Encoding UTF8)) -eq
                $script:HermesManagedProviderSha256 -and
            (Test-Path -LiteralPath $pluginManifest -PathType Leaf) -and
            (Get-AiStackTextSha256 -Content (Get-Content -LiteralPath $pluginManifest -Raw -Encoding UTF8)) -eq
                $script:AgentMemoryIntegrationFiles['integrations/hermes/plugin.yaml'] -and
            (Test-AiStackCaptureEnvironment -Path $environmentPath -Secret $secret -Port $port) -and
            (Get-AiStackHermesMemoryProvider -Content $config) -eq 'agentmemory') {
            [void]$results.Add((New-DoctorResult -Name 'Hermes capture' -Status 'PASS' -Detail 'AgentMemory is the selected memory provider'))
        }
        else {
            [void]$results.Add((New-DoctorResult -Name 'Hermes capture' -Status 'WARN' -Detail 'run install-capture -Agent Hermes'))
        }
    }
    return @($results)
}
