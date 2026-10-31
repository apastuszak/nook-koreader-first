package dev.nookwifi.helper;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class PowerRulesTest {
    @Test
    public void allowedValues() {
        assertEquals(0, PowerRules.parseAllowed("0"));
        assertEquals(3600000, PowerRules.parseAllowed("3600000"));
        assertEquals(21600000, PowerRules.parseAllowed("21600000"));
        assertEquals(86400000, PowerRules.parseAllowed("86400000"));
        assertEquals(259200000, PowerRules.parseAllowed("259200000"));
        assertEquals(604800000, PowerRules.parseAllowed("604800000"));
    }

    @Test
    public void everyAllowedValueParses() {
        for (int ms : PowerRules.ALLOWED_MS) {
            assertEquals(ms, PowerRules.parseAllowed(Integer.toString(ms)));
        }
    }

    @Test
    public void rejectsOtherValues() {
        assertEquals(-1, PowerRules.parseAllowed(null));
        assertEquals(-1, PowerRules.parseAllowed(""));
        assertEquals(-1, PowerRules.parseAllowed("120000")); // 2 minutes: off after every short sleep
        assertEquals(-1, PowerRules.parseAllowed("1"));
        assertEquals(-1, PowerRules.parseAllowed("-1"));
        assertEquals(-1, PowerRules.parseAllowed("+3600000"));
        assertEquals(-1, PowerRules.parseAllowed(" 3600000"));
        assertEquals(-1, PowerRules.parseAllowed("3600000\n"));
        assertEquals(-1, PowerRules.parseAllowed("1h"));
        assertEquals(-1, PowerRules.parseAllowed("99999999999")); // too long
        assertEquals(-1, PowerRules.parseAllowed("4294967296")); // 2^32, wraps to 0 as an int
        assertEquals(-1, PowerRules.parseAllowed("4298567296")); // 2^32 + 1 hour
    }
}
