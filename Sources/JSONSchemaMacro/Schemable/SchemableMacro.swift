import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum SchemableError: Error { case unsupportedDeclaration }
extension SchemableError: CustomStringConvertible {
  var description: String {
    switch self {
    case .unsupportedDeclaration: "Macro can only be applied to struct or class"
    }
  }
}

public struct SchemableMacro: MemberMacro, ExtensionMacro {

  // MARK: - Utils

  private static func extractAccessLevel(from declaration: some DeclGroupSyntax) -> String? {
    declaration.modifiers.first { m in
      ["public", "internal", "package", "fileprivate", "private"].contains(m.name.text)
    }?.name.text
  }

  /// Get the effective access level for the schema property, considering enclosing extensions
  private static func effectiveAccessLevel(
    from declaration: some DeclGroupSyntax,
    context: some MacroExpansionContext
  ) -> String? {
    if let declAccessLevel = extractAccessLevel(from: declaration) {
      return declAccessLevel
    }

    let lexicalContext = context.lexicalContext
    for contextElement in lexicalContext {
      if let extensionDecl = contextElement.as(ExtensionDeclSyntax.self) {
        let extensionAccessLevel = extensionDecl.modifiers.first { modifier in
          ["public", "package", "internal"].contains(modifier.name.text)
        }?.name.text

        if let extensionAccessLevel {
          return extensionAccessLevel
        }
      }
    }

    return nil
  }

  /// Parse a boolean labeled arg
  private static func boolArg(_ node: AttributeSyntax, name: String) -> Bool? {
    guard
      let args = node.arguments?.as(LabeledExprListSyntax.self),
      let expr = args.first(where: { $0.label?.text == name })?.expression
    else { return nil }
    if let b = expr.as(BooleanLiteralExprSyntax.self) {
      return b.literal.tokenKind == .keyword(.true)
    }
    return nil
  }

  /// Parse `mode:` enum arg: `.refs` or `.inline` (default .refs)
  private static func modeArg(_ node: AttributeSyntax) -> String {
    guard
      let args = node.arguments?.as(LabeledExprListSyntax.self),
      let expr = args.first(where: { $0.label?.text == "mode" })?.expression
    else { return "inline" }
    let txt = expr.description.trimmingCharacters(in: .whitespacesAndNewlines)
    if txt.contains("refs") { return "refs" }
    return "inline"
  }

  /// Parse `keyStrategy:` expression (passed through verbatim)
  private static func keyStrategyExpr(_ node: AttributeSyntax) -> ExprSyntax? {
    node.arguments?
      .as(LabeledExprListSyntax.self)?
      .first(where: { $0.label?.text == "keyStrategy" })?
      .expression
  }

