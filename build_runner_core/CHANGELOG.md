## 0.2.0-dev

### New Features

- The `BuildPerformance` class is now serializable, it has a `fromJson`
  constructor and a `toJson` instance method.
- Added `BuildOptions.logPerformanceDir`, performance logs will be continuously
  written to that directory if provided.
- Added support for `global_options` in `build.yaml` of the root package.

### Breaking changes

- `BuildPhasePerformance.action` has been replaced with
  `BuildPhasePerformance.builderKeys`.
- `BuilderActionPerformance.builder` has been replaced with
  `BuilderActionPerformance.builderKey`.

### Internal changes

- Remove dependency on package:cli_util.

## 0.1.0

Initial release, migrating the core functionality of package:build_runner to
this package.
