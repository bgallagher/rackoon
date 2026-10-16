"""A failed connection explained for the Overview: what it means and what to do. The raw message stays on screen
beside it. Like `ConnectionFailure` in the Kotlin core (which, like the web, has no `ssh -v` to ask which keys were
offered, so a refused login is explained from how the server is signed in to); the wording speaks of the machine
Rackoon runs on rather than a phone."""

from __future__ import annotations

import enum
from dataclasses import dataclass


class FailureKind(enum.Enum):
    AUTH_REFUSED = "authRefused"
    UNREACHABLE = "unreachable"
    UNRESOLVED = "unresolved"
    HOST_KEY_UNKNOWN = "hostKeyUnknown"
    HOST_KEY_CHANGED = "hostKeyChanged"


class SignIn(enum.Enum):
    TAILSCALE = "tailscale"
    KEY = "key"
    PASSWORD = "password"


@dataclass(frozen=True)
class ConnectionFailure:
    kind: FailureKind
    headline: str
    advice: str


AUTH_REFUSED = ("Sign-in was refused", "Exhausted available authentication", "Permission denied",
                "Authentication failed")
UNRESOLVED = ("Unable to resolve host", "UnknownHost", "No address associated with hostname", "Name or service not known",
              "nodename nor servname provided", "Temporary failure in name resolution")
REFUSED = ("Connection refused", "ECONNREFUSED", "Connect call failed")
DROPPED = ("Connection closed", "Connection reset", "Connection lost", "EOF", "Broken pipe")
NO_ROUTE = ("No route to host", "Network is unreachable", "timed out", "Timed out", "ENETUNREACH", "EHOSTUNREACH")


def _has(text: str, words: tuple[str, ...], ignore_case: bool = True) -> bool:
    t = text.lower() if ignore_case else text
    return any((w.lower() if ignore_case else w) in t for w in words)


def is_auth_refused(message: str) -> bool:
    return _has(message, AUTH_REFUSED)


def explain(raw: str, sign_in: SignIn | None = None) -> ConnectionFailure | None:
    """None when the message is not one we know; the card then shows the raw text alone."""
    text = raw.strip()
    if "host key is not trusted" in text:
        return ConnectionFailure(FailureKind.HOST_KEY_UNKNOWN, "This server's host key isn't trusted yet.",
                                 "Compare the fingerprint with the server's own (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub "
                                 "on the server) and trust it under Edit connection.")
    if "host key changed" in text.lower():
        return ConnectionFailure(FailureKind.HOST_KEY_CHANGED, "The server's host key changed. Rackoon won't connect.",
                                 "If the server was reinstalled, check its new fingerprint, then remove its entry from "
                                 "known_hosts.json in Rackoon's data folder. Otherwise someone may be in between: don't sign in.")
    if is_auth_refused(text):
        return _auth_refused(sign_in)
    if _has(text, UNRESOLVED):
        return ConnectionFailure(FailureKind.UNRESOLVED, "The server's name could not be looked up.",
                                 "The machine Rackoon runs on doesn't know that name. Check the spelling under Edit connection, "
                                 "or use the IP address. A Tailscale name only resolves where Tailscale (MagicDNS) is connected.")
    if _has(text, REFUSED):
        return ConnectionFailure(FailureKind.UNREACHABLE, "Nothing accepts SSH at that address and port.",
                                 "The machine answered, but no SSH service is listening there. Check the port under Edit "
                                 "connection and that sshd is running on the server.")
    if _has(text, DROPPED):
        return ConnectionFailure(FailureKind.UNREACHABLE, "The server dropped the connection.",
                                 "It may be rate-limiting Rackoon (fail2ban), restarting, or not an SSH server at all. Try again "
                                 "in a minute; if it keeps happening, check the address and port under Edit connection.")
    if _has(text, NO_ROUTE, ignore_case=False):
        return ConnectionFailure(FailureKind.UNREACHABLE, "Can't reach the server.",
                                 "Check that the server is on and that the machine Rackoon runs on can reach it (same network, "
                                 "or Tailscale in the container's host), then try again.")
    return None


def _auth_refused(sign_in: SignIn | None) -> ConnectionFailure:
    advice = {
        SignIn.TAILSCALE: "Tailscale SSH did not let this user in. Check that the machine Rackoon runs on is on your tailnet, "
                          "that your tailnet policy allows SSH to this server as this user, and the user name (Edit "
                          "connection). Or choose a key under Edit connection.",
        SignIn.KEY: "The server did not accept the key for this user. Check the user name under Edit connection and that the "
                    "key's public half is in the server's ~/.ssh/authorized_keys (Settings > Keys shows it to copy).",
        SignIn.PASSWORD: "The server did not accept the password for this user. Many servers only take keys "
                         "(PasswordAuthentication no).",
    }.get(sign_in) if sign_in else None
    return ConnectionFailure(FailureKind.AUTH_REFUSED, "The server refused the login.",
                             advice or "Check the user name under Edit connection, and the sign-in method: Tailscale SSH or a key.")
