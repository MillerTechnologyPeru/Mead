package mead.server;

import android.os.CoolingDevice;
import android.os.IThermalEventListener;
import android.os.IThermalStatusListener;
import android.os.RemoteException;
import android.os.Temperature;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import mead.host.HostThermal;
import mead.server.base.ThermalServiceBase;

/**
 * Android's thermal service for Mead: the host's thermal zones and cooling
 * devices (mead.host.HostThermal), with their throttling status. Status
 * listeners hear the status when they register and whenever it changes;
 * event listeners hear a zone's temperature when its throttling status
 * changes, as Android's service tells them. HostWatcher looks every few
 * seconds.
 */
final class ThermalService extends ThermalServiceBase {
    private final List<IThermalStatusListener> mStatusListeners = new ArrayList<>();
    /** Event listeners, with the temperature type they asked for (null for all). */
    private final Map<IThermalEventListener, Integer> mEventListeners = new HashMap<>();
    private int mStatus = -1;
    private final Map<String, Integer> mZoneStatus = new HashMap<>();

    @Override public boolean registerThermalEventListener(IThermalEventListener listener) {
        synchronized (this) {
            mEventListeners.put(listener, null);
        }
        HostWatcher.start();
        return true;
    }

    @Override public boolean registerThermalEventListenerWithType(IThermalEventListener listener, int type) {
        synchronized (this) {
            mEventListeners.put(listener, type);
        }
        HostWatcher.start();
        return true;
    }

    @Override public boolean unregisterThermalEventListener(IThermalEventListener listener) {
        synchronized (this) {
            return mEventListeners.remove(listener) != null || containsBinder(listener);
        }
    }

    private boolean containsBinder(IThermalEventListener listener) {
        for (IThermalEventListener known : mEventListeners.keySet()) {
            if (known.asBinder() == listener.asBinder()) {
                mEventListeners.remove(known);
                return true;
            }
        }
        return false;
    }

    @Override public List<Temperature> getCurrentTemperatures() {
        return HostThermal.temperatures(null);
    }

    @Override public List<Temperature> getCurrentTemperaturesWithType(int type) {
        return HostThermal.temperatures(type);
    }

    @Override public boolean registerThermalStatusListener(IThermalStatusListener listener) {
        synchronized (this) {
            mStatusListeners.add(listener);
        }
        try {
            listener.onStatusChange(getCurrentThermalStatus());
        } catch (RemoteException e) {
            // The listener is in this process.
        }
        HostWatcher.start();
        return true;
    }

    @Override public boolean unregisterThermalStatusListener(IThermalStatusListener listener) {
        synchronized (this) {
            for (int i = mStatusListeners.size() - 1; i >= 0; i--) {
                if (mStatusListeners.get(i).asBinder() == listener.asBinder()) {
                    mStatusListeners.remove(i);
                    return true;
                }
            }
        }
        return false;
    }

    @Override public int getCurrentThermalStatus() {
        return HostThermal.status();
    }

    @Override public List<CoolingDevice> getCurrentCoolingDevices() {
        return HostThermal.coolingDevices(null);
    }

    @Override public List<CoolingDevice> getCurrentCoolingDevicesWithType(int type) {
        return HostThermal.coolingDevices(type);
    }

    /** HostWatcher's look: tells the listeners what changed since the last. */
    void update() {
        List<IThermalStatusListener> statusListeners;
        Map<IThermalEventListener, Integer> eventListeners;
        synchronized (this) {
            if (mStatusListeners.isEmpty() && mEventListeners.isEmpty()) return;
            statusListeners = new ArrayList<>(mStatusListeners);
            eventListeners = new HashMap<>(mEventListeners);
        }
        List<HostThermal.Zone> zones = HostThermal.zones();
        int status = Temperature.THROTTLING_NONE;
        List<Temperature> changed = new ArrayList<>();
        synchronized (this) {
            for (HostThermal.Zone zone : zones) {
                int zoneStatus = zone.status();
                status = Math.max(status, zoneStatus);
                Integer before = mZoneStatus.put(zone.name, zoneStatus);
                if (before != null && before != zoneStatus) changed.add(zone.temperature());
            }
            if (status == mStatus) statusListeners.clear();
            mStatus = status;
        }
        for (IThermalStatusListener listener : statusListeners) {
            try {
                listener.onStatusChange(status);
            } catch (RemoteException e) {
                // In this process.
            }
        }
        for (Temperature temperature : changed) {
            for (Map.Entry<IThermalEventListener, Integer> entry : eventListeners.entrySet()) {
                if (entry.getValue() != null && entry.getValue() != temperature.getType()) continue;
                try {
                    entry.getKey().notifyThrottling(temperature);
                } catch (RemoteException e) {
                    // In this process.
                }
            }
        }
    }
}
