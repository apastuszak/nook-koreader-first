package dev.nookwifi.helper;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

import org.junit.Test;

public class CreatedNetworksTest {
    private static final String CAFE = NetworkRules.networkKey("Cafe", "wpa_psk");
    private static final String HOME = NetworkRules.networkKey("Home", "wpa_psk");
    private static final int BOOT = 7;
    private static final long T0 = 1_000_000L; // elapsed ms since boot

    private static Set<String> created(String key, int boot, long at) {
        return CreatedNetworks.update(Collections.<String>emptySet(), key, true, boot, at);
    }

    @Test
    public void recentlyCreatedNetworkMayBeForgotten() {
        Set<String> s = created(CAFE, BOOT, T0);
        assertTrue(CreatedNetworks.isRecent(s, CAFE, BOOT, T0 + 30_000));
    }

    @Test
    public void otherNetworksMayNotBeForgotten() {
        Set<String> s = created(CAFE, BOOT, T0);
        assertFalse(CreatedNetworks.isRecent(s, HOME, BOOT, T0 + 1_000));
        // Same SSID, different security: a different network.
        assertFalse(CreatedNetworks.isRecent(s, NetworkRules.networkKey("Cafe", "open"), BOOT, T0 + 1_000));
    }

    @Test
    public void windowExpires() {
        Set<String> s = created(CAFE, BOOT, T0);
        assertTrue(CreatedNetworks.isRecent(s, CAFE, BOOT, T0 + CreatedNetworks.WINDOW_MS - 1));
        assertFalse(CreatedNetworks.isRecent(s, CAFE, BOOT, T0 + CreatedNetworks.WINDOW_MS));
    }

    @Test
    public void rebootExpiresEntriesEvenWhenElapsedTimeLooksRecent() {
        Set<String> s = created(CAFE, BOOT, T0);
        // After a reboot elapsed time restarts; it may by chance be just past T0.
        assertFalse(CreatedNetworks.isRecent(s, CAFE, BOOT + 1, T0 + 1_000));
        assertFalse(CreatedNetworks.isRecent(s, CAFE, BOOT + 1, 10));
    }

    @Test
    public void elapsedTimeGoingBackwardsIsNotRecent() {
        Set<String> s = created(CAFE, BOOT, T0);
        assertFalse(CreatedNetworks.isRecent(s, CAFE, BOOT, T0 - 1));
    }

    @Test
    public void forgettingRemovesOnlyThatNetwork() {
        Set<String> s = created(CAFE, BOOT, T0);
        s = CreatedNetworks.update(s, HOME, true, BOOT, T0 + 1_000);
        s = CreatedNetworks.update(s, CAFE, false, BOOT, T0 + 2_000);
        assertFalse(CreatedNetworks.isRecent(s, CAFE, BOOT, T0 + 3_000));
        assertTrue(CreatedNetworks.isRecent(s, HOME, BOOT, T0 + 3_000));
    }

    @Test
    public void updateDropsExpiredAndUnreadableEntries() {
        Set<String> s = new HashSet<>(created(CAFE, BOOT, T0));
        s.add("1793400000000|wpa_psk|Old"); // 1.0.4's wall-clock format
        s.add("garbage");
        s.add("7|not-a-number|wpa_psk|X");
        Set<String> out = CreatedNetworks.update(s, HOME, true, BOOT, T0 + CreatedNetworks.WINDOW_MS + 5);
        // CAFE expired, the unreadable entries are dropped, HOME was added.
        assertEquals(1, out.size());
        assertTrue(CreatedNetworks.isRecent(out, HOME, BOOT, T0 + CreatedNetworks.WINDOW_MS + 6));
    }

    @Test
    public void updateDoesNotModifyItsInput() {
        Set<String> s = created(CAFE, BOOT, T0);
        Set<String> copy = new HashSet<>(s);
        CreatedNetworks.update(s, HOME, true, BOOT, T0 + 1);
        assertEquals(copy, s);
    }

    @Test
    public void unknownBootCountMakesNothingRecent() {
        // Without a boot count a reboot cannot be detected, so nothing may be forgotten.
        Set<String> s = created(CAFE, -1, T0);
        assertFalse(CreatedNetworks.isRecent(s, CAFE, -1, T0 + 1_000));
        assertTrue("unknown boot count should not be recorded", s.isEmpty());
        Set<String> known = created(CAFE, BOOT, T0);
        assertFalse(CreatedNetworks.isRecent(known, CAFE, -1, T0 + 1_000));
    }

    @Test
    public void keysContainingSeparatorsRoundTrip() {
        String odd = NetworkRules.networkKey("a|b|c", "open");
        Set<String> s = created(odd, BOOT, T0);
        assertTrue(CreatedNetworks.isRecent(s, odd, BOOT, T0 + 1));
        assertFalse(CreatedNetworks.isRecent(s, NetworkRules.networkKey("a|b|c", "wpa_psk"), BOOT, T0 + 1));
        assertFalse(CreatedNetworks.isRecent(s, NetworkRules.networkKey("a|b", "open"), BOOT, T0 + 1));
    }
}
