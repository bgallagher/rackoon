"""The terminal's highlighting and reconnect rules: the Kotlin core's OutputHighlighterTests,
TerminalOutputFilterTests and ReconnectPolicyTests, case for case."""

from __future__ import annotations

import random

from rackoon.core.terminal import (
    HighlightKind,
    HighlightSpan,
    ReconnectPolicy,
    Retry,
    SessionEnd,
    TerminalOutputFilter,
    is_ipv6,
    resolve,
    spans,
)

ESC = "\x1b"


def found(s: str) -> list[tuple[str, HighlightKind]]:
    data = s.encode()
    return [(data[x.start:x.end].decode(), x.kind) for x in spans(s)]


# --- OutputHighlighterTests ---------------------------------------------------------------------------------------


def test_ipv4() -> None:
    r = found("IPv4 address for eth0: 89.167.95.123 and https://10.0.0.1:9090/ ok")
    assert [t for t, _ in r] == ["89.167.95.123", "10.0.0.1"]
    assert all(k is HighlightKind.IP_ADDRESS for _, k in r)


def test_ipv4_rejections() -> None:
    assert found("version 1.2.3 and 256.1.1.1 and 1.2.3.4.5 and 300.300.300.300") == []
    assert found("abc1.2.3.4") == []


def test_ipv6() -> None:
    assert [t for t, _ in found("IPv6 address for eth0: 2a01:4f9:c014:2ddc::1")] == ["2a01:4f9:c014:2ddc::1"]
    assert [t for t, _ in found("link fe80::1 up")] == ["fe80::1"]
    assert [t for t, _ in found("2001:0db8:0000:0000:0000:ff00:0042:8329")] == ["2001:0db8:0000:0000:0000:ff00:0042:8329"]
    assert not is_ipv6("1::2::3")


def test_ipv6_lookalikes_are_ignored() -> None:
    assert found("at 11:26:02 PM") == []
    assert found("mac aa:bb:cc:dd:ee:ff end") == []
    assert found("ratio 3:1") == []


def test_words() -> None:
    assert [k for _, k in found("Build FAILED: permission denied")] == [HighlightKind.ERROR, HighlightKind.ERROR]
    assert [k for _, k in found("warning: deprecated")] == [HighlightKind.WARNING]
    assert [k for _, k in found("Tests passed. Successfully installed")] == [HighlightKind.SUCCESS, HighlightKind.SUCCESS]
    assert found("errors: 0, terror, warned") == []


def test_percent_thresholds() -> None:
    assert [(t, k) for t, k in found("Usage of /: 91% of 37G")] == [("91%", HighlightKind.ERROR)]
    assert [(t, k) for t, k in found("disk 80%")] == [("80%", HighlightKind.WARNING)]
    assert found("cpu 43.1% of 37.23GB") == []
    assert [t for t, _ in found("use 99.5%")] == ["99.5%"]


def test_offsets_are_utf8_bytes_even_with_multibyte_text() -> None:
    s = "héllo 日本 10.0.0.1"
    sp = spans(s)
    assert len(sp) == 1 and s.encode()[sp[0].start:sp[0].end] == b"10.0.0.1"


def test_overlaps_keep_the_earlier_span() -> None:
    r = resolve([HighlightSpan(0, 5, HighlightKind.ERROR), HighlightSpan(3, 8, HighlightKind.WARNING),
                 HighlightSpan(8, 9, HighlightKind.SUCCESS)])
    assert [x.kind for x in r] == [HighlightKind.ERROR, HighlightKind.SUCCESS]


# --- TerminalOutputFilterTests ------------------------------------------------------------------------------------


def run(f: TerminalOutputFilter, s: str) -> str:
    return f.process(s.encode()).decode()


def strip_injected(s: str) -> str:
    for c in ("31", "32", "33", "35"):
        s = s.replace(f"{ESC}[{c}m", "")
    return s.replace(f"{ESC}[39m", "")


def test_colours_an_ip_in_plain_output() -> None:
    out = run(TerminalOutputFilter(), "IPv4 address for eth0: 89.167.95.123\r\nnext line\r\n")
    assert out == f"IPv4 address for eth0: {ESC}[35m89.167.95.123{ESC}[39m\r\nnext line\r\n"


