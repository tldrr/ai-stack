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
    $env:AI_STACK_TEST_ROOT = $tempRoot
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

    Invoke-Test 'Setup is idempotent and generates local secrets' {
        Initialize-AiStackConfiguration
        $envBefore = [System.IO.File]::ReadAllText((Join-Path $tempRoot '.env'))
        $secretBefore = [System.IO.File]::ReadAllText((Join-Path $tempRoot '.state\agentmemory-secret'))
        Initialize-AiStackConfiguration
        $envAfter = [System.IO.File]::ReadAllText((Join-Path $tempRoot '.env'))
        $secretAfter = [System.IO.File]::ReadAllText((Join-Path $tempRoot '.state\agentmemory-secret'))

        Assert-Equal $envBefore $envAfter 'Setup changed .env on the second run.'
        Assert-Equal $secretBefore $secretAfter 'Setup rotated the AgentMemory secret.'
        Assert-True ($envBefore -notmatch 'change-me-generated-by-setup') 'LiteLLM placeholder was not replaced.'
        Assert-True ($secretBefore -match '^am_[0-9a-f]{64}$') 'AgentMemory secret has the wrong format.'
    }

    Invoke-Test 'Copilot JSON merge preserves servers and is idempotent' {
        $copilotPath = Join-Path $tempRoot 'copilot\mcp-config.json'
        New-Item -ItemType Directory -Path (Split-Path $copilotPath -Parent) | Out-Null
        '{"mcpServers":{"existing":{"command":"existing"}},"setting":true}' |
            Set-Content -LiteralPath $copilotPath -Encoding UTF8
        $launcher = Join-Path $tempRoot '.state\agentmemory-mcp.ps1'

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
        $launcher = Join-Path $tempRoot '.state\agentmemory-mcp.ps1'

        Assert-True (Merge-CodexMcpConfig -Path $codexPath -LauncherPath $launcher)
        $first = [System.IO.File]::ReadAllText($codexPath)
        Assert-True (-not (Merge-CodexMcpConfig -Path $codexPath -LauncherPath $launcher)) 'Second merge reported a change.'
        $second = [System.IO.File]::ReadAllText($codexPath)

        Assert-Equal $first $second
        Assert-True ($second -match 'model = "gpt-5"') 'Existing top-level config was removed.'
        Assert-True ($second -match '\[mcp_servers\.existing\]') 'Existing MCP server was removed.'
        Assert-Equal 1 ([regex]::Matches($second, '\[mcp_servers\.agentmemory\]').Count) 'AgentMemory table was duplicated.'
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
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

if ($failures.Count -gt 0) {
    Write-Host ''
    $failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "$($failures.Count) of $testCount tests failed."
}

Write-Host "All $testCount tests passed."
