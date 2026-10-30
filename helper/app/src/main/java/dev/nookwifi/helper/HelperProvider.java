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

import org.json.JSONException;
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

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        String caller = getCallingPackage();
        // Log the method only; args will carry passwords in later stages.
        Log.i(TAG, "call " + method + " from " + caller);
        JSONObject reply;
        try {
            if (!isAllowed(caller)) {
                reply = error("caller_not_allowed");
            } else {
                reply = dispatch(method);
            }
        } catch (RuntimeException | JSONException e) {
            Log.e(TAG, "call " + method + " failed", e);
            reply = error("internal_error");
        }
        try {
            reply.put("protocol", PROTOCOL);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
        Bundle out = new Bundle();
        out.putString("json", reply.toString());
        return out;
    }

    private JSONObject dispatch(String method) throws JSONException {
        switch (method) {
            case "ping":
                return ping();
            default:
                return error("unknown_method");
        }
    }

    private JSONObject ping() throws JSONException {
        JSONObject reply = ok();
        try {
            PackageInfo info = getContext().getPackageManager()
                    .getPackageInfo(getContext().getPackageName(), 0);
            reply.put("versionName", info.versionName);
            reply.put("versionCode", info.versionCode);
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

    private static JSONObject ok() throws JSONException {
        return new JSONObject().put("ok", true);
    }

    private static JSONObject error(String code) {
        try {
            return new JSONObject().put("ok", false).put("error", code);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
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
