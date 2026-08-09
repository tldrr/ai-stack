Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root = if ($env:AI_STACK_TEST_ROOT) {
    [System.IO.Path]::GetFullPath($env:AI_STACK_TEST_ROOT)
}
else {
    Split-Path $PSScriptRoot -Parent
}
$script:DataPath = if ($env:AI_STACK_TEST_DATA_PATH) {
    [System.IO.Path]::GetFullPath($env:AI_STACK_TEST_DATA_PATH)
}
else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ai-stack'
}
$script:EnvPath = Join-Path $script:DataPath '.env'
$script:EnvExamplePath = Join-Path $script:Root '.env.example'
$script:ComposePath = Join-Path $script:Root 'compose.yaml'
$script:StatePath = $script:DataPath
$script:McpLauncherPath = Join-Path $script:StatePath 'agentmemory-mcp.ps1'
$script:AgentMemorySecretPath = Join-Path $script:StatePath 'agentmemory-secret'
$script:CloudflareStatePath = Join-Path $script:StatePath 'cloudflared'
$script:CloudflareConfigPath = Join-Path $script:CloudflareStatePath 'config.yml'
$script:CloudflareCredentialsPath = Join-Path $script:CloudflareStatePath 'credentials.json'
$script:AgentMemoryDataPath = Join-Path $script:DataPath 'data\agentmemory'
$script:CopilotDataPath = Join-Path $script:DataPath 'data\github-copilot'
$script:LegacyEnvPath = Join-Path $script:Root '.env'
$script:LegacyStatePath = Join-Path $script:Root '.state'
$script:LegacyRepoDataPath = Join-Path $script:Root '.ai-stack'
$script:ClientHome = if ($env:AI_STACK_TEST_CLIENT_HOME) {
    [System.IO.Path]::GetFullPath($env:AI_STACK_TEST_CLIENT_HOME)
}
else {
    [Environment]::GetFolderPath('UserProfile')
}
$script:MigrationPerformed = $false

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

function Protect-AiStackData {
    if ($env:OS -ne 'Windows_NT' -or
        -not (Test-Path -LiteralPath $script:DataPath)) {
        return
    }
    $icacls = Get-Command icacls.exe -ErrorAction SilentlyContinue
    if (-not $icacls) {
        throw 'Cannot secure .ai-stack because icacls.exe is unavailable.'
    }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    & $icacls.Source $script:DataPath /inheritance:d /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to disable inherited permissions on .ai-stack.'
    }
    $existingSids = @((Get-Acl -LiteralPath $script:DataPath).Access | ForEach-Object {
        try {
            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            throw "Cannot resolve ACL identity '$($_.IdentityReference)'."
        }
    } | Select-Object -Unique)
    foreach ($sid in $existingSids | Where-Object { $_ -notin $allowedSids }) {
        & $icacls.Source $script:DataPath /remove "*$sid" /Q | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to remove unexpected ACL principal '$sid' from .ai-stack."
        }
    }
    $grantArguments = @(
        $script:DataPath,
        '/grant:r',
        "*${currentSid}:(OI)(CI)F",
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F',
        '/Q'
    )
    & $icacls.Source @grantArguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to grant restricted permissions on .ai-stack.'
    }
    $permissionMarker = Join-Path $script:DataPath '.permissions-v1'
    if (-not (Test-Path -LiteralPath $permissionMarker)) {
        foreach ($item in Get-ChildItem -LiteralPath $script:DataPath -Recurse -Force) {
            & $icacls.Source $item.FullName /reset /Q 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $item.FullName)) {
                throw "Failed to inherit restricted permissions on '$($item.FullName)'."
            }
        }
        Write-Utf8NoBom -Path $permissionMarker -Content "1$([Environment]::NewLine)"
    }
}

