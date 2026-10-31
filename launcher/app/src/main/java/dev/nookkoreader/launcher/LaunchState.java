package dev.nookkoreader.launcher;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.provider.Settings;

/** Writes before handing control to another process; process death cannot reset the guard. */
final class LaunchState {
    private final SharedPreferences prefs;
    private final int boot;

    LaunchState(Context context) {
        prefs = context.getSharedPreferences("launch_guard", Context.MODE_PRIVATE);
        boot = Settings.Global.getInt(context.getContentResolver(), Settings.Global.BOOT_COUNT, -1);
    }

    @SuppressLint("ApplySharedPref")
    String enter(boolean manual) {
        if (!manual && prefs.getBoolean("paused", false)) return "paused";
        LaunchGuard.Result result = LaunchGuard.enter(manual ? "" : prefs.getString("history", ""),
                prefs.getInt("boot", -1), boot, SystemClock.elapsedRealtime());
        boolean paused = result.decision != LaunchGuard.Decision.LAUNCH;
        if (!prefs.edit().putString("history", result.history).putInt("boot", boot)
                .putBoolean("paused", paused).commit()) return "storage";
        return paused ? "loop" : null;
    }

    @SuppressLint("ApplySharedPref")
    void pause() {
        prefs.edit().putBoolean("paused", true).commit();
    }
}
