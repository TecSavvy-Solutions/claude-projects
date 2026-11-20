# windows_backup.ps1 - Sicherung vor dem Umstieg auf Linux (robocopy + SHA256-Manifest)
# - Die QUELLE wird nie veraendert oder geloescht (nur Lesen).
# - Standard = TROCKENLAUF: zeigt nur, was kopiert wuerde (Dateizahl/Bytes je Ordner). Kopiert wird erst mit -Execute.
# - Ordnerliste steht in einer lokalen .psd1-Datei (-Config), damit keine persoenlichen Pfade im Repo stehen.
#   Vorlage: backup_config.example.psd1
# Start (PowerShell, normal):
#   powershell -ExecutionPolicy Bypass -File C:\Temp\windows_backup.ps1 -Config C:\Temp\backup_config.psd1 -Dest "\\HOST\SHARE\ZIELORDNER"
#   ... dasselbe nochmal mit -Execute, wenn der Trockenlauf gut aussieht.
# Nur ASCII im Skript (Windows PowerShell 5.1).

param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Dest,
    [switch]$Execute
)

$ErrorActionPreference = 'Continue'
$stamp  = Get-Date -Format 'yyyyMMdd_HHmm'
$logDir = 'C:\Temp'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$roboLog = Join-Path $logDir ("backup_robocopy_{0}.log" -f $stamp)
$sumLog  = Join-Path $logDir ("backup_summary_{0}.txt" -f $stamp)

function Say([string]$s) { Write-Host $s; Add-Content -LiteralPath $sumLog -Value $s -Encoding UTF8 }
# Platzhalter %VAR% per reiner String-Ersetzung aufloesen (keine .NET-Aufrufe, kein Namenskonflikt mit Cmdlets)
$envTokens = @{
    '%USERPROFILE%'  = $env:USERPROFILE
    '%APPDATA%'      = $env:APPDATA
    '%LOCALAPPDATA%' = $env:LOCALAPPDATA
    '%TEMP%'         = $env:TEMP
    '%COMPUTERNAME%' = $env:COMPUTERNAME
}
function Resolve-BackupPath([string]$raw) {
    $out = $raw
    foreach ($k in $envTokens.Keys) { $out = $out.Replace($k, [string]$envTokens[$k]) }
    return $out
}

if (-not (Test-Path -LiteralPath $Config)) { Write-Host "FEHLER: Config nicht gefunden: $Config"; exit 1 }
$cfg = Import-PowerShellDataFile -LiteralPath $Config

Write-Host ('Config gelesen: Items={0}  GitRepos={1}  Secrets={2}' -f @($cfg.Items).Count, @($cfg.GitRepos).Count, @($cfg.Secrets).Count)

