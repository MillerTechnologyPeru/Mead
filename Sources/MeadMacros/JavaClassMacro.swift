import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct JavaMacroError: DiagnosticMessage, Error {
    let message: String
    var severity: DiagnosticSeverity { .error }
    var diagnosticID: MessageID { MessageID(domain: "MeadMacros", id: "JavaClass") }
}

/// `@JavaMethod` and `@JavaField` only mark things for `@JavaClass` to find.
public struct JavaMemberMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

private struct MarkerArguments {
    var name: String?
    var signature: String?

    init(_ attribute: AttributeSyntax) {
        guard let list = attribute.arguments?.as(LabeledExprListSyntax.self) else { return }
        for argument in list {
            let text = argument.expression.trimmedDescription
            if argument.label?.text == "signature" {
                signature = text
            } else if argument.label == nil {
                name = text
            }
        }
    }
}

private func marker(_ name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
    for element in attributes {
        if let attribute = element.as(AttributeSyntax.self),
           attribute.attributeName.trimmedDescription == name {
            return attribute
        }
    }
    return nil
}

private func hasModifier(_ modifiers: DeclModifierListSyntax, _ names: String...) -> Bool {
    modifiers.contains { names.contains($0.name.text) }
}

private func strippingTicks(_ name: String) -> String {
    name.filter { $0 != "`" }
}

private func descriptor(of type: TypeSyntax) -> String {
    "(\(type.trimmedDescription)).javaDescriptor"
}

/// The expression for a signature made of these parameter and return types.
private func signatureExpression(parameters: [TypeSyntax], result: TypeSyntax?) -> String {
    var parts = ["\"(\""]
    parts += parameters.map(descriptor)
    parts.append("\")\"")
    parts.append(result.map(descriptor) ?? "\"V\"")
    return parts.joined(separator: " + ")
}

private func isVoid(_ clause: ReturnClauseSyntax?) -> Bool {
    guard let text = clause?.type.trimmedDescription else { return true }
    return text == "Void" || text == "()"
}

private func callArguments(_ parameters: FunctionParameterListSyntax) -> String {
    parameters.enumerated().map { index, parameter in
        let unpacked = "(\(parameter.type.trimmedDescription)).fromJava(arguments![\(index)], in: thread)"
        let label = parameter.firstName.text
        return label == "_" ? unpacked : "\(label): \(unpacked)"
    }.joined(separator: ", ")
}

public struct JavaClassMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else {
            throw JavaMacroError(message: "@JavaClass goes on a class deriving from JavaObject")
        }
        guard let javaName = node.arguments?.as(LabeledExprListSyntax.self)?.first?.expression.trimmedDescription else {
            throw JavaMacroError(message: "@JavaClass needs the class's Java name")
        }
        guard let parent = classDeclaration.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription else {
            throw JavaMacroError(message: "@JavaClass goes on a class deriving from JavaObject")
        }

        let type = classDeclaration.name.text
        var members: [String] = []
        for item in classDeclaration.memberBlock.members {
            if let function = item.decl.as(FunctionDeclSyntax.self),
               let attribute = marker("JavaMethod", in: function.attributes) {
                members.append(method(function, attribute: attribute, type: type))
            } else if let initializer = item.decl.as(InitializerDeclSyntax.self),
                      let attribute = marker("JavaMethod", in: initializer.attributes) {
                members.append(constructor(initializer, attribute: attribute, type: type))
            } else if let variable = item.decl.as(VariableDeclSyntax.self),
                      let attribute = marker("JavaField", in: variable.attributes) {
                members.append(try field(variable, attribute: attribute, type: type))
            }
        }

        let list = members.isEmpty ? "[]" : "[\n\(members.joined(separator: ",\n"))\n]"
        return [
            "public override class var javaClassName: String { \(raw: javaName) }",
            "public override class var javaSuperclassType: JavaObject.Type? { \(raw: parent).self }",
            "public override class func javaMembers() -> [JavaMember] { \(raw: list) }",
        ]
    }

    private static func method(_ function: FunctionDeclSyntax, attribute: AttributeSyntax, type: String) -> String {
        let arguments = MarkerArguments(attribute)
        let parameters = function.signature.parameterClause.parameters
        let returnClause = function.signature.returnClause
        let void = isVoid(returnClause)
        let isStatic = hasModifier(function.modifiers, "static", "class")
        let name = arguments.name ?? "\"\(strippingTicks(function.name.text))\""
        let signature = arguments.signature
            ?? signatureExpression(parameters: parameters.map(\.type), result: void ? nil : returnClause?.type)
        let receiver = isStatic ? type : "(receiver as! \(type))"
        let attempt = function.signature.effectSpecifiers?.throwsClause != nil ? "try " : ""
        let call = "\(attempt)\(receiver).\(function.name.text)(\(callArguments(parameters)))"
        let body = void ? "\(call)\nreturn jvalue()" : "return \(attempt)(\(String(call.dropFirst(attempt.count)))).toJava(in: thread)"
        return """
        .method(name: \(name), signature: \(signature), isStatic: \(isStatic)) { thread, receiver, arguments in
        \(body)
        }
        """
    }

    private static func constructor(_ initializer: InitializerDeclSyntax, attribute: AttributeSyntax, type: String) -> String {
        let arguments = MarkerArguments(attribute)
        let parameters = initializer.signature.parameterClause.parameters
        let signature = arguments.signature ?? signatureExpression(parameters: parameters.map(\.type), result: nil)
        let attempt = initializer.signature.effectSpecifiers?.throwsClause != nil ? "try " : ""
        return """
        .constructor(signature: \(signature)) { thread, arguments in
        return \(attempt)\(type)(\(callArguments(parameters)))
        }
        """
    }

    private static func field(_ variable: VariableDeclSyntax, attribute: AttributeSyntax, type: String) throws -> String {
        guard let binding = variable.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
              let fieldType = binding.typeAnnotation?.type else {
            throw JavaMacroError(message: "@JavaField needs a stored property with a type annotation")
        }
        let arguments = MarkerArguments(attribute)
        let isStatic = hasModifier(variable.modifiers, "static", "class")
        let name = arguments.name ?? "\"\(strippingTicks(identifier.identifier.text))\""
        let signature = arguments.signature ?? descriptor(of: fieldType)
        let property = identifier.identifier.text
        let access = isStatic ? "\(type).\(property)" : "(receiver as! \(type)).\(property)"
        return """
        .field(name: \(name), signature: \(signature), isStatic: \(isStatic), get: { thread, receiver in
        (\(access)).toJava(in: thread)
        }, set: { thread, receiver, value in
        \(access) = (\(fieldType.trimmedDescription)).fromJava(value, in: thread)
        })
        """
    }
}

@main
struct MeadMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [JavaClassMacro.self, JavaMemberMacro.self]
}
