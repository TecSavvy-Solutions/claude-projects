# Migration Windows 10 → Linux Mint – Phase 0 (Inventur)

Zwei **read-only** Skripte. Sie ändern nichts, sie lesen nur Namen, Größen, Pfade, Versionen.

| Skript | Läuft auf | Ausgabe |
|---|---|---|
| `windows_inventur.ps1` | Windows-Laptop | `Desktop\inventur_<PC>_<Datum>.txt` |
| `pi_inventur.sh` | Raspberry Pi | `~/pi_inventur_<Datum>.txt` |

## 1. Windows-Laptop
1. Datei herunterladen (z. B. Rechtsklick auf *Raw* → Speichern unter) nach `C:\Temp\`.
2. PowerShell (normal, Admin nur für BitLocker-Status nötig):
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Temp\windows_inventur.ps1
   ```
3. Dauer: einige Minuten (AppData/Profil wird gezählt).

## 2. Pi
```bash
ssh tecsavvy@100.121.250.36
bash pi_inventur.sh        # Datei vorher per scp/Browser auf den Pi legen
```
Secrets (`PASSWORD`, `TOKEN`, `SECRET`, `KEY`, …) werden als `***REDACTED***` ausgegeben. Gelesen werden **nicht**: `token.txt`, `.env`, Nextcloud-Daten, Datenbanken.

## 3. Ergebnis weitergeben
- **Nicht in dieses Repo committen** – `claude-projects` ist **öffentlich**, die Ausgaben enthalten Ordner- und Dateinamen (z. B. Karriere-Unterlagen).
- Datei vorher kurz überfliegen. Dann entweder Inhalt in die Session einfügen oder in das **private** Repo `homelab-server` legen (Ordner `migration/inventur/`).

## Was nicht erfasst wird
Dateiinhalte, Passwörter, Tokens, SSH-/Browser-/Passwort-Manager-Inhalte (nur Existenz/Größe), Werte von Umgebungsvariablen außer `PATH`/`PYTHON*`, MCP-`env`/`headers`.

## Danach
Aus der Ausgabe entstehen: Backup-Liste (Git-sauber vs. nur lokal), Software-Mapping Windows → Linux, Pi-Konfiguration im Repo (ohne Secrets). Siehe Plan, Phasen 1–5.

---

# Phase 1 – Sicherung (`windows_backup.ps1`)

Kopiert Ordner per `robocopy` auf ein Ziel (z. B. Samba-Freigabe), erstellt ein SHA256-Manifest und packt Secrets in ein verschlüsseltes 7-Zip-Paket.

- **Quelle wird nie verändert oder gelöscht.**
- **Standard = Trockenlauf** (zeigt nur Dateizahl/Bytes je Ordner). Kopiert wird erst mit `-Execute`.
- Ordnerliste liegt in einer **lokalen** Config (`backup_config.psd1`, Vorlage `backup_config.example.psd1`) – die echte Config nicht in dieses öffentliche Repo legen.

```powershell
# 1. Trockenlauf
powershell -ExecutionPolicy Bypass -File C:\Temp\windows_backup.ps1 -Config C:\Temp\backup_config.psd1 -Dest "\\HOST\SHARE\ZIELORDNER"
# 2. Kopieren (erst wenn Trockenlauf plausibel und Platz am Ziel ausreicht)
powershell -ExecutionPolicy Bypass -File C:\Temp\windows_backup.ps1 -Config C:\Temp\backup_config.psd1 -Dest "\\HOST\SHARE\ZIELORDNER" -Execute
```

Prüfung nach dem Kopieren (auf dem Zielrechner, im Zielordner):
```bash
sha256sum -c --quiet MANIFEST_sha256.txt   # keine Ausgabe = alles identisch
```
Logs: `C:\Temp\backup_summary_*.txt` (Zusammenfassung) und `C:\Temp\backup_robocopy_*.log`.
