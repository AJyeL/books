<#
Tests de scripts/rapatrier-sauvegarde.ps1 contre un faux atlas (conteneur SSH), autovérifiés (code 0 = tout est conforme).

Lancement, depuis le dossier du dépôt, Docker Desktop démarré :
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-RapatrierSauvegarde.ps1

- Utilise les vrais ssh.exe, tar.exe et cmd.exe de Windows, et le vrai scripts/exporter-sauvegarde.sh,
  avec un faux PostgreSQL (tests/shell/faux-docker) qui produit un faux dump binaire (les 256 valeurs d'octets).
- Refus : des exports volontairement défectueux (tests/shell/faux-export.sh) sont appelés par le même point
  d'entrée, en désignant un autre dépôt distant (-DepotDistant variantes/{mode}).
- Le faux atlas est publié sur 127.0.0.1:2222 le temps des tests, puis supprimé.
- Configuration SSH de test (-F) : la configuration SSH de l'utilisateur n'est ni lue ni modifiée.
  Le mot de passe de test est fourni par SSH_ASKPASS, pour ce test seulement.
- Fichiers de travail dans data\tests-rapatriement\ (ignoré par Git), supprimés à la fin.
- Scénario du double-clic : copie du script et du lanceur .cmd dans data\tests-rapatriement\scripts\, avec un réglage
  local de test à côté, puis lancement du .cmd sans aucun paramètre. Le vrai réglage local n'est jamais lu ni modifié.

Paramètre facultatif -ScriptRapatriement : version du script à tester (par défaut, celle du dépôt),
pour les contre-épreuves.
#>
param([string]$ScriptRapatriement = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$depot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$racine = Join-Path $depot 'data\tests-rapatriement'
$sauvegardes = Join-Path $racine 'sauvegardes'
$travail = Join-Path $racine 'travail'
$reglage = Join-Path $racine 'reglage.psd1'
$configSsh = Join-Path $racine 'ssh_config'
$fauxDump = Join-Path $racine 'faux-dump'
# Chemin par défaut calculé ici, et non dans param() : sous PowerShell 5.1, $PSScriptRoot y est vide
$rapatriement = if ($ScriptRapatriement) { (Resolve-Path -LiteralPath $ScriptRapatriement).Path } else { Join-Path $depot 'scripts\rapatrier-sauvegarde.ps1' }
$conteneur = 'books-atlas-factice'
$NomDump = '^books_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\.dump$'
$echecs = 0

function Test-Condition([string]$libelle, [bool]$condition) {
    if ($condition) { Write-Host "OK    $libelle" } else { Write-Host "ÉCHEC $libelle"; $script:echecs++ }
}

function Invoke-Atlas([string]$commande) {
    # Commande sur le faux atlas, en tant qu'arnaud ; renvoie la sortie
    $sortie = & docker exec -u arnaud $conteneur sh -c $commande
    return ($sortie -join "`n")
}

function Invoke-Rapatriement([string]$depotDistant = 'books', [string]$fichierReglage = $reglage) {
    $script:sortieRapatriement = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rapatriement `
        -Reglages $fichierReglage -HoteSsh 'atlas-factice' -ConfigSsh $configSsh -DepotDistant $depotDistant `
        -DossierTravail $travail | Out-String
    return $LASTEXITCODE
}

function Get-Contenu { @(Get-ChildItem -LiteralPath $sauvegardes -File | ForEach-Object Name | Sort-Object) }
function Get-Empreinte([string]$chemin) { (Get-FileHash -LiteralPath $chemin -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-AtlasPropre { (Invoke-Atlas 'find /tmp -mindepth 1 -maxdepth 1 -user arnaud') -eq '' }

function Test-Refus([string]$libelle, [int]$code, [string]$motif) {
    # Refus : code 1, dossier des sauvegardes inchangé, motif affiché, dossier de travail vidé
    Test-Condition "$libelle : code 1" ($code -eq 1)
    Test-Condition "$libelle : dossier des sauvegardes inchangé" (((Get-Contenu) -join ',') -eq ($script:avant -join ','))
    Test-Condition "$libelle : motif affiché" ($sortieRapatriement -match $motif)
    Test-Condition "$libelle : dossier de travail vidé" (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
}

# --- Préparation : dossiers, réglage, configuration SSH de test, faux dump, faux atlas -------
Remove-Item -LiteralPath $racine -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $racine, $sauvegardes, $travail | Out-Null
[IO.File]::WriteAllText($reglage, "@{ DossierSauvegardes = '$sauvegardes' }`n")
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

# Faux dump : signature PGDMP, puis 4 fois les 256 valeurs d'octets (nul, CR, LF, 0x1A, 0xFF…), puis CR LF
$octets = New-Object System.Collections.Generic.List[byte]
$octets.AddRange([Text.Encoding]::ASCII.GetBytes('PGDMP'))
for ($n = 0; $n -lt 4; $n++) { for ($i = 0; $i -lt 256; $i++) { $octets.Add([byte]$i) } }
$octets.AddRange([byte[]](13, 10))
[IO.File]::WriteAllBytes($fauxDump, $octets.ToArray())
$empreinteFauxDump = Get-Empreinte $fauxDump

& docker rm -f $conteneur 2>$null | Out-Null
& docker build -q -t books-atlas-factice -f (Join-Path $depot 'tests\atlas-factice\Dockerfile') (Join-Path $depot 'tests') | Out-Null
& docker run -d --name $conteneur -p 127.0.0.1:2222:22 `
    -v "$(Join-Path $depot 'scripts'):/home/arnaud/books/scripts:ro" `
    -v "$(Join-Path $depot 'tests\shell'):/home/arnaud/tests-shell:ro" books-atlas-factice | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    try { $client = New-Object Net.Sockets.TcpClient('127.0.0.1', 2222); $client.Close(); break } catch { Start-Sleep -Milliseconds 500 }
}
Start-Sleep -Seconds 1
& docker cp $fauxDump "${conteneur}:/home/arnaud/faux-dump" | Out-Null
& docker exec $conteneur chown arnaud:arnaud /home/arnaud/faux-dump | Out-Null
# Dépôts distants de test : chacun lance faux-export.sh dans un mode défectueux
$modes = 'valide empreinte-fausse dump-vide fichier-en-trop manifeste-absent manifeste-autre-nom membre-parent pas-une-archive code-non-nul'
Invoke-Atlas ('for m in ' + $modes + '; do mkdir -p ~/variantes/$m/scripts; ' +
    'printf ''exec bash ~/tests-shell/faux-export.sh %s\n'' $m > ~/variantes/$m/scripts/exporter-sauvegarde.sh; done') | Out-Null

try {
    # 1. Rapatriement réussi, par le vrai script d'export
    $script:avant = @()
    $code = Invoke-Rapatriement
    $contenu = @(Get-Contenu)
    $dumps = @($contenu | Where-Object { $_ -cmatch $NomDump })
    Test-Condition 'réussite : code 0' ($code -eq 0)
    Test-Condition 'réussite : un dump et son manifeste, rien d''autre' ($contenu.Count -eq 2 -and $dumps.Count -eq 1 -and $contenu -ccontains "$($dumps[0]).sha256")
    if ($dumps.Count -eq 1) {
        $premier = $dumps[0]
        $cheminPremier = Join-Path $sauvegardes $premier
        Test-Condition 'réussite : dump identique au faux dump d''atlas, octet par octet' ((Get-Empreinte $cheminPremier) -eq $empreinteFauxDump)
        Test-Condition 'réussite : manifeste rangé, vérifiable (empreinte et nom du dump)' (
            [IO.File]::ReadAllText("$cheminPremier.sha256") -ceq "$empreinteFauxDump  $premier`n")
        Test-Condition 'réussite : bilan (nom, empreinte, 1 copie)' (
            $sortieRapatriement -match [regex]::Escape($premier) -and $sortieRapatriement -match $empreinteFauxDump -and
            $sortieRapatriement -match 'Copies présentes : 1,')
    }
    Test-Condition 'réussite : dossier de travail vidé' (@(Get-ChildItem -LiteralPath $travail).Count -eq 0)
    Test-Condition 'réussite : dossier temporaire supprimé sur atlas' (Test-AtlasPropre)

    # 2. Second rapatriement : la première copie est conservée, intacte
    Start-Sleep -Seconds 1
    $code = Invoke-Rapatriement
    Test-Condition 'seconde copie : code 0' ($code -eq 0)
    Test-Condition 'seconde copie : deux dumps présents, aucun supprimé' (@(Get-Contenu | Where-Object { $_ -cmatch $NomDump }).Count -eq 2)
    Test-Condition 'seconde copie : première copie intacte' ((Get-Empreinte $cheminPremier) -eq $empreinteFauxDump)
    Test-Condition 'seconde copie : bilan, 2 copies' ($sortieRapatriement -match 'Copies présentes : 2,')

    # 3. pg_dump en échec sur atlas (vrai script d'export)
    $script:avant = @(Get-Contenu)
    Invoke-Atlas 'echo 1 > ~/code-pg-dump' | Out-Null
    # Le message d'atlas passe par la sortie d'erreur de ssh, affichée à l'écran et non capturée ici
    Test-Refus 'pg_dump en échec' (Invoke-Rapatriement) 'code de ssh'
    Test-Condition 'pg_dump en échec : dossier temporaire supprimé sur atlas' (Test-AtlasPropre)
    Invoke-Atlas 'rm ~/code-pg-dump' | Out-Null

    # 4. Exports défectueux, par le même point d'entrée
    Test-Refus 'empreinte falsifiée' (Invoke-Rapatriement 'variantes/empreinte-fausse') 'empreinte SHA-256 différente'
    Test-Refus 'dump vide' (Invoke-Rapatriement 'variantes/dump-vide') 'sauvegarde vide'
    Test-Refus 'fichier en trop' (Invoke-Rapatriement 'variantes/fichier-en-trop') 'contenu de l''archive inattendu'
    Test-Refus 'manifeste absent' (Invoke-Rapatriement 'variantes/manifeste-absent') 'contenu de l''archive inattendu'
    Test-Refus 'manifeste pour un autre nom' (Invoke-Rapatriement 'variantes/manifeste-autre-nom') 'MANIFEST.sha256 mal formé'
    Test-Refus 'membre hors du dossier (..)' (Invoke-Rapatriement 'variantes/membre-parent') 'contenu de l''archive inattendu'
    Test-Condition 'membre hors du dossier (..) : rien écrit à côté du dossier de travail' (
        @(Get-ChildItem -LiteralPath $racine -File -Filter 'books_*').Count -eq 0)
    Test-Refus 'sortie qui n''est pas une archive' (Invoke-Rapatriement 'variantes/pas-une-archive') 'archive illisible'
    Test-Refus 'archive correcte mais export en échec' (Invoke-Rapatriement 'variantes/code-non-nul') 'code de ssh : 1'

    # 5. Collision : une copie du même nom existe déjà ; elle n'est pas écrasée
    $existant = Join-Path $sauvegardes 'books_2026-10-08T10-00-00Z.dump'
    [IO.File]::WriteAllText($existant, 'copie existante')
    $script:avant = @(Get-Contenu)
    Test-Refus 'collision' (Invoke-Rapatriement 'variantes/valide') 'existe déjà'
    Test-Condition 'collision : copie existante intacte' ([IO.File]::ReadAllText($existant) -eq 'copie existante')
    Remove-Item -LiteralPath $existant

    # 6. Mauvais mot de passe
    $script:avant = @(Get-Contenu)
    [IO.File]::WriteAllText($askpass, "@echo faux-mot-de-passe`r`n")
    Test-Refus 'mauvais mot de passe' (Invoke-Rapatriement) 'code de ssh'
    [IO.File]::WriteAllText($askpass, "@echo mot-de-passe-de-test`r`n")

    # 7. Réglage local : absent, clé inconnue, dossier absent (code 2, aucune connexion)
    Test-Condition 'réglage absent : code 2' ((Invoke-Rapatriement 'books' (Join-Path $racine 'absent.psd1')) -eq 2)
    $faute = Join-Path $racine 'faute.psd1'
    [IO.File]::WriteAllText($faute, "@{ DossierSauvegardes = '$sauvegardes'; DossierSauvegarde = 'x' }`n")
    Test-Condition 'clé inconnue dans le réglage : code 2' ((Invoke-Rapatriement 'books' $faute) -eq 2)
    $sansDossier = Join-Path $racine 'sans-dossier.psd1'
    [IO.File]::WriteAllText($sansDossier, "@{ DossierSauvegardes = '$(Join-Path $racine 'absent')' }`n")
    Test-Condition 'dossier des sauvegardes absent : code 2' ((Invoke-Rapatriement 'books' $sansDossier) -eq 2)
    Test-Condition 'dossier des sauvegardes absent : pas créé' (-not (Test-Path -LiteralPath (Join-Path $racine 'absent')))
    Test-Condition 'réglage invalide : dossier des sauvegardes inchangé' (((Get-Contenu) -join ',') -eq ($script:avant -join ','))

    # 8. Seuil de révision : 23 copies factices + 1 rapatriée = 24
    $seuil = Join-Path $racine 'seuil'
    New-Item -ItemType Directory -Path $seuil | Out-Null
    for ($i = 1; $i -le 23; $i++) { [IO.File]::WriteAllText((Join-Path $seuil ('books_2025-01-{0:D2}T00-00-00Z.dump' -f $i)), 'x') }
    $reglageSeuil = Join-Path $racine 'seuil.psd1'
    [IO.File]::WriteAllText($reglageSeuil, "@{ DossierSauvegardes = '$seuil' }`n")
    $code = Invoke-Rapatriement 'books' $reglageSeuil
    Test-Condition 'seuil de révision : code 0, 24 copies, signalé' ($code -eq 0 -and $sortieRapatriement -match 'Copies présentes : 24,' -and $sortieRapatriement -match 'Seuil de révision atteint')

    # 9. Lancement exactement comme l'utilisateur : double-clic sur le .cmd, sans aucun paramètre
    $script:avant = @(Get-Contenu)
    $copie = Join-Path $racine 'scripts'
    New-Item -ItemType Directory -Path $copie -Force | Out-Null
    Copy-Item -LiteralPath $rapatriement -Destination (Join-Path $copie 'rapatrier-sauvegarde.ps1')
    Copy-Item -LiteralPath (Join-Path $depot 'scripts\rapatrier-sauvegarde.cmd') -Destination $copie
    [IO.File]::WriteAllText((Join-Path $copie 'rapatrier-sauvegarde.local.psd1'),
        "@{ DossierSauvegardes = '$sauvegardes'; ConfigSsh = '$configSsh' }`n")
    # La touche attendue par « pause » est fournie par « echo. » ; 2>&1 : erreurs de lancement capturées aussi
    $doubleClic = Join-Path $racine 'double-clic.cmd'
    [IO.File]::WriteAllText($doubleClic, "@echo off`r`necho.| call `"$(Join-Path $copie 'rapatrier-sauvegarde.cmd')`" 2>&1`r`nexit /b %ERRORLEVEL%`r`n")
    $tempAvant = $env:TEMP
    $env:TEMP = $travail  # valeur par défaut du dossier de travail (TEMP), sans écrire hors du dépôt
    try {
        $script:sortieRapatriement = & cmd.exe /d /c $doubleClic | Out-String
        $code = $LASTEXITCODE
    } finally {
        $env:TEMP = $tempAvant
    }
    Test-Condition 'double-clic sans paramètre : pas d''erreur de lancement' ($sortieRapatriement -notmatch 'Join-Path|Impossible de lier')
    Test-Condition 'double-clic sans paramètre : code 0' ($code -eq 0)
    Test-Condition 'double-clic sans paramètre : une copie de plus' (@(Get-Contenu).Count -eq $script:avant.Count + 2)
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
