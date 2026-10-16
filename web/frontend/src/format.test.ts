import { describe, expect, it } from "vitest";
import { ago, bytes, destination, duration, fraction, percent, serverClock } from "./format";

describe("format", () => {
  it("writes bytes in decimal units", () => {
    expect(bytes(0)).toBe("0 B");
    expect(bytes(999)).toBe("999 B");
    expect(bytes(1500)).toBe("1.5 KB");
    expect(bytes(500_107_862_016)).toBe("500 GB");
    expect(bytes(-1)).toBe("—");
  });
  it("writes percentages and fractions", () => {
    expect(percent(41.6)).toBe("42%");
    expect(percent(null)).toBe("—");
    expect(fraction(0.391)).toBe("39%");
    expect(fraction(null)).toBe("—");
  });
  it("writes durations", () => {
    expect(duration(59)).toBe("59 s");
    expect(duration(3 * 60)).toBe("3 min");
    expect(duration(2 * 3600 + 5 * 60)).toBe("2 h 5 min");
    expect(duration(27.4 * 86400)).toBe("27 days, 9 h");
    expect(duration(86400)).toBe("1 day, 0 h");
  });
  it("says how long ago", () => {
    expect(ago(null, 100)).toBe("never");
    expect(ago(98, 100)).toBe("just now");
    expect(ago(50, 100)).toBe("50 s ago");
    expect(ago(100 - 7200, 100)).toBe("2 h ago");
  });
  it("shows the server's own clock, ticking from the poll", () => {
    expect(serverClock(0, 3600, 0, 61)).toBe("1970-01-01 01:01:01");
  });
  it("writes ssh destinations", () => {
    expect(destination({ host: "h" })).toBe("h");
    expect(destination({ user: "rk", host: "h", port: 2222 })).toBe("rk@h:2222");
    expect(destination({ user: "rk", host: "h", port: 22 })).toBe("rk@h");
  });
});
