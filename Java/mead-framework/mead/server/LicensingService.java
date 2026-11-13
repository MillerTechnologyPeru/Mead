package mead.server;

import android.content.ComponentName;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Log;

/**
 * Google Play's licensing service (com.android.vending.licensing
 * .ILicensingService), in-process, for apps that check their license with
 * Play's License Verification Library or pairip's license client. Each
 * request is asked of Google for the signed-in account, by Mead's natives
 * (ARTLicensing.swift), and Google's answer goes to the app's listener as
 * Play would hand it over: the first protocol's signed text and signature,
 * the second's license token as LICENSE_DATA. Mead doesn't verify or alter
 * either; the app checks Google's signature itself.
 *
 * Written against the AIDL by hand, as the interfaces aren't in the
 * framework: the app's proxy transacts with it in this process.
 */
final class LicensingService extends Binder {
    private static final String TAG = "MeadLicensing";
    static final String DESCRIPTOR = "com.android.vending.licensing.ILicensingService";
    static final ComponentName COMPONENT = new ComponentName("com.android.vending",
            "com.android.vending.licensing.LicensingService");
    private static final String V1_LISTENER = "com.android.vending.licensing.ILicenseResultListener";
    private static final String V2_LISTENER = "com.android.vending.licensing.ILicenseV2ResultListener";
    private static final int CHECK_LICENSE = IBinder.FIRST_CALL_TRANSACTION;
    private static final int CHECK_LICENSE_V2 = IBinder.FIRST_CALL_TRANSACTION + 1;
    private static final int VERIFY_LICENSE = IBinder.FIRST_CALL_TRANSACTION;
    /** Play's local error for a package other than the caller's. */
    private static final int ERROR_NON_MATCHING_UID = 0x103;

    /** Asks Google: {code, signed data, signature}. */
    static native String[] nativeCheckLicense(String packageName, int versionCode, long nonce);

    /** Asks Google: {code, license token}. */
    static native String[] nativeCheckLicenseV2(String packageName, int versionCode);

    LicensingService() {
        attachInterface(null, DESCRIPTOR);
    }

    /** Whether an intent's service is this one: Play's, by action. */
    static boolean handles(android.content.Intent intent) {
        if (!DESCRIPTOR.equals(intent.getAction())) return false;
        String target = intent.getPackage() != null ? intent.getPackage()
                : intent.getComponent() != null ? intent.getComponent().getPackageName() : null;
        return target == null || COMPONENT.getPackageName().equals(target);
    }

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
        switch (code) {
            case CHECK_LICENSE: {
                data.enforceInterface(DESCRIPTOR);
                final long nonce = data.readLong();
                final String packageName = data.readString();
                final IBinder listener = data.readStrongBinder();
                answerLater(new Runnable() {
                    @Override
                    public void run() {
                        String[] answer = mine(packageName)
                                ? nativeCheckLicense(packageName, versionCode(), nonce)
                                : new String[] {String.valueOf(ERROR_NON_MATCHING_UID), null, null};
                        Parcel call = Parcel.obtain();
                        try {
                            call.writeInterfaceToken(V1_LISTENER);
                            call.writeInt(Integer.parseInt(answer[0]));
                            call.writeString(answer[1]);
                            call.writeString(answer[2]);
                            listener.transact(VERIFY_LICENSE, call, null, IBinder.FLAG_ONEWAY);
                        } catch (RemoteException e) {
                            Log.w(TAG, "The license listener is gone", e);
                        } finally {
                            call.recycle();
                        }
                    }
                });
                return true;
            }
            case CHECK_LICENSE_V2: {
                data.enforceInterface(DESCRIPTOR);
                final String packageName = data.readString();
                final IBinder listener = data.readStrongBinder();
                // extraParams, unused, as Play's.
                if (data.readInt() != 0) Bundle.CREATOR.createFromParcel(data);
                answerLater(new Runnable() {
                    @Override
                    public void run() {
                        String[] answer = mine(packageName)
                                ? nativeCheckLicenseV2(packageName, versionCode())
                                : new String[] {String.valueOf(ERROR_NON_MATCHING_UID), null};
                        Bundle result = new Bundle();
                        if (answer[1] != null) result.putString("LICENSE_DATA", answer[1]);
                        Parcel call = Parcel.obtain();
                        try {
                            call.writeInterfaceToken(V2_LISTENER);
                            call.writeInt(Integer.parseInt(answer[0]));
                            call.writeInt(1);
                            result.writeToParcel(call, 0);
                            listener.transact(VERIFY_LICENSE, call, null, IBinder.FLAG_ONEWAY);
                        } catch (RemoteException e) {
                            Log.w(TAG, "The license listener is gone", e);
                        } finally {
                            call.recycle();
                        }
                    }
                });
                return true;
            }
            default:
                return super.onTransact(code, data, reply, flags);
        }
    }

    /** As Play answers from its own thread, once Google has. */
    private static void answerLater(Runnable answer) {
        new Thread(answer, "MeadLicensing").start();
    }

    /** Only the app's own license may be asked about, as Play checks the caller's UID. */
    private static boolean mine(String packageName) {
        MeadApp app = MeadApp.sCurrent;
        return app != null && app.packageName.equals(packageName);
    }

    private static int versionCode() {
        MeadApp app = MeadApp.sCurrent;
        return app != null ? (int) app.versionCode : 0;
    }
}
