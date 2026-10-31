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
import java.util.function.Consumer;
import java.util.function.Predicate;

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
        button(root, R.string.other_launcher, v -> showOtherLaunchers());
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
        if (isDefaultHome() && state.resume() && startHome()) {
            finish();
            return;
        }
        String reason = state.enter(true);
        if (reason != null) {
            boolean saved = state.pause();
            status.setText(!saved || "storage".equals(reason) ? R.string.storage : R.string.guard_unavailable);
        } else if (AppLaunch.openReader(this)) {
            finish();
        } else {
            status.setText(state.pause() ? R.string.missing : R.string.storage);
        }
    }

    private boolean isDefaultHome() {
        ResolveInfo home = getPackageManager().resolveActivity(homeIntent(), 0);
        return home != null && home.activityInfo != null
                && getPackageName().equals(home.activityInfo.packageName);
    }

    // An implicit HOME intent with HOME as its only category starts HomeActivity as
    // Android's Home, which then opens KOReader. A KOReader task opened from Home
    // returns to Home on exit; one opened from this screen returns to whatever app
    // was open behind it (e.g. another launcher picked here). Explicit components
    // would make it an ordinary activity start, so the intent must stay implicit.
    private static Intent homeIntent() {
        return new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
    }

    private boolean startHome() {
        return AppLaunch.open(this, homeIntent());
    }

    private void showApps() {
        Intent query = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        pickAndOpen(query, R.string.apps, info -> true, this::openFromDrawer);
    }

    // Every other installed Home app (e.g. Olauncher, the Nook's own launcher), so this
    // works with whatever launcher the user keeps. Entries with negative priority, such
    // as Android's FallbackHome (only for boot/encryption screens), are skipped, and so
    // is com.android.settings in case a firmware gives FallbackHome a normal priority.
    private void showOtherLaunchers() {
        Intent query = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        pickAndOpen(query, R.string.other_launcher,
                info -> info.priority >= 0 && !"com.android.settings".equals(info.activityInfo.packageName),
                this::openLauncher);
    }

    // Shared picker: other apps' exported activities matching query and keep. With one
    // match it opens directly; with several it asks. Opening never changes the default.
    private void pickAndOpen(Intent query, int title, Predicate<ResolveInfo> keep, Consumer<ResolveInfo> open) {
        List<ResolveInfo> found = new ArrayList<>();
        for (ResolveInfo info : getPackageManager().queryIntentActivities(query, 0)) {
            if (info.activityInfo != null && info.activityInfo.exported
                    && !getPackageName().equals(info.activityInfo.packageName) && keep.test(info)) {
                found.add(info);
            }
        }
        if (found.isEmpty()) {
            showStatus(R.string.no_other_launcher);
            return;
        }
        if (found.size() == 1 && title == R.string.other_launcher) {
            open.accept(found.get(0));
            return;
        }
        found.sort(new ResolveInfo.DisplayNameComparator(getPackageManager()));
        String[] labels = new String[found.size()];
        for (int i = 0; i < found.size(); i++) {
            ResolveInfo info = found.get(i);
            labels[i] = info.loadLabel(getPackageManager()) + "\n" + info.activityInfo.packageName;
            if (sharesPackage(found, info)) labels[i] += " (" + info.activityInfo.name + ")";
        }
        new AlertDialog.Builder(this).setTitle(title)
                .setItems(labels, (dialog, which) -> open.accept(found.get(which)))
                .setNegativeButton(android.R.string.cancel, null).show();
    }

    // Two entries from one package would otherwise look identical in the list.
    private static boolean sharesPackage(List<ResolveInfo> all, ResolveInfo info) {
        for (ResolveInfo other : all) {
            if (other != info && other.activityInfo.packageName.equals(info.activityInfo.packageName)) return true;
        }
        return false;
    }

    private void openFromDrawer(ResolveInfo info) {
        Intent open = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .setComponent(new ComponentName(info.activityInfo.packageName, info.activityInfo.name))
                .addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        if (!AppLaunch.open(this, open)) unavailable();
    }

    // Prefers the launcher's app-drawer entry, the path verified on the Nook for
    // Olauncher in 0.1.0. Falls back to an explicit start of its HOME component, which
    // for a third-party caller is an ordinary activity start, not a Home-type one.
    private void openLauncher(ResolveInfo info) {
        if (AppLaunch.openPackage(this, info.activityInfo.packageName)) return;
        Intent open = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                .setComponent(new ComponentName(info.activityInfo.packageName, info.activityInfo.name));
        if (!AppLaunch.open(this, open)) unavailable();
    }

    // Back must not finish the recovery HOME task and re-enter an automatic loop.
    // It is ignored without replacing the message explaining why recovery opened.
    @Override public void onBackPressed() {
    }

    private void unavailable() { showStatus(R.string.unavailable); }

    // Keeps the "could not save the restart guard" warning visible under any later message.
    private void showStatus(int message) {
        status.setText(pausedOk ? getString(message)
                : getString(R.string.storage) + "\n\n" + getString(message));
    }

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
