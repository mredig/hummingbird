//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTPTypes
import HummingbirdCore
import NIOCore

/// Create rules for routing requests and then create `Responder` that will follow these rules.
///
/// `Router` requires an implementation of  the `on(path:method:use)` functions but because it
/// also conforms to `RouterMethods` it is also possible to call the method specific functions `get`, `put`,
/// `head`, `post` and `patch`.  The route handler closures all return objects conforming to
/// `ResponseGenerator`.  This allows us to support routes which return a multitude of types eg
/// ```
/// router.get("string") { _, _ -> String in
///     return "string"
/// }
/// router.post("status") { _, _ -> HTTPResponse.Status in
///     return .ok
/// }
/// router.data("data") { request, context -> ByteBuffer in
///     return ByteBuffer(string: "buffer")
/// }
/// ```
///
/// The default `Router` setup in `Application` is the `TrieRouter` . This uses a
/// trie to partition all the routes for faster access. It also supports wildcards and parameter extraction
/// ```
/// router.get("user/*", use: anyUser)
/// router.get("user/:id", use: userWithId)
/// ```
/// Both of these match routes which start with "/user" and the next path segment being anything.
/// The second version extracts the path segment out and adds it to `Request.parameters` with the
/// key "id".
public final class Router<Context: RequestContext>: RouterMethods, HTTPResponderBuilder {
    var trie: RouterPathTrieBuilder<EndpointResponders<Context>>
    public let middlewares: MiddlewareGroup<Context>
    let options: RouterOptions

    public init(context: Context.Type = BasicRequestContext.self, options: RouterOptions = []) {
        self.trie = RouterPathTrieBuilder()
        self.middlewares = .init()
        self.options = options
    }

    /// build responder from router
    public func buildResponder() -> RouterResponder<Context> {
        if self.options.contains(.autoGenerateHeadEndpoints) {
            // swift-format-ignore: ReplaceForEachWithForLoop
            self.trie.forEach { node in
                node.value?.autoGenerateHeadEndpoint()
            }
        }
        return .init(
            context: Context.self,
            trie: self.trie,
            options: self.options,
            notFoundResponder: self.middlewares.constructResponder(finalResponder: NotFoundResponder<Context>())
        )
    }

    /// Add responder to call when path and method are matched
    ///
    /// - Parameters:
    ///   - path: Path to match
    ///   - method: Request method to match
    ///   - responder: Responder to call if match is made
    @discardableResult public func on<Responder: HTTPResponder>(
        _ path: RouterPath,
        method: HTTPRequest.Method,
        responder: Responder
    ) -> Self where Responder.Context == Context {
        var path = path
        if self.options.contains(.caseInsensitive) {
            path = path.lowercased()
        }
        self.trie.addEntry(path, value: EndpointResponders(path: path)) { node in
            node.value!.addResponder(for: method, responder: self.middlewares.constructResponder(finalResponder: responder))
        }
        return self
    }

    /// Add middleware to Router
    ///
    /// This middleware will only be applied to endpoints added after this call.
    /// - Parameter middleware: Middleware we are adding
    @discardableResult public func add(middleware: any MiddlewareProtocol<Request, Response, Context>) -> Self {
        self.middlewares.add(middleware)
        return self
    }
}

/// Responder that return a not found error
struct NotFoundResponder<Context: RequestContext>: HTTPResponder {
    func respond(to request: Request, context: Context) throws -> Response {
        throw HTTPError(.notFound)
    }
}

/// A type that has a single method to build a HTTPResponder
public protocol HTTPResponderBuilder {
    associatedtype Responder: HTTPResponder
    /// build a responder
    func buildResponder() -> Responder
}

/// Router Options
public struct RouterOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Router path comparisons will be case insensitive
    public static var caseInsensitive: Self { .init(rawValue: 1 << 0) }
    /// For every GET request that does not have a HEAD request, auto generate the HEAD request
    public static var autoGenerateHeadEndpoints: Self { .init(rawValue: 1 << 1) }
}

extension Router {
    /// Route description
    public struct RouteDescription: CustomStringConvertible {
        /// Route path
        public let path: RouterPath
        /// Route method
        public let method: HTTPRequest.Method

        public var description: String { "\(method) \(path)" }
    }

    /// List of routes added to router
    public var routes: [RouteDescription] {
        let trieValues = self.trie.root.values()
        return trieValues.flatMap { endpoint in
            endpoint.value.methods.keys
                .sorted { $0.rawValue < $1.rawValue }
                .map { RouteDescription(path: endpoint.path, method: $0) }
        }
    }

    /// Validate router
    ///
    /// Verify that routes are not clashing
    public func validate() throws {
        func matching(routerPath: RouterPath, pathComponents: [String]) -> Bool {
            guard routerPath.count == pathComponents.count else { return false }
            for index in 0..<routerPath.count {
                if case routerPath[index] = pathComponents[index] {
                    continue
                }
                return false
            }
            return true
        }
        // get trie routes sorted in the way they will be evaluated after building the router
        let trieValues = self.trie.root.values().sorted { lhs, rhs in
            let count = min(lhs.path.count, rhs.path.count)
            for i in 0..<count {
                if lhs.path[i].priority < rhs.path[i].priority {
                    return false
                }
            }
            return true
        }
        guard trieValues.count > 1 else { return }
        for index in 1..<trieValues.count {
            // create path that will match this trie entry
            let pathComponents = trieValues[index].path.flatMap { element -> [String] in
                switch element.value {
                case .path(let path):
                    [String(path)]
                case .capture:
                    [UUID().uuidString]
                case .prefixCapture(let suffix, _):
                    ["\(UUID().uuidString)\(suffix)"]
                case .suffixCapture(let prefix, _):
                    ["\(prefix)/\(UUID().uuidString)"]
                case .wildcard:
                    [UUID().uuidString]
                case .prefixWildcard(let suffix):
                    ["\(UUID().uuidString)\(suffix)"]
                case .suffixWildcard(let prefix):
                    ["\(prefix)/\(UUID().uuidString)"]
                case .recursiveWildcard:
                    // can't think of a better way to do this at the moment except
                    // by creating path woith many entries
                    (0..<20).map { _ in UUID().uuidString }
                case .null:
                    [""]
                }
            }
            // test path against all the previous trie entries
            for route in trieValues[0..<index] {
                if matching(routerPath: route.path, pathComponents: pathComponents) {
                    throw RouterValidationError(
                        path: trieValues[index].path,
                        override: route.path
                    )
                }
            }
        }
    }
}

/// Router validation error
public struct RouterValidationError: Error, CustomStringConvertible {
    let path: RouterPath
    let override: RouterPath

    public var description: String {
        "Route \(override) overrides \(path)"
    }
}
