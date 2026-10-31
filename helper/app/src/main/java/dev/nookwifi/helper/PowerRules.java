package dev.nookwifi.helper;

/**
 * Pure rules for the Nook's power-off timer. No Android dependencies, so they
 * are unit-tested on the JVM (src/test).
 *
 * The firmware's power manager (ntx PowerManagerEx) reads the hidden system
 * setting power_off_timeout each time the Nook goes to sleep and, if it is not
 * 0, powers off after sleeping that many milliseconds (verified on the Nook:
 * 120000 shut it down about 2 minutes after sleeping, even on USB power). A
 * missing setting reads as 0.
 */
final class PowerRules {
    private PowerRules() {
    }

    static final String SETTING = "power_off_timeout";

    private static final int HOUR_MS = 60 * 60 * 1000;

    /**
     * The only values the helper writes: never, 1 hour, 6 hours, 1 day, 3 days,
     * 1 week. A fixed list keeps a caller from setting a timeout of seconds,
     * which would power the Nook off right after every sleep. All fit in an int,
     * which Settings.System.putInt needs.
     */
    static final int[] ALLOWED_MS = {0, HOUR_MS, 6 * HOUR_MS, 24 * HOUR_MS, 72 * HOUR_MS, 168 * HOUR_MS};

    /** The allowed timeout in arg, or -1 if arg is not one of them. */
    static int parseAllowed(String arg) {
        if (arg == null || !arg.matches("[0-9]{1,10}")) {
            return -1;
        }
        long value = Long.parseLong(arg);
        for (int allowed : ALLOWED_MS) {
            if (allowed == value) {
                return allowed;
            }
        }
        return -1;
    }
}
