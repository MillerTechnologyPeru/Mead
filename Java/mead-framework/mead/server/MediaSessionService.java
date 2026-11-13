package mead.server;

import android.view.KeyEvent;
import mead.server.base.SessionManagerBase;

/**
 * Android's media session service for Mead. Android's window hands it the
 * volume keys an app doesn't consume; the host owns the volume, so they are
 * dropped here (Mead's audio service reports every stream at its maximum).
 * Without the service a volume key ends the app.
 */
final class MediaSessionService extends SessionManagerBase {
    @Override public void dispatchVolumeKeyEvent(String packageName, String opPackageName,
            boolean asSystemService, KeyEvent keyEvent, int stream, boolean musicOnly) {
    }
}
