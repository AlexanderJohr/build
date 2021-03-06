// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:build/src/builder/logging.dart';
import 'package:build_config/build_config.dart';
import 'package:graphs/graphs.dart';
import 'package:logging/logging.dart';

import '../generate/exceptions.dart';
import '../generate/phase.dart';
import '../validation/config_validation.dart';
import 'package_graph.dart';
import 'target_graph.dart';

typedef BuildPhase BuildPhaseFactory(
    PackageNode package,
    BuilderOptions options,
    InputSet targetSources,
    InputSet generateFor,
    bool isReleaseBuild);

typedef bool PackageFilter(PackageNode node);

/// Run a builder on all packages in the package graph.
PackageFilter toAllPackages() => (_) => true;

/// Require manual configuration to opt in to a builder.
PackageFilter toNoneByDefault() => (_) => false;

/// Run a builder on all packages with an immediate dependency on [packageName].
PackageFilter toDependentsOf(String packageName) =>
    (p) => p.dependencies.any((d) => d.name == packageName);

/// Run a builder on a single package.
PackageFilter toPackage(String package) => (p) => p.name == package;

/// Run a builder on a collection of packages.
PackageFilter toPackages(Set<String> packages) =>
    (p) => packages.contains(p.name);

/// Run a builders if the package matches any of [filters]
PackageFilter toAll(Iterable<PackageFilter> filters) =>
    (p) => filters.any((f) => f(p));

PackageFilter toRoot() => (p) => p.isRoot;

/// Apply [builder] to the root package.
///
/// Creates a `BuilderApplication` which corresponds to an empty builder key so
/// that no other `build.yaml` based configuration will apply.
BuilderApplication applyToRoot(Builder builder,
        {bool isOptional = false,
        bool hideOutput = false,
        InputSet generateFor}) =>
    new BuilderApplication.forBuilder('', [(_) => builder], toRoot(),
        isOptional: isOptional,
        hideOutput: hideOutput,
        defaultGenerateFor: generateFor);

/// Apply each builder from [builderFactories] to the packages matching
/// [filter].
///
/// If the builder should only run on a subset of files within a target pass
/// globs to [defaultGenerateFor]. This can be overridden by any target which
/// configured the builder manually.
///
/// If [isOptional] is true the builder will only run if one of its outputs is
/// read by a later builder, or is used as a primary input to a later builder.
/// If no build actions read the output of an optional action, then it will
/// never run.
///
/// Any existing Builders which match a key in [appliesBuilders] will
/// automatically be applied to any target which runs this Builder, whether
/// because it matches [filter] or because it was enabled manually.
BuilderApplication apply(String builderKey,
        List<BuilderFactory> builderFactories, PackageFilter filter,
        {bool isOptional,
        bool hideOutput,
        InputSet defaultGenerateFor,
        BuilderOptions defaultOptions,
        BuilderOptions defaultDevOptions,
        BuilderOptions defaultReleaseOptions,
        Iterable<String> appliesBuilders}) =>
    new BuilderApplication.forBuilder(
      builderKey,
      builderFactories,
      filter,
      isOptional: isOptional,
      hideOutput: hideOutput,
      defaultGenerateFor: defaultGenerateFor,
      defaultOptions: defaultOptions,
      defaultDevOptions: defaultDevOptions,
      defaultReleaseOptions: defaultReleaseOptions,
      appliesBuilders: appliesBuilders,
    );

/// Same as [apply] except it takes [PostProcessBuilderFactory]s.
///
/// Does not provide options for `isOptional` or `hideOutput` because they
/// aren't configurable for these types of builders. They are never optional and
/// always hidden.
BuilderApplication applyPostProcess(
        String builderKey, PostProcessBuilderFactory builderFactory,
        {InputSet defaultGenerateFor,
        BuilderOptions defaultOptions,
        BuilderOptions defaultDevOptions,
        BuilderOptions defaultReleaseOptions}) =>
    new BuilderApplication.forPostProcessBuilder(
      builderKey,
      builderFactory,
      defaultGenerateFor: defaultGenerateFor,
      defaultOptions: defaultOptions,
      defaultDevOptions: defaultDevOptions,
      defaultReleaseOptions: defaultReleaseOptions,
    );

/// A description of which packages need a given [Builder] or
/// [PostProcessBuilder] applied.
class BuilderApplication {
  /// Factories that create [BuildPhase]s for all [Builder]s or
  /// [PostProcessBuilder]s that should be applied.
  final List<BuildPhaseFactory> buildPhaseFactories;

  /// Determines whether a given package needs builder applied.
  final PackageFilter filter;

  /// Builder keys which, when applied to a target, will also apply this Builder
  /// even if [filter] does not match.
  final Iterable<String> appliesBuilders;

  /// A uniqe key for this builder.
  ///
  /// Ignored when null or empty.
  final String builderKey;

