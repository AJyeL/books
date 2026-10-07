<#
.SYNOPSIS
    Envoie les captures de l'extension vers atlas et lance leur ingestion (décision 008, section 1).

.DESCRIPTION
    1. Inventaire du dossier des captures (premier niveau seulement) : seules les paires complètes .html + .json
       au nom conforme (décision 007) partent ; tout autre fichier est signalé et laissé sur place.
    2. Préparation : copie des paires dans un dossier de travail, liste d'empreintes MANIFEST.sha256 calculée
       sur les originaux, archive tar. Aucun outil ne lit les captures comme du texte.
    3. Une seule connexion SSH (alias « atlas », mot de passe saisi à l'invite) : l'archive est transmise par une
       redirection de cmd.exe, qui copie les octets tels quels (jamais par un tuyau PowerShell).
       Sur atlas, scripts/recevoir-captures.sh déballe, vérifie, place le lot dans inbox/ et lance l'ingestion.
    4. Si le transfert a réussi, les captures sont déplacées dans envoyees\AAAA-MM\ (mois de la capture),
       quel que soit le résultat de l'ingestion : envoyees\ est une archive permanente, jamais vidée.

    Codes de sortie :
      0  transfert réussi, ingestion sans anomalie (ou aucune capture à envoyer)
      1  transfert réussi, ingestion avec anomalies ou non effectuée (les captures attendent dans inbox/)
      2  réglage local, dossier ou outil invalide : rien n'a été envoyé
      3  transfert échoué : rien n'a été déplacé sur le PC

.PARAMETER Reglages
    Fichier de réglage local (non versionné). Par défaut : envoyer-captures.local.psd1, à côté du script.
.PARAMETER HoteSsh
    Alias SSH d'atlas, défini dans la configuration SSH de l'utilisateur. Par défaut : atlas.
.PARAMETER ConfigSsh
    Fichier de configuration SSH particulier (tests) ; vide : celui de l'utilisateur.
.PARAMETER DepotDistant
    Dossier du dépôt sur atlas, relatif au dossier personnel. Par défaut : books.
.PARAMETER DossierTravail
    Dossier où l'archive est préparée, puis supprimée. Par défaut : le dossier temporaire de Windows.
#>
[CmdletBinding()]
param(
    [string]$Reglages = (Join-Path $PSScriptRoot 'envoyer-captures.local.psd1'),
    [string]$HoteSsh = 'atlas',
    [string]$ConfigSsh = '',
    [string]$DepotDistant = 'books',
    [string]$DossierTravail = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Le bilan venu d'atlas est en UTF-8
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

# Nom d'une capture sans extension (décision 007) ; groupes 2 et 3 : année et mois de la capture
$NomCapture = '^amazon_fr_bestsellers_[0-9]+_(paid|free)_p[12]_([0-9]{4})-([0-9]{2})-[0-9]{2}T[0-9]{6}Z$'
# Outils fournis avec Windows, appelés par leur chemin complet (et non ceux d'autres logiciels installés)
$Ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$Tar = Join-Path $env:WINDIR 'System32\tar.exe'
$Utf8SansBom = New-Object System.Text.UTF8Encoding $false

function Write-Section([string]$texte) { Write-Host ''; Write-Host "== $texte" }

# --- 1. Réglage local et outils ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Reglages -PathType Leaf)) {
    Write-Host "Réglage local introuvable : $Reglages"
    Write-Host "Copiez envoyer-captures.exemple.psd1 en envoyer-captures.local.psd1, puis indiquez votre dossier."
    exit 2
}
$reglage = Import-PowerShellDataFile -LiteralPath $Reglages
$dossier = $reglage['DossierCaptures']
if (-not $dossier -or -not (Test-Path -LiteralPath $dossier -PathType Container)) {
    Write-Host "Dossier des captures introuvable : '$dossier' (réglage DossierCaptures de $Reglages)."
    exit 2
}
foreach ($outil in $Ssh, $Tar) {
    if (-not (Test-Path -LiteralPath $outil -PathType Leaf)) { Write-Host "Outil introuvable : $outil"; exit 2 }
}
if ($ConfigSsh -and -not (Test-Path -LiteralPath $ConfigSsh -PathType Leaf)) {
    Write-Host "Configuration SSH introuvable : $ConfigSsh"; exit 2
}

# --- 2. Inventaire : paires complètes seulement --------------------------------------------
Write-Section "Captures dans $dossier"
$parNom = @{}
$signales = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ChildItem -LiteralPath $dossier -File | Sort-Object Name)) {
    if (($f.Extension -ceq '.html' -or $f.Extension -ceq '.json') -and $f.BaseName -cmatch $NomCapture) {
        if (-not $parNom.ContainsKey($f.BaseName)) { $parNom[$f.BaseName] = @{} }
        $parNom[$f.BaseName][$f.Extension] = $f
    } else {
        $signales.Add("$($f.Name) : nom hors format, laissé sur place")
    }
}
$paires = New-Object System.Collections.Generic.List[string]
foreach ($nom in @($parNom.Keys | Sort-Object)) {
    if ($parNom[$nom].ContainsKey('.html') -and $parNom[$nom].ContainsKey('.json')) {
        $paires.Add($nom)
    } else {
        $present = @($parNom[$nom].Keys)[0]
        $signales.Add("$nom$present : jumeau absent (orphelin ou capture en cours), laissé sur place")
    }
}
foreach ($s in $signales) { Write-Host "  signalé : $s" }
if ($paires.Count -eq 0) {
    Write-Host 'Aucune capture complète à envoyer. Aucune connexion ouverte.'
    exit 0
}
Write-Host "  $($paires.Count) capture(s) complète(s) à envoyer."

