[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'setup', 'configure', 'configure-tunnel', 'configure-edge', 'start', 'stop', 'restart', 'status', 'doctor', 'logs', 'install-clients', 'install-capture', 'import-sessions', 'enrich-sessions', 'uninstall')]
    [string]$Command = 'help',

    [ValidateSet('All', 'Copilot', 'Codex')]
    [string]$Client = 'All',

    [ValidateSet('All', 'Copilot', 'Pi', 'Hermes')]
    [string]$Agent = 'All',

    [ValidateSet('litellm', 'agentmemory', 'cloudflared')]
    [string]$Service,

    [ValidateSet('All', 'Hermes', 'Pi', 'Copilot', 'VSCode')]
    [string]$Source = 'All',

    [string]$RestHostname,
    [string]$ViewerHostname,
    [string]$ConsoleHostname,
    [string]$ConsoleOriginHostname,
    [string]$ServerUrl,
    [string]$SecretFile,

    [switch]$DisableConsole,
    [switch]$Tunnel,
    [switch]$DryRun,
    [switch]$DeleteData,
    [switch]$Force,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\AiStack.psm1') -Force

switch ($Command) {
    'help' {
        @'
ai-stack management

  .\ai-stack.ps1 setup
  .\ai-stack.ps1 configure [-NoOpen]
  .\ai-stack.ps1 configure-tunnel [-RestHostname api.mem.example.com] [-ViewerHostname mem.example.com] [-ConsoleHostname iii.mem.example.com] [-DisableConsole]
  .\ai-stack.ps1 configure-edge -RestHostname api.mem.example.com -ViewerHostname mem.example.com -ConsoleHostname iii.mem.example.com -ConsoleOriginHostname iii-origin.example.com
  .\ai-stack.ps1 start [-Tunnel]
  .\ai-stack.ps1 stop
  .\ai-stack.ps1 restart
  .\ai-stack.ps1 status
  .\ai-stack.ps1 doctor
  .\ai-stack.ps1 logs [-Service litellm|agentmemory|cloudflared]
  .\ai-stack.ps1 install-clients [-Client All|Copilot|Codex] [-ServerUrl https://api.mem.example.com] [-SecretFile C:\secure\agentmemory-secret]
  .\ai-stack.ps1 install-capture [-Agent All|Copilot|Pi|Hermes]
  .\ai-stack.ps1 import-sessions [-Source All|Hermes|Pi|Copilot|VSCode] [-DryRun] [-Force]
  .\ai-stack.ps1 enrich-sessions [-Source All|Hermes|Pi|Copilot|VSCode] [-DryRun] [-Force]
  .\ai-stack.ps1 uninstall [-DeleteData] [-Force]
'@
    }
    'setup' {
        Initialize-AiStackConfiguration
    }
    'configure' {
        $envPath = Initialize-AiStackConfiguration -PassThru
        if (-not $NoOpen) {
            Start-Process notepad.exe -ArgumentList @($envPath)
        }
        Write-Host "Configuration: $envPath"
    }
    'configure-tunnel' {
        Initialize-CloudflareTunnel `
            -RestHostname $RestHostname `
            -ViewerHostname $ViewerHostname `
            -ConsoleHostname $ConsoleHostname `
            -DisableConsole:$DisableConsole
    }
    'configure-edge' {
        Initialize-CloudflareEdge `
            -RestHostname $RestHostname `
            -ViewerHostname $ViewerHostname `
            -ConsoleHostname $ConsoleHostname `
            -ConsoleOriginHostname $ConsoleOriginHostname
    }
    'start' {
        Start-AiStack -Tunnel:$Tunnel
    }
    'stop' {
        Stop-AiStack
    }
    'restart' {
        Restart-AiStack
    }
    'status' {
        Get-AiStackStatus
    }
    'doctor' {
        $results = Invoke-AiStackDoctor
        if ($results.Status -contains 'FAIL') {
            exit 1
        }
    }
    'logs' {
        Show-AiStackLogs -Service $Service
    }
    'install-clients' {
        $installArguments = @{ Client = $Client }
        $resolvedServerUrl = $ServerUrl
        if (-not $PSBoundParameters.ContainsKey('ServerUrl')) {
            $resolvedServerUrl = Read-Host 'AgentMemory server URL (leave blank to use the local stack)'
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedServerUrl)) {
            $installArguments.ServerUrl = $resolvedServerUrl.Trim()
            $resolvedSecretFile = $SecretFile
            if (-not $PSBoundParameters.ContainsKey('SecretFile')) {
                do {
                    $resolvedSecretFile = Read-Host 'Path to the remote server agentmemory-secret file'
                } while ([string]::IsNullOrWhiteSpace($resolvedSecretFile))
            }
            $installArguments.SecretFile = $resolvedSecretFile
        }
        elseif ($PSBoundParameters.ContainsKey('SecretFile')) {
            throw 'SecretFile requires ServerUrl.'
        }
        Install-AiStackClients @installArguments
    }
    'install-capture' {
        Install-AiStackCapture -Agent $Agent
    }
    'import-sessions' {
        Import-AiStackSessions -Source $Source -DryRun:$DryRun -Force:$Force
    }
    'enrich-sessions' {
        Invoke-AiStackSessionEnrichment -Source $Source -DryRun:$DryRun -Force:$Force
    }
    'uninstall' {
        Uninstall-AiStack -DeleteData:$DeleteData -Force:$Force
    }
}
