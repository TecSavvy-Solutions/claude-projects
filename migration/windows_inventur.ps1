# windows_inventur.ps1 - READ-ONLY Inventur vor dem Umstieg auf Linux Mint
# Aendert NICHTS am System. Schreibt nur eine Textdatei auf den Desktop.
# Start (kein Admin noetig, Admin liefert nur zusaetzlich BitLocker-Status):
#   powershell -ExecutionPolicy Bypass -File .\windows_inventur.ps1
# Gesammelt werden: Namen, Groessen, Pfade, Versionen. NICHT gesammelt: Dateiinhalte,
# Passwoerter, Tokens (Werte von Umgebungsvariablen ausser PATH/PYTHON*, MCP-env/headers, cmdkey-Passwoerter).
# Nur ASCII im Skript (Windows PowerShell 5.1 liest BOM-lose Dateien als ANSI).

$ErrorActionPreference = 'Continue'
$desktop = [Environment]::GetFolderPath('Desktop')
$stamp   = Get-Date -Format 'yyyyMMdd_HHmm'
$script:Out = Join-Path $desktop ("inventur_{0}_{1}.txt" -f $env:COMPUTERNAME, $stamp)
New-Item -ItemType File -Path $script:Out -Force | Out-Null

function W([string]$s) { Add-Content -LiteralPath $script:Out -Value $s -Encoding UTF8 }
function Sec([string]$t) { W ''; W ('=' * 78); W $t; W ('=' * 78); Write-Host "-> $t" }

function Redact([string]$s) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '://[^@/\s]+@', '://***@'
    if ($s -match '(?i)pass|pwd|token|secret|apikey|api_key|credential') { return '[REDACTED: Zeile enthaelt pass/token/secret]' }
    return $s
}

function Run([string]$title, [scriptblock]$block) {
    Sec $title
    try {
        $r = & $block 2>&1 | Out-String -Width 250
        W $r
    } catch {
        W ("FEHLER: " + $_.Exception.Message)
    }
}

$skipDirs = @('node_modules', 'AppData', '.venv', 'venv', 'Windows', 'Program Files', 'Program Files (x86)',
              'ProgramData', '$Recycle.Bin', 'System Volume Information', '.cache', '.npm', '__pycache__', 'Recovery')

function Get-TopLevel([string]$path, [string[]]$noSize = @()) {
    $mask = 0x441000   # Offline | RecallOnOpen | RecallOnDataAccess = Cloud-Platzhalter (OneDrive/Nextcloud Virtual Files)
    Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $item = $_
        $sizeMB = ''; $files = ''; $cloud = ''
        $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($item.PSIsContainer) {
            if ($isLink) { $sizeMB = 'link' }
            elseif ($noSize -contains $item.Name) { $sizeMB = 'uebersprungen' }
            else {
                $sum = 0L; $cnt = 0; $off = 0
                Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $cnt++; $sum += $_.Length
                    if (([int]$_.Attributes -band $mask) -ne 0) { $off++ }
                }
                $sizeMB = [math]::Round($sum / 1MB, 1); $files = $cnt; $cloud = $off
            }
        } else {
            $sizeMB = [math]::Round($item.Length / 1MB, 2); $files = 1
        }
        [PSCustomObject]@{
            Name = $item.Name
            Typ = $(if ($item.PSIsContainer) { 'DIR' } else { 'FILE' })
            SizeMB = $sizeMB
            Dateien = $files
            CloudOnly = $cloud
            Attribute = $item.Attributes.ToString()
            Geaendert = $item.LastWriteTime.ToString('yyyy-MM-dd')
        }
    }
}

function Find-GitRepos([string]$root, [int]$depth) {
    if ($depth -lt 0) { return }
    $dirs = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($d.Name -eq '.git') { $d.Parent.FullName; continue }
        if ($skipDirs -contains $d.Name) { continue }
        Find-GitRepos $d.FullName ($depth - 1)
    }
}

W ("Inventur erstellt: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  Benutzer: " + $env:USERNAME + "  Rechner: " + $env:COMPUTERNAME)

