"""Tests de books.collector.lock : une seule ingestion à la fois, verrou libéré à la fin du processus."""

import signal
import subprocess
import sys

import pytest

from books.collector.ingestion import ingest
from books.collector.lock import LOCK_NAME, LockBusy, ingestion_lock

# Second processus : prend le verrou, l'annonce, puis attend qu'on le termine
HOLDER = """
import sys, time
from pathlib import Path
from books.collector.lock import ingestion_lock
with ingestion_lock(Path(sys.argv[1])):
    print("pris", flush=True)
    time.sleep(60)
"""


@pytest.fixture
def holder(tmp_path):
    """Lance un autre processus qui tient le verrou ; renvoie le processus."""
    process = subprocess.Popen([sys.executable, "-c", HOLDER, str(tmp_path)], stdout=subprocess.PIPE, text=True)
    assert process.stdout.readline().strip() == "pris"
    yield process
    if process.poll() is None:
        process.kill()
    process.wait()


def test_verrou_libre(tmp_path):
    with ingestion_lock(tmp_path) as path:
        assert path == tmp_path / LOCK_NAME
    with ingestion_lock(tmp_path):  # rendu à la sortie du bloc : reprenable
        pass


def test_second_preneur_refuse(tmp_path, holder):
    with pytest.raises(LockBusy, match="ingestion déjà en cours"):
        with ingestion_lock(tmp_path):
            pass


def test_verrou_rendu_a_la_fin_normale(tmp_path, holder):
    holder.terminate()
    holder.wait()
    with ingestion_lock(tmp_path):
        pass


def test_verrou_rendu_meme_si_le_processus_est_tue(tmp_path, holder):
    holder.send_signal(signal.SIGKILL)  # arrêt brutal, comme un plantage : aucun nettoyage possible
    holder.wait()
    with ingestion_lock(tmp_path):  # le noyau a rendu le verrou
        pass
    assert (tmp_path / LOCK_NAME).exists()  # le fichier reste, vide et inoffensif


def test_verrou_rendu_meme_en_cas_d_erreur(tmp_path):
    with pytest.raises(RuntimeError):
        with ingestion_lock(tmp_path):
            raise RuntimeError("panne")
    with ingestion_lock(tmp_path):
        pass


def test_fichier_de_verrou_hors_de_inbox(tmp_path):
    # Le verrou vit à côté de inbox/ : l'ingestion ne le voit pas comme un fichier hors format
    from test_ingestion import FakeRepo
    (tmp_path / "inbox").mkdir()
    (tmp_path / "raw").mkdir()
    with ingestion_lock(tmp_path):
        result = ingest(tmp_path, FakeRepo(), tmp_path / "raw", "0.1.0", log=lambda m: None)
    assert result.status == "success"
    assert result.report.left_in_place == [] and result.report.quarantined == []
