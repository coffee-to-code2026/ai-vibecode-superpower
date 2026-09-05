[CmdletBinding()]
param([string]$Client)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedHash([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $out = [Collections.Generic.List[byte]]::new()
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 13 -and $i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { $out.Add(10); $i++ } else { $out.Add($bytes[$i]) }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($out.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Assert-NoReparse([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse point: $Path" }
    if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $Path -Force | ForEach-Object { Assert-NoReparse $_.FullName } }
}

function Assert-NoReparseChain([string]$Path) {
    $currentPath = [IO.Path]::GetFullPath($Path)
    while ($currentPath -and -not (Test-Path -LiteralPath $currentPath)) {
        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrEmpty($parentPath) -or $parentPath -eq $currentPath) { break }
        $currentPath = $parentPath
    }
    while ($currentPath -and (Test-Path -LiteralPath $currentPath)) {
        $current = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse point: $($current.FullName)" }
        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrEmpty($parentPath) -or $parentPath -eq $currentPath) { break }
        $currentPath = $parentPath
    }
}

function Assert-InstallContainer([string]$Path) {
    Assert-NoReparseChain $Path
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $item.PSIsContainer) { throw "Expected a non-reparse directory: $Path" }
}

function Assert-InstallTarget([string]$Path, [ValidateSet('File', 'Directory')][string]$Kind) {
    Assert-NoReparseChain $Path
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to replace reparse point: $Path" }
    if ($Kind -eq 'File' -and $item.PSIsContainer) { throw "Expected a regular file target: $Path" }
    if ($Kind -eq 'Directory' -and -not $item.PSIsContainer) { throw "Expected a directory target: $Path" }
    if ($Kind -eq 'Directory') { Assert-NoReparse $Path }
}

function Assert-TomlRoles([string]$Directory, [string]$Manifest, [int]$ExpectedCount) {
    $hashes = @{}
    foreach ($line in Get-Content -LiteralPath $Manifest) {
        if ($line -notmatch '^([0-9a-f]{64}) {2}([^\s]+)$') { throw "Invalid role manifest: $Manifest" }
        $hashes[$Matches[2]] = $Matches[1]
    }
    if ($hashes.Count -ne $ExpectedCount) { throw "Expected $ExpectedCount managed role hashes" }
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.toml' -File)
    if ($files.Count -ne $ExpectedCount) { throw "Expected $ExpectedCount managed role files" }
    foreach ($file in $files) {
        if (-not $hashes.ContainsKey($file.Name) -or (Get-NormalizedHash $file.FullName) -ne $hashes[$file.Name]) { throw "Role hash mismatch: $($file.Name)" }
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($key in 'name', 'model', 'model_reasoning_effort', 'sandbox_mode', 'description', 'developer_instructions') {
            if ($text -notmatch "(?m)^$key\s*=") { throw "Role field missing: $($file.Name)/$key" }
        }
    }
}

function Assert-AgentProfiles([string]$Directory, [string]$Manifest, [int]$ExpectedCount, [string]$Variant, [int]$Strict = 1) {
    $hashes = @{}
    foreach ($line in Get-Content -LiteralPath $Manifest) {
        if ($line -notmatch '^([0-9a-f]{64}) {2}([^\s]+)$') { throw "Invalid agent manifest: $Manifest" }
        $hashes[$Matches[2]] = $Matches[1]
    }
    if ($hashes.Count -ne $ExpectedCount) { throw "Expected $ExpectedCount managed agent hashes" }
    if ($Strict -eq 1) {
        $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.md' -File)
        if ($files.Count -ne $ExpectedCount) { throw "Expected $ExpectedCount managed agent files" }
    } else {
        foreach ($name in $hashes.Keys) {
            if (-not (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf)) { throw "Missing managed agent: $name" }
        }
        $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.md' -File)
    }
    foreach ($file in $files) {
        if (-not $hashes.ContainsKey($file.Name)) {
            if ($Strict -eq 1) { throw "Unexpected managed agent: $($file.Name)" }
            continue
        }
        if ((Get-NormalizedHash $file.FullName) -ne $hashes[$file.Name]) { throw "Agent hash mismatch: $($file.Name)" }
        $text = Get-Content -LiteralPath $file.FullName -Raw
        $lines = $text -split "`r?`n"
        if ($lines.Count -lt 2 -or $lines[0] -ne '---') { throw "Agent frontmatter missing: $($file.Name)" }
        $end = -1
        for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq '---') { $end = $i; break } }
        if ($end -lt 1) { throw "Agent frontmatter unterminated: $($file.Name)" }
        $frontmatter = $lines[1..($end - 1)] -join "`n"
        $requiredKeys = if ($Variant -eq 'mdopencode') { @('name', 'description', 'mode', 'model') } else { @('name', 'description', 'model', 'thoughtLevel') }
        $name = $null
        foreach ($key in $requiredKeys) {
            if ($frontmatter -notmatch "(?m)^$key\s*:") { throw "Agent field missing: $($file.Name)/$key" }
            if ($key -eq 'name' -and $frontmatter -match '(?m)^name\s*:\s*"?([^\r\n"]+?)"?\s*$') { $name = $Matches[1].Trim() }
        }
        if ($Variant -eq 'mdopencode') {
            if ($frontmatter -notmatch '(?m)^options\s*:$') { throw "Agent options block missing: $($file.Name)" }
            if ($frontmatter -notmatch '(?m)^\s+reasoningEffort\s*:') { throw "Agent options.reasoningEffort missing: $($file.Name)" }
        }
        if ($name -ne $file.BaseName) { throw "Agent name mismatch: $($file.Name)/$name" }
    }
}