function Move-LegacyAiStackState {
    $legacyRepoDataExists = $script:LegacyRepoDataPath -ne $script:DataPath -and
        (Test-Path -LiteralPath $script:LegacyRepoDataPath)
    $legacyEnvExists = Test-Path -LiteralPath $script:LegacyEnvPath
    $legacyStateExists = Test-Path -LiteralPath $script:LegacyStatePath
    if (-not $legacyRepoDataExists -and -not $legacyEnvExists -and -not $legacyStateExists) {
        return
    }
    if ($legacyRepoDataExists -and (Test-DirectoryHasData -Path $script:DataPath)) {
        throw "Both repository-local state '$script:LegacyRepoDataPath' and home state '$script:DataPath' contain data. Reconcile them manually before continuing."
    }
    if ($legacyRepoDataExists -and $legacyEnvExists -and
        (Test-Path -LiteralPath (Join-Path $script:LegacyRepoDataPath '.env'))) {
        throw 'Both repository .env and repository-local .ai-stack\.env exist. Reconcile them manually before continuing.'
    }
    if ($legacyEnvExists -and (Test-Path -LiteralPath $script:EnvPath)) {
        throw 'Both repository .env and home .ai-stack\.env exist. Reconcile them manually before continuing.'
    }
    if ($legacyStateExists) {
        foreach ($name in @('agentmemory-secret', 'agentmemory-mcp.ps1', 'cloudflared')) {
            $source = Join-Path $script:LegacyStatePath $name
            $destination = Join-Path $script:DataPath $name
            if ($legacyRepoDataExists) {
                $destination = Join-Path $script:LegacyRepoDataPath $name
            }
            if ((Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $destination)) {
                throw "Both legacy and current ai-stack state exist for '$name'. Reconcile them manually before continuing."
            }
        }
    }
    if ($legacyRepoDataExists) {
        if (Test-Path -LiteralPath $script:DataPath) {
            Remove-Item -LiteralPath $script:DataPath -Force
        }
        Move-Item -LiteralPath $script:LegacyRepoDataPath -Destination $script:DataPath
    }
    elseif (-not (Test-Path -LiteralPath $script:DataPath)) {
        New-Item -ItemType Directory -Path $script:DataPath -Force | Out-Null
    }
    if ($legacyEnvExists) {
        Move-Item -LiteralPath $script:LegacyEnvPath -Destination $script:EnvPath
    }
    if ($legacyStateExists) {
        foreach ($name in @('agentmemory-secret', 'agentmemory-mcp.ps1', 'cloudflared')) {
            $source = Join-Path $script:LegacyStatePath $name
            if (-not (Test-Path -LiteralPath $source)) {
                continue
            }
            $destination = Join-Path $script:DataPath $name
            Move-Item -LiteralPath $source -Destination $destination
        }
        if (@(Get-ChildItem -LiteralPath $script:LegacyStatePath -Force).Count -eq 0) {
            Remove-Item -LiteralPath $script:LegacyStatePath -Force
        }
        else {
            Write-Warning "Unrecognized files remain in '$script:LegacyStatePath'; they were not moved or deleted."
        }
    }
    Protect-AiStackData
    $script:MigrationPerformed = $true
    Write-Host "Migrated generated runtime state to '$script:DataPath'."
}

function New-McpLauncher {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        New-Item -ItemType Directory -Path $script:StatePath | Out-Null
    }

    $relativeEnvPath = '.env'
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

function Update-MigratedClientLaunchers {
    if (-not $script:MigrationPerformed) {
        return
    }

    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $script:ClientHome '.copilot' }
    $copilotConfig = Join-Path $copilotHome 'mcp-config.json'
    if (Test-Path -LiteralPath $copilotConfig) {
        try {
            $config = [System.IO.File]::ReadAllText($copilotConfig) | ConvertFrom-Json
        }
        catch {
            throw "Cannot inspect malformed Copilot MCP JSON at '$copilotConfig': $($_.Exception.Message)"
        }
        if ($config.PSObject.Properties['mcpServers'] -and
            $config.mcpServers.PSObject.Properties['agentmemory']) {
            [void](Merge-CopilotMcpConfig -Path $copilotConfig -LauncherPath $script:McpLauncherPath)
        }
    }

    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $script:ClientHome '.codex' }
    $codexConfig = Join-Path $codexHome 'config.toml'
    if ((Test-Path -LiteralPath $codexConfig) -and
        ([System.IO.File]::ReadAllText($codexConfig) -match '(?m)^\[mcp_servers\.agentmemory\]')) {
        [void](Merge-CodexMcpConfig -Path $codexConfig -LauncherPath $script:McpLauncherPath)
    }
}

