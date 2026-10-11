<#
.SYNOPSIS
    Rapatrie sur le PC le guide de veille exporté par atlas, vérifié par son empreinte et son format (décision 017).

.DESCRIPTION
    1. Une seule connexion SSH (alias « atlas », mot de passe saisi à l'invite) : sur atlas,
       scripts/exporter-guide.sh lit guide.export_document sous books_reader et écrit sur sa sortie standard une
       archive tar (guide_….json + MANIFEST.sha256). L'archive est enregistrée par une redirection de cmd.exe,
       qui copie les octets tels quels.
    2. Contrôles dans un dossier de travail : code de ssh nul ; archive composée exactement du manifeste et d'un
       document au nom attendu ; manifeste d'une ligne désignant ce document ; empreinte SHA-256 identique ;
       document en UTF-8 sans BOM, au format version 1 (décision 017, section 4), dont la date d'export
       correspond au nom.
    3. Seulement alors, le document rejoint le dossier du guide (nom provisoire .partiel, empreinte revérifiée,
       puis renommage), accompagné de son manifeste (….json.sha256). Rien n'est jamais supprimé ni écrasé.
    Le dossier du guide n'est jamais celui des captures : l'envoi y signalerait le fichier comme hors format.

    Codes de sortie :
      0  guide reçu, vérifié et rangé
      1  export, transfert ou vérification en échec : rien n'a été ajouté au dossier du guide
      2  réglage local, dossier ou outil invalide : aucune connexion ouverte

.PARAMETER Reglages
    Fichier de réglage local (non versionné). Par défaut : recevoir-guide.local.psd1, à côté du script.
    Clés acceptées : DossierGuide (obligatoire), ConfigSsh (facultative).
.PARAMETER HoteSsh
    Alias SSH d'atlas, défini dans la configuration SSH de l'utilisateur. Par défaut : atlas.
.PARAMETER ConfigSsh
    Fichier de configuration SSH particulier (tests) ; à défaut, la clé ConfigSsh du réglage local ;
    à défaut, la configuration SSH de l'utilisateur.
.PARAMETER DepotDistant
    Dossier du dépôt sur atlas, relatif au dossier personnel. Par défaut : books.
.PARAMETER DossierTravail
    Dossier où l'archive est reçue et vérifiée, puis supprimée. Par défaut : le dossier temporaire de Windows (TEMP).
#>
[CmdletBinding()]
param(
    [string]$Reglages = '',
    [string]$HoteSsh = 'atlas',
    [string]$ConfigSsh = '',
    [string]$DepotDistant = 'books',
    [string]$DossierTravail = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Valeurs par défaut calculées ici, et non dans param() : sous PowerShell 5.1, $PSScriptRoot y est vide
# quand le script est lancé par « powershell -File » (cas du lanceur .cmd).
$dossierDuScript = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Reglages) { $Reglages = Join-Path $dossierDuScript 'recevoir-guide.local.psd1' }
if (-not $DossierTravail) { $DossierTravail = [IO.Path]::GetTempPath() }
# Les messages d'atlas (affichés par ssh) sont en UTF-8
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

# Nom d'un document du guide (décision 017, section 4)
$NomGuide = '^guide_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.json$'
$FormatDate = "yyyy-MM-dd'T'HH:mm:ss'Z'"
$Culture = [Globalization.CultureInfo]::InvariantCulture
# Outils fournis avec Windows, appelés par leur chemin complet (et non ceux d'autres logiciels installés)
$Ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$Tar = Join-Path $env:WINDIR 'System32\tar.exe'
$Utf8SansBom = New-Object System.Text.UTF8Encoding $false
# Décodage strict : un octet qui n'est pas de l'UTF-8 valide arrête la lecture au lieu d'être remplacé
$Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

function Write-Section([string]$texte) { Write-Host ''; Write-Host "== $texte" }
function Get-Empreinte([string]$chemin) { (Get-FileHash -LiteralPath $chemin -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-Cles($objet) {
    # Noms des champs d'un objet JSON, dans l'ordre du document ; $null si ce n'est pas un objet
    if ($objet -is [System.Management.Automation.PSCustomObject]) { return ,@($objet.PSObject.Properties | ForEach-Object Name) }
    return $null
}

function ConvertTo-DateUtc($valeur) {
    # Date au format AAAA-MM-JJTHH:MM:SSZ, existante ; $null sinon
    if ($valeur -isnot [string] -or $valeur -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') { return $null }
    $date = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParseExact($valeur, $FormatDate, $Culture, $styles, [ref]$date)) { return $date }
    return $null
}

function Test-Entier($valeur) { return ($valeur -is [int] -or $valeur -is [long]) }

function Test-FormatGuide($doc) {
    # Écarts au format version 1 (décision 017, section 4) ; tableau vide si le document est conforme.
    # Mêmes règles que tests/python/test_guide_contrat.py (check_document).
    $ecarts = New-Object System.Collections.Generic.List[string]
    $cles = Get-Cles $doc
    if ($null -eq $cles -or ($cles -join ',') -cne 'schema_version,generated_at,lists,kindle_asins') {
        $ecarts.Add("clés du document : $(if ($null -eq $cles) { 'pas un objet' } else { $cles -join ', ' })")
        return ,$ecarts.ToArray()
    }
    if (-not (Test-Entier $doc.schema_version) -or $doc.schema_version -ne 1) { $ecarts.Add('schema_version différent de 1') }
    $export = ConvertTo-DateUtc $doc.generated_at
    if ($null -eq $export) { $ecarts.Add('generated_at mal formé') }
    if ($doc.lists -isnot [array]) { $ecarts.Add("lists n'est pas un tableau"); return ,$ecarts.ToArray() }
    $precedente = $null
    $i = 0
    foreach ($liste in $doc.lists) {
        $clesListe = Get-Cles $liste
        if ($null -eq $clesListe -or ($clesListe -join ',') -cne 'category_node,list_type,entries') {
            $ecarts.Add("liste $i : clés inattendues"); $i++; continue
        }
        if ($liste.category_node -isnot [string] -or $liste.category_node -cnotmatch '^[0-9]+$') { $ecarts.Add("liste $i : category_node mal formé") }
        if ($liste.list_type -isnot [string] -or $liste.list_type -cnotin 'paid', 'free') { $ecarts.Add("liste $i : list_type inconnu") }
        # Tri par catégorie puis type (ordre ordinal ; la tabulation précède tout chiffre), sans doublon
        $cle = "$($liste.category_node)`t$($liste.list_type)"
        if ($null -ne $precedente -and [string]::CompareOrdinal($precedente, $cle) -ge 0) {
            $ecarts.Add('lists non triées par category_node puis list_type, ou liste en double')
        }
        $precedente = $cle
        if ($liste.entries -isnot [array] -or @($liste.entries).Count -eq 0) { $ecarts.Add("liste $i : entries vide ou absent"); $i++; continue }
        $rangs = New-Object System.Collections.Generic.List[object]
        $asins = New-Object System.Collections.Generic.HashSet[string]
        $doublon = $false
        $j = 0
        foreach ($entree in $liste.entries) {
            $clesEntree = Get-Cles $entree
            if ($null -eq $clesEntree -or ($clesEntree -join ',') -cne 'asin,rank,observed_at') {
                $ecarts.Add("liste $i, entrée $j : clés inattendues"); $j++; continue
            }
            if ($entree.asin -isnot [string] -or $entree.asin -cnotmatch '^[A-Z0-9]{10}$') { $ecarts.Add("liste $i, entrée $j : asin mal formé") }
            if (-not (Test-Entier $entree.rank) -or $entree.rank -lt 1 -or $entree.rank -gt 100) { $ecarts.Add("liste $i, entrée $j : rank hors de 1 à 100") }
            $observation = ConvertTo-DateUtc $entree.observed_at
            if ($null -eq $observation) { $ecarts.Add("liste $i, entrée $j : observed_at mal formé") }
            elseif ($null -ne $export -and $observation -gt $export) { $ecarts.Add("liste $i, entrée $j : observed_at postérieur à generated_at") }
            if (-not $asins.Add([string]$entree.asin)) { $doublon = $true }
            if ($rangs -contains $entree.rank) { $doublon = $true }
            $rangs.Add($entree.rank)
            $j++
        }
        if ($doublon) { $ecarts.Add("liste $i : ASIN ou rang en double") }
        elseif (@($rangs | Where-Object { -not (Test-Entier $_) }).Count -eq 0) {
            for ($k = 1; $k -lt $rangs.Count; $k++) {
                if ($rangs[$k] -le $rangs[$k - 1]) { $ecarts.Add("liste $i : entries non triées par rang"); break }
            }
        }
        $i++
    }
    if ($doc.kindle_asins -isnot [array] -or @($doc.kindle_asins | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[A-Z0-9]{10}$' }).Count -gt 0) {
        $ecarts.Add('kindle_asins mal formé')
    }
    else {
        $k = @($doc.kindle_asins)
        for ($n = 1; $n -lt $k.Count; $n++) {
            if ([string]::CompareOrdinal($k[$n - 1], $k[$n]) -ge 0) { $ecarts.Add('kindle_asins non triés ou en double'); break }
        }
    }
    return ,$ecarts.ToArray()
}

# --- 1. Réglage local et outils ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Reglages -PathType Leaf)) {
    Write-Host "Réglage local introuvable : $Reglages"
    Write-Host "Copiez recevoir-guide.exemple.psd1 en recevoir-guide.local.psd1, puis indiquez votre dossier."
    exit 2
}
$reglage = Import-PowerShellDataFile -LiteralPath $Reglages
# Clés acceptées ; une clé inconnue (faute de frappe) arrête le script au lieu d'être ignorée
$clesInconnues = @($reglage.Keys | Where-Object { $_ -cnotin 'DossierGuide', 'ConfigSsh' })
if ($clesInconnues.Count -gt 0) {
    Write-Host "Réglage inconnu dans $Reglages : $($clesInconnues -join ', ') (acceptés : DossierGuide, ConfigSsh)."
    exit 2
}
if (-not $ConfigSsh -and $reglage.ContainsKey('ConfigSsh')) { $ConfigSsh = $reglage['ConfigSsh'] }
$dossier = $reglage['DossierGuide']
if (-not $dossier -or -not (Test-Path -LiteralPath $dossier -PathType Container)) {
    Write-Host "Dossier du guide introuvable : '$dossier' (réglage DossierGuide de $Reglages)."
    exit 2
}
foreach ($outil in $Ssh, $Tar) {
    if (-not (Test-Path -LiteralPath $outil -PathType Leaf)) { Write-Host "Outil introuvable : $outil"; exit 2 }
}
if ($ConfigSsh -and -not (Test-Path -LiteralPath $ConfigSsh -PathType Leaf)) {
    Write-Host "Configuration SSH introuvable : $ConfigSsh"; exit 2
}

# --- 2. Réception de l'archive ---------------------------------------------------------------
$horodatage = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HHmmss'Z'", $Culture)
$travail = Join-Path $DossierTravail "books-guide-$horodatage"
$archive = Join-Path $travail 'guide.tar'
$extrait = Join-Path $travail 'extrait'
$lanceur = Join-Path $travail 'reception.cmd'
$partiel = $null
$code = 1

New-Item -ItemType Directory -Path $extrait | Out-Null
try {
    # Redirection de cmd.exe : octets enregistrés tels quels. Seule la sortie normale (l'archive) va dans le fichier ;
    # la sortie d'erreur reste à l'écran (questions de ssh, messages d'atlas). -n : ssh ne lit pas le clavier.
    $optionConfig = if ($ConfigSsh) { "-F `"$ConfigSsh`" " } else { '' }
    $ligne = "`"$Ssh`" -n $optionConfig$HoteSsh bash $DepotDistant/scripts/exporter-guide.sh > `"$archive`""
    [IO.File]::WriteAllText($lanceur, "@echo off`r`n$ligne`r`nexit /b %ERRORLEVEL%`r`n", [Text.Encoding]::Default)

    Write-Section "Export du guide de veille sur $HoteSsh"
    Write-Host 'Saisissez le mot de passe d''atlas si ssh le demande.'
    & cmd.exe /d /c "`"$lanceur`""
    $codeSsh = $LASTEXITCODE
    if ($codeSsh -ne 0) { throw "export ou transfert échoué (code de ssh : $codeSsh)" }
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or (Get-Item -LiteralPath $archive).Length -eq 0) {
        throw 'aucune archive reçue'
    }

    # --- 3. Contrôles --------------------------------------------------------------------------
    Write-Section 'Vérification'
    # Contenu de l'archive, lu AVANT toute extraction : exactement le manifeste et un document au nom attendu
    $membres = @(& $Tar -t -f $archive)
    if ($LASTEXITCODE -ne 0) { throw 'archive illisible' }
    $documents = @($membres | Where-Object { $_ -cmatch $NomGuide })
    if ($membres.Count -ne 2 -or $documents.Count -ne 1 -or ($membres -cnotcontains 'MANIFEST.sha256')) {
        throw "contenu de l'archive inattendu : $($membres -join ', ')"
    }
    $nom = $documents[0]
    & $Tar -x -f $archive -C $extrait
    if ($LASTEXITCODE -ne 0) { throw "extraction de l'archive échouée" }
    $recu = Join-Path $extrait $nom
    $manifeste = Join-Path $extrait 'MANIFEST.sha256'
    foreach ($f in $recu, $manifeste) {
        # Fichier ordinaire seulement : ni dossier, ni lien vers un autre fichier
        if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or
            ((Get-Item -LiteralPath $f).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$(Split-Path -Leaf $f) n'est pas un fichier ordinaire"
        }
    }
    $ligneManifeste = [regex]::Match([IO.File]::ReadAllText($manifeste, $Utf8SansBom), '\A([0-9a-f]{64})  (\S+)\n?\z')
    if (-not $ligneManifeste.Success -or $ligneManifeste.Groups[2].Value -cne $nom) {
        throw 'MANIFEST.sha256 mal formé, ou ne désignant pas le document reçu'
    }
    $attendue = $ligneManifeste.Groups[1].Value
    if ((Get-Item -LiteralPath $recu).Length -eq 0) { throw 'document vide' }
    $empreinte = Get-Empreinte $recu
    if ($empreinte -cne $attendue) {
        throw "empreinte SHA-256 différente de celle du manifeste (reçue $empreinte, attendue $attendue)"
    }
    Write-Host "Empreinte conforme au manifeste : $empreinte"

    # Format du document (décision 017, section 4)
    $octets = [IO.File]::ReadAllBytes($recu)
    if ($octets.Length -ge 3 -and $octets[0] -eq 0xEF -and $octets[1] -eq 0xBB -and $octets[2] -eq 0xBF) {
        throw 'document en UTF-8 avec BOM : format attendu sans BOM'
    }
    try { $texte = $Utf8Strict.GetString($octets) } catch { throw "document qui n'est pas de l'UTF-8 valide" }
    # ConvertFrom-Json de PowerShell 5.1 lit au plus 2 Mo de texte : au-delà, refus visible (bien au-dessus du volume prévu)
    try { $doc = ConvertFrom-Json -InputObject $texte } catch { throw "document qui n'est pas du JSON valide : $($_.Exception.Message)" }
    # Pas de @() : la fonction rend déjà un tableau (vide si conforme), qu'un @() envelopperait une seconde fois
    $ecarts = Test-FormatGuide $doc
    if ($ecarts.Count -gt 0) {
        throw "document non conforme au format version 1 : $($ecarts[0..([Math]::Min(4, $ecarts.Count - 1))] -join ' ; ')"
    }
    $export = ConvertTo-DateUtc $doc.generated_at
    if ("guide_$($export.ToString("yyyy-MM-dd'T'HHmmss'Z'", $Culture)).json" -cne $nom) {
        throw "nom du document ($nom) différent de sa date d'export ($($doc.generated_at))"
    }
    Write-Host 'Format conforme (version 1).'

    # --- 4. Rangement : nom provisoire, empreinte revérifiée, puis renommage ----------------------
    $final = Join-Path $dossier $nom
    $finalManifeste = "$final.sha256"
    $partielPrevu = "$final.partiel"
    foreach ($f in $final, $finalManifeste, $partielPrevu) {
        if (Test-Path -LiteralPath $f) { throw "$(Split-Path -Leaf $f) existe déjà dans le dossier du guide : rien n'est écrasé" }
    }
    $partiel = $partielPrevu
    Move-Item -LiteralPath $recu -Destination $partiel
    if ((Get-Empreinte $partiel) -cne $attendue) { throw 'empreinte différente après le déplacement vers le dossier du guide' }
    Move-Item -LiteralPath $partiel -Destination $final
    $partiel = $null
    Move-Item -LiteralPath $manifeste -Destination $finalManifeste

    # --- 5. Bilan --------------------------------------------------------------------------------
    $listes = @($doc.lists)
    $entrees = @($listes | ForEach-Object { @($_.entries) })
    $dates = @($entrees | ForEach-Object { $_.observed_at } | Sort-Object -Unique)
    Write-Section 'Résultat'
    Write-Host "Guide reçu et vérifié : $nom"
    Write-Host "  Export          : $($doc.generated_at) (UTC)"
    Write-Host "  Listes          : $($listes.Count), $($entrees.Count) livre(s) classé(s)"
    Write-Host "  Fiches Kindle   : $(@($doc.kindle_asins).Count) ASIN en base"
    if ($dates.Count -gt 0) { Write-Host "  Observations    : du $($dates[0]) au $($dates[-1]) (UTC)" }
    Write-Host "  Dossier         : $dossier"
    Write-Host 'Importez ce fichier dans l''extension (page d''options du guide) avant la prochaine séance.'
    $restes = @(Get-ChildItem -LiteralPath $dossier -File -Filter '*.partiel')
    foreach ($r in $restes) { Write-Host "Signalé : $($r.Name), reste d'une exécution interrompue, à examiner puis supprimer à la main." }
    $code = 0
}
catch {
    Write-Section 'Échec'
    Write-Host "Erreur : $($_.Exception.Message)"
    Write-Host 'Rien n''a été ajouté au dossier du guide.'
    $code = 1
}
finally {
    if ($partiel) { Remove-Item -LiteralPath $partiel -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $travail -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
