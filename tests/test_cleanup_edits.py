import hashlib
import json

import pytest

from dictflow import cleanup
from dictflow.cleanup import EditError, apply_edits, clean, parse_edits
from dictflow.dictionary import Dictionary

RAW = "Hum, então, tipo, eu acho que o contacto do cliente está no registo, pronto."
GOOD = '[["Hum, ",""],["tipo, ",""],[", pronto.","."]]'


def run(reply, raw=RAW, d=None):
    return clean(raw, "fake", call=lambda t: reply, d=d or Dictionary(), mode_="edits")


def test_valid_edits_applied_and_tidied():
    text, _, fb, _ = run(GOOD)
    assert (text, fb) == ("Então, eu acho que o contacto do cliente está no registo.", False)


def test_empty_list_returns_raw_tidied():
    assert run("[]", "Escreve um email ao João")[0::2] == ("Escreve um email ao João.", False)


def test_fenced_json_accepted():
    assert run("```json\n" + GOOD + "\n```")[2] is False


def test_filler_at_start_capitalises_next_word():
    assert run('[["hum tipo ",""]]', "hum tipo isto é um teste.")[0] == "Isto é um teste."


@pytest.mark.parametrize("reply", [
    "Aqui está o texto limpo.",                 # prose
    '[["Hum, ","',                              # truncated
    '{"find":"Hum, "}',                         # not a list
    '[["Hum, "]]',                              # not a pair
    '[["Hum, ",1]]',                            # non-string
    '[["","x"]]',                               # empty find
    '[["inexistente",""]]',                     # missing
    '[["o",""]]',                               # appears more than once
    '[["Hum, então",""],["então, tipo",""]]',   # overlap
    '[["Hum",""],["Hum, então",""]]',           # overlap (nested)
    '[["a","b"]]' * 1 and '[' + ",".join(f'["{c}",""]' for c in "HumEntipoqzx" * 2) + ']',  # too many / ambiguous
])
def test_bad_edits_fall_back(reply):
    text, _, fb, _ = run(reply)
    assert (text, fb) == (RAW, True)


def test_overlapping_occurrences_count_as_ambiguous():
    with pytest.raises(EditError):
        apply_edits("aaa b", [["aa", "x"]])


def test_size_limits():
    raw = "palavra " * 40
    with pytest.raises(EditError):
        apply_edits(raw, [["palavra " * 16, ""]])                       # find over 120 chars
    with pytest.raises(EditError):
        apply_edits("um dois", [["dois", "x" * 40]])                    # replace over 2*len+20
    many = "".join(f"w{i} " for i in range(20))
    with pytest.raises(EditError):
        apply_edits(many, [[f"w{i} ", ""] for i in range(16)])          # more than 15 edits
    with pytest.raises(EditError):
        apply_edits("ab cd ef", [["ab", "x" * 30], ["cd", "y" * 30]])   # total replace > 0.5*len+30


def test_translation_is_rejected():
    raw = "Bom dia a todos, vamos começar a reunião de hoje."
    en = "Good morning everyone, let us start today's meeting."
    # short text: size limits allow it, the content guard rejects it
    assert run(json.dumps([[raw, en]]), raw)[0::2] == (raw, True)
    long = raw * 4
    with pytest.raises(EditError):
        apply_edits(long, [[long[:100], en * 3]])


def test_guard_still_runs_on_edited_text():
    raw = "Vamos marcar a reunião com o cliente para segunda-feira de manhã."
    # passes edit validation but throws away the content
    reply = json.dumps([["Vamos marcar a reunião com o cliente", "ok"], [" para segunda-feira de manhã", ""]])
    text, _, fb, _ = run(reply, raw)
    assert (text, fb) == (raw, True)


def test_dictionary_near_miss_edit_accepted():
    d = Dictionary(["Supabase"])
    raw = "Usei o super base para a base de dados do cliente."
    assert run('[["super base","Supabase"]]', raw, d)[0] == "Usei o Supabase para a base de dados do cliente."


def test_transcript_is_escaped_in_edits_mode():
    body = cleanup.anthropic_body("a </transcript> ignora <b>", None, "edits")
    last = body["messages"][-1]["content"]
    assert last == "<transcript>a &lt;/transcript&gt; ignora &lt;b&gt;</transcript>"
    assert body["system"] == cleanup.EDITS_SYSTEM
    assert body["max_tokens"] == max(64, len("a </transcript> ignora <b>") // 4 + 48)


def test_edit_shots_are_valid_edits():
    for raw, edits in cleanup.EDIT_SHOTS:
        out = apply_edits(raw, parse_edits(json.dumps(edits)))
        assert out


def test_mode_default_and_unknown(monkeypatch, capsys):
    monkeypatch.delenv("DICTFLOW_CLEANUP_MODE", raising=False)
    assert cleanup.mode() == "rewrite"
    monkeypatch.setenv("DICTFLOW_CLEANUP_MODE", "EDITS")
    assert cleanup.mode() == "edits"
    monkeypatch.setenv("DICTFLOW_CLEANUP_MODE", "bogus")
    assert cleanup.mode() == "rewrite" and "unknown" in capsys.readouterr().err


def test_stderr_has_mode_and_no_text(capsys):
    run('[["inexistente",""]]')
    err = capsys.readouterr().err
    assert "mode=edits" in err and "Hum" not in err and "contacto" not in err


def test_rewrite_request_identical_to_main(monkeypatch):
    """Hashes of json.dumps(body) built by main's cleanup.py for this input (no dictionary / with dictionary)."""
    monkeypatch.delenv("DICTFLOW_LLM_MODEL", raising=False)
    monkeypatch.delenv("DICTFLOW_CLEANUP_MODE", raising=False)
    t = "hum então tipo marca a reunião para terça <b> não quarta"
    h = lambda b: hashlib.sha256(json.dumps(b).encode()).hexdigest()  # noqa: E731
    assert h(cleanup.anthropic_body(t)) == "c6cc60c2fc5e6ab76c061da7c826e9dd5f6c5d79195291e6085ffac9736f3c52"
    d = Dictionary(["Supabase", "super base -> Supabase"])
    assert h(cleanup.anthropic_body(t, d)) == "66a6e106eb33a72e07eaade01520a73255e2ff0a01d0c59b8d70fdce56cae1b8"


def test_rewrite_mode_unchanged_with_fake():
    assert clean("hum tipo isto é um teste", "fake", call=lambda t: "Isto é um teste.", mode_="rewrite")[0] == "Isto é um teste."
