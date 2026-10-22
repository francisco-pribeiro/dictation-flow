import pytest


@pytest.fixture(autouse=True)
def _isolated_dictionary(tmp_path, monkeypatch):
    """Never read or write the real ~/Library dictionary from tests."""
    monkeypatch.setenv("DICTFLOW_DICTIONARY", str(tmp_path / "dictionary.txt"))
