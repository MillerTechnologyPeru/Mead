package mead.server;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.IClipboard;
import android.content.IOnPrimaryClipChangedListener;
import android.os.RemoteCallbackList;
import android.os.RemoteException;

/**
 * Android's clipboard for Mead: the app's own, kept in its process. What it
 * copies it can paste, and its listeners hear of each change; the host's
 * clipboard isn't shared with it yet.
 */
final class ClipboardService extends IClipboard.Stub {
    private final RemoteCallbackList<IOnPrimaryClipChangedListener> mListeners = new RemoteCallbackList<>();
    private ClipData mClip;

    @Override
    public void setPrimaryClip(ClipData clip, String callingPackage, int userId) {
        if (clip == null || clip.getItemCount() <= 0) {
            throw new IllegalArgumentException("No items");
        }
        changed(clip);
    }

    @Override
    public void clearPrimaryClip(String callingPackage, int userId) {
        changed(null);
    }

    @Override
    public synchronized ClipData getPrimaryClip(String callingPackage, int userId) {
        return mClip;
    }

    @Override
    public synchronized ClipDescription getPrimaryClipDescription(String callingPackage, int userId) {
        return mClip != null ? mClip.getDescription() : null;
    }

    @Override
    public synchronized boolean hasPrimaryClip(String callingPackage, int userId) {
        return mClip != null;
    }

    @Override
    public void addPrimaryClipChangedListener(IOnPrimaryClipChangedListener listener, String callingPackage, int userId) {
        mListeners.register(listener);
    }

    @Override
    public void removePrimaryClipChangedListener(IOnPrimaryClipChangedListener listener, String callingPackage, int userId) {
        mListeners.unregister(listener);
    }

    @Override
    public synchronized boolean hasClipboardText(String callingPackage, int userId) {
        if (mClip == null || mClip.getItemCount() == 0) return false;
        CharSequence text = mClip.getItemAt(0).getText();
        return text != null && text.length() > 0;
    }

    private void changed(ClipData clip) {
        synchronized (this) {
            mClip = clip;
        }
        synchronized (mListeners) {
            int count = mListeners.beginBroadcast();
            try {
                for (int i = 0; i < count; i++) {
                    try {
                        mListeners.getBroadcastItem(i).dispatchPrimaryClipChanged();
                    } catch (RemoteException e) {
                        // The listener is gone: RemoteCallbackList drops it.
                    }
                }
            } finally {
                mListeners.finishBroadcast();
            }
        }
    }
}
