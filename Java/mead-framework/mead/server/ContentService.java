package mead.server;

import android.content.ISyncStatusObserver;
import android.database.IContentObserver;
import android.net.Uri;
import android.os.RemoteException;
import java.util.ArrayList;
import java.util.List;
import mead.server.base.ContentServiceBase;

/**
 * Android's content service for Mead: content observers, told of changes
 * the app's providers report, as Android's does within one app. There's no
 * sync.
 */
final class ContentService extends ContentServiceBase {
    private static final class Observer {
        final Uri uri;
        final boolean descendants;
        final IContentObserver observer;
        final int userId;

        Observer(Uri uri, boolean descendants, IContentObserver observer, int userId) {
            this.uri = uri;
            this.descendants = descendants;
            this.observer = observer;
            this.userId = userId;
        }

        /** Whether a change at a URI is this observer's. */
        boolean observes(Uri changed) {
            if (!uri.getScheme().equals(changed.getScheme())
                    || !String.valueOf(uri.getAuthority()).equals(String.valueOf(changed.getAuthority()))) {
                return false;
            }
            List<String> observed = uri.getPathSegments(), segments = changed.getPathSegments();
            if (segments.size() < observed.size()) {
                // A change above the observed URI changes what's under it.
                return observed.subList(0, segments.size()).equals(segments);
            }
            if (!segments.subList(0, observed.size()).equals(observed)) return false;
            return segments.size() == observed.size() || descendants;
        }
    }

    private final List<Observer> mObservers = new ArrayList<>();

    @Override
    public void registerContentObserver(Uri uri, boolean notifyForDescendants, IContentObserver observer,
            int userHandle, int targetSdkVersion) {
        if (uri == null || observer == null) throw new IllegalArgumentException("no URI or observer");
        synchronized (mObservers) {
            mObservers.add(new Observer(uri, notifyForDescendants, observer, userHandle));
        }
    }

    @Override
    public void unregisterContentObserver(IContentObserver observer) {
        synchronized (mObservers) {
            for (int i = mObservers.size() - 1; i >= 0; i--) {
                if (mObservers.get(i).observer.asBinder() == observer.asBinder()) mObservers.remove(i);
            }
        }
    }

    @Override
    public void notifyChange(Uri uri, IContentObserver observer, boolean observerWantsSelfNotifications, int flags,
            int userHandle, int targetSdkVersion, String callingPackage) {
        List<Observer> told = new ArrayList<>();
        synchronized (mObservers) {
            for (Observer registered : mObservers) {
                if (registered.observes(uri)) told.add(registered);
            }
        }
        for (Observer registered : told) {
            boolean self = observer != null && registered.observer.asBinder() == observer.asBinder();
            if (self && !observerWantsSelfNotifications) continue;
            try {
                registered.observer.onChange(self, uri, registered.userId);
            } catch (RemoteException e) {
                // The observer is in this process.
            }
        }
    }

    @Override
    public void addStatusChangeListener(int mask, ISyncStatusObserver callback) {}

    @Override
    public void removeStatusChangeListener(ISyncStatusObserver callback) {}
}
