package dev.nookwifi.helper;

import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.provider.Settings;
import android.util.Log;

import org.json.JSONObject;

/**
 * The Nook's power-off timer, behind the helper's powerOff* methods: how long
 * the Nook may sleep before it powers off (see PowerRules).
 *
 * Writing needs "Modify system settings" (WRITE_SETTINGS, a special app op the
 * user allows on Android's own screen; powerOffOpenSettings opens it). With it,
 * this firmware accepts writes to power_off_timeout from a normal app targeting
 * API 27, although it is not a public setting (verified with spikes/settings-test).
 * Without it, putInt throws SecurityException. Settings.System.canWrite was not
 * reliable there (it stayed true after the grant was reset), so writes are tried
 * and the exception reported.
 *
 * When an app is uninstalled, Android 8 deletes the system settings it last
 * wrote; a missing power_off_timeout reads as 0 (never) to the firmware
 * (verified), so uninstalling the helper only drops the timer.
 */
final class PowerOps {
    private final Context context;

    PowerOps(Context context) {
        this.context = context.getApplicationContext();
    }

    /** Reply field timeoutMs: the current timeout, 0 for never (also when unset). */
    JSONObject get() {
        return Replies.put(Replies.ok(), "timeoutMs", currentTimeout());
    }

    /**
     * arg is one of PowerRules.ALLOWED_MS. Replies with the value read back, or
     * "write_settings_needed" if the user has not allowed it.
     */
    JSONObject set(String arg) {
        int timeout = PowerRules.parseAllowed(arg);
        if (timeout < 0) {
            return Replies.error("bad_argument");
        }
        ContentResolver resolver = context.getContentResolver();
        try {
            if (!Settings.System.putInt(resolver, PowerRules.SETTING, timeout)) {
                return Replies.error("request_rejected");
            }
        } catch (SecurityException e) {
            return Replies.error("write_settings_needed");
        } catch (IllegalArgumentException e) {
            // Stock Android refuses non-public settings from apps targeting API 23+;
            // this firmware does not, but another one might.
            Log.w(HelperProvider.TAG, "power_off_timeout refused: " + e.getClass().getSimpleName());
            return Replies.error("not_supported");
        }
        return Replies.put(Replies.ok(), "timeoutMs", currentTimeout());
    }

    /** Opens Android's "Modify system settings" screen for the helper. */
    JSONObject openSettings() {
        Intent intent = new Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS,
                Uri.parse("package:" + context.getPackageName()))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            context.startActivity(intent);
            return Replies.ok();
        } catch (ActivityNotFoundException | SecurityException e) {
            return Replies.error("settings_unavailable");
        }
    }

    private int currentTimeout() {
        return Settings.System.getInt(context.getContentResolver(), PowerRules.SETTING, 0);
    }
}