function Test-DirectoryHasData {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Test-Path -LiteralPath $Path) -and
        (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0)
}

function Test-DockerAvailable {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & docker info --format '{{.ServerVersion}}' *> $null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
        $global:LASTEXITCODE = 0
    }
}

function Test-DockerVolumeExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & docker volume inspect $Name *> $null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
        $global:LASTEXITCODE = 0
    }
}

function Get-AiStackProjectName {
    if (-not [string]::IsNullOrWhiteSpace($env:COMPOSE_PROJECT_NAME)) {
        return $env:COMPOSE_PROJECT_NAME.Trim()
    }
    $values = Get-DotEnvValues -Path $script:EnvPath
    if ($values.ContainsKey('COMPOSE_PROJECT_NAME') -and
        -not [string]::IsNullOrWhiteSpace($values['COMPOSE_PROJECT_NAME'])) {
        return $values['COMPOSE_PROJECT_NAME'].Trim().Trim('"').Trim("'")
    }
    return 'ai-stack'
}

function Move-LegacyDockerData {
    param([Parameter(Mandatory = $true)][string]$ProjectName)

    foreach ($path in @($script:AgentMemoryDataPath, $script:CopilotDataPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }
    if (-not (Test-DockerAvailable)) {
        return
    }

    $migrations = @(
        @{ Volume = "$ProjectName`_agentmemory-data"; Destination = $script:AgentMemoryDataPath },
        @{ Volume = "$ProjectName`_github-copilot-token"; Destination = $script:CopilotDataPath }
    )
    $pendingMigrations = @($migrations | Where-Object {
        Test-DockerVolumeExists -Name $_.Volume
    })
    foreach ($migration in $pendingMigrations) {
        if (Test-DirectoryHasData -Path $migration.Destination) {
            throw "Both legacy Docker volume '$($migration.Volume)' and '$($migration.Destination)' contain data. Reconcile them manually before continuing."
        }

        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            $runningContainers = @(& docker ps --filter "volume=$($migration.Volume)" --format '{{.ID}}' 2>$null)
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
            $global:LASTEXITCODE = 0
        }
        if ($runningContainers.Count -gt 0) {
            throw "Docker volume '$($migration.Volume)' is in use. Run '.\ai-stack.ps1 stop', then rerun setup to migrate it safely."
        }
    }

    foreach ($migration in $pendingMigrations) {
        Write-Host "Migrating Docker volume '$($migration.Volume)' to '$($migration.Destination)'..."
        & docker run --rm `
            --mount "type=volume,source=$($migration.Volume),target=/source,readonly" `
            --mount "type=bind,source=$($migration.Destination),target=/destination" `
            alpine:3.22 sh -c 'cp -a /source/. /destination/'
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to migrate Docker volume '$($migration.Volume)'. The source volume was preserved."
        }
        & docker volume rm $migration.Volume
        if ($LASTEXITCODE -ne 0) {
            throw "Data was copied, but legacy Docker volume '$($migration.Volume)' could not be removed."
        }
    }
}

function Remove-LegacyDockerData {
    param([Parameter(Mandatory = $true)][string]$ProjectName)

    if (-not (Test-DockerAvailable)) {
        return
    }
    foreach ($volume in @(
        "$ProjectName`_agentmemory-data",
        "$ProjectName`_github-copilot-token"
    )) {
        if (Test-DockerVolumeExists -Name $volume) {
            & docker volume rm $volume
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove legacy Docker volume '$volume'."
            }
        }
    }
}