# ---------------------------------------------------------------- 1. Hardware / Boot
Run '1.1 System & Hardware (relevant fuer Mint-Kompatibilitaet)' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    "OS:        $($os.Caption) $($os.Version) Build $($os.BuildNumber)"
    "Modell:    $($cs.Manufacturer) $($cs.Model)"
    "CPU:       $($cpu.Name)  Kerne: $($cpu.NumberOfCores)  Threads: $($cpu.NumberOfLogicalProcessors)"
    "RAM:       $([math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) GB"
    "BIOS:      " + ((Get-CimInstance Win32_BIOS | Select-Object -First 1) | ForEach-Object { "$($_.Manufacturer) $($_.SMBIOSBIOSVersion)" })
    try { "SecureBoot/UEFI: " + (Confirm-SecureBootUEFI) } catch { "SecureBoot/UEFI: nicht UEFI oder nicht abfragbar (Legacy-BIOS moeglich)" }
    'GPU:'
    Get-CimInstance Win32_VideoController | ForEach-Object { "  - $($_.Name)  Treiber $($_.DriverVersion)" }
    'Netzwerk-Adapter (WLAN-Chip wichtig fuer Linux):'
    Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter } | ForEach-Object { "  - $($_.Name)" }
    'Bluetooth/Audio:'
    Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPClass -in @('Bluetooth', 'MEDIA') } | Select-Object -ExpandProperty Name -Unique | ForEach-Object { "  - $_" }
}

Run '1.2 Laufwerke / Volumes' {
    Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType, HealthStatus,
        @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } },
        @{n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } } | Format-Table -AutoSize
    Get-PhysicalDisk | Select-Object FriendlyName, MediaType, BusType, HealthStatus,
        @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 0) } } | Format-Table -AutoSize
}

Run '1.3 BitLocker / Geraeteverschluesselung (braucht Admin, sonst Hinweis)' {
    try { Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionMethod | Format-Table -AutoSize }
    catch { 'nicht abfragbar (kein Admin?) - Falls BitLocker aktiv: Recovery-Key sichern ist fuer Wipe irrelevant, aber Daten VOR Wipe kopieren.' }
}

# ---------------------------------------------------------------- 2. Ordner & Groessen
$profile = $env:USERPROFILE
Run "2.1 Benutzerprofil Top-Level inkl. versteckter ($profile) - CloudOnly = nur online (nicht lokal!)" {
    Get-TopLevel $profile @('AppData') | Sort-Object { if ($_.SizeMB -is [double] -or $_.SizeMB -is [decimal]) { -[double]$_.SizeMB } else { 0 } } | Format-Table -AutoSize
}

Run '2.2 AppData Top-Level (nur Groessen der Unterordner Roaming/Local)' {
    foreach ($p in @('Roaming', 'Local')) {
        "--- AppData\$p"
        Get-TopLevel (Join-Path $profile "AppData\$p") | Where-Object { $_.Typ -eq 'DIR' } |
            Sort-Object { if ($_.SizeMB -is [double] -or $_.SizeMB -is [decimal]) { -[double]$_.SizeMB } else { 0 } } |
            Select-Object -First 25 | Format-Table -AutoSize
    }
}

Run '2.3 Bekannte Ordner / Umleitungen (OneDrive?)' {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $p = Get-ItemProperty $k
    foreach ($n in @('Desktop', 'Personal', 'My Pictures', 'My Music', 'My Video', '{374DE290-123F-4565-9164-39C4925E467B}')) { "{0,-45} {1}" -f $n, $p.$n }
    "OneDrive:           $env:OneDrive"
    "OneDriveConsumer:   $env:OneDriveConsumer"
    "OneDriveCommercial: $env:OneDriveCommercial"
}

Run '2.4 Laufwerks-Wurzeln aller festen Laufwerke (Windows/Programme ohne Groessenberechnung)' {
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
        "--- $($_.Root)"
        Get-TopLevel $_.Root $skipDirs | Format-Table -AutoSize
    }
}

if (Test-Path 'C:\homeserver') {
    Run '2.5 C:\homeserver Baum (Tiefe 2, nur Namen; ohne node_modules/.git/.venv)' {
        function Show-Tree([string]$p, [int]$d, [string]$indent) {
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Sort-Object { -not $_.PSIsContainer }, Name | ForEach-Object {
                if ($_.PSIsContainer) {
                    "$indent[D] $($_.Name)"
                    if ($d -gt 0 -and $skipDirs -notcontains $_.Name -and $_.Name -ne '.git' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Show-Tree $_.FullName ($d - 1) ($indent + '    ') }
                } else { "$indent$($_.Name)" }
            }
        }
        Show-Tree 'C:\homeserver' 2 ''
    }
}

