package dev.nookkoreader.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/** Always-accessible launcher icon and latched escape screen. No privileged operations. */
public final class RecoveryActivity extends Activity {
    private TextView status;
    // False if the pause flag could not be saved when this screen opened.
    private boolean pausedOk = true;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        pausedOk = new LaunchState(this).pause();
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(0xffffffff);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(24);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root);
        TextView title = label(getString(R.string.app_name), 26);
        root.addView(title);
        status = label("", 18);
        status.setPadding(0, dp(16), 0, dp(16));
        root.addView(status);
        explain(getIntent());
        button(root, R.string.resume, v -> resumeReader());
        button(root, R.string.olauncher, v -> {
            if (!AppLaunch.openPackage(this, AppLaunch.OLAUNCHER)) unavailable();
        });
        button(root, R.string.home_settings, v -> {
            // The user chooses a default in Android; this app never changes it itself.
            if (!AppLaunch.open(this, new Intent(Settings.ACTION_HOME_SETTINGS))) {
                if (!AppLaunch.open(this, new Intent(Settings.ACTION_SETTINGS))) unavailable();
            }
        });
        button(root, R.string.android_settings, v -> {
            if (!AppLaunch.open(this, new Intent(Settings.ACTION_SETTINGS))) unavailable();
        });
        button(root, R.string.apps, v -> showApps());
        TextView tip = label(getString(R.string.recovery_tip), 16);
        tip.setPadding(0, dp(16), 0, 0);
        root.addView(tip);
        setContentView(scroll);
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        pausedOk = new LaunchState(this).pause();
        explain(intent);
    }

    private void explain(Intent intent) {
        String reason = intent.getStringExtra("reason");
        int message = R.string.paused;
        if ("loop".equals(reason)) message = R.string.loop;
        if ("missing".equals(reason)) message = R.string.missing;
        if ("storage".equals(reason)) message = R.string.storage;
        if ("unavailable".equals(reason)) message = R.string.guard_unavailable;
        if (!pausedOk) message = R.string.storage;
        status.setText(message);
    }

    private void resumeReader() {
        LaunchState state = new LaunchState(this);
        String reason = state.enter(true);
        if (reason != null) {
            boolean saved = state.pause();
            status.setText(!saved || "storage".equals(reason) ? R.string.storage : R.string.guard_unavailable);
        } else if (AppLaunch.openPackage(this, AppLaunch.KOREADER)) {
            finish();
        } else {
            status.setText(state.pause() ? R.string.missing : R.string.storage);
        }
    }

    private void showApps() {
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> apps = new ArrayList<>();
        for (ResolveInfo info : getPackageManager().queryIntentActivities(launcher, 0)) {
            if (info.activityInfo != null && info.activityInfo.exported
                    && !getPackageName().equals(info.activityInfo.packageName)) apps.add(info);
        }
        apps.sort(new ResolveInfo.DisplayNameComparator(getPackageManager()));
        String[] labels = new String[apps.size()];
        for (int i = 0; i < apps.size(); i++) {
            ResolveInfo info = apps.get(i);
            labels[i] = info.loadLabel(getPackageManager()) + "\n" + info.activityInfo.packageName;
        }
        new AlertDialog.Builder(this).setTitle(R.string.apps)
                .setItems(labels, (dialog, which) -> {
                    ResolveInfo info = apps.get(which);
                    Intent open = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                            .setComponent(new ComponentName(info.activityInfo.packageName, info.activityInfo.name))
                            .addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
                    if (!AppLaunch.open(this, open)) unavailable();
                }).setNegativeButton(android.R.string.cancel, null).show();
    }

    // Back must not finish the recovery HOME task and re-enter an automatic loop.
    // It is ignored without replacing the message explaining why recovery opened.
    @Override public void onBackPressed() {
    }

    private void unavailable() { status.setText(R.string.unavailable); }

    private TextView label(String text, int size) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(size);
        view.setTextColor(0xff000000);
        return view;
    }

    private void button(LinearLayout root, int text, View.OnClickListener click) {
        Button button = new Button(this);
        button.setText(text);
        button.setTextSize(20);
        button.setTextColor(0xff000000);
        button.setAllCaps(false);
        button.setMinHeight(dp(60));
        button.setOnClickListener(click);
        root.addView(button, new LinearLayout.LayoutParams(-1, -2));
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
