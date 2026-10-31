package dev.nookwifi.settingsspike;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;

import org.json.JSONObject;

/**
 * Power-off timer spike. Answers whether a normal app may write the Nook's hidden
 * power_off_timeout (and, for comparison, the public screen_off_timeout). Results
 * are logged under "SettingsSpike" and returned as a "json" string. Only the ADB
 * shell (UID 2000) may call it.
 *
 * adb shell content call --uri content://dev.nookwifi.settingsspike --method <m> [--arg <a>]
 *
 * Methods: canWrite, get <key>, put <key>=<int>
 */
public final class SettingsProvider extends ContentProvider {
    private static final String TAG = "SettingsSpike";

    @Override public boolean onCreate() {
        return true;
    }

    @Override public Bundle call(String method, String arg, Bundle extras) {
        JSONObject reply = new JSONObject();
        try {
            int uid = Binder.getCallingUid();
            if (uid != 2000 && uid != 0) { // ADB shell or root
                reply.put("error", "caller_not_allowed");
            } else {
                run(method, arg, reply);
            }
        } catch (Throwable t) {
            try {
                reply.put("error", t.getClass().getName() + ": " + t.getMessage());
            } catch (Exception ignored) {
            }
        }
        Log.i(TAG, method + (arg == null ? "" : " " + arg) + " -> " + reply);
        Bundle out = new Bundle();
        out.putString("json", reply.toString());
        return out;
    }

    private static boolean allowedKey(String key) {
        return "power_off_timeout".equals(key) || "screen_off_timeout".equals(key);
    }

    private void run(String method, String arg, JSONObject reply) throws Exception {
        switch (method) {
            case "canWrite":
                reply.put("canWrite", Settings.System.canWrite(getContext()));
                break;
            case "get":
                if (!allowedKey(arg)) {
                    reply.put("error", "bad_key");
                    break;
                }
                reply.put("value", Settings.System.getString(getContext().getContentResolver(), arg));
                break;
            case "put": {
                String[] kv = arg == null ? new String[0] : arg.split("=", 2);
                if (kv.length != 2 || !allowedKey(kv[0])) {
                    reply.put("error", "bad_argument");
                    break;
                }
                int value = Integer.parseInt(kv[1]);
                boolean ok = Settings.System.putInt(getContext().getContentResolver(), kv[0], value);
                reply.put("ok", ok);
                reply.put("readBack", Settings.System.getString(getContext().getContentResolver(), kv[0]));
                break;
            }
            default:
                reply.put("error", "unknown_method");
        }
    }

    @Override public Cursor query(Uri uri, String[] p, String s, String[] a, String o) { return null; }
    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override public int delete(Uri uri, String s, String[] a) { return 0; }
    @Override public int update(Uri uri, ContentValues v, String s, String[] a) { return 0; }
}
