from dictflow.bench import br_flags, wer


def test_wer_identical_and_normalised():
    assert wer("Olá, mundo!", "ola mundo") > 0  # accents are not stripped
    assert wer("Hello, World!", "hello   world") == 0


def test_wer_counts_edits():
    assert wer("a b c d", "a x c") == 0.5  # 1 substitution + 1 deletion
    assert wer("a b", "") == 1.0
    assert wer("", "") == 0.0


def test_br_flags_on_portuguese_reference():
    ref = "O facto é que a equipa precisa do contacto"
    assert br_flags(ref, "O fato é que a equipe precisa do contato") == ["contato", "fato"]
    assert br_flags(ref, "O facto é que a equipa precisa do contacto") == []


def test_br_flags_ignores_english_reference():
    assert br_flags("What time is the meeting for the team", "what time is it") == []
