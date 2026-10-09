<#
Tests de scripts/envoyer-captures.ps1 contre un faux atlas (conteneur SSH), autovérifiés (code 0 = tout est conforme).

Lancement, depuis le dossier du dépôt, Docker Desktop démarré :
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-EnvoyerCaptures.ps1

- Utilise les vrais ssh.exe, tar.exe et cmd.exe de Windows, et le vrai scripts/recevoir-captures.sh.
- Le faux atlas est publié sur 127.0.0.1:2222 le temps des tests, puis supprimé.
- Configuration SSH de test (-F) : la configuration SSH de l'utilisateur n'est ni lue ni modifiée.
  Le mot de passe de test est fourni par SSH_ASKPASS, pour ce test seulement.
- Fichiers de travail dans data\tests-envoi\ (ignoré par Git), supprimés à la fin.
- Captures envoyées : les captures de test inventées de tests\fixtures\captures\.
- Scénario du double-clic : copie du script et du lanceur .cmd dans data\tests-envoi\scripts\, avec un réglage
  local de test à côté, puis lancement du .cmd sans aucun paramètre (valeurs par défaut). Le réglage désigne
  une configuration SSH de test où l'alias « atlas » mène au faux atlas ; TEMP est redirigé dans data\.
  Le vrai réglage local (scripts\envoyer-captures.local.psd1) n'est jamais lu ni modifié.