  /// Base identifier for a type (unwrap Optional, Array, IUO, Member types)
  private static func baseTypeName(from type: TypeSyntax) -> String? {
    if let opt = type.as(OptionalTypeSyntax.self) { return baseTypeName(from: opt.wrappedType) }
    if let iu = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return baseTypeName(from: iu.wrappedType) }
    if let arr = type.as(ArrayTypeSyntax.self) { return baseTypeName(from: arr.element) }
    if let id = type.as(IdentifierTypeSyntax.self) { return id.name.text }
    if let mem = type.as(MemberTypeSyntax.self) {
      return mem.baseType.description.trimmingCharacters(in: .whitespacesAndNewlines) + "." + mem.name.text
    }
    return nil
  }

  private static func collectDirectRefs(in decl: some DeclGroupSyntax, selfName: String) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for m in decl.memberBlock.members.schemableMembers() {
      guard let base = baseSchemableTypeName(from: m.type), base != selfName else { continue }
      if seen.insert(base).inserted { out.append(base) }
    }
    return out
  }

  // MARK: - ExtensionMacro

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let accessLevel = declaration.modifiers.first { modifier in
      ["private", "fileprivate"].contains(modifier.name.text)
    }?.name.text

    let mode = modeArg(node)
    let addsProvider = mode == "refs" && !declaration.is(EnumDeclSyntax.self)

    let extensionDecl = try ExtensionDeclSyntax(
      """
      \(raw: accessLevel.map { "\($0) " } ?? "")extension \(type.trimmed): Schemable\(raw: addsProvider ? ", _SchemableRefsProvider" : "") {}
      """
    )

    return [extensionDecl]
  }

  // MARK: - MemberMacro

  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let accessLevel = effectiveAccessLevel(from: declaration, context: context)
    let accessModifier = accessLevel.map { "\($0) " } ?? ""

    let arguments = node.arguments?.as(LabeledExprListSyntax.self)
    let strategyArg = arguments?.first(where: { $0.label?.text == "keyStrategy" })?.expression
    let mode = modeArg(node)
    let attachDefs = boolArg(node, name: "attachDefs") ?? false

    if let structDecl = declaration.as(StructDeclSyntax.self) {
      return try makeMembersForNominalDecl(
        name: structDecl.name.text,
        decl: declaration,
        accessMod: accessModifier,
        keyStrategy: strategyArg,
        mode: mode,
        attachDefs: attachDefs,
        accessLevel: accessLevel,
        context: context,
        arguments: arguments,
        isClass: false
      )
    } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
      return try makeMembersForNominalDecl(
        name: classDecl.name.text,
        decl: declaration,
        accessMod: accessModifier,
        keyStrategy: strategyArg,
        mode: mode,
        attachDefs: attachDefs,
        accessLevel: accessLevel,
        context: context,
        arguments: arguments,
        isClass: true
      )
    } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      let enumCompositionArg = arguments?
        .first(where: { $0.label?.text == "enumComposition" })?
        .expression
      let generator = EnumSchemaGenerator(
        fromEnum: enumDecl,
        accessLevel: accessLevel,
        composition: CompositionKeyword(argument: enumCompositionArg)
      )
      var decls: [DeclSyntax] = [generator.makeSchema()]

      if mode == "refs" {
        let emptyRefs: DeclSyntax = "nonisolated(unsafe) static let __directRefs: [any Schemable.Type] = []"
        decls.append(emptyRefs)
      }

      if let strategyArg {
        let property: DeclSyntax = """
          @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
          \(raw: accessModifier)static var keyEncodingStrategy: KeyEncodingStrategies { \(strategyArg) }
          """
        decls.append(property)
      }
      return decls
    }

    throw SchemableError.unsupportedDeclaration
  }

  // MARK: - Helpers

  private static func makeMembersForNominalDecl(
    name selfName: String,
    decl: some DeclGroupSyntax,
    accessMod: String,
    keyStrategy: ExprSyntax?,
    mode: String,
    attachDefs: Bool,
    accessLevel: String?,
    context: some MacroExpansionContext,
    arguments: LabeledExprListSyntax?,
    isClass: Bool
  ) throws -> [DeclSyntax] {

    // In inline mode, delegate entirely to upstream generators (preserving exact output order)
    if mode == "inline" {
      let optionalNullsArg = arguments?.first(where: { $0.label?.text == "optionalNulls" })?.expression
      let optionalNullUnionArg = arguments?.first(where: { $0.label?.text == "optionalNullUnion" })?.expression
      let optionalNulls: Bool
      if let boolLiteral = optionalNullsArg?.as(BooleanLiteralExprSyntax.self) {
        optionalNulls = boolLiteral.literal.text == "true"
      } else {
        optionalNulls = true
      }
      let optionalNullUnion = CompositionKeyword(argument: optionalNullUnionArg)

      let schemaDecl: DeclSyntax
      if let s = decl.as(StructDeclSyntax.self) {
        schemaDecl = SchemaGenerator(
          fromStruct: s,
          keyStrategy: keyStrategy,
          optionalNulls: optionalNulls,
          accessLevel: accessLevel,
          context: context,
          optionalNullUnion: optionalNullUnion
        ).makeSchema()
      } else if let c = decl.as(ClassDeclSyntax.self) {
        schemaDecl = SchemaGenerator(
          fromClass: c,
          keyStrategy: keyStrategy,
          optionalNulls: optionalNulls,
          accessLevel: accessLevel,
          context: context,
          optionalNullUnion: optionalNullUnion
        ).makeSchema()
      } else {
        throw SchemableError.unsupportedDeclaration
      }

      var decls: [DeclSyntax] = [schemaDecl]
      if let ks = keyStrategy {
        let property: DeclSyntax = """
          @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
          \(raw: accessMod)static var keyEncodingStrategy: KeyEncodingStrategies { \(ks) }
          """
        decls.append(property)
      }
      return decls
    }

    // refs mode: generate __directRefs + $ref-based schema
    var out: [DeclSyntax] = []

    if let ks = keyStrategy {
      out.append(
        """
        @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
        \(raw: accessMod)static var keyEncodingStrategy: KeyEncodingStrategies { \(ks) }
        """
      )
    }

    // __directRefs
    let refs = collectDirectRefs(in: decl, selfName: selfName)
    let refsList = refs.map { "\($0).self" }.joined(separator: ", ")
    out.append(
      """
      \(raw: accessMod)nonisolated(unsafe) static let __directRefs: [any Schemable.Type] = [\(raw: refsList)]
      """
    )

    // schema (refs mode)
    do {
      let members = decl.memberBlock.members.schemableMembers()

      var propertyStrings: [String] = []

      for m in members {
        let key = m.identifier.text
        let isOpt = m.type.isOptional

        if let base = baseSchemableTypeName(from: m.type) {
          if isArray(m.type) {
            let line = #"JSONProperty(key: "\#(key)") { JSONArray { Ref<\#(base)>() } }"#
            propertyStrings.append(requiredWrap(line, isOpt))
          } else if isDictionary(m.type) {
            let line = #"JSONProperty(key: "\#(key)") { JSONObject().additionalProperties { Ref<\#(base)>() } }"#
            propertyStrings.append(requiredWrap(line, isOpt))
          } else {
            let line = #"JSONProperty(key: "\#(key)") { Ref<\#(base)>() }"#
            propertyStrings.append(requiredWrap(line, isOpt))
          }
        } else {
          var didUseSelfRef = false
          if let code = m.generateSchema(
            keyStrategy: keyStrategy,
            typeName: selfName,
            optionalNullUnion: .oneOf,
            didUseSelfReference: &didUseSelfRef
          ) {
            propertyStrings.append(code.description)
          }
        }
      }

      let body: ExprSyntax = """
        JSONSchema(\(raw: selfName).init) {
          JSONObject {
            \(raw: propertyStrings.joined(separator: "\n    "))
          }
          .additionalProperties(false)
        }
        """

      let expr: ExprSyntax = attachDefs
        ? "\(body).withDefs(collectTransitiveDefs(from: __directRefs))"
        : body

      out.append(
        """
        @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
        @JSONSchemaBuilder
        \(raw: accessMod)static var schema: some JSONSchemaComponent<\(raw: selfName)> {
          \(expr)
        }
        """
      )
    }

    return out
  }

  private static let nonSchemableFoundationTypes: Set<String> = [
    "UUID", "Date", "URL", "Data", "Decimal", "JSONValue",
  ]

  private static func baseSchemableTypeName(from type: TypeSyntax) -> String? {
    if let t = type.as(OptionalTypeSyntax.self) { return baseSchemableTypeName(from: t.wrappedType) }
    if let t = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return baseSchemableTypeName(from: t.wrappedType) }
    if let arr = type.as(ArrayTypeSyntax.self) { return baseSchemableTypeName(from: arr.element) }
    if let id = type.as(IdentifierTypeSyntax.self), let gen = id.genericArgumentClause {
      #if canImport(SwiftSyntax601)
      if id.name.text == "Array", let first = gen.arguments.first?.argument,
         case GenericArgumentSyntax.Argument.type(let elt) = first {
        return baseSchemableTypeName(from: elt)
      }
      if id.name.text == "Dictionary",
         let second = gen.arguments.dropFirst().first?.argument,
         case GenericArgumentSyntax.Argument.type(let valueArg) = second {
        return baseSchemableTypeName(from: valueArg)
      }
      #else
      if id.name.text == "Array", let elt = gen.arguments.first?.argument {
        return baseSchemableTypeName(from: elt)
      }
      if id.name.text == "Dictionary" {
        guard let valueArg = gen.arguments.dropFirst().first?.argument else { return nil }
        return baseSchemableTypeName(from: valueArg)
      }
      #endif
    }
    if let id = type.as(IdentifierTypeSyntax.self) {
      let base = id.name.text
      if SupportedPrimitive(rawValue: base) != nil { return nil }
      if nonSchemableFoundationTypes.contains(base) { return nil }
      return base
    }
    if let mem = type.as(MemberTypeSyntax.self) {
      return mem.baseType.description.trimmingCharacters(in: .whitespacesAndNewlines) + "." + mem.name.text
    }
    return nil
  }

  private static func unwrapOptionals(_ t: TypeSyntax) -> TypeSyntax {
    if let o = t.as(OptionalTypeSyntax.self) { return unwrapOptionals(o.wrappedType) }
    if let u = t.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return unwrapOptionals(u.wrappedType) }
    return t
  }

  static func isArray(_ t: TypeSyntax) -> Bool {
    let u = unwrapOptionals(t)
    if u.is(ArrayTypeSyntax.self) { return true }
    if let id = u.as(IdentifierTypeSyntax.self), id.name.text == "Array" { return true }
    return false
  }

  static func isDictionary(_ t: TypeSyntax) -> Bool {
    let u = unwrapOptionals(t)
    if u.is(DictionaryTypeSyntax.self) { return true }
    if let id = u.as(IdentifierTypeSyntax.self), id.name.text == "Dictionary" { return true }
    return false
  }

  static func requiredWrap(_ s: String, _ opt: Bool) -> String {
    opt ? s : "\(s)\n    .required()"
  }

}
