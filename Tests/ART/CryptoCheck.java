import java.io.*;
import java.math.BigInteger;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.ECGenParameterSpec;
import java.util.Objects;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import javax.net.ssl.*;

// Exercises Conscrypt (libjavacrypto, with BoringSSL inside it) from Java:
// the provider's digests, MACs, ciphers, signatures and randomness, then a
// TLS connection that checks the server's certificate against Android's CA
// store. Pass a URL to connect to; without one the TLS check is skipped.
public class CryptoCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    static String hex(byte[] bytes) {
        return String.format("%0" + (bytes.length * 2) + "x", new BigInteger(1, bytes));
    }

    public static void main(String[] args) throws Exception {
        check("first provider", Security.getProviders()[0].getName(), "AndroidOpenSSL");

        MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
        check("SHA-256 provider", sha256.getProvider().getName(), "AndroidOpenSSL");
        check("SHA-256", hex(sha256.digest("abc".getBytes(StandardCharsets.US_ASCII))),
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

        Mac hmac = Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec("key".getBytes(StandardCharsets.US_ASCII), "HmacSHA256"));
        check("HMAC-SHA256", hex(hmac.doFinal("The quick brown fox jumps over the lazy dog".getBytes(StandardCharsets.US_ASCII))),
              "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");

        KeyGenerator aes = KeyGenerator.getInstance("AES");
        aes.init(256);
        SecretKey key = aes.generateKey();
        byte[] iv = new byte[12];
        new SecureRandom().nextBytes(iv);
        Cipher gcm = Cipher.getInstance("AES/GCM/NoPadding");
        gcm.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, iv));
        byte[] sealed = gcm.doFinal("sealed with AES-GCM".getBytes(StandardCharsets.UTF_8));
        gcm.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, iv));
        check("AES-GCM round trip", new String(gcm.doFinal(sealed), StandardCharsets.UTF_8), "sealed with AES-GCM");
        check("AES-GCM provider", gcm.getProvider().getName(), "AndroidOpenSSL");

        KeyPairGenerator ec = KeyPairGenerator.getInstance("EC");
        ec.initialize(new ECGenParameterSpec("secp256r1"));
        KeyPair pair = ec.generateKeyPair();
        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(pair.getPrivate());
        signer.update("signed".getBytes(StandardCharsets.UTF_8));
        byte[] signature = signer.sign();
        signer.initVerify(pair.getPublic());
        signer.update("signed".getBytes(StandardCharsets.UTF_8));
        check("ECDSA P-256 verifies", signer.verify(signature), true);

        KeyPairGenerator rsa = KeyPairGenerator.getInstance("RSA");
        rsa.initialize(2048);
        KeyPair rsaPair = rsa.generateKeyPair();
        Cipher oaep = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding");
        oaep.init(Cipher.ENCRYPT_MODE, rsaPair.getPublic());
        byte[] wrapped = oaep.doFinal("wrapped".getBytes(StandardCharsets.UTF_8));
        oaep.init(Cipher.DECRYPT_MODE, rsaPair.getPrivate());
        check("RSA-OAEP round trip", new String(oaep.doFinal(wrapped), StandardCharsets.UTF_8), "wrapped");

        check("default SSLContext", SSLContext.getDefault().getProvider().getName(), "AndroidOpenSSL");

        if (args.length > 0) {
            HttpsURLConnection connection = (HttpsURLConnection) new URL(args[0]).openConnection();
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(15000);
            int status = connection.getResponseCode();
            check("HTTPS " + args[0], status / 100, 2);
            System.out.println("     cipher suite " + connection.getCipherSuite());
            connection.disconnect();

            // A certificate no CA vouches for must be refused.
            try {
                HttpsURLConnection bad = (HttpsURLConnection) new URL("https://self-signed.badssl.com/").openConnection();
                bad.setConnectTimeout(15000);
                bad.getResponseCode();
                check("self-signed certificate refused", false, true);
            } catch (SSLHandshakeException expected) {
                check("self-signed certificate refused", true, true);
            }
        }

        System.out.println(failures == 0 ? "all passed" : failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
