# Réglage local du script de réception du guide de veille (décision 017).
# Copier ce fichier en recevoir-guide.local.psd1, à côté de lui, puis indiquer votre dossier.
# Le fichier .local.psd1 est ignoré par Git : votre chemin personnel n'entre jamais dans le dépôt public.
@{
    # Dossier (existant) où les guides reçus sont conservés sur ce PC ; rien n'y est jamais supprimé.
    # Jamais le dossier des captures de l'extension : l'envoi y signalerait le guide comme fichier hors format.
    DossierGuide = 'C:\Chemin\vers\books-guide'
    # Facultatif : fichier de configuration SSH particulier (par défaut : celui de l'utilisateur)
    # ConfigSsh = 'C:\Chemin\vers\ssh_config'
}
