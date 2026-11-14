package mead.server;

import android.content.Intent;
import android.os.PowerManager;
import mead.host.HostPower;

/**
 * Watches the host for what Android's power and thermal services announce:
 * a look every two seconds, from one daemon thread started the first time
 * something listens. The thermal service's listeners hear status changes;
 * power saving and the screen turning on or off go out as Android's
 * broadcasts (ACTION_POWER_SAVE_MODE_CHANGED, ACTION_SCREEN_ON/OFF).
 */
final class HostWatcher {
    private static final long INTERVAL_MS = 2000;
    private static boolean sStarted;

    private HostWatcher() {}

    static synchronized void start() {
        if (sStarted) return;
        sStarted = true;
        Thread thread = new Thread(new Runnable() {
            @Override
            public void run() {
                watch();
            }
        }, "MeadHostWatcher");
        thread.setDaemon(true);
        thread.start();
    }

    private static void watch() {
        boolean powerSave = HostPower.powerSave();
        boolean screenOn = HostPower.screenOn();
        while (true) {
            try {
                Thread.sleep(INTERVAL_MS);
            } catch (InterruptedException e) {
                return;
            }
            ThermalService thermal = MeadServices.sThermal;
            if (thermal != null) thermal.update();
            boolean nowSaving = HostPower.powerSave();
            if (nowSaving != powerSave) {
                powerSave = nowSaving;
                MeadServices.sActivityManager.broadcast(new Intent(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
                        .addFlags(Intent.FLAG_RECEIVER_REGISTERED_ONLY));
            }
            boolean nowOn = HostPower.screenOn();
            if (nowOn != screenOn) {
                screenOn = nowOn;
                MeadServices.sActivityManager.broadcast(new Intent(nowOn ? Intent.ACTION_SCREEN_ON
                        : Intent.ACTION_SCREEN_OFF).addFlags(Intent.FLAG_RECEIVER_REGISTERED_ONLY));
            }
        }
    }
}