function Initialize-AiStackConfiguration {
    [CmdletBinding()]
    param([switch]$PassThru)

    Move-LegacyAiStackState
    if (-not (Test-Path -LiteralPath $script:DataPath)) {
        New-Item -ItemType Directory -Path $script:DataPath -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:EnvPath)) {
        Copy-Item -LiteralPath $script:EnvExamplePath -Destination $script:EnvPath
    }

    $content = [System.IO.File]::ReadAllText($script:EnvPath)
    $values = Get-DotEnvValues -Path $script:EnvPath

    foreach ($default in ([ordered]@{
        AGENTMEMORY_CONSOLE_PORT = '3114'
        AGENTMEMORY_INJECT_CONTEXT = 'true'
        AGENTMEMORY_AUTO_COMPRESS = 'false'
    }).GetEnumerator()) {
        if (-not $values.ContainsKey($default.Key)) {
            $content = Set-DotEnvValue -Content $content -Name $default.Key -Value $default.Value
        }
    }
    if ((-not $values.ContainsKey('LITELLM_MASTER_KEY')) -or
        [string]::IsNullOrWhiteSpace($values['LITELLM_MASTER_KEY']) -or
        $values['LITELLM_MASTER_KEY'] -eq 'change-me-generated-by-setup') {
        $content = Set-DotEnvValue -Content $content -Name 'LITELLM_MASTER_KEY' -Value (New-AiStackSecret -Prefix 'sk-local-')
    }
    $content = Set-DotEnvValue -Content $content -Name 'AI_STACK_HOME' -Value $script:DataPath.Replace('\', '/')
    Write-Utf8NoBom -Path $script:EnvPath -Content $content
    $projectName = Get-AiStackProjectName
    Move-LegacyDockerData -ProjectName $projectName
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        New-Item -ItemType Directory -Path $script:StatePath | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:AgentMemorySecretPath) -or
        [string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($script:AgentMemorySecretPath))) {
        if (Test-DirectoryHasData -Path $script:AgentMemoryDataPath) {
            throw 'AgentMemory data exists but ~\.ai-stack\agentmemory-secret is missing. Restore the matching secret backup or intentionally delete ~\.ai-stack\data\agentmemory before running setup.'
        }
        Write-Utf8NoBom -Path $script:AgentMemorySecretPath -Content (New-AiStackSecret -Prefix 'am_')
    }
    New-McpLauncher
    Update-MigratedClientLaunchers
    Protect-AiStackData
    Write-Host "Local configuration initialized in '$script:DataPath'."
    if ($PassThru) {
        return $script:EnvPath
    }
}

function Get-ComposeArguments {
    $arguments = @(
        'compose',
        '--project-name', (Get-AiStackProjectName),
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
    $previousHome = [Environment]::GetEnvironmentVariable('AI_STACK_HOME', 'Process')
    $env:AI_STACK_HOME = $script:DataPath.Replace('\', '/')
    try {
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
    finally {
        if ($null -eq $previousHome) {
            Remove-Item Env:\AI_STACK_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AI_STACK_HOME = $previousHome
        }
    }
}

function Assert-CloudflareHostname {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Hostname
    )

    $pattern = '^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
    if ($Hostname -notmatch $pattern) {
        throw "$Name must be a valid fully qualified hostname."
    }
}

function New-CloudflareTunnelConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TunnelId,
        [Parameter(Mandatory = $true)][string]$RestHostname,
        [Parameter(Mandatory = $true)][string]$ViewerHostname,
        [string]$Path = $script:CloudflareConfigPath
    )

    $parsedTunnelId = [guid]::Empty
    if (-not [guid]::TryParse($TunnelId, [ref]$parsedTunnelId)) {
        throw 'TunnelId must be a valid UUID.'
    }
    Assert-CloudflareHostname -Name 'CLOUDFLARE_REST_HOSTNAME' -Hostname $RestHostname
    Assert-CloudflareHostname -Name 'CLOUDFLARE_VIEWER_HOSTNAME' -Hostname $ViewerHostname
    if ($RestHostname -ieq $ViewerHostname) {
        throw 'Cloudflare REST and viewer hostnames must be different.'
    }

    $content = @"
tunnel: $($parsedTunnelId.ToString())
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: $RestHostname
    service: http://agentmemory:3111
  - hostname: $ViewerHostname
    service: http://agentmemory:3113
  - service: http_status:404
"@ + [Environment]::NewLine

    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $existing = if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::ReadAllText($Path)
    }
    else {
        ''
    }
    if ($existing -eq $content) {
        return $false
    }
    Write-Utf8NoBom -Path $Path -Content $content
    return $true
}