def test_disabled_is_an_exact_pass_through() -> None:
    s = f"error at 10.0.0.1 {ESC}[1;31mred{ESC}[0m\r\n".encode()
    assert TerminalOutputFilter(enabled=False).process(s) == s


def test_leaves_program_coloured_text_alone() -> None:
    out = run(TerminalOutputFilter(), f"{ESC}[32mserver 10.0.0.1{ESC}[0m and 10.0.0.2\r\n")
    assert f"{ESC}[35m10.0.0.1" not in out
    assert f"{ESC}[35m10.0.0.2{ESC}[39m" in out


def test_background_and_256_colour_and_reverse_also_suppress() -> None:
    for start in (f"{ESC}[44m", f"{ESC}[38;5;196m", f"{ESC}[38;2;1;2;3m", f"{ESC}[7m", f"{ESC}[1;33;40m"):
        assert run(TerminalOutputFilter(), f"{start}10.0.0.1 \r\n") == f"{start}10.0.0.1 \r\n", start
    f = TerminalOutputFilter()
    run(f, f"{ESC}[7m")
    assert run(f, f"{ESC}[27m10.0.0.1 x") == f"{ESC}[27m{ESC}[35m10.0.0.1{ESC}[39m x"


def test_subparameter_forms_do_not_break_tracking() -> None:
    assert f"{ESC}[35m10.0.0.1" in run(TerminalOutputFilter(), f"{ESC}[38;5;196;0m10.0.0.1 x")


def test_alternate_screen_is_never_touched() -> None:
    out = run(TerminalOutputFilter(), f"{ESC}[?1049h10.0.0.1 error {ESC}[?1049l and 10.0.0.2 x")
    assert f"{ESC}[?1049h10.0.0.1 error {ESC}[?1049l" in out
    assert f"{ESC}[35m10.0.0.2{ESC}[39m" in out


def test_escape_sequences_pass_through_unchanged() -> None:
    s = f"{ESC}]0;root@10.0.0.1: ~\x07{ESC}(B{ESC}[2;5H{ESC}[K{ESC}Pq10.0.0.2{ESC}\\hello\r\n"
    assert run(TerminalOutputFilter(), s) == s


def test_chunk_edge_matches_are_skipped_not_mangled() -> None:
    f = TerminalOutputFilter()
    assert run(f, "ip 10.0.0.1") + run(f, "23 done\r\n") == "ip 10.0.0.123 done\r\n"


def test_typed_echo_byte_by_byte_is_unchanged() -> None:
    f = TerminalOutputFilter()
    assert "".join(run(f, ch) for ch in "ping 10.0.0.1\r\n") == "ping 10.0.0.1\r\n"


def test_multibyte_characters_split_across_chunks() -> None:
    f = TerminalOutputFilter()
    out = b"".join(f.process(bytes([b])) for b in "café 日本 10.0.0.1 x\r\n".encode()) + f.process(b"")
    assert strip_injected(out.decode()) == "café 日本 10.0.0.1 x\r\n"


def test_random_chunking_never_corrupts_output() -> None:
    corpus = ("System load: 0.44  Usage of /: 91% of 37G\r\nIPv4 address for eth0: 89.167.95.123\r\n"
              f"{ESC}[1;32mok{ESC}[0m build FAILED at 10.0.0.9\r\nIPv6: 2a01:4f9:c014:2ddc::1 warning: x\r\n"
              f"{ESC}]0;title 10.0.0.1\x07{ESC}[?1049hfull screen 1.2.3.4{ESC}[?1049l tail 8.8.8.8 \r\n")
    data = corpus.encode()
    rng = random.Random(42)
    for _ in range(300):
        f = TerminalOutputFilter()
        out = bytearray()
        i = 0
        while i < len(data):
            n = rng.randint(1, 9)
            out += f.process(data[i:i + n])
            i += n
        out += f.process(b"")
        assert strip_injected(out.decode()) == corpus


