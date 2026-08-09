[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'setup', 'configure', 'configure-tunnel', 'start', 'stop', 'restart', 'status', 'doctor', 'logs', 'install-clients', 'import-sessions', 'enrich-sessions', 'uninstall')]
    [string]$Command = 'help',

    [ValidateSet('All', 'Copilot', 'Codex')]
    [string]$Client = 'All',

    [ValidateSet('litellm', 'agentmemory', 'cloudflared')]
    [string]$Service,

    [ValidateSet('All', 'Hermes', 'Pi', 'Copilot', 'VSCode')]
    [string]$Source = 'All',

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
  .\ai-stack.ps1 configure-tunnel
  .\ai-stack.ps1 start [-Tunnel]
  .\ai-stack.ps1 stop
  .\ai-stack.ps1 restart
  .\ai-stack.ps1 status
  .\ai-stack.ps1 doctor
  .\ai-stack.ps1 logs [-Service litellm|agentmemory|cloudflared]
  .\ai-stack.ps1 install-clients [-Client All|Copilot|Codex]
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
        Initialize-CloudflareTunnel
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
        Install-AiStackClients -Client $Client
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
