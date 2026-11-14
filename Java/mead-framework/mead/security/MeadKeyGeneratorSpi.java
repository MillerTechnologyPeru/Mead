package mead.security;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.StrongBoxUnavailableException;
import java.io.IOException;
import java.security.InvalidAlgorithmParameterException;
import java.security.ProviderException;
import java.security.SecureRandom;
import java.security.spec.AlgorithmParameterSpec;
import javax.crypto.KeyGeneratorSpi;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

/**
 * KeyGenerator.getInstance(algorithm, "AndroidKeyStore"): a random key of
 * the KeyGenParameterSpec's size, stored under its alias (replacing what
 * was there, as Android does).
 */
public abstract class MeadKeyGeneratorSpi extends KeyGeneratorSpi {
    private final String mAlgorithm;
    private final int mDefaultSize;
    private KeyGenParameterSpec mSpec;
    private int mSize;
    private SecureRandom mRandom;

    MeadKeyGeneratorSpi(String algorithm, int defaultSize) {
        mAlgorithm = algorithm;
        mDefaultSize = defaultSize;
    }

    @Override
    protected void engineInit(SecureRandom random) {
        throw new UnsupportedOperationException(
                "Cannot initialize without a " + KeyGenParameterSpec.class.getName() + " parameter");
    }

    @Override
    protected void engineInit(int size, SecureRandom random) {
        throw new UnsupportedOperationException(
                "Cannot initialize without a " + KeyGenParameterSpec.class.getName() + " parameter");
    }

    @Override
    protected void engineInit(AlgorithmParameterSpec params, SecureRandom random)
            throws InvalidAlgorithmParameterException {
        if (!(params instanceof KeyGenParameterSpec)) {
            throw new InvalidAlgorithmParameterException(
                    "Cannot initialize without a " + KeyGenParameterSpec.class.getName() + " parameter");
        }
        KeyGenParameterSpec spec = (KeyGenParameterSpec) params;
        if (spec.getKeystoreAlias() == null) throw new InvalidAlgorithmParameterException("KeyStore entry alias not provided");
        int size = spec.getKeySize() == -1 ? mDefaultSize : spec.getKeySize();
        checkSize(size);
        MeadKeyPairGeneratorSpi.checkSupported(spec);
        mSpec = spec;
        mSize = size;
        mRandom = random != null ? random : new SecureRandom();
    }

    void checkSize(int size) throws InvalidAlgorithmParameterException {
        if (size % 8 != 0 || size < 64 || size > 512) {
            throw new InvalidAlgorithmParameterException("Unsupported key size: " + size);
        }
    }

    @Override
    protected SecretKey engineGenerateKey() {
        if (mSpec == null) throw new IllegalStateException("Not initialized");
        if (mSpec.isStrongBoxBacked()) throw new StrongBoxUnavailableException();
        byte[] key = new byte[mSize / 8];
        mRandom.nextBytes(key);
        try {
            KeyStoreFiles.write(mSpec.getKeystoreAlias(), new KeyStoreFiles.Entry(KeyStoreFiles.SECRET_KEY,
                    System.currentTimeMillis(), mAlgorithm, key, new byte[0][]));
        } catch (IOException e) {
            throw new ProviderException("Failed to store the key", e);
        }
        return new SecretKeySpec(key, mAlgorithm);
    }

    public static final class AES extends MeadKeyGeneratorSpi {
        public AES() { super("AES", 128); }

        @Override
        void checkSize(int size) throws InvalidAlgorithmParameterException {
            if (size != 128 && size != 192 && size != 256) {
                throw new InvalidAlgorithmParameterException("Unsupported key size: " + size
                        + ". Supported: 128, 192, 256.");
            }
        }
    }

    public static final class HmacSHA1 extends MeadKeyGeneratorSpi {
        public HmacSHA1() { super("HmacSHA1", 160); }
    }

    public static final class HmacSHA224 extends MeadKeyGeneratorSpi {
        public HmacSHA224() { super("HmacSHA224", 224); }
    }

    public static final class HmacSHA256 extends MeadKeyGeneratorSpi {
        public HmacSHA256() { super("HmacSHA256", 256); }
    }

    public static final class HmacSHA384 extends MeadKeyGeneratorSpi {
        public HmacSHA384() { super("HmacSHA384", 384); }
    }

    public static final class HmacSHA512 extends MeadKeyGeneratorSpi {
        public HmacSHA512() { super("HmacSHA512", 512); }
    }
}
