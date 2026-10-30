package dev.nookwifi.helper;

import android.Manifest;
import android.annotation.SuppressLint;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Wi-Fi operations behind the helper's methods. Nothing here blocks waiting for
 * a state change: callers poll getState, so KOReader's UI thread is never held
 * for longer than one binder call.
 */
final class WifiOps {
    private static final String UNKNOWN_SSID = "<unknown ssid>";
    private static final int SIGNAL_LEVELS = 5;

    private final Context context;
    private final WifiManager wifi;
    private final ConnectivityManager connectivity;

    WifiOps(Context context) {
        this.context = context.getApplicationContext();
        this.wifi = (WifiManager) this.context.getSystemService(Context.WIFI_SERVICE);
        this.connectivity = (ConnectivityManager) this.context.getSystemService(Context.CONNECTIVITY_SERVICE);
    }

    /**
     * Reply fields: wifiState (disabled|disabling|enabled|enabling|unknown),
     * enabled, locationPermission, connection (lowercase NetworkInfo.DetailedState),
     * and when connected: networkId, ssid (only with location permission), rssi,
     * signalLevel (0-4), linkMbps, ip.
     */
    JSONObject getState() {
        return putState(Replies.ok());
    }

    /** arg is "true" or "false". Returns as soon as Android accepts the request. */
    JSONObject setEnabled(String arg) {
        boolean on;
        if ("true".equals(arg)) {
            on = true;
        } else if ("false".equals(arg)) {
            on = false;
        } else {
            return Replies.error("bad_argument");
        }
        JSONObject reply = wifi.setWifiEnabled(on) ? Replies.ok() : Replies.error("request_rejected");
        return putState(reply);
    }

    /**
     * Saved networks as "networks": [{networkId, ssid, status (current|enabled|disabled),
     * security (open|wep|wpa_psk|eap), signalLevel (0-4, only if seen in the last scan)}].
     * "scanAvailable" says whether signal levels could be checked at all (needs location
     * permission and Wi-Fi on). Works with Wi-Fi off.
     */
    // Lint applies newer-API rules (ACCESS_FINE_LOCATION). On API 27, saved networks
    // need no location permission and scan results need only coarse location, which
    // scanLevels checks first (both verified on the Nook in Stage 0).
    @SuppressLint("MissingPermission")
    JSONObject listSaved() {
        List<WifiConfiguration> configs = wifi.getConfiguredNetworks();
        if (configs == null) {
            return putState(Replies.error("wifi_disabled"));
        }
        // With Wi-Fi off there are no scan results, so "not in range" would be wrong.
        boolean scanAvailable = hasLocationPermission() && wifi.isWifiEnabled();
        Map<String, Integer> levels = scanAvailable ? scanLevels() : new HashMap<String, Integer>();
        JSONArray networks = new JSONArray();
        for (WifiConfiguration c : configs) {
            JSONObject n = new JSONObject();
            String ssid = unquote(c.SSID);
            Replies.put(n, "networkId", c.networkId);
            if (ssid != null) {
                Replies.put(n, "ssid", ssid);
                Integer level = levels.get(ssid);
                if (level != null) {
                    Replies.put(n, "signalLevel", level);
                }
            }
            Replies.put(n, "status", configStatus(c.status));
            Replies.put(n, "security", security(c));
            networks.put(n);
        }
        JSONObject reply = Replies.ok();
        Replies.put(reply, "networks", networks);
        Replies.put(reply, "scanAvailable", scanAvailable);
        return reply;
    }

    /**
     * arg is a networkId from listSaved. Asks Android to connect to that saved
     * network; callers poll getState for the result.
     */
    JSONObject connectSaved(String arg) {
        int networkId;
        try {
            networkId = Integer.parseInt(arg);
        } catch (NumberFormatException e) {
            return Replies.error("bad_argument");
        }
        if (!wifi.isWifiEnabled()) {
            return putState(Replies.error("wifi_disabled"));
        }
        if (!isSaved(networkId)) {
            return putState(Replies.error("unknown_network"));
        }
        // disableOthers=true is the "user picked this network" path; on API 27 it does
        // not permanently disable the other saved networks.
        boolean accepted = wifi.enableNetwork(networkId, true) && wifi.reconnect();
        return putState(accepted ? Replies.ok() : Replies.error("request_rejected"));
    }

    /** Asks Android to reconnect to the best available saved network. */
    JSONObject reconnect() {
        if (!wifi.isWifiEnabled()) {
            return putState(Replies.error("wifi_disabled"));
        }
        return putState(wifi.reconnect() ? Replies.ok() : Replies.error("request_rejected"));
    }

