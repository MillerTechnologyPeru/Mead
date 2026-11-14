package mead.security;

import android.security.KeyPairGeneratorSpec;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.StrongBoxUnavailableException;
import java.io.IOException;
import java.math.BigInteger;
import java.security.GeneralSecurityException;
import java.security.InvalidAlgorithmParameterException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyPairGeneratorSpi;
import java.security.NoSuchAlgorithmException;
import java.security.NoSuchProviderException;
import java.security.ProviderException;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.security.spec.AlgorithmParameterSpec;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.RSAKeyGenParameterSpec;
import java.util.Date;
import javax.security.auth.x500.X500Principal;

/**
 * KeyPairGenerator.getInstance("RSA" or "EC", "AndroidKeyStore"): a key pair
 * from Conscrypt, with a self-signed certificate (SelfSignedCertificate),
 * stored under the spec's alias. Takes a KeyGenParameterSpec, or the older
 * KeyPairGeneratorSpec.
 */
public abstract class MeadKeyPairGeneratorSpi extends KeyPairGeneratorSpi {
    private final String mAlgorithm;
    private String mAlias;
    private int mSize;
    private AlgorithmParameterSpec mParameters;
    private X500Principal mSubject;
    private BigInteger mSerial;
    private Date mNotBefore;
    private Date mNotAfter;
    private boolean mStrongBox;
    private byte[] mAttestationChallenge;
    private SecureRandom mRandom;

    MeadKeyPairGeneratorSpi(String algorithm) {
        mAlgorithm = algorithm;
    }

    /**
     * What Mead's software keys can't be, refused as a phone without the
     * hardware or a secure lock screen refuses it.
     */
    static void checkSupported(KeyGenParameterSpec spec) throws InvalidAlgorithmParameterException {
        if (spec.isUserAuthenticationRequired()) {
            throw new InvalidAlgorithmParameterException(new IllegalStateException(
                    "Secure lock screen must be enabled to create keys requiring user authentication"));
        }
    }

    @Override
    public void initialize(int keysize, SecureRandom random) {
        throw new IllegalArgumentException(KeyGenParameterSpec.class.getName() + " or "
                + KeyPairGeneratorSpec.class.getName() + " required to initialize this KeyPairGenerator");
    }

    @Override
    public void initialize(AlgorithmParameterSpec params, SecureRandom random)
            throws InvalidAlgorithmParameterException {
        if (params instanceof KeyGenParameterSpec) {
            KeyGenParameterSpec spec = (KeyGenParameterSpec) params;
            checkSupported(spec);
            mAlias = spec.getKeystoreAlias();
            mSize = spec.getKeySize();
            mParameters = spec.getAlgorithmParameterSpec();
            mSubject = spec.getCertificateSubject();
            mSerial = spec.getCertificateSerialNumber();
            mNotBefore = spec.getCertificateNotBefore();
            mNotAfter = spec.getCertificateNotAfter();
            mStrongBox = spec.isStrongBoxBacked();
            mAttestationChallenge = spec.getAttestationChallenge();
        } else if (params instanceof KeyPairGeneratorSpec) {
            KeyPairGeneratorSpec spec = (KeyPairGeneratorSpec) params;
            if (spec.getKeyType() != null && !spec.getKeyType().equalsIgnoreCase(mAlgorithm)) {
                throw new InvalidAlgorithmParameterException(
                        "Key type " + spec.getKeyType() + " doesn't match this " + mAlgorithm + " generator");
            }
            mAlias = spec.getKeystoreAlias();
            mSize = spec.getKeySize();
            mParameters = spec.getAlgorithmParameterSpec();
            mSubject = spec.getSubjectDN();
            mSerial = spec.getSerialNumber();
            mNotBefore = spec.getStartDate();
            mNotAfter = spec.getEndDate();
            mStrongBox = false;
            mAttestationChallenge = null;
        } else {
            throw new InvalidAlgorithmParameterException("Unsupported params class: "
                    + (params == null ? null : params.getClass().getName()) + ". Supported: "
                    + KeyGenParameterSpec.class.getName() + ", " + KeyPairGeneratorSpec.class.getName());
        }
        if (mAlias == null) throw new InvalidAlgorithmParameterException("KeyStore entry alias not provided");
        if (mSubject == null) mSubject = new X500Principal("CN=fake");
        if (mSerial == null) mSerial = BigInteger.ONE;
        if (mNotBefore == null) mNotBefore = new Date(0L);
        if (mNotAfter == null) mNotAfter = new Date(2461449600000L); // 2048-01-01
        mRandom = random != null ? random : new SecureRandom();
        checkParameters();
    }

    abstract void checkParameters() throws InvalidAlgorithmParameterException;