$modus = 'TROCKENLAUF (es wird NICHTS kopiert)'
if ($Execute) { $modus = 'KOPIEREN' }
Say ("Backup {0}  Rechner: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME)
Say "Modus: $modus"
Say "Ziel:  $Dest"
Say "Logs:  $roboLog  /  $sumLog"

# ---------------------------------------------------------------- Ziel pruefen
$destRoot = $Dest
if (-not (Test-Path -LiteralPath $Dest)) { $destRoot = Split-Path -Parent $Dest }
if (-not (Test-Path -LiteralPath $destRoot)) {
    Say "FEHLER: Ziel nicht erreichbar: $destRoot  (Freigabe/Tailscale/Anmeldedaten pruefen)"
    exit 1
}
if ($Execute -and -not (Test-Path -LiteralPath $Dest)) {
    try { New-Item -ItemType Directory -Path $Dest -Force -ErrorAction Stop | Out-Null }
    catch { Say ("FEHLER: Zielordner nicht anlegbar: " + $_.Exception.Message); exit 1 }
}

# ---------------------------------------------------------------- Git-Check (nur Namen)
if ($cfg.GitRepos) {
    Say ''
    Say '--- Git-Check: Repos mit ungesicherten Aenderungen ---'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { Say 'git nicht gefunden - Check uebersprungen' }
    else {
        foreach ($r in $cfg.GitRepos) {
            $repo = Resolve-BackupPath $r
            if ([string]::IsNullOrWhiteSpace($repo)) { Say "  FEHLER: leerer Pfad (Rohwert: '$r')"; continue }
            if (-not (Test-Path -LiteralPath $repo)) { Say "  (fehlt) $repo"; continue }
            $g = @('-c', 'safe.directory=*', '-C', $repo)
            $st = @(& git @g status --short 2>$null)
            $unp = @(& git @g log --branches --not --remotes --oneline 2>$null).Count
            if ($st.Count -eq 0 -and $unp -eq 0) { Say "  sauber: $repo" }
            else {
                Say ("  ACHTUNG: {0}  geaenderte Dateien: {1}, ungepushte Commits: {2}" -f $repo, $st.Count, $unp)
                $st | Select-Object -First 15 | ForEach-Object { Say ("      " + $_) }
            }
        }
    }
}

# ---------------------------------------------------------------- Ordner kopieren
Say ''
Say '--- Ordner ---'
$results = @()
foreach ($item in $cfg.Items) {
    $src = Resolve-BackupPath ([string]$item.Src)
    if ([string]::IsNullOrWhiteSpace($src)) { Say ("FEHLER: Quelle leer bei Eintrag '{0}' (Rohwert: '{1}') - uebersprungen" -f $item.Name, $item.Src); continue }
    $dst = Join-Path $Dest $item.Dest
    if (-not (Test-Path -LiteralPath $src)) { Say "UEBERSPRUNGEN (Quelle fehlt): $src"; continue }

    $ra = @($src, $dst)
    if ($item.Files) { foreach ($f in $item.Files) { $ra += $f } } else { $ra += '/E' }
    $ra += @('/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/FFT', '/XJ', '/NP', '/BYTES', '/NFL', '/NDL', '/NJH', '/MT:4')
    if ($item.XD -and $item.XD.Count -gt 0) { $ra += '/XD'; foreach ($d in $item.XD) { $ra += (Resolve-BackupPath $d) } }
    if ($item.XF -and $item.XF.Count -gt 0) { $ra += '/XF'; foreach ($f in $item.XF) { $ra += (Resolve-BackupPath $f) } }
    $ra += ('/UNILOG+:' + $roboLog)
    $ra += '/TEE'

    Say ''
    Say (">>> {0}  ({1})" -f $item.Name, $src)
    $first = $ra
    if (-not $Execute) { $first = $ra + '/L' }
    & robocopy @first
    $code = $LASTEXITCODE

    $verify = ''
    if ($Execute) {
        if ($code -lt 8) {
            & robocopy @ra '/L' | Out-Null
            $vcode = $LASTEXITCODE
            if ($vcode -eq 0) { $verify = 'OK' } else { $verify = "ABWEICHUNG (Code $vcode)" }
        } else { $verify = 'FEHLER beim Kopieren' }
    }
    $results += [PSCustomObject]@{ Name = $item.Name; Robocopy = $code; Pruefung = $verify; Quelle = $src }
}

Say ''
Say '--- Ergebnis (robocopy-Code: 0-7 = ok, >=8 = Fehler; im Trockenlauf 1 = "wuerde kopieren") ---'
Say ($results | Format-Table -AutoSize | Out-String -Width 200)

# ---------------------------------------------------------------- Secrets (verschluesselt)
if ($cfg.Secrets -and $cfg.Secrets.Count -gt 0) {
    Say ''
    Say '--- Secrets-Paket (7-Zip, AES-256, Dateinamen verschluesselt) ---'
    $paths = @()
    foreach ($p in $cfg.Secrets) {
        $e = Resolve-BackupPath $p
        if (Test-Path -Path $e) { $paths += $e; Say "  enthalten: $e" } else { Say "  nicht gefunden: $e" }
    }
    $sz = @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $Execute) { Say '  (Trockenlauf: Paket wird nicht erstellt)' }
    elseif (-not $sz) { Say '  7-Zip fehlt: "winget install 7zip.7zip" ausfuehren, dann dieses Skript erneut mit -Execute starten. Secrets sind NOCH NICHT gesichert!' }
    elseif ($paths.Count -eq 0) { Say '  nichts zu sichern' }
    else {
        $archive = Join-Path $logDir ("secrets_{0}.7z" -f $stamp)
        Write-Host 'Gleich fragt 7-Zip nach einem Passwort (zweimal). Passwort NICHT in diese Dateien schreiben, sondern in den Passwort-Manager / auf Papier.'
        & $sz a -t7z -mhe=on -p $archive @paths
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $archive)) {
            Copy-Item -LiteralPath $archive -Destination (Join-Path $Dest 'secrets.7z') -Force
            $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLower()
            Say "  secrets.7z auf Ziel kopiert. SHA256: $h"
            Say ('  Test ausserhalb dieses Skripts: 7z t secrets.7z (Passwort eingeben). Lokale Kopie: ' + $archive)
        } else { Say '  FEHLER beim Erstellen des Secrets-Pakets' }
    }
}

# ---------------------------------------------------------------- Manifest (nur -Execute)
if ($Execute) {
    Say ''
    Say '--- SHA256-Manifest (Quelle-Hash fuer jede am Ziel angekommene Datei) ---'
    $lines = New-Object System.Collections.Generic.List[string]
    $fails = 0
    foreach ($item in $cfg.Items) {
        $src = Resolve-BackupPath $item.Src
        $dst = Join-Path $Dest $item.Dest
        if (-not (Test-Path -LiteralPath $dst)) { continue }
        Write-Host ("Hash: " + $item.Name)
        Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($dst.Length).TrimStart('\')
            $srcFile = Join-Path $src $rel
            if (Test-Path -LiteralPath $srcFile) {
                try {
                    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $srcFile -ErrorAction Stop).Hash.ToLower()
                    $lines.Add(("{0}  {1}/{2}" -f $h, $item.Dest, ($rel -replace '\\', '/')))
                } catch { $fails++ }
            }
        }
    }
    $mf = Join-Path $Dest 'MANIFEST_sha256.txt'
    [IO.File]::WriteAllLines($mf, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Say ("  Manifest: {0}  Eintraege: {1}  nicht hashbar (z.B. gesperrt): {2}" -f $mf, $lines.Count, $fails)
    $info = @("Backup vom $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Rechner: $env:COMPUTERNAME", 'Pruefen auf dem Zielrechner im Ordner: sha256sum -c --quiet MANIFEST_sha256.txt')
    [IO.File]::WriteAllLines((Join-Path $Dest 'INFO.txt'), $info, (New-Object System.Text.UTF8Encoding($false)))
    Say '  Naechster Schritt (Pi, im Zielordner): sha256sum -c --quiet MANIFEST_sha256.txt   -> keine Ausgabe = alles identisch'
}

Say ''
Say 'FERTIG.'
Say "Bitte die Datei $sumLog an Claude geben (enthaelt Pfade, keine Passwoerter)."
