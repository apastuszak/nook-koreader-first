package dev.nookkoreader.launcher;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;

final class AppLaunch {
    static final String KOREADER = "org.koreader.launcher";
    static final String OLAUNCHER = "app.olauncher";
    private AppLaunch() { }

    static boolean openPackage(Activity activity, String pkg) {
        Intent intent = activity.getPackageManager().getLaunchIntentForPackage(pkg);
        return intent != null && open(activity, intent);
    }

    static boolean open(Activity activity, Intent intent) {
        try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(intent);
            activity.overridePendingTransition(0, 0);
            return true;
        } catch (ActivityNotFoundException | SecurityException e) {
            return false;
        }
    }
}
