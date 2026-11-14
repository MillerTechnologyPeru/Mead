package mead.server;

import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.AudioSystem;
import android.media.PlayerBase;
import java.util.concurrent.atomic.AtomicInteger;
import mead.server.base.AudioServiceBase;

/**
 * Android's audio service for Mead: players are tracked (by ID only), every
 * stream is at its full volume and unmuted, and the audio mode is normal.
 * The volumes are the windowing system's to set, for the whole app.
 */
final class AudioService extends AudioServiceBase {
    private static final int MAX_VOLUME = 15;
    private final AtomicInteger mNextPlayer = new AtomicInteger(1);

    @Override public int trackPlayer(PlayerBase.PlayerIdCard card) { return mNextPlayer.getAndIncrement(); }
    @Override public void playerAttributes(int piid, AudioAttributes attributes) {}
    @Override public void playerEvent(int piid, int event) {}
    @Override public void releasePlayer(int piid) {}
    @Override public void playerHasOpPlayAudio(int piid, boolean hasOpPlayAudio) {}
    @Override public int getStreamVolume(int streamType) { return MAX_VOLUME; }
    @Override public int getStreamMaxVolume(int streamType) { return MAX_VOLUME; }
    @Override public boolean isStreamMute(int streamType) { return false; }
    @Override public int getMode() { return AudioSystem.MODE_NORMAL; }
    @Override public int getRingerModeExternal() { return AudioManager.RINGER_MODE_NORMAL; }
    @Override public boolean isSpeakerphoneOn() { return false; }

    /**
     * Audio focus: Mead runs one app, so its requests are granted, as
     * Android grants the only app asking; giving it up always succeeds.
     */
    @Override public int requestAudioFocus(android.media.AudioAttributes attributes, int durationHint,
            android.os.IBinder cb, android.media.IAudioFocusDispatcher dispatcher, String clientId,
            String callingPackageName, int flags, android.media.audiopolicy.IAudioPolicyCallback policyCallback,
            int sdk) {
        return android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
    }

    @Override public int abandonAudioFocus(android.media.IAudioFocusDispatcher dispatcher, String clientId,
            android.media.AudioAttributes attributes, String callingPackageName) {
        return android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
    }
}
