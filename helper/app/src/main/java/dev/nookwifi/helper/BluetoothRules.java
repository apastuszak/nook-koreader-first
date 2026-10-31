package dev.nookwifi.helper;

import java.util.regex.Pattern;

/**
 * Pure rules for Bluetooth replies: addresses, state names and which devices
 * look like page-turner remotes. No Android dependencies, so they are
 * unit-tested on the JVM (src/test). The int values are Android's constants
 * (BluetoothAdapter, BluetoothDevice, BluetoothProfile, BluetoothClass), which
 * are fixed API values.
 */
final class BluetoothRules {
    private BluetoothRules() {
    }

    // BluetoothAdapter.checkBluetoothAddress accepts only upper case; so does this.
    private static final Pattern ADDRESS = Pattern.compile("([0-9A-F]{2}:){5}[0-9A-F]{2}");

    // BluetoothClass.Device.Major.PERIPHERAL: keyboards, pointing devices,
    // gamepads and remote controls. The 8BitDo Micro reports 0x540 (keyboard).
    static final int MAJOR_PERIPHERAL = 0x0500;

    static boolean isValidAddress(String address) {
        return address != null && ADDRESS.matcher(address).matches();
    }

    /**
     * True for devices in the peripheral class. Some BLE page turners report no
     * class at all (0x1f00, uncategorized), so callers must not hide the others.
     */
    static boolean isLikelyRemote(int majorClass) {
        return majorClass == MAJOR_PERIPHERAL;
    }

    /** BluetoothAdapter.STATE_*: off, turning_on, on, turning_off, or unknown. */
    static String adapterState(int state) {
        switch (state) {
            case 10: return "off";
            case 11: return "turning_on";
            case 12: return "on";
            case 13: return "turning_off";
            default: return "unknown";
        }
    }

    /** BluetoothDevice.BOND_*: none, bonding, bonded, or unknown. */
    static String bondState(int state) {
        switch (state) {
            case 10: return "none";
            case 11: return "bonding";
            case 12: return "bonded";
            default: return "unknown";
        }
    }

    /** BluetoothProfile.STATE_*: disconnected, connecting, connected, disconnecting, or unknown. */
    static String connectionState(int state) {
        switch (state) {
            case 0: return "disconnected";
            case 1: return "connecting";
            case 2: return "connected";
            case 3: return "disconnecting";
            default: return "unknown";
        }
    }
}
