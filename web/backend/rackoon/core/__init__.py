"""Rackoon's Python core: the third core beside RackoonCore (Swift) and android/core (Kotlin), kept in step with them
only through spec/ (golden fixtures, shared scenarios, lab checks; docs/parity.md).

Pure: no SSH, no network, no database. The one thing it reads is spec/ itself (commands, command library, themes),
so there is no Python copy of any shell command. The web backend's services and transport build on it; the browser
only renders what it computes.
"""
