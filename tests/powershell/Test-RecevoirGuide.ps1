<#
Tests de scripts/recevoir-guide.ps1 contre un faux atlas (conteneur SSH), autovérifiés (code 0 = tout est conforme).

Lancement, depuis le dossier du dépôt, Docker Desktop démarré :
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-RecevoirGuide.ps1

- Utilise les vrais ssh.exe, tar.exe et cmd.exe de Windows, et le vrai scripts/exporter-guide.sh, avec un faux
  PostgreSQL (tests/shell/faux-docker) qui rend le document de l'exemple du contrat (tests/fixtures/guide_exemple.json,
  valeurs inventées), mis sur une ligne comme le rend psql.
- Refus : des exports volontairement défectueux (tests/shell/faux-export-guide.sh) sont appelés par le même point
  d'entrée, en désignant un autre dépôt distant (-DepotDistant variantes/{mode}).
- Le faux atlas est publié sur 127.0.0.1:2222 le temps des tests, puis supprimé.
- Configuration SSH de test (-F) : la configuration SSH de l'utilisateur n'est ni lue ni modifiée.
  Le mot de passe de test est fourni par SSH_ASKPASS, pour ce test seulement.
- Fichiers de travail dans data\tests-guide\ (ignoré par Git), supprimés à la fin.
- Scénario du double-clic : copie du script et du lanceur .cmd dans data\tests-guide\scripts\, avec un réglage local de
  test à côté, puis lancement du .cmd sans aucun paramètre. Le vrai réglage local n'est jamais lu ni modifié.

