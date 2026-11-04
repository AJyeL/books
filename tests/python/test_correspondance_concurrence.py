"""Appels concurrents de mapping.code_for (migration 010, décision 019) contre un PostgreSQL 17 jetable, sous le rôle
books_transformer : deux connexions demandent le code du même texte au même moment. Un script SQL ne tourne que dans
une session et ne peut pas le vérifier (tests/sql/test_010_correspondance.sql couvre le reste).

Lancement : bash tests/lancer-tests-postgres.sh (sinon, ces tests sont sautés).
"""

import threading
import time

import psycopg
import pytest

KEY = "terme Sentinelle concurrence"  # clé inventée
CALL = "SELECT mapping.code_for('search_term', %s)"


def attendre_le_blocage(pg, conn) -> None:
    """Attend que la connexion soit bloquée par un verrou (la première transaction n'est pas terminée)."""
    pid = conn.info.backend_pid
    for _ in range(100):
        if pg.query("SELECT wait_event_type FROM pg_stat_activity WHERE pid = %s", (pid,)) == [("Lock",)]:
            return
        time.sleep(0.1)
    pytest.fail("la seconde connexion n'a pas attendu la première")


def appel_en_fond(conn) -> tuple[threading.Thread, dict]:
    """Lance l'appel de la seconde connexion dans un fil séparé ; le résultat ou l'erreur arrive dans le dict."""
    result = {}

    def call():
        try:
            result["code"] = conn.execute(CALL, (KEY,)).fetchone()[0]
        except psycopg.Error as error:
            result["error"] = error

    thread = threading.Thread(target=call)
    thread.start()
    return thread, result


def lignes(pg) -> list[tuple]:
    return pg.query("SELECT code FROM mapping.text_code WHERE nature = 'search_term' AND key = %s", (KEY,))


def test_appels_concurrents_meme_code(pg):
    with pg.connect_transformer() as first, pg.connect_transformer() as second:
        first.execute("BEGIN")
        (code,) = first.execute(CALL, (KEY,)).fetchone()  # ligne insérée, non validée
        thread, result = appel_en_fond(second)
        attendre_le_blocage(pg, second)
        first.execute("COMMIT")
        thread.join(10)
        assert not thread.is_alive()
        assert result == {"code": code}
    assert lignes(pg) == [(code,)]


def test_premiere_transaction_annulee(pg):
    with pg.connect_transformer() as first, pg.connect_transformer() as second:
        first.execute("BEGIN")
        (abandoned,) = first.execute(CALL, (KEY,)).fetchone()
        thread, result = appel_en_fond(second)
        attendre_le_blocage(pg, second)
        first.execute("ROLLBACK")
        thread.join(10)
        assert not thread.is_alive()
        assert "error" not in result
        assert result["code"] != abandoned  # la seconde crée sa propre ligne ; la séquence ne revient pas en arrière
    assert lignes(pg) == [(result["code"],)]


def test_isolation_repeatable_read_erreur_explicite(pg):
    with pg.connect_transformer() as first, pg.connect_transformer() as second:
        first.execute("BEGIN")
        (code,) = first.execute(CALL, (KEY,)).fetchone()
        second.execute("BEGIN ISOLATION LEVEL REPEATABLE READ")
        second.execute("SELECT 1")  # instantané pris avant la validation de la première transaction
        thread, result = appel_en_fond(second)
        attendre_le_blocage(pg, second)
        first.execute("COMMIT")
        thread.join(10)
        assert not thread.is_alive()
        error = result.get("error")
        assert isinstance(error, psycopg.errors.SerializationFailure), result
        assert "sentinelle" not in str(error).lower()  # le message ne recopie pas la clé
        second.execute("ROLLBACK")
    assert lignes(pg) == [(code,)]
