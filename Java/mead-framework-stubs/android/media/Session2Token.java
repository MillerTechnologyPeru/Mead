package android.media;

/**
 * A compile-time stand-in for Android 10's Session2Token, which the media
 * session service's interface names: the class is in updatable-media.jar,
 * not in the framework's classes.jar that Mead compiles against. It is
 * never dexed; ART loads the real one from the boot class path.
 */
public final class Session2Token {
}
