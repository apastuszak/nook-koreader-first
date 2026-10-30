package dev.nookwifi.helper;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * The helper's only screen: grants the location permission that Android 8.1
 * requires for Wi-Fi scan results and the current network name, so setup does
 * not need ADB. Everything else happens through HelperProvider.
 */
public class SetupActivity extends Activity {
    private static final int REQUEST_LOCATION = 1;

    private TextView status;
    private Button allow;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = dp(32);
        root.setPadding(pad, pad, pad, pad);

        TextView title = text(getString(R.string.setup_title), 26);
        root.addView(title);
        TextView body = text(getString(R.string.setup_body), 18);
        body.setPadding(0, dp(24), 0, dp(24));
        root.addView(body);

        status = text("", 20);
        status.setPadding(0, 0, 0, dp(24));
        root.addView(status);

        allow = new Button(this);
        allow.setText(R.string.setup_allow);
        allow.setAllCaps(false);
        allow.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        allow.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                requestPermissions(new String[] {Manifest.permission.ACCESS_COARSE_LOCATION}, REQUEST_LOCATION);
            }
        });
        root.addView(allow, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(72)));

        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        refresh();
    }

    private void refresh() {
        boolean granted = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
        status.setText(granted ? R.string.setup_done : R.string.setup_needed);
        allow.setVisibility(granted ? View.GONE : View.VISIBLE);
    }

    private TextView text(String s, int sp) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(0xFF000000);
        return t;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
