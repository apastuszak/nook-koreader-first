package dev.nookwifi.helper;

/**
 * Pure rules for SSIDs, security types and passwords. No Android dependencies,
 * so they are unit-tested on the JVM (src/test).
 */
final class NetworkRules {
    private NetworkRules() {
    }

    /**
     * Identifies a network the way Android's configKey does: SSID plus security.
     * Security comes first and never contains '|', so no SSID (which may contain
     * any character) can make two different networks share a key.
     */
    static String networkKey(String ssid, String security) {
        return security + "|" + ssid;
    }

    /**
     * Security type from ScanResult.capabilities, e.g. "[WPA2-PSK-CCMP][ESS]":
     * open, wpa_psk, sae, owe, eap or wep. PSK wins over SAE so WPA2/WPA3
     * transition networks join as WPA2, which API 27 supports.
     */
    static String scanSecurity(String caps) {
        if (caps == null) {
            return "open";
        }
        if (caps.contains("EAP")) {
            return "eap";
        }
        if (caps.contains("PSK")) {
            return "wpa_psk";
        }
        if (caps.contains("SAE")) {
            return "sae";
        }
        if (caps.contains("OWE")) {
            return "owe";
        }
        if (caps.contains("WEP")) {
            return "wep";
        }
        return "open";
    }

    /** WPA/WPA2 passphrases are 8-63 printable ASCII characters, or a 64-digit hex key. */
    static boolean isValidPsk(String password) {
        if (password == null) {
            return false;
        }
        if (isHexKey(password)) {
            return true;
        }
        if (password.length() < 8 || password.length() > 63) {
            return false;
        }
        for (int i = 0; i < password.length(); i++) {
            char ch = password.charAt(i);
            if (ch < 0x20 || ch > 0x7e) {
                return false;
            }
        }
        return true;
    }

    /** A 64-digit hex string is a raw key and must not be quoted. */
    static boolean isHexKey(String password) {
        return password.length() == 64 && password.matches("[0-9A-Fa-f]{64}");
    }

    static String quote(String s) {
        return "\"" + s + "\"";
    }

    /** Android quotes UTF-8 SSIDs and leaves hex SSIDs bare. Returns null for none. */
    static String unquote(String ssid) {
        if (ssid == null || ssid.isEmpty()) {
            return null;
        }
        if (ssid.length() >= 2 && ssid.startsWith("\"") && ssid.endsWith("\"")) {
            return ssid.substring(1, ssid.length() - 1);
        }
        return ssid;
    }
}
