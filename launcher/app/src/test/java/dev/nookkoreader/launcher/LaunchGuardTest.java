package dev.nookkoreader.launcher;

import org.junit.Test;
import static org.junit.Assert.*;

public class LaunchGuardTest {
    @Test public void ordinaryHomeLaunches() {
        assertEquals(LaunchGuard.Decision.LAUNCH, LaunchGuard.enter("", 9, 9, 100).decision);
        assertEquals(LaunchGuard.Decision.LAUNCH, LaunchGuard.enter("100,500", 9, 9, 11000).decision);
    }

    @Test public void anyThreeHomeEntriesWithinTenSecondsOpenRecovery() {
        // Fast or slow: the Nook's button cannot produce a fast triple anyway.
        assertEquals(LaunchGuard.Decision.LOOP, LaunchGuard.enter("100,700", 9, 9, 1600).decision);
        assertEquals(LaunchGuard.Decision.LOOP, LaunchGuard.enter("100,2400", 9, 9, 4700).decision);
    }

    @Test public void crashReturnsStopBeforeThirdLaunch() {
        LaunchGuard.Result first = LaunchGuard.enter("", 9, 9, 1000);
        LaunchGuard.Result second = LaunchGuard.enter(first.history, 9, 9, 4000);
        LaunchGuard.Result third = LaunchGuard.enter(second.history, 9, 9, 7000);
        assertEquals(LaunchGuard.Decision.LAUNCH, second.decision);
        assertEquals(LaunchGuard.Decision.LOOP, third.decision);
    }

    @Test public void oldAttemptsExpireButBoundaryIsIncluded() {
        assertEquals(LaunchGuard.Decision.LOOP, LaunchGuard.enter("100,3000", 9, 9, 10100).decision);
        assertEquals(LaunchGuard.Decision.LAUNCH, LaunchGuard.enter("100,3000", 9, 9, 10101).decision);
    }

    @Test public void rebootDiscardsHistory() {
        assertEquals(LaunchGuard.Decision.LAUNCH, LaunchGuard.enter("1000,2000", 8, 9, 100).decision);
    }

    @Test public void corruptOrUnknownClockFailsClosed() {
        assertEquals(LaunchGuard.Decision.LOOP, LaunchGuard.enter("oops", 9, 9, 100).decision);
        assertEquals(LaunchGuard.Decision.LOOP, LaunchGuard.enter("200", 9, 9, 100).decision);
        assertEquals(LaunchGuard.Decision.LOOP, LaunchGuard.enter("", -1, -1, 100).decision);
    }

    @Test public void historyIsBounded() {
        assertEquals("200,300,400", LaunchGuard.enter("0,100,200,300", 9, 9, 400).history);
    }
}