Paramètre facultatif -ScriptEnvoi : version du script d'envoi à tester (par défaut, celle du dépôt),
pour les contre-épreuves.
#>
param([string]$ScriptEnvoi = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$depot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$racine = Join-Path $depot 'data\tests-envoi'
$captures = Join-Path $racine 'captures'
$travail = Join-Path $racine 'travail'
$reglage = Join-Path $racine 'reglage.psd1'
$configSsh = Join-Path $racine 'ssh_config'
# Chemin par défaut calculé ici, et non dans param() : sous PowerShell 5.1, $PSScriptRoot y est vide
$envoi = if ($ScriptEnvoi) { (Resolve-Path -LiteralPath $ScriptEnvoi).Path } else { Join-Path $depot 'scripts\envoyer-captures.ps1' }
$fixtures = Join-Path $depot 'tests\fixtures\captures'
$conteneur = 'books-atlas-factice'
$echecs = 0

function Test-Condition([string]$libelle, [bool]$condition) {
    if ($condition) { Write-Host "OK    $libelle" } else { Write-Host "ÉCHEC $libelle"; $script:echecs++ }
}

function Invoke-Atlas([string]$commande) {
    # Commande sur le faux atlas, en tant qu'arnaud ; renvoie la sortie
    $sortie = & docker exec -u arnaud $conteneur sh -c $commande
    return ($sortie -join "`n")
}

function Reset-Scenario([int]$codeIngestion, [int]$codeExtraction = 0) {
    # PC : dossier des captures avec les 5 paires de test ; atlas : dossiers vides, codes d'ingestion et d'extraction
    Remove-Item -LiteralPath $captures -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $captures | Out-Null
    Copy-Item -Path (Join-Path $fixtures '*') -Destination $captures
    Invoke-Atlas ("rm -rf ~/recues ~/appels ~/books-data/captures/inbox/* ~/books-data/captures/attente/*; " +
                  "echo $codeIngestion > ~/code-ingestion; echo $codeExtraction > ~/code-extraction") | Out-Null
}

function Invoke-Envoi([string]$fichierReglage = $reglage, [string]$depotDistant = 'books') {
    $script:sortieEnvoi = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $envoi `
        -Reglages $fichierReglage -HoteSsh 'atlas-factice' -ConfigSsh $configSsh -DossierTravail $travail `
        -DepotDistant $depotDistant | Out-String
    return $LASTEXITCODE
}

function Get-Appels { Invoke-Atlas 'cat ~/appels 2>/dev/null' }

function Get-Restants { @(Get-ChildItem -LiteralPath $captures -File | ForEach-Object Name | Sort-Object) }
function Get-Ranges {
    $mois = Join-Path $captures 'envoyees\2026-10'
    if (Test-Path -LiteralPath $mois) { @(Get-ChildItem -LiteralPath $mois -File | ForEach-Object Name | Sort-Object) } else { @() }
}

$originaux = @{}
foreach ($f in Get-ChildItem -LiteralPath $fixtures -File) {
    $originaux[$f.Name] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$nomsOriginaux = @($originaux.Keys | Sort-Object)

# --- Préparation : dossiers, réglage, configuration SSH de test, faux atlas ----------------
Remove-Item -LiteralPath $racine -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $racine, $travail | Out-Null
[IO.File]::WriteAllText($reglage, "@{ DossierCaptures = '$captures' }`n")
$known = (Join-Path $racine 'known_hosts') -replace '\\', '/'
# Deux alias pour le faux atlas : « atlas-factice » (paramètre explicite) et « atlas » (valeur par défaut du script)
[IO.File]::WriteAllText($configSsh, @"
Host atlas-factice atlas
    HostName 127.0.0.1
    Port 2222
    User arnaud
    StrictHostKeyChecking no
    UserKnownHostsFile "$known"
    PubkeyAuthentication no
    PreferredAuthentications password
    NumberOfPasswordPrompts 1
"@)
$askpass = Join-Path $racine 'askpass.cmd'
[IO.File]::WriteAllText($askpass, "@echo mot-de-passe-de-test`r`n")
$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = 'force'

& docker rm -f $conteneur 2>$null | Out-Null
& docker build -q -t books-atlas-factice -f (Join-Path $depot 'tests\atlas-factice\Dockerfile') (Join-Path $depot 'tests') | Out-Null
& docker run -d --name $conteneur -p 127.0.0.1:2222:22 -v "$(Join-Path $depot 'scripts'):/home/arnaud/books/scripts:ro" books-atlas-factice | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    try { $client = New-Object Net.Sockets.TcpClient('127.0.0.1', 2222); $client.Close(); break } catch { Start-Sleep -Milliseconds 500 }
}
Start-Sleep -Seconds 1

try {
    # 1. Transfert réussi, ingestion sans anomalie
    Reset-Scenario 0
    $code = Invoke-Envoi
    Test-Condition 'sans anomalie : code 0' ($code -eq 0)
    Test-Condition 'sans anomalie : toutes les captures rangées dans envoyees\2026-10' (((Get-Ranges) -join ',') -eq ($nomsOriginaux -join ','))
    Test-Condition 'sans anomalie : plus rien au premier niveau' (@(Get-Restants).Count -eq 0)
    $recues = @{}
    foreach ($ligne in (Invoke-Atlas 'cd ~/recues && sha256sum */*') -split "`n") {
        if ($ligne -match '^([0-9a-f]{64})  [^/]+/(.+)$') { $recues[$Matches[2]] = $Matches[1] }
    }
    $identiques = ($recues.Count -eq $originaux.Count)
    foreach ($nom in $originaux.Keys) { if ($recues[$nom] -ne $originaux[$nom]) { $identiques = $false } }
    Test-Condition 'sans anomalie : octets reçus sur atlas identiques aux originaux (10 fichiers)' $identiques
    Test-Condition 'sans anomalie : attente/ vide sur atlas' ((Invoke-Atlas 'ls -A ~/books-data/captures/attente') -eq '')
    Test-Condition 'sans anomalie : dossier de travail supprimé' (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
    Test-Condition 'sans anomalie : ingestion puis extraction sur atlas (décision 012)' ((Get-Appels) -eq "ingestion`nextraction")
    Test-Condition 'sans anomalie : bilan de l''extraction affiché, « Extraction sans anomalie »' (
        $sortieEnvoi -match 'Bilan factice de l.extraction' -and $sortieEnvoi -match 'Extraction sans anomalie')

    # 2. Transfert réussi, ingestion avec anomalies
    Reset-Scenario 1
    $code = Invoke-Envoi
    Test-Condition 'avec anomalies : code 1' ($code -eq 1)
    Test-Condition 'avec anomalies : captures rangées quand même' (@(Get-Ranges).Count -eq 10 -and @(Get-Restants).Count -eq 0)

    # 3. Transfert réussi, ingestion non effectuée (configuration sur atlas)
    Reset-Scenario 2
    $code = Invoke-Envoi
    Test-Condition 'ingestion non effectuée : code 1' ($code -eq 1)
    Test-Condition 'ingestion non effectuée : captures rangées' (@(Get-Ranges).Count -eq 10)
    Test-Condition 'ingestion non effectuée : extraction lancée quand même, sans anomalie' (
        (Get-Appels) -eq "ingestion`nextraction" -and $sortieEnvoi -match 'Extraction sans anomalie')

    # 3 bis. Ingestion sans anomalie, extraction en échec : le code final remonte (le plus grave l'emporte)
    Reset-Scenario 0 1
    $code = Invoke-Envoi
    Test-Condition 'extraction en échec : code 1' ($code -eq 1)
    Test-Condition 'extraction en échec : message' ($sortieEnvoi -match 'Ingestion sans anomalie' -and $sortieEnvoi -match 'Extraction avec anomalies')
    Test-Condition 'extraction en échec : captures rangées quand même' (@(Get-Ranges).Count -eq 10)

    # 3 ter. Configuration invalide de l'extracteur sur atlas (code 2) : code 1 sur le PC, le code 2 restant réservé au PC
    Reset-Scenario 0 2
    $code = Invoke-Envoi
    Test-Condition 'extraction mal configurée sur atlas : code 1' ($code -eq 1)
    Test-Condition 'extraction mal configurée sur atlas : message' ($sortieEnvoi -match 'configuration invalide sur atlas')

    # 3 quater. Repère d'extraction absent (atlas pas à jour) : code 1, jamais lu comme un succès
    Reset-Scenario 0 0
    Invoke-Atlas ('mkdir -p ~/ancien/scripts && grep -v "BOOKS:EXTRACTION:CODE" ~/books/scripts/recevoir-captures.sh ' +
                  '> ~/ancien/scripts/recevoir-captures.sh') | Out-Null
    $code = Invoke-Envoi $reglage 'ancien'
    Test-Condition 'repère d''extraction absent : repère bien absent de la réponse' ($sortieEnvoi -notmatch 'BOOKS:EXTRACTION')
    Test-Condition 'repère d''extraction absent : code 1' ($code -eq 1)
    Test-Condition 'repère d''extraction absent : message' ($sortieEnvoi -match 'Extraction non signalée par atlas')

    # 4. Transfert échoué : rien n'est déplacé sur le PC
    Reset-Scenario 0
    Invoke-Atlas 'rmdir ~/books-data/captures/inbox' | Out-Null
    $code = Invoke-Envoi
    Test-Condition 'transfert échoué : code 3' ($code -eq 3)
    Test-Condition 'transfert échoué : rien déplacé sur le PC' (((Get-Restants) -join ',') -eq ($nomsOriginaux -join ',') -and @(Get-Ranges).Count -eq 0)
    Test-Condition 'transfert échoué : message de atlas affiché' ($sortieEnvoi -match 'BOOKS:TRANSFERT:ECHEC')
    Test-Condition 'transfert échoué : ni ingestion ni extraction lancées' ((Get-Appels) -eq '' -and $sortieEnvoi -notmatch 'BOOKS:EXTRACTION')
    Invoke-Atlas 'mkdir -m 700 ~/books-data/captures/inbox' | Out-Null

    # 5. Mauvais mot de passe : transfert échoué, rien déplacé
    Reset-Scenario 0
    [IO.File]::WriteAllText($askpass, "@echo faux-mot-de-passe`r`n")
    $code = Invoke-Envoi
    Test-Condition 'mauvais mot de passe : code 3' ($code -eq 3)
    Test-Condition 'mauvais mot de passe : rien déplacé' (@(Get-Restants).Count -eq 10 -and @(Get-Ranges).Count -eq 0)
    [IO.File]::WriteAllText($askpass, "@echo mot-de-passe-de-test`r`n")

    # 6. Orphelin et fichier hors format : signalés et laissés sur place, les paires partent
    Reset-Scenario 0
    $premier = $nomsOriginaux | Where-Object { $_ -like '*.html' } | Select-Object -First 1
    $orphelin = $premier -replace 'T[0-9]{6}Z', 'T235959Z'  # même capture, autre horodatage, sans JSON
    Copy-Item -LiteralPath (Join-Path $captures $premier) -Destination (Join-Path $captures $orphelin)
    Copy-Item -LiteralPath (Join-Path $captures $premier) -Destination (Join-Path $captures ($premier -replace '\.html$', ' (1).html'))
    $code = Invoke-Envoi
    Test-Condition 'orphelin et hors format : code 0' ($code -eq 0)
    $attendus = (@($orphelin, ($premier -replace '\.html$', ' (1).html')) | Sort-Object) -join ','
    Test-Condition 'orphelin et hors format : laissés sur place' ((@(Get-Restants) -join ',') -eq $attendus)
    Test-Condition 'orphelin et hors format : les 5 paires rangées' (@(Get-Ranges).Count -eq 10)

    # 7. Rien à envoyer : aucune connexion
    Reset-Scenario 0
    Get-ChildItem -LiteralPath $captures -File -Filter '*.json' | Remove-Item
    $code = Invoke-Envoi
    Test-Condition 'rien à envoyer : code 0' ($code -eq 0)
    Test-Condition 'rien à envoyer : aucun lot arrivé sur atlas' ((Invoke-Atlas 'ls -A ~/books-data/captures/inbox ~/books-data/captures/attente; ls -d ~/recues 2>/dev/null') -notmatch '20')
    Test-Condition 'rien à envoyer : les HTML restent sur place' (@(Get-Restants).Count -eq 5)

    # 8. Collision dans envoyees\ : rien envoyé, rien déplacé, fichier existant intact
    Reset-Scenario 0
    $mois = Join-Path $captures 'envoyees\2026-10'
    New-Item -ItemType Directory -Path $mois | Out-Null
    [IO.File]::WriteAllText((Join-Path $mois $premier), 'deja la')
    $code = Invoke-Envoi
    Test-Condition 'collision dans envoyees : code 2' ($code -eq 2)
    Test-Condition 'collision dans envoyees : rien envoyé' ((Invoke-Atlas 'ls -d ~/recues 2>/dev/null') -eq '')
    Test-Condition 'collision dans envoyees : rien déplacé, fichier existant intact' (@(Get-Restants).Count -eq 10 -and [IO.File]::ReadAllText((Join-Path $mois $premier)) -eq 'deja la')

    # 9. Réglage local absent
    $code = Invoke-Envoi (Join-Path $racine 'absent.psd1')
    Test-Condition 'réglage absent : code 2' ($code -eq 2)

    # 10. Clé inconnue dans le réglage local (faute de frappe) : refusée, pas ignorée
    $faute = Join-Path $racine 'faute.psd1'
    [IO.File]::WriteAllText($faute, "@{ DossierCaptures = '$captures'; DossierCapture = 'x' }`n")
    Reset-Scenario 0
    $code = Invoke-Envoi $faute
    Test-Condition 'clé inconnue dans le réglage : code 2' ($code -eq 2)
    Test-Condition 'clé inconnue dans le réglage : rien envoyé' ((Invoke-Atlas 'ls -d ~/recues 2>/dev/null') -eq '')

    # 11. Lancement exactement comme l'utilisateur : double-clic sur le .cmd, sans aucun paramètre
    Reset-Scenario 0
    $copie = Join-Path $racine 'scripts'
    New-Item -ItemType Directory -Path $copie -Force | Out-Null
    Copy-Item -LiteralPath $envoi -Destination (Join-Path $copie 'envoyer-captures.ps1')
    Copy-Item -LiteralPath (Join-Path $depot 'scripts\envoyer-captures.cmd') -Destination $copie
    [IO.File]::WriteAllText((Join-Path $copie 'envoyer-captures.local.psd1'),
        "@{ DossierCaptures = '$captures'; ConfigSsh = '$configSsh' }`n")
    # La touche attendue par « pause » est fournie par « echo. » ; lanceur intermédiaire sans espace dans le chemin.
    # 2>&1 dans cmd.exe : les erreurs de lancement (sortie d'erreur) sont capturées avec la sortie normale.
    $doubleClic = Join-Path $racine 'double-clic.cmd'
    [IO.File]::WriteAllText($doubleClic, "@echo off`r`necho.| call `"$(Join-Path $copie 'envoyer-captures.cmd')`" 2>&1`r`nexit /b %ERRORLEVEL%`r`n")
    $tempAvant = $env:TEMP
    $env:TEMP = $travail  # valeur par défaut du dossier de travail (TEMP), sans écrire hors du dépôt
    try {
        $script:sortieEnvoi = & cmd.exe /d /c $doubleClic | Out-String
        $code = $LASTEXITCODE
    } finally {
        $env:TEMP = $tempAvant
    }
    Test-Condition 'double-clic sans paramètre : pas d''erreur de lancement' ($sortieEnvoi -notmatch 'Join-Path|Impossible de lier')
    Test-Condition 'double-clic sans paramètre : code 0' ($code -eq 0)
    Test-Condition 'double-clic sans paramètre : captures rangées' (@(Get-Ranges).Count -eq 10 -and @(Get-Restants).Count -eq 0)
    Test-Condition 'double-clic sans paramètre : dossier de travail vidé' (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
}
finally {
    & docker rm -f $conteneur | Out-Null
    Remove-Item Env:\SSH_ASKPASS, Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $racine -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '---'
if ($echecs -eq 0) { Write-Host 'Tous les tests sont conformes.' } else { Write-Host "$echecs échec(s)." }
exit ([int]($echecs -gt 0))
