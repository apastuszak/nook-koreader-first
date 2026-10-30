package dev.nookwifi.helper;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.HashSet;
import java.util.Set;

import org.junit.Test;

public class NetworkRulesTest {
    @Test
    public void networkKeyDistinguishesSecurity() {
        assertNotEquals(NetworkRules.networkKey("Cafe", "open"), NetworkRules.networkKey("Cafe", "wpa_psk"));
    }

    // Security values come from a fixed set, none containing '|'.
    private static final String[] SECURITIES = {"open", "wpa_psk", "sae", "owe", "eap", "wep"};
    private static final String[] TRICKY_SSIDS = {
        "Cafe", "", "|", "open|Cafe", "Cafe|open", "wpa_psk|Cafe", "a\u0000open", "a\u0000wpa_psk",
        "open", "wpa_psk|", "|wpa_psk", "Caf\u00e9 \ud83d\udcf6",
    };

    @Test
    public void networkKeyNeverCollidesForRealSecurityValues() {
        Set<String> keys = new HashSet<>();
        int pairs = 0;
        for (String security : SECURITIES) {
            for (String ssid : TRICKY_SSIDS) {
                keys.add(NetworkRules.networkKey(ssid, security));
                pairs++;
            }
        }
        assertEquals("two different networks share a key", pairs, keys.size());
    }

    @Test
    public void scanSecurityParsesCapabilities() {
        assertEquals("wpa_psk", NetworkRules.scanSecurity("[WPA2-PSK-CCMP][ESS]"));
        assertEquals("wpa_psk", NetworkRules.scanSecurity("[WPA-PSK-TKIP][WPA2-PSK-CCMP][ESS][WPS]"));
        // WPA2/WPA3 transition networks join as WPA2.
        assertEquals("wpa_psk", NetworkRules.scanSecurity("[WPA2-PSK-CCMP][RSN-SAE-CCMP][ESS]"));
        assertEquals("sae", NetworkRules.scanSecurity("[RSN-SAE-CCMP][ESS]"));
        assertEquals("eap", NetworkRules.scanSecurity("[WPA2-EAP-CCMP][ESS]"));
        assertEquals("owe", NetworkRules.scanSecurity("[RSN-OWE-CCMP][ESS]"));
        assertEquals("wep", NetworkRules.scanSecurity("[WEP][ESS]"));
        assertEquals("open", NetworkRules.scanSecurity("[ESS]"));
        assertEquals("open", NetworkRules.scanSecurity(null));
    }

    @Test
    public void pskRules() {
        assertTrue(NetworkRules.isValidPsk("12345678"));
        assertTrue(NetworkRules.isValidPsk("correct horse battery staple"));
        assertTrue(NetworkRules.isValidPsk("a".repeat(63)));
        assertTrue(NetworkRules.isValidPsk("F".repeat(64))); // raw hex key
        assertFalse(NetworkRules.isValidPsk("1234567"));
        assertFalse(NetworkRules.isValidPsk("g".repeat(64))); // 64 chars, not hex
        assertFalse(NetworkRules.isValidPsk("café au lait")); // non-ASCII
        assertFalse(NetworkRules.isValidPsk("tab\there!!"));
        assertFalse(NetworkRules.isValidPsk(null));
    }

    @Test
    public void hexKeysAreNotQuoted() {
        assertTrue(NetworkRules.isHexKey("0".repeat(64)));
        assertFalse(NetworkRules.isHexKey("0".repeat(63)));
        assertEquals("\"pass word\"", NetworkRules.quote("pass word"));
    }

    @Test
    public void unquoteHandlesQuotedHexAndEmpty() {
        assertEquals("Home", NetworkRules.unquote("\"Home\""));
        assertEquals("a\"b", NetworkRules.unquote("\"a\"b\""));
        assertEquals("0a1b2c", NetworkRules.unquote("0a1b2c")); // hex SSIDs are bare
        assertNull(NetworkRules.unquote(""));
        assertNull(NetworkRules.unquote(null));
    }
}
