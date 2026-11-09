<#
Tests de scripts/envoyer-ads.ps1 (décision 018, lots A et B) contre un faux atlas (conteneur SSH), autovérifiés
(code 0 = tout est conforme).

Lancement, depuis le dossier du dépôt, Docker Desktop démarré :
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-EnvoyerAds.ps1

- Utilise les vrais ssh.exe, tar.exe et cmd.exe de Windows, et le vrai scripts/recevoir-ads.sh.
- Le faux atlas est publié sur 127.0.0.1:2222 le temps des tests, puis supprimé.
- Configuration SSH de test (-F) : la configuration SSH de l'utilisateur n'est ni lue ni modifiée.
  Le mot de passe de test est fourni par SSH_ASKPASS, pour ce test seulement.
- Fichiers de travail dans data\tests-envoi-ads\ (ignoré par Git), supprimés à la fin.
- Rapports envoyés : les deux rapports inventés de tests\fixtures\ads\.
- Scénario du double-clic : copie du script et du lanceur .cmd dans data\tests-envoi-ads\scripts\, avec un réglage
  local de test à côté, puis lancement du .cmd sans aucun paramètre. Le vrai réglage local
  (scripts\envoyer-ads.local.psd1) n'est jamais lu ni modifié.

Paramètre facultatif -ScriptEnvoi : version du script d'envoi à tester (par défaut, celle du dépôt),
pour les contre-épreuves.
#>
param([string]$ScriptEnvoi = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$depot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$racine = Join-Path $depot 'data\tests-envoi-ads'
$rapports = Join-Path $racine 'rapports'
$travail = Join-Path $racine 'travail'
$reglage = Join-Path $racine 'reglage.psd1'
$configSsh = Join-Path $racine 'ssh_config'
$envoi = if ($ScriptEnvoi) { (Resolve-Path -LiteralPath $ScriptEnvoi).Path } else { Join-Path $depot 'scripts\envoyer-ads.ps1' }
$fixtures = Join-Path $depot 'tests\fixtures\ads'
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
    # PC : dossier des rapports avec les rapports de test ; atlas : dossiers vides, codes d'ingestion et d'extraction
    if (Test-Path -LiteralPath $rapports) { Remove-Item -LiteralPath $rapports -Recurse -Force }
    New-Item -ItemType Directory -Path $rapports | Out-Null
    Copy-Item -Path (Join-Path $fixtures '*.csv') -Destination $rapports
    Invoke-Atlas ("rm -rf ~/recues ~/appels ~/books-data/ads/inbox/* ~/books-data/ads/attente/*; " +
                  "echo $codeIngestion > ~/code-ingestion; echo $codeExtraction > ~/code-extraction") | Out-Null
}

function Invoke-Envoi([string]$fichierReglage = $reglage, [string]$depotDistant = 'books', [string]$instant = '') {
    # -Instant n'est passé que s'il est fourni : PowerShell 5.1 perd les arguments vides transmis à un exécutable
    $options = @()
    if ($instant) { $options = @('-Instant', $instant) }
    $script:sortieEnvoi = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $envoi `
        -Reglages $fichierReglage -HoteSsh 'atlas-factice' -ConfigSsh $configSsh -DossierTravail $travail `
        -DepotDistant $depotDistant @options | Out-String
    return $LASTEXITCODE
}

function Get-Appels { Invoke-Atlas 'if [ -f ~/appels ]; then cat ~/appels; fi' }
function Get-Recues { Invoke-Atlas 'if [ -d ~/recues ]; then ls -d ~/recues; fi' }
function Get-Restants { @(Get-ChildItem -LiteralPath $rapports -File | ForEach-Object Name | Sort-Object) }
function Get-Ranges {
    # Mois d'envoi, en UTC (le test peut, au pire, chevaucher un changement de mois : ce dossier-ci ou le suivant)
    $envoyes = Join-Path $rapports 'envoyes'
    if (Test-Path -LiteralPath $envoyes) { @(Get-ChildItem -LiteralPath $envoyes -File -Recurse | ForEach-Object Name | Sort-Object) } else { @() }
}

