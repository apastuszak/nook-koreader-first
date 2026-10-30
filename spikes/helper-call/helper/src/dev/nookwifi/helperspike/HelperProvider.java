package dev.nookwifi.helperspike;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.net.wifi.WifiManager;
import android.os.Binder;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * Stage 0 Test 2 stub. Exposes call() only; every reply is a Bundle with a
 * single "json" string so the Lua side needs just one getString() over JNI.
 */
public class HelperProvider extends ContentProvider {
    private static final String TAG = "WifiHelperSpike";
    private static final int PROTOCOL = 1;

    @Override
    public boolean onCreate() {
        Log.i(TAG, "onCreate, process up " + processUptimeMs() + " ms");
        return true;
    }

    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        Log.i(TAG, "call method=" + method + " from " + getCallingPackage());
        JSONObject reply = new JSONObject();
        try {
            reply.put("protocol", PROTOCOL);
            reply.put("method", method);
            switch (method) {
                case "ping":
                    reply.put("ok", true);
                    reply.put("callingPackage", getCallingPackage());
                    reply.put("callingUid", Binder.getCallingUid());
                    reply.put("helperPid", Process.myPid());
                    reply.put("processUptimeMs", processUptimeMs());
                    break;
                case "echo":
                    reply.put("ok", true);
                    reply.put("echo", arg);
                    reply.put("length", arg == null ? -1 : arg.length());
                    reply.put("extrasKey", extras == null ? null : extras.getString("key"));
                    break;
                case "wifiState":
                    WifiManager wifi = (WifiManager) getContext().getApplicationContext()
                            .getSystemService(Context.WIFI_SERVICE);
                    reply.put("ok", true);
                    reply.put("enabled", wifi.isWifiEnabled());
                    reply.put("state", wifi.getWifiState());
                    break;
                case "fail":
                    // IllegalStateException is one of the types Binder re-throws in the caller.
                    throw new IllegalStateException("deliberate failure from helper");
                default:
                    reply.put("ok", false);
                    reply.put("error", "unknown_method");
            }
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
        Bundle out = new Bundle();
        out.putString("json", reply.toString());
        return out;
    }

    private static long processUptimeMs() {
        return SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime();
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