function Assert-ManagedRoles([string]$Kind, [string]$Directory, [string]$Manifest, [int]$ExpectedCount, [int]$Strict = 1) {
    switch ($Kind) {
        'toml' { Assert-TomlRoles $Directory $Manifest $ExpectedCount }
        'md' { Assert-AgentProfiles $Directory $Manifest $ExpectedCount 'md' $Strict }
        'mdopencode' { Assert-AgentProfiles $Directory $Manifest $ExpectedCount 'mdopencode' $Strict }
        'none' { }
        default { throw "Unknown role kind: $Kind" }
    }
}

function Assert-SafeTomlMergeInput([string]$Path) {
    function ConvertFrom-SafeQuotedTomlKey([string]$Key) {
        $KeyLength = $Key.Length
        if ($KeyLength -lt 2) { return $null }
        $quote = $Key[0]
        if ($quote -ne '"' -and $quote -ne "'") { return $null }
        if ($Key[$KeyLength - 1] -ne $quote) { return $null }
        $decoded = [Text.StringBuilder]::new()
        for ($i = 1; $i -lt $KeyLength - 1; $i++) {
            $character = $Key[$i]
            if ([int][char]$character -lt 32 -or [int][char]$character -eq 127) { return $null }
            if ($quote -eq "'") {
                if ($character -eq "'") { return $null }
                [void]$decoded.Append($character)
                continue
            }
            if ($character -eq '"') { return $null }
            if ($character -ne '\') { [void]$decoded.Append($character); continue }
            $i++
            if ($i -ge $KeyLength - 1) { return $null }
            $character = $Key[$i]
            if ($character -eq 'u' -or $character -eq 'U') {
                $count = if ($character -eq 'u') { 4 } else { 8 }
                if ($i + $count -ge $KeyLength - 1) { return $null }
                $hex = $Key.Substring($i + 1, $count)
                for ($digit = 1; $digit -le $count; $digit++) {
                    if ($Key[$i + $digit] -notmatch '^[0-9A-Fa-f]$') { return $null }
                }
                $codePoint = [Convert]::ToUInt32($hex, 16)
                if ($codePoint -gt 0x10FFFF -or ($codePoint -ge 0xD800 -and $codePoint -le 0xDFFF)) { return $null }
                [void]$decoded.Append([char]::ConvertFromUtf32($codePoint))
                $i += $count
            } elseif ($character -eq '"' -or $character -eq '\') {
                [void]$decoded.Append($character)
            } elseif ($character -in @('b','t','n','f','r')) {
                $escaped = switch ($character) { 'b' { [char]8 } 't' { "`t" } 'n' { "`n" } 'f' { [char]12 } 'r' { "`r" } }
                [void]$decoded.Append($escaped)
            } else {
                return $null
            }
        }
        return [pscustomobject]@{ Value = $decoded.ToString() }
    }
    function Find-TomlAssignmentSeparator([string]$Line) {
        $basic = $false; $literal = $false
        for ($i = 0; $i -lt $Line.Length; $i++) {
            $character = $Line[$i]
            if ($basic) {
                if ($character -eq '\') { $i++ } elseif ($character -eq '"') { $basic = $false }
                continue
            }
            if ($literal) {
                if ($character -eq "'") { $literal = $false }
                continue
            }
            if ($character -eq '"') { $basic = $true }
            elseif ($character -eq "'") { $literal = $true }
            elseif ($character -eq '=') { return $i }
        }
        return -1
    }
    function Test-ClosedTomlValue([string]$Value) {
        $basic = $false; $literal = $false; $arrayDepth = 0; $inlineDepth = 0
        for ($i = 0; $i -lt $Value.Length; $i++) {
            $character = $Value[$i]
            if ($basic) {
                if ($character -eq '\') { $i++ } elseif ($character -eq '"') { $basic = $false }
                continue
            }
            if ($literal) {
                if ($character -eq "'") { $literal = $false }
                continue
            }
            if ($character -eq '"') { $basic = $true }
            elseif ($character -eq "'") { $literal = $true }
            elseif ($character -eq '[') { $arrayDepth++ }
            elseif ($character -eq ']') { $arrayDepth-- }
            elseif ($character -eq '{') { $inlineDepth++ }
            elseif ($character -eq '}') { $inlineDepth-- }
            if ($arrayDepth -lt 0 -or $inlineDepth -lt 0) { return $false }
        }
        return -not $basic -and -not $literal -and $arrayDepth -eq 0 -and $inlineDepth -eq 0
    }
    $section = 'root'; $seen = @{}
    foreach ($line in [IO.File]::ReadLines($Path)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.Contains('"""') -or $trimmed.Contains("'''")) { throw "Unsupported multiline TOML in $Path" }
        if ($trimmed.StartsWith('[[')) {
            if ($trimmed -notmatch '^\[\[[^\]]+\]\]\s*(#.*)?$') { throw ('Unsupported TOML array table header in ' + $Path + ': ' + $trimmed) }
            $section = '__array__'; continue
        }
        if ($trimmed.StartsWith('[')) {
            if ($trimmed -notmatch '^\[[^\]]+\]\s*(#.*)?$') { throw ('Unsupported TOML table header in ' + $Path + ': ' + $trimmed) }
            $header = $trimmed.Substring(1, $trimmed.IndexOf(']') - 1)
            $section = $header.Trim(); continue
        }
        $separator = Find-TomlAssignmentSeparator $trimmed
        if ($separator -lt 0) { throw "Unsupported TOML line in ${Path}: $line" }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1)
        if (-not (Test-ClosedTomlValue $value)) { throw ('Unsupported TOML value syntax in ' + $Path + ': ' + $value) }
        $keyIdentity = $key
        if ($key -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
            $quotedKey = ConvertFrom-SafeQuotedTomlKey $key
            if ($null -eq $quotedKey) { throw ('Unsupported TOML key syntax in ' + $Path + ': ' + $key) }
            $keyIdentity = $quotedKey.Value
        }
        $managed = ($section -eq 'root' -and $keyIdentity -in @('model','model_reasoning_effort','sandbox_mode','approval_policy','approvals_reviewer')) -or
            ($section -eq 'agents' -and $keyIdentity -in @('max_threads','max_depth')) -or
            ($section -eq 'features' -and $keyIdentity -eq 'goals')
        if ($managed) {
            if ($key -ne $keyIdentity) { throw "Quoted TOML key aliases a managed key in ${Path}: $section/$key" }
            $identity = "$section/$keyIdentity"
            if ($seen.ContainsKey($identity)) { throw "Repeated managed TOML key in ${Path}: $identity" }
            $seen[$identity] = $true
        }
    }
}

function Get-ManagedConfigValues([string]$Path) {
    $values = [ordered]@{
        root = [ordered]@{ model = $null; model_reasoning_effort = $null; sandbox_mode = $null; approval_policy = $null; approvals_reviewer = $null }
        agents = [ordered]@{ max_threads = $null; max_depth = $null }
        features = [ordered]@{ goals = $null }
    }
    $section = 'root'
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*\[\[([^\]]+)\]\]') { $section = '__array__'; continue }
        if ($line -match '^\s*\[([^\]]+)\]') { $section = $Matches[1].Trim(); continue }
        if ($values.Contains($section) -and $line -match '^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(.+)$') {
            $key = $Matches[1]
            if ($values[$section].Contains($key)) { $values[$section][$key] = $Matches[2].Trim() }
        }
    }
    foreach ($sectionName in $values.Keys) { foreach ($key in $values[$sectionName].Keys) { if ([string]::IsNullOrWhiteSpace($values[$sectionName][$key])) { throw "Missing managed config setting: $sectionName/$key" } } }
    return $values
}

