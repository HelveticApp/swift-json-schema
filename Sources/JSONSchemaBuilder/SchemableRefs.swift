import JSONSchema

/// $ref "#/$defs/TypeName"
public struct Ref<T>: JSONSchemaComponent {
	public var schemaValue: SchemaValue
	public init() {
		self.schemaValue = .object([ KeywordIdentifier("$ref"): .string("#/$defs/\(String(describing: T.self))") ])
	}
	public func parse(_ _: JSONValue) -> Parsed<T, ParseIssue> { .invalid([]) }
}

/// Un composant qui porte un SchemaValue arbitraire.
public struct JSONRaw<Out>: JSONSchemaComponent {
	public var schemaValue: SchemaValue
	public init(_ v: SchemaValue) { self.schemaValue = v }
	public func parse(_ _: JSONValue) -> Parsed<Out, ParseIssue> { .invalid([]) }
}

/// Joindre $defs construits à partir de types @Schemable.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public extension JSONSchemaComponent {
	func withDefs(_ defs: [any Schemable.Type]) -> JSONRaw<Output> {
		var sv = self.schemaValue
		var dict: [KeywordIdentifier: JSONValue] = [:]
		for t in defs.uniqueSchemables() {
			dict[KeywordIdentifier(String(describing: t))] = t.schema.schemaValue.value
		}
		sv[KeywordIdentifier("$defs")] = .object(dict)
		return JSONRaw(sv)
	}
}

public extension Array where Element == any Schemable.Type {
	func uniqueSchemables() -> [any Schemable.Type] {
		var seen = Set<ObjectIdentifier>()
		var out: [any Schemable.Type] = []
		for t in self {
			let id = ObjectIdentifier(t)
			if seen.insert(id).inserted { out.append(t) }
		}
		return out
	}
}

/// Pour que la macro publie ses refs directes
public protocol _SchemableRefsProvider {
	static var __directRefs: [any Schemable.Type] { get }
}

/// Transitive closure des références à partir d'un ensemble de racines.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public func collectTransitiveDefs(from roots: [any Schemable.Type]) -> [any Schemable.Type] {
	var stack = roots
	var seen  = Set<ObjectIdentifier>()
	var out: [any Schemable.Type] = []
	
	while let t = stack.popLast() {
		let id = ObjectIdentifier(t)
		guard seen.insert(id).inserted else { continue }
		out.append(t)
		if let p = t as? _SchemableRefsProvider.Type {
			stack.append(contentsOf: p.__directRefs)
		}
	}
	return out
}
