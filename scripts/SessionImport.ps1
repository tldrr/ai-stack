Set-StrictMode -Version 2.0

$script:ImportStatePath = Join-Path $script:DataPath 'imports'
$script:ImportManifestPath = Join-Path $script:ImportStatePath 'manifest.json'
$script:EnrichmentManifestPath = Join-Path $script:ImportStatePath 'enrichment-manifest.json'
$script:DerivedInvalidationPath = Join-Path $script:ImportStatePath 'derived-invalidation.json'
$script:ConsolidationManifestPath = Join-Path $script:ImportStatePath 'consolidation-manifest.json'
$script:CopilotSessionReaderPath = Join-Path $script:Root 'scripts\read-copilot-sessions.mjs'
$script:EnrichmentRunnerPath = Join-Path $script:Root 'scripts\enrich-agentmemory.mjs'

function Get-AiStackImportHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function New-AiStackImportId {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Value
    )

    return "$Prefix`_$((Get-AiStackImportHash -Value $Value).Substring(0, 32))"
}

function Protect-AiStackImportText {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $safe = [regex]::Replace($Text, "`0", '')
    $safe = [regex]::Replace(
        $safe,
        '(?is)-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
        '[REDACTED PRIVATE KEY]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?im)^(\s*(?:authorization|proxy-authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|auth[_-]?token|bearer[_-]?token|password|passwd|secret)\s*[:=]\s*).+$',
        '$1[REDACTED]'
    )
    $safe = [regex]::Replace($safe, '(?i)\bBearer\s+[A-Za-z0-9._~+/\-=]{16,}', 'Bearer [REDACTED]')
    $safe = [regex]::Replace($safe, '\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}\b', '[REDACTED GITHUB TOKEN]')
    $safe = [regex]::Replace($safe, '\bsk-[A-Za-z0-9_-]{20,}\b', '[REDACTED API KEY]')
    $safe = [regex]::Replace(
        $safe,
        '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
        '[REDACTED JWT]'
    )
    return $safe.Trim()
}

function Get-AiStackImportText {
    param($Content)

    if ($null -eq $Content) {
        return ''
    }
    if ($Content -is [string]) {
        return [string]$Content
    }
    if ($Content -is [System.Collections.IEnumerable] -and $Content -isnot [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.ArrayList
        foreach ($item in $Content) {
            if ($item -is [string]) {
                [void]$parts.Add([string]$item)
            }
            elseif ($item -and $item.PSObject.Properties['text'] -and $item.text -is [string]) {
                [void]$parts.Add([string]$item.text)
            }
            elseif ($item -and
                $item.PSObject.Properties['type'] -and
                $item.type -in @('text', 'input_text', 'output_text') -and
                $item.PSObject.Properties['content'] -and
                $item.content -is [string]) {
                [void]$parts.Add([string]$item.content)
            }
        }
        return ($parts -join [Environment]::NewLine)
    }
    if ($Content.PSObject.Properties['text'] -and $Content.text -is [string]) {
        return [string]$Content.text
    }
    return ''
}

function ConvertTo-AiStackIsoTimestamp {
    param(
        $Value,
        [datetime]$Fallback = [datetime]::UtcNow
    )

    if ($null -ne $Value -and "$Value" -match '^\d{12,}$') {
        try {
            return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value).UtcDateTime.ToString('o')
        }
        catch {}
    }
    if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace("$Value")) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse(
            "$Value",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed
        )) {
            return $parsed.ToUniversalTime().ToString('o')
        }
    }
    return $Fallback.ToUniversalTime().ToString('o')
}

function Resolve-AiStackImportProject {
    param(
        [AllowNull()][AllowEmptyString()][string]$Repository,
        [AllowNull()][AllowEmptyString()][string]$Cwd,
        [Parameter(Mandatory = $true)][string]$Fallback
    )

    if (-not [string]::IsNullOrWhiteSpace($Repository)) {
        return $Repository.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        $trimmed = $Cwd.TrimEnd('\', '/')
        $leaf = @($trimmed -split '[\\/]')[-1]
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
            return $leaf
        }
    }
    return $Fallback
}

function New-AiStackImportMessage {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('user', 'assistant')][string]$Role,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $safeText = Protect-AiStackImportText -Text $Text
    if ([string]::IsNullOrWhiteSpace($safeText)) {
        return $null
    }
    return [pscustomobject]@{
        Role = $Role
        Text = $safeText
        Timestamp = $Timestamp
    }
}

function New-AiStackNormalizedSession {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Cwd,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Messages,
        [AllowNull()][string]$Model
    )

    $safeMessages = @($Messages | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.Text) })
    if ($safeMessages.Count -eq 0) {
        return $null
    }
    $importId = New-AiStackImportId -Prefix "import_$($Source.ToLowerInvariant())" -Value $SourceId
    $fingerprint = ($safeMessages | ForEach-Object {
        "$($_.Role)|$($_.Timestamp)|$(Get-AiStackImportHash -Value $_.Text)"
    }) -join "`n"
    return [pscustomobject]@{
        Id = $importId
        NativeId = $SourceId
        Source = $Source
        Project = $Project
        Cwd = $Cwd
        Model = $Model
        Messages = $safeMessages
        ContentHash = Get-AiStackImportHash -Value "$Source|$SourceId|$Project|$fingerprint"
    }
}