function Get-ProviderSettings([string]$Path) {
    $values = [ordered]@{ request_max_retries = $null; stream_max_retries = $null; stream_idle_timeout_ms = $null; websocket_connect_timeout_ms = $null }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(.+)$' -and $values.Contains($Matches[1])) { $values[$Matches[1]] = $Matches[2].Trim() }
    }
    foreach ($key in $values.Keys) { if ([string]::IsNullOrWhiteSpace($values[$key])) { throw "Missing provider setting: $key" } }
    return $values
}

function Merge-Config([string]$Template, [string]$Existing, [string]$Provider, [string]$Output) {
    Assert-SafeTomlMergeInput $Template
    Assert-SafeTomlMergeInput $Provider
    if (Test-Path -LiteralPath $Existing -PathType Leaf) { Assert-SafeTomlMergeInput $Existing }
    $managed = Get-ManagedConfigValues $Template
    $providerValues = Get-ProviderSettings $Provider
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Existing -PathType Leaf) { Get-Content -LiteralPath $Existing | ForEach-Object { $lines.Add($_) } } else { Get-Content -LiteralPath $Template | ForEach-Object { $lines.Add($_) } }
    $outputLines = [Collections.Generic.List[string]]::new()
    $seen = @{ root = @{}; agents = @{}; features = @{} }
    $seenSections = @{}
    $section = 'root'; $providerSection = $false; $providerSeen = @{}; $providerFound = $false
    $flush = {
        param([string]$name)
        if ($name -eq 'root' -or $name -eq 'agents' -or $name -eq 'features') {
            foreach ($key in $managed[$name].Keys) { if (-not $seen[$name].ContainsKey($key)) { $outputLines.Add("$key = $($managed[$name][$key])"); $seen[$name][$key] = $true } }
        }
        if ($providerSection) {
            foreach ($key in $providerValues.Keys) { if (-not $providerSeen.ContainsKey($key)) { $outputLines.Add("$key = $($providerValues[$key])"); $providerSeen[$key] = $true } }
        }
    }
    foreach ($line in $lines) {
        if ($line -match '^\s*\[\[([^\]]+)\]\]') { & $flush $section; $section = '__array__'; $providerSection = $false; $providerSeen = @{}; $outputLines.Add($line); continue }
        if ($line -match '^\s*\[([^\]]+)\]') {
            & $flush $section
            $header = $Matches[1].Trim()
            $section = if ($header -in @('agents','features')) { $header } else { '__other__' }
            if ($section -in @('agents','features')) { $seenSections[$section] = $true }
            $providerSection = $header -match '^model_providers\.(?:[A-Za-z0-9_-]+|"[^"]+"|''[^'']+'')$'
            if ($providerSection) { $providerFound = $true }
            $providerSeen = @{}
            $outputLines.Add($line); continue
        }
        if ($providerSection -and $line -match '^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=') {
            $key = $Matches[1]
            if ($providerValues.Contains($key)) { $outputLines.Add("$key = $($providerValues[$key])"); $providerSeen[$key] = $true; continue }
        }
        if (($section -eq 'root' -or $section -eq 'agents' -or $section -eq 'features') -and $line -match '^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=') {
            $key = $Matches[1]
            if ($managed[$section].Contains($key)) { $outputLines.Add("$key = $($managed[$section][$key])"); $seen[$section][$key] = $true; continue }
        }
        $outputLines.Add($line)
    }
    & $flush $section
    foreach ($table in 'agents','features') {
        if (-not $seenSections.ContainsKey($table)) { if ($outputLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($outputLines[$outputLines.Count - 1])) { $outputLines.Add('') }; $outputLines.Add("[$table]"); foreach ($key in $managed[$table].Keys) { $outputLines.Add("$key = $($managed[$table][$key])") } }
    }
    if (-not $providerFound) { Write-Warning "No [model_providers.<provider-id>] table found in $Existing; skipped provider settings." }
    Set-Content -LiteralPath $Output -Value $outputLines -Encoding utf8
}

