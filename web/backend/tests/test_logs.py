"""Log lines: the Kotlin core's LogBuffer and LogLineParser/LogParts cases, plus the streamed-run result."""

from __future__ import annotations

from rackoon.core import logs
from rackoon.core.logs import LogBuffer, LogLevel, LogParts
from rackoon.core.stream import StreamedRun, strip_ansi


def test_lines_split_across_chunks_are_joined_and_endings_normalised() -> None:
    b = LogBuffer()
    assert b.append("hello wo") == []
    assert b.append("rld\r\nsecond") == ["hello world"]
    assert b.append(" line\r\n") == ["second line"]
    assert b.append("Connection to host closed.\r\n") == [], "ssh's own goodbye is not a log line"
    assert b.lines == ["hello world", "second line"]


def test_the_buffer_is_capped_but_total_keeps_counting() -> None:
    b = LogBuffer(max_lines=10)
    for i in range(1, 51):
        b.append(f"line {i}\n")
    assert len(b.lines) == 10 and b.total_appended == 50 and b.lines[-1] == "line 50"


def test_levels_only_from_explicit_markers() -> None:
    assert logs.level("2026-10-12T07:15:02Z INFO a1") is LogLevel.INFO
    assert logs.level("2026-10-12T07:15:03Z ERROR a2") is LogLevel.ERROR
    assert logs.level("level=warn msg=slow") is LogLevel.WARN
    assert logs.level('{"level":"debug","msg":"x"}') is LogLevel.DEBUG
    assert logs.level("[error] nope") is LogLevel.ERROR
    assert logs.level("plain line with the word error in prose") is None


def test_a_row_shows_time_level_and_message_separately() -> None:
    assert logs.parts("2026-10-12T07:15:02Z INFO started") == LogParts("2026-10-12T07:15:02Z", LogLevel.INFO, "started")
    assert logs.parts("2026-10-12T07:15:03Z ERROR boom: connection refused") == \
        LogParts("2026-10-12T07:15:03Z", LogLevel.ERROR, "boom: connection refused")
    assert logs.parts('level=warn msg="slow query"') == LogParts(None, LogLevel.WARN, 'msg="slow query"')
    assert logs.parts("plain line with the word error in prose") == \
        LogParts(None, None, "plain line with the word error in prose")
    assert logs.parts("2026-10-12T07:15:03Z job ERROR handler ran").message == "job ERROR handler ran"
    assert logs.timestamp_length("10:42:07.123 hi") == len("10:42:07.123")


def test_streamed_run_failure_messages_and_ansi() -> None:
    assert StreamedRun(0, False, None, "").failure_message("docker compose up") is None
    assert StreamedRun(1, False, None, "").failure_message("docker compose up") == \
        "docker compose up failed (exit 1). The output shows why."
    assert StreamedRun(None, True, None, "").failure_message("x") == "Cancelled. The command was interrupted on the server."
    assert StreamedRun(None, False, "ssh died", "").failure_message("x") == "ssh died"
    assert StreamedRun(None, False, None, "").failure_message("x") == "The connection ended before x reported a result."
    assert strip_ansi("\x1b[1;32m✔\x1b[0m Container web\r  Started\x1b(B") == "✔ Container web  Started"
