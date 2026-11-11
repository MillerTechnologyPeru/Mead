package mead.server;

import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.pm.ParceledListSlice;
import android.os.Bundle;
import com.android.internal.appwidget.IAppWidgetHost;
import java.util.Collections;
import mead.server.base.AppWidgetServiceBase;

/**
 * Android's app widget service for Mead: there's no home screen to hold
 * widgets, so an app has none placed, and none can be.
 */
final class AppWidgetService extends AppWidgetServiceBase {
    @Override public int[] getAppWidgetIds(ComponentName provider) { return new int[0]; }
    @Override public int[] getAppWidgetIdsForHost(String callingPackage, int hostId) { return new int[0]; }
    @Override public ParceledListSlice startListening(IAppWidgetHost host, String callingPackage, int hostId,
            int[] appWidgetIds) {
        return new ParceledListSlice<>(Collections.emptyList());
    }
    @Override public void stopListening(String callingPackage, int hostId) {}
    @Override public Bundle getAppWidgetOptions(String callingPackage, int appWidgetId) { return new Bundle(); }
    @Override public ParceledListSlice getInstalledProvidersForProfile(int categoryFilter, int profileId,
            String packageName) {
        return new ParceledListSlice<>(Collections.emptyList());
    }
    @Override public AppWidgetProviderInfo getAppWidgetInfo(String callingPackage, int appWidgetId) { return null; }
    @Override public boolean hasBindAppWidgetPermission(String packageName, int userId) { return false; }
    @Override public boolean isRequestPinAppWidgetSupported() { return false; }
}
