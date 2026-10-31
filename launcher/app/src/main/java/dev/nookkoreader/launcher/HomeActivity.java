package dev.nookkoreader.launcher;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;

/** Only HOME entries redirect. RecoveryActivity never redirects automatically. */
public final class HomeActivity extends Activity {
    // Logs each HOME entry and the guard's decision (no user data), so button
    // behavior can be checked with `make logs-launcher`.
    static final String TAG = "KOReaderHome";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        route("onCreate");
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        route("onNewIntent");
    }

    private void route(String via) {
        LaunchState state = new LaunchState(this);
        String reason = state.enter(false);
        Log.i(TAG, "HOME entry via " + via + " at " + SystemClock.elapsedRealtime() + " ms: "
                + (reason == null ? "launch KOReader" : reason));
        if (reason == null && AppLaunch.openPackage(this, AppLaunch.KOREADER)) {
            finish();
            return;
        }
        state.pause();
        Intent recovery = new Intent(this, RecoveryActivity.class);
        recovery.putExtra("reason", reason == null ? "missing" : reason);
        recovery.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        startActivity(recovery);
        finish();
    }
}
