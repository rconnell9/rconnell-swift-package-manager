//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import _Concurrency
import Build
import Dispatch

@_spi(SwiftPMInternal)
import DriverSupport

import Foundation
import OrderedCollections
import PackageGraph
import PackageLoading
import PackageModel
import SPMBuildCore
import XCBuildSupport
import SwiftBuildSupport

import struct TSCBasic.KeyedPair
import func TSCBasic.topologicalSort
import var TSCBasic.stdoutStream
import enum TSCBasic.GraphError
import struct TSCBasic.OrderedSet
import enum TSCUtility.Diagnostics
import struct TSCUtility.Version

await { () async in
    await SwiftBootstrapBuildTool.main()
}()

struct SwiftBootstrapBuildTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-bootstrap",
        abstract: "Bootstrapping build tool, only use in the context of bootstrapping SwiftPM itself.",
        shouldDisplay: false
    )

    @Option(name: .customLong("package-path"),
            help: "Specify the package path to operate on (default current directory). This changes the working directory before any other operation.",
            completion: .directory)
    public var packageDirectory: AbsolutePath?

    /// The custom .build directory, if provided.
    @Option(name: .customLong("scratch-path"), help: "Specify a custom scratch directory path (default .build).", completion: .directory)
    var _scratchDirectory: AbsolutePath?

    @Option(name: .customLong("build-path"), help: .hidden)
    var _deprecated_buildPath: AbsolutePath?

    var scratchDirectory: AbsolutePath? {
        self._scratchDirectory ?? self._deprecated_buildPath
    }

    @Option(name: .shortAndLong, help: "Build with configuration.")
    public var configuration: BuildConfiguration = .debug

    @Option(name: .customLong("Xcc", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all C compiler invocations.")
    var cCompilerFlags: [String] = []

    @Option(name: .customLong("Xswiftc", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all Swift compiler invocations.")
    var swiftCompilerFlags: [String] = []

    @Option(name: .customLong("Xlinker", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all linker invocations.")
    var linkerFlags: [String] = []

    @Option(name: .customLong("Xcxx", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: "Pass flag through to all C++ compiler invocations.")
    var cxxCompilerFlags: [String] = []

    @Option(name: .customLong("Xxcbuild", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: ArgumentHelp(
                "Pass flag through to the Xcode build system invocations.",
                visibility: .hidden))
    public var xcbuildFlags: [String] = []

    @Option(name: .customLong("Xbuild-tools-swiftc", withSingleDash: true),
            parsing: .unconditionalSingleValue,
            help: ArgumentHelp("Pass flag to the manifest build invocation.",
                               visibility: .hidden))
    public var manifestFlags: [String] = []

    @Option(
      name: .customLong("arch"),
      help: ArgumentHelp("Build the package for the these architectures.", visibility: .hidden))
    public var architectures: [String] = []

    /// The verbosity of informational output.
    @Flag(name: .shortAndLong, help: "Increase verbosity to include informational output.")
    public var verbose: Bool = false

    /// The verbosity of informational output.
    @Flag(name: [.long, .customLong("vv")], help: "Increase verbosity to include debug output.")
    public var veryVerbose: Bool = false

    /// Whether to use the integrated Swift driver rather than shelling out
    /// to a separate process.
    @Flag()
    public var useIntegratedSwiftDriver: Bool = false

    /// An option that indicates this build should check whether targets only import
    /// their explicitly-declared dependencies
    @Option(help: "Check that targets only import their explicitly-declared dependencies.")
    public var explicitTargetDependencyImportCheck: TargetDependencyImportCheckingMode = .none

    enum TargetDependencyImportCheckingMode: String, Codable, ExpressibleByArgument, CaseIterable {
        case none
        case error
    }

    /// Disables adding $ORIGIN/@loader_path to the rpath, useful when deploying
    @Flag(name: .customLong("disable-local-rpath"), help: "Disable adding $ORIGIN/@loader_path to the rpath by default.")
    public var shouldDisableLocalRpath: Bool = false

    /// The build system to use.
    @Option(name: .customLong("build-system"))
    var _buildSystem: BuildSystemProvider.Kind = .native

    private var buildSystem: BuildSystemProvider.Kind {
        #if os(macOS)
        // Force the Xcode build system if we want to build more than one arch.
        return self.architectures.count > 1 ? .xcode : self._buildSystem
        #else
        // Use whatever the build system provided by the command-line, or default fallback
        //  on other platforms.
        return self._buildSystem
        #endif
    }

    public var buildFlags: BuildFlags {
        BuildFlags(
            cCompilerFlags: self.cCompilerFlags,
            cxxCompilerFlags: self.cxxCompilerFlags,
            swiftCompilerFlags: self.swiftCompilerFlags,
            linkerFlags: self.linkerFlags,
            xcbuildFlags: self.xcbuildFlags
        )
    }

    private var logLevel: Basics.Diagnostic.Severity {
        if self.verbose {
            return .info
        } else if self.veryVerbose {
            return .debug
        } else {
            return .warning
        }
    }

    public init() {}

    public func run() async throws {
        do {
            let fileSystem = localFileSystem

            let observabilityScope = ObservabilitySystem { _, diagnostics in
                if diagnostics.severity >= logLevel {
                    print(diagnostics)
                }
            }.topScope

            guard let cwd: AbsolutePath = fileSystem.currentWorkingDirectory else {
                observabilityScope.emit(error: "couldn't determine the current working directory")
                throw ExitCode.failure
            }

            guard let packagePath = packageDirectory ?? localFileSystem.currentWorkingDirectory else {
                throw StringError("unknown package path")
            }

            let scratchDirectory =
                try BuildSystemUtilities.getEnvBuildPath(workingDir: cwd) ??
                self.scratchDirectory ??
                packagePath.appending(".build")

            let builder = try Builder(
                fileSystem: localFileSystem,
                observabilityScope: observabilityScope,
                logLevel: self.logLevel
            )

            try await builder.build(
                packagePath: packagePath,
                scratchDirectory: scratchDirectory,
                buildSystem: self.buildSystem,
                configuration: self.configuration,
                architectures: self.architectures,
                buildFlags: self.buildFlags,
                manifestBuildFlags: self.manifestFlags,
                useIntegratedSwiftDriver: self.useIntegratedSwiftDriver,
                explicitTargetDependencyImportCheck: self.explicitTargetDependencyImportCheck,
                shouldDisableLocalRpath: self.shouldDisableLocalRpath
            )
        } catch _ as Diagnostics {
            throw ExitCode.failure
        }
    }

    struct Builder {
        let identityResolver: IdentityResolver
        let dependencyMapper: DependencyMapper
        let hostToolchain: UserToolchain
        let targetToolchain: UserToolchain
        let fileSystem: FileSystem
        let observabilityScope: ObservabilityScope
        let logLevel: Basics.Diagnostic.Severity

        init(fileSystem: FileSystem, observabilityScope: ObservabilityScope, logLevel: Basics.Diagnostic.Severity) throws {
            self.identityResolver = DefaultIdentityResolver()
            self.dependencyMapper = DefaultDependencyMapper(identityResolver: self.identityResolver)
            let environment = Environment.current
            self.hostToolchain = try UserToolchain(
                swiftSDK: SwiftSDK.hostSwiftSDK(
                    environment: environment,
                    fileSystem: fileSystem
                ),
                environment: environment
            )
            self.targetToolchain = hostToolchain // TODO: support cross-compilation?
            self.fileSystem = fileSystem
            self.observabilityScope = observabilityScope
            self.logLevel = logLevel
        }

        func build(
            packagePath:  AbsolutePath,
            scratchDirectory: AbsolutePath,
            buildSystem: BuildSystemProvider.Kind,
            configuration: BuildConfiguration,
            architectures: [String],
            buildFlags: BuildFlags,
            manifestBuildFlags: [String],
            useIntegratedSwiftDriver: Bool,
            explicitTargetDependencyImportCheck: TargetDependencyImportCheckingMode,
            shouldDisableLocalRpath: Bool
        ) async throws {
            let buildSystem = try createBuildSystem(
                packagePath: packagePath,
                scratchDirectory: scratchDirectory,
                buildSystem: buildSystem,
                configuration: configuration,
                architectures: architectures,
                buildFlags: buildFlags,
                manifestBuildFlags: manifestBuildFlags,
                useIntegratedSwiftDriver: useIntegratedSwiftDriver,
                explicitTargetDependencyImportCheck: explicitTargetDependencyImportCheck,
                shouldDisableLocalRpath: shouldDisableLocalRpath,
                logLevel: logLevel
            )
            try await buildSystem.build(subset: .allExcludingTests)
        }

        func createBuildSystem(
            packagePath: AbsolutePath,
            scratchDirectory: AbsolutePath,
            buildSystem: BuildSystemProvider.Kind,
            configuration: BuildConfiguration,
            architectures: [String],
            buildFlags: BuildFlags,
            manifestBuildFlags: [String],
            useIntegratedSwiftDriver: Bool,
            explicitTargetDependencyImportCheck: TargetDependencyImportCheckingMode,
            shouldDisableLocalRpath: Bool,
            logLevel: Basics.Diagnostic.Severity
        ) throws -> BuildSystem {
            let dataPath = scratchDirectory.appending(
                component: self.targetToolchain.targetTriple.platformBuildPathComponent(buildSystem: buildSystem)
            )

            let buildParameters = try BuildParameters(
                destination: .target,
                dataPath: dataPath,
                configuration: configuration,
                toolchain: self.targetToolchain,
                triple: self.hostToolchain.targetTriple,
                flags: buildFlags,
                buildSystemKind: buildSystem,
                architectures: architectures,
                driverParameters: .init(
                    explicitTargetDependencyImportCheckingMode: explicitTargetDependencyImportCheck == .error ? .error : .none,
                    useIntegratedSwiftDriver: useIntegratedSwiftDriver,
                    isPackageAccessModifierSupported: DriverSupport.isPackageNameSupported(
                        toolchain: targetToolchain,
                        fileSystem: self.fileSystem
                    )
                ),
                linkingParameters: .init(
                    shouldDisableLocalRpath: shouldDisableLocalRpath
                ),
                outputParameters: .init(
                    isVerbose: logLevel <= .info
                )
            )

            let manifestLoader = createManifestLoader(manifestBuildFlags: manifestBuildFlags)

            let asyncUnsafePackageGraphLoader = {
                try await self.loadPackageGraph(packagePath: packagePath, manifestLoader: manifestLoader)
            }

            switch buildSystem {
            case .native:
                let pluginScriptRunner = DefaultPluginScriptRunner(
                    fileSystem: self.fileSystem,
                    cacheDir: scratchDirectory.appending("plugin-cache"),
                    toolchain: self.hostToolchain,
                    extraPluginSwiftCFlags: [],
                    enableSandbox: true,
                    verboseOutput: self.logLevel <= .info
                )
                return BuildOperation(
                    // when building `swift-bootstrap`, host and target build parameters are the same
                    productsBuildParameters: buildParameters,
                    toolsBuildParameters: buildParameters,
                    cacheBuildManifest: false,
                    packageGraphLoader: asyncUnsafePackageGraphLoader,
                    pluginConfiguration: .init(
                        scriptRunner: pluginScriptRunner,
                        workDirectory: scratchDirectory.appending(component: "plugin-working-directory"),
                        disableSandbox: false
                    ),
                    scratchDirectory: scratchDirectory,
                    // When bootstrapping no special trait build configuration is used
                    traitConfiguration: nil,
                    additionalFileRules: [],
                    pkgConfigDirectories: [],
                    outputStream: TSCBasic.stdoutStream,
                    logLevel: logLevel,
                    fileSystem: self.fileSystem,
                    observabilityScope: self.observabilityScope,
                    delegate: nil
                )
            case .xcode:
                return try XcodeBuildSystem(
                    buildParameters: buildParameters,
                    packageGraphLoader: asyncUnsafePackageGraphLoader,
                    outputStream: TSCBasic.stdoutStream,
                    logLevel: logLevel,
                    fileSystem: self.fileSystem,
                    observabilityScope: self.observabilityScope,
                    delegate: nil
                )
            case .swiftbuild:
                let pluginScriptRunner = DefaultPluginScriptRunner(
                    fileSystem: self.fileSystem,
                    cacheDir: scratchDirectory.appending("plugin-cache"),
                    toolchain: self.hostToolchain,
                    extraPluginSwiftCFlags: [],
                    enableSandbox: true,
                    verboseOutput: self.logLevel <= .info
                )

                return try SwiftBuildSystem(
                    buildParameters: buildParameters,
                    packageGraphLoader: asyncUnsafePackageGraphLoader,
                    packageManagerResourcesDirectory: nil,
                    additionalFileRules: [],
                    outputStream: TSCBasic.stdoutStream,
                    logLevel: logLevel,
                    fileSystem: self.fileSystem,
                    observabilityScope: self.observabilityScope,
                    pluginConfiguration: .init(
                        scriptRunner: pluginScriptRunner,
                        workDirectory: scratchDirectory.appending(component: "plugin-working-directory"),
                        disableSandbox: false
                    ),
                    delegate: nil,
                )
            }
        }

        func createManifestLoader(manifestBuildFlags: [String]) -> ManifestLoader {
            var extraManifestFlags = manifestBuildFlags
            if self.logLevel <= .info {
                extraManifestFlags.append("-v")
            }

            return ManifestLoader(
                toolchain: self.hostToolchain,
                isManifestSandboxEnabled: false,
                extraManifestFlags: extraManifestFlags
            )
        }

        func loadPackageGraph(packagePath: AbsolutePath, manifestLoader: ManifestLoader) async throws -> ModulesGraph {
            let rootPackageRef = PackageReference(identity: .init(path: packagePath), kind: .root(packagePath))
            let rootPackageManifest =  try await self.loadManifest(manifestLoader: manifestLoader, package: rootPackageRef)

            var loadedManifests = [PackageIdentity: Manifest]()
            loadedManifests[rootPackageRef.identity] = rootPackageManifest

            // Compute the transitive closure of available dependencies.
            let input = loadedManifests.map { identity, manifest in KeyedPair(manifest, key: identity) }
            _ = try await topologicalSort(input) { pair in
                // When bootstrapping no special trait build configuration is used
                let dependenciesRequired = try pair.item.dependenciesRequired(for: .everything, nil)
                let dependenciesToLoad = dependenciesRequired.map{ $0.packageRef }.filter { !loadedManifests.keys.contains($0.identity) }
                let dependenciesManifests = try await self.loadManifests(manifestLoader: manifestLoader, packages: dependenciesToLoad)
                dependenciesManifests.forEach { loadedManifests[$0.key] = $0.value }
                return dependenciesRequired.compactMap { dependency in
                    loadedManifests[dependency.identity].flatMap {
                        KeyedPair($0, key: dependency.identity)
                    }
                }
            }

            let packageGraphRoot = try PackageGraphRoot(
                input: .init(packages: [packagePath]),
                manifests: [packagePath: rootPackageManifest],
                observabilityScope: observabilityScope
            )

            return try ModulesGraph.load(
                root: packageGraphRoot,
                identityResolver: identityResolver,
                externalManifests: loadedManifests.reduce(into: OrderedCollections.OrderedDictionary<PackageIdentity, (manifest: Manifest, fs: FileSystem)>()) { partial, item in
                    partial[item.key] = (manifest: item.value, fs: self.fileSystem)
                },
                binaryArtifacts: [:],
                prebuilts: [:],
                fileSystem: fileSystem,
                observabilityScope: observabilityScope
            )
        }

        func loadManifests(
            manifestLoader: ManifestLoader,
            packages: [PackageReference]
        ) async throws -> [PackageIdentity: Manifest] {
            return try await withThrowingTaskGroup(of: (package:PackageReference, manifest:Manifest).self) { group in
                for package in packages {
                    group.addTask {
                        try await (package, self.loadManifest(manifestLoader: manifestLoader, package: package))
                    }
                }
                return try await group.reduce(into: [:]) { partialResult, packageManifest in
                    partialResult[packageManifest.package.identity] = packageManifest.manifest
                }
            }
        }

        func loadManifest(
            manifestLoader: ManifestLoader,
            package: PackageReference
        ) async throws -> Manifest {
            let packagePath = try Result { try AbsolutePath(validating: package.locationString) }.mapError({ StringError("Package path \(package.locationString) is not an absolute path. This can be caused by a dependency declared somewhere in the package graph that is using a URL instead of a local path. Original error: \($0)") }).get()
            let manifestPath = packagePath.appending(component: Manifest.filename)
            let manifestToolsVersion = try ToolsVersionParser.parse(manifestPath: manifestPath, fileSystem: fileSystem)
            return try await manifestLoader.load(
                manifestPath: manifestPath,
                manifestToolsVersion: manifestToolsVersion,
                packageIdentity: package.identity,
                packageKind: package.kind,
                packageLocation: package.locationString,
                packageVersion: .none,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope,
                delegateQueue: .sharedConcurrent
            )
        }
    }
}

// TODO: move to shared area
extension AbsolutePath {
    public init?(argument: String) {
        if let cwd: AbsolutePath = localFileSystem.currentWorkingDirectory {
            guard let path = try? AbsolutePath(validating: argument, relativeTo: cwd) else {
                return nil
            }
            self = path
        } else {
            guard let path = try? AbsolutePath(validating: argument) else {
                return nil
            }
            self = path
        }
    }

    public static var defaultCompletionKind: CompletionKind {
        // This type is most commonly used to select a directory, not a file.
        // Specify '.file()' in an argument declaration when necessary.
        .directory
    }
}

extension BuildConfiguration {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

extension AbsolutePath: ExpressibleByArgument {}
extension BuildConfiguration: ExpressibleByArgument {}
extension BuildSystemProvider.Kind: ExpressibleByArgument {}

public func topologicalSort<T: Hashable>(
    _ nodes: [T], successors: (T) async throws -> [T]
) async throws -> [T] {
    // Implements a topological sort via recursion and reverse postorder DFS.
    func visit(_ node: T,
               _ stack: inout OrderedSet<T>, _ visited: inout Set<T>, _ result: inout [T],
               _ successors: (T) async throws -> [T]) async throws {
        // Mark this node as visited -- we are done if it already was.
        if !visited.insert(node).inserted {
            return
        }

        // Otherwise, visit each adjacent node.
        for succ in try await successors(node) {
            guard stack.append(succ) else {
                // If the successor is already in this current stack, we have found a cycle.
                //
                // FIXME: We could easily include information on the cycle we found here.
                throw TSCBasic.GraphError.unexpectedCycle
            }
            try await visit(succ, &stack, &visited, &result, successors)
            let popped = stack.removeLast()
            assert(popped == succ)
        }

        // Add to the result.
        result.append(node)
    }

    // FIXME: This should use a stack not recursion.
    var visited = Set<T>()
    var result = [T]()
    var stack = OrderedSet<T>()
    for node in nodes {
        precondition(stack.isEmpty)
        stack.append(node)
        try await visit(node, &stack, &visited, &result, successors)
        let popped = stack.removeLast()
        assert(popped == node)
    }

    return result.reversed()
}
