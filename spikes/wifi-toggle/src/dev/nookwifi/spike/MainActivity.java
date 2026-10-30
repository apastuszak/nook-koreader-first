package dev.nookwifi.spike;

import android.Manifest;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * Stage 0 Test 1: checks whether an ordinary app holding CHANGE_WIFI_STATE can
 * toggle Wi-Fi, scan, and read saved networks on this firmware. Everything is
 * logged on screen and to logcat under the tag "WifiSpike". No passwords are
 * read or printed.
 */
public class MainActivity extends Activity {
    private static final String TAG = "WifiSpike";
    private static final long POLL_MS = 500;
    private static final long STATE_TIMEOUT_MS = 20000;
    private static final long SCAN_TIMEOUT_MS = 15000;

    private final Handler handler = new Handler();
    private final SimpleDateFormat clock = new SimpleDateFormat("HH:mm:ss.SSS", Locale.US);

    private WifiManager wifi;
    private ConnectivityManager connectivity;
    private TextView logView;
    private ScrollView scroll;

    // Start time of the current action, for elapsed-time reporting.
    private long t0;
    private Runnable poller;
    private boolean scanPending;

    private final Runnable scanTimeout = new Runnable() {
        @Override
        public void run() {
            scanPending = false;
            log("Scan TIMED OUT after " + SCAN_TIMEOUT_MS + " ms; reading cached results");
            dumpScanResults();
        }
    };

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String action = intent.getAction();
            if (WifiManager.WIFI_STATE_CHANGED_ACTION.equals(action)) {
                int state = intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, -1);
                log("broadcast WIFI_STATE_CHANGED -> " + stateName(state) + elapsed());
            } else if (WifiManager.NETWORK_STATE_CHANGED_ACTION.equals(action)) {
                NetworkInfo info = intent.getParcelableExtra(WifiManager.EXTRA_NETWORK_INFO);
                if (info != null) {
                    log("broadcast NETWORK_STATE_CHANGED -> " + info.getDetailedState() + elapsed());
                }
            } else if (WifiManager.SCAN_RESULTS_AVAILABLE_ACTION.equals(action)) {
                boolean updated = intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false);
                log("broadcast SCAN_RESULTS_AVAILABLE updated=" + updated + elapsed());
                if (scanPending) {
                    scanPending = false;
                    handler.removeCallbacks(scanTimeout);
                    dumpScanResults();
                }
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        connectivity = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        setContentView(buildLayout());

        IntentFilter filter = new IntentFilter();
        filter.addAction(WifiManager.WIFI_STATE_CHANGED_ACTION);
        filter.addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION);
        filter.addAction(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION);
        registerReceiver(receiver, filter);

        log("Started. SDK " + android.os.Build.VERSION.SDK_INT + ", " + android.os.Build.DISPLAY);
        status();
    }

    @Override
    protected void onDestroy() {
        unregisterReceiver(receiver);
        handler.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    private View buildLayout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(12);
        root.setPadding(pad, pad, pad, pad);

        addRow(root, button("Status", 0), button("Saved networks", 1));
        addRow(root, button("Wi-Fi ON", 2), button("Wi-Fi OFF", 3));
        addRow(root, button("Scan", 4), button("Ask location perm", 5));
        addRow(root, button("Clear log", 6));

        logView = new TextView(this);
        logView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        logView.setTextColor(0xFF000000);
        logView.setTextIsSelectable(true);
        scroll = new ScrollView(this);
        scroll.addView(logView);
        root.addView(scroll, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
        return root;
    }

    private void addRow(LinearLayout root, Button... buttons) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        for (Button b : buttons) {
            row.addView(b, new LinearLayout.LayoutParams(0, dp(64), 1f));
        }
        root.addView(row);
    }

    // android-27's android.jar lacks LambdaMetafactory, so no lambdas in this file.
    private Button button(String label, final int id) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        b.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                onButton(id);
            }
        });
        return b;
    }

    private void onButton(int id) {
        switch (id) {
            case 0: status(); break;
            case 1: savedNetworks(); break;
            case 2: setEnabled(true); break;
            case 3: setEnabled(false); break;
            case 4: scan(); break;
            case 5: requestLocation(); break;
            case 6: logView.setText(""); break;
        }
    }

    // --- Actions ---

    private void status() {
        startAction("Status");
        log("permissions: " + permissionSummary());
        log("location_providers_allowed="
                + Settings.Secure.getString(getContentResolver(), Settings.Secure.LOCATION_PROVIDERS_ALLOWED));
        try {
            log("isWifiEnabled=" + wifi.isWifiEnabled() + " state=" + stateName(wifi.getWifiState()));
            WifiInfo info = wifi.getConnectionInfo();
            if (info != null) {
                log("connection: ssid=" + info.getSSID() + " rssi=" + info.getRssi()
                        + " linkMbps=" + info.getLinkSpeed() + " ip=" + ipString(info.getIpAddress())
                        + " supplicant=" + info.getSupplicantState() + " netId=" + info.getNetworkId());
            }
        } catch (SecurityException e) {
            log("SecurityException: " + e.getMessage());
        }
        NetworkInfo active = connectivity.getActiveNetworkInfo();
        log("active network: " + (active == null ? "none" : active.getTypeName() + " " + active.getDetailedState()));
    }

    private void setEnabled(boolean on) {
        startAction("setWifiEnabled(" + on + ")");
        boolean accepted;
        try {
            accepted = wifi.setWifiEnabled(on);
        } catch (SecurityException e) {
            log("SecurityException: " + e.getMessage());
            return;
        }
        log("setWifiEnabled returned " + accepted + elapsed());
        if (accepted) {
            pollFor(on ? WifiManager.WIFI_STATE_ENABLED : WifiManager.WIFI_STATE_DISABLED);
        }
    }

    // Polls getWifiState() so the result reflects actual state, not just request acceptance.
    private void pollFor(final int target) {
        if (poller != null) {
            handler.removeCallbacks(poller);
        }
        poller = new Runnable() {
            private int last = -2;

            @Override
            public void run() {
                int state = wifi.getWifiState();
                if (state != last) {
                    log("poll: " + stateName(state) + elapsed());
                    last = state;
                }
                if (state == target) {
                    log("RESULT: reached " + stateName(target) + elapsed());
                } else if (SystemClock.elapsedRealtime() - t0 >= STATE_TIMEOUT_MS) {
                    log("RESULT: TIMED OUT waiting for " + stateName(target) + ", last " + stateName(state));
                } else {
                    handler.postDelayed(this, POLL_MS);
                }
            }
        };
        handler.post(poller);
    }

    private void scan() {
        startAction("Scan");
        log("permissions: " + permissionSummary());
        handler.removeCallbacks(scanTimeout);
        boolean started;
        try {
            started = wifi.startScan();
        } catch (SecurityException e) {
            log("startScan SecurityException: " + e.getMessage());
            return;
        }
        log("startScan returned " + started);
        scanPending = true;
        handler.postDelayed(scanTimeout, SCAN_TIMEOUT_MS);
    }

    private void dumpScanResults() {
        List<ScanResult> results;
        try {
            results = wifi.getScanResults();
        } catch (SecurityException e) {
            log("getScanResults SecurityException: " + e.getMessage());
            return;
        }
        if (results == null) {
            log("getScanResults returned null");
            return;
        }
        log("RESULT: getScanResults count=" + results.size() + elapsed());
        List<ScanResult> sorted = new ArrayList<>(results);
        Collections.sort(sorted, new Comparator<ScanResult>() {
            @Override
            public int compare(ScanResult a, ScanResult b) {
                return b.level - a.level;
            }
        });
        for (int i = 0; i < Math.min(15, sorted.size()); i++) {
            ScanResult r = sorted.get(i);
            String ssid = r.SSID == null || r.SSID.isEmpty() ? "(hidden)" : r.SSID;
            log("  " + ssid + "  " + r.level + " dBm  " + r.frequency + " MHz  " + r.capabilities);
        }
    }

    private void savedNetworks() {
        startAction("Saved networks");
        List<WifiConfiguration> configs;
        try {
            configs = wifi.getConfiguredNetworks();
        } catch (SecurityException e) {
            log("getConfiguredNetworks SecurityException: " + e.getMessage());
            return;
        }
        if (configs == null) {
            log("getConfiguredNetworks returned null (Wi-Fi off?)");
            return;
        }
        log("RESULT: saved networks count=" + configs.size());
        for (WifiConfiguration c : configs) {
            log("  netId=" + c.networkId + " ssid=" + c.SSID + " status=" + configStatus(c.status));
        }
    }

    private void requestLocation() {
        startAction("Request ACCESS_COARSE_LOCATION");
        requestPermissions(new String[] {Manifest.permission.ACCESS_COARSE_LOCATION}, 1);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        log("location permission granted=" + granted);
    }

    // --- Helpers ---

    private void startAction(String name) {
        t0 = SystemClock.elapsedRealtime();
        log("=== " + name + " ===");
    }

    private String elapsed() {
        return " (+" + (SystemClock.elapsedRealtime() - t0) + " ms)";
    }

    private void log(String msg) {
        Log.i(TAG, msg);
        logView.append(clock.format(new Date()) + "  " + msg + "\n");
        scroll.post(new Runnable() {
            @Override
            public void run() {
                scroll.fullScroll(View.FOCUS_DOWN);
            }
        });
    }

    private String permissionSummary() {
        return "CHANGE_WIFI_STATE=" + granted(Manifest.permission.CHANGE_WIFI_STATE)
                + " COARSE_LOCATION=" + granted(Manifest.permission.ACCESS_COARSE_LOCATION)
                + " FINE_LOCATION=" + granted(Manifest.permission.ACCESS_FINE_LOCATION);
    }

    private boolean granted(String permission) {
        return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    private static String stateName(int state) {
        switch (state) {
            case WifiManager.WIFI_STATE_DISABLED: return "DISABLED";
            case WifiManager.WIFI_STATE_DISABLING: return "DISABLING";
            case WifiManager.WIFI_STATE_ENABLED: return "ENABLED";
            case WifiManager.WIFI_STATE_ENABLING: return "ENABLING";
            case WifiManager.WIFI_STATE_UNKNOWN: return "UNKNOWN";
            default: return "?" + state;
        }
    }

    private static String configStatus(int status) {
        switch (status) {
            case WifiConfiguration.Status.CURRENT: return "CURRENT";
            case WifiConfiguration.Status.DISABLED: return "DISABLED";
            case WifiConfiguration.Status.ENABLED: return "ENABLED";
            default: return "?" + status;
        }
    }

    private static String ipString(int ip) {
        return (ip & 0xff) + "." + ((ip >> 8) & 0xff) + "." + ((ip >> 16) & 0xff) + "." + ((ip >> 24) & 0xff);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
