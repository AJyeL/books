# Réglage local du script de rapatriement de la sauvegarde (décision 009).
# Copier ce fichier en rapatrier-sauvegarde.local.psd1, à côté de lui, puis indiquer votre dossier.
# Le fichier .local.psd1 est ignoré par Git : votre chemin personnel n'entre jamais dans le dépôt public.
@{
    # Dossier (existant) où les copies de la base sont conservées sur ce PC ; rien n'y est jamais supprimé
    DossierSauvegardes = 'C:\Chemin\vers\books-sauvegardes'
    # Facultatif : fichier de configuration SSH particulier (par défaut : celui de l'utilisateur)
    # ConfigSsh = 'C:\Chemin\vers\ssh_config'
}
