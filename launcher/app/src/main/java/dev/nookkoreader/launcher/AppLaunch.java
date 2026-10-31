package dev.nookkoreader.launcher;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;

final class AppLaunch {
    static final String KOREADER = "org.koreader.launcher";
    private AppLaunch() { }

    static boolean openPackage(Activity activity, String pkg) {
        Intent intent = activity.getPackageManager().getLaunchIntentForPackage(pkg);
        return intent != null && open(activity, intent);
    }

    // Asks Android to return to Home when KOReader exits. On the Nook this alone did
    // not help when KOReader was opened from RecoveryActivity with other apps' tasks
    // behind it, so RecoveryActivity resumes through a real HOME intent instead.
    static boolean openReader(Activity activity) {
        Intent intent = activity.getPackageManager().getLaunchIntentForPackage(KOREADER);
        return intent != null && open(activity, intent.addFlags(Intent.FLAG_ACTIVITY_TASK_ON_HOME));
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
