package dev.nookwifi.helper;

import java.util.HashSet;
import java.util.Set;

/**
 * Records of networks join() created, so forget() can clean up after a failed
 * join but never remove anything else. Pure logic over a set of strings (kept
 * in SharedPreferences by WifiOps), unit-tested on the JVM.
 *
 * Entries are "<boot count>|<elapsed ms since boot>|<networkKey>". Not the
 * networkId: IDs are reassigned when Android loads saved networks at boot. Not
 * wall-clock time either: changing the clock would open or close the window.
 * Elapsed time restarts at boot, so the boot count makes entries from an
 * earlier boot expire instead of looking recent.
 */
final class CreatedNetworks {
    /** forget() is only for cleaning up right after a failed join. */
    static final long WINDOW_MS = 10 * 60 * 1000;

    private CreatedNetworks() {
    }

    /**
     * True if key was recorded within WINDOW_MS during this boot. A negative boot
     * count means "unknown": then nothing is recent, because without it a reboot
     * could make an old entry look new. forget() then refuses, which is safe.
     */
    static boolean isRecent(Set<String> entries, String key, int boot, long nowMs) {
        if (boot < 0) {
            return false;
        }
        for (String entry : entries) {
            Parsed p = Parsed.of(entry);
            if (p != null && p.key.equals(key) && p.isLive(boot, nowMs)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Returns a new set with key added (add=true) or removed, and with expired
     * or unreadable entries dropped. The input is not modified.
     */
    static Set<String> update(Set<String> entries, String key, boolean add, int boot, long nowMs) {
        Set<String> kept = new HashSet<>();
        for (String entry : entries) {
            Parsed p = Parsed.of(entry);
            if (p != null && p.isLive(boot, nowMs) && !p.key.equals(key)) {
                kept.add(entry);
            }
        }
        if (add && boot >= 0) {
            kept.add(boot + "|" + nowMs + "|" + key);
        }
        return kept;
    }

    private static final class Parsed {
        final int boot;
        final long createdMs;
        final String key;

        private Parsed(int boot, long createdMs, String key) {
            this.boot = boot;
            this.createdMs = createdMs;
            this.key = key;
        }

        // The key itself contains '|', so split only the first two fields.
        // Entries in another format (e.g. 1.0.4's "<time>|<key>") return null.
        static Parsed of(String entry) {
            int first = entry.indexOf('|');
            int second = first < 0 ? -1 : entry.indexOf('|', first + 1);
            if (second < 0) {
                return null;
            }
            try {
                return new Parsed(Integer.parseInt(entry.substring(0, first)),
                        Long.parseLong(entry.substring(first + 1, second)), entry.substring(second + 1));
            } catch (NumberFormatException e) {
                return null;
            }
        }

        boolean isLive(int nowBoot, long nowMs) {
            long age = nowMs - createdMs;
            return boot == nowBoot && age >= 0 && age < WINDOW_MS;
        }
    }
}
