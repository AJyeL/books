﻿# Réglage local du script d'envoi des rapports Amazon Ads (décision 018).
# Copier ce fichier en envoyer-ads.local.psd1, à côté de lui, puis indiquer votre dossier.
# Le fichier .local.psd1 est ignoré par Git : votre chemin personnel n'entre jamais dans le dépôt public.
@{
    # Dossier où vous déposez les rapports téléchargés depuis l'e-mail d'Amazon ; envoyes\ y sera créé.
    # Ne pas ouvrir les rapports dans Excel avant l'envoi : un réenregistrement change leur forme.
    DossierRapports = 'C:\Chemin\vers\books-rapports-ads'
    # Facultatif : fichier de configuration SSH particulier (par défaut : celui de l'utilisateur)
    # ConfigSsh = 'C:\Chemin\vers\ssh_config'
}
