package mead.security;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import javax.security.auth.x500.X500Principal;

/**
 * The self-signed X.509 certificate Android's key store gives a generated
 * key pair: the spec's subject (also the issuer), serial number and
 * validity, signed with SHA-256 by the pair's own private key. DER, by hand.
 */
final class SelfSignedCertificate {
    // sha256WithRSAEncryption (1.2.840.113549.1.1.11), with NULL parameters.
    private static final byte[] SHA256_WITH_RSA = {
        0x30, 0x0d, 0x06, 0x09, 0x2a, (byte) 0x86, 0x48, (byte) 0x86, (byte) 0xf7, 0x0d, 0x01, 0x01, 0x0b, 0x05, 0x00,
    };
    // ecdsa-with-SHA256 (1.2.840.10045.4.3.2), without parameters.
    private static final byte[] SHA256_WITH_ECDSA = {
        0x30, 0x0a, 0x06, 0x08, 0x2a, (byte) 0x86, 0x48, (byte) 0xce, 0x3d, 0x04, 0x03, 0x02,
    };

    private SelfSignedCertificate() {}

    static X509Certificate create(KeyPair pair, String algorithm, X500Principal subject, BigInteger serial,
                                  Date notBefore, Date notAfter) throws GeneralSecurityException {
        boolean rsa = "RSA".equals(algorithm);
        byte[] signatureAlgorithm = rsa ? SHA256_WITH_RSA : SHA256_WITH_ECDSA;
        byte[] name = subject.getEncoded();
        byte[] tbs = sequence(
                tlv(0xa0, integer(BigInteger.valueOf(2))),
                integer(serial),
                signatureAlgorithm,
                name,
                sequence(time(notBefore), time(notAfter)),
                name,
                pair.getPublic().getEncoded());
        Signature signer = Signature.getInstance(rsa ? "SHA256withRSA" : "SHA256withECDSA");
        signer.initSign(pair.getPrivate());
        signer.update(tbs);
        byte[] signature = signer.sign();
        byte[] bits = new byte[signature.length + 1];
        System.arraycopy(signature, 0, bits, 1, signature.length);
        byte[] certificate = sequence(tbs, signatureAlgorithm, tlv(0x03, bits));
        return (X509Certificate) CertificateFactory.getInstance("X.509")
                .generateCertificate(new ByteArrayInputStream(certificate));
    }

    private static byte[] integer(BigInteger value) {
        return tlv(0x02, value.toByteArray());
    }

    /** UTCTime through 2049, GeneralizedTime after, as RFC 5280 has it. */
    private static byte[] time(Date date) {
        Calendar calendar = Calendar.getInstance(TimeZone.getTimeZone("UTC"));
        calendar.setTime(date);
        int year = calendar.get(Calendar.YEAR);
        boolean utc = year >= 1950 && year < 2050;
        SimpleDateFormat format = new SimpleDateFormat(utc ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return tlv(utc ? 0x17 : 0x18, format.format(date).getBytes(java.nio.charset.StandardCharsets.US_ASCII));
    }

    private static byte[] sequence(byte[]... parts) {
        ByteArrayOutputStream contents = new ByteArrayOutputStream();
        for (byte[] part : parts) contents.write(part, 0, part.length);
        return tlv(0x30, contents.toByteArray());
    }

    private static byte[] tlv(int tag, byte[] value) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(value.length + 6);
        out.write(tag);
        int length = value.length;
        if (length < 0x80) {
            out.write(length);
        } else {
            int bytes = length > 0xffffff ? 4 : length > 0xffff ? 3 : length > 0xff ? 2 : 1;
            out.write(0x80 | bytes);
            for (int shift = (bytes - 1) * 8; shift >= 0; shift -= 8) out.write((length >> shift) & 0xff);
        }
        out.write(value, 0, value.length);
        return out.toByteArray();
    }
}
