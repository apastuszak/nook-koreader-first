package dev.nookwifi.helper;

import android.Manifest;
import android.annotation.SuppressLint;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.SystemClock;
import android.provider.Settings;

import org.json.JSONArray;
import org.json.JSONObject;

import static dev.nookwifi.helper.NetworkRules.isHexKey;
import static dev.nookwifi.helper.NetworkRules.isValidPsk;
import static dev.nookwifi.helper.NetworkRules.networkKey;
import static dev.nookwifi.helper.NetworkRules.quote;
import static dev.nookwifi.helper.NetworkRules.scanSecurity;
import static dev.nookwifi.helper.NetworkRules.unquote;

import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Wi-Fi operations behind the helper's methods. Nothing here blocks waiting for
 * a state change: callers poll getState, so KOReader's UI thread is never held
 * for longer than one binder call.
 *
 * Passwords arrive only in join()'s extras. They go straight into the
 * WifiConfiguration handed to Android and are never logged, stored, or echoed.
 */
final class WifiOps {
    private static final String UNKNOWN_SSID = "<unknown ssid>";
    private static final int SIGNAL_LEVELS = 5;
    private static final int MAX_SSID_BYTES = 32;

    private final Context context;
    private final WifiManager wifi;
    private final ConnectivityManager connectivity;

    // Set by the supplicant broadcast; reset whenever a connection attempt starts.
    // Lost if Android kills the helper process between polls: the plugin then
    // reports a timeout instead of a wrong password.
    private volatile boolean authFailed;
    // Network being authenticated when it failed, or -1 if Android had already cleared it.
    private volatile int authFailedNetworkId = -1;

    // Kept on disk, because Android may kill the cached helper process between
    // the plugin's polls: the scan request time (so "fresh" still works) and the
    // networks join() created recently, the only ones forget() may remove (see
    // CreatedNetworks for why they are keyed by networkKey, boot and elapsed time).
    private static final String PREFS = "state";
    private static final String KEY_SCAN_REQUEST = "lastScanRequestMs";
    private static final String KEY_CREATED = "createdNetworksV2";
    // 1.0.4's wall-clock format; nothing reads it, so it is deleted at startup.
    private static final String KEY_CREATED_V1 = "createdNetworks";
    private final SharedPreferences prefs;
    // Settings.Global.BOOT_COUNT, read once: a process never outlives a boot. -1 if
    // unavailable, which makes CreatedNetworks treat nothing as recent.
    private final int bootCount;

