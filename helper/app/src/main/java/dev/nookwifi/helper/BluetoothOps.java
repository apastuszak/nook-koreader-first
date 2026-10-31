package dev.nookwifi.helper;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothClass;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.ActivityNotFoundException;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import static dev.nookwifi.helper.BluetoothRules.adapterState;
import static dev.nookwifi.helper.BluetoothRules.bondState;
import static dev.nookwifi.helper.BluetoothRules.connectionState;
import static dev.nookwifi.helper.BluetoothRules.isLikelyRemote;
import static dev.nookwifi.helper.BluetoothRules.isValidAddress;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Bluetooth operations for page-turner remotes, behind the helper's bt* methods.
 * Like WifiOps, nothing here waits for a state change: the plugin polls.
 *
 * Verified on the Nook in Bluetooth Stage 0 (spikes/bt-test): enable/disable,
 * bonded devices, discovery, createBond (HID then connects by itself) and the
 * hidden removeBond all work for a normal app on API 27, with no popup for the
 * 8BitDo Micro. Device addresses are never logged.
 */
// Lint applies API 31+ rules (BLUETOOTH_CONNECT, BLUETOOTH_SCAN, runtime grants)
// because compileSdk is newer. On API 27 BLUETOOTH and BLUETOOTH_ADMIN are
// install-time permissions declared in the manifest, and discovery's location
// permission is checked in startScan.
@SuppressLint("MissingPermission")
final class BluetoothOps {
    // BluetoothProfile.INPUT_DEVICE (HID host) is hidden on API 27; its value is 4.
    private static final int INPUT_DEVICE = 4;
    private static final ComponentName STOCK_SETTINGS =
            new ComponentName("com.android.settings", "com.android.settings.Settings$BluetoothSettingsActivity");

    private final Context context;
    private final BluetoothAdapter adapter;
    // HID host proxy, for each remote's connection state. Android drops it when
    // Bluetooth turns off and the Bluetooth process restarts when it turns on;
    // the proxy rebinds by itself (seen in Stage 0). Null until bound.
    private volatile BluetoothProfile hid;

    // Discovery results since the last btScan, by address, described when asked:
    // Android often learns a device's name only after first finding it. In memory
    // only: if Android kills the helper mid-scan, the plugin times out.
    private final Map<String, BluetoothDevice> found = new LinkedHashMap<>();
    private volatile boolean scanRequested;
    // "Finished" counts only after Android confirmed this scan started: startScan
    // cancels any running discovery first, and that cancellation's FINISHED
    // broadcast can arrive after the new request (seen on the Nook: a second
    // scan reported finished on its first poll).
    private volatile boolean scanStarted;
    private volatile boolean scanFinished;