function Get-HermesImportSessions {
    $root = Join-Path $env:LOCALAPPDATA 'hermes\sessions'
    if (-not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $records = New-Object System.Collections.ArrayList
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File | Sort-Object Name) {
        try {
            $dump = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        }
        catch {
            Write-Warning "Skipping malformed Hermes session dump '$($file.Name)'."
            continue
        }
        $sourceId = if ($dump.PSObject.Properties['session_id'] -and $dump.session_id) {
            [string]$dump.session_id
        }
        else {
            [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        }
        [void]$records.Add([pscustomobject]@{
            Dump = $dump
            SourceId = $sourceId
            Timestamp = ConvertTo-AiStackIsoTimestamp -Value $dump.timestamp -Fallback $file.LastWriteTimeUtc
            FileName = $file.Name
        })
    }

    $groups = @{}
    foreach ($record in $records | Sort-Object SourceId, Timestamp, FileName) {
        $dump = $record.Dump
        $sourceId = $record.SourceId
        $timestamp = $record.Timestamp
        if (-not $groups.ContainsKey($sourceId)) {
            $groups[$sourceId] = [ordered]@{
                Messages = New-Object System.Collections.ArrayList
                StartedAt = $null
                EndedAt = $null
                Model = $null
            }
        }
        $group = $groups[$sourceId]
        if (-not $group.StartedAt -or $timestamp -lt $group.StartedAt) { $group.StartedAt = $timestamp }
        if (-not $group.EndedAt -or $timestamp -gt $group.EndedAt) { $group.EndedAt = $timestamp }

        $body = if ($dump.request -and $dump.request.PSObject.Properties['body']) { $dump.request.body } else { $null }
        if ($body -is [string]) {
            try { $body = $body | ConvertFrom-Json } catch { $body = $null }
        }
        if (-not $body) { continue }
        if ($body.PSObject.Properties['model']) { $group.Model = [string]$body.model }
        $dumpMessages = New-Object System.Collections.ArrayList
        $index = 0
        foreach ($message in @($body.messages)) {
            $index++
            $role = if ($message.PSObject.Properties['role']) { [string]$message.role } else { '' }
            if ($role -notin @('user', 'assistant')) { continue }
            $text = Get-AiStackImportText -Content $message.content
            $safe = Protect-AiStackImportText -Text $text
            if ([string]::IsNullOrWhiteSpace($safe)) { continue }
            $messageTimestamp = ([datetime]::Parse($timestamp)).AddMilliseconds($index).ToUniversalTime().ToString('o')
            [void]$dumpMessages.Add((New-AiStackImportMessage -Role $role -Text $safe -Timestamp $messageTimestamp))
        }

        $existing = @($group.Messages)
        $candidate = @($dumpMessages)
        if ($candidate.Count -eq 0) { continue }
        $overlap = 0
        if ($existing.Count -gt 0 -and $candidate.Count -gt 1) {
            $maximum = [Math]::Min($existing.Count, $candidate.Count)
            for ($length = $maximum; $length -ge 1; $length--) {
                $matches = $true
                for ($position = 0; $position -lt $length; $position++) {
                    $left = $existing[$existing.Count - $length + $position]
                    $right = $candidate[$position]
                    if ($left.Role -ne $right.Role -or $left.Text -ne $right.Text) {
                        $matches = $false
                        break
                    }
                }
                if ($matches) {
                    $overlap = $length
                    break
                }
            }
        }
        for ($position = $overlap; $position -lt $candidate.Count; $position++) {
            [void]$group.Messages.Add($candidate[$position])
        }
    }

    $sessions = New-Object System.Collections.ArrayList
    foreach ($entry in $groups.GetEnumerator() | Sort-Object Key) {
        $session = New-AiStackNormalizedSession `
            -Source 'Hermes' `
            -SourceId $entry.Key `
            -Project 'hermes' `
            -Cwd 'hermes://local' `
            -Messages @($entry.Value.Messages) `
            -Model $entry.Value.Model
        if ($session) { [void]$sessions.Add($session) }
    }
    return @($sessions)
}

function Get-WslPiSessionRoots {
    if ($env:AI_STACK_TEST_DISABLE_WSL -eq '1') {
        return @()
    }
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        return @()
    }
    $listResult = Invoke-AiStackNative -Command $wsl.Source -Arguments @('--list', '--quiet')
    if ($listResult.ExitCode -ne 0) {
        Write-Warning 'WSL distributions could not be listed; Windows pi history will still be processed.'
        return @()
    }

    $roots = New-Object System.Collections.ArrayList
    $distributions = @($listResult.Output | ForEach-Object {
        ([regex]::Replace([string]$_, "`0", '')).Trim()
    } | Where-Object {
        $_ -and $_ -notmatch '^docker-desktop' -and $_ -notmatch '[\\/:*?"<>|]'
    } | Select-Object -Unique)
    foreach ($distribution in $distributions) {
        $homeResult = Invoke-AiStackNative `
            -Command $wsl.Source `
            -Arguments @(
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
        $linuxHome = if ($homeLine.Count -eq 1) {
            $homeLine[0].Substring('__AI_STACK_HOME__'.Length)
        }
        else {
            ''
        }
        if ($linuxHome -notmatch '^/[^\r\n]*$') {
            Write-Warning "WSL distribution '$distribution' returned an invalid home directory; skipping it."
            continue
        }
        $relativeHome = $linuxHome.Replace('/', '\')
        $root = "\\wsl.localhost\$distribution$relativeHome\.pi\agent\sessions"
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            $fallback = "\\wsl$\$distribution$relativeHome\.pi\agent\sessions"
            if (Test-Path -LiteralPath $fallback -PathType Container) {
                $root = $fallback
            }
            else {
                continue
            }
        }
        [void]$roots.Add([pscustomobject]@{
            Root = $root
            Namespace = "wsl:$distribution"
        })
    }
    return @($roots)
}

function Get-PiImportSessionsFromRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Namespace
    )

    $root = $Root
    if (-not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $sessions = New-Object System.Collections.ArrayList
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -Recurse | Sort-Object FullName) {
        $sourceId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $cwd = 'pi://local'
        $model = $null
        $messages = New-Object System.Collections.ArrayList
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($record.PSObject.Properties['id'] -and $record.type -in @('session', 'session_start')) {
                $sourceId = [string]$record.id
            }
            if ($record.PSObject.Properties['sessionId'] -and $record.sessionId) {
                $sourceId = [string]$record.sessionId
            }
            if ($record.PSObject.Properties['cwd'] -and $record.cwd) { $cwd = [string]$record.cwd }
            if ($record.PSObject.Properties['model'] -and $record.model) { $model = [string]$record.model }
            $message = if ($record.PSObject.Properties['message']) { $record.message } else { $record }
            $role = if ($message -and $message.PSObject.Properties['role']) { [string]$message.role } else { '' }
            if ($role -notin @('user', 'assistant')) { continue }
            $text = Get-AiStackImportText -Content $message.content
            $timestampValue = if ($message.PSObject.Properties['timestamp']) { $message.timestamp } elseif ($record.PSObject.Properties['timestamp']) { $record.timestamp } else { $null }
            $timestamp = ConvertTo-AiStackIsoTimestamp -Value $timestampValue -Fallback $file.LastWriteTimeUtc.AddMilliseconds($lineNumber)
            $normalized = New-AiStackImportMessage -Role $role -Text $text -Timestamp $timestamp
            if ($normalized) { [void]$messages.Add($normalized) }
        }
        $project = Resolve-AiStackImportProject -Cwd $cwd -Repository '' -Fallback 'pi'
        $session = New-AiStackNormalizedSession `
            -Source 'Pi' `
            -SourceId "$Namespace|$sourceId" `
            -Project $project `
            -Cwd $cwd `
            -Messages @($messages) `
            -Model $model
        if ($session) { [void]$sessions.Add($session) }
    }
    return @($sessions)
}