  /// Whether genereated assets should be placed in the build cache.
  final bool hideOutput;

  const BuilderApplication._(
    this.builderKey,
    this.buildPhaseFactories,
    this.filter,
    this.hideOutput,
    Iterable<String> appliesBuilders,
  ) : appliesBuilders = appliesBuilders ?? const [];

  factory BuilderApplication.forBuilder(
    String builderKey,
    List<BuilderFactory> builderFactories,
    PackageFilter filter, {
    bool isOptional,
    bool hideOutput,
    InputSet defaultGenerateFor,
    BuilderOptions defaultOptions,
    BuilderOptions defaultDevOptions,
    BuilderOptions defaultReleaseOptions,
    Iterable<String> appliesBuilders,
  }) {
    hideOutput ??= true;
    var phaseFactories = builderFactories.map((builderFactory) {
      return (PackageNode package, BuilderOptions options,
          InputSet targetSources, InputSet generateFor, bool isReleaseBuild) {
        generateFor ??= defaultGenerateFor;

        var optionsWithDefaults = (defaultOptions ?? BuilderOptions.empty)
            .overrideWith(
                isReleaseBuild ? defaultReleaseOptions : defaultDevOptions)
            .overrideWith(options);
        if (package.isRoot) {
          optionsWithDefaults =
              optionsWithDefaults.overrideWith(BuilderOptions.forRoot);
        }

        final logger = new Logger(builderKey);
        final builder =
            _scopeLogSync(() => builderFactory(optionsWithDefaults), logger);
        if (builder == null) {
          logger.severe(_factoryFailure(package.name, optionsWithDefaults));
          throw new CannotBuildException();
        }
        return new InBuildPhase(builder, package.name,
            builderKey: builderKey,
            targetSources: targetSources,
            generateFor: generateFor,
            builderOptions: optionsWithDefaults,
            hideOutput: hideOutput,
            isOptional: isOptional);
      };
    }).toList();
    return new BuilderApplication._(
        builderKey, phaseFactories, filter, hideOutput, appliesBuilders);
  }

  /// Note that these builder applications each create their own phase, but they
  /// will all eventually be merged into a single phase.
  factory BuilderApplication.forPostProcessBuilder(
    String builderKey,
    PostProcessBuilderFactory builderFactory, {
    InputSet defaultGenerateFor,
    BuilderOptions defaultOptions,
    BuilderOptions defaultDevOptions,
    BuilderOptions defaultReleaseOptions,
  }) {
    var phaseFactory = (PackageNode package, BuilderOptions options,
        InputSet targetSources, InputSet generateFor, bool isReleaseBuild) {
      generateFor ??= defaultGenerateFor;

      var optionsWithDefaults = (defaultOptions ?? BuilderOptions.empty)
          .overrideWith(
              isReleaseBuild ? defaultReleaseOptions : defaultDevOptions)
          .overrideWith(options);
      if (package.isRoot) {
        optionsWithDefaults =
            optionsWithDefaults.overrideWith(BuilderOptions.forRoot);
      }

      final logger = new Logger(builderKey);
      final builder =
          _scopeLogSync(() => builderFactory(optionsWithDefaults), logger);
      if (builder == null) {
        logger.severe(_factoryFailure(package.name, optionsWithDefaults));
        throw new CannotBuildException();
      }
      var builderAction = new PostBuildAction(builder, package.name,
          builderOptions: optionsWithDefaults,
          generateFor: generateFor,
          targetSources: targetSources);
      return new PostBuildPhase([builderAction]);
    };
    return new BuilderApplication._(
        builderKey, [phaseFactory], toNoneByDefault(), true, []);
  }
}

final _logger = new Logger('ApplyBuilders');

