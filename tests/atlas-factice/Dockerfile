# Faux atlas, pour tester scripts/envoyer-captures.ps1 sans le vrai serveur (tests uniquement).
# Serveur SSH, utilisateur arnaud (UID 1000) au mot de passe de test, disposition des dossiers d'atlas,
# et faux « docker » (tests/shell/faux-docker) à la place du collecteur.
# Construction, depuis le dossier du dépôt : docker build -t books-atlas-factice -f tests/atlas-factice/Dockerfile tests
# scripts/recevoir-captures.sh est monté en lecture seule au lancement (version en cours du dépôt).
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && useradd --uid 1000 --create-home --shell /bin/bash arnaud \
 && echo 'arnaud:mot-de-passe-de-test' | chpasswd \
 && mkdir -p /home/arnaud/books/scripts \
             /home/arnaud/books-data/captures/attente \
             /home/arnaud/books-data/captures/inbox \
             /home/arnaud/books-data/captures/quarantaine \
 && chown -R arnaud:arnaud /home/arnaud \
 && chmod 700 /home/arnaud/books-data/captures /home/arnaud/books-data/captures/*

COPY shell/faux-docker /usr/local/bin/docker
RUN chmod 755 /usr/local/bin/docker

CMD ["/usr/sbin/sshd", "-D", "-e"]