function Get-CloudflaredCommand {
    foreach ($name in @('cloudflared.exe', 'cloudflared')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    throw 'cloudflared was not found on PATH. Install the pinned or current stable Cloudflare Tunnel client first.'
}

function Invoke-CloudflaredCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 wraps native stderr as ErrorRecord objects,
        # while cloudflared writes normal diagnostics there.
        $ErrorActionPreference = 'Continue'
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) {
        throw "cloudflared failed: $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Get-CloudflareOriginCertificatePath {
    if (-not [string]::IsNullOrWhiteSpace($env:TUNNEL_ORIGIN_CERT) -and
        (Test-Path -LiteralPath $env:TUNNEL_ORIGIN_CERT)) {
        return [System.IO.Path]::GetFullPath($env:TUNNEL_ORIGIN_CERT)
    }
    $candidate = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cloudflared\cert.pem'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return $null
}

function Get-CloudflareTunnelIdFromCredentials {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $credentials = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        throw "Cannot read Cloudflare tunnel credentials at '$Path': $($_.Exception.Message)"
    }
    $tunnelId = [string]$credentials.TunnelID
    $parsedTunnelId = [guid]::Empty
    if (-not [guid]::TryParse($tunnelId, [ref]$parsedTunnelId)) {
        throw "Cloudflare credentials at '$Path' do not contain a valid TunnelID."
    }
    return $parsedTunnelId.ToString()
}

function Find-CloudflareTunnelsByName {
    param(
        $Tunnels,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return @($Tunnels | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties['name'] -and $_.name -eq $Name
    })
}

