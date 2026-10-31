package dev.nookwifi.helper;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class BluetoothRulesTest {
    @Test
    public void validAddresses() {
        assertTrue(BluetoothRules.isValidAddress("E4:17:D8:00:00:06"));
        assertTrue(BluetoothRules.isValidAddress("00:00:00:00:00:00"));
    }

    @Test
    public void invalidAddresses() {
        assertFalse(BluetoothRules.isValidAddress(null));
        assertFalse(BluetoothRules.isValidAddress(""));
        assertFalse(BluetoothRules.isValidAddress("e4:17:d8:00:00:06")); // Android wants upper case
        assertFalse(BluetoothRules.isValidAddress("E4:17:D8:00:00"));
        assertFalse(BluetoothRules.isValidAddress("E4:17:D8:00:00:06:07"));
        assertFalse(BluetoothRules.isValidAddress("E4-17-D8-00-00-06"));
        assertFalse(BluetoothRules.isValidAddress("E4:17:D8:00:00:06\n"));
        assertFalse(BluetoothRules.isValidAddress("G4:17:D8:00:00:06"));
    }

    @Test
    public void peripheralsAreLikelyRemotes() {
        assertTrue(BluetoothRules.isLikelyRemote(0x0500));
        assertFalse(BluetoothRules.isLikelyRemote(0x1f00)); // uncategorized, e.g. many BLE devices
        assertFalse(BluetoothRules.isLikelyRemote(0x0400)); // audio/video
        assertFalse(BluetoothRules.isLikelyRemote(0x0200)); // phone
    }

    @Test
    public void stateNames() {
        assertEquals("off", BluetoothRules.adapterState(10));
        assertEquals("turning_on", BluetoothRules.adapterState(11));
        assertEquals("on", BluetoothRules.adapterState(12));
        assertEquals("turning_off", BluetoothRules.adapterState(13));
        assertEquals("unknown", BluetoothRules.adapterState(-1));
        assertEquals("none", BluetoothRules.bondState(10));
        assertEquals("bonding", BluetoothRules.bondState(11));
        assertEquals("bonded", BluetoothRules.bondState(12));
        assertEquals("unknown", BluetoothRules.bondState(0));
        assertEquals("disconnected", BluetoothRules.connectionState(0));
        assertEquals("connecting", BluetoothRules.connectionState(1));
        assertEquals("connected", BluetoothRules.connectionState(2));
        assertEquals("disconnecting", BluetoothRules.connectionState(3));
        assertEquals("unknown", BluetoothRules.connectionState(7));
    }
}