# --- 3. Destinations dans envoyees\ : aucun écrasement possible ----------------------------
$destinations = @{}
$occupees = New-Object System.Collections.Generic.List[string]
foreach ($nom in $paires) {
    $m = [regex]::Match($nom, $NomCapture)
    $mois = Join-Path $dossier ("envoyees\{0}-{1}" -f $m.Groups[2].Value, $m.Groups[3].Value)
    $destinations[$nom] = $mois
    foreach ($ext in '.html', '.json') {
        if (Test-Path -LiteralPath (Join-Path $mois "$nom$ext")) { $occupees.Add("$nom$ext") }
    }
}
if ($occupees.Count -gt 0) {
    Write-Host "Déjà présent dans envoyees\ : $($occupees -join ', ')"
    Write-Host 'Rien n''a été envoyé : examinez ces fichiers avant de relancer.'
    exit 2
}

# --- 4. Préparation du lot ------------------------------------------------------------------
$lot = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$travail = Join-Path $DossierTravail "books-envoi-$lot"
$preparation = Join-Path $travail 'lot'
$archive = Join-Path $travail 'lot.tar'
$listeNoms = Join-Path $travail 'noms.txt'
$sortie = Join-Path $travail 'sortie.txt'
$lanceur = Join-Path $travail 'envoi.cmd'
$code = 3
$transfertReussi = $false

