package mead.security;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.GeneralSecurityException;
import java.security.Key;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.KeyStoreSpi;
import java.security.PrivateKey;
import java.security.UnrecoverableEntryException;
import java.security.UnrecoverableKeyException;
import java.security.cert.Certificate;
import java.security.cert.CertificateEncodingException;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.Enumeration;
import javax.crypto.SecretKey;

/**
 * KeyStore.getInstance("AndroidKeyStore"): the entries in KeyStoreFiles. As
 * on Android, it's loaded with null (no stream or password), can't be
 * stored to a stream, and keys need no password.
 */
public final class MeadKeyStoreSpi extends KeyStoreSpi {
    @Override
    public Key engineGetKey(String alias, char[] password) throws UnrecoverableKeyException {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        if (entry == null) return null;
        try {
            return entry.key();
        } catch (GeneralSecurityException e) {
            UnrecoverableKeyException failure = new UnrecoverableKeyException("can't read key " + alias);
            failure.initCause(e);
            throw failure;
        }
    }

    @Override
    public Certificate[] engineGetCertificateChain(String alias) {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        if (entry == null || entry.kind != KeyStoreFiles.PRIVATE_KEY) return null;
        return chain(entry);
    }

    @Override
    public Certificate engineGetCertificate(String alias) {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        if (entry == null) return null;
        Certificate[] chain = chain(entry);
        return chain != null ? chain[0] : null;
    }

    private static Certificate[] chain(KeyStoreFiles.Entry entry) {
        try {
            return entry.chain();
        } catch (GeneralSecurityException e) {
            return null;
        }
    }

    @Override
    public Date engineGetCreationDate(String alias) {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        return entry != null ? new Date(entry.created) : null;
    }

    @Override
    public void engineSetKeyEntry(String alias, Key key, char[] password, Certificate[] chain) throws KeyStoreException {
        if (alias == null) throw new NullPointerException("alias == null");
        byte[] encoded = key.getEncoded();
        if (encoded == null) throw new KeyStoreException("key " + key.getAlgorithm() + " can't be encoded to import");
        long now = System.currentTimeMillis();
        if (key instanceof SecretKey) {
            write(alias, new KeyStoreFiles.Entry(KeyStoreFiles.SECRET_KEY, now, key.getAlgorithm(), encoded, new byte[0][]));
        } else if (key instanceof PrivateKey) {
            if (chain == null || chain.length == 0) throw new KeyStoreException("a private key needs its certificate chain");
            write(alias, new KeyStoreFiles.Entry(KeyStoreFiles.PRIVATE_KEY, now, key.getAlgorithm(), encoded, encode(chain)));
        } else {
            throw new KeyStoreException("unsupported key " + key.getClass().getName());
        }
    }

    @Override
    public void engineSetKeyEntry(String alias, byte[] key, Certificate[] chain) throws KeyStoreException {
        throw new KeyStoreException("Operation not supported because key encoding is unknown");
    }

    @Override
    public void engineSetCertificateEntry(String alias, Certificate certificate) throws KeyStoreException {
        if (alias == null) throw new NullPointerException("alias == null");
        if (certificate == null) throw new NullPointerException("cert == null");
        KeyStoreFiles.Entry existing = KeyStoreFiles.read(alias);
        if (existing != null && existing.kind != KeyStoreFiles.CERTIFICATE) {
            throw new KeyStoreException("Entry exists and is not a trusted certificate");
        }
        write(alias, new KeyStoreFiles.Entry(KeyStoreFiles.CERTIFICATE, System.currentTimeMillis(), "X.509",
                new byte[0], encode(new Certificate[] {certificate})));
    }

    @Override
    public void engineDeleteEntry(String alias) {
        KeyStoreFiles.delete(alias);
    }

    @Override
    public Enumeration<String> engineAliases() {
        return Collections.enumeration(KeyStoreFiles.aliases());
    }

    @Override
    public boolean engineContainsAlias(String alias) {
        return KeyStoreFiles.read(alias) != null;
    }

    @Override
    public int engineSize() {
        return KeyStoreFiles.aliases().size();
    }

    @Override
    public boolean engineIsKeyEntry(String alias) {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        return entry != null && entry.kind != KeyStoreFiles.CERTIFICATE;
    }

