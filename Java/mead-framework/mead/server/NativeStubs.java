package mead.server;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.List;

/**
 * Framework classes whose natives Mead answers with nothing: what they'd
 * report goes to system services Mead doesn't have (statsd). Mead registers
 * a native doing nothing and returning zero for each of their native
 * methods, listed by signatures().
 */
public final class NativeStubs {
    private NativeStubs() {}

    /** The classes. */
    public static final String[] CLASSES = {"android.util.StatsLog", "android.util.StatsLogInternal"};

    /** A class's native methods, as "name" then its JNI descriptor, alternately. */
    public static String[] signatures(String className) throws ClassNotFoundException {
        List<String> signatures = new ArrayList<>();
        for (Method method : Class.forName(className).getDeclaredMethods()) {
            if (!Modifier.isNative(method.getModifiers())) continue;
            StringBuilder descriptor = new StringBuilder("(");
            for (Class<?> parameter : method.getParameterTypes()) descriptor.append(descriptor(parameter));
            descriptor.append(')').append(descriptor(method.getReturnType()));
            signatures.add(method.getName());
            signatures.add(descriptor.toString());
        }
        return signatures.toArray(new String[0]);
    }

    private static String descriptor(Class<?> type) {
        if (type == void.class) return "V";
        if (type == boolean.class) return "Z";
        if (type == byte.class) return "B";
        if (type == char.class) return "C";
        if (type == short.class) return "S";
        if (type == int.class) return "I";
        if (type == long.class) return "J";
        if (type == float.class) return "F";
        if (type == double.class) return "D";
        if (type.isArray()) return type.getName().replace('.', '/');
        return "L" + type.getName().replace('.', '/') + ";";
    }
}