    // Removals requested by forget(), by address: false until Android's
    // BOND_STATE_CHANGED broadcast reports the bond gone. getBondState() cannot
    // confirm it, because Android 8.1 also returns BOND_NONE when the Bluetooth
    // service is down or the call fails. In memory only: if Android kills the
    // helper mid-removal, the plugin times out and points to Android settings.
    private final Map<String, Boolean> removals = new HashMap<>();
    // Pairings requested by pair(), by address: true once Android's broadcast
    // reports bonding -> none. A failed pairing can pass in well under the
    // plugin's 0.5 s poll (70 ms seen on the Nook), and getBondState()'s "none"
    // is ambiguous for the same reason as above. Guarded by removals' lock.
    private final Map<String, Boolean> pairings = new HashMap<>();

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent intent) {
            String action = intent.getAction();
            if (BluetoothDevice.ACTION_FOUND.equals(action)) {
                BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                if (device != null && scanRequested) {
                    synchronized (found) {
                        found.put(device.getAddress(), device);
                    }
                }
            } else if (BluetoothAdapter.ACTION_DISCOVERY_STARTED.equals(action)) {
                if (scanRequested) {
                    scanStarted = true;
                }
            } else if (BluetoothAdapter.ACTION_DISCOVERY_FINISHED.equals(action)) {
                if (scanRequested && scanStarted) {
                    scanFinished = true;
                }
            } else if (BluetoothDevice.ACTION_BOND_STATE_CHANGED.equals(action)) {
                BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                int bond = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR);
                int previous = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR);
                if (device != null && bond == BluetoothDevice.BOND_NONE) {
                    synchronized (removals) {
                        if (removals.containsKey(device.getAddress())) {
                            removals.put(device.getAddress(), true);
                        }
                        if (previous == BluetoothDevice.BOND_BONDING && pairings.containsKey(device.getAddress())) {
                            pairings.put(device.getAddress(), true);
                        }
                    }
                }
            }
        }
    };

    BluetoothOps(Context context) {
        this.context = context.getApplicationContext();
        this.adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null) {
            return;
        }
        adapter.getProfileProxy(this.context, new BluetoothProfile.ServiceListener() {
            @Override
            public void onServiceConnected(int profile, BluetoothProfile proxy) {
                hid = proxy;
            }

            @Override
            public void onServiceDisconnected(int profile) {
                hid = null;
            }
        }, INPUT_DEVICE);
        IntentFilter filter = new IntentFilter();
        filter.addAction(BluetoothDevice.ACTION_FOUND);
        filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED);
        filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED);
        filter.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        // Lives as long as the helper process, like WifiOps' receiver.
        this.context.registerReceiver(receiver, filter);
    }

    /**
     * Reply fields: available (false if the device has no Bluetooth),
     * bluetoothState (off|turning_on|on|turning_off|unknown), enabled, discovering,
     * hidReady (whether remotes' connection states can be read yet), and screenOn
     * (PowerManager.isInteractive). KOReader on Android sends the same event when
     * the Nook sleeps and when another app opens; screenOn tells them apart.
     */
    JSONObject getState() {
        return putState(Replies.ok());
    }

    /** arg is "true" or "false". Returns as soon as Android accepts the request. */
    JSONObject setEnabled(String arg) {
        if (adapter == null) {
            return putState(Replies.error("bt_unavailable"));
        }
        boolean accepted;
        if ("true".equals(arg)) {
            accepted = adapter.enable();
        } else if ("false".equals(arg)) {
            accepted = adapter.disable();
        } else {
            return Replies.error("bad_argument");
        }
        return putState(accepted ? Replies.ok() : Replies.error("request_rejected"));
    }

    /**
     * Paired devices as "devices": [{address, name, remote, bond, connection}].
     * connection is left out while the HID proxy is not bound yet. Works with
     * Bluetooth off (the list is then empty on Android 8.1).
     */
    JSONObject listPaired() {
        if (adapter == null) {
            return putState(Replies.error("bt_unavailable"));
        }
        JSONArray devices = new JSONArray();
        for (BluetoothDevice d : adapter.getBondedDevices()) {
            devices.put(describe(d));
        }
        return Replies.put(putState(Replies.ok()), "devices", devices);
    }

    /**
     * One device by address (arg): the same fields as in listPaired, plus
     * "forgotten" (true once Android reported the bond removed after btForget)
     * and "pairFailed" (true once Android reported a btPair attempt failed).
     */
    JSONObject device(String arg) {
        if (adapter == null) {
            return putState(Replies.error("bt_unavailable"));
        }
        if (!isValidAddress(arg)) {
            return Replies.error("bad_argument");
        }
        JSONObject device = describe(adapter.getRemoteDevice(arg));
        synchronized (removals) {
            Replies.put(device, "forgotten", Boolean.TRUE.equals(removals.get(arg)));
            Replies.put(device, "pairFailed", Boolean.TRUE.equals(pairings.get(arg)));
        }
        return Replies.put(putState(Replies.ok()), "device", device);
    }

    /**
     * Starts discovery (about 14 s on the Nook). Callers poll scanResults until
     * "finished". Needs coarse location, like Wi-Fi scanning.
     */
    JSONObject startScan() {
        if (adapter == null) {
            return putState(Replies.error("bt_unavailable"));
        }
        if (!adapter.isEnabled()) {
            return putState(Replies.error("bt_disabled"));
        }
        if (!WifiOps.hasLocationPermission(context)) {
            return Replies.error("location_permission_needed");
        }
        synchronized (found) {
            found.clear();
        }
        adapter.cancelDiscovery();
        scanStarted = false;
        scanFinished = false;
        scanRequested = true;
        if (!adapter.startDiscovery()) {
            scanRequested = false;
            return putState(Replies.error("request_rejected"));
        }
        return putState(Replies.ok());
    }

    /**
     * Stops discovery early, e.g. when the plugin's list closes. Skipped while a
     * pairing is in progress: cancelDiscovery also cancels the remote-name
     * request that starts bonding, and the pairing then fails (seen on the Nook
     * when the list's close came 30 ms after btPair). pair() already stopped
     * discovery before bonding.
     */
    JSONObject stopScan() {
        if (adapter != null && !pairingInProgress()) {
            adapter.cancelDiscovery();
        }
        return putState(Replies.ok());
    }

    private boolean pairingInProgress() {
        List<String> addresses;
        synchronized (removals) {
            addresses = new ArrayList<>(pairings.keySet());
        }
        for (String address : addresses) {
            if (adapter.getRemoteDevice(address).getBondState() == BluetoothDevice.BOND_BONDING) {
                return true;
            }
        }
        return false;
    }

    /**
     * Devices found since the last btScan that have a name, as "devices" (same
     * fields as listPaired), plus "finished" once discovery ended. Unnamed devices
     * (mostly BLE beacons and phones; 19 nearby in Stage 0) are left out.
     */
    JSONObject scanResults() {
        if (adapter == null) {
            return putState(Replies.error("bt_unavailable"));
        }
        // Copied first, so the receiver is not held up by the calls below. The
        // name is checked before describing: each describe() makes several calls
        // into the Bluetooth service, the plugin polls every 0.5 s, and most
        // devices found nearby have no name (19 devices in Stage 0).
        List<BluetoothDevice> snapshot;
        synchronized (found) {
            snapshot = new ArrayList<>(found.values());
        }
        JSONArray devices = new JSONArray();
        for (BluetoothDevice device : snapshot) {
            String name = device.getName();
            if (name != null && !name.isEmpty()) {
                devices.put(describe(device));
            }
        }
        JSONObject reply = putState(Replies.ok());
        Replies.put(reply, "devices", devices);
        Replies.put(reply, "finished", scanFinished);
        return reply;
    }

    /**
     * Pairs with the device at arg. Android connects HID by itself once bonded
     * (Stage 0); a remote that needs a PIN gets Android's own pairing dialog.
     * Callers poll device(arg).
     */
    JSONObject pair(String arg) {
        if (adapter == null) {
            return putState(Replies.error("bt_unavailable"));
        }
        if (!isValidAddress(arg)) {
            return Replies.error("bad_argument");
        }
        if (!adapter.isEnabled()) {
            return putState(Replies.error("bt_disabled"));
        }
        BluetoothDevice device = adapter.getRemoteDevice(arg);
        if (device.getBondState() == BluetoothDevice.BOND_BONDED) {
            return putState(Replies.error("already_paired"));
        }
        // Recorded before the request, so a broadcast that arrives at once counts.
        synchronized (removals) {
            removals.remove(arg);
            pairings.put(arg, false);
        }
        // Discovery slows bonding down; Android recommends stopping it first.
        adapter.cancelDiscovery();
        if (!device.createBond()) {
            synchronized (removals) {
                pairings.remove(arg);
            }
            return putState(Replies.error("request_rejected"));
        }
        return putState(Replies.ok());
    }

    /**
     * Forgets (unpairs) the paired device at arg, through the hidden
     * BluetoothDevice.removeBond(). It worked from a normal app on the Nook
     * (Stage 0); if a firmware hides it, the reply is "not_supported" and the
     * plugin points to Android's Bluetooth settings. Android queues the removal;
     * callers poll device(arg) until "forgotten".
     */
    JSONObject forget(String arg) {
        if (adapter == null) {
            return putState(Replies.error("bt_unavailable"));
        }
        if (!isValidAddress(arg)) {
            return Replies.error("bad_argument");
        }
        BluetoothDevice device = adapter.getRemoteDevice(arg);
        if (device.getBondState() != BluetoothDevice.BOND_BONDED) {
            return putState(Replies.error("not_paired"));
        }
        // Recorded before the request, so a broadcast that arrives at once counts.
        synchronized (removals) {
            pairings.remove(arg);
            removals.put(arg, false);
        }
        boolean removed = false;
        try {
            Method removeBond = BluetoothDevice.class.getMethod("removeBond");
            removed = Boolean.TRUE.equals(removeBond.invoke(device));
        } catch (ReflectiveOperationException e) {
            Log.w(HelperProvider.TAG, "removeBond unavailable: " + e.getClass().getSimpleName());
            return putState(Replies.error("not_supported"));
        } finally {
            if (!removed) {
                // Not requested, so a later removal (e.g. in Android settings)
                // must not be taken for this one.
                synchronized (removals) {
                    removals.remove(arg);
                }
            }
        }
        return putState(removed ? Replies.ok() : Replies.error("request_rejected"));
    }

    /**
     * Opens stock Android's Bluetooth settings, never the Nook's (which cannot
     * pair remotes): the explicit component first, then the generic action, which
     * on this firmware resolves only to the stock screen (checked 2026-10-30).
     */
    JSONObject openSettings() {
        Intent intent = new Intent().setComponent(STOCK_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            context.startActivity(intent);
            return Replies.ok();
        } catch (ActivityNotFoundException | SecurityException e) {
            Log.w(HelperProvider.TAG, "stock Bluetooth settings unavailable: " + e.getClass().getSimpleName());
        }
        try {
            context.startActivity(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            return Replies.ok();
        } catch (ActivityNotFoundException | SecurityException e) {
            return Replies.error("settings_unavailable");
        }
    }

    private JSONObject putState(JSONObject reply) {
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (power != null) {
            Replies.put(reply, "screenOn", power.isInteractive());
        }
        Replies.put(reply, "available", adapter != null);
        if (adapter == null) {
            return reply;
        }
        int state = adapter.getState();
        Replies.put(reply, "bluetoothState", adapterState(state));
        Replies.put(reply, "enabled", state == BluetoothAdapter.STATE_ON);
        Replies.put(reply, "discovering", adapter.isDiscovering());
        Replies.put(reply, "hidReady", hid != null);
        return reply;
    }

    // Name is left out when unknown (common for BLE devices before a name lookup).
    private JSONObject describe(BluetoothDevice d) {
        JSONObject o = new JSONObject();
        Replies.put(o, "address", d.getAddress());
        String name = d.getName();
        if (name != null && !name.isEmpty()) {
            Replies.put(o, "name", name);
        }
        BluetoothClass cls = d.getBluetoothClass();
        Replies.put(o, "remote", cls != null && isLikelyRemote(cls.getMajorDeviceClass()));
        Replies.put(o, "bond", bondState(d.getBondState()));
        BluetoothProfile proxy = hid;
        if (proxy != null) {
            Replies.put(o, "connection", connectionState(proxy.getConnectionState(d)));
        }
        return o;
    }
}
