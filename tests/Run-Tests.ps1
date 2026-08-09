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
    $env:AI_STACK_TEST_DISABLE_WSL = '1'
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

    Invoke-Test 'Node scripts parse cleanly' {
        $scripts = @(
            (Join-Path $repoRoot 'scripts\read-copilot-sessions.mjs'),
            (Join-Path $repoRoot 'scripts\enrich-agentmemory.mjs'),
            (Join-Path $repoRoot 'docker\agentmemory\patch-import-index.mjs'),
            (Join-Path $repoRoot 'docker\agentmemory\graph-backfill.mjs')
        )
        foreach ($script in $scripts) {
            & node --check $script
            Assert-Equal 0 $LASTEXITCODE "Node could not parse '$script'."
        }
    }

    Invoke-Test 'AgentMemory image includes local embeddings' {
        $dockerfile = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docker\agentmemory\Dockerfile'))
        $entrypoint = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docker\agentmemory\entrypoint.sh'))
        $importPatch = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docker\agentmemory\patch-import-index.mjs'))
        $graphBackfill = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docker\agentmemory\graph-backfill.mjs'))
        Assert-True ($dockerfile -notmatch '--omit=optional') 'The image omits AgentMemory local embedding dependencies.'
        Assert-True ($dockerfile -match '@agentmemory/agentmemory@\$\{AGENTMEMORY_VERSION\}') 'AgentMemory is not version-pinned at build time.'
        Assert-True ($dockerfile -match 'ln -s /data/transformers-cache') 'Transformers.js is not using the persistent writable cache.'
        Assert-True ($entrypoint -match 'TRANSFORMERS_CACHE_DIR') 'The persistent Transformers.js cache is not initialized.'
        Assert-True ($dockerfile -match 'patch-import-index\.mjs') 'The pinned 0.9.28 import index compatibility patch is not applied.'
        Assert-True ($importPatch -match 'embedBatch') 'Imported observations are not added to the vector index in batches.'
        Assert-True ($importPatch -match 'flushIndexSave') 'Imported search index updates are not persisted.'
        Assert-True ($importPatch -match 'throw error') 'Embedding failures do not fail the import for a resumable retry.'
        Assert-True ($importPatch -match 'idx\.remove\(memory\.id\)') 'Reimported memories leave stale BM25 postings.'
        Assert-True ($importPatch -match 'idx\.remove\(observation\.id\)') 'Reimported observations leave stale BM25 postings.'
        Assert-True ($importPatch -match 'vectorIndex\?\.remove\(memory\.id\)') 'Superseded memories leave stale vector entries.'
        Assert-True ($importPatch -match 'vectorIndex\?\.remove\(observation\.id\)') 'Reimported observations leave stale vector entries.'
        Assert-True ($importPatch -match 'currentMemories') 'Consolidated memories are not added to search indexes.'
        Assert-True ($importPatch -match 'consolidationFailures') 'Base consolidation silently swallows partial failures.'
        Assert-True ($importPatch -match 'mem:consolidation:completed') 'Partial consolidation retries duplicate successful memories.'
        Assert-True ($importPatch -match 'resetDerived') 'Semantic and procedural memories cannot be rebuilt after source changes.'
        Assert-True ($importPatch -match 'reflectionFailures') 'Reflection silently swallows partial failures.'
        Assert-True ($importPatch -match 'kv\.list\(KV\.insights\)') 'Stale reflection insights survive derived-data rebuilds.'
        Assert-True ($importPatch -match 'idRemap\.get\(rawEdge\.sourceNodeId\)') 'Merged graph nodes do not remap edge endpoints.'
        Assert-True ($importPatch -match 'graphExtractionChain') 'Graph extraction writes are not serialized.'
        Assert-True ($importPatch -match 'serialized graph snapshot rebuild') 'Graph snapshot rebuilds are not serialized with extraction.'
        Assert-True ($importPatch -match 'serialized graph reset') 'Graph resets are not serialized with extraction.'
        Assert-True ($importPatch -match 'rebuildResetAt') 'Snapshot rebuilds can restore pre-reset graph rows.'
        Assert-True ($importPatch -match 'graphResetAt') 'MCP graph stats include pre-reset graph rows.'
        Assert-True ($dockerfile -match 'graph-backfill\.mjs') 'The resumable graph backfill runner is not included in the image.'
        Assert-True ($graphBackfill -match 'mem::graph-extract') 'Graph backfill does not use AgentMemory graph extraction.'
        Assert-True ($graphBackfill -match 'graph-backfill-manifest\.json') 'Graph backfill is not resumable.'
        Assert-True ($graphBackfill -match 'session\.summary') 'Graph backfill does not use source-grounded session summaries.'
        Assert-True ($graphBackfill -match 'missingSummaries') 'Graph backfill can silently omit unsummarized sessions.'
        Assert-True ($graphBackfill -match 'const sessions = allSessions\.filter') 'A graph reset cannot rebuild summarized live sessions.'
        Assert-True ($graphBackfill -match 'invocationTimeoutMs:\s*900_000') 'Graph extraction can time out before the model returns.'
    }

    Invoke-Test 'AgentMemory shutdown preserves buffered state' {
        $entrypoint = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docker\agentmemory\entrypoint.sh'))
        $compose = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'compose.yaml'))
        Assert-True ($entrypoint -match 'AGENTMEMORY_DATA_DIR') 'The persistent AgentMemory data directory is not explicit.'
        Assert-True ($entrypoint -match 'trap shutdown TERM INT') 'The entrypoint does not handle Docker shutdown signals.'
        Assert-True ($entrypoint -match 'iii\.pid') 'The detached iii engine is not included in graceful shutdown.'
        Assert-True ($compose -match '(?ms)^\s{2}agentmemory:.*?^\s{4}stop_grace_period:\s*30s') 'AgentMemory does not have enough time for state flush.'
        $module = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\AiStack.psm1'))
        Assert-True ($module -match 'function Restart-AiStack[\s\S]*?@\(''up'', ''-d'', ''--build''\)') 'Restart does not rebuild a changed AgentMemory image.'
        Assert-True ($module -match '\.permissions-v1') 'Windows ACL hardening is repeated against live database files.'
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
        Assert-True ($module -match "\$arguments = @\('up', '-d', '--build'\)") 'Restart does not rebuild and recreate services when Compose configuration changes.'
        Assert-True ($module -match "'ps', '--all', '--services'") 'Restart cannot recover a provisioned but exited tunnel.'
        Assert-True ($module -match "\$runningServices -contains 'cloudflared'") 'Restart does not preserve an active tunnel profile.'
        Assert-True ($module -match "'rm', '--stop', '--force', 'cloudflared'") 'Disabling the tunnel leaves an exited container that restart can re-enable.'
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

    Invoke-Test 'Session import records are deterministic and redact secrets' {
        $module = Get-Module AiStack
        $result = & $module {
            $messages = @(
                (New-AiStackImportMessage `
                    -Role 'user' `
                    -Text "Use this token: Bearer abcdefghijklmnopqrstuvwxyz123456" `
                    -Timestamp '2026-01-01T00:00:00Z'),
                (New-AiStackImportMessage `
                    -Role 'assistant' `
                    -Text 'Completed without exposing credentials.' `
                    -Timestamp '2026-01-01T00:00:01Z')
            )
            $first = New-AiStackNormalizedSession `
                -Source 'VSCode' `
                -SourceId 'workspace|session-1' `
                -Project 'sample' `
                -Cwd 'C:\sample' `
                -Messages $messages
            $second = New-AiStackNormalizedSession `
                -Source 'VSCode' `
                -SourceId 'workspace|session-1' `
                -Project 'sample' `
                -Cwd 'C:\sample' `
                -Messages $messages
            $firstExport = ConvertTo-AiStackAgentMemoryExport -Session $first
            $secondExport = ConvertTo-AiStackAgentMemoryExport -Session $second
            [pscustomobject]@{
                FirstId = $first.Id
                SecondId = $second.Id
                FirstContentHash = $first.ContentHash
                FirstObservationIds = @($firstExport.observations[$first.Id].id)
                SecondObservationIds = @($secondExport.observations[$second.Id].id)
                Narrative = $firstExport.observations[$first.Id][0].narrative
                Importance = @($firstExport.observations[$first.Id].importance)
                ImportContentHash = $firstExport.sessions[0].importContentHash
                Tags = @($firstExport.sessions[0].tags)
            }
        }
        Assert-Equal $result.FirstId $result.SecondId 'Session IDs changed for identical source data.'
        Assert-Equal ($result.FirstObservationIds -join ',') ($result.SecondObservationIds -join ',') 'Observation IDs changed for identical source data.'
        Assert-True ($result.Narrative -match 'Bearer \[REDACTED\]') 'Bearer token was not redacted.'
        Assert-Equal '7,6' ($result.Importance -join ',') 'Imported observations do not use AgentMemory''s 1-10 importance scale.'
        Assert-Equal $result.FirstContentHash $result.ImportContentHash 'The imported session does not carry its source content hash.'
        Assert-True ($result.Tags -contains 'source-vscode') 'Source tag is missing.'
    }

    Invoke-Test 'Historical source adapters exclude hidden and sensitive content' {
        $module = Get-Module AiStack
        $oldAppData = $env:APPDATA
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:APPDATA = Join-Path $tempRoot 'appdata'
            $env:LOCALAPPDATA = Join-Path $tempRoot 'localappdata'

            $hermesRoot = Join-Path $env:LOCALAPPDATA 'hermes\sessions'
            New-Item -ItemType Directory -Path $hermesRoot -Force | Out-Null
            $hermes = @{
                timestamp = '2026-01-01T00:00:00Z'
                session_id = 'hermes-1'
                request = @{
                    headers = @{ Authorization = 'Bearer must-not-import' }
                    body = @{
                        model = 'test-model'
                        messages = @(
                            @{ role = 'system'; content = 'hidden system prompt' },
                            @{ role = 'user'; content = 'hello from Hermes' },
                            @{ role = 'assistant'; content = 'hello back' }
                        )
                    }
                }
            } | ConvertTo-Json -Depth 8
            Set-Content -LiteralPath (Join-Path $hermesRoot 'session.json') -Value $hermes -Encoding UTF8
            $hermesFollowUp = @{
                timestamp = '2026-01-01T00:01:00Z'
                session_id = 'hermes-1'
                request = @{
                    body = @{
                        model = 'test-model'
                        messages = @(
                            @{ role = 'system'; content = 'hidden system prompt' },
                            @{ role = 'user'; content = 'hello from Hermes' },
                            @{ role = 'assistant'; content = 'hello back' },
                            @{ role = 'user'; content = 'hello from Hermes' }
                        )
                    }
                }
            } | ConvertTo-Json -Depth 8
            Set-Content `
                -LiteralPath (Join-Path $hermesRoot 'session-follow-up.json') `
                -Value $hermesFollowUp `
                -Encoding UTF8
            (Get-Item -LiteralPath (Join-Path $hermesRoot 'session.json')).LastWriteTimeUtc = [datetime]'2026-02-01T00:00:00Z'
            (Get-Item -LiteralPath (Join-Path $hermesRoot 'session-follow-up.json')).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'

            $piRoot = Join-Path $testClientHome '.pi\agent\sessions\project'
            New-Item -ItemType Directory -Path $piRoot -Force | Out-Null
            @(
                (@{ type = 'session'; id = 'pi-1'; cwd = 'C:\pi-project'; timestamp = '2026-01-02T00:00:00Z' } | ConvertTo-Json -Compress),
                (@{ type = 'message'; message = @{ role = 'user'; content = 'hello from pi'; timestamp = '2026-01-02T00:00:01Z' } } | ConvertTo-Json -Compress),
                (@{ type = 'message'; message = @{ role = 'assistant'; content = 'pi response'; timestamp = '2026-01-02T00:00:02Z' } } | ConvertTo-Json -Compress)
            ) | Set-Content -LiteralPath (Join-Path $piRoot 'session.jsonl') -Encoding UTF8

            $workspaceRoot = Join-Path $env:APPDATA 'Code\User\workspaceStorage\workspace-1'
            $chatRoot = Join-Path $workspaceRoot 'chatSessions'
            New-Item -ItemType Directory -Path $chatRoot -Force | Out-Null
            @{ folder = 'file:///C:/work/sample-project' } |
                ConvertTo-Json -Compress |
                Set-Content -LiteralPath (Join-Path $workspaceRoot 'workspace.json') -Encoding UTF8
            $chat = @{
                kind = 0
                v = @{
                    sessionId = 'vscode-1'
                    customTitle = 'temporary'
                    requests = @(
                        @{
                            timestamp = 1767225600000
                            modelId = 'test-model'
                            message = @{ text = 'hello from VS Code' }
                            response = @(
                                @{ kind = 'thinking'; value = 'hidden reasoning' },
                                @{ value = 'visible response' },
                                @{ kind = 'toolInvocationSerialized'; value = 'hidden tool output' }
                            )
                        }
                    )
                }
            }
            $chatSet = @{
                kind = 1
                k = @('requests', 0, 'response')
                v = @(@{ value = 'updated visible response' })
            }
            $chatPush = @{
                kind = 2
                k = @('requests')
                v = @(@{
                    timestamp = 1767225660000
                    modelId = 'test-model'
                    message = @{ text = 'second VS Code request' }
                    response = @(@{ value = 'second VS Code response' })
                })
            }
            $chatDelete = @{ kind = 3; k = @('customTitle') }
            @($chat, $chatSet, $chatPush, $chatDelete) |
                ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress } |
                Set-Content -LiteralPath (Join-Path $chatRoot 'session.jsonl') -Encoding UTF8

            $result = & $module {
                [pscustomobject]@{
                    Hermes = @(Get-HermesImportSessions)
                    Pi = @(Get-PiImportSessions)
                    VSCode = @(Get-VSCodeImportSessions)
                }
            }
            Assert-Equal 1 $result.Hermes.Count
            Assert-Equal 3 $result.Hermes[0].Messages.Count
            Assert-Equal 2 @($result.Hermes[0].Messages | Where-Object Text -eq 'hello from Hermes').Count 'Hermes repeated messages were discarded.'
            Assert-True (($result.Hermes[0].Messages.Text -join ' ') -notmatch 'system prompt|must-not-import') 'Hermes metadata or system prompts leaked into the import.'
            Assert-Equal 1 $result.Pi.Count
            Assert-Equal 2 $result.Pi[0].Messages.Count
            Assert-Equal 1 $result.VSCode.Count
            Assert-Equal 4 $result.VSCode[0].Messages.Count
            Assert-True (($result.VSCode[0].Messages.Text -join ' ') -match 'updated visible response|second VS Code request') 'VS Code mutation log entries were not replayed.'
            Assert-True (($result.VSCode[0].Messages.Text -join ' ') -notmatch 'hidden reasoning|hidden tool output') 'VS Code hidden content leaked into the import.'
        }
        finally {
            $env:APPDATA = $oldAppData
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    Invoke-Test 'Historical enrichment is resumable and WSL-safe' {
        $launcher = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'ai-stack.ps1'))
        $importer = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\SessionImport.ps1'))
        $summaryRunner = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\enrich-agentmemory.mjs'))
        Assert-True ($launcher -match "'enrich-sessions'") 'The enrichment command is not exposed by the launcher.'
        Assert-True ($importer -match '__AI_STACK_HOME__') 'WSL home discovery does not isolate shell startup output.'
        Assert-True ($importer -match 'Invoke-AiStackSessionEnrichment') 'Historical enrichment is not wired into the module.'
        Assert-True ($summaryRunner -match 'alreadySummarized') 'Existing summaries are not skipped on resume.'
        Assert-True ($summaryRunner -match 'importContentHash') 'Summary checkpoints do not invalidate changed transcripts.'
        Assert-True ($summaryRunner -match 'historical-import') 'Enrichment is not restricted to historical imports.'
        Assert-True ($importer -match '\$staleIds\.Count -gt 0 -or \$sessionContentChanged') 'Append-only transcript changes do not invalidate derived data.'
        Assert-True ($importer -match '\$SessionIds\.Count -eq 0 -and \$ObservationIds\.Count -eq 0') 'Append-only transcript invalidation exits before clearing derived data.'
        Assert-True ($importer -match 'ConsolidationManifestPath') 'Failed consolidation cannot be resumed independently.'
        Assert-True ($importer -match '\$pipelineErrors\.Count -gt 0') 'Partial consolidation pipeline failures are checkpointed as success.'
        Assert-True ($importer -match '\$Force -and -not \$DryRun') 'Forced summary regeneration does not reset the graph.'
        Assert-True ($importer -match 'resetDerived = \(-not \$consolidationCurrent -or \$Force\)') 'Resumed enrichment preserves stale derived tiers.'
        Assert-True ($importer -match 'Fallback \$turnFallback') 'Copilot turns without timestamps are not deterministic.'
        $invalidationWrite = $importer.IndexOf('$script:DerivedInvalidationPath', $importer.IndexOf('$staleIds.Count -gt 0'))
        $manifestWrite = $importer.IndexOf('Write-AiStackImportManifest -Entries $manifest', $importer.IndexOf('$staleIds.Count -gt 0'))
        Assert-True ($invalidationWrite -ge 0 -and $invalidationWrite -lt $manifestWrite) 'Derived-data invalidation is checkpointed after the import manifest.'
    }

    Invoke-Test 'Continuous-capture generation is safe and idempotent' {
        $module = Get-Module AiStack
        $result = & $module {
            param($Root)

            $piSource = @'
import path from "node:path";
import crypto from "node:crypto";

type TextBlock = { type?: string; text?: string };
'@
            $piFirst = Add-AiStackPiEnvironmentBootstrap -Content $piSource
            $piSecond = Add-AiStackPiEnvironmentBootstrap -Content $piFirst
            $copilotHooks = '{"hooks":{"sessionStart":[{"type":"command","command":"node ${COPILOT_PLUGIN_ROOT}/scripts/session-start.mjs"}]}}'
            $copilotRunnerPath = 'C:\capture\ai-stack-runner.mjs'
            $copilotFirst = Add-AiStackCopilotEnvironmentRunner `
                -Content $copilotHooks `
                -RunnerPath $copilotRunnerPath
            $copilotSecond = Add-AiStackCopilotEnvironmentRunner `
                -Content $copilotFirst `
                -RunnerPath $copilotRunnerPath
            $copilotRunner = Get-AiStackCopilotEnvironmentRunner

            $hermesSource = @"
model:
  default: test
memory:
  provider:
  session_store: true
unrelated:
  keep: value
"@
            $hermesFirst = Merge-AiStackHermesMemoryProvider -Content $hermesSource
            $hermesSecond = Merge-AiStackHermesMemoryProvider -Content $hermesFirst
            $nestedHermes = Merge-AiStackHermesMemoryProvider -Content @"
memory:
  nested:
    provider: keep
  provider: previous
"@
            $commentedHermes = Merge-AiStackHermesMemoryProvider -Content @"
memory:
    # A deeply-indented comment must not determine mapping indentation.
  provider: previous
  keep: true
"@
            $spacedHermes = Merge-AiStackHermesMemoryProvider -Content @"
memory:
  session_store: true

  provider: previous
"@
            $headerCommentHermes = Merge-AiStackHermesMemoryProvider -Content @"
memory: # keep this comment
  provider: previous
"@
            $flowHermesRejected = $false
            try {
                [void](Merge-AiStackHermesMemoryProvider -Content 'memory: { provider: previous, keep: true }')
            }
            catch {
                $flowHermesRejected = $true
            }
            $blockHermesRejected = $false
            try {
                [void](Merge-AiStackHermesMemoryProvider -Content @"
memory:
  provider: >-
    previous
"@)
            }
            catch {
                $blockHermesRejected = $true
            }
            $previousHermesHome = $env:HERMES_HOME
            try {
                $env:HERMES_HOME = Join-Path $Root 'custom-hermes'
                $customHermesHome = Get-AiStackHermesHome
            }
            finally {
                if ($null -eq $previousHermesHome) {
                    Remove-Item Env:\HERMES_HOME -ErrorAction SilentlyContinue
                }
                else {
                    $env:HERMES_HOME = $previousHermesHome
                }
            }
            $hermesPlugin = Add-AiStackHermesWindowsHome -Content 'candidates: list[Path] = []'
            $hermesPluginAgain = Add-AiStackHermesWindowsHome -Content $hermesPlugin

            $managedPath = Join-Path $Root 'capture\managed.txt'
            $firstWrite = Set-AiStackManagedFile -Path $managedPath -Content 'first'
            $secondWrite = Set-AiStackManagedFile -Path $managedPath -Content 'first'
            $thirdWrite = Set-AiStackManagedFile -Path $managedPath -Content 'second'
            [pscustomobject]@{
                PiFirst = $piFirst
                PiSecond = $piSecond
                CopilotFirst = $copilotFirst
                CopilotSecond = $copilotSecond
                CopilotRunner = $copilotRunner
                HermesFirst = $hermesFirst
                HermesSecond = $hermesSecond
                NestedHermes = $nestedHermes
                CommentedHermes = $commentedHermes
                SpacedHermes = $spacedHermes
                HeaderCommentHermes = $headerCommentHermes
                NestedProvider = Get-AiStackHermesMemoryProvider -Content $nestedHermes
                FlowHermesRejected = $flowHermesRejected
                BlockHermesRejected = $blockHermesRejected
                CustomHermesHome = $customHermesHome
                HermesPlugin = $hermesPlugin
                HermesPluginAgain = $hermesPluginAgain
                FirstWrite = $firstWrite
                SecondWrite = $secondWrite
                ThirdWrite = $thirdWrite
                ManagedContent = [System.IO.File]::ReadAllText($managedPath)
                BackupCount = @(Get-ChildItem "$managedPath.ai-stack-backup-*").Count
                CaptureSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\scripts\CaptureInstall.ps1'))
            }
        } $tempRoot

        Assert-Equal $result.PiFirst $result.PiSecond 'pi bootstrap was duplicated.'
        Assert-Equal 1 ([regex]::Matches($result.PiFirst, 'loadAiStackAgentMemoryEnv\(\);').Count) 'pi bootstrap was not generated exactly once.'
        Assert-True ($result.PiFirst -notmatch 'AGENTMEMORY_SECRET=') 'pi extension embeds an AgentMemory secret.'
        Assert-Equal $result.CopilotFirst $result.CopilotSecond 'Copilot hook runner was duplicated.'
        Assert-True ($result.CopilotFirst -match 'C:\\\\capture\\\\ai-stack-runner\.mjs') 'Copilot hook does not use the absolute generated runner path.'
        Assert-True ($result.CopilotFirst -match 'session-start\.mjs') 'Copilot hook lost its official script target.'
        Assert-True ($result.CopilotRunner -notmatch 'AGENTMEMORY_SECRET=') 'Copilot hook runner embeds an AgentMemory secret.'
        Assert-True ($result.CopilotRunner -match '\.agentmemory') 'Copilot hook runner does not load the protected local environment.'
        Assert-Equal $result.HermesFirst $result.HermesSecond 'Hermes memory-provider merge is not idempotent.'
        Assert-True ($result.HermesFirst -match '(?m)^  provider: agentmemory$') 'Hermes provider was not selected.'
        Assert-True ($result.HermesFirst -match '(?m)^unrelated:\r?$') 'Hermes unrelated configuration was removed.'
        Assert-True ($result.NestedHermes -match '(?m)^    provider: keep\r?$') 'Hermes nested provider setting was overwritten.'
        Assert-True ($result.NestedHermes -match '(?m)^  provider: agentmemory\r?$') 'Hermes top-level memory provider was not selected.'
        Assert-True ($result.CommentedHermes -match '(?m)^  provider: agentmemory\r?$') 'Hermes comment indentation corrupted the mapping.'
        Assert-Equal 1 ([regex]::Matches($result.SpacedHermes, '(?m)^  provider: agentmemory\r?$').Count) 'Hermes provider after a blank line was duplicated.'
        Assert-True ($result.HeaderCommentHermes -match '(?m)^  provider: agentmemory\r?$') 'Hermes memory header comment prevented the provider merge.'
        Assert-True ($result.HeaderCommentHermes.Contains('memory: # keep this comment')) 'Hermes memory header comment was removed.'
        Assert-Equal 'agentmemory' $result.NestedProvider 'Hermes provider validation selected a nested provider.'
        Assert-True $result.FlowHermesRejected 'Hermes flow-style memory YAML was modified unsafely.'
        Assert-True $result.BlockHermesRejected 'Hermes block-scalar provider YAML was modified unsafely.'
        Assert-True ($result.CustomHermesHome -like '*custom-hermes') 'HERMES_HOME override was ignored.'
        Assert-Equal $result.HermesPlugin $result.HermesPluginAgain 'Hermes Windows home patch is not idempotent.'
        Assert-True ($result.HermesPlugin -match 'Path\.home\(\)') 'Hermes cannot find the protected environment on native Windows.'
        Assert-True ($result.FirstWrite -and -not $result.SecondWrite -and $result.ThirdWrite) 'Managed-file writes are not idempotent.'
        Assert-Equal 'second' $result.ManagedContent 'Managed file did not receive the new content.'
        Assert-Equal 1 $result.BackupCount 'Managed-file replacement did not create exactly one backup.'
        Assert-True ($result.CaptureSource -match 'd60652a7058773fa9428fa720eda38942f12f014') 'Capture integrations are not pinned to the reviewed upstream commit.'
        Assert-Equal 20 ([regex]::Matches($result.CaptureSource, "[a-f0-9]{64}'").Count) 'Capture integration hashes are incomplete.'
        Assert-True ($result.CaptureSource -match 'chmod 600') 'WSL secret permissions are not enforced.'
        Assert-True ($result.CaptureSource -match 'SkipIfUnavailable:\(\$Agent -eq ''All''\)') 'An unavailable Copilot installation blocks other capture agents.'
        Assert-True ($result.CaptureSource -match 'Get-AiStackCopilotPluginMcpConfig') 'Copilot plugin MCP execution is not routed through the pinned launcher.'
        Assert-True ($result.CaptureSource -notmatch "args\s*=\s*@\(''-y'',\s*''@agentmemory/mcp''") 'Copilot plugin MCP still uses an unpinned package.'
        Assert-True ($result.CaptureSource -match '\.env\.ai-stack-backup-\*') 'AgentMemory secret backups are not protected.'
        Assert-True ($result.CaptureSource -match 'Sync-AiStackPinnedSkills') 'Copilot plugin skills are not pinned.'
        Assert-True ($result.CaptureSource -match '\$Agent -ne ''All''') 'All-agent installation failures are not isolated.'
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
    Remove-Item Env:\AI_STACK_TEST_DISABLE_WSL -ErrorAction SilentlyContinue
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
