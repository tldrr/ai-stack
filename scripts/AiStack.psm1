Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root = if ($env:AI_STACK_TEST_ROOT) {
    [System.IO.Path]::GetFullPath($env:AI_STACK_TEST_ROOT)
}
else {
    Split-Path $PSScriptRoot -Parent
}
$script:EnvPath = Join-Path $script:Root '.env'
$script:EnvExamplePath = Join-Path $script:Root '.env.example'
$script:ComposePath = Join-Path $script:Root 'compose.yaml'
$script:StatePath = Join-Path $script:Root '.state'
$script:McpLauncherPath = Join-Path $script:StatePath 'agentmemory-mcp.ps1'
$script:AgentMemorySecretPath = Join-Path $script:StatePath 'agentmemory-secret'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-AiStackSecret {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }

    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return "$Prefix$hex"
}

function Get-DotEnvValues {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(?:#|$)') {
            continue
        }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $values[$matches[1]] = $matches[2].Trim()
        }
    }
    return $values
}

function Set-DotEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $escapedName = [regex]::Escape($Name)
    if ($Content -match "(?m)^$escapedName=") {
        return [regex]::Replace($Content, "(?m)^$escapedName=.*$", "$Name=$Value")
    }
    return $Content.TrimEnd() + [Environment]::NewLine + "$Name=$Value" + [Environment]::NewLine
}

function New-McpLauncher {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        New-Item -ItemType Directory -Path $script:StatePath | Out-Null
    }

    $relativeEnvPath = '..\.env'
    $content = @"
`$ErrorActionPreference = 'Stop'
`$envPath = [System.IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '$relativeEnvPath'))
`$restPort = '3111'
foreach (`$line in Get-Content -LiteralPath `$envPath) {
    if (`$line -match '^\s*AGENTMEMORY_REST_PORT=(.*)$') {
        `$restPort = `$matches[1].Trim()
    }
}
`$secretPath = Join-Path `$PSScriptRoot 'agentmemory-secret'
`$env:AGENTMEMORY_SECRET = [System.IO.File]::ReadAllText(`$secretPath).Trim()
`$env:AGENTMEMORY_URL = "http://localhost:`$restPort"
`$env:AGENTMEMORY_TOOLS = 'all'
`$npx = if (Get-Command npx.cmd -ErrorAction SilentlyContinue) { 'npx.cmd' } else { 'npx' }
& `$npx -y '@agentmemory/mcp@0.9.28'
exit `$LASTEXITCODE
"@
    Write-Utf8NoBom -Path $script:McpLauncherPath -Content $content
}

function Test-AiStackDataVolumeExists {
    param([Parameter(Mandatory = $true)][string]$ProjectName)

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & docker volume inspect "$ProjectName`_agentmemory-data" *> $null
        $exists = $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    # An expected "volume not found" must not become the caller's process exit
    # code when setup is run directly from CI or a shell.
    $global:LASTEXITCODE = 0
    return $exists
}

function Initialize-AiStackConfiguration {
    [CmdletBinding()]
    param([switch]$PassThru)

    if (-not (Test-Path -LiteralPath $script:EnvPath)) {
        Copy-Item -LiteralPath $script:EnvExamplePath -Destination $script:EnvPath
    }

    $content = [System.IO.File]::ReadAllText($script:EnvPath)
    $values = Get-DotEnvValues -Path $script:EnvPath

    if ((-not $values.ContainsKey('LITELLM_MASTER_KEY')) -or
        [string]::IsNullOrWhiteSpace($values['LITELLM_MASTER_KEY']) -or
        $values['LITELLM_MASTER_KEY'] -eq 'change-me-generated-by-setup') {
        $content = Set-DotEnvValue -Content $content -Name 'LITELLM_MASTER_KEY' -Value (New-AiStackSecret -Prefix 'sk-local-')
    }
    Write-Utf8NoBom -Path $script:EnvPath -Content $content
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        New-Item -ItemType Directory -Path $script:StatePath | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:AgentMemorySecretPath) -or
        [string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($script:AgentMemorySecretPath))) {
        $projectName = if ($values.ContainsKey('COMPOSE_PROJECT_NAME')) {
            $values['COMPOSE_PROJECT_NAME']
        }
        else {
            'ai-stack'
        }
        if (Test-AiStackDataVolumeExists -ProjectName $projectName) {
            throw 'AgentMemory data exists but .state\agentmemory-secret is missing. Restore the matching secret backup or intentionally delete the data volume before running setup.'
        }
        Write-Utf8NoBom -Path $script:AgentMemorySecretPath -Content (New-AiStackSecret -Prefix 'am_')
    }
    New-McpLauncher
    Write-Host 'Local configuration initialized. Secrets remain in git-ignored local files.'
    if ($PassThru) {
        return $script:EnvPath
    }
}

