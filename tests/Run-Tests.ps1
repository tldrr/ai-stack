[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'scripts\AiStack.psm1'
$failures = New-Object System.Collections.ArrayList
$testCount = 0

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $script:testCount++
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        [void]$script:failures.Add("$Name`: $($_.Exception.Message)")
        Write-Host "FAIL $Name" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Expected condition to be true.')
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = 'Values differ.')
    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-stack-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$previousComposeProjectName = [Environment]::GetEnvironmentVariable('COMPOSE_PROJECT_NAME', 'Process')
Remove-Item Env:\COMPOSE_PROJECT_NAME -ErrorAction SilentlyContinue

try {
    Copy-Item (Join-Path $repoRoot '.env.example') (Join-Path $tempRoot '.env.example')
    $examplePath = Join-Path $tempRoot '.env.example'
    $example = [System.IO.File]::ReadAllText($examplePath)
    $example = [regex]::Replace(
        $example,
        '(?m)^COMPOSE_PROJECT_NAME=.*$',
        "COMPOSE_PROJECT_NAME=ai-stack-tests-$([guid]::NewGuid().ToString('N'))"
    )
    [System.IO.File]::WriteAllText($examplePath, $example, (New-Object System.Text.UTF8Encoding($false)))
    $testDataPath = Join-Path $tempRoot 'home\.ai-stack'
    $testClientHome = Join-Path $tempRoot 'clients'
    New-Item -ItemType Directory -Path (Split-Path $testDataPath -Parent) | Out-Null
    $env:AI_STACK_TEST_ROOT = $tempRoot
    $env:AI_STACK_TEST_DATA_PATH = $testDataPath
    $env:AI_STACK_TEST_CLIENT_HOME = $testClientHome
    Import-Module $modulePath -Force

    Invoke-Test 'PowerShell files parse cleanly' {
        $parseErrors = @()
        Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1' | ForEach-Object {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
            $parseErrors += $errors
        }
        Assert-Equal 0 $parseErrors.Count ($parseErrors -join [Environment]::NewLine)
    }

    Invoke-Test 'AgentMemory image includes local embeddings' {
        $dockerfile = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docker\agentmemory\Dockerfile'))
        Assert-True ($dockerfile -notmatch '--omit=optional') 'The image omits AgentMemory local embedding dependencies.'
        Assert-True ($dockerfile -match '@agentmemory/agentmemory@\$\{AGENTMEMORY_VERSION\}') 'AgentMemory is not version-pinned at build time.'
    }

    Invoke-Test 'AgentMemory shutdown preserves buffered state' {
        $entrypoint = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docker\agentmemory\entrypoint.sh'))
        $compose = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'compose.yaml'))
        Assert-True ($entrypoint -match 'AGENTMEMORY_DATA_DIR') 'The persistent AgentMemory data directory is not explicit.'
        Assert-True ($entrypoint -match 'trap shutdown TERM INT') 'The entrypoint does not handle Docker shutdown signals.'
        Assert-True ($entrypoint -match 'iii\.pid') 'The detached iii engine is not included in graceful shutdown.'
        Assert-True ($compose -match '(?ms)^\s{2}agentmemory:.*?^\s{4}stop_grace_period:\s*30s') 'AgentMemory does not have enough time for state flush.'
    }

    Invoke-Test 'Docker data persists under the local state directory' {
        $compose = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'compose.yaml'))
        Assert-True ($compose -match 'GITHUB_COPILOT_TOKEN_DIR:\s*/var/lib/litellm/github-copilot') 'LiteLLM does not write Copilot credentials to the mounted directory.'
        Assert-True ($compose -match 'source:\s*\$\{AI_STACK_HOME:.*\}/data/github-copilot') 'Copilot credentials are not persisted under the home .ai-stack.'
        Assert-True ($compose -match 'source:\s*\$\{AI_STACK_HOME:.*\}/data/agentmemory') 'AgentMemory data is not persisted under the home .ai-stack.'
        Assert-True ($compose -notmatch '(?m)^volumes:\s*$') 'Compose still declares named volumes.'
    }

    Invoke-Test 'Setup is idempotent and generates local secrets' {
        Copy-Item $examplePath (Join-Path $tempRoot '.env')
        $legacyState = Join-Path $tempRoot '.state'
        New-Item -ItemType Directory -Path $legacyState | Out-Null
        'legacy launcher' | Set-Content -LiteralPath (Join-Path $legacyState 'agentmemory-mcp.ps1')
        $copilotConfig = Join-Path $testClientHome '.copilot\mcp-config.json'
        $codexConfig = Join-Path $testClientHome '.codex\config.toml'
        New-Item -ItemType Directory -Path (Split-Path $copilotConfig -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $codexConfig -Parent) -Force | Out-Null
        '{"mcpServers":{"agentmemory":{"command":"powershell.exe","args":["-File","C:\\old\\agentmemory-mcp.ps1"]}}}' |
            Set-Content -LiteralPath $copilotConfig -Encoding UTF8
        "[mcp_servers.agentmemory]`ncommand = `"powershell.exe`"`nargs = [`"-File`", `"C:\\old\\agentmemory-mcp.ps1`"]" |
            Set-Content -LiteralPath $codexConfig -Encoding UTF8

        Initialize-AiStackConfiguration
        $envBefore = [System.IO.File]::ReadAllText((Join-Path $testDataPath '.env'))
        $secretBefore = [System.IO.File]::ReadAllText((Join-Path $testDataPath 'agentmemory-secret'))
        Initialize-AiStackConfiguration
        $envAfter = [System.IO.File]::ReadAllText((Join-Path $testDataPath '.env'))
        $secretAfter = [System.IO.File]::ReadAllText((Join-Path $testDataPath 'agentmemory-secret'))

        Assert-Equal $envBefore $envAfter 'Setup changed .env on the second run.'
        Assert-Equal $secretBefore $secretAfter 'Setup rotated the AgentMemory secret.'
        Assert-True ($envBefore -notmatch 'change-me-generated-by-setup') 'LiteLLM placeholder was not replaced.'
        Assert-True ($secretBefore -match '^am_[0-9a-f]{64}$') 'AgentMemory secret has the wrong format.'
        Assert-True (-not (Test-Path (Join-Path $tempRoot '.env'))) 'Legacy .env was not removed.'
        Assert-True (-not (Test-Path (Join-Path $tempRoot '.state'))) 'Legacy .state was not removed.'
        Assert-True (Test-Path (Join-Path $testDataPath 'agentmemory-mcp.ps1')) 'MCP launcher was not consolidated.'
        Assert-True (Test-Path (Join-Path $testDataPath 'data\agentmemory')) 'AgentMemory data directory was not created.'
        Assert-True (Test-Path (Join-Path $testDataPath 'data\github-copilot')) 'Copilot data directory was not created.'
        Assert-True ($envBefore -match '(?m)^AI_STACK_HOME=.+/home/\.ai-stack$') 'The Docker-compatible home path was not generated.'
        $updatedCopilot = [System.IO.File]::ReadAllText($copilotConfig) | ConvertFrom-Json
        Assert-Equal (Join-Path $testDataPath 'agentmemory-mcp.ps1') $updatedCopilot.mcpServers.agentmemory.args[-1] 'Copilot retained the legacy launcher path.'
        Assert-True ([System.IO.File]::ReadAllText($codexConfig) -match [regex]::Escape($testDataPath.Replace('\', '\\'))) 'Codex retained the legacy launcher path.'
        if ($env:OS -eq 'Windows_NT') {
            Assert-True ((Get-Acl $testDataPath).AreAccessRulesProtected) '.ai-stack still inherits permissions from its parent.'
            $allowed = @((Get-Acl $testDataPath).Access | ForEach-Object { $_.IdentityReference.Value })
            Assert-Equal 3 $allowed.Count 'The home state ACL contains unexpected explicit principals.'
        }
    }

    Invoke-Test 'Cloudflare config generation is safe and idempotent' {
        $configPath = Join-Path $testDataPath 'cloudflared\config.yml'
        $tunnelId = '245b35f7-4ee8-4d7f-a39a-5ad80c128f51'
        Assert-True (New-CloudflareTunnelConfig `
            -TunnelId $tunnelId `
            -RestHostname 'memory-api.example.com' `
            -ViewerHostname 'memory.example.com' `
            -Path $configPath)
        $first = [System.IO.File]::ReadAllText($configPath)
        Assert-True (-not (New-CloudflareTunnelConfig `
            -TunnelId $tunnelId `
            -RestHostname 'memory-api.example.com' `
            -ViewerHostname 'memory.example.com' `
            -Path $configPath)) 'Second config generation reported a change.'
        Assert-Equal $first ([System.IO.File]::ReadAllText($configPath))
        Assert-True ($first -match 'credentials-file: /etc/cloudflared/credentials\.json') 'Container credential path is missing.'
        Assert-True ($first -match 'service: http://agentmemory:3111') 'REST ingress is missing.'
        Assert-True ($first -match 'service: http://agentmemory:3113') 'Viewer ingress is missing.'
        Assert-True ($first -match '(?m)^  - service: http_status:404\r?$') 'Catch-all ingress is missing.'

        $failed = $false
        try {
            [void](New-CloudflareTunnelConfig `
                -TunnelId $tunnelId `
                -RestHostname 'bad hostname' `
                -ViewerHostname 'memory.example.com' `
                -Path $configPath)
        }
        catch {
            $failed = $true
        }
        Assert-True $failed 'Invalid hostnames were accepted.'
    }

    Invoke-Test 'Empty Cloudflare tunnel lists are handled' {
        $module = Get-Module AiStack
        $emptyMatches = @(& $module {
            @(Find-CloudflareTunnelsByName -Tunnels $null -Name 'ai-stack')
        })
        Assert-Equal 0 $emptyMatches.Count 'An empty tunnel list produced a match.'

        $tunnels = @(
            [pscustomobject]@{ name = 'other' },
            [pscustomobject]@{ name = 'ai-stack' }
        )
        $matches = @(& $module {
            param($items)
            @(Find-CloudflareTunnelsByName -Tunnels $items -Name 'ai-stack')
        } $tunnels)
        Assert-Equal 1 $matches.Count 'The requested tunnel was not selected exactly once.'
    }

    Invoke-Test 'Compose uses local Cloudflare config without a token' {
        $compose = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'compose.yaml'))
        $envExample = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.env.example'))
        $module = [System.IO.File]::ReadAllText($modulePath)
        Assert-True ($compose -match 'source:\s*\$\{AI_STACK_HOME:.*\}/cloudflared') 'Cloudflare home state is not mounted.'
        Assert-True ($compose -match 'read_only:\s*true') 'Cloudflare state is not mounted read-only.'
        Assert-True ($compose -match '/etc/cloudflared/config\.yml') 'Cloudflare config file is not used.'
        Assert-True ($compose -notmatch 'CLOUDFLARE_TUNNEL_TOKEN') 'Compose still depends on a remotely managed tunnel token.'
        Assert-True ($envExample -notmatch 'CLOUDFLARE_TUNNEL_TOKEN') '.env.example still requests a tunnel token.'
        Assert-True ($module -match "Invoke-DockerCompose -Arguments @\('--profile', 'tunnel', 'down'\)") 'Stop does not include the tunnel profile.'
        Assert-True ($module -match "\$arguments = @\('--profile', 'tunnel', 'down', '--remove-orphans'\)") 'Uninstall does not include the tunnel profile.'
    }

    Invoke-Test 'Copilot JSON merge preserves servers and is idempotent' {
        $copilotPath = Join-Path $tempRoot 'copilot\mcp-config.json'
        New-Item -ItemType Directory -Path (Split-Path $copilotPath -Parent) | Out-Null
        '{"mcpServers":{"existing":{"command":"existing"}},"setting":true}' |
            Set-Content -LiteralPath $copilotPath -Encoding UTF8
        $launcher = Join-Path $testDataPath 'agentmemory-mcp.ps1'

        Assert-True (Merge-CopilotMcpConfig -Path $copilotPath -LauncherPath $launcher)
        $backupCount = @(Get-ChildItem "$copilotPath.ai-stack-backup-*").Count
        Assert-True (-not (Merge-CopilotMcpConfig -Path $copilotPath -LauncherPath $launcher)) 'Second merge reported a change.'
        Assert-Equal $backupCount @(Get-ChildItem "$copilotPath.ai-stack-backup-*").Count 'Second merge created another backup.'

        $merged = [System.IO.File]::ReadAllText($copilotPath) | ConvertFrom-Json
        Assert-Equal 'existing' $merged.mcpServers.existing.command
        Assert-Equal 'powershell.exe' $merged.mcpServers.agentmemory.command
        Assert-Equal $true $merged.setting
    }

    Invoke-Test 'Codex TOML merge preserves config and is idempotent' {
        $codexPath = Join-Path $tempRoot 'codex\config.toml'
        New-Item -ItemType Directory -Path (Split-Path $codexPath -Parent) | Out-Null
        @'
model = "gpt-5"

[mcp_servers.existing]
command = "existing"

[mcp_servers.agentmemory]
command = "old"
'@ | Set-Content -LiteralPath $codexPath -Encoding UTF8
        $launcher = Join-Path $testDataPath 'agentmemory-mcp.ps1'

        Assert-True (Merge-CodexMcpConfig -Path $codexPath -LauncherPath $launcher)
        $first = [System.IO.File]::ReadAllText($codexPath)
        Assert-True (-not (Merge-CodexMcpConfig -Path $codexPath -LauncherPath $launcher)) 'Second merge reported a change.'
        $second = [System.IO.File]::ReadAllText($codexPath)

        Assert-Equal $first $second
        Assert-True ($second -match 'model = "gpt-5"') 'Existing top-level config was removed.'
        Assert-True ($second -match '\[mcp_servers\.existing\]') 'Existing MCP server was removed.'
        Assert-Equal 1 ([regex]::Matches($second, '\[mcp_servers\.agentmemory\]').Count) 'AgentMemory table was duplicated.'
    }

    Invoke-Test 'Native installer tolerates successful stderr' {
        $module = Get-Module AiStack
        & $module {
            Invoke-IdempotentNative -Command 'powershell.exe' -Arguments @(
                '-NoProfile',
                '-Command',
                "[Console]::Error.WriteLine('expected warning'); exit 0"
            )
        }
    }

    Invoke-Test 'Doctor reports healthy injected probes' {
        $results = Invoke-AiStackDoctor `
            -CommandProbe { param($name) $true } `
            -DockerProbe { '29.2.1' } `
            -HttpProbe { param($url) 200 }
        Assert-True ($results.Count -ge 5)
        Assert-True ($results.Status -notcontains 'FAIL')
        Assert-Equal 2 @($results | Where-Object { $_.Name -in @('LiteLLM', 'AgentMemory') -and $_.Status -eq 'PASS' }).Count
    }

    Invoke-Test 'Doctor fails when Docker is unavailable' {
        $results = Invoke-AiStackDoctor `
            -CommandProbe { param($name) $name -ne 'docker' } `
            -DockerProbe { throw 'must not run' } `
            -HttpProbe { param($url) throw 'offline' }
        Assert-Equal 'FAIL' ($results | Where-Object Name -eq 'Docker CLI').Status
        Assert-Equal 2 @($results | Where-Object { $_.Name -in @('LiteLLM', 'AgentMemory') -and $_.Status -eq 'WARN' }).Count
    }
}
finally {
    Remove-Module AiStack -ErrorAction SilentlyContinue
    Remove-Item Env:\AI_STACK_TEST_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\AI_STACK_TEST_DATA_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\AI_STACK_TEST_CLIENT_HOME -ErrorAction SilentlyContinue
    if ($null -ne $previousComposeProjectName) {
        $env:COMPOSE_PROJECT_NAME = $previousComposeProjectName
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

if ($failures.Count -gt 0) {
    Write-Host ''
    $failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "$($failures.Count) of $testCount tests failed."
}

Write-Host "All $testCount tests passed."