    private final BroadcastReceiver supplicantReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent intent) {
            if (isInitialStickyBroadcast()) {
                return;
            }
            if (intent.getIntExtra(WifiManager.EXTRA_SUPPLICANT_ERROR, 0) == WifiManager.ERROR_AUTHENTICATING) {
                WifiInfo info = wifi.getConnectionInfo();
                authFailedNetworkId = info == null ? -1 : info.getNetworkId();
                authFailed = true;
            }
        }
    };

    WifiOps(Context context) {
        this.context = context.getApplicationContext();
        this.wifi = (WifiManager) this.context.getSystemService(Context.WIFI_SERVICE);
        this.connectivity = (ConnectivityManager) this.context.getSystemService(Context.CONNECTIVITY_SERVICE);
        this.prefs = this.context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (prefs.contains(KEY_CREATED_V1)) {
            prefs.edit().remove(KEY_CREATED_V1).apply();
        }
        this.bootCount = Settings.Global.getInt(this.context.getContentResolver(), Settings.Global.BOOT_COUNT, -1);
        // Lives as long as the helper process; there is no teardown point for a ContentProvider.
        this.context.registerReceiver(supplicantReceiver,
                new IntentFilter(WifiManager.SUPPLICANT_STATE_CHANGED_ACTION));
    }

    /**
     * Reply fields: wifiState (disabled|disabling|enabled|enabling|unknown),
     * enabled, locationPermission, connection (lowercase NetworkInfo.DetailedState),
     * authFailed (wrong password since the last join/connectSaved) with
     * authFailedNetworkId (-1 if unknown), and when connected: networkId, ssid
     * (only with location permission), rssi, signalLevel (0-4), linkMbps, ip.
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
                Integer level = levels.get(networkKey(ssid, security(c)));
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
        resetAuthFailure();
        // enableNetwork(id, true) starts the connection itself (connectToUserSelectNetwork
        // in logcat). Do not add reconnect(): it forces a scan and a fresh network
        // selection, which can pick another saved network because this firmware
        // records no user choice for the helper.
        boolean accepted = wifi.enableNetwork(networkId, true);
        return putState(accepted ? Replies.ok() : Replies.error("request_rejected"));
    }

    /** Starts a scan; callers poll scanResults until "fresh" is true. */
    // commit(), not apply(): the write must survive the process being killed right after.
    @SuppressLint("ApplySharedPref")
    JSONObject startScan() {
        if (!wifi.isWifiEnabled()) {
            return putState(Replies.error("wifi_disabled"));
        }
        // Without it, API 27 returns an empty list instead of an error (Stage 0).
        if (!hasLocationPermission()) {
            return Replies.error("location_permission_needed");
        }
        prefs.edit().putLong(KEY_SCAN_REQUEST, SystemClock.elapsedRealtime()).commit();
        return wifi.startScan() ? Replies.ok() : Replies.error("request_rejected");
    }

    /**
     * Visible networks, one entry per SSID and security type (strongest access
     * point), as "networks": [{ssid, signalLevel (0-4), security
     * (open|wpa_psk|sae|owe|eap|wep), current, savedNetworkId (if a saved network
     * has the same SSID *and* security)}]. Hidden SSIDs are left out. "fresh" is
     * true once results newer than the last scan request have arrived.
     *
     * Matching on security as well as SSID matters: an open network sharing the
     * name of a saved WPA one (or vice versa) must not be treated as saved, or
     * choosing it would connect the other profile, e.g. an unintended open network.
     */
    @SuppressLint("MissingPermission") // see listSaved
    JSONObject scanResults() {
        if (!hasLocationPermission()) {
            return Replies.error("location_permission_needed");
        }
        if (!wifi.isWifiEnabled()) {
            return putState(Replies.error("wifi_disabled"));
        }
        List<ScanResult> results = wifi.getScanResults();
        long newestMs = 0;
        if (results != null) {
            for (ScanResult r : results) {
                // ScanResult.timestamp is microseconds since boot.
                newestMs = Math.max(newestMs, r.timestamp / 1000);
            }
        }
        Map<String, ScanResult> best = bestByNetwork(results);
        Map<String, Integer> saved = savedIdsByNetwork();
        int currentId = -1;
        NetworkInfo net = connectivity.getNetworkInfo(ConnectivityManager.TYPE_WIFI);
        if (net != null && net.isConnected()) {
            WifiInfo info = wifi.getConnectionInfo();
            if (info != null) {
                currentId = info.getNetworkId();
            }
        }

        JSONArray networks = new JSONArray();
        for (ScanResult r : best.values()) {
            JSONObject n = new JSONObject();
            String security = scanSecurity(r.capabilities);
            Integer savedId = saved.get(networkKey(r.SSID, security));
            Replies.put(n, "ssid", r.SSID);
            Replies.put(n, "signalLevel", WifiManager.calculateSignalLevel(r.level, SIGNAL_LEVELS));
            Replies.put(n, "security", security);
            Replies.put(n, "current", savedId != null && savedId == currentId);
            if (savedId != null) {
                Replies.put(n, "savedNetworkId", savedId);
            }
            networks.put(n);
        }
        JSONObject reply = Replies.ok();
        Replies.put(reply, "networks", networks);
        long requestedMs = prefs.getLong(KEY_SCAN_REQUEST, 0);
        Replies.put(reply, "fresh", requestedMs > 0 && newestMs >= requestedMs);
        return reply;
    }

    /**
     * Saves and connects to a new network. Extras: ssid, security (open|wpa_psk),
     * password (wpa_psk only). Refuses networks already saved with the same SSID
     * and security ("already_saved" with savedNetworkId), so a mistyped password
     * can never replace a working one. Returns the new network as createdNetworkId (not
     * networkId, which putState sets to the *current* connection); callers poll
     * getState and should forget() it if the connection fails.
     */
    JSONObject join(Bundle extras) {
        String ssid = extras == null ? null : extras.getString("ssid");
        String security = extras == null ? null : extras.getString("security");
        if (ssid == null || ssid.isEmpty() || ssid.getBytes(StandardCharsets.UTF_8).length > MAX_SSID_BYTES) {
            return Replies.error("bad_argument");
        }
        if (!wifi.isWifiEnabled()) {
            return putState(Replies.error("wifi_disabled"));
        }
        Integer existing = savedIdsByNetwork().get(networkKey(ssid, security));
        if (existing != null) {
            return Replies.put(Replies.error("already_saved"), "savedNetworkId", existing);
        }

        WifiConfiguration config = new WifiConfiguration();
        config.SSID = quote(ssid);
        if ("open".equals(security)) {
            config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE);
        } else if ("wpa_psk".equals(security)) {
            String password = extras.getString("password");
            if (!isValidPsk(password)) {
                return Replies.error("invalid_password");
            }
            config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK);
            // A 64-digit hex string is a raw key and must not be quoted.
            config.preSharedKey = isHexKey(password) ? password : quote(password);
        } else {
            return Replies.error("unsupported_security");
        }

        int networkId = wifi.addNetwork(config);
        if (networkId == -1) {
            return putState(Replies.error("request_rejected"));
        }
        recordCreated(networkKey(ssid, security));
        resetAuthFailure();
        // enableNetwork(id, true) starts the connection itself (connectToUserSelectNetwork
        // in logcat). Do not add reconnect(): it forces a scan and a fresh network
        // selection, which can pick another saved network because this firmware
        // records no user choice for the helper.
        boolean accepted = wifi.enableNetwork(networkId, true);
        JSONObject reply = accepted ? Replies.ok() : Replies.error("request_rejected");
        Replies.put(reply, "createdNetworkId", networkId);
        return putState(reply);
    }

    /**
     * arg is a networkId from join's createdNetworkId. Removes that network, for
     * cleaning up after a failed join. Only a network whose SSID and security match
     * one join() added in the last 10 minutes can be removed ("not_created_here"
     * otherwise), so a caller bug can never
     * delete the user's other networks. This Nook's firmware allows removing the
     * helper's own networks but refuses ones saved by the Nook or Android settings.
     */
    JSONObject forget(String arg) {
        int networkId;
        try {
            networkId = Integer.parseInt(arg);
        } catch (NumberFormatException e) {
            return Replies.error("bad_argument");
        }
        String key = savedKey(networkId);
        if (key == null) {
            return Replies.error("unknown_network");
        }
        if (!wasCreatedRecently(key)) {
            return Replies.error("not_created_here");
        }
        if (!wifi.removeNetwork(networkId)) {
            return Replies.error("request_rejected");
        }
        forgetCreated(key);
        return Replies.ok();
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
        Replies.put(reply, "authFailed", authFailed);
        if (authFailed) {
            Replies.put(reply, "authFailedNetworkId", authFailedNetworkId);
        }

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

    // Saved network IDs by networkKey(SSID, security).
    @SuppressLint("MissingPermission") // see listSaved
    private Map<String, Integer> savedIdsByNetwork() {
        Map<String, Integer> ids = new HashMap<>();
        List<WifiConfiguration> configs = wifi.getConfiguredNetworks();
        if (configs != null) {
            for (WifiConfiguration c : configs) {
                String ssid = unquote(c.SSID);
                if (ssid != null) {
                    ids.put(networkKey(ssid, security(c)), c.networkId);
                }
            }
        }
        return ids;
    }

    @SuppressLint("MissingPermission") // see listSaved
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

    // Strongest signal level per networkKey from the last scan. Needs location
    // permission: without it, API 27 returns an empty list (verified in Stage 0).
    @SuppressLint("MissingPermission") // see listSaved
    private Map<String, Integer> scanLevels() {
        Map<String, Integer> levels = new HashMap<>();
        for (Map.Entry<String, ScanResult> e : bestByNetwork(wifi.getScanResults()).entrySet()) {
            levels.put(e.getKey(), WifiManager.calculateSignalLevel(e.getValue().level, SIGNAL_LEVELS));
        }
        return levels;
    }

    // The strongest access point for each visible networkKey (SSID plus security);
    // hidden SSIDs are left out.
    private static Map<String, ScanResult> bestByNetwork(List<ScanResult> results) {
        Map<String, ScanResult> best = new HashMap<>();
        if (results != null) {
            for (ScanResult r : results) {
                if (r.SSID == null || r.SSID.isEmpty()) {
                    continue;
                }
                String key = networkKey(r.SSID, scanSecurity(r.capabilities));
                ScanResult prev = best.get(key);
                if (prev == null || r.level > prev.level) {
                    best.put(key, r);
                }
            }
        }
        return best;
    }

    // networkKey of the saved network with this ID, or null if there is none.
    @SuppressLint("MissingPermission") // see listSaved
    private String savedKey(int networkId) {
        List<WifiConfiguration> configs = wifi.getConfiguredNetworks();
        if (configs != null) {
            for (WifiConfiguration c : configs) {
                String ssid = unquote(c.SSID);
                if (c.networkId == networkId && ssid != null) {
                    return networkKey(ssid, security(c));
                }
            }
        }
        return null;
    }

    private boolean wasCreatedRecently(String key) {
        return CreatedNetworks.isRecent(createdEntries(), key, bootCount, SystemClock.elapsedRealtime());
    }

    private void recordCreated(String key) {
        updateCreated(key, true);
    }

    private void forgetCreated(String key) {
        updateCreated(key, false);
    }

    // synchronized: two binder threads must not lose each other's update. commit(),
    // not apply(): the write must survive the process being killed right after.
    @SuppressLint("ApplySharedPref")
    private synchronized void updateCreated(String key, boolean add) {
        Set<String> updated = CreatedNetworks.update(createdEntries(), key, add, bootCount,
                SystemClock.elapsedRealtime());
        prefs.edit().putStringSet(KEY_CREATED, updated).commit();
    }

    private Set<String> createdEntries() {
        return prefs.getStringSet(KEY_CREATED, Collections.<String>emptySet());
    }

    private void resetAuthFailure() {
        authFailed = false;
        authFailedNetworkId = -1;
    }

    // Without location permission, API 27 reports "<unknown ssid>" (verified in Stage 0).
    private static String ssidOf(WifiInfo info) {
        String ssid = info.getSSID();
        if (UNKNOWN_SSID.equals(ssid)) {
            return null;
        }
        return unquote(ssid);
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
