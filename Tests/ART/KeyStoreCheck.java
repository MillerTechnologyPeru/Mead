import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.nio.charset.StandardCharsets;
import java.security.InvalidAlgorithmParameterException;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.ProviderException;
import java.security.Security;
import java.security.Signature;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.util.Arrays;
import java.util.Collections;
import java.util.Objects;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.security.auth.x500.X500Principal;

// Mead's AndroidKeyStore provider (mead.security): keys made through it are
// kept, come back from a fresh KeyStore, and work with Conscrypt's ciphers,
// MACs and signatures; what Mead can't back (attestation, user
// authentication) is refused. Run it on Mead with mead-framework.jar.
public class KeyStoreCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    static KeyStore store() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        return store;
    }

    static String thrown(Runnable action) {
        try {
            action.run();
            return "nothing";
        } catch (RuntimeException e) {
            return e.getClass().getSimpleName();
        }
    }

    public static void main(String[] args) throws Exception {
        check("provider", Security.getProvider("AndroidKeyStore") != null, true);
        KeyStore store = store();
        for (String alias : Collections.list(store.aliases())) {
            if (alias.startsWith("mead-check-")) store.deleteEntry(alias);
        }

        // AES-GCM, as Jetpack's MasterKey and Tink make and use it.
        KeyGenerator aes = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        aes.init(new KeyGenParameterSpec.Builder("mead-check-aes",
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build());
        SecretKey generated = aes.generateKey();
        check("AES key size", generated.getEncoded().length * 8, 256);
        Cipher seal = Cipher.getInstance("AES/GCM/NoPadding");
        seal.init(Cipher.ENCRYPT_MODE, generated);
        byte[] iv = seal.getIV();
        check("AES-GCM random IV", iv != null && iv.length == 12, true);
        byte[] sealed = seal.doFinal("kept in the key store".getBytes(StandardCharsets.UTF_8));
        SecretKey reloaded = (SecretKey) store().getKey("mead-check-aes", null);
        Cipher open = Cipher.getInstance("AES/GCM/NoPadding");
        open.init(Cipher.DECRYPT_MODE, reloaded, new GCMParameterSpec(128, iv));
        check("AES-GCM with the stored key", new String(open.doFinal(sealed), StandardCharsets.UTF_8),
                "kept in the key store");
        check("AES entry", store().entryInstanceOf("mead-check-aes", KeyStore.SecretKeyEntry.class), true);

        // HMAC.
        KeyGenerator hmac = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore");
        hmac.init(new KeyGenParameterSpec.Builder("mead-check-hmac", KeyProperties.PURPOSE_SIGN).build());
        SecretKey macKey = hmac.generateKey();
        Mac first = Mac.getInstance("HmacSHA256");
        first.init(macKey);
        Mac second = Mac.getInstance("HmacSHA256");
        second.init(store().getKey("mead-check-hmac", null));
        byte[] message = "authenticated".getBytes(StandardCharsets.UTF_8);
        check("HMAC with the stored key", Arrays.equals(first.doFinal(message), second.doFinal(message)), true);

        // EC, signing, with its self-signed certificate.
        KeyPairGenerator ec = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
        ec.initialize(new KeyGenParameterSpec.Builder("mead-check-ec",
                KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setCertificateSubject(new X500Principal("CN=Mead check"))
                .build());
        ec.generateKeyPair();
        KeyStore.Entry entry = store().getEntry("mead-check-ec", null);
        check("EC entry", entry instanceof KeyStore.PrivateKeyEntry, true);
        KeyStore.PrivateKeyEntry ecEntry = (KeyStore.PrivateKeyEntry) entry;
        X509Certificate ecCertificate = (X509Certificate) ecEntry.getCertificate();
        check("EC certificate subject", ecCertificate.getSubjectX500Principal().getName(), "CN=Mead check");
        ecCertificate.verify(ecCertificate.getPublicKey());
        check("EC certificate is self-signed", true, true);
        Signature sign = Signature.getInstance("SHA256withECDSA");
        sign.initSign(ecEntry.getPrivateKey());
        sign.update(message);
        byte[] signature = sign.sign();
        Signature verify = Signature.getInstance("SHA256withECDSA");
        verify.initVerify(store().getCertificate("mead-check-ec"));
        verify.update(message);
        check("EC signature verifies", verify.verify(signature), true);

        // RSA, with the default exponent and validity.
        KeyPairGenerator rsa = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
        rsa.initialize(new KeyGenParameterSpec.Builder("mead-check-rsa", KeyProperties.PURPOSE_SIGN)
                .setKeySize(2048).setDigests(KeyProperties.DIGEST_SHA256)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1).build());
        rsa.generateKeyPair();
        X509Certificate rsaCertificate = (X509Certificate) store().getCertificate("mead-check-rsa");
        rsaCertificate.verify(rsaCertificate.getPublicKey());
        check("RSA certificate algorithm", rsaCertificate.getSigAlgName(), "SHA256withRSA");
        check("RSA chain length", store().getCertificateChain("mead-check-rsa").length, 1);
        check("RSA certificate alias", store().getCertificateAlias(rsaCertificate), "mead-check-rsa");

        // The store as a whole.
        KeyStore all = store();
        check("aliases", Collections.list(all.aliases()).containsAll(
                Arrays.asList("mead-check-aes", "mead-check-hmac", "mead-check-ec", "mead-check-rsa")), true);
        check("is key entry", all.isKeyEntry("mead-check-rsa"), true);
        try {
            all.setCertificateEntry("mead-check-rsa", ecCertificate);
            check("certificate over a key", "allowed", "KeyStoreException");
        } catch (KeyStoreException e) {
            check("certificate over a key", "KeyStoreException", "KeyStoreException");
        }
        all.setCertificateEntry("mead-check-cert", ecCertificate);
        check("trusted certificate", store().isCertificateEntry("mead-check-cert"), true);

        // What Mead refuses.
        check("init without a spec", thrown(new Runnable() {
            public void run() {
                try {
                    KeyGenerator.getInstance("AES", "AndroidKeyStore").init(256);
                } catch (java.security.GeneralSecurityException e) {
                    throw new RuntimeException(e);
                }
            }
        }), "UnsupportedOperationException");
        try {
            KeyGenerator.getInstance("AES", "AndroidKeyStore").init(
                    new KeyGenParameterSpec.Builder("mead-check-auth", KeyProperties.PURPOSE_ENCRYPT)
                            .setUserAuthenticationRequired(true).build());
            check("user authentication", "allowed", "InvalidAlgorithmParameterException");
        } catch (InvalidAlgorithmParameterException e) {
            check("user authentication", "InvalidAlgorithmParameterException", "InvalidAlgorithmParameterException");
        }
        final KeyPairGenerator attested = KeyPairGenerator.getInstance("EC", "AndroidKeyStore");
        attested.initialize(new KeyGenParameterSpec.Builder("mead-check-attested", KeyProperties.PURPOSE_SIGN)
                .setAttestationChallenge(new byte[] {1, 2, 3}).build());
        check("attestation", thrown(new Runnable() {
            public void run() { attested.generateKeyPair(); }
        }), "ProviderException");
        check("no attested key kept", store().containsAlias("mead-check-attested"), false);

        for (String alias : Collections.list(store().aliases())) {
            if (alias.startsWith("mead-check-")) store().deleteEntry(alias);
        }
        check("deleted", store().containsAlias("mead-check-aes"), false);

        System.out.println(failures == 0 ? "KeyStoreCheck: all passed" : "KeyStoreCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
