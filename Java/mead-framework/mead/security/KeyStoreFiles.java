package mead.security;

import android.system.ErrnoException;
import android.system.Os;
import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.Key;
import java.security.KeyFactory;
import java.security.NoSuchAlgorithmException;
import java.security.NoSuchProviderException;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.List;
import javax.crypto.spec.SecretKeySpec;
import mead.server.MeadApp;

/**
 * The key store's entries, one file each in <app data>/keystore (mode 0700,
 * files 0600), named by the alias's UTF-8 bytes in hex. A file is written
 * whole and renamed into place. Without an app (a dex run), the store is
 * ~/.mead/keystore.
 */
final class KeyStoreFiles {
    static final int SECRET_KEY = 1;
    static final int PRIVATE_KEY = 2;
    static final int CERTIFICATE = 3;

    private static final int VERSION = 1;
    private static final Object sLock = new Object();

    private KeyStoreFiles() {}

    /** An entry: a secret key, a private key with its chain, or a trusted certificate. */
    static final class Entry {
        final int kind;
        final long created;
        final String algorithm;
        final byte[] key;
        final byte[][] certificates;

        Entry(int kind, long created, String algorithm, byte[] key, byte[][] certificates) {
            this.kind = kind;
            this.created = created;
            this.algorithm = algorithm;
            this.key = key;
            this.certificates = certificates;
        }

        /** The key it holds; null for a certificate. */
        Key key() throws GeneralSecurityException {
            if (kind == SECRET_KEY) return new SecretKeySpec(key, algorithm);
            if (kind == PRIVATE_KEY) return keyFactory(algorithm).generatePrivate(new PKCS8EncodedKeySpec(key));
            return null;
        }

        /** Its certificates: a private key's chain, or the trusted certificate; none for a secret key. */
        Certificate[] chain() throws GeneralSecurityException {
            if (certificates.length == 0) return null;
            CertificateFactory factory = CertificateFactory.getInstance("X.509");
            Certificate[] chain = new Certificate[certificates.length];
            for (int index = 0; index < chain.length; index++) {
                chain[index] = factory.generateCertificate(new ByteArrayInputStream(certificates[index]));
            }
            return chain;
        }
    }

    static KeyFactory keyFactory(String algorithm) throws NoSuchAlgorithmException {
        try {
            return KeyFactory.getInstance(algorithm, "AndroidOpenSSL");
        } catch (NoSuchProviderException e) {
            return KeyFactory.getInstance(algorithm);
        }
    }

    static File directory() {
        String data = MeadApp.currentDataDir();
        if (data == null) {
            String home = System.getenv("HOME");
            data = (home != null ? home : "/tmp") + "/.mead";
        }
        File directory = new File(data, "keystore");
        if (!directory.isDirectory()) {
            directory.mkdirs();
            chmod(directory, 0700);
        }
        return directory;
    }

    private static File file(String alias) {
        byte[] bytes = alias.getBytes(StandardCharsets.UTF_8);
        StringBuilder name = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) name.append(String.format("%02x", b & 0xff));
        return new File(directory(), name.toString());
    }

    private static String alias(String name) {
        if (name.length() % 2 != 0) return null;
        byte[] bytes = new byte[name.length() / 2];
        try {
            for (int index = 0; index < bytes.length; index++) {
                bytes[index] = (byte) Integer.parseInt(name.substring(index * 2, index * 2 + 2), 16);
            }
        } catch (NumberFormatException e) {
            return null;
        }
        return new String(bytes, StandardCharsets.UTF_8);
    }

    static Entry read(String alias) {
        synchronized (sLock) {
            File file = file(alias);
            if (!file.isFile()) return null;
            try (DataInputStream in = new DataInputStream(new FileInputStream(file))) {
                if (in.readInt() != VERSION) return null;
                int kind = in.readInt();
                long created = in.readLong();
                String algorithm = in.readUTF();
                byte[] key = new byte[in.readInt()];
                in.readFully(key);
                byte[][] certificates = new byte[in.readInt()][];
                for (int index = 0; index < certificates.length; index++) {
                    certificates[index] = new byte[in.readInt()];
                    in.readFully(certificates[index]);
                }
                return new Entry(kind, created, algorithm, key, certificates);
            } catch (IOException e) {
                return null;
            }
        }
    }

    static void write(String alias, Entry entry) throws IOException {
        synchronized (sLock) {
            File file = file(alias);
            File temporary = new File(file.getParentFile(), file.getName() + ".new");
            try (FileOutputStream stream = new FileOutputStream(temporary)) {
                chmod(temporary, 0600);
                DataOutputStream out = new DataOutputStream(stream);
                out.writeInt(VERSION);
                out.writeInt(entry.kind);
                out.writeLong(entry.created);
                out.writeUTF(entry.algorithm);
                out.writeInt(entry.key.length);
                out.write(entry.key);
                out.writeInt(entry.certificates.length);
                for (byte[] certificate : entry.certificates) {
                    out.writeInt(certificate.length);
                    out.write(certificate);
                }
                out.flush();
                stream.getFD().sync();
            }
            if (!temporary.renameTo(file)) {
                temporary.delete();
                throw new IOException("can't write key store entry " + file);
            }
        }
    }

    static void delete(String alias) {
        synchronized (sLock) {
            file(alias).delete();
        }
    }

    static List<String> aliases() {
        List<String> aliases = new ArrayList<>();
        synchronized (sLock) {
            String[] names = directory().list();
            if (names == null) return aliases;
            for (String name : names) {
                if (name.endsWith(".new")) continue;
                String alias = alias(name);
                if (alias != null) aliases.add(alias);
            }
        }
        return aliases;
    }

    private static void chmod(File file, int mode) {
        try {
            Os.chmod(file.getPath(), mode);
        } catch (ErrnoException e) {
            // The directory's own mode still keeps others out.
        }
    }
}