$originaux = @{}
foreach ($f in Get-ChildItem -LiteralPath $fixtures -File -Filter '*.csv') {
    $originaux[$f.Name] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$nomsOriginaux = @($originaux.Keys | Sort-Object)
$nbFichiers = $nomsOriginaux.Count

# --- Préparation : dossiers, réglage, configuration SSH de test, faux atlas ----------------
if (Test-Path -LiteralPath $racine) { Remove-Item -LiteralPath $racine -Recurse -Force }
New-Item -ItemType Directory -Path $racine, $travail | Out-Null
[IO.File]::WriteAllText($reglage, "@{ DossierRapports = '$rapports' }`n")
$known = (Join-Path $racine 'known_hosts') -replace '\\', '/'
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

# Un conteneur de même nom resté d'un essai précédent est supprimé ; son absence n'est pas une erreur
if (& docker ps -a -q --filter "name=^$conteneur$") { & docker rm -f $conteneur | Out-Null }
& docker build -q -t books-atlas-factice -f (Join-Path $depot 'tests\atlas-factice\Dockerfile') (Join-Path $depot 'tests') | Out-Null
if ($LASTEXITCODE -ne 0) { throw "construction du faux atlas en échec (code $LASTEXITCODE)" }
& docker run -d --name $conteneur -p 127.0.0.1:2222:22 -v "$(Join-Path $depot 'scripts'):/home/arnaud/books/scripts:ro" books-atlas-factice | Out-Null
if ($LASTEXITCODE -ne 0) { throw "lancement du faux atlas en échec (code $LASTEXITCODE)" }
for ($i = 0; $i -lt 30; $i++) {
    try { $client = New-Object Net.Sockets.TcpClient('127.0.0.1', 2222); $client.Close(); break } catch { Start-Sleep -Milliseconds 500 }
}
Start-Sleep -Seconds 1

try {
    # 1. Transfert réussi, ingestion sans anomalie
    Reset-Scenario 0
    $code = Invoke-Envoi
    Test-Condition 'sans anomalie : code 0' ($code -eq 0)
    $envoyes = Join-Path $rapports 'envoyes'
    $dossiersMois = @(Get-ChildItem -LiteralPath $envoyes -Directory)
    $dossiersLot = @(Get-ChildItem -LiteralPath $envoyes -Directory -Recurse | Where-Object { $_.Parent.FullName -ne $envoyes })
    Test-Condition "sans anomalie : rapports rangés dans envoyes\AAAA-MM\{lot}\ (mois d'envoi, puis lot)" (
        ((Get-Ranges) -join ',') -eq ($nomsOriginaux -join ',') -and
        $dossiersMois.Count -eq 1 -and $dossiersMois[0].Name -match '^[0-9]{4}-[0-9]{2}$' -and
        $dossiersLot.Count -eq 1 -and $dossiersLot[0].Name -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$')
    Test-Condition 'sans anomalie : plus rien au premier niveau' (@(Get-Restants).Count -eq 0)
    $recues = @{}
    foreach ($ligne in (Invoke-Atlas 'cd ~/recues && sha256sum */*') -split "`n") {
        if ($ligne -match '^([0-9a-f]{64})  [^/]+/(.+)$') { $recues[$Matches[2]] = $Matches[1] }
    }
    $identiques = ($recues.Count -eq $originaux.Count)
    foreach ($nom in $originaux.Keys) { if ($recues[$nom] -ne $originaux[$nom]) { $identiques = $false } }
    Test-Condition "sans anomalie : octets reçus sur atlas identiques aux originaux ($nbFichiers fichiers, BOM et CRLF)" $identiques
    Test-Condition 'sans anomalie : attente/ vide sur atlas' ((Invoke-Atlas 'ls -A ~/books-data/ads/attente') -eq '')
    Test-Condition 'sans anomalie : dossier de travail supprimé' (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
    Test-Condition 'sans anomalie : ingestion puis extraction des rapports sur atlas' ((Get-Appels) -eq "ingestion-ads`nextraction-ads")
    Test-Condition 'sans anomalie : bilans affichés, « Ingestion sans anomalie », « Extraction sans anomalie »' (
        $sortieEnvoi -match 'Bilan factice de l.ingestion des rapports Ads' -and $sortieEnvoi -match 'Ingestion sans anomalie' -and
        $sortieEnvoi -match 'Bilan factice de l.extraction des rapports Ads' -and $sortieEnvoi -match 'Extraction sans anomalie')
    Test-Condition 'sans anomalie : captures non touchées sur atlas' ((Invoke-Atlas 'ls -A ~/books-data/captures/inbox') -eq '')

    # 2. Transfert réussi, ingestion avec anomalies (fichier invalid par exemple)
    Reset-Scenario 1
    $code = Invoke-Envoi
    Test-Condition 'avec anomalies : code 1' ($code -eq 1)
    Test-Condition 'avec anomalies : rapports rangés quand même' (@(Get-Ranges).Count -eq $nbFichiers -and @(Get-Restants).Count -eq 0)
    Test-Condition 'avec anomalies : message' ($sortieEnvoi -match 'Ingestion avec anomalies')

    # 3. Transfert réussi, ingestion non effectuée (configuration sur atlas)
    Reset-Scenario 2
    $code = Invoke-Envoi
    Test-Condition 'ingestion non effectuée : code 1' ($code -eq 1)
    Test-Condition 'ingestion non effectuée : rapports rangés, message' (
        @(Get-Ranges).Count -eq $nbFichiers -and $sortieEnvoi -match 'Ingestion non effectuée \(code 2\)')
    Test-Condition 'ingestion non effectuée : extraction lancée quand même' (
        (Get-Appels) -eq "ingestion-ads`nextraction-ads" -and $sortieEnvoi -match 'Extraction sans anomalie')

    # 3 bis. Ingestion sans anomalie, extraction en échec : le code final remonte
    Reset-Scenario 0 1
    $code = Invoke-Envoi
    Test-Condition 'extraction en échec : code 1, messages' (
        $code -eq 1 -and $sortieEnvoi -match 'Ingestion sans anomalie' -and $sortieEnvoi -match 'Extraction avec anomalies')

    # 3 ter. Extraction mal configurée sur atlas (code 2) : code 1 sur le PC, le code 2 restant réservé au PC
    Reset-Scenario 0 2
    $code = Invoke-Envoi
    Test-Condition 'extraction mal configurée sur atlas : code 1, message' (
        $code -eq 1 -and $sortieEnvoi -match 'configuration invalide sur atlas')

    # 3 quater. Repère d'extraction absent (atlas pas à jour) : code 1, jamais lu comme un succès
    Reset-Scenario 0
    Invoke-Atlas ('mkdir -p ~/sansextraction/scripts && grep -v "BOOKS:EXTRACTION:CODE" ~/books/scripts/recevoir-ads.sh ' +
                  '> ~/sansextraction/scripts/recevoir-ads.sh') | Out-Null
    $code = Invoke-Envoi $reglage 'sansextraction'
    Test-Condition 'repère d''extraction absent : code 1, message' (
        $sortieEnvoi -notmatch 'BOOKS:EXTRACTION' -and $code -eq 1 -and $sortieEnvoi -match 'Extraction non signalée par atlas')

    # 4. Repère d'ingestion absent : code 1, jamais lu comme un succès
    Reset-Scenario 0
    Invoke-Atlas ('mkdir -p ~/ancien/scripts && grep -v "BOOKS:INGESTION:CODE" ~/books/scripts/recevoir-ads.sh ' +
                  '> ~/ancien/scripts/recevoir-ads.sh') | Out-Null
    $code = Invoke-Envoi $reglage 'ancien'
    Test-Condition 'repère d''ingestion absent : repère bien absent de la réponse' ($sortieEnvoi -notmatch 'BOOKS:INGESTION')
    Test-Condition 'repère d''ingestion absent : code 1, message' ($code -eq 1 -and $sortieEnvoi -match 'Ingestion non signalée par atlas')

    # 5. Transfert échoué : rien n'est déplacé sur le PC
    Reset-Scenario 0
    Invoke-Atlas 'rmdir ~/books-data/ads/inbox' | Out-Null
    $code = Invoke-Envoi
    Test-Condition 'transfert échoué : code 3' ($code -eq 3)
    Test-Condition 'transfert échoué : rien déplacé sur le PC' (((Get-Restants) -join ',') -eq ($nomsOriginaux -join ',') -and @(Get-Ranges).Count -eq 0)
    Test-Condition 'transfert échoué : message d''atlas affiché, ingestion non lancée' (
        $sortieEnvoi -match 'BOOKS:TRANSFERT:ECHEC' -and (Get-Appels) -eq '')
    Invoke-Atlas 'mkdir -m 700 ~/books-data/ads/inbox' | Out-Null

    # 6. Mauvais mot de passe : transfert échoué, rien déplacé
    Reset-Scenario 0
    [IO.File]::WriteAllText($askpass, "@echo faux-mot-de-passe`r`n")
    $code = Invoke-Envoi
    Test-Condition 'mauvais mot de passe : code 3, rien déplacé' ($code -eq 3 -and @(Get-Restants).Count -eq $nbFichiers -and @(Get-Ranges).Count -eq 0)
    [IO.File]::WriteAllText($askpass, "@echo mot-de-passe-de-test`r`n")

    # 7. Second téléchargement de même nom (« (1) ») : envoyé ; noms hors format et fichier trop gros : signalés et
    #    laissés sur place, les autres partent
    Reset-Scenario 0
    $premier = $nomsOriginaux[0]
    $doublon = $premier -replace '\.csv$', ' (1).csv'
    $malForme = $premier -replace '\.csv$', ' (1a).csv'
    Copy-Item -LiteralPath (Join-Path $rapports $premier) -Destination (Join-Path $rapports $doublon)
    Copy-Item -LiteralPath (Join-Path $rapports $premier) -Destination (Join-Path $rapports $malForme)
    Copy-Item -LiteralPath (Join-Path $rapports $premier) -Destination (Join-Path $rapports 'rapport.txt')
    $gros = Join-Path $rapports 'gros_12_05_2026T19_59_56.csv'
    $flux = [IO.File]::Create($gros); try { $flux.SetLength(20MB + 1) } finally { $flux.Close() }
    $code = Invoke-Envoi
    Test-Condition 'suffixe et hors format : code 0' ($code -eq 0)
    $attendus = (@($malForme, 'rapport.txt', 'gros_12_05_2026T19_59_56.csv') | Sort-Object) -join ','
    Test-Condition 'suffixe et hors format : seuls les hors format restent sur place' ((@(Get-Restants) -join ',') -eq $attendus)
    Test-Condition 'suffixe et hors format : signalés' (
        $sortieEnvoi -match [regex]::Escape("$malForme : nom hors format") -and $sortieEnvoi -match 'rapport\.txt : nom hors format' -and
        $sortieEnvoi -match 'gros_12_05_2026T19_59_56\.csv : plus de 20 Mo' -and $sortieEnvoi -notmatch [regex]::Escape("$doublon : "))
    Test-Condition 'suffixe et hors format : « (1) » envoyé et rangé avec les rapports conformes' (
        ((Get-Ranges) -join ',') -eq ((@($nomsOriginaux) + $doublon | Sort-Object) -join ','))
    $recuDoublon = Invoke-Atlas "cd ~/recues && sha256sum */'$doublon' | cut -c1-64"
    Test-Condition 'suffixe et hors format : octets du « (1) » identiques sur atlas' ($recuDoublon -eq $originaux[$premier])

    # 8. Rien à envoyer : aucune connexion
    Reset-Scenario 0
    Get-ChildItem -LiteralPath $rapports -File | Rename-Item -NewName { $_.Name -replace '\.csv$', '.txt' }
    $code = Invoke-Envoi
    Test-Condition 'rien à envoyer : code 0, aucun lot arrivé sur atlas' ($code -eq 0 -and (Get-Recues) -eq '' -and
        (Invoke-Atlas 'ls -A ~/books-data/ads/inbox ~/books-data/ads/attente') -notmatch '20')
    Test-Condition 'rien à envoyer : message' ($sortieEnvoi -match 'Aucun rapport à envoyer')

    # 9. Deux livraisons de même nom, envoyées l'une après l'autre : rangées dans deux lots, sans blocage
    #    (un rapport programmé garde le même nom à chaque livraison)
    Reset-Scenario 0
    $code1 = Invoke-Envoi
    Copy-Item -Path (Join-Path $fixtures '*.csv') -Destination $rapports
    # Le nom de lot est à la seconde près : deux envois dans la même seconde auraient le même lot, et le second serait
    # refusé par le contrôle « déjà présent » (code 2, rien envoyé). On attend donc la seconde suivante.
    $lotPrecedent = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    while ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') -eq $lotPrecedent) { Start-Sleep -Milliseconds 100 }
    $code2 = Invoke-Envoi
    $lots = @(Get-ChildItem -LiteralPath (Join-Path $rapports 'envoyes') -Directory -Recurse |
              Where-Object { $_.Name -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$' })
    Test-Condition 'deux livraisons de même nom : codes 0 et 0, deux lots, aucun fichier restant' (
        $code1 -eq 0 -and $code2 -eq 0 -and $lots.Count -eq 2 -and @(Get-Ranges).Count -eq 2 * $nbFichiers -and
        @(Get-Restants).Count -eq 0)

    # 9 bis. Deux envois forcés au même instant, donc au même nom de lot : le second est refusé par le contrôle
    #        « déjà présent » (code 2), sans connexion, sans rien envoyer ni déplacer. Preuve déterministe du cas que
    #        le test 9 évite en attendant la seconde suivante.
    Reset-Scenario 0
    $instantImpose = '2026-11-09T10:00:00Z'
    $dossierLot = Join-Path $rapports 'envoyes\2026-11\2026-11-09T100000Z'
    $code1 = Invoke-Envoi -instant $instantImpose
    Test-Condition 'même lot : premier envoi, code 0, rangé dans le lot de l''instant imposé' (
        $code1 -eq 0 -and @(Get-ChildItem -LiteralPath $dossierLot -File).Count -eq $nbFichiers -and @(Get-Restants).Count -eq 0)
    $etatAtlas = { Invoke-Atlas 'cd ~ && { cat appels 2>&1; ls -AR recues books-data/ads/inbox books-data/ads/attente 2>&1; } | sha256sum' }
    $atlasAvant = & $etatAtlas
    $rangesAvant = @(Get-ChildItem -LiteralPath (Join-Path $rapports 'envoyes') -File -Recurse |
                     ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join ','
    Copy-Item -Path (Join-Path $fixtures '*.csv') -Destination $rapports
    $code2 = Invoke-Envoi -instant $instantImpose
    $rangesApres = @(Get-ChildItem -LiteralPath (Join-Path $rapports 'envoyes') -File -Recurse |
                     ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join ','
    Test-Condition 'même lot : second envoi refusé, code 2, motif « déjà présent »' (
        $code2 -eq 2 -and $sortieEnvoi -match 'Déjà présent dans envoyes' -and $sortieEnvoi -notmatch 'Envoi du lot')
    Test-Condition 'même lot : rien envoyé (atlas inchangé)' ((& $etatAtlas) -eq $atlasAvant)
    Test-Condition 'même lot : rien déplacé (rapports sur place, envoyes\ intact, dossier de travail vide)' (
        ((Get-Restants) -join ',') -eq ($nomsOriginaux -join ',') -and $rangesApres -eq $rangesAvant -and
        @(Get-ChildItem -LiteralPath $travail).Count -eq 0)
    $code = Invoke-Envoi -instant '2026-11-09 10:00:00'
    Test-Condition 'instant mal formé : code 2, rien envoyé' ($code -eq 2 -and $sortieEnvoi -match 'Instant invalide' -and
        (& $etatAtlas) -eq $atlasAvant)

    # 10. Réglage local absent ; clé inconnue (faute de frappe) refusée, pas ignorée
    $code = Invoke-Envoi (Join-Path $racine 'absent.psd1')
    Test-Condition 'réglage absent : code 2' ($code -eq 2)
    $faute = Join-Path $racine 'faute.psd1'
    [IO.File]::WriteAllText($faute, "@{ DossierRapports = '$rapports'; DossierCaptures = 'x' }`n")
    Reset-Scenario 0
    $code = Invoke-Envoi $faute
    Test-Condition 'clé inconnue dans le réglage : code 2, rien envoyé' ($code -eq 2 -and (Get-Recues) -eq '')

    # 11. Lancement exactement comme l'utilisateur : double-clic sur le .cmd, sans aucun paramètre
    Reset-Scenario 0
    $copie = Join-Path $racine 'scripts'
    New-Item -ItemType Directory -Path $copie -Force | Out-Null
    Copy-Item -LiteralPath $envoi -Destination (Join-Path $copie 'envoyer-ads.ps1')
    Copy-Item -LiteralPath (Join-Path $depot 'scripts\envoyer-ads.cmd') -Destination $copie
    [IO.File]::WriteAllText((Join-Path $copie 'envoyer-ads.local.psd1'),
        "@{ DossierRapports = '$rapports'; ConfigSsh = '$configSsh' }`n")
    $doubleClic = Join-Path $racine 'double-clic.cmd'
    [IO.File]::WriteAllText($doubleClic, "@echo off`r`necho.| call `"$(Join-Path $copie 'envoyer-ads.cmd')`" 2>&1`r`nexit /b %ERRORLEVEL%`r`n")
    $tempAvant = $env:TEMP
    $env:TEMP = $travail
    try {
        $script:sortieEnvoi = & cmd.exe /d /c $doubleClic | Out-String
        $code = $LASTEXITCODE
    } finally {
        $env:TEMP = $tempAvant
    }
    Test-Condition 'double-clic sans paramètre : pas d''erreur de lancement' ($sortieEnvoi -notmatch 'Join-Path|Impossible de lier')
    Test-Condition 'double-clic sans paramètre : code 0, rapports rangés' ($code -eq 0 -and @(Get-Ranges).Count -eq $nbFichiers -and @(Get-Restants).Count -eq 0)
    Test-Condition 'double-clic sans paramètre : dossier de travail vidé' (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
}
finally {
    & docker rm -f $conteneur | Out-Null
    Remove-Item Env:\SSH_ASKPASS, Env:\SSH_ASKPASS_REQUIRE
    Remove-Item -LiteralPath $racine -Recurse -Force
}

Write-Host '---'
if ($echecs -eq 0) { Write-Host 'Tous les tests sont conformes.' } else { Write-Host "$echecs échec(s)." }
exit ([int]($echecs -gt 0))
