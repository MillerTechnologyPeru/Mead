// Mead on ART, phase 2's check: ART in Mead's process loads a bionic JNI
// library (libfixture_art.so) through Mead's loader, finds its natives, and
// the library calls back into Java.
//
//   javac --release 8 NativeCheck.java && java -jar <art>/lib/java/dx.jar --dex --output=native-check.dex NativeCheck.class
//   mead --dex native-check.dex NativeCheck /path/to/libfixture_art.so
public class NativeCheck {
    static native int add(int left, int right);

    static native String greet(String name);

    static String decorate(String name) {
        return "Hello, " + name;
    }

    public static void main(String[] args) {
        System.load(args[0]);
        int sum = add(2, 3);
        String greeting = greet("Mead");
        System.out.println("add(2, 3) = " + sum);
        System.out.println("greet(\"Mead\") = " + greeting);
        boolean passed = sum == 5 && "Hello, Mead, from bionic (11 characters)".equals(greeting);
        System.out.println(passed ? "passed" : "FAILED");
        if (!passed) {
            System.exit(1);
        }
    }
}