function Get-ComposeArguments {
    $arguments = @(
        'compose',
        '--project-directory', $script:Root,
        '--env-file', $script:EnvPath,
        '-f', $script:ComposePath
    )
    return $arguments
}

function Invoke-DockerCompose {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Capture
    )

    $allArguments = @(Get-ComposeArguments) + $Arguments
    if ($Capture) {
        $output = & docker @allArguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose failed: $($output -join [Environment]::NewLine)"
        }
        return $output
    }

    & docker @allArguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose exited with code $LASTEXITCODE."
    }
}

function Assert-TunnelConfigured {
    $values = Get-DotEnvValues -Path $script:EnvPath
    if (-not $values.ContainsKey('CLOUDFLARE_TUNNEL_TOKEN') -or
        [string]::IsNullOrWhiteSpace($values['CLOUDFLARE_TUNNEL_TOKEN'])) {
        throw 'CLOUDFLARE_TUNNEL_TOKEN must be set in .env before starting the tunnel profile.'
    }
}

function Assert-AiStackEnvExists {
    if (-not (Test-Path -LiteralPath $script:EnvPath)) {
        throw "Local configuration is missing at '$script:EnvPath'. Run setup first."
    }
}

function Start-AiStack {
    [CmdletBinding()]
    param([switch]$Tunnel)

    Initialize-AiStackConfiguration
    $arguments = @('up', '-d', '--build')
    if ($Tunnel) {
        Assert-TunnelConfigured
        $arguments = @('--profile', 'tunnel') + $arguments
    }
    else {
        # Calling start without -Tunnel also closes any previously enabled
        # public tunnel instead of leaving stale exposure running.
        Invoke-DockerCompose -Arguments @('--profile', 'tunnel', 'stop', 'cloudflared')
    }
    Invoke-DockerCompose -Arguments $arguments
}

function Stop-AiStack {
    Assert-AiStackEnvExists
    Invoke-DockerCompose -Arguments @('down')
}

function Restart-AiStack {
    Initialize-AiStackConfiguration
    Invoke-DockerCompose -Arguments @('restart')
}

function Get-AiStackStatus {
    Assert-AiStackEnvExists
    Invoke-DockerCompose -Arguments @('ps')
}

function Show-AiStackLogs {
    param([string]$Service)

    Assert-AiStackEnvExists
    $arguments = @('logs', '--follow', '--tail', '200')
    if (-not [string]::IsNullOrWhiteSpace($Service)) {
        $arguments += $Service
    }
    Invoke-DockerCompose -Arguments $arguments
}

function Backup-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Copy-Item -LiteralPath $Path -Destination "$Path.ai-stack-backup-$stamp"
}

function ConvertTo-JsonStable {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
}

