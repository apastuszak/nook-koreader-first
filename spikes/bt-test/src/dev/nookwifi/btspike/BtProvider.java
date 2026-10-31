package dev.nookwifi.btspike;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothClass;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.reflect.Method;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Bluetooth Stage 0 spike. Each method answers one question about what a normal
 * app can do on the Nook. Results are logged under "BtSpike" and returned as a
 * "json" string. Only the ADB shell (UID 2000) may call it.
 *
 * adb shell content call --uri content://dev.nookwifi.btspike --method <m> [--arg <a>]
 *
 * Methods: state, enable, disable, bonded, discoverStart, discoverStop, found,
 * pair <addr>, unpair <addr>, hidConnect <addr>, hidDisconnect <addr>
 */
public final class BtProvider extends ContentProvider {
    private static final String TAG = "BtSpike";
    // BluetoothProfile.INPUT_DEVICE is hidden on API 27; its value is 4.
    private static final int INPUT_DEVICE = 4;

    private BluetoothAdapter adapter;
    private volatile BluetoothProfile hid;
    private final Map<String, JSONObject> found = new LinkedHashMap<>();

    @Override public boolean onCreate() {
        adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null) return true;
        connectHidProxy();
        IntentFilter filter = new IntentFilter();
        filter.addAction(BluetoothDevice.ACTION_FOUND);
        filter.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        filter.addAction(BluetoothDevice.ACTION_ACL_CONNECTED);
        filter.addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED);
        filter.addAction(BluetoothAdapter.ACTION_STATE_CHANGED);
        filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED);
        filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED);
        filter.addAction("android.bluetooth.input.profile.action.CONNECTION_STATE_CHANGED");
        getContext().registerReceiver(events, filter);
        return true;
    }

    private void connectHidProxy() {
        boolean ok = adapter.getProfileProxy(getContext(), new BluetoothProfile.ServiceListener() {
            @Override public void onServiceConnected(int profile, BluetoothProfile proxy) {
                hid = proxy;
                Log.i(TAG, "HID proxy connected: " + proxy.getClass().getName());
            }
            @Override public void onServiceDisconnected(int profile) {
                hid = null;
                Log.i(TAG, "HID proxy disconnected");
            }
        }, INPUT_DEVICE);
        Log.i(TAG, "getProfileProxy(INPUT_DEVICE) returned " + ok);
    }

    private final BroadcastReceiver events = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
            String what = intent.getAction();
            if (BluetoothDevice.ACTION_FOUND.equals(what) && device != null) {
                try {
                    JSONObject d = describe(device);
                    d.put("rssi", intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE));
                    synchronized (found) { found.put(device.getAddress(), d); }
                } catch (Exception e) {
                    Log.w(TAG, "found", e);
                }
            }
            StringBuilder line = new StringBuilder("event ").append(what);
            if (device != null) line.append(" device=").append(device.getName());
            if (intent.hasExtra(BluetoothDevice.EXTRA_BOND_STATE)) {
                line.append(" bond=").append(intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1));
            }
            if (intent.hasExtra(BluetoothAdapter.EXTRA_STATE)) {
                line.append(" state=").append(intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1));
            }
            if (intent.hasExtra(BluetoothProfile.EXTRA_STATE)) {
                line.append(" profileState=").append(intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1));
            }
            Log.i(TAG, line.toString());
        }
    };

    @Override public Bundle call(String method, String arg, Bundle extras) {
        JSONObject reply = new JSONObject();
        try {
            int uid = Binder.getCallingUid();
            if (uid != 2000 && uid != 0) { // ADB shell or root
                reply.put("error", "caller_not_allowed");
            } else if (adapter == null) {
                reply.put("error", "no_adapter");
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

    private void run(String method, String arg, JSONObject reply) throws Exception {
        switch (method) {
            case "state":
                reply.put("enabled", adapter.isEnabled());
                reply.put("state", adapter.getState());
                reply.put("discovering", adapter.isDiscovering());
                reply.put("hidProxy", hid != null);
                break;
            case "enable":
                reply.put("accepted", adapter.enable());
                break;
            case "disable":
                reply.put("accepted", adapter.disable());
                break;
            case "bonded": {
                JSONArray list = new JSONArray();
                for (BluetoothDevice d : adapter.getBondedDevices()) list.put(describe(d));
                reply.put("devices", list);
                break;
            }
            case "discoverStart":
                synchronized (found) { found.clear(); }
                reply.put("accepted", adapter.startDiscovery());
                break;
            case "discoverStop":
                reply.put("accepted", adapter.cancelDiscovery());
                break;
            case "found": {
                JSONArray list = new JSONArray();
                synchronized (found) { for (JSONObject d : found.values()) list.put(d); }
                reply.put("discovering", adapter.isDiscovering());
                reply.put("devices", list);
                break;
            }
            case "pair":
                reply.put("accepted", device(arg).createBond());
                break;
            case "unpair":
                reply.put("result", invoke(device(arg), "removeBond"));
                break;
            case "hidConnect":
                reply.put("result", invokeHid("connect", device(arg)));
                break;
            case "hidDisconnect":
                reply.put("result", invokeHid("disconnect", device(arg)));
                break;
            default:
                reply.put("error", "unknown_method");
        }
    }

    private BluetoothDevice device(String address) {
        if (address == null || !BluetoothAdapter.checkBluetoothAddress(address)) {
            throw new IllegalArgumentException("bad address");
        }
        return adapter.getRemoteDevice(address);
    }

    private JSONObject describe(BluetoothDevice d) throws Exception {
        JSONObject o = new JSONObject();
        o.put("name", d.getName());
        o.put("address", d.getAddress());
        o.put("type", d.getType());
        o.put("bond", d.getBondState());
        BluetoothClass cls = d.getBluetoothClass();
        if (cls != null) {
            o.put("majorClass", Integer.toHexString(cls.getMajorDeviceClass()));
            o.put("deviceClass", Integer.toHexString(cls.getDeviceClass()));
            o.put("peripheral", cls.getMajorDeviceClass() == BluetoothClass.Device.Major.PERIPHERAL);
        }
        BluetoothProfile proxy = hid;
        if (proxy != null) o.put("hidState", proxy.getConnectionState(d));
        return o;
    }

    // Hidden APIs, called by reflection. API 27 has no hidden-API restrictions, but
    // the framework may still enforce a privileged permission: that is the question.
    private static Object invoke(Object target, String name) throws Exception {
        Method m = target.getClass().getMethod(name);
        return m.invoke(target);
    }

    private Object invokeHid(String name, BluetoothDevice device) throws Exception {
        BluetoothProfile proxy = hid;
        if (proxy == null) throw new IllegalStateException("HID proxy not connected");
        Method m = proxy.getClass().getMethod(name, BluetoothDevice.class);
        return m.invoke(proxy, device);
    }

    @Override public Cursor query(Uri uri, String[] p, String s, String[] a, String o) { return null; }
    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override public int delete(Uri uri, String s, String[] a) { return 0; }
    @Override public int update(Uri uri, ContentValues v, String s, String[] a) { return 0; }
}