    abstract AlgorithmParameterSpec generatorParameters();

    int size() { return mSize; }

    AlgorithmParameterSpec parameters() { return mParameters; }

    void setSize(int size) { mSize = size; }

    @Override
    public KeyPair generateKeyPair() {
        if (mAlias == null) throw new IllegalStateException("Not initialized");
        if (mStrongBox) throw new StrongBoxUnavailableException();
        // Attestation is the secure hardware vouching for the key: Mead has none to vouch.
        if (mAttestationChallenge != null) {
            throw new ProviderException("Failed to generate attestation certificate chain: Mead has no secure hardware");
        }
        try {
            KeyPairGenerator generator = conscrypt(mAlgorithm);
            generator.initialize(generatorParameters(), mRandom);
            KeyPair pair = generator.generateKeyPair();
            X509Certificate certificate = SelfSignedCertificate.create(pair, mAlgorithm, mSubject, mSerial,
                    mNotBefore, mNotAfter);
            KeyStoreFiles.write(mAlias, new KeyStoreFiles.Entry(KeyStoreFiles.PRIVATE_KEY, System.currentTimeMillis(),
                    mAlgorithm, pair.getPrivate().getEncoded(), new byte[][] {certificate.getEncoded()}));
            return new KeyPair(certificate.getPublicKey(), pair.getPrivate());
        } catch (GeneralSecurityException | IOException e) {
            throw new ProviderException("Failed to generate key pair", e);
        }
    }

    private static KeyPairGenerator conscrypt(String algorithm) throws NoSuchAlgorithmException {
        try {
            return KeyPairGenerator.getInstance(algorithm, "AndroidOpenSSL");
        } catch (NoSuchProviderException e) {
            return KeyPairGenerator.getInstance(algorithm);
        }
    }

    public static final class RSA extends MeadKeyPairGeneratorSpi {
        public RSA() { super("RSA"); }

        @Override
        void checkParameters() throws InvalidAlgorithmParameterException {
            AlgorithmParameterSpec parameters = parameters();
            if (parameters != null && !(parameters instanceof RSAKeyGenParameterSpec)) {
                throw new InvalidAlgorithmParameterException("RSA may only use RSAKeyGenParameterSpec");
            }
            if (size() == -1) {
                setSize(parameters != null ? ((RSAKeyGenParameterSpec) parameters).getKeysize() : 2048);
            }
            if (size() < 512 || size() > 8192) {
                throw new InvalidAlgorithmParameterException("RSA key size must be >= 512 and <= 8192");
            }
        }

        @Override
        AlgorithmParameterSpec generatorParameters() {
            BigInteger exponent = parameters() != null
                    ? ((RSAKeyGenParameterSpec) parameters()).getPublicExponent() : RSAKeyGenParameterSpec.F4;
            return new RSAKeyGenParameterSpec(size(), exponent);
        }
    }

    public static final class EC extends MeadKeyPairGeneratorSpi {
        private String mCurve;

        public EC() { super("EC"); }

        @Override
        void checkParameters() throws InvalidAlgorithmParameterException {
            AlgorithmParameterSpec parameters = parameters();
            if (parameters instanceof ECGenParameterSpec) {
                String name = ((ECGenParameterSpec) parameters).getName().toLowerCase(java.util.Locale.US);
                int size;
                switch (name) {
                    case "p-224": case "secp224r1": size = 224; mCurve = "secp224r1"; break;
                    case "p-256": case "secp256r1": case "prime256v1": size = 256; mCurve = "prime256v1"; break;
                    case "p-384": case "secp384r1": size = 384; mCurve = "secp384r1"; break;
                    case "p-521": case "secp521r1": size = 521; mCurve = "secp521r1"; break;
                    default: throw new InvalidAlgorithmParameterException("Unsupported EC curve name: " + name);
                }
                if (size() != -1 && size() != size) {
                    throw new InvalidAlgorithmParameterException("EC key size must match the curve's: " + size);
                }
                setSize(size);
            } else if (parameters != null) {
                throw new InvalidAlgorithmParameterException("EC may only use ECGenParameterSpec");
            } else {
                if (size() == -1) setSize(256);
                switch (size()) {
                    case 224: mCurve = "secp224r1"; break;
                    case 256: mCurve = "prime256v1"; break;
                    case 384: mCurve = "secp384r1"; break;
                    case 521: mCurve = "secp521r1"; break;
                    default: throw new InvalidAlgorithmParameterException("Unsupported EC key size: " + size());
                }
            }
        }

        @Override
        AlgorithmParameterSpec generatorParameters() {
            return new ECGenParameterSpec(mCurve);
        }
    }
}