def test_state_is_tracked_while_disabled_so_enabling_mid_stream_is_correct() -> None:
    f = TerminalOutputFilter(enabled=False)
    assert run(f, f"{ESC}[?1049h") == f"{ESC}[?1049h"
    f.is_enabled = True
    assert run(f, "inside vim 10.0.0.1 x") == "inside vim 10.0.0.1 x"
    assert f"{ESC}[35m10.0.0.2" in run(f, f"{ESC}[?1049l back 10.0.0.2 x")
    g = TerminalOutputFilter(enabled=False)
    run(g, f"{ESC}[32m")
    g.is_enabled = True
    assert run(g, "10.0.0.1 x") == "10.0.0.1 x"


def test_disabled_filter_is_an_exact_identity_for_arbitrary_bytes() -> None:
    rng = random.Random(7)
    f = TerminalOutputFilter(enabled=False)
    specials = f"{ESC}[0m{ESC}]0;t\x07{ESC}[?1049h 10.0.0.1 error 99%\r\n".encode()
    for _ in range(3000):
        n = rng.randint(0, 80)
        chunk = bytes(specials[rng.randrange(len(specials))] if rng.random() < 0.5 else rng.randrange(256)
                      for _ in range(n))
        assert f.process(chunk) == chunk


def test_fast_path_does_not_lose_state_across_an_escape_later() -> None:
    f = TerminalOutputFilter(enabled=False)
    assert run(f, "plain text with no escapes at all\r\n") == "plain text with no escapes at all\r\n"
    run(f, f"{ESC}[?1049h")
    assert run(f, "10.0.0.1 more plain bytes") == "10.0.0.1 more plain bytes"
    f.is_enabled = True
    assert run(f, "10.0.0.1 x") == "10.0.0.1 x"


def test_disabled_filter_holds_nothing_back() -> None:
    f = TerminalOutputFilter(enabled=False)
    euro = "€".encode()
    assert f.process(euro[:2]) == euro[:2]
    assert f.finish() == b""


def test_finish_releases_a_held_back_partial_character() -> None:
    f = TerminalOutputFilter()
    euro = "€".encode()
    assert f.process(euro[:2]) == b""
    assert f.finish() == euro[:2]
    assert f.finish() == b""


def test_garbage_input_never_crashes() -> None:
    rng = random.Random(1)
    f = TerminalOutputFilter()
    for _ in range(2000):
        f.process(bytes(rng.randrange(256) for _ in range(rng.randint(0, 64))))


# --- ReconnectPolicyTests -----------------------------------------------------------------------------------------


def retry(p: ReconnectPolicy, connected: float = 0) -> Retry | None:
    return p.on_ended(SessionEnd.CONNECTION_LOST, connected)


def test_backs_off_through_five_attempts_then_gives_up() -> None:
    p = ReconnectPolicy()
    delays = []
    for _ in range(5):
        r = retry(p)
        assert r is not None
        delays.append(r.delay_seconds)
    assert delays == [1, 2, 4, 8, 15]
    assert retry(p) is None


def test_reports_the_attempt_number() -> None:
    p = ReconnectPolicy()
    assert retry(p) == Retry(1, 1, 5)
    assert retry(p) == Retry(2, 2, 5)


def test_only_a_lost_connection_is_retried() -> None:
    p = ReconnectPolicy()
    assert p.on_ended(SessionEnd.REMOTE_EXIT, 60) is None
    assert p.on_ended(SessionEnd.CLOSED_BY_USER, 60) is None
    assert retry(p) == Retry(1, 1, 5), "the budget was untouched"


def test_a_session_that_lasted_ten_seconds_earns_a_fresh_budget() -> None:
    p = ReconnectPolicy()
    for _ in range(4):
        retry(p)
    assert retry(p, connected=10) == Retry(1, 1, 5)
    assert retry(p, connected=9.999) == Retry(2, 2, 5)


def test_reset_forgets_earlier_failures() -> None:
    p = ReconnectPolicy()
    for _ in range(3):
        retry(p)
    p.reset()
    assert retry(p) == Retry(1, 1, 5)