    @Override
    public boolean engineIsCertificateEntry(String alias) {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        return entry != null && entry.kind == KeyStoreFiles.CERTIFICATE;
    }

    @Override
    public String engineGetCertificateAlias(Certificate certificate) {
        if (certificate == null) return null;
        byte[] wanted;
        try {
            wanted = certificate.getEncoded();
        } catch (CertificateEncodingException e) {
            return null;
        }
        for (String alias : KeyStoreFiles.aliases()) {
            KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
            if (entry != null && entry.certificates.length > 0 && Arrays.equals(entry.certificates[0], wanted)) {
                return alias;
            }
        }
        return null;
    }

    @Override
    public void engineStore(OutputStream stream, char[] password) {
        throw new UnsupportedOperationException("Can not serialize AndroidKeyStore to OutputStream");
    }

    @Override
    public void engineLoad(InputStream stream, char[] password) {
        if (stream != null) throw new IllegalArgumentException("InputStream not supported");
        if (password != null) throw new IllegalArgumentException("password not supported");
    }

    /** Android 12's namespaces are other apps' and the system's: an app's own is all Mead has. */
    @Override
    public void engineLoad(KeyStore.LoadStoreParameter parameter) {}

    @Override
    public KeyStore.Entry engineGetEntry(String alias, KeyStore.ProtectionParameter protection)
            throws UnrecoverableEntryException {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        if (entry == null) return null;
        try {
            switch (entry.kind) {
                case KeyStoreFiles.SECRET_KEY:
                    return new KeyStore.SecretKeyEntry((SecretKey) entry.key());
                case KeyStoreFiles.PRIVATE_KEY:
                    return new KeyStore.PrivateKeyEntry((PrivateKey) entry.key(), entry.chain());
                default:
                    return new KeyStore.TrustedCertificateEntry(entry.chain()[0]);
            }
        } catch (GeneralSecurityException e) {
            UnrecoverableEntryException failure = new UnrecoverableEntryException("can't read entry " + alias);
            failure.initCause(e);
            throw failure;
        }
    }

    /** Protection parameters (KeyProtection) set what a phone's keymaster would enforce; Mead's keys are software keys. */
    @Override
    public void engineSetEntry(String alias, KeyStore.Entry entry, KeyStore.ProtectionParameter protection)
            throws KeyStoreException {
        if (entry instanceof KeyStore.PrivateKeyEntry) {
            KeyStore.PrivateKeyEntry privateEntry = (KeyStore.PrivateKeyEntry) entry;
            engineSetKeyEntry(alias, privateEntry.getPrivateKey(), null, privateEntry.getCertificateChain());
        } else if (entry instanceof KeyStore.SecretKeyEntry) {
            engineSetKeyEntry(alias, ((KeyStore.SecretKeyEntry) entry).getSecretKey(), null, null);
        } else if (entry instanceof KeyStore.TrustedCertificateEntry) {
            engineSetCertificateEntry(alias, ((KeyStore.TrustedCertificateEntry) entry).getTrustedCertificate());
        } else {
            throw new KeyStoreException("unsupported entry " + (entry == null ? null : entry.getClass().getName()));
        }
    }

    @Override
    public boolean engineEntryInstanceOf(String alias, Class<? extends KeyStore.Entry> type) {
        KeyStoreFiles.Entry entry = KeyStoreFiles.read(alias);
        if (entry == null) return false;
        switch (entry.kind) {
            case KeyStoreFiles.SECRET_KEY: return type == KeyStore.SecretKeyEntry.class;
            case KeyStoreFiles.PRIVATE_KEY: return type == KeyStore.PrivateKeyEntry.class;
            default: return type == KeyStore.TrustedCertificateEntry.class;
        }
    }

    private static void write(String alias, KeyStoreFiles.Entry entry) throws KeyStoreException {
        try {
            KeyStoreFiles.write(alias, entry);
        } catch (IOException e) {
            throw new KeyStoreException("can't store " + alias, e);
        }
    }

    private static byte[][] encode(Certificate[] chain) throws KeyStoreException {
        byte[][] encoded = new byte[chain.length][];
        try {
            for (int index = 0; index < chain.length; index++) encoded[index] = chain[index].getEncoded();
        } catch (CertificateEncodingException e) {
            throw new KeyStoreException("can't encode the certificate chain", e);
        }
        return encoded;
    }
}