# ---------------------------------------------------------------- 3. Git
Run '3.1 Git-Repos (Profil, C:\homeserver, alle Laufwerke bis Tiefe 6) + Sicherungsstatus' {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { 'git nicht gefunden'; return }
    $roots = @($profile)
    if (Test-Path 'C:\homeserver') { $roots += 'C:\homeserver' }
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null -and $_.Root -ne 'C:\' } | ForEach-Object { $roots += $_.Root }
    $repos = @(); foreach ($r in $roots) { $repos += Find-GitRepos $r 6 }
    $repos = $repos | Sort-Object -Unique
    $repos | ForEach-Object {
        $r = $_
        $g = @('-c', 'safe.directory=*', '-C', $r)
        $remote = (& git @g remote -v 2>$null | Select-Object -First 1)
        $branch = (& git @g branch --show-current 2>$null)
        $st = @(& git @g status --porcelain=v1 2>$null)
        $unpushed = @(& git @g log --branches --not --remotes --oneline 2>$null).Count
        $stash = @(& git @g stash list 2>$null).Count
        $last = (& git @g log -1 --format=%cd --date=short 2>$null)
        [PSCustomObject]@{
            Repo = $r; Branch = $branch; Geaendert = $st.Count; UngepushteCommits = $unpushed; Stashes = $stash
            LetzterCommit = $last; Remote = (Redact ([string]$remote))
        }
    } | Format-List
    "Repos gesamt: $($repos.Count)"
}

# ---------------------------------------------------------------- 4. Software
Run '4.1 Installierte Programme (Registry)' {
    $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher | Sort-Object DisplayName -Unique | Format-Table -AutoSize
}
Run '4.2 winget list' {
    if (Get-Command winget -ErrorAction SilentlyContinue) { winget list --accept-source-agreements } else { 'winget nicht vorhanden' }
}
Run '4.3 Store-Apps (ohne System)' {
    Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } |
        Select-Object Name, Version | Sort-Object Name | Format-Table -AutoSize
}
Run '4.4 WSL / Docker Desktop / Hyper-V (koennen Daten enthalten!)' {
    if (Get-Command wsl -ErrorAction SilentlyContinue) { (wsl -l -v 2>&1 | Out-String) -replace "`0", '' } else { 'wsl nicht vorhanden' }
    'Docker Desktop installiert: ' + (Test-Path 'C:\Program Files\Docker')
    try { Get-VM | Select-Object Name, State | Format-Table -AutoSize } catch { 'Hyper-V: keine VMs abfragbar' }
}