Paramètre facultatif -ScriptReception : version du script à tester (par défaut, celle du dépôt), pour les contre-épreuves.
#>
param([string]$ScriptReception = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$depot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$racine = Join-Path $depot 'data\tests-guide'
$guides = Join-Path $racine 'guides'
$travail = Join-Path $racine 'travail'
$reglage = Join-Path $racine 'reglage.psd1'
$configSsh = Join-Path $racine 'ssh_config'
$fauxGuide = Join-Path $racine 'faux-guide'
# Chemin par défaut calculé ici, et non dans param() : sous PowerShell 5.1, $PSScriptRoot y est vide
$reception = if ($ScriptReception) { (Resolve-Path -LiteralPath $ScriptReception).Path } else { Join-Path $depot 'scripts\recevoir-guide.ps1' }
$conteneur = 'books-atlas-factice'
$NomGuide = '^guide_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.json$'
$echecs = 0

function Test-Condition([string]$libelle, [bool]$condition) {
    if ($condition) { Write-Host "OK    $libelle" } else { Write-Host "ÉCHEC $libelle"; $script:echecs++ }
}

function Invoke-Atlas([string]$commande) {
    # Commande sur le faux atlas, en tant qu'arnaud ; renvoie la sortie
    $sortie = & docker exec -u arnaud $conteneur sh -c $commande
    return ($sortie -join "`n")
}

function Invoke-Reception([string]$depotDistant = 'books', [string]$fichierReglage = $reglage) {
    $script:sortieReception = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reception `
        -Reglages $fichierReglage -HoteSsh 'atlas-factice' -ConfigSsh $configSsh -DepotDistant $depotDistant `
        -DossierTravail $travail | Out-String
    return $LASTEXITCODE
}

function Get-Contenu { @(Get-ChildItem -LiteralPath $guides -File | ForEach-Object Name | Sort-Object) }
function Get-Empreinte([string]$chemin) { (Get-FileHash -LiteralPath $chemin -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-AtlasPropre { (Invoke-Atlas 'find /tmp -mindepth 1 -maxdepth 1 -user arnaud') -eq '' }

function Set-FauxGuide([string]$dateExport) {
    # Document de l'exemple du contrat, sur une ligne, avec la date d'export donnée ; copié sur le faux atlas
    $texte = [IO.File]::ReadAllText((Join-Path $depot 'tests\fixtures\guide_exemple.json'), (New-Object System.Text.UTF8Encoding $false))
    $texte = ($texte -replace "`r?`n", '') -replace '"generated_at": "[^"]*"', "`"generated_at`": `"$dateExport`""
    [IO.File]::WriteAllBytes($fauxGuide, (New-Object System.Text.UTF8Encoding $false).GetBytes("$texte`n"))
    & docker cp $fauxGuide "${conteneur}:/home/arnaud/faux-guide" | Out-Null
    & docker exec $conteneur chown arnaud:arnaud /home/arnaud/faux-guide | Out-Null
    return (Get-Empreinte $fauxGuide)
}

function Test-Refus([string]$libelle, [int]$code, [string]$motif) {
    # Refus : code 1, dossier du guide inchangé, motif affiché, dossier de travail vidé
    Test-Condition "$libelle : code 1" ($code -eq 1)
    Test-Condition "$libelle : dossier du guide inchangé" (((Get-Contenu) -join ',') -eq ($script:avant -join ','))
    Test-Condition "$libelle : motif affiché" ($sortieReception -match $motif)
    Test-Condition "$libelle : dossier de travail vidé" (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
}

# --- Préparation : dossiers, réglage, configuration SSH de test, faux atlas -------------------
Remove-Item -LiteralPath $racine -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $racine, $guides, $travail | Out-Null
[IO.File]::WriteAllText($reglage, "@{ DossierGuide = '$guides' }`n")
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
& docker run -d --name $conteneur -p 127.0.0.1:2222:22 `
    -v "$(Join-Path $depot 'scripts'):/home/arnaud/books/scripts:ro" `
    -v "$(Join-Path $depot 'tests\shell'):/home/arnaud/tests-shell:ro" books-atlas-factice | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    try { $client = New-Object Net.Sockets.TcpClient('127.0.0.1', 2222); $client.Close(); break } catch { Start-Sleep -Milliseconds 500 }
}
Start-Sleep -Seconds 1
# Dépôts distants de test : chacun lance faux-export-guide.sh dans un mode défectueux
$modes = 'valide empreinte-fausse document-vide fichier-en-trop manifeste-absent manifeste-autre-nom membre-parent ' +
    'pas-une-archive code-non-nul champ-inconnu rang-hors-plage avec-bom pas-utf8 json-invalide nom-date-differente'
Invoke-Atlas ('for m in ' + $modes + '; do mkdir -p ~/variantes/$m/scripts; ' +
    'printf ''exec bash ~/tests-shell/faux-export-guide.sh %s\n'' $m > ~/variantes/$m/scripts/exporter-guide.sh; done') | Out-Null

try {
    # 1. Réception réussie, par le vrai script d'export (faux PostgreSQL)
    $empreinte1 = Set-FauxGuide '2026-10-11T18:00:00Z'
    $script:avant = @()
    $code = Invoke-Reception
    $premier = 'guide_2026-10-11T180000Z.json'
    $cheminPremier = Join-Path $guides $premier
    if ($code -ne 0) { Write-Host $sortieReception }  # motif de l'échec, pour le diagnostic
    Test-Condition 'réussite : code 0' ($code -eq 0)
    Test-Condition 'réussite : le guide et son manifeste, rien d''autre' (((Get-Contenu) -join ',') -ceq "$premier,$premier.sha256")
    if (Test-Path -LiteralPath $cheminPremier) {
        Test-Condition 'réussite : guide identique au document d''atlas, octet par octet' ((Get-Empreinte $cheminPremier) -eq $empreinte1)
        Test-Condition 'réussite : manifeste rangé, vérifiable (empreinte et nom du guide)' (
            [IO.File]::ReadAllText("$cheminPremier.sha256") -ceq "$empreinte1  $premier`n")
    }
    Test-Condition 'réussite : bilan (3 listes, 11 livres, 5 fiches Kindle, observations)' (
        $sortieReception -match 'Listes\s+: 3, 11 livre' -and $sortieReception -match 'Fiches Kindle\s+: 5 ASIN' -and
        $sortieReception -match 'du 2026-10-09T18:30:00Z au 2026-10-10T20:00:00Z' -and $sortieReception -match 'Importez ce fichier')
    Test-Condition 'réussite : dossier de travail vidé' (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
    Test-Condition 'réussite : aucun fichier laissé sur atlas' (Test-AtlasPropre)

    # 2. Seconde réception, autre date d'export : le premier guide est conservé, intact
    $empreinte2 = Set-FauxGuide '2026-10-11T19:00:00Z'
    $code = Invoke-Reception
    Test-Condition 'seconde réception : code 0' ($code -eq 0)
    Test-Condition 'seconde réception : deux guides présents, aucun supprimé' (@(Get-Contenu | Where-Object { $_ -cmatch $NomGuide }).Count -eq 2)
    Test-Condition 'seconde réception : premier guide intact' ((Get-Empreinte $cheminPremier) -eq $empreinte1)
    Test-Condition 'seconde réception : nouveau guide au nom de sa date' (
        (Get-Empreinte (Join-Path $guides 'guide_2026-10-11T190000Z.json')) -eq $empreinte2)

    # 3. Lecture en échec sur atlas (vrai script d'export)
    $script:avant = @(Get-Contenu)
    Invoke-Atlas 'echo 1 > ~/code-guide' | Out-Null
    Test-Refus 'lecture en échec sur atlas' (Invoke-Reception) 'code de ssh'
    Test-Condition 'lecture en échec : aucun fichier laissé sur atlas' (Test-AtlasPropre)
    Invoke-Atlas 'rm ~/code-guide' | Out-Null

    # 4. Exports défectueux, par le même point d'entrée
    Test-Refus 'empreinte falsifiée' (Invoke-Reception 'variantes/empreinte-fausse') 'empreinte SHA-256 différente'
    Test-Refus 'document vide' (Invoke-Reception 'variantes/document-vide') 'document vide'
    Test-Refus 'fichier en trop' (Invoke-Reception 'variantes/fichier-en-trop') 'contenu de l''archive inattendu'
    Test-Refus 'manifeste absent' (Invoke-Reception 'variantes/manifeste-absent') 'contenu de l''archive inattendu'
    Test-Refus 'manifeste pour un autre nom' (Invoke-Reception 'variantes/manifeste-autre-nom') 'MANIFEST.sha256 mal formé'
    Test-Refus 'membre hors du dossier (..)' (Invoke-Reception 'variantes/membre-parent') 'contenu de l''archive inattendu'
    Test-Condition 'membre hors du dossier (..) : rien écrit à côté du dossier de travail' (
        @(Get-ChildItem -LiteralPath $racine -File -Filter 'guide_*').Count -eq 0)
    Test-Refus 'sortie qui n''est pas une archive' (Invoke-Reception 'variantes/pas-une-archive') 'archive illisible'
    Test-Refus 'archive correcte mais export en échec' (Invoke-Reception 'variantes/code-non-nul') 'code de ssh : 1'
    Test-Refus 'champ inconnu dans une entrée' (Invoke-Reception 'variantes/champ-inconnu') 'entrée 0 : clés inattendues'
    Test-Refus 'rang hors de 1 à 100' (Invoke-Reception 'variantes/rang-hors-plage') 'rank hors de 1 à 100'
    Test-Refus 'document avec BOM' (Invoke-Reception 'variantes/avec-bom') 'avec BOM'
    Test-Refus 'document qui n''est pas de l''UTF-8' (Invoke-Reception 'variantes/pas-utf8') 'UTF-8 valide'
    Test-Refus 'JSON invalide' (Invoke-Reception 'variantes/json-invalide') 'pas du JSON valide'
    Test-Refus 'nom différent de la date d''export' (Invoke-Reception 'variantes/nom-date-differente') 'différent de sa date d''export'

    # 5. Collision : un guide du même nom existe déjà ; il n'est pas écrasé
    $existant = Join-Path $guides 'guide_2026-10-11T170000Z.json'
    [IO.File]::WriteAllText($existant, 'guide existant')
    $script:avant = @(Get-Contenu)
    Test-Refus 'collision' (Invoke-Reception 'variantes/valide') 'existe déjà'
    Test-Condition 'collision : guide existant intact' ([IO.File]::ReadAllText($existant) -eq 'guide existant')
    Remove-Item -LiteralPath $existant
    $script:avant = @(Get-Contenu)

    # 6. Mauvais mot de passe
    [IO.File]::WriteAllText($askpass, "@echo faux-mot-de-passe`r`n")
    Test-Refus 'mauvais mot de passe' (Invoke-Reception) 'code de ssh'
    [IO.File]::WriteAllText($askpass, "@echo mot-de-passe-de-test`r`n")

    # 7. Réglage local : absent, clé inconnue, dossier absent (code 2, aucune connexion)
    Test-Condition 'réglage absent : code 2' ((Invoke-Reception 'books' (Join-Path $racine 'absent.psd1')) -eq 2)
    $faute = Join-Path $racine 'faute.psd1'
    [IO.File]::WriteAllText($faute, "@{ DossierGuide = '$guides'; DossierCaptures = 'x' }`n")
    Test-Condition 'clé inconnue dans le réglage : code 2' ((Invoke-Reception 'books' $faute) -eq 2)
    $sansDossier = Join-Path $racine 'sans-dossier.psd1'
    [IO.File]::WriteAllText($sansDossier, "@{ DossierGuide = '$(Join-Path $racine 'absent')' }`n")
    Test-Condition 'dossier du guide absent : code 2' ((Invoke-Reception 'books' $sansDossier) -eq 2)
    Test-Condition 'dossier du guide absent : pas créé' (-not (Test-Path -LiteralPath (Join-Path $racine 'absent')))
    Test-Condition 'réglage invalide : dossier du guide inchangé' (((Get-Contenu) -join ',') -eq ($script:avant -join ','))

    # 8. Lancement exactement comme l'utilisateur : double-clic sur le .cmd, sans aucun paramètre
    Set-FauxGuide '2026-10-11T20:00:00Z' | Out-Null
    $script:avant = @(Get-Contenu)
    $copie = Join-Path $racine 'scripts'
    New-Item -ItemType Directory -Path $copie -Force | Out-Null
    Copy-Item -LiteralPath $reception -Destination (Join-Path $copie 'recevoir-guide.ps1')
    Copy-Item -LiteralPath (Join-Path $depot 'scripts\recevoir-guide.cmd') -Destination $copie
    [IO.File]::WriteAllText((Join-Path $copie 'recevoir-guide.local.psd1'),
        "@{ DossierGuide = '$guides'; ConfigSsh = '$configSsh' }`n")
    # La touche attendue par « pause » est fournie par « echo. » ; 2>&1 : erreurs de lancement capturées aussi
    $doubleClic = Join-Path $racine 'double-clic.cmd'
    [IO.File]::WriteAllText($doubleClic, "@echo off`r`necho.| call `"$(Join-Path $copie 'recevoir-guide.cmd')`" 2>&1`r`nexit /b %ERRORLEVEL%`r`n")
    $tempAvant = $env:TEMP
    $env:TEMP = $travail  # valeur par défaut du dossier de travail (TEMP), sans écrire hors du dépôt
    try {
        $script:sortieReception = & cmd.exe /d /c $doubleClic | Out-String
        $code = $LASTEXITCODE
    } finally {
        $env:TEMP = $tempAvant
    }
    Test-Condition 'double-clic sans paramètre : pas d''erreur de lancement' ($sortieReception -notmatch 'Join-Path|Impossible de lier')
    Test-Condition 'double-clic sans paramètre : code 0' ($code -eq 0)
    Test-Condition 'double-clic sans paramètre : un guide de plus' (@(Get-Contenu).Count -eq $script:avant.Count + 2)
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