/// Creates a [BuildPhase] to apply each builder in [builderApplications] to
/// each target in [targetGraph] such that all builders are run for dependencies
/// before moving on to later packages.
///
/// When there is a package cycle the builders are applied to each packages
/// within the cycle before moving on to packages that depend on any package
/// within the cycle.
///
/// Builders may be filtered, for instance to run only on package which have a
/// dependency on some other package by choosing the appropriate
/// [BuilderApplication].
Future<List<BuildPhase>> createBuildPhases(
    TargetGraph targetGraph,
    Iterable<BuilderApplication> builderApplications,
    Map<String, Map<String, dynamic>> builderConfigOverrides,
    bool isReleaseMode) async {
  validateBuilderConfig(builderApplications, targetGraph.rootPackageConfig,
      builderConfigOverrides, _logger);
  final globalOptions = targetGraph.rootPackageConfig.globalOptions.map(
      (key, config) => new MapEntry(
          key,
          (config?.options ?? BuilderOptions.empty).overrideWith(
              isReleaseMode ? config?.releaseOptions : config?.devOptions)));
  for (final key in builderConfigOverrides.keys) {
    final overrides = new BuilderOptions(builderConfigOverrides[key]);
    globalOptions[key] =
        (globalOptions[key] ?? BuilderOptions.empty).overrideWith(overrides);
  }

  final cycles = stronglyConnectedComponents<String, TargetNode>(
      targetGraph.allModules.values,
      (node) => node.target.key,
      (node) => node.target.dependencies?.map((key) {
            if (!targetGraph.allModules.containsKey(key)) {
              _logger.severe('${node.target.key} declares a dependency on $key '
                  'but it does not exist');
              throw new CannotBuildException();
            }
            return targetGraph.allModules[key];
          })?.where((n) => n != null));
  final applyWith = _applyWith(builderApplications);
  final expandedPhases = cycles
      .expand((cycle) => _createBuildPhasesWithinCycle(
          cycle, builderApplications, globalOptions, applyWith, isReleaseMode))
      .toList();

  final inBuildPhases =
      expandedPhases.where((p) => p is InBuildPhase).cast<BuildPhase>();

  final postBuildPhases = expandedPhases
      .where((p) => p is PostBuildPhase)
      .cast<PostBuildPhase>()
      .toList();
  final collapsedPostBuildPhase = <PostBuildPhase>[];
  if (postBuildPhases.isNotEmpty) {
    collapsedPostBuildPhase.add(postBuildPhases
        .fold<PostBuildPhase>(new PostBuildPhase([]), (previous, next) {
      previous.builderActions.addAll(next.builderActions);
      return previous;
    }));
  }

  return inBuildPhases.followedBy(collapsedPostBuildPhase).toList();
}

Iterable<BuildPhase> _createBuildPhasesWithinCycle(
        Iterable<TargetNode> cycle,
        Iterable<BuilderApplication> builderApplications,
        Map<String, BuilderOptions> globalOptions,
        Map<String, List<BuilderApplication>> applyWith,
        bool isReleaseMode) =>
    builderApplications.expand((builderApplication) =>
        _createBuildPhasesForBuilderInCycle(
            cycle,
            builderApplication,
            globalOptions[builderApplication.builderKey] ??
                BuilderOptions.empty,
            applyWith,
            isReleaseMode));

Iterable<BuildPhase> _createBuildPhasesForBuilderInCycle(
    Iterable<TargetNode> cycle,
    BuilderApplication builderApplication,
    BuilderOptions globalOptionOverrides,
    Map<String, List<BuilderApplication>> applyWith,
    bool isReleaseMode) {
  TargetBuilderConfig targetConfig(TargetNode node) =>
      node.target.builders[builderApplication.builderKey];
  return builderApplication.buildPhaseFactories.expand((createPhase) => cycle
          .where((targetNode) =>
              _shouldApply(builderApplication, targetNode, applyWith))
          .map((node) {
        final builderConfig = targetConfig(node);
        final options = (builderConfig?.options ?? BuilderOptions.empty)
            .overrideWith(isReleaseMode
                ? builderConfig?.releaseOptions
                : builderConfig?.devOptions)
            .overrideWith(globalOptionOverrides);
        return createPhase(node.package, options, node.target.sources,
            builderConfig?.generateFor, isReleaseMode);
      }));
}

bool _shouldApply(BuilderApplication builderApplication, TargetNode node,
    Map<String, List<BuilderApplication>> applyWith) {
  if (!builderApplication.hideOutput && !node.package.isRoot) {
    return false;
  }
  final builderConfig = node.target.builders[builderApplication.builderKey];
  if (builderConfig?.isEnabled != null) {
    return builderConfig.isEnabled;
  }
  return builderApplication.filter(node.package) ||
      (applyWith[builderApplication.builderKey] ?? const [])
          .any((anchorBuilder) => _shouldApply(anchorBuilder, node, applyWith));
}

/// Inverts the dependency map from 'applies builders' to 'applied with
/// builders'.
Map<String, List<BuilderApplication>> _applyWith(
    Iterable<BuilderApplication> builderApplications) {
  final applyWith = <String, List<BuilderApplication>>{};
  for (final builderApplication in builderApplications) {
    for (final alsoApply in builderApplication.appliesBuilders) {
      applyWith.putIfAbsent(alsoApply, () => []).add(builderApplication);
    }
  }
  return applyWith;
}

/// Runs [fn] in an error handling [Zone].
///
/// Any calls to [print] will be logged with `log.info`, and any errors will be
/// logged with `log.severe`.
T _scopeLogSync<T>(T fn(), Logger log) {
  return runZoned(fn,
      zoneSpecification:
          new ZoneSpecification(print: (self, parent, zone, message) {
        log.info(message);
      }),
      zoneValues: {logKey: log},
      onError: (Object e, StackTrace s) {
        log.severe('', e, s);
      });
}

String _factoryFailure(String packageName, BuilderOptions options) =>
    'Failed to instantiate builder for $packageName with configuration:\n'
    '${new JsonEncoder.withIndent(' ').convert(options.config)}';