function Get-PiImportSessions {
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add([pscustomobject]@{
        Root = Join-Path $script:ClientHome '.pi\agent\sessions'
        Namespace = 'windows'
    })
    foreach ($wslRoot in @(Get-WslPiSessionRoots)) {
        [void]$roots.Add($wslRoot)
    }

    $sessions = New-Object System.Collections.ArrayList
    foreach ($sourceRoot in $roots) {
        foreach ($session in @(Get-PiImportSessionsFromRoot `
            -Root $sourceRoot.Root `
            -Namespace $sourceRoot.Namespace)) {
            [void]$sessions.Add($session)
        }
    }
    return @($sessions)
}

function Get-CopilotImportSessions {
    $databasePath = Join-Path $script:ClientHome '.copilot\session-store.db'
    if (-not (Test-Path -LiteralPath $databasePath)) {
        return @()
    }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        throw 'Node.js 22 or newer is required to read the Copilot session database.'
    }

    $result = Invoke-AiStackNative `
        -Command $node.Source `
        -Arguments @('--no-warnings', $script:CopilotSessionReaderPath, $databasePath)
    if ($result.ExitCode -ne 0) {
        throw "Cannot read the Copilot session database: $($result.Output -join [Environment]::NewLine)"
    }

    $sessions = New-Object System.Collections.ArrayList
    foreach ($line in $result.Output) {
        try { $record = $line | ConvertFrom-Json } catch { continue }
        $messages = New-Object System.Collections.ArrayList
        $turnOffset = 0
        $sessionTimestamp = ConvertTo-AiStackIsoTimestamp `
            -Value $record.created_at `
            -Fallback ([datetime]'1970-01-01T00:00:00Z')
        foreach ($turn in @($record.turns)) {
            $turnIndex = if ($turn.PSObject.Properties['turn_index']) {
                [int]$turn.turn_index
            }
            else {
                0
            }
            $turnFallback = ([datetime]::Parse($sessionTimestamp)).AddSeconds($turnIndex)
            $baseTimestamp = ConvertTo-AiStackIsoTimestamp `
                -Value $turn.timestamp `
                -Fallback $turnFallback
            if (-not [string]::IsNullOrWhiteSpace([string]$turn.user_message)) {
                [void]$messages.Add((New-AiStackImportMessage `
                    -Role 'user' `
                    -Text ([string]$turn.user_message) `
                    -Timestamp ([datetime]::Parse($baseTimestamp).AddMilliseconds($turnOffset++).ToUniversalTime().ToString('o'))))
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$turn.assistant_response)) {
                [void]$messages.Add((New-AiStackImportMessage `
                    -Role 'assistant' `
                    -Text ([string]$turn.assistant_response) `
                    -Timestamp ([datetime]::Parse($baseTimestamp).AddMilliseconds($turnOffset++).ToUniversalTime().ToString('o'))))
            }
        }
        $cwd = if ($record.cwd) { [string]$record.cwd } else { 'copilot://local' }
        $project = Resolve-AiStackImportProject -Repository ([string]$record.repository) -Cwd $cwd -Fallback 'copilot'
        $session = New-AiStackNormalizedSession `
            -Source 'Copilot' `
            -SourceId ([string]$record.id) `
            -Project $project `
            -Cwd $cwd `
            -Messages @($messages)
        if ($session) { [void]$sessions.Add($session) }
    }
    return @($sessions)
}

function Get-VSCodeWorkspaceInfo {
    param(
        [AllowNull()][string]$WorkspaceJsonPath,
        [Parameter(Mandatory = $true)][string]$FallbackProject
    )

    $location = ''
    if ($WorkspaceJsonPath -and (Test-Path -LiteralPath $WorkspaceJsonPath)) {
        try {
            $workspace = [System.IO.File]::ReadAllText($WorkspaceJsonPath) | ConvertFrom-Json
            if ($workspace.PSObject.Properties['folder']) { $location = [string]$workspace.folder }
            elseif ($workspace.PSObject.Properties['workspace']) { $location = [string]$workspace.workspace }
        }
        catch {}
    }
    if ([string]::IsNullOrWhiteSpace($location)) {
        return [pscustomobject]@{ Project = $FallbackProject; Cwd = "vscode://$FallbackProject" }
    }
    try {
        $uri = [uri]$location
        $cwd = if ($uri.IsFile) { $uri.LocalPath } else { $uri.AbsoluteUri }
        $leaf = [uri]::UnescapeDataString($uri.AbsolutePath.TrimEnd('/').Split('/')[-1])
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $FallbackProject }
        return [pscustomobject]@{ Project = $leaf; Cwd = $cwd }
    }
    catch {
        return [pscustomobject]@{
            Project = Resolve-AiStackImportProject -Cwd $location -Repository '' -Fallback $FallbackProject
            Cwd = $location
        }
    }
}

function Get-VSCodeAssistantText {
    param($Response)

    $parts = New-Object System.Collections.ArrayList
    foreach ($part in @($Response)) {
        if (-not $part) { continue }
        $kind = if ($part.PSObject.Properties['kind']) { [string]$part.kind } else { '' }
        if ($kind -in @('thinking', 'toolInvocationSerialized', 'mcpServersStarting', 'elicitationSerialized', 'textEditGroup')) {
            continue
        }
        if ($part.PSObject.Properties['value'] -and $part.value -is [string]) {
            [void]$parts.Add([string]$part.value)
        }
        elseif ($kind -in @('markdownContent', 'markdownVulnerability') -and
            $part.PSObject.Properties['value'] -and
            $part.value -and
            $part.value.PSObject.Properties['value'] -and
            $part.value.value -is [string]) {
            [void]$parts.Add([string]$part.value.value)
        }
    }
    return ($parts -join ([Environment]::NewLine + [Environment]::NewLine))
}

function Get-AiStackObjectPathParent {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Path
    )

    if ($Path.Count -eq 0) {
        throw 'Mutation paths cannot be empty.'
    }
    $current = $Root
    for ($index = 0; $index -lt $Path.Count - 1; $index++) {
        $segment = $Path[$index]
        if ($current -is [System.Collections.IList] -and
            [string]$segment -match '^\d+$') {
            $current = $current[[int]$segment]
        }
        else {
            $property = $current.PSObject.Properties[[string]$segment]
            if (-not $property) {
                throw "Mutation path segment '$segment' does not exist."
            }
            $current = $property.Value
        }
        if ($null -eq $current) {
            throw "Mutation path segment '$segment' resolved to null."
        }
    }
    return [pscustomobject]@{
        Parent = $current
        Key = $Path[$Path.Count - 1]
    }
}

function Set-AiStackObjectPathValue {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][object[]]$Path,
        [AllowNull()]$Value
    )

    $target = Get-AiStackObjectPathParent -Root $Root -Path $Path
    if ($target.Parent -is [System.Collections.IList] -and
        [string]$target.Key -match '^\d+$') {
        $target.Parent[[int]$target.Key] = $Value
        return
    }
    $property = $target.Parent.PSObject.Properties[[string]$target.Key]
    if ($property) {
        $property.Value = $Value
    }
    else {
        $target.Parent |
            Add-Member -NotePropertyName ([string]$target.Key) -NotePropertyValue $Value
    }
}

function Remove-AiStackObjectPathValue {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][object[]]$Path
    )

    $target = Get-AiStackObjectPathParent -Root $Root -Path $Path
    if ($target.Parent -is [System.Collections.IList] -and
        [string]$target.Key -match '^\d+$') {
        $target.Parent[[int]$target.Key] = $null
        return
    }
    $target.Parent.PSObject.Properties.Remove([string]$target.Key)
}

function Add-AiStackObjectPathValues {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][object[]]$Path,
        [AllowNull()]$Values,
        [AllowNull()]$StartIndex
    )

    $target = Get-AiStackObjectPathParent -Root $Root -Path $Path
    $property = $target.Parent.PSObject.Properties[[string]$target.Key]
    $items = New-Object System.Collections.ArrayList
    if ($property -and $property.Value) {
        foreach ($item in @($property.Value)) { [void]$items.Add($item) }
    }
    if ($null -ne $StartIndex) {
        $keep = [Math]::Max(0, [Math]::Min([int]$StartIndex, $items.Count))
        while ($items.Count -gt $keep) { $items.RemoveAt($items.Count - 1) }
    }
    foreach ($item in @($Values)) {
        if ($null -ne $item) { [void]$items.Add($item) }
    }
    Set-AiStackObjectPathValue -Root $Root -Path $Path -Value @($items)
}

function Get-VSCodeImportSessions {
    $userRoots = @(
        (Join-Path $env:APPDATA 'Code\User'),
        (Join-Path $env:APPDATA 'Code - Insiders\User')
    )
    $sessionFiles = New-Object System.Collections.ArrayList
    foreach ($userRoot in $userRoots) {
        if (-not (Test-Path -LiteralPath $userRoot)) { continue }
        $workspaceRoots = @((Join-Path $userRoot 'workspaceStorage'))
        $profilesRoot = Join-Path $userRoot 'profiles'
        if (Test-Path -LiteralPath $profilesRoot) {
            $workspaceRoots += @(Get-ChildItem -LiteralPath $profilesRoot -Directory | ForEach-Object {
                Join-Path $_.FullName 'workspaceStorage'
            })
        }
        foreach ($workspaceRoot in $workspaceRoots | Where-Object { Test-Path -LiteralPath $_ }) {
            foreach ($file in Get-ChildItem -LiteralPath $workspaceRoot -Filter '*.jsonl' -File -Recurse |
                Where-Object { $_.Directory.Name -eq 'chatSessions' }) {
                [void]$sessionFiles.Add([pscustomobject]@{
                    File = $file
                    WorkspaceJson = Join-Path $file.Directory.Parent.FullName 'workspace.json'
                    FallbackProject = 'vscode'
                })
            }
        }
        $emptyRoot = Join-Path $userRoot 'globalStorage\emptyWindowChatSessions'
        if (Test-Path -LiteralPath $emptyRoot) {
            foreach ($file in Get-ChildItem -LiteralPath $emptyRoot -Filter '*.jsonl' -File -Recurse) {
                [void]$sessionFiles.Add([pscustomobject]@{
                    File = $file
                    WorkspaceJson = $null
                    FallbackProject = 'vscode-empty-window'
                })
            }
        }
    }

    $sessions = New-Object System.Collections.ArrayList
    foreach ($candidate in $sessionFiles | Sort-Object { $_.File.FullName }) {
        $snapshot = $null
        foreach ($line in Get-Content -LiteralPath $candidate.File.FullName -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($record.kind -eq 0 -and $record.PSObject.Properties['v']) {
                $snapshot = $record.v
            }
            elseif ($snapshot -and
                $record.PSObject.Properties['k'] -and
                $record.kind -in @(1, 2, 3)) {
                try {
                    $path = @($record.k)
                    switch ([int]$record.kind) {
                        1 {
                            Set-AiStackObjectPathValue `
                                -Root $snapshot `
                                -Path $path `
                                -Value $record.v
                        }
                        2 {
                            $startIndex = if ($record.PSObject.Properties['i']) {
                                $record.i
                            }
                            else {
                                $null
                            }
                            $values = if ($record.PSObject.Properties['v']) {
                                $record.v
                            }
                            else {
                                @()
                            }
                            Add-AiStackObjectPathValues `
                                -Root $snapshot `
                                -Path $path `
                                -Values $values `
                                -StartIndex $startIndex
                        }
                        3 {
                            Remove-AiStackObjectPathValue `
                                -Root $snapshot `
                                -Path $path
                        }
                    }
                }
                catch {
                    Write-Warning "Skipping malformed VS Code mutation in '$($candidate.File.Name)': $($_.Exception.Message)"
                }
            }
        }
        if (-not $snapshot) { continue }
        $messages = New-Object System.Collections.ArrayList
        $model = $null
        $requestOffset = 0
        foreach ($request in @($snapshot.requests)) {
            if ($request.PSObject.Properties['modelId'] -and $request.modelId) { $model = [string]$request.modelId }
            $timestamp = ConvertTo-AiStackIsoTimestamp -Value $request.timestamp -Fallback $candidate.File.LastWriteTimeUtc
            $userText = if ($request.message -and $request.message.PSObject.Properties['text']) { [string]$request.message.text } else { '' }
            $user = New-AiStackImportMessage `
                -Role 'user' `
                -Text $userText `
                -Timestamp ([datetime]::Parse($timestamp).AddMilliseconds($requestOffset++).ToUniversalTime().ToString('o'))
            if ($user) { [void]$messages.Add($user) }
            $assistantText = Get-VSCodeAssistantText -Response $request.response
            $assistant = New-AiStackImportMessage `
                -Role 'assistant' `
                -Text $assistantText `
                -Timestamp ([datetime]::Parse($timestamp).AddMilliseconds($requestOffset++).ToUniversalTime().ToString('o'))
            if ($assistant) { [void]$messages.Add($assistant) }
        }
        $workspace = Get-VSCodeWorkspaceInfo `
            -WorkspaceJsonPath $candidate.WorkspaceJson `
            -FallbackProject $candidate.FallbackProject
        $nativeId = if ($snapshot.PSObject.Properties['sessionId'] -and $snapshot.sessionId) {
            [string]$snapshot.sessionId
        }
        else {
            [System.IO.Path]::GetFileNameWithoutExtension($candidate.File.Name)
        }
        $sourceId = "$($candidate.File.Directory.Parent.Name)|$nativeId"
        $session = New-AiStackNormalizedSession `
            -Source 'VSCode' `
            -SourceId $sourceId `
            -Project $workspace.Project `
            -Cwd $workspace.Cwd `
            -Messages @($messages) `
            -Model $model
        if ($session) { [void]$sessions.Add($session) }
    }
    return @($sessions)
}