# ---------------------------------------------------------------- 5. Python
Run '5.1 Python (C:\Python314 + weitere Installationen)' {
    $py = 'C:\Python314\python.exe'
    if (Test-Path $py) {
        "Version: " + (& $py --version 2>&1)
        'sys.path / prefix:'
        & $py -c "import sys; print('prefix=', sys.prefix); print('\n'.join(sys.path))" 2>&1 | Where-Object { $_ -notmatch 'platform independent' }
        'pip config:'
        & $py -m pip config list 2>&1 | Where-Object { $_ -notmatch 'platform independent' }
        'pip freeze:'
        & $py -m pip freeze 2>&1 | Where-Object { $_ -notmatch 'platform independent' }
    } else { 'C:\Python314\python.exe nicht gefunden' }
    ''
    'Alle python.exe (PATH):'
    where.exe python 2>&1
    'py-Launcher:'
    if (Get-Command py -ErrorAction SilentlyContinue) { py -0p 2>&1 }
    'Weitere Installationen:'
    Get-ChildItem 'C:\' -Filter 'Python*' -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
}
Run '5.2 Python-Pfadumleitung: .pth-Dateien, Lib/Scripts in C:\homeserver, virtuelle Umgebungen' {
    'site-packages *.pth / sitecustomize / usercustomize:'
    Get-ChildItem 'C:\Python314\Lib\site-packages' -Include *.pth, sitecustomize.py, usercustomize.py -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    ''
    if (Test-Path 'C:\homeserver\Lib') { 'C:\homeserver\Lib (Top-Level Namen):'; Get-ChildItem 'C:\homeserver\Lib' -Force | ForEach-Object { '  ' + $_.Name } }
    if (Test-Path 'C:\homeserver\Scripts') { 'C:\homeserver\Scripts (Top-Level Namen):'; Get-ChildItem 'C:\homeserver\Scripts' -Force | ForEach-Object { '  ' + $_.Name } }
    ''
    'venv-Ordner (pyvenv.cfg) unter C:\homeserver und Profil (ohne AppData):'
    foreach ($r in @('C:\homeserver', $profile)) {
        if (Test-Path $r) {
            Get-ChildItem $r -Recurse -Force -Filter pyvenv.cfg -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\AppData\\' } | ForEach-Object { $_.DirectoryName }
        }
    }
    ''
    'requirements.txt / pyproject.toml / Pipfile (Projektabhaengigkeiten):'
    foreach ($r in @('C:\homeserver', $profile)) {
        if (Test-Path $r) {
            Get-ChildItem $r -Recurse -Force -Include requirements*.txt, pyproject.toml, Pipfile -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\(AppData|node_modules|site-packages)\\' } | ForEach-Object { $_.FullName }
        }
    }
}
Run '5.3 Umgebungsvariablen (Namen; Werte nur fuer PATH/PYTHON*)' {
    foreach ($scope in @('User', 'Machine')) {
        "--- $scope"
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in ($vars.Keys | Sort-Object)) {
            if ($k -match '^(Path|PYTHON.*)$') { "{0} = {1}" -f $k, $vars[$k] } else { $k }
        }
    }
}

# ---------------------------------------------------------------- 6. Automation / Autostart
Run '6.1 Geplante Tasks (ohne Microsoft-Standard)' {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft*' } | ForEach-Object {
        $a = ($_.Actions | ForEach-Object { Redact ("$($_.Execute) $($_.Arguments)") }) -join ' | '
        "{0}{1}  [{2}]  {3}" -f $_.TaskPath, $_.TaskName, $_.State, $a
    }
}
Run '6.2 Autostart (Run-Keys, Startup-Ordner)' {
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        "--- $k"
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { "{0} = {1}" -f $_.Name, (Redact ([string]$_.Value)) } }
    }
    '--- Startup-Ordner'
    Get-ChildItem ([Environment]::GetFolderPath('Startup')) -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
}
Run '6.3 Gespeicherte Windows-Anmeldedaten (NUR Ziele, keine Passwoerter)' {
    cmdkey /list 2>&1 | Where-Object { $_ -match 'Ziel|Target' }
}