function Initialize-CloudflareTunnel {
    [CmdletBinding()]
    param()

    Initialize-AiStackConfiguration
    $values = Get-DotEnvValues -Path $script:EnvPath
    $tunnelName = if ($values.ContainsKey('CLOUDFLARE_TUNNEL_NAME')) {
        $values['CLOUDFLARE_TUNNEL_NAME']
    }
    else {
        'ai-stack'
    }
    if ($tunnelName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') {
        throw 'CLOUDFLARE_TUNNEL_NAME contains unsupported characters.'
    }
    foreach ($name in @('CLOUDFLARE_REST_HOSTNAME', 'CLOUDFLARE_VIEWER_HOSTNAME')) {
        if (-not $values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($values[$name]) -or
            $values[$name] -like '*.example.com') {
            throw "$name must be set to a real hostname in ~\.ai-stack\.env."
        }
    }

    $cloudflared = Get-CloudflaredCommand
    $originCertificate = Get-CloudflareOriginCertificatePath
    if (-not $originCertificate) {
        Write-Host 'Cloudflare authorization is required once. Complete the browser flow that opens.'
        [void](Invoke-CloudflaredCommand -Command $cloudflared -Arguments @('tunnel', 'login'))
        $originCertificate = Get-CloudflareOriginCertificatePath
        if (-not $originCertificate) {
            throw 'Cloudflare login completed without creating ~/.cloudflared/cert.pem.'
        }
    }

    if (-not (Test-Path -LiteralPath $script:CloudflareStatePath)) {
        New-Item -ItemType Directory -Path $script:CloudflareStatePath -Force | Out-Null
    }

    if (Test-Path -LiteralPath $script:CloudflareCredentialsPath) {
        $tunnelId = Get-CloudflareTunnelIdFromCredentials -Path $script:CloudflareCredentialsPath
    }
    else {
        $listOutput = Invoke-CloudflaredCommand -Command $cloudflared -Arguments @(
            'tunnel', '--origincert', $originCertificate, 'list', '--output', 'json'
        )
        try {
            $tunnels = @(($listOutput -join [Environment]::NewLine) | ConvertFrom-Json)
        }
        catch {
            throw "cloudflared returned invalid tunnel list JSON: $($_.Exception.Message)"
        }
        $matchingTunnels = @(Find-CloudflareTunnelsByName -Tunnels $tunnels -Name $tunnelName)
        if ($matchingTunnels.Count -gt 0) {
            throw "Tunnel '$tunnelName' already exists but its local credentials are missing. Restore ~\.ai-stack\cloudflared\credentials.json or choose a different CLOUDFLARE_TUNNEL_NAME."
        }

        [void](Invoke-CloudflaredCommand -Command $cloudflared -Arguments @(
            'tunnel', '--origincert', $originCertificate, 'create',
            '--credentials-file', $script:CloudflareCredentialsPath,
            '--output', 'json', $tunnelName
        ))
        $tunnelId = Get-CloudflareTunnelIdFromCredentials -Path $script:CloudflareCredentialsPath
    }

    [void](New-CloudflareTunnelConfig `
        -TunnelId $tunnelId `
        -RestHostname $values['CLOUDFLARE_REST_HOSTNAME'] `
        -ViewerHostname $values['CLOUDFLARE_VIEWER_HOSTNAME'])

    [void](Invoke-CloudflaredCommand -Command $cloudflared -Arguments @(
        'tunnel', '--config', $script:CloudflareConfigPath, 'ingress', 'validate'
    ))
    foreach ($hostname in @($values['CLOUDFLARE_REST_HOSTNAME'], $values['CLOUDFLARE_VIEWER_HOSTNAME'])) {
        [void](Invoke-CloudflaredCommand -Command $cloudflared -Arguments @(
            'tunnel', '--origincert', $originCertificate, 'route', 'dns',
            '--overwrite-dns', $tunnelId, $hostname
        ))
    }

    Write-Host "Cloudflare tunnel '$tunnelName' is configured from $script:CloudflareConfigPath."
    Write-Host 'Run .\ai-stack.ps1 start -Tunnel to launch its Docker-managed connector.'
}

function Assert-TunnelConfigured {
    foreach ($path in @($script:CloudflareConfigPath, $script:CloudflareCredentialsPath)) {
        if (-not (Test-Path -LiteralPath $path) -or
            [string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($path))) {
            throw 'The local Cloudflare tunnel is not configured. Run .\ai-stack.ps1 configure-tunnel first.'
        }
    }
    [void](Get-CloudflareTunnelIdFromCredentials -Path $script:CloudflareCredentialsPath)
}

function Assert-AiStackEnvExists {
    Move-LegacyAiStackState
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
        # public tunnel. Removing its container records that this was an
        # intentional disable, while restart can still recover crashed tunnels.
        Invoke-DockerCompose -Arguments @('--profile', 'tunnel', 'rm', '--stop', '--force', 'cloudflared')
    }
    Invoke-DockerCompose -Arguments $arguments
}

function Stop-AiStack {
    Assert-AiStackEnvExists
    Invoke-DockerCompose -Arguments @('--profile', 'tunnel', 'down')
}

function Restart-AiStack {
    Initialize-AiStackConfiguration
    $runningServices = @(
        Invoke-DockerCompose `
            -Arguments @('--profile', 'tunnel', 'ps', '--all', '--services') `
            -Capture
    )
    $arguments = @('up', '-d', '--build')
    if ($runningServices -contains 'cloudflared') {
        $arguments = @('--profile', 'tunnel') + $arguments
    }
    Invoke-DockerCompose -Arguments $arguments
}

function Get-AiStackStatus {
    Assert-AiStackEnvExists
    Invoke-DockerCompose -Arguments @('--profile', 'tunnel', 'ps')
}

function Show-AiStackLogs {
    param([string]$Service)

    Assert-AiStackEnvExists
    $arguments = @('--profile', 'tunnel', 'logs', '--follow', '--tail', '200')
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

function Invoke-AiStackNative {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rawOutput = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $output = @($rawOutput | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        }
        else {
            [string]$_
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Invoke-IdempotentNative {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $result = Invoke-AiStackNative -Command $Command -Arguments $Arguments
    if ($result.ExitCode -ne 0 -and
        ($result.Output -join ' ') -notmatch '(?i)already (?:added|installed|exists)') {
        throw "$Command failed: $($result.Output -join [Environment]::NewLine)"
    }
    if ($result.Output) {
        Write-Host ($result.Output -join [Environment]::NewLine)
    }
}

function Test-CopilotPluginInstalled {
    param([Parameter(Mandatory = $true)][string]$Command)

    $result = Invoke-AiStackNative -Command $Command -Arguments @('plugin', 'list')
    if ($result.ExitCode -ne 0) {
        throw "$Command plugin list failed: $($result.Output -join [Environment]::NewLine)"
    }
    return ($result.Output -join [Environment]::NewLine) -match
        '(?im)^\s*(?:[^\w\s]\s*)?agentmemory\s+\(v'
}

function Get-CodexPluginState {
    param([Parameter(Mandatory = $true)][string]$Command)

    $marketplaceResult = Invoke-AiStackNative `
        -Command $Command `
        -Arguments @('plugin', 'marketplace', 'list', '--json')
    if ($marketplaceResult.ExitCode -ne 0) {
        throw "$Command plugin marketplace list failed: $($marketplaceResult.Output -join [Environment]::NewLine)"
    }
    $pluginResult = Invoke-AiStackNative `
        -Command $Command `
        -Arguments @('plugin', 'list', '--json')
    if ($pluginResult.ExitCode -ne 0) {
        throw "$Command plugin list failed: $($pluginResult.Output -join [Environment]::NewLine)"
    }
    try {
        $marketplaces = ($marketplaceResult.Output -join [Environment]::NewLine) | ConvertFrom-Json
        $plugins = ($pluginResult.Output -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Cannot parse Codex plugin state: $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        MarketplaceInstalled = @($marketplaces.marketplaces).name -contains 'agentmemory'
        PluginInstalled = @($plugins.installed).pluginId -contains 'agentmemory@agentmemory'
    }
}

function Get-AiStackClientCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$WinGetPackage,
        [Parameter(Mandatory = $true)][string]$WinGetExecutable
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    if ($env:OS -eq 'Windows_NT') {
        $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        $packagePath = Get-ChildItem -LiteralPath $packages -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "${WinGetPackage}_*" } |
            Select-Object -First 1 -ExpandProperty FullName
        $candidate = if ($packagePath) {
            Get-ChildItem -LiteralPath $packagePath `
                -Filter $WinGetExecutable -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
        }
        if ($candidate) {
            return $candidate
        }
    }
    return $null
}

