"""The sudo password flow, apt actions, the Updates screen's rules and the reboot rules: the Swift core's
SudoElevationTests, SudoHandshakeTests, ElevationWindowTests, AptActionTests and RebootTests (sudo exists only in the
Swift core so far), with the real-shell checks run through /bin/sh and stub programs."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from rackoon.core import apt, reboot, spec, sudo
from rackoon.core.apt import AptAction
from rackoon.core.stream import StreamedRun
from rackoon.core.updates import PendingUpdate, UpdatesSnapshot

NONCE = "0123456789abcdef0123456789abcdef"
PROMPT = f"##rackoon-sudo-{NONCE}:"
OK = f"##rackoon-sudo-ok-{NONCE}"
FAIL = f"##rackoon-sudo-fail-{NONCE}"
# sudo-rs (Ubuntu 26.04) over a pty: the prompt is wrapped, typed characters echo as asterisks and are erased.
SUDO_RS_PROMPT = f"[sudo: {PROMPT}] Password: ****\b \b\b \b\b \b\b \b\r\n"


def stubs(tmp: Path, programs: dict[str, str]) -> dict[str, str]:
    for name, body in programs.items():
        f = tmp / name
        f.write_text(f"#!/bin/sh\n{body}\n")
        f.chmod(0o755)
    return {**os.environ, "PATH": f"{tmp}:/usr/bin:/bin"}


# --- the password prefix ----------------------------------------------------------------------------------------


def test_the_password_variant_is_the_prefix_in_front_of_the_unchanged_script() -> None:
    plain = AptAction("upgrade_all").command
    assert plain is not None
    elevated = sudo.with_password(plain, NONCE)
    assert elevated is not None and elevated.endswith(plain), "the script itself still uses sudo -n"
    assert elevated.startswith(f"if [ \"$(id -u)\" -ne 0 ]; then mesg n 2>/dev/null; stty -echo 2>/dev/null; "
                               f"sudo -p '{PROMPT}' -v"), "mesg n first: nobody can write into the session"
    assert sudo.with_password("docker ps", NONCE) is None, "a script without $S has no password variant"
    assert sudo.with_password(plain, "x'; reboot; '") is None, "a malformed nonce never reaches the shell"
    refresh = AptAction("refresh")
    assert refresh.password_intent(NONCE) != refresh.intent, "its own intent and confirmation"
    assert refresh.password_intent(NONCE) == refresh.password_intent(NONCE)
    assert refresh.password_intent(NONCE) != refresh.password_intent(sudo.make_nonce())


def test_nonces_are_random_hex_and_the_prefix_is_the_specs() -> None:
    a, b = sudo.make_nonce(), sudo.make_nonce()
    assert sudo.is_nonce(a) and a != b and not sudo.is_nonce("ABCDEF0123456789abcdef0123456789")
    assert sudo.prefix() == spec.script("sudo_prompt")


def test_the_prefix_in_a_real_shell(tmp_path: Path) -> None:
    """A wrong password (the stub exits 1) never runs the script and prints the fail marker with exit 7."""
    script = sudo.with_password("S='sudo -n'; echo script-ran", NONCE)
    assert script is not None
    for stub_exit, expected, code in ((0, f"sudo-args: -p {PROMPT} -v\n{OK}\nscript-ran\n", 0),
                                      (1, f"sudo-args: -p {PROMPT} -v\n{FAIL}\n", 7)):
        env = stubs(tmp_path, {"sudo": f'echo "sudo-args: $*"\nexit {stub_exit}', "id": "echo 1000"})
        p = subprocess.run(["/bin/sh", "-c", script], capture_output=True, text=True, env=env, timeout=30)
        assert (p.stdout, p.returncode) == (expected, code)


def test_refusals_from_classic_sudo_and_sudo_rs() -> None:
    assert sudo.needs_password("sudo: a password is required\n")
    assert sudo.needs_password("sudo: a terminal is required to read the password; either use the -S option")
    assert sudo.needs_password("sudo: interactive authentication is required"), "sudo-rs, Ubuntu 26.04"
    assert not sudo.needs_password("E: Could not get lock /var/lib/dpkg/lock-frontend")
    assert "not allowed to use sudo" in sudo.explain_refusal("lab is not in the sudoers file.")
    assert sudo.is_auth_failure("sudo: 1 incorrect password attempt")
    assert sudo.is_auth_failure("sudo: Authentication failed, try again.")
    assert not sudo.is_auth_failure("Reading package lists... Done")
    assert "terminal" in sudo.explain_refusal("sudo: sorry, you must have a tty to run sudo")
    assert sudo.is_sudo_auth_failure("Sorry, try again.\nsudo: 1 incorrect password attempt\n")
    assert not sudo.is_sudo_auth_failure("unauthorized: authentication required\n"), "a registry's words don't count"


# --- the handshake ------------------------------------------------------------------------------------------------


def handshake(chunks: list[str]) -> tuple[str, list[str], sudo.SudoOutcome | None]:
    h = sudo.SudoHandshake(NONCE)
    shown, actions = "", []
    for c in chunks:
        s, a = h.push(c)
        shown += s
        actions += a
    shown += h.finish()
    return shown, actions, h.outcome


def test_right_password_with_sudo_rs_shows_no_asterisks() -> None:
    shown, actions, outcome = handshake([SUDO_RS_PROMPT, "\r\n", f"{OK}\r\n", "Reading package lists... Done\r\n"])
    assert actions == [sudo.TYPE_PASSWORD] and outcome == sudo.ACCEPTED
    assert shown == sudo.SudoHandshake.NOTICE + "\r\nReading package lists... Done\r\n"
    assert "*" not in shown, "the password's length must not show"


def test_right_password_with_classic_sudo_and_root_without_a_prompt() -> None:
    shown, actions, outcome = handshake([PROMPT, "\r\n", f"{OK}\r\n", "done\r\n"])
    assert (shown, actions, outcome) == (sudo.SudoHandshake.NOTICE + "done\r\n", [sudo.TYPE_PASSWORD], sudo.ACCEPTED)
    assert handshake([f"{OK}\r\n", "output\r\n"]) == ("output\r\n", [], sudo.ACCEPTED)


def test_a_wrong_password_is_typed_once_then_interrupted() -> None:
    shown, actions, outcome = handshake([SUDO_RS_PROMPT, "sudo: Authentication failed, try again.\r\n",
                                         f"[sudo: {PROMPT}] Password: "])
    assert actions == [sudo.TYPE_PASSWORD, sudo.INTERRUPT], "never typed a second time"
    assert outcome == sudo.REJECTED and "Authentication failed" in shown and "not accepted" in shown
    _, actions, outcome = handshake([PROMPT, "\r\n", "sudo: 1 incorrect password attempt\r\n", f"{FAIL}\r\n"])
    assert actions == [sudo.TYPE_PASSWORD] and outcome == sudo.REJECTED, "passwd_tries=1 is a wrong password too"


def test_a_second_question_without_a_failure_is_not_a_wrong_password() -> None:
    shown, actions, outcome = handshake([SUDO_RS_PROMPT, f"[sudo: {PROMPT}] Verification code: "])
    assert actions == [sudo.TYPE_PASSWORD, sudo.INTERRUPT] and outcome == sudo.OTHER and "not accepted" not in shown


def test_refused_for_another_reason_carries_what_sudo_said() -> None:
    _, actions, outcome = handshake(["lab is not in the sudoers file.\r\n", f"{FAIL}\r\n"])
    assert actions == [] and outcome == sudo.SudoOutcome("refused", "lab is not in the sudoers file.")


def test_prompts_after_the_ok_marker_are_never_answered() -> None:
    """Text the script prints (a journal line, a user name) carrying a prompt marker after sudo finished."""
    shown, actions, outcome = handshake([PROMPT, "\r\n", f"{OK}\r\n", f"Oct 13 sshd: Invalid user {PROMPT} from x\r\n",
                                         f"[sudo: {PROMPT}] Password: \r\n", "sudo: Authentication failed, try again.\r\n"])
    assert actions == [sudo.TYPE_PASSWORD] and outcome == sudo.ACCEPTED
    assert f"Invalid user {PROMPT}" in shown


def test_markers_with_another_nonce_are_just_text_and_an_early_end_is_unfinished() -> None:
    other = "##rackoon-sudo-ffffffffffffffffffffffffffffffff:"
    shown, actions, _ = handshake([f"{other}\r\n", PROMPT, "\r\n", f"{OK}\r\n"])
    assert actions == [sudo.TYPE_PASSWORD] and shown.startswith(other)
    assert handshake(["Connection closed.\r\n"])[2] == sudo.UNFINISHED


def test_the_handshake_split_at_every_point() -> None:
    text = SUDO_RS_PROMPT + f"{OK}\r\nafter\r\n"
    for cut in range(1, len(text)):
        assert handshake([text[:cut], text[cut:]]) == (sudo.SudoHandshake.NOTICE + "after\r\n", [sudo.TYPE_PASSWORD],
                                                       sudo.ACCEPTED), cut


def test_streamed_run_sudo_verdicts() -> None:
    assert StreamedRun(0, False, None, "sudo: interactive authentication is required\r\n").needs_sudo_password, \
        "recognised even when the pipeline exits 0"
    every = StreamedRun(1, False, None, "sudo: interactive authentication is required\r\n", sudo.ACCEPTED)
    assert every.sudo_asks_every_time and not every.needs_sudo_password and every.sudo_problem == sudo.ASKS_EVERY_TIME
    other = StreamedRun(None, False, None, "", sudo.OTHER)
    assert not other.needs_sudo_password and other.sudo_problem == sudo.OTHER_PROMPT
    rejected = StreamedRun(None, False, None, "", sudo.REJECTED)
    assert rejected.needs_sudo_password and rejected.sudo_problem and "not accept" in rejected.sudo_problem


# --- Docker through sudo ------------------------------------------------------------------------------------------


def test_elevated_commands_reach_the_inner_shell_unchanged() -> None:
    for script in ["echo '##docker'; docker ps -a", "cd '/srv/it'\"'\"'s' && docker compose -p a up -d",
                   "echo \"$HOME\" '$x' `id`"]:
        wrapped = sudo.elevated(script)
        assert wrapped is not None and wrapped.startswith("sudo -S -p '' sh -c '")
        inner = wrapped.removeprefix("sudo -S -p '' sh -c ")
        p = subprocess.run(["/bin/sh", "-c", "printf '%s' " + inner], capture_output=True, text=True, timeout=10)
        assert p.stdout == script
    assert sudo.elevated("echo a\x00b") is None
    stream = sudo.elevated_stream("docker logs -f --tail 100 abcdef012345", NONCE)
    assert stream is not None and stream.endswith("sudo -n sh -c 'docker logs -f --tail 100 abcdef012345'")
    assert f"sudo -p '{PROMPT}' -v" in stream


def test_the_elevation_window() -> None:
    w = sudo.ElevationWindow(900)
    assert w.active("a", 0) is None and sudo.ElevationWindow.DEFAULT_LENGTH == 15 * 60
    w.unlock("a", "pw", 0)
    unlock = w.active("a", 899)
    assert unlock is not None and unlock.password == "pw"
    assert w.active("a", 900) is None, "expired exactly at the end, never later"
    assert w.active("b", 0) is None and "pw" not in repr(unlock), "per server; never printed"
    w.lock("a", "rejected")
    assert w.active("a", 0) is None and w.lock_reasons["a"] == "rejected"
    w.unlock("a", "pw2", 0)
    assert "a" not in w.lock_reasons and w.generation("a") == 3
    w.lock("b", "nothing to lock")
    assert w.generation("b") == 0 and "b" not in w.lock_reasons


# --- apt ----------------------------------------------------------------------------------------------------------


def test_apt_commands_come_from_the_spec_and_never_remove() -> None:
    assert AptAction("refresh").command == spec.script("apt_refresh")
    assert AptAction("upgrade_all").command == spec.script("apt_upgrade")
    c = AptAction("upgrade", ("openssl", "libssl3t64", "g++-13")).command
    assert c is not None and c.endswith("install --only-upgrade -y -o Dpkg::Options::=--force-confold openssl "
                                        "libssl3t64 g++-13")
    for a in (AptAction("refresh"), AptAction("upgrade_all"), AptAction("upgrade", ("openssl",))):
        cmd = a.command or ""
        assert not any(w in cmd for w in ("dist-upgrade", "remove", "purge", "autoremove"))
        assert "DEBIAN_FRONTEND=noninteractive" in cmd and "sudo -n" in cmd


def test_package_lists_are_deduplicated_capped_and_validated() -> None:
    assert (AptAction("upgrade", ("openssl", "curl", "openssl")).command or "").endswith(" openssl curl")
    many = tuple(f"pkg-{i}" for i in range(apt.MAX_PACKAGES))
    assert AptAction("upgrade", many).command is not None
    assert AptAction("upgrade", many + ("one-more",)).command is None
    for bad in ("", "a", "Openssl", "-o", "foo;reboot", "foo bar", "$(id)", "a\nb", "foo|bar", "a`b`", "ünï"):
        assert AptAction("upgrade", (bad,)).command is None, bad
    assert AptAction("upgrade", ()).command is None
    assert AptAction("upgrade", ("openssl", "x;y")).command is None, "one bad name rejects the whole list"
    assert AptAction("upgrade", ("libstdc++6", "python3.12", "0ad")).command is not None


def test_a_real_shell_picks_sudo_only_when_not_root(tmp_path: Path) -> None:
    for uid, expected in (("0", "apt-get-args: update"), ("1000", "sudo-args: -n env")):
        env = stubs(tmp_path, {"id": f"echo {uid}", "sudo": 'echo "sudo-args: $*"', "apt-get": 'echo "apt-get-args: $*"'})
        p = subprocess.run(["/bin/sh", "-c", AptAction("refresh").command or ""], capture_output=True, text=True,
                           env=env, timeout=30)
        assert p.stdout.startswith(expected), p.stdout


def test_apt_failures_are_explained() -> None:
    assert "without a password" in apt.explain("", "sudo: a password is required\n", 1)
    assert "lock" in apt.explain("E: Could not get lock /var/lib/dpkg/lock-frontend", "", 100)
    assert "dpkg --configure -a" in apt.explain("", "E: dpkg was interrupted, you must manually run", 100)
    assert apt.explain("", "", 9) == "apt-get failed (exit 9)"
    assert apt.explain("a\nb\nE: one\nc\nE: two", "", 100) == "E: one\nE: two"


def test_the_updates_screen_rules() -> None:
    sec = PendingUpdate("openssl", "noble-updates,noble-security", "3.0.13-0ubuntu3.5", "3.0.13-0ubuntu3.4", "amd64", True)
    plain = PendingUpdate("curl", "noble-updates", "8.5.0-2ubuntu10.6", None, "amd64", False)
    s = UpdatesSnapshot([plain, sec], ["linux-image-generic"], 1_000_000, True)
    assert apt.subtitle(s) == "2 updates available, 1 security"
    assert apt.subtitle(UpdatesSnapshot([], [], None, False)) == "Everything is up to date"
    assert [p.name for p in apt.sorted_packages(s.packages)] == ["openssl", "curl"]
    assert apt.security_names(s.packages) == ["openssl"]
    assert apt.install_security_hint(s.packages, False) is None
    assert apt.install_security_hint(s.packages, True) == "Read-only mode is on"
    assert apt.install_security_hint([plain], False) == "No security updates"
    assert apt.refreshed_text(s, 1_000_000 + 7200) == "2 hours ago"
    assert apt.staleness(s, 1_000_000 + 3 * 86_400) is None
    assert (apt.staleness(s, 1_000_000 + 4 * 86_400) or "").startswith("Package lists were refreshed 4 days ago")
    p = apt.prompt(AptAction("upgrade", ("a1", "b2", "c3", "d4", "e5", "f6", "g7")), 9, 7)
    assert p.title == "Install 7 security updates?" and p.message.endswith("f6 and 1 more.")
    assert apt.prompt(AptAction("upgrade_all"), 9, 0).title == "Install all 9 updates?"


# --- reboot -------------------------------------------------------------------------------------------------------


def test_reboot_commands_and_intents() -> None:
    assert reboot.intent().command == spec.script("reboot") and reboot.boot_id_command() == spec.script("boot_id")
    assert reboot.sudo_intent() != reboot.intent(), "a yes to the plain reboot is not a yes to the sudo one"
    assert reboot.outcome_of(0, "##rebooting\n", "") is None
    no_sudo = reboot.outcome_of(5, "##no-sudo\n", "")
    assert no_sudo is not None and no_sudo.kind == "no_sudo"
    failed = reboot.outcome_of(1, "", "boom\n")
    assert failed is not None and failed.message == "boom"
    assert reboot.is_back("a", 0, "b\n") and not reboot.is_back("a", 0, "a\n") and not reboot.is_back("a", 255, "b")
    assert reboot.offers_reboot("reboot_required") and not reboot.offers_reboot("disk_high")


def test_sudo_refusals_of_the_reboot_are_explained() -> None:
    c = reboot.classify_sudo_failure
    assert c("sudo: no password was provided\n##sudo-failed", 6).kind == "bad_password"
    assert c("\nsudo: Authentication failed, try again.\n\nsudo: Authentication required but not attempted\n", 6).kind == \
        "bad_password"
    assert "terminal" in c("sudo: sorry, you must have a tty to run sudo\n##sudo-failed", 6).message
    assert "not allowed to use sudo" in c("lab is not in the sudoers file.\n##sudo-failed", 6).message
    assert c("sh: 1: systemctl: not found\n##sudo-failed\n", 6) == reboot.RebootFailure("failed",
                                                                                         "sh: 1: systemctl: not found")
    assert c("", 255).message == "The reboot command failed (exit 255)."
    assert reboot.sudo_outcome_of(0, "##rebooting\n", "") is None
