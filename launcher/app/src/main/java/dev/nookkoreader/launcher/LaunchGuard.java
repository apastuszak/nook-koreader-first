package dev.nookkoreader.launcher;

import java.util.ArrayList;
import java.util.List;

/**
 * Pure, bounded history of HOME entries, including automatic returns after a crash.
 * Three entries within LOOP_MS open recovery, whether the user pressed Home three
 * times (the escape route) or KOReader keeps closing. There is no separate
 * fast-triple-tap escape: the Nook's Home button reports its release 1.3-2 s after a
 * press and swallows taps in between, so quick taps reach Android as one press
 * (seen in logcat on 2026-10-30).
 */
final class LaunchGuard {
    static final long LOOP_MS = 10000;
    // UNAVAILABLE: history unreadable or the clock/boot count unknown, so the guard
    // cannot tell; it fails closed, but is not a loop.
    enum Decision { LAUNCH, LOOP, UNAVAILABLE }

    private LaunchGuard() { }

    static final class Result {
        final Decision decision;
        final String history;
        Result(Decision decision, String history) {
            this.decision = decision;
            this.history = history;
        }
    }

    // History is private persisted state, not an intent extra. A reboot resets it.
    static Result enter(String history, int savedBoot, int boot, long now) {
        List<Long> recent = new ArrayList<>();
        if (savedBoot == boot && boot >= 0 && !history.isEmpty()) {
            try {
                for (String part : history.split(",")) {
                    long t = Long.parseLong(part);
                    if (t < 0 || t > now) return new Result(Decision.UNAVAILABLE, "");
                    if (now - t <= LOOP_MS) recent.add(t);
                }
            } catch (NumberFormatException e) {
                return new Result(Decision.UNAVAILABLE, "");
            }
        }
        if (boot < 0 || now < 0) return new Result(Decision.UNAVAILABLE, "");
        recent.add(now);
        Decision decision = recent.size() >= 3 ? Decision.LOOP : Decision.LAUNCH;
        StringBuilder out = new StringBuilder();
        for (int i = Math.max(0, recent.size() - 3); i < recent.size(); i++) {
            if (out.length() > 0) out.append(',');
            out.append(recent.get(i));
        }
        return new Result(decision, out.toString());
    }
}
