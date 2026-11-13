import java.io.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.text.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;
import java.util.zip.*;
import javax.xml.parsers.*;
import org.xml.sax.*;
import org.xml.sax.helpers.DefaultHandler;

// Exercises each native part of Android 10's core library once: libjavacore's
// NativeBN, ICU regex and formatting, Expat, libcore.io, and libopenjdk's zip,
// files and threads.
public class CoreCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    public static void main(String[] args) throws Exception {
        BigInteger big = BigInteger.ONE.shiftLeft(130).subtract(BigInteger.valueOf(12345));
        check("BigInteger multiply", big.multiply(big).mod(BigInteger.valueOf(1000003)).toString(), new BigInteger(big.toString()).pow(2).mod(BigInteger.valueOf(1000003)).toString());
        check("BigInteger negative bytes", new BigInteger(new byte[] {(byte) 0xff, 0x00}).toString(), "-256");
        check("BigInteger longValue", BigInteger.valueOf(-1234567890123L).longValue(), -1234567890123L);
        check("BigInteger bitLength", BigInteger.valueOf(-1024).bitLength(), 10);
        check("BigInteger probable prime", BigInteger.valueOf(1000003).isProbablePrime(50), true);
        check("BigInteger modPow", BigInteger.valueOf(4).modPow(BigInteger.valueOf(13), BigInteger.valueOf(497)).toString(), "445");

        Matcher m = Pattern.compile("(\\w+)@(\\w+)\\.com").matcher("mail alice@example.com now");
        check("regex", m.find() ? m.group(1) + "/" + m.group(2) : null, "alice/example");

        check("NumberFormat de-DE", NumberFormat.getInstance(Locale.GERMANY).format(1234567.891), "1.234.567,891");
        check("String.format", String.format(Locale.US, "%08.3f|%x", Math.PI, 255), "0003.142|ff");
        check("upper-case Turkish", "title".toUpperCase(new Locale("tr")), "TİTLE");
        SimpleDateFormat date = new SimpleDateFormat("yyyy-MM-dd HH:mm zzz", Locale.US);
        date.setTimeZone(TimeZone.getTimeZone("America/New_York"));
        check("time zone", date.format(new Date(0)), "1969-12-31 19:00 EST");

        ByteArrayOutputStream zipped = new ByteArrayOutputStream();
        try (GZIPOutputStream out = new GZIPOutputStream(zipped)) {
            out.write("compress me, compress me, compress me".getBytes(StandardCharsets.UTF_8));
        }
        try (GZIPInputStream in = new GZIPInputStream(new ByteArrayInputStream(zipped.toByteArray()))) {
            check("gzip round trip", new String(readAll(in), StandardCharsets.UTF_8), "compress me, compress me, compress me");
        }
        CRC32 crc = new CRC32();
        crc.update("123456789".getBytes(StandardCharsets.US_ASCII));
        check("CRC32", Long.toHexString(crc.getValue()), "cbf43926");

        final StringBuilder seen = new StringBuilder();
        SAXParserFactory.newInstance().newSAXParser().parse(
            new ByteArrayInputStream("<a><b name='x'/><b name='y'/></a>".getBytes(StandardCharsets.UTF_8)),
            new DefaultHandler() {
                @Override public void startElement(String uri, String local, String qName, Attributes attributes) {
                    if (qName.equals("b")) seen.append(attributes.getValue("name"));
                }
            });
        check("SAX (Expat)", seen.toString(), "xy");

        File dir = new File(System.getProperty("java.io.tmpdir"), "corecheck-" + System.nanoTime());
        check("mkdirs", dir.mkdirs(), true);
        Path file = dir.toPath().resolve("file.txt");
        Files.write(file, Arrays.asList("one", "two"), StandardCharsets.UTF_8);
        check("nio Files", Files.readAllLines(file, StandardCharsets.UTF_8), Arrays.asList("one", "two"));
        check("canonical path", new File(dir, "../" + dir.getName() + "/file.txt").getCanonicalPath(), file.toFile().getCanonicalPath());
        try (RandomAccessFile raf = new RandomAccessFile(file.toFile(), "r")) {
            check("RandomAccessFile", raf.length(), 8L);
        }
        Files.delete(file);
        check("delete", dir.delete(), true);

        ExecutorService pool = Executors.newFixedThreadPool(4);
        List<Future<Integer>> results = new ArrayList<>();
        for (int i = 0; i < 8; i++) {
            final int n = i;
            results.add(pool.submit(new Callable<Integer>() {
                @Override public Integer call() { return n * n; }
            }));
        }
        int sum = 0;
        for (Future<Integer> f : results) sum += f.get();
        pool.shutdown();
        check("threads", sum, 140);

        check("user.home set", System.getProperty("user.home") != null, true);
        check("getenv", System.getenv("PATH") != null, true);
        check("Charset ISO-8859-1", new String(new byte[] {(byte) 0xe9}, "ISO-8859-1"), "é");

        System.out.println(failures == 0 ? "all passed" : failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }

    static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
        return out.toByteArray();
    }
}
