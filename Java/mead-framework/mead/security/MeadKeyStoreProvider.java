package mead.security;

import java.security.Provider;
import java.security.Security;

/**
 * Android's "AndroidKeyStore" JCA provider, as Mead has it. A phone's keys
 * live in its keystore daemon, backed by the TEE or StrongBox; Mead has
 * neither, so its keys are software keys, kept in the app's data directory
 * (KeyStoreFiles) and readable only by the user Mead runs as. Keys come back
 * as ordinary keys, which Conscrypt's ciphers, MACs and signatures use.
 *
 * What Mead can't do, it refuses as a phone without the hardware does: key
 * attestation, StrongBox, and keys that need the user's authentication
 * (Mead has no secure lock screen).
 */
public final class MeadKeyStoreProvider extends Provider {
    public static final String NAME = "AndroidKeyStore";

    public MeadKeyStoreProvider() {
        super(NAME, 1.0, "Android key store, in software (Mead)");
        put("KeyStore." + NAME, MeadKeyStoreSpi.class.getName());
        put("KeyGenerator.AES", MeadKeyGeneratorSpi.AES.class.getName());
        put("KeyGenerator.HmacSHA1", MeadKeyGeneratorSpi.HmacSHA1.class.getName());
        put("KeyGenerator.HmacSHA224", MeadKeyGeneratorSpi.HmacSHA224.class.getName());
        put("KeyGenerator.HmacSHA256", MeadKeyGeneratorSpi.HmacSHA256.class.getName());
        put("KeyGenerator.HmacSHA384", MeadKeyGeneratorSpi.HmacSHA384.class.getName());
        put("KeyGenerator.HmacSHA512", MeadKeyGeneratorSpi.HmacSHA512.class.getName());
        put("KeyPairGenerator.RSA", MeadKeyPairGeneratorSpi.RSA.class.getName());
        put("KeyPairGenerator.EC", MeadKeyPairGeneratorSpi.EC.class.getName());
    }

    /** Adds the provider, last, as Android does; once. */
    public static void install() {
        if (Security.getProvider(NAME) == null) Security.addProvider(new MeadKeyStoreProvider());
    }
}
