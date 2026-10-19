// The terminal colours of the active theme, for xterm.js (terminal tabs and the read-only Output view).
import type { ITheme } from "@xterm/xterm";
import type { Appearance } from "./types";

export function xtermTheme(a: Appearance | undefined): ITheme | undefined {
  if (!a) return undefined;
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  const t = (dark ? a.dark : a.light).terminal;
  const [black, red, green, yellow, blue, magenta, cyan, white, bBlack, bRed, bGreen, bYellow, bBlue, bMagenta, bCyan, bWhite] = t.ansi;
  return {
    background: t.background, foreground: t.foreground, cursor: t.cursor, cursorAccent: t.background,
    selectionBackground: `${t.selection}66`, black, red, green, yellow, blue, magenta, cyan, white,
    brightBlack: bBlack, brightRed: bRed, brightGreen: bGreen, brightYellow: bYellow, brightBlue: bBlue,
    brightMagenta: bMagenta, brightCyan: bCyan, brightWhite: bWhite,
  };
}
