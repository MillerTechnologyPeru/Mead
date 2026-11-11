package mead.server;

import com.android.internal.view.InputBindResult;
import mead.server.base.InputMethodManagerBase;

/**
 * Android's input method manager for Mead: no input methods yet. Windows
 * that gain focus are told there's nothing to bind.
 */
final class InputMethodManagerService extends InputMethodManagerBase {
    @Override
    public InputBindResult startInputOrWindowGainedFocus(int startInputReason,
            com.android.internal.view.IInputMethodClient client, android.os.IBinder windowToken,
            int startInputFlags, int softInputMode, int windowFlags, android.view.inputmethod.EditorInfo attribute,
            com.android.internal.view.IInputContext inputContext, int missingMethodFlags,
            int unverifiedTargetSdkVersion) {
        return InputBindResult.NULL;
    }
}