New-Item -ItemType Directory -Path $preparation | Out-Null
try {
    $manifeste = New-Object System.Collections.Generic.List[string]
    $noms = New-Object System.Collections.Generic.List[string]
    $noms.Add('MANIFEST.sha256')
    foreach ($nom in $paires) {
        foreach ($ext in '.html', '.json') {
            $source = $parNom[$nom][$ext].FullName
            # Empreinte calculée sur l'original, en binaire : une copie altérée serait détectée par atlas
            $empreinte = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifeste.Add("$empreinte  $nom$ext")
            $noms.Add("$nom$ext")
            Copy-Item -LiteralPath $source -Destination $preparation
        }
    }
    [IO.File]::WriteAllText((Join-Path $preparation 'MANIFEST.sha256'), (($manifeste -join "`n") + "`n"), $Utf8SansBom)
    [IO.File]::WriteAllText($listeNoms, (($noms -join "`n") + "`n"), $Utf8SansBom)

    Push-Location -LiteralPath $preparation
    try { & $Tar --format ustar -c -f $archive -T $listeNoms } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "tar a échoué (code $LASTEXITCODE)" }

    # --- 5. Une seule connexion : réception, contrôle, inbox/, ingestion ---------------------
    # Redirections de cmd.exe : octets transmis tels quels. Seule la sortie normale est enregistrée ;
    # la sortie d'erreur reste à l'écran (questions de ssh : mot de passe, empreinte du serveur).
    $optionConfig = if ($ConfigSsh) { "-F `"$ConfigSsh`" " } else { '' }
    $ligne = "`"$Ssh`" $optionConfig$HoteSsh bash $DepotDistant/scripts/recevoir-captures.sh $lot < `"$archive`" > `"$sortie`""
    [IO.File]::WriteAllText($lanceur, "@echo off`r`n$ligne`r`nexit /b %ERRORLEVEL%`r`n", [Text.Encoding]::Default)

    Write-Section "Envoi du lot $lot vers $HoteSsh ($($paires.Count) capture(s))"
    Write-Host 'Saisissez le mot de passe d''atlas si ssh le demande.'
    & cmd.exe /d /c "`"$lanceur`""
    $codeSsh = $LASTEXITCODE
    $texte = if (Test-Path -LiteralPath $sortie) { [IO.File]::ReadAllText($sortie, $Utf8SansBom) } else { '' }

    Write-Section 'Réponse d''atlas'
    Write-Host $texte.TrimEnd()

    $transfert = [regex]::Match($texte, "(?m)^BOOKS:TRANSFERT:OK $lot ([0-9]+)\r?$")
    if (-not $transfert.Success -or [int]$transfert.Groups[1].Value -ne 2 * $paires.Count) {
        Write-Section 'Transfert échoué'
        Write-Host "Code de ssh : $codeSsh. Rien n'a été déplacé sur le PC : relancez l'envoi."
        Write-Host "Si atlas a reçu le lot, il est resté dans ~/books-data/captures/attente/$lot pour examen."
        $code = 3
    } else {
        # --- 6. Transfert réussi : les captures rejoignent envoyees\AAAA-MM\ ---------------------
        $transfertReussi = $true
        $deplaces = 0
        foreach ($nom in $paires) {
            New-Item -ItemType Directory -Force -Path $destinations[$nom] | Out-Null
            foreach ($ext in '.html', '.json') {
                Move-Item -LiteralPath $parNom[$nom][$ext].FullName -Destination (Join-Path $destinations[$nom] "$nom$ext")
                $deplaces++
            }
        }
        $ingestion = [regex]::Match($texte, '(?m)^BOOKS:INGESTION:CODE ([0-9]+)\r?$')
        $codeIngestion = if ($ingestion.Success) { [int]$ingestion.Groups[1].Value } else { -1 }

        Write-Section 'Résultat'
        Write-Host "Transfert réussi : $($paires.Count) capture(s) déposée(s) sur atlas, $deplaces fichier(s) rangé(s) dans envoyees\."
        if ($codeIngestion -eq 0) {
            Write-Host 'Ingestion sans anomalie.'
            $code = 0
        } elseif ($codeIngestion -eq 1) {
            Write-Host 'Ingestion avec anomalies : voir le bilan ci-dessus.'
            $code = 1
        } else {
            Write-Host "Ingestion non effectuée (code $codeIngestion) : les captures attendent dans inbox/ sur atlas,"
            Write-Host 'et seront ingérées à la prochaine ingestion.'
            $code = 1
        }
    }
}
catch {
    Write-Host "Erreur : $($_.Exception.Message)"
    if ($transfertReussi) {
        # Les captures sont déjà sur atlas : celles restées sur le PC repartiront et seront « déjà ingérées »
        Write-Host 'Transfert réussi, mais rangement dans envoyees\ incomplet : vérifiez le dossier des captures.'
        $code = 1
    } else {
        Write-Host 'Transfert non effectué : rien n''a été déplacé sur le PC.'
        $code = 3
    }
}
finally {
    Remove-Item -LiteralPath $travail -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