function Install-AiStackClients {
    [CmdletBinding()]
    param([ValidateSet('All', 'Copilot', 'Codex')][string]$Client = 'All')

    Initialize-AiStackConfiguration
    $homePath = $script:ClientHome

    if ($Client -in @('All', 'Copilot')) {
        $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $homePath '.copilot' }
        $copilotConfig = Join-Path $copilotHome 'mcp-config.json'
        [void](Merge-CopilotMcpConfig -Path $copilotConfig -LauncherPath $script:McpLauncherPath)
        $copilotCommand = Get-AiStackClientCommand `
            -Name 'copilot' `
            -WinGetPackage 'GitHub.Copilot' `
            -WinGetExecutable 'copilot.exe'
        if ($copilotCommand) {
            if (Test-CopilotPluginInstalled -Command $copilotCommand) {
                Write-Host 'Copilot AgentMemory plugin is already installed.'
            }
            else {
                Invoke-IdempotentNative -Command $copilotCommand -Arguments @('plugin', 'install', 'rohitg00/agentmemory:plugin')
            }
        }
        else {
            Write-Warning 'Copilot CLI was not found. MCP configuration was installed; run the official plugin command after installing Copilot CLI.'
        }
    }

    if ($Client -in @('All', 'Codex')) {
        $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $homePath '.codex' }
        $codexConfig = Join-Path $codexHome 'config.toml'
        [void](Merge-CodexMcpConfig -Path $codexConfig -LauncherPath $script:McpLauncherPath)
        $codexCommand = Get-AiStackClientCommand `
            -Name 'codex' `
            -WinGetPackage 'OpenAI.Codex' `
            -WinGetExecutable 'codex-*-windows-msvc.exe'
        if ($codexCommand) {
            $codexState = Get-CodexPluginState -Command $codexCommand
            if (-not $codexState.MarketplaceInstalled) {
                Invoke-IdempotentNative -Command $codexCommand -Arguments @('plugin', 'marketplace', 'add', 'rohitg00/agentmemory')
            }
            if (-not $codexState.PluginInstalled) {
                Invoke-IdempotentNative -Command $codexCommand -Arguments @('plugin', 'add', 'agentmemory@agentmemory')
            }
            if ($codexState.MarketplaceInstalled -and $codexState.PluginInstalled) {
                Write-Host 'Codex AgentMemory marketplace and plugin are already installed.'
            }
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
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3
            [pscustomobject]@{
                StatusCode = $response.StatusCode
                Content = $response.Content
            }
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
    $consolePort = if ($doctorValues.ContainsKey('AGENTMEMORY_CONSOLE_PORT')) { $doctorValues['AGENTMEMORY_CONSOLE_PORT'] } else { '3114' }
    foreach ($endpoint in @(
        @{ Name = 'LiteLLM'; Url = "http://127.0.0.1:$litellmPort/health/liveliness" },
        @{ Name = 'AgentMemory'; Url = "http://127.0.0.1:$agentMemoryPort/agentmemory/livez" },
        @{ Name = 'iii Console'; Url = "http://127.0.0.1:$consolePort/api/engine/_console/health"; ExpectedJsonStatus = 'healthy' }
    )) {
        try {
            $probeResult = & $HttpProbe $endpoint.Url
            $statusCode = if ($probeResult -is [int]) {
                $probeResult
            }
            else {
                $probeResult.StatusCode
            }
            if ([int]$statusCode -eq 200) {
                if ($endpoint.ContainsKey('ExpectedJsonStatus') -and
                    $probeResult -isnot [int] -and
                    $probeResult.Content) {
                    $health = $probeResult.Content | ConvertFrom-Json
                    if ($health.status -ne $endpoint.ExpectedJsonStatus) {
                        [void]$results.Add((New-DoctorResult -Name $endpoint.Name -Status 'WARN' -Detail "engine health is '$($health.status)'"))
                        continue
                    }
                }
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

    foreach ($captureResult in @(Get-AiStackCaptureDoctorResults)) {
        [void]$results.Add($captureResult)
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
    $projectName = Get-AiStackProjectName
    $arguments = @('--profile', 'tunnel', 'down', '--remove-orphans')
    if ($DeleteData) {
        if (-not $Force) {
            $answer = Read-Host 'This permanently deletes AgentMemory data and Copilot OAuth state. Type DELETE to continue'
            if ($answer -cne 'DELETE') {
                throw 'Data deletion cancelled.'
            }
        }
    }
    Invoke-DockerCompose -Arguments $arguments
    if ($DeleteData) {
        foreach ($path in @($script:AgentMemoryDataPath, $script:CopilotDataPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        }
        Remove-LegacyDockerData -ProjectName $projectName
        Write-Host 'Containers, network, AgentMemory data, and Copilot OAuth state removed. Home configuration and local secrets were preserved.'
    }
    else {
        Move-LegacyDockerData -ProjectName $projectName
        Write-Host 'Containers and network removed. Existing client configuration and home .ai-stack runtime state were preserved.'
    }
}

. (Join-Path $PSScriptRoot 'SessionImport.ps1')
. (Join-Path $PSScriptRoot 'CaptureInstall.ps1')

Export-ModuleMember -Function @(
    'Get-DotEnvValues',
    'Initialize-AiStackConfiguration',
    'New-CloudflareTunnelConfig',
    'Initialize-CloudflareTunnel',
    'Merge-CopilotMcpConfig',
    'Merge-CodexMcpConfig',
    'Invoke-AiStackDoctor',
    'Start-AiStack',
    'Stop-AiStack',
    'Restart-AiStack',
    'Get-AiStackStatus',
    'Show-AiStackLogs',
    'Install-AiStackClients',
    'Install-AiStackCapture',
    'Import-AiStackSessions',
    'Invoke-AiStackSessionEnrichment',
    'Uninstall-AiStack'
)
