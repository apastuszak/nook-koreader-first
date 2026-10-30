package dev.nookwifi.helper;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;

import org.json.JSONObject;

import java.util.Locale;

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
     * and when connected: ssid (only with location permission), rssi,
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

    private JSONObject putState(JSONObject reply) {
        int state = wifi.getWifiState();
        Replies.put(reply, "wifiState", stateName(state));
        Replies.put(reply, "enabled", state == WifiManager.WIFI_STATE_ENABLED);
        boolean location = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
        Replies.put(reply, "locationPermission", location);

        NetworkInfo net = connectivity.getNetworkInfo(ConnectivityManager.TYPE_WIFI);
        Replies.put(reply, "connection",
                net == null ? "unknown" : net.getDetailedState().name().toLowerCase(Locale.ROOT));
        if (net != null && net.isConnected()) {
            WifiInfo info = wifi.getConnectionInfo();
            if (info != null) {
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

    // Without location permission, API 27 reports "<unknown ssid>" (verified in Stage 0).
    private static String ssidOf(WifiInfo info) {
        String ssid = info.getSSID();
        if (ssid == null || ssid.isEmpty() || UNKNOWN_SSID.equals(ssid)) {
            return null;
        }
        if (ssid.length() >= 2 && ssid.startsWith("\"") && ssid.endsWith("\"")) {
            return ssid.substring(1, ssid.length() - 1);
        }
        return ssid;
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