    private JSONObject putState(JSONObject reply) {
        int state = wifi.getWifiState();
        Replies.put(reply, "wifiState", stateName(state));
        Replies.put(reply, "enabled", state == WifiManager.WIFI_STATE_ENABLED);
        Replies.put(reply, "locationPermission", hasLocationPermission());

        NetworkInfo net = connectivity.getNetworkInfo(ConnectivityManager.TYPE_WIFI);
        Replies.put(reply, "connection",
                net == null ? "unknown" : net.getDetailedState().name().toLowerCase(Locale.ROOT));
        if (net != null && net.isConnected()) {
            WifiInfo info = wifi.getConnectionInfo();
            if (info != null) {
                Replies.put(reply, "networkId", info.getNetworkId());
                String ssid = ssidOf(info);
                if (ssid != null) {
                    Replies.put(reply, "ssid", ssid);
                }
                Replies.put(reply, "rssi", info.getRssi());
                Replies.put(reply, "signalLevel", WifiManager.calculateSignalLevel(info.getRssi(), SIGNAL_LEVELS));
                Replies.put(reply, "linkMbps", info.getLinkSpeed());
                Replies.put(reply, "ip", ipString(info.getIpAddress()));
            }
        }
        return reply;
    }

    private boolean hasLocationPermission() {
        return context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
    }

    // Lint applies newer-API rules (ACCESS_FINE_LOCATION). On API 27, saved networks
    // need no location permission and scan results need only coarse location, which
    // scanLevels checks first (both verified on the Nook in Stage 0).
    @SuppressLint("MissingPermission")
    private boolean isSaved(int networkId) {
        List<WifiConfiguration> configs = wifi.getConfiguredNetworks();
        if (configs != null) {
            for (WifiConfiguration c : configs) {
                if (c.networkId == networkId) {
                    return true;
                }
            }
        }
        return false;
    }

    // Strongest signal level per SSID from the last scan. Needs location permission:
    // without it, API 27 returns an empty list (verified in Stage 0).
    // Lint applies newer-API rules (ACCESS_FINE_LOCATION). On API 27, saved networks
    // need no location permission and scan results need only coarse location, which
    // scanLevels checks first (both verified on the Nook in Stage 0).
    @SuppressLint("MissingPermission")
    private Map<String, Integer> scanLevels() {
        Map<String, Integer> levels = new HashMap<>();
        List<ScanResult> results = wifi.getScanResults();
        if (results != null) {
            for (ScanResult r : results) {
                if (r.SSID == null || r.SSID.isEmpty()) {
                    continue;
                }
                int level = WifiManager.calculateSignalLevel(r.level, SIGNAL_LEVELS);
                Integer best = levels.get(r.SSID);
                if (best == null || level > best) {
                    levels.put(r.SSID, level);
                }
            }
        }
        return levels;
    }

    // Without location permission, API 27 reports "<unknown ssid>" (verified in Stage 0).
    private static String ssidOf(WifiInfo info) {
        String ssid = info.getSSID();
        if (UNKNOWN_SSID.equals(ssid)) {
            return null;
        }
        return unquote(ssid);
    }

    // Android quotes UTF-8 SSIDs and leaves hex SSIDs bare.
    private static String unquote(String ssid) {
        if (ssid == null || ssid.isEmpty()) {
            return null;
        }
        if (ssid.length() >= 2 && ssid.startsWith("\"") && ssid.endsWith("\"")) {
            return ssid.substring(1, ssid.length() - 1);
        }
        return ssid;
    }

    private static String configStatus(int status) {
        switch (status) {
            case WifiConfiguration.Status.CURRENT: return "current";
            case WifiConfiguration.Status.DISABLED: return "disabled";
            default: return "enabled";
        }
    }

    private static String security(WifiConfiguration c) {
        if (c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.WPA_PSK)) {
            return "wpa_psk";
        }
        if (c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.WPA_EAP)
                || c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.IEEE8021X)) {
            return "eap";
        }
        if (c.wepKeys != null && c.wepKeys[0] != null) {
            return "wep";
        }
        return "open";
    }

    private static String stateName(int state) {
        switch (state) {
            case WifiManager.WIFI_STATE_DISABLED: return "disabled";
            case WifiManager.WIFI_STATE_DISABLING: return "disabling";
            case WifiManager.WIFI_STATE_ENABLED: return "enabled";
            case WifiManager.WIFI_STATE_ENABLING: return "enabling";
            default: return "unknown";
        }
    }

    private static String ipString(int ip) {
        return (ip & 0xff) + "." + ((ip >> 8) & 0xff) + "." + ((ip >> 16) & 0xff) + "." + ((ip >> 24) & 0xff);
    }
}