function Split-AiStackImportText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$MaximumLength = 12000
    )

    $chunks = New-Object System.Collections.ArrayList
    for ($offset = 0; $offset -lt $Text.Length; $offset += $MaximumLength) {
        $length = [Math]::Min($MaximumLength, $Text.Length - $offset)
        [void]$chunks.Add($Text.Substring($offset, $length))
    }
    return @($chunks)
}

function ConvertTo-AiStackAgentMemoryExport {
    param([Parameter(Mandatory = $true)]$Session)

    $observations = New-Object System.Collections.ArrayList
    $messageIndex = 0
    foreach ($message in $Session.Messages) {
        $messageIndex++
        $chunks = @(Split-AiStackImportText -Text $message.Text)
        $chunkIndex = 0
        foreach ($chunk in $chunks) {
            $chunkIndex++
            $observationId = New-AiStackImportId `
                -Prefix 'obs_import' `
                -Value "$($Session.Id)|$messageIndex|$chunkIndex|$($message.Role)|$chunk"
            $title = if ($message.Role -eq 'user') { 'User message' } else { 'Assistant response' }
            if ($chunks.Count -gt 1) { $title += " ($chunkIndex/$($chunks.Count))" }
            [void]$observations.Add([ordered]@{
                id = $observationId
                sessionId = $Session.Id
                timestamp = $message.Timestamp
                type = 'conversation'
                title = $title
                facts = @()
                narrative = $chunk
                concepts = @("source:$($Session.Source.ToLowerInvariant())", "project:$($Session.Project)")
                files = @()
                importance = if ($message.Role -eq 'user') { 7 } else { 6 }
                confidence = 1.0
            })
        }
    }
    $firstPrompt = @($Session.Messages | Where-Object Role -eq 'user' | Select-Object -First 1)
    $startedAt = ($Session.Messages | Sort-Object Timestamp | Select-Object -First 1).Timestamp
    $endedAt = ($Session.Messages | Sort-Object Timestamp -Descending | Select-Object -First 1).Timestamp
    $sessionRecord = [ordered]@{
        id = $Session.Id
        project = $Session.Project
        cwd = $Session.Cwd
        startedAt = $startedAt
        endedAt = $endedAt
        status = 'completed'
        observationCount = $observations.Count
        tags = @('historical-import', "source-$($Session.Source.ToLowerInvariant())")
        importContentHash = $Session.ContentHash
        firstPrompt = if ($firstPrompt.Count) { $firstPrompt[0].Text.Substring(0, [Math]::Min(200, $firstPrompt[0].Text.Length)) } else { $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($Session.Model)) {
        $sessionRecord.model = $Session.Model
    }
    $observationBuckets = [ordered]@{}
    $observationBuckets[$Session.Id] = @($observations)
    return [ordered]@{
        version = '0.9.28'
        exportedAt = [datetime]::UtcNow.ToString('o')
        sessions = @($sessionRecord)
        observations = $observationBuckets
        memories = @()
        summaries = @()
    }
}

function Read-AiStackImportManifest {
    $entries = @{}
    if (-not (Test-Path -LiteralPath $script:ImportManifestPath)) {
        return $entries
    }
    try {
        $manifest = [System.IO.File]::ReadAllText($script:ImportManifestPath) | ConvertFrom-Json
        foreach ($entry in @($manifest.entries)) {
            if ($entry.sessionId) { $entries[[string]$entry.sessionId] = $entry }
        }
    }
    catch {
        throw "Cannot read import manifest '$script:ImportManifestPath': $($_.Exception.Message)"
    }
    return $entries
}

function Write-AiStackImportManifest {
    param([Parameter(Mandatory = $true)][hashtable]$Entries)

    if (-not (Test-Path -LiteralPath $script:ImportStatePath)) {
        New-Item -ItemType Directory -Path $script:ImportStatePath -Force | Out-Null
    }
    $manifest = [ordered]@{
        version = 1
        updatedAt = [datetime]::UtcNow.ToString('o')
        entries = @($Entries.Values | Sort-Object sessionId)
    }
    Write-Utf8NoBom `
        -Path $script:ImportManifestPath `
        -Content (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
}

function Get-AiStackRemoteSessionIds {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    $headers = @{ Authorization = "Bearer $Secret" }
    $response = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$BaseUrl/agentmemory/sessions" `
        -Headers $headers `
        -Method Get `
        -TimeoutSec 30
    $sessions = if ($response.PSObject.Properties['sessions']) { @($response.sessions) } else { @($response) }
    $ids = @{}
    foreach ($session in $sessions) {
        if ($session.id) { $ids[[string]$session.id] = $true }
    }
    return $ids
}

function Send-AiStackSessionImport {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    $exportData = ConvertTo-AiStackAgentMemoryExport -Session $Session
    $payload = [ordered]@{ exportData = $exportData; strategy = 'merge' }
    $json = $payload | ConvertTo-Json -Depth 15 -Compress
    $response = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$BaseUrl/agentmemory/import" `
        -Headers @{ Authorization = "Bearer $Secret" } `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -Method Post `
        -TimeoutSec 180
    if ($response.PSObject.Properties['success'] -and -not $response.success) {
        throw "AgentMemory rejected session '$($Session.Id)': $($response.error)"
    }
    $observations = @($exportData.observations[$Session.Id])
    return [pscustomobject]@{
        Count = $observations.Count
        Ids = @($observations.id)
    }
}

function Get-AiStackRemoteObservationIds {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    $encodedSessionId = [uri]::EscapeDataString($SessionId)
    $response = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$BaseUrl/agentmemory/replay/load?sessionId=$encodedSessionId" `
        -Headers @{ Authorization = "Bearer $Secret" } `
        -Method Get `
        -TimeoutSec 30
    if (-not $response.success -or -not $response.timeline) {
        return @()
    }
    return @($response.timeline.events | ForEach-Object { $_.id } | Where-Object { $_ })
}

function Remove-AiStackRemoteObservations {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ObservationIds,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    if ($ObservationIds.Count -eq 0) {
        return
    }
    $payload = @{
        sessionId = $SessionId
        observationIds = @($ObservationIds)
    } | ConvertTo-Json -Depth 4 -Compress
    $response = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$BaseUrl/agentmemory/forget" `
        -Headers @{ Authorization = "Bearer $Secret" } `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) `
        -Method Post `
        -TimeoutSec 60
    if ($response.PSObject.Properties['success'] -and -not $response.success) {
        throw "AgentMemory could not remove stale observations for '$SessionId': $($response.error)"
    }
}

function Reset-AiStackDerivedData {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SessionIds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ObservationIds
    )

    if ($SessionIds.Count -eq 0 -and $ObservationIds.Count -eq 0) { return }
    $headers = @{ Authorization = ('Bear' + 'er ' + $Secret) }
    $sessionSet = @{}
    foreach ($id in $SessionIds) { $sessionSet[$id] = $true }
    $observationSet = @{}
    foreach ($id in $ObservationIds) { $observationSet[$id] = $true }

    $memoryResponse = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$BaseUrl/agentmemory/memories?agentId=*" `
        -Headers $headers `
        -Method Get `
        -TimeoutSec 60
    $memoryIds = @($memoryResponse.memories | Where-Object {
        $memory = $_
        $memorySessionIds = if ($memory.PSObject.Properties['sessionIds']) {
            @($memory.sessionIds)
        }
        else {
            @()
        }
        $memoryObservationIds = if ($memory.PSObject.Properties['sourceObservationIds']) {
            @($memory.sourceObservationIds)
        }
        else {
            @()
        }
        @($memorySessionIds | Where-Object { $sessionSet.ContainsKey([string]$_) }).Count -gt 0 -or
        @($memoryObservationIds | Where-Object { $observationSet.ContainsKey([string]$_) }).Count -gt 0
    } | ForEach-Object { [string]$_.id })
    if ($memoryIds.Count -gt 0) {
        $deletePayload = @{
            memoryIds = $memoryIds
            reason = 'Historical source observations changed'
        } | ConvertTo-Json -Depth 4 -Compress
        $deleteResult = Invoke-RestMethod `
            -UseBasicParsing `
            -Uri "$BaseUrl/agentmemory/governance/memories" `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($deletePayload)) `
            -Method Delete `
            -TimeoutSec 60
        if ($deleteResult.PSObject.Properties['success'] -and -not $deleteResult.success) {
            throw 'AgentMemory could not remove memories derived from changed observations.'
        }
    }

    $graphResult = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$BaseUrl/agentmemory/graph/reset" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body '{}' `
        -Method Post `
        -TimeoutSec 180
    if ($graphResult.PSObject.Properties['success'] -and -not $graphResult.success) {
        throw 'AgentMemory could not reset the graph after source observations changed.'
    }
    $graphManifest = Join-Path $script:AgentMemoryDataPath 'graph-backfill-manifest.json'
    if (Test-Path -LiteralPath $graphManifest) {
        Remove-Item -LiteralPath $graphManifest -Force
    }
    if (Test-Path -LiteralPath $script:DerivedInvalidationPath) {
        Remove-Item -LiteralPath $script:DerivedInvalidationPath -Force
    }
}

function Import-AiStackSessions {
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'Hermes', 'Pi', 'Copilot', 'VSCode')][string]$Source = 'All',
        [switch]$DryRun,
        [switch]$Force
    )

    $readers = [ordered]@{
        Hermes = { @(Get-HermesImportSessions) }
        Pi = { @(Get-PiImportSessions) }
        Copilot = { @(Get-CopilotImportSessions) }
        VSCode = { @(Get-VSCodeImportSessions) }
    }
    $selected = if ($Source -eq 'All') { @($readers.Keys) } else { @($Source) }
    $sessions = New-Object System.Collections.ArrayList
    $sourceStats = New-Object System.Collections.ArrayList
    foreach ($name in $selected) {
        $found = @(& $readers[$name])
        foreach ($session in $found) { [void]$sessions.Add($session) }
        [void]$sourceStats.Add([pscustomobject]@{
            Source = $name
            Sessions = $found.Count
            Messages = (@($found | ForEach-Object { $_.Messages }).Count)
        })
    }

    $sourceStats | Format-Table -AutoSize | Out-Host
    if ($DryRun) {
        Write-Host 'Dry run complete. No transcripts were sent to AgentMemory and no import state was changed.'
        return [pscustomobject]@{
            DryRun = $true
            Sessions = $sessions.Count
            Messages = (@($sessions | ForEach-Object { $_.Messages }).Count)
            Imported = 0
            Skipped = 0
            Observations = 0
        }
    }
    if ($sessions.Count -eq 0) {
        Write-Host 'No importable sessions were found.'
        return [pscustomobject]@{
            DryRun = $false
            Sessions = 0
            Messages = 0
            Imported = 0
            Skipped = 0
            Observations = 0
        }
    }

    Initialize-AiStackConfiguration
    $values = Get-DotEnvValues -Path $script:EnvPath
    $port = if ($values.ContainsKey('AGENTMEMORY_REST_PORT')) { $values['AGENTMEMORY_REST_PORT'] } else { '3111' }
    $baseUrl = "http://127.0.0.1:$port"
    $secret = [System.IO.File]::ReadAllText($script:AgentMemorySecretPath).Trim()
    $remoteIds = Get-AiStackRemoteSessionIds -BaseUrl $baseUrl -Secret $secret
    $manifest = Read-AiStackImportManifest
    $imported = 0
    $skipped = 0
    $observationCount = 0
    $changedSessionIds = New-Object System.Collections.ArrayList
    $staleObservationIds = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $script:DerivedInvalidationPath) {
        try {
            $pendingInvalidation = [System.IO.File]::ReadAllText(
                $script:DerivedInvalidationPath
            ) | ConvertFrom-Json
            foreach ($id in @($pendingInvalidation.sessionIds)) {
                [void]$changedSessionIds.Add([string]$id)
            }
            foreach ($id in @($pendingInvalidation.observationIds)) {
                [void]$staleObservationIds.Add([string]$id)
            }
        }
        catch {
            throw "Cannot resume derived-data invalidation: $($_.Exception.Message)"
        }
    }

    foreach ($session in $sessions | Sort-Object Source, Id) {
        $manifestEntry = if ($manifest.ContainsKey($session.Id)) { $manifest[$session.Id] } else { $null }
        $unchanged = $manifestEntry -and $manifestEntry.contentHash -eq $session.ContentHash
        if (-not $Force -and $unchanged -and $remoteIds.ContainsKey($session.Id)) {
            $skipped++
            continue
        }
        $previousIds = if ($remoteIds.ContainsKey($session.Id)) {
            @(Get-AiStackRemoteObservationIds -SessionId $session.Id -BaseUrl $baseUrl -Secret $secret)
        }
        else {
            @()
        }
        $importResult = Send-AiStackSessionImport -Session $session -BaseUrl $baseUrl -Secret $secret
        $staleIds = @($previousIds | Where-Object { $_ -notin $importResult.Ids })
        $sessionContentChanged = $manifestEntry -and $manifestEntry.contentHash -ne $session.ContentHash
        if ($staleIds.Count -gt 0 -or $sessionContentChanged) {
            [void]$changedSessionIds.Add([string]$session.Id)
            foreach ($id in $staleIds) { [void]$staleObservationIds.Add([string]$id) }
            $invalidation = [ordered]@{
                version = 1
                createdAt = [datetime]::UtcNow.ToString('o')
                sessionIds = @($changedSessionIds | Select-Object -Unique)
                observationIds = @($staleObservationIds | Select-Object -Unique)
            }
            Write-Utf8NoBom `
                -Path $script:DerivedInvalidationPath `
                -Content (($invalidation | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
        }
        Remove-AiStackRemoteObservations `
            -SessionId $session.Id `
            -ObservationIds $staleIds `
            -BaseUrl $baseUrl `
            -Secret $secret
        $observationCount += $importResult.Count
        $imported++
        $remoteIds[$session.Id] = $true
        $manifest[$session.Id] = [pscustomobject]@{
            sessionId = $session.Id
            source = $session.Source
            contentHash = $session.ContentHash
            observations = $importResult.Count
            observationIds = @($importResult.Ids)
            importedAt = [datetime]::UtcNow.ToString('o')
        }
        Write-AiStackImportManifest -Entries $manifest
    }

    if ($staleObservationIds.Count -gt 0) {
        $invalidation = [ordered]@{
            version = 1
            createdAt = [datetime]::UtcNow.ToString('o')
            sessionIds = @($changedSessionIds | Select-Object -Unique)
            observationIds = @($staleObservationIds | Select-Object -Unique)
        }
        Write-Utf8NoBom `
            -Path $script:DerivedInvalidationPath `
            -Content (($invalidation | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
    }
    Reset-AiStackDerivedData `
        -BaseUrl $baseUrl `
        -Secret $secret `
        -SessionIds @($changedSessionIds | Select-Object -Unique) `
        -ObservationIds @($staleObservationIds | Select-Object -Unique)
    Write-Host "Imported $imported session(s) with $observationCount observation(s); skipped $skipped unchanged session(s)."
    return [pscustomobject]@{
        DryRun = $false
        Sessions = $sessions.Count
        Messages = (@($sessions | ForEach-Object { $_.Messages }).Count)
        Imported = $imported
        Skipped = $skipped
        Observations = $observationCount
    }
}

function ConvertFrom-AiStackLastJsonLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $items = @($Lines)
    for ($index = $items.Count - 1; $index -ge 0; $index--) {
        try {
            return ([string]$items[$index] | ConvertFrom-Json)
        }
        catch {
            continue
        }
    }
    throw "$Operation did not return a JSON result."
}

function Invoke-AiStackSessionEnrichment {
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'Hermes', 'Pi', 'Copilot', 'VSCode')]
        [string]$Source = 'All',
        [switch]$DryRun,
        [switch]$Force
    )

    Initialize-AiStackConfiguration
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        throw 'Node.js 22 or newer is required to enrich historical sessions.'
    }

    $values = Get-DotEnvValues -Path $script:EnvPath
    $port = if ($values.ContainsKey('AGENTMEMORY_REST_PORT')) {
        $values['AGENTMEMORY_REST_PORT']
    }
    else {
        '3111'
    }
    $baseUrl = "http://127.0.0.1:$port"
    $secret = [System.IO.File]::ReadAllText($script:AgentMemorySecretPath).Trim()
    $headers = @{ Authorization = ('Bear' + 'er ' + $secret) }
    $summaryArguments = @(
        '--no-warnings',
        $script:EnrichmentRunnerPath,
        $baseUrl,
        $script:AgentMemorySecretPath,
        $Source.ToLowerInvariant(),
        '2',
        $script:EnrichmentManifestPath
    )
    if ($DryRun) { $summaryArguments += '--dry-run' }
    if ($Force) { $summaryArguments += '--force' }

    $summaryRun = Invoke-AiStackNative `
        -Command $node.Source `
        -Arguments $summaryArguments
    $summaryRun.Output | ForEach-Object { Write-Host $_ }
    if ($summaryRun.ExitCode -ne 0) {
        throw 'One or more historical session summaries failed. Rerun enrich-sessions to resume.'
    }
    $summaryResult = ConvertFrom-AiStackLastJsonLine `
        -Lines @($summaryRun.Output) `
        -Operation 'Session summarization'

    if ($Force -and -not $DryRun) {
        $graphReset = Invoke-RestMethod `
            -UseBasicParsing `
            -Uri "$baseUrl/agentmemory/graph/reset" `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body '{}' `
            -Method Post `
            -TimeoutSec 900
        if (-not $graphReset.success) {
            throw 'AgentMemory could not reset the graph before forced enrichment.'
        }
        $graphManifestPath = Join-Path $script:AgentMemoryDataPath 'graph-backfill-manifest.json'
        if (Test-Path -LiteralPath $graphManifestPath) {
            Remove-Item -LiteralPath $graphManifestPath -Force
        }
        if (Test-Path -LiteralPath $script:ConsolidationManifestPath) {
            Remove-Item -LiteralPath $script:ConsolidationManifestPath -Force
        }
    }

    $graphArguments = @(
        'exec', '-T', 'agentmemory', 'node',
        '/opt/agentmemory/graph-backfill.mjs',
        $Source.ToLowerInvariant()
    )
    if ($DryRun) { $graphArguments += '--dry-run' }
    $graphOutput = @(
        Invoke-DockerCompose -Arguments $graphArguments -Capture
    )
    $graphOutput | ForEach-Object { Write-Host $_ }
    $graphResult = ConvertFrom-AiStackLastJsonLine `
        -Lines $graphOutput `
        -Operation 'Knowledge graph extraction'

    if ($DryRun) {
        return [pscustomobject]@{
            DryRun = $true
            Sessions = $summaryResult.sessions
            PendingSummaries = $summaryResult.pending
            PendingGraphBatches = $graphResult.pendingBatches
        }
    }

    $summaryState = if (Test-Path -LiteralPath $script:EnrichmentManifestPath) {
        $value = [System.IO.File]::ReadAllText($script:EnrichmentManifestPath) | ConvertFrom-Json
        $value.sessions | ConvertTo-Json -Depth 8 -Compress
    }
    else {
        '{}'
    }
    $graphManifestPath = Join-Path $script:AgentMemoryDataPath 'graph-backfill-manifest.json'
    $graphState = if (Test-Path -LiteralPath $graphManifestPath) {
        $value = [System.IO.File]::ReadAllText($graphManifestPath) | ConvertFrom-Json
        @($value.completed | Sort-Object) -join ','
    }
    else {
        ''
    }
    $consolidationStateHash = Get-AiStackImportHash -Value "$summaryState`n$graphState"
    $consolidationCurrent = $false
    if (Test-Path -LiteralPath $script:ConsolidationManifestPath) {
        try {
            $consolidationManifest = [System.IO.File]::ReadAllText($script:ConsolidationManifestPath) | ConvertFrom-Json
            $consolidationCurrent = $consolidationManifest.stateHash -eq $consolidationStateHash
        }
        catch {
            $consolidationCurrent = $false
        }
    }

    $newWork = [int]$summaryResult.completed + [int]$graphResult.succeeded
    if ($newWork -eq 0 -and $consolidationCurrent -and -not $Force) {
        Write-Host 'Historical enrichment is already current; consolidation was not rerun.'
        return [pscustomobject]@{
            DryRun = $false
            Sessions = $summaryResult.sessions
            Summaries = 0
            GraphBatches = 0
            Consolidated = $false
        }
    }

    $consolidateBody = @{
        minObservations = 10
        stateHash = $consolidationStateHash
    } | ConvertTo-Json -Compress
    $memoryResult = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$baseUrl/agentmemory/consolidate" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $consolidateBody `
        -Method Post `
        -TimeoutSec 180
    if ($memoryResult.PSObject.Properties['failures'] -and @($memoryResult.failures).Count -gt 0) {
        throw "AgentMemory base consolidation had $(@($memoryResult.failures).Count) failed concept(s)."
    }
    $pipelineBody = @{
        tier = 'all'
        force = $true
        resetDerived = (-not $consolidationCurrent -or $Force)
        stateHash = $consolidationStateHash
    } | ConvertTo-Json -Compress
    $pipelineResult = Invoke-RestMethod `
        -UseBasicParsing `
        -Uri "$baseUrl/agentmemory/consolidate-pipeline" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $pipelineBody `
        -Method Post `
        -TimeoutSec 180
    $pipelineErrors = @()
    if ($pipelineResult.PSObject.Properties['results']) {
        $pipelineErrors = @($pipelineResult.results.PSObject.Properties | Where-Object {
            $_.Value -and (
                $_.Value.PSObject.Properties['error'] -or
                ($_.Value.PSObject.Properties['failures'] -and @($_.Value.failures).Count -gt 0)
            )
        })
    }
    if (-not $pipelineResult.success -or $pipelineErrors.Count -gt 0) {
        throw "AgentMemory consolidation failed: $($pipelineResult.reason)"
    }
    $consolidationManifest = [ordered]@{
        version = 1
        stateHash = $consolidationStateHash
        consolidatedAt = [datetime]::UtcNow.ToString('o')
    }
    Write-Utf8NoBom `
        -Path $script:ConsolidationManifestPath `
        -Content (($consolidationManifest | ConvertTo-Json -Depth 3) + [Environment]::NewLine)

    Write-Host "Enriched $($summaryResult.sessions) historical session(s): $($summaryResult.completed) summaries and $($graphResult.succeeded) graph batch(es)."
    return [pscustomobject]@{
        DryRun = $false
        Sessions = $summaryResult.sessions
        Summaries = $summaryResult.completed
        GraphBatches = $graphResult.succeeded
        Memories = $memoryResult.consolidated
        Consolidated = $true
    }
}
