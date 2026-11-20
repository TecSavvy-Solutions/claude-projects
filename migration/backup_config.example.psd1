# backup_config.example.psd1 - Vorlage fuer windows_backup.ps1 (nur Beispielwerte!)
# Kopieren nach C:\Temp\backup_config.psd1 und anpassen. Die echte Config NICHT ins oeffentliche Repo legen.
# Dateiformat: PowerShell-Datenfile (nur Strings/Listen). %VARIABLEN% werden expandiert (z.B. %USERPROFILE%).
@{
    # Repos, die vor der Sicherung auf ungepushte Aenderungen geprueft werden
    GitRepos = @(
        'C:\projekte\mein-repo'
    )

    # Ordner: Name (nur Anzeige), Src (Quelle), Dest (Unterordner im Ziel),
    #         XD = ausgeschlossene Ordner (Name oder voller Pfad), XF = ausgeschlossene Dateien (Wildcards ok, nur ASCII),
    #         Files = nur diese Dateien aus Src kopieren (ohne Unterordner)
    Items = @(
        @{ Name = 'projekte'; Src = 'C:\projekte'; Dest = 'projekte'
           XD = @('node_modules', '__pycache__', '.venv'); XF = @('*.tmp') }
        @{ Name = 'home-dateien'; Src = '%USERPROFILE%'; Dest = 'home'; Files = @('.gitconfig') }
    )

    # Wird NICHT unverschluesselt kopiert, sondern in ein 7-Zip-Paket (AES-256) gepackt
    Secrets = @(
        '%USERPROFILE%\.ssh'
    )
}
