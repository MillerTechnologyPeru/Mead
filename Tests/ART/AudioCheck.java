import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Looper;
import java.util.Objects;

// Android 10's AudioTrack on ART, over Mead's SDL audio: a streaming track
// plays a second of a 440 Hz tone, its blocking writes keeping pace with the
// device, its playback head following; pausing holds the head; a static
// track and a float one play through. Run on Mead, with a playback device.
public class AudioCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    static short[] tone(int rate, int frames, int channels) {
        short[] samples = new short[frames * channels];
        for (int i = 0; i < frames; i++) {
            short value = (short) (Math.sin(2 * Math.PI * 440 * i / rate) * 8000);
            for (int c = 0; c < channels; c++) samples[i * channels + c] = value;
        }
        return samples;
    }

    static AudioTrack track(int rate, int encoding, int bufferBytes, int mode) {
        return new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_GAME)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setSampleRate(rate)
                        .setEncoding(encoding)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build())
                .setBufferSizeInBytes(bufferBytes)
                .setTransferMode(mode)
                .build();
    }

    public static void main(String[] args) throws Exception {
        Looper.prepare();
        int rate = 48000;
        int deviceRate = AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC);
        System.out.println("     the device's rate: " + deviceRate);
        check("device rate", deviceRate > 0, true);
        int minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
        check("minimum buffer", minimum > 0, true);

        // Streaming, with blocking writes into a buffer of about 80 ms.
        AudioTrack stream = track(rate, AudioFormat.ENCODING_PCM_16BIT, minimum * 4, AudioTrack.MODE_STREAM);
        check("stream initialized", stream.getState(), AudioTrack.STATE_INITIALIZED);
        stream.play();
        check("playing", stream.getPlayState(), AudioTrack.PLAYSTATE_PLAYING);
        short[] second = tone(rate, rate, 2);
        long start = System.nanoTime();
        int written = stream.write(second, 0, second.length);
        long elapsed = (System.nanoTime() - start) / 1_000_000;
        check("wrote a second", written, second.length);
        System.out.println("     writing a second took " + elapsed + " ms");
        check("writes keep pace with the device", elapsed >= 700 && elapsed <= 1500, true);
        Thread.sleep(300);
        int position = stream.getPlaybackHeadPosition();
        System.out.println("     playback head: " + position + " frames");
        check("a second played", position >= rate * 9 / 10 && position <= rate, true);

        stream.write(second, 0, second.length / 4, AudioTrack.WRITE_NON_BLOCKING);
        stream.pause();
        int paused = stream.getPlaybackHeadPosition();
        Thread.sleep(300);
        check("pause holds the head", Math.abs(stream.getPlaybackHeadPosition() - paused) < rate / 100, true);
        stream.stop();
        check("stopped", stream.getPlayState(), AudioTrack.PLAYSTATE_STOPPED);
        stream.release();

        // Static: a quarter second, written then played.
        short[] quarter = tone(rate, rate / 4, 2);
        AudioTrack fixed = track(rate, AudioFormat.ENCODING_PCM_16BIT, quarter.length * 2, AudioTrack.MODE_STATIC);
        check("static written", fixed.write(quarter, 0, quarter.length), quarter.length);
        fixed.play();
        Thread.sleep(500);
        check("static played through", fixed.getPlaybackHeadPosition(), rate / 4);
        fixed.release();

        // Float samples.
        AudioTrack floats = track(rate, AudioFormat.ENCODING_PCM_FLOAT, rate / 5 * 8, AudioTrack.MODE_STREAM);
        float[] samples = new float[rate / 10 * 2];
        for (int i = 0; i < samples.length; i++) samples[i] = (float) Math.sin(i * 0.05) * 0.25f;
        floats.play();
        check("float written", floats.write(samples, 0, samples.length, AudioTrack.WRITE_BLOCKING), samples.length);
        floats.release();

        System.out.println(failures == 0 ? "AudioCheck passed" : "AudioCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
