# Image du collecteur B.O.O.K.S. : aucun secret n'y est copié (voir .dockerignore).
# La configuration arrive au lancement, par les variables d'environnement.
FROM python:3.12-slim

# Pas de fichiers .pyc, journaux affichés immédiatement, pas de cache pip dans l'image
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Utilisateur non-root, même UID que l'utilisateur d'atlas (1000),
# pour pouvoir écrire dans ~/books-data/raw monté en volume
RUN groupadd --gid 1000 books \
 && useradd --uid 1000 --gid books --no-create-home --shell /usr/sbin/nologin books

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN pip install . && rm -rf build

# Catégories à collecter : versionnées, intégrées à l'image (les modifier impose de reconstruire)
COPY config ./config
ENV BOOKS_TARGETS_FILE=/app/config/targets.toml

USER books
CMD ["python", "-m", "books.collector"]