function Expand-Placeholders([string]$Directory, [string]$Token, [string]$Root) {
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Recurse -File) {
        if ($file.Extension.ToLowerInvariant() -notin @('.md','.toml','.txt')) { continue }
        $text = [IO.File]::ReadAllText($file.FullName)
        $expanded = $text.Replace(('<' + $Token + '>'), $Root).Replace(('$' + $Token), $Root)
        if ($expanded -ne $text) { [IO.File]::WriteAllText($file.FullName, $expanded, [Text.UTF8Encoding]::new($false)) }
    }
}

$root = Split-Path -Parent $PSCommandPath
$sourceSystemDocs = Join-Path $root 'shared\docs\system'
$clientProfiles = [ordered]@{
    codex = @{
        Label = 'Codex'; HomeEnv = 'CODEX_HOME'; DefaultHome = '.codex'; RoleKind = 'toml'; RoleCount = 12; Placeholder = 'CODEX_HOME'
        ConfigMode = 'toml'; RolesInstall = 'directory'; RolesRel = 'agents\ai-vibecode-superpower'
        Roles = Join-Path $root 'codex-global-config\agents\ai-vibecode-superpower'
        Manifest = Join-Path $root 'codex-global-config\agents\ai-vibecode-superpower.sha256'
        Instructions = Join-Path $root 'codex-global-config\AGENTS.md'
        Docs = Join-Path $root 'codex-global-config\docs'
        ConfigTemplate = Join-Path $root 'codex-global-config\config.toml'
        ProviderSettings = Join-Path $root 'codex-global-config\model-provider-settings.toml'
        Skills = @(
            @{ Name = 'agent-toolchain'; Source = (Join-Path $root 'shared\skills\agent-toolchain') },
            @{ Name = 'gpt-image-2-cli'; Source = (Join-Path $root 'codex-global-config\skills\gpt-image-2-cli') },
            @{ Name = 'project-doc-planner'; Source = (Join-Path $root 'shared\skills\project-doc-planner') },
            @{ Name = 'orchestrate-model-workflow'; Source = (Join-Path $root 'codex-global-config\skills\orchestrate-model-workflow') }
        )
    }
    zcode = @{
        Label = 'ZCode'; HomeEnv = 'ZCODE_HOME'; DefaultHome = '.zcode'; RoleKind = 'md'; RoleCount = 5; Placeholder = 'ZCODE_HOME'
        ConfigMode = 'none'; RolesInstall = 'directory'; RolesRel = 'agents\ai-vibecode-superpower'
        Roles = Join-Path $root 'zcode-global-config\agents\ai-vibecode-superpower'
        Manifest = Join-Path $root 'zcode-global-config\agents\ai-vibecode-superpower.sha256'
        Instructions = Join-Path $root 'zcode-global-config\AGENTS.md'
        Docs = Join-Path $root 'zcode-global-config\docs'
        Skills = @(
            @{ Name = 'agent-toolchain'; Source = (Join-Path $root 'shared\skills\agent-toolchain') },
            @{ Name = 'project-doc-planner'; Source = (Join-Path $root 'shared\skills\project-doc-planner') },
            @{ Name = 'orchestrate-model-workflow'; Source = (Join-Path $root 'zcode-global-config\skills\orchestrate-model-workflow') }
        )
    }
    opencode = @{
        Label = 'opencode'; HomeEnv = 'OPENCODE_HOME'; DefaultHome = '.config\opencode'; RoleKind = 'mdopencode'; RoleCount = 12; Placeholder = 'OPENCODE_HOME'
        ConfigMode = 'opencode-json'; RolesInstall = 'files'; RolesRel = 'agent'
        Roles = Join-Path $root 'opencode-global-config\agents\ai-vibecode-superpower'
        Manifest = Join-Path $root 'opencode-global-config\agents\ai-vibecode-superpower.sha256'
        Instructions = Join-Path $root 'opencode-global-config\AGENTS.md'
        Docs = Join-Path $root 'opencode-global-config\docs'
        ConfigSource = Join-Path $root 'opencode-global-config\opencode.json'
        Skills = @(
            @{ Name = 'agent-toolchain'; Source = (Join-Path $root 'opencode-global-config\skills\agent-toolchain') },
            @{ Name = 'orchestrate-model-workflow'; Source = (Join-Path $root 'opencode-global-config\skills\orchestrate-model-workflow') },
            @{ Name = 'project-doc-planner'; Source = (Join-Path $root 'shared\skills\project-doc-planner') }
        )
    }
    dsh = @{
        Label = 'dsh'; HomeEnv = 'DSH_HOME'; DefaultHome = '.dsh'; RoleKind = 'none'; RoleCount = 0; Placeholder = 'DSH_HOME'
        ConfigMode = 'dsh-probe'; RolesInstall = 'none'; RolesRel = ''
        Instructions = Join-Path $root 'dsh-global-config\AGENTS.md'
        Docs = Join-Path $root 'dsh-global-config\docs'
        Skills = @(
            @{ Name = 'orchestrate-model-workflow'; Source = (Join-Path $root 'dsh-global-config\skills\orchestrate-model-workflow') }
        )
    }
}