# ---------------------------------------------------------------- 7. Claude / Tools / Secrets-Orte
Run '7.1 Claude-Daten (Groessen, MCP-Server nur Name/Typ/URL ohne Header/Env)' {
    foreach ($p in @("$profile\.claude", "$env:APPDATA\Claude", 'C:\homeserver\.claude')) {
        if (Test-Path $p) {
            $m = Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
            "{0}  ->  {1} MB, {2} Dateien" -f $p, [math]::Round($m.Sum / 1MB, 1), $m.Count
        } else { "$p  ->  nicht vorhanden" }
    }
    ''
    $cj = "$profile\.claude.json"
    if (Test-Path $cj) {
        ".claude.json vorhanden ($([math]::Round((Get-Item $cj).Length/1KB,1)) KB)"
        try {
            $j = Get-Content $cj -Raw | ConvertFrom-Json
            if ($j.mcpServers) { 'Globale MCP-Server:'; $j.mcpServers.PSObject.Properties | ForEach-Object { "  - {0}  type={1}  url={2}  command={3}" -f $_.Name, $_.Value.type, (Redact ([string]$_.Value.url)), $_.Value.command } }
        } catch { 'Konnte .claude.json nicht parsen.' }
    }
    ''
    if (Test-Path "$profile\.claude\projects") {
        'Transkript-Projekte (.claude\projects):'
        Get-ChildItem "$profile\.claude\projects" -Directory | ForEach-Object {
            $c = @(Get-ChildItem $_.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue).Count
            "  {0}  ({1} Sessions)" -f $_.Name, $c
        }
    }
    ''
    'Hook-/Settings-Dateien (nur Existenz):'
    foreach ($f in @("$profile\.claude\settings.json", "$profile\.claude\settings.local.json", 'C:\homeserver\.claude\settings.local.json', 'C:\homeserver\CLAUDE.md')) { "  {0}  ->  {1}" -f $f, (Test-Path $f) }
}
Run '7.2 SSH (nur Dateinamen + Host-Zeilen, keine Schluessel)' {
    $ssh = "$profile\.ssh"
    if (Test-Path $ssh) {
        Get-ChildItem $ssh -Force | ForEach-Object { "{0}  ({1} Bytes)" -f $_.Name, $_.Length }
        if (Test-Path "$ssh\config") { '--- config (nur Host/HostName/User/IdentityFile):'; Select-String -Path "$ssh\config" -Pattern '^\s*(Host|HostName|User|IdentityFile)\b' | ForEach-Object { $_.Line } }
    } else { '.ssh nicht vorhanden' }
}
Run '7.3 Nextcloud-Client (nur Sync-Pfade)' {
    $cfg = "$env:APPDATA\Nextcloud\nextcloud.cfg"
    if (Test-Path $cfg) { Select-String -Path $cfg -Pattern 'localPath|targetPath|\\url=|virtualFilesMode|paused' | ForEach-Object { Redact $_.Line } } else { 'nextcloud.cfg nicht gefunden' }
}
Run '7.4 Browser-Profile & Passwort-Manager-Spuren (nur Groessen)' {
    $b = @{
        'Chrome'  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        'Edge'    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        'Firefox' = "$env:APPDATA\Mozilla\Firefox\Profiles"
    }
    foreach ($k in $b.Keys) {
        if (Test-Path $b[$k]) {
            $m = Get-ChildItem $b[$k] -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
            "{0}: {1} MB  ({2})" -f $k, [math]::Round($m.Sum / 1MB, 0), $b[$k]
        } else { "$k: nicht vorhanden" }
    }
    'Hinweis: Lesezeichen/Passwoerter vor dem Wipe per Browser-Sync oder Export sichern.'
}
Run '7.5 Dateien, die nach Secrets aussehen (nur Pfade; NICHT in Git/Backup unverschluesselt ablegen)' {
    foreach ($r in @('C:\homeserver', "$profile\Documents", "$profile\Desktop", "$profile\Downloads")) {
        if (Test-Path $r) {
            Get-ChildItem $r -Recurse -Force -File -Include '.env*', '*.pem', '*.key', '*.pfx', '*.kdbx', 'id_rsa*', 'id_ed25519*', '*password*', '*passwort*', '*credential*', '*secret*', '*token*' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\(node_modules|site-packages|\.git)\\' } | ForEach-Object { $_.FullName }
        }
    }
}

# ---------------------------------------------------------------- 8. Grosse Dateien & Dateitypen
Run '8.1 Groesste Dateien (>200 MB) in Profil (ohne AppData) und C:\homeserver' {
    foreach ($r in @($profile, 'C:\homeserver')) {
        if (Test-Path $r) {
            Get-ChildItem $r -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 200MB -and $_.FullName -notmatch '\\AppData\\' } |
                Sort-Object Length -Descending | Select-Object -First 30 |
                ForEach-Object { "{0,10} MB  {1}" -f [math]::Round($_.Length / 1MB, 0), $_.FullName }
        }
    }
}
Run '8.2 Dateitypen in Dokumenten-Bereichen (Anzahl, ohne AppData)' {
    foreach ($r in @("$profile\Documents", "$profile\Desktop", "$profile\Downloads", 'C:\homeserver')) {
        if (Test-Path $r) {
            "--- $r"
            Get-ChildItem $r -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\(AppData|node_modules|\.git|site-packages)\\' } |
                Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 15 Count, Name | Format-Table -AutoSize
        }
    }
}

Sec 'FERTIG'
W "Ausgabedatei: $script:Out"
Write-Host ''
Write-Host "FERTIG. Ausgabe: $script:Out" -ForegroundColor Green
Write-Host 'Bitte Datei pruefen (enthaelt Datei-/Ordnernamen) und dann an Claude geben.'
