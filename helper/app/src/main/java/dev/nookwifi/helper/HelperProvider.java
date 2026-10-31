package dev.nookwifi.helper;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.util.Log;

import org.json.JSONObject;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * The helper's only interface. KOReader calls
 * {@code ContentResolver.call(content://dev.nookwifi.helper, method, arg, extras)}
 * and gets back a Bundle holding one "json" string. Every reply has "ok" and
 * "protocol"; failures also carry an "error" code. call() never throws, so the
 * plugin sees a Java exception only when the helper is missing.
 *
 * Methods: ping, getState, setEnabled(arg "true"|"false"), listSaved,
 * connectSaved(arg networkId), reconnect, scan, scanResults,
 * join(extras ssid/security/password), forget(arg networkId). See WifiOps for fields.
 *
 * Bluetooth (page-turner remotes): btState, btSetEnabled(arg "true"|"false"),
 * btPaired, btDevice(arg address), btScan, btScanStop, btScanResults,
 * btPair(arg address), btForget(arg address), btOpenSettings. See BluetoothOps.
 *
 * Power-off timer: powerOffGet, powerOffSet(arg milliseconds), powerOffOpenSettings.
 * See PowerOps.
 */
public class HelperProvider extends ContentProvider {
    static final String TAG = "NookWifi";
    static final int PROTOCOL = 1;

    private static final Set<String> ALLOWED_CALLERS =
            Collections.unmodifiableSet(new HashSet<>(Arrays.asList("org.koreader.launcher")));
    // Lets `adb shell content call` exercise debug builds without KOReader. On API 27
    // that command sends no calling package, so match the shell's fixed UID
    // (Process.SHELL_UID, hidden before API 29).
    private static final int SHELL_UID = 2000;

    private WifiOps wifi;
    private BluetoothOps bluetooth;
    private PowerOps power;

    @Override
    public boolean onCreate() {
        wifi = new WifiOps(getContext());
        bluetooth = new BluetoothOps(getContext());
        power = new PowerOps(getContext());
        return true;
    }

    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        JSONObject reply;
        try {
            // Throws SecurityException if the caller's package and UID do not match.
            String caller = getCallingPackage();
            // Log the method only: join's extras carry a password.
            Log.i(TAG, "call " + method + " from " + caller);
            if (!isAllowed(caller)) {
                reply = Replies.error("caller_not_allowed");
            } else {
                reply = dispatch(method, arg, extras);
            }
        } catch (SecurityException e) {
            Log.w(TAG, "call " + method + ": caller identity check failed");
            reply = Replies.error("caller_not_allowed");
        } catch (RuntimeException e) {
            // The exception, not the arguments: those may include a password.
            Log.e(TAG, "call " + method + " failed", e);
            reply = Replies.error("internal_error");
        }
        Replies.put(reply, "protocol", PROTOCOL);
        Bundle out = new Bundle();
        out.putString("json", reply.toString());
        return out;
    }

    private JSONObject dispatch(String method, String arg, Bundle extras) {
        switch (method) {
            case "ping":
                return ping();
            case "getState":
                return wifi.getState();
            case "setEnabled":
                return wifi.setEnabled(arg);
            case "listSaved":
                return wifi.listSaved();
            case "connectSaved":
                return wifi.connectSaved(arg);
            case "reconnect":
                return wifi.reconnect();
            case "scan":
                return wifi.startScan();
            case "scanResults":
                return wifi.scanResults();
            case "join":
                return wifi.join(extras);
            case "forget":
                return wifi.forget(arg);
            case "btState":
                return bluetooth.getState();
            case "btSetEnabled":
                return bluetooth.setEnabled(arg);
            case "btPaired":
                return bluetooth.listPaired();
            case "btDevice":
                return bluetooth.device(arg);
            case "btScan":
                return bluetooth.startScan();
            case "btScanStop":
                return bluetooth.stopScan();
            case "btScanResults":
                return bluetooth.scanResults();
            case "btPair":
                return bluetooth.pair(arg);
            case "btForget":
                return bluetooth.forget(arg);
            case "btOpenSettings":
                return bluetooth.openSettings();
            case "powerOffGet":
                return power.get();
            case "powerOffSet":
                return power.set(arg);
            case "powerOffOpenSettings":
                return power.openSettings();
            default:
                return Replies.error("unknown_method");
        }
    }

    private JSONObject ping() {
        JSONObject reply = Replies.ok();
        try {
            PackageInfo info = getContext().getPackageManager()
                    .getPackageInfo(getContext().getPackageName(), 0);
            Replies.put(reply, "versionName", info.versionName);
            Replies.put(reply, "versionCode", info.versionCode);
        } catch (PackageManager.NameNotFoundException e) {
            throw new IllegalStateException(e);
        }
        return reply;
    }

    private boolean isAllowed(String caller) {
        if (caller != null && ALLOWED_CALLERS.contains(caller)) {
            return true;
        }
        boolean debuggable = (getContext().getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        return debuggable && Binder.getCallingUid() == SHELL_UID;
    }

    // Unused ContentProvider surface.

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