if ([string]::IsNullOrWhiteSpace($Client)) {
    $allClients = @($clientProfiles.Keys)
    if ([Console]::IsInputRedirected) { throw "No client specified. Usage: .\install.ps1 -Client <$((@($allClients) + 'all') -join '|')>" }
    Write-Host 'Select the client to install:'
    $index = 1
    foreach ($name in $allClients) { Write-Host ("  {0}) {1}" -f $index, $clientProfiles[$name].Label); $index++ }
    Write-Host ("  {0}) All" -f $index)
    $choice = Read-Host 'Enter number or name (q to quit)'
    if ($choice -match '^[qQ]$') { return }
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le ($allClients.Count + 1)) {
        if ([int]$choice -le $allClients.Count) { $Client = $allClients[[int]$choice - 1] } else { $Client = 'all' }
    } else {
        $Client = $choice
    }
}
$Client = $Client.Trim().ToLowerInvariant()
if ($Client -eq 'all') {
    $allClients = @($clientProfiles.Keys)
    foreach ($name in $allClients) {
        Write-Host "=== 安装 $name ==="
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        & $pwsh -NoLogo -NoProfile -File $PSCommandPath -Client $name
        if ($LASTEXITCODE -ne 0) { throw "客户端 $name 安装失败；后续客户端未继续。" }
    }
    Write-Host '四个客户端均已安装完成。'
    return
}
if (-not $clientProfiles.Contains($Client)) { throw "Unknown client: $Client (supported: $((@($clientProfiles.Keys) + 'all') -join '|'))" }
$profile = $clientProfiles[$Client]
$label = $profile.Label

$profilePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
$homeEnvValue = [Environment]::GetEnvironmentVariable($profile.HomeEnv)
$homePath = if ($homeEnvValue) { [IO.Path]::GetFullPath($homeEnvValue) } else { [IO.Path]::GetFullPath((Join-Path $profilePath $profile.DefaultHome)) }
if ([string]::IsNullOrWhiteSpace($homePath) -or [IO.Path]::GetPathRoot($homePath).TrimEnd('\') -eq $homePath.TrimEnd('\')) { throw "Refusing unsafe $label home: $homePath" }

if ($Client -eq 'dsh' -and -not (Get-Command dsh -ErrorAction SilentlyContinue)) { throw '未找到 dsh 命令；请先安装 @deepseek-ai/dsh 并运行一次 dsh web，再重新运行本脚本。' }

foreach ($path in @($profile.Docs, $sourceSystemDocs, $profile.Instructions)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing source: $path" } }
if ($profile.Contains('Roles')) { foreach ($path in @($profile.Roles, $profile.Manifest)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing source: $path" } } }
if ($profile.ConfigMode -eq 'toml') { foreach ($path in @($profile.ConfigTemplate, $profile.ProviderSettings)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing source: $path" } } }
if ($profile.ConfigMode -eq 'opencode-json') { if (-not (Test-Path -LiteralPath $profile.ConfigSource)) { throw "Missing source: $($profile.ConfigSource)" } }
foreach ($skill in $profile.Skills) {
    if (-not (Test-Path -LiteralPath $skill.Source -PathType Container)) { throw "Missing skill: $($skill.Name)" }
    if (-not (Test-Path -LiteralPath (Join-Path $skill.Source 'SKILL.md') -PathType Leaf)) { throw "Missing SKILL.md for skill: $($skill.Name)" }
}
if (Test-Path -LiteralPath (Join-Path $profile.Docs 'system')) { throw "$($profile.Docs) must not contain a system/ directory; shared system docs are composed by the installer" }
Assert-ManagedRoles $profile.RoleKind $profile.Roles $profile.Manifest $profile.RoleCount
Assert-NoReparseChain $root
Assert-NoReparse $root
Assert-NoReparseChain $homePath

$existingConfig = $null
if ($profile.ConfigMode -eq 'toml') { $existingConfig = Join-Path $homePath 'config.toml' }
$stagedOpenCodeJson = $null
if ($profile.ConfigMode -eq 'opencode-json' -and -not (Test-Path -LiteralPath (Join-Path $homePath 'opencode.json'))) { $stagedOpenCodeJson = Join-Path $homePath 'opencode.json' }

$stage = Join-Path $homePath ('.install-stage-' + [Guid]::NewGuid().ToString('N'))
$backup = $null
$targets = @(
    @{ Name='AGENTS.md'; Target=(Join-Path $homePath 'AGENTS.md'); Candidate=(Join-Path $stage 'AGENTS.md'); Kind='File'; BackedUp=$false; InstallStarted=$false },
    @{ Name='docs'; Target=(Join-Path $homePath 'docs'); Candidate=(Join-Path $stage 'docs'); Kind='Directory'; BackedUp=$false; InstallStarted=$false }
)
if ($null -ne $existingConfig) {
    $targets = @(@{ Name='config.toml'; Target=$existingConfig; Candidate=(Join-Path $stage 'config.toml'); Kind='File'; BackedUp=$false; InstallStarted=$false }) + $targets
}
if ($null -ne $stagedOpenCodeJson) {
    $targets = @(@{ Name='opencode.json'; Target=$stagedOpenCodeJson; Candidate=(Join-Path $stage 'opencode.json'); Kind='File'; BackedUp=$false; InstallStarted=$false }) + $targets
}
if ($profile.RolesInstall -eq 'directory') {
    $targets += @{ Name='agents/ai-vibecode-superpower'; Target=(Join-Path $homePath $profile.RolesRel); Candidate=(Join-Path $stage 'agents\ai-vibecode-superpower'); Kind='Directory'; BackedUp=$false; InstallStarted=$false }
} elseif ($profile.RolesInstall -eq 'files') {
    foreach ($file in Get-ChildItem -LiteralPath $profile.Roles -Filter '*.md' -File) {
        $targets += @{ Name="agent/$($file.Name)"; Target=(Join-Path $homePath "agent\$($file.Name)"); Candidate=(Join-Path $stage "agents\ai-vibecode-superpower\$($file.Name)"); Kind='File'; BackedUp=$false; InstallStarted=$false }
    }
}
foreach ($skill in $profile.Skills) { $targets += @{ Name="skills/$($skill.Name)"; Target=(Join-Path $homePath "skills\$($skill.Name)"); Candidate=(Join-Path $stage "skills\$($skill.Name)"); Kind='Directory'; BackedUp=$false; InstallStarted=$false } }
foreach ($target in $targets) { Assert-InstallTarget $target.Target $target.Kind }
$containers = @((Join-Path $homePath 'skills'),(Join-Path $homePath 'backups'))
if ($profile.RolesInstall -eq 'directory') { $containers += (Join-Path $homePath 'agents') }
if ($profile.RolesInstall -eq 'files') { $containers += (Join-Path $homePath 'agent') }
foreach ($container in $containers) { Assert-InstallContainer $container }

try {
    New-Item -ItemType Directory -Path $homePath -Force | Out-Null
    Assert-NoReparseChain $homePath
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stage 'skills') -Force | Out-Null
    if ($profile.RolesInstall -ne 'none') { New-Item -ItemType Directory -Path (Join-Path $stage 'agents\ai-vibecode-superpower') -Force | Out-Null }
    Copy-Item $profile.Instructions (Join-Path $stage 'AGENTS.md')
    Copy-Item $profile.Docs (Join-Path $stage 'docs') -Recurse
    Copy-Item $sourceSystemDocs (Join-Path $stage 'docs\system') -Recurse
    if ($profile.RolesInstall -eq 'directory') { Copy-Item $profile.Roles (Join-Path $stage 'agents') -Recurse }
    elseif ($profile.RolesInstall -eq 'files') { Copy-Item (Join-Path $profile.Roles '*') (Join-Path $stage 'agents\ai-vibecode-superpower') }
    foreach ($skill in $profile.Skills) { Copy-Item $skill.Source (Join-Path $stage 'skills') -Recurse }
    if ($null -ne $existingConfig) { Merge-Config $profile.ConfigTemplate $existingConfig $profile.ProviderSettings (Join-Path $stage 'config.toml') }
    if ($null -ne $stagedOpenCodeJson) { Copy-Item $profile.ConfigSource (Join-Path $stage 'opencode.json') }
    Expand-Placeholders $stage $profile.Placeholder $homePath
    if ($profile.RolesInstall -ne 'none') { Assert-ManagedRoles $profile.RoleKind (Join-Path $stage 'agents\ai-vibecode-superpower') $profile.Manifest $profile.RoleCount }

    $backupRoot = Join-Path $homePath 'backups'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Assert-InstallContainer $backupRoot
    $backup = Join-Path $backupRoot ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target.Target) {
            $backupTarget = Join-Path $backup $target.Name
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupTarget) -Force | Out-Null
            Move-Item -LiteralPath $target.Target -Destination $backupTarget
            $target.BackedUp = $true
        }
        if ($null -ne $target.Candidate) {
            $target.InstallStarted = $true
            New-Item -ItemType Directory -Path (Split-Path -Parent $target.Target) -Force | Out-Null
            Move-Item -LiteralPath $target.Candidate -Destination $target.Target
        }
    }
    if ($profile.RolesInstall -ne 'none') { Assert-ManagedRoles $profile.RoleKind (Join-Path $homePath $profile.RolesRel) $profile.Manifest $profile.RoleCount $(if ($profile.RolesInstall -eq 'files') { 0 } else { 1 }) }
    Write-Host "$label configuration installed in: $homePath"
    if ($profile.RolesInstall -eq 'none') { Write-Host 'Standalone skills installed.' } else { Write-Host 'Standalone skills and managed agent roles installed.' }
    Write-Host "Backup directory: $backup"
    switch ($Client) {
        'zcode' { Write-Host 'Unmanaged ZCode state (cli/, v2/, plugins, other skills and agents) was not modified.' }
        'opencode' {
            if ($null -eq $stagedOpenCodeJson) {
                Write-Host 'opencode.json 已存在，安装器没有覆盖。如需启用默认模型，请手动合并 model 字段：'
                Write-Host '  "model": "merge-ai/deepseek-v4-flash",'
            }
            Write-Host 'Unmanaged opencode state (unrelated agents/skills) was not modified.'
        }
        'dsh' {
            Write-Host 'Unmanaged DSH state (settings.yaml, cli/, plugins and other skills) was not modified.'
            $settingsPath = Join-Path $homePath 'settings.yaml'
            Write-Host '检查模型分层配置 ...'
            if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
                $settingsText = Get-Content -LiteralPath $settingsPath -Raw
                $flashOk = $settingsText -match 'deepseek-v4-flash-0731'
                $proOk = $settingsText -match 'deepseek-v4-pro-0813'
                if ($flashOk -and $proOk) {
                    Write-Host '已检测到 flash 与 pro 两个模型档，分层可用。'
                } else {
                    Write-Host '注意：settings.yaml 未同时包含 deepseek-v4-flash-0731 与 deepseek-v4-pro-0813。'
                    Write-Host 'orchestrate-model-workflow 的 Luna(flash)/Terra+Sol(pro) 分层需要这两个模型档，请按需补充。'
                }
            } else {
                Write-Host "未找到 $settingsPath；模型分层请按需在 DSH 配置中声明两个模型档。"
            }
        }
    }
}
catch {
    $original = $_.Exception.Message
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    foreach ($target in $targets) {
        if (-not $target.InstallStarted) { continue }
        try {
            if (Test-Path -LiteralPath $target.Target) {
                $item = Get-Item -LiteralPath $target.Target -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to remove reparse point during rollback: $($target.Target)" }
                Remove-Item -LiteralPath $target.Target -Recurse -Force
            }
        } catch { $rollbackErrors.Add("Could not remove installed target $($target.Target): $($_.Exception.Message)") }
    }
    foreach ($target in $targets) {
        if (-not $target.BackedUp -or $null -eq $backup) { continue }
        $backupTarget = Join-Path $backup $target.Name
        if (-not (Test-Path -LiteralPath $backupTarget)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $target.Target)) { New-Item -ItemType Directory -Path (Split-Path -Parent $target.Target) -Force | Out-Null; Move-Item -LiteralPath $backupTarget -Destination $target.Target }
        } catch { $rollbackErrors.Add("Could not restore target $($target.Target): $($_.Exception.Message)") }
    }
    if ($rollbackErrors.Count -gt 0) { throw "$original; rollback incomplete: $($rollbackErrors -join '; ') Backup retained at $backup" }
    throw
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