function Merge-CopilotMcpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        try {
            $config = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        }
        catch {
            throw "Cannot merge malformed Copilot MCP JSON at '$Path': $($_.Exception.Message)"
        }
    }
    else {
        $config = New-Object PSObject
    }

    if (-not $config.PSObject.Properties['mcpServers']) {
        $config | Add-Member -MemberType NoteProperty -Name mcpServers -Value (New-Object PSObject)
    }

    $server = [ordered]@{
        type = 'local'
        command = 'powershell.exe'
        args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LauncherPath)
        tools = @('*')
    }
    if ($config.mcpServers.PSObject.Properties['agentmemory']) {
        $config.mcpServers.agentmemory = $server
    }
    else {
        $config.mcpServers | Add-Member -MemberType NoteProperty -Name agentmemory -Value $server
    }

    $updated = ConvertTo-JsonStable -Value $config
    $existing = if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) } else { '' }
    if ($existing -ne $updated) {
        Backup-File -Path $Path
        Write-Utf8NoBom -Path $Path -Content $updated
        return $true
    }
    return $false
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Merge-CodexMcpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $begin = '# BEGIN ai-stack agentmemory'
    $end = '# END ai-stack agentmemory'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LauncherPath) |
        ForEach-Object { ConvertTo-TomlString -Value $_ }
    $block = @(
        $begin
        '[mcp_servers.agentmemory]'
        "command = `"powershell.exe`""
        "args = [$($args -join ', ')]"
        $end
    ) -join [Environment]::NewLine

    $existing = if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) } else { '' }
    $managedPattern = "(?ms)^\s*$([regex]::Escape($begin)).*?^\s*$([regex]::Escape($end))\s*(?:\r?\n)?"
    $withoutManaged = [regex]::Replace($existing, $managedPattern, '')
    $tablePattern = '(?ms)^\[mcp_servers\.agentmemory\]\s*\r?\n.*?(?=^\[|\z)'
    $withoutExisting = [regex]::Replace($withoutManaged, $tablePattern, '')
    $updated = $withoutExisting.TrimEnd()
    if ($updated.Length -gt 0) {
        $updated += [Environment]::NewLine + [Environment]::NewLine
    }
    $updated += $block + [Environment]::NewLine

    if ($existing -ne $updated) {
        Backup-File -Path $Path
        Write-Utf8NoBom -Path $Path -Content $updated
        return $true
    }
    return $false
}

function Invoke-IdempotentNative {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and ($output -join ' ') -notmatch '(?i)already (?:added|installed|exists)') {
        throw "$Command failed: $($output -join [Environment]::NewLine)"
    }
    if ($output) {
        Write-Host ($output -join [Environment]::NewLine)
    }
}

function Install-AiStackClients {
    [CmdletBinding()]
    param([ValidateSet('All', 'Copilot', 'Codex')][string]$Client = 'All')

    Initialize-AiStackConfiguration
    $homePath = [Environment]::GetFolderPath('UserProfile')

    if ($Client -in @('All', 'Copilot')) {
        $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $homePath '.copilot' }
        $copilotConfig = Join-Path $copilotHome 'mcp-config.json'
        [void](Merge-CopilotMcpConfig -Path $copilotConfig -LauncherPath $script:McpLauncherPath)
        if (Get-Command copilot -ErrorAction SilentlyContinue) {
            Invoke-IdempotentNative -Command 'copilot' -Arguments @('plugin', 'install', 'rohitg00/agentmemory:plugin')
        }
        else {
            Write-Warning 'Copilot CLI was not found. MCP configuration was installed; run the official plugin command after installing Copilot CLI.'
        }
    }

    if ($Client -in @('All', 'Codex')) {
        $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $homePath '.codex' }
        $codexConfig = Join-Path $codexHome 'config.toml'
        [void](Merge-CodexMcpConfig -Path $codexConfig -LauncherPath $script:McpLauncherPath)
        if (Get-Command codex -ErrorAction SilentlyContinue) {
            Invoke-IdempotentNative -Command 'codex' -Arguments @('plugin', 'marketplace', 'add', 'rohitg00/agentmemory')
            Invoke-IdempotentNative -Command 'codex' -Arguments @('plugin', 'add', 'agentmemory@agentmemory')
        }
        else {
            Write-Warning 'Codex CLI was not found. MCP configuration was installed; add the official marketplace plugin after installing Codex.'
        }
    }

    Write-Host 'Client configuration complete. Restart desktop apps and approve plugin trust in their UI when prompted.'
}

function New-DoctorResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    return [PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

function Invoke-AiStackDoctor {
    [CmdletBinding()]
    param(
        [scriptblock]$CommandProbe = { param($name) [bool](Get-Command $name -ErrorAction SilentlyContinue) },
        [scriptblock]$DockerProbe = { docker info --format '{{.ServerVersion}}' 2>$null },
        [scriptblock]$HttpProbe = {
            param($url)
            (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3).StatusCode
        }
    )

    $results = New-Object System.Collections.ArrayList
    if (& $CommandProbe 'docker') {
        [void]$results.Add((New-DoctorResult -Name 'Docker CLI' -Status 'PASS' -Detail 'docker is available'))
        try {
            $version = & $DockerProbe
            if ([string]::IsNullOrWhiteSpace(($version -join ''))) {
                throw 'Docker engine returned no version.'
            }
            [void]$results.Add((New-DoctorResult -Name 'Docker engine' -Status 'PASS' -Detail "running ($version)"))
        }
        catch {
            [void]$results.Add((New-DoctorResult -Name 'Docker engine' -Status 'FAIL' -Detail 'Docker Desktop is not reachable'))
        }
    }
    else {
        [void]$results.Add((New-DoctorResult -Name 'Docker CLI' -Status 'FAIL' -Detail 'docker is not on PATH'))
    }

    if (& $CommandProbe 'node') {
        [void]$results.Add((New-DoctorResult -Name 'Node.js' -Status 'PASS' -Detail 'available for the MCP shim'))
    }
    else {
        [void]$results.Add((New-DoctorResult -Name 'Node.js' -Status 'WARN' -Detail 'required only for install-clients'))
    }

    if (Test-Path -LiteralPath $script:EnvPath) {
        $values = Get-DotEnvValues -Path $script:EnvPath
        $unsafe = @(@('LITELLM_MASTER_KEY') | Where-Object {
            (-not $values.ContainsKey($_)) -or
            [string]::IsNullOrWhiteSpace($values[$_]) -or
            $values[$_] -like 'change-me-*'
        })
        if ($unsafe.Count -eq 0) {
            if ((Test-Path -LiteralPath $script:AgentMemorySecretPath) -and
                -not [string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($script:AgentMemorySecretPath))) {
                [void]$results.Add((New-DoctorResult -Name 'Local configuration' -Status 'PASS' -Detail 'required local configuration and secrets exist'))
            }
            else {
                [void]$results.Add((New-DoctorResult -Name 'Local configuration' -Status 'FAIL' -Detail 'run setup to generate the AgentMemory secret'))
            }
        }
        else {
            [void]$results.Add((New-DoctorResult -Name 'Local configuration' -Status 'FAIL' -Detail 'run setup to generate required local secrets'))
        }
    }
    else {
        [void]$results.Add((New-DoctorResult -Name 'Local configuration' -Status 'WARN' -Detail 'run setup before start'))
    }

    $doctorValues = Get-DotEnvValues -Path $script:EnvPath
    $litellmPort = if ($doctorValues.ContainsKey('LITELLM_PORT')) { $doctorValues['LITELLM_PORT'] } else { '4000' }
    $agentMemoryPort = if ($doctorValues.ContainsKey('AGENTMEMORY_REST_PORT')) { $doctorValues['AGENTMEMORY_REST_PORT'] } else { '3111' }
    foreach ($endpoint in @(
        @{ Name = 'LiteLLM'; Url = "http://127.0.0.1:$litellmPort/health/liveliness" },
        @{ Name = 'AgentMemory'; Url = "http://127.0.0.1:$agentMemoryPort/agentmemory/livez" }
    )) {
        try {
            $statusCode = & $HttpProbe $endpoint.Url
            if ([int]$statusCode -eq 200) {
                [void]$results.Add((New-DoctorResult -Name $endpoint.Name -Status 'PASS' -Detail 'local health endpoint is responding'))
            }
            else {
                [void]$results.Add((New-DoctorResult -Name $endpoint.Name -Status 'WARN' -Detail "health endpoint returned $statusCode"))
            }
        }
        catch {
            [void]$results.Add((New-DoctorResult -Name $endpoint.Name -Status 'WARN' -Detail 'not running or not yet healthy'))
        }
    }

    $results | Format-Table -AutoSize | Out-Host
    return @($results)
}

function Uninstall-AiStack {
    [CmdletBinding()]
    param(
        [switch]$DeleteData,
        [switch]$Force
    )

    Assert-AiStackEnvExists
    $arguments = @('down', '--remove-orphans')
    if ($DeleteData) {
        if (-not $Force) {
            $answer = Read-Host 'This permanently deletes AgentMemory data and Copilot OAuth state. Type DELETE to continue'
            if ($answer -cne 'DELETE') {
                throw 'Volume deletion cancelled.'
            }
        }
        $arguments += '--volumes'
    }
    Invoke-DockerCompose -Arguments $arguments
    Write-Host 'Containers and networks removed. Existing client configuration and local .env were preserved.'
}

Export-ModuleMember -Function @(
    'Get-DotEnvValues',
    'Initialize-AiStackConfiguration',
    'Merge-CopilotMcpConfig',
    'Merge-CodexMcpConfig',
    'Invoke-AiStackDoctor',
    'Start-AiStack',
    'Stop-AiStack',
    'Restart-AiStack',
    'Get-AiStackStatus',
    'Show-AiStackLogs',
    'Install-AiStackClients',
    'Uninstall-AiStack'
)
