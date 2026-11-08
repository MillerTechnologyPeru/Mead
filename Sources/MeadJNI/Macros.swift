/// Makes a `JavaObject` subclass a Java class: registers what `@JavaMethod`
/// and `@JavaField` mark, with signatures derived from the Swift types.
@attached(member, names: named(javaClassName), named(javaSuperclassType), named(javaMembers))
public macro JavaClass(_ name: String) = #externalMacro(module: "MeadMacros", type: "JavaClassMacro")

/// Marks a method or initializer as callable from JNI. `name` defaults to the
/// Swift name, or `<init>` for an initializer; `signature` is only needed
/// when a reference type's Swift spelling does not say its Java class.
@attached(peer)
public macro JavaMethod(_ name: String? = nil, signature: String? = nil) = #externalMacro(module: "MeadMacros", type: "JavaMemberMacro")

/// Marks a property as a Java field.
@attached(peer)
public macro JavaField(_ name: String? = nil, signature: String? = nil) = #externalMacro(module: "MeadMacros", type: "JavaMemberMacro")
