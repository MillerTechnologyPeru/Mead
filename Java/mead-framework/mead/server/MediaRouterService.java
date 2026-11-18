package mead.server;

import android.media.IMediaRouterClient;
import android.media.IMediaRouterService;
import android.media.MediaRouterClientState;

/**
 * Android's media router service for Mead: there are no routes besides the
 * device's own (its speakers and screen), which MediaRouter makes itself,
 * as on a phone with nothing to cast to. Clients register and ask for
 * routes; none are found, and none are selected. MediaRouter needs the
 * service to exist: Android 10's throws without it.
 */
final class MediaRouterService extends IMediaRouterService.Stub {
    @Override public void registerClientAsUser(IMediaRouterClient client, String packageName, int userId) {}
    @Override public void unregisterClient(IMediaRouterClient client) {}
    @Override public void registerClientGroupId(IMediaRouterClient client, String groupId) {}
    // No global routes.
    @Override public MediaRouterClientState getState(IMediaRouterClient client) { return null; }
    @Override public boolean isPlaybackActive(IMediaRouterClient client) { return false; }
    @Override public void setDiscoveryRequest(IMediaRouterClient client, int routeTypes, boolean activeScan) {}
    @Override public void setSelectedRoute(IMediaRouterClient client, String routeId, boolean explicit) {}
    @Override public void requestSetVolume(IMediaRouterClient client, String routeId, int volume) {}
    @Override public void requestUpdateVolume(IMediaRouterClient client, String routeId, int direction) {}
}
