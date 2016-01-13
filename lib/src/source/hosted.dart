// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io' as io;
import "dart:convert";

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import '../exceptions.dart';
import '../http.dart';
import '../io.dart';
import '../log.dart' as log;
import '../package.dart';
import '../pubspec.dart';
import '../utils.dart';
import 'cached.dart';

/// A package source that gets packages from a package hosting site that uses
/// the same API as pub.dartlang.org.
class HostedSource extends CachedSource {
  /// Returns a reference to a hosted package named [name].
  ///
  /// If [url] is passed, it's the URL of the pub server from which the package
  /// should be downloaded. It can be a [Uri] or a [String].
  static PackageRef refFor(String name, {url}) =>
      new PackageRef(name, 'hosted', _descriptionFor(name, url));

  /// Returns an ID for a hosted package named [name] at [version].
  ///
  /// If [url] is passed, it's the URL of the pub server from which the package
  /// should be downloaded. It can be a [Uri] or a [String].
  static PackageId idFor(String name, Version version, {url}) =>
      new PackageId(name, 'hosted', version, _descriptionFor(name, url));

  /// Returns the description for a hosted package named [name] with the
  /// given package server [url].
  static _descriptionFor(String name, [url]) {
    if (url == null) return name;

    if (url is! String && url is! Uri) {
      throw new ArgumentError.value(url, 'url', 'must be a Uri or a String.');
    }

    return {'name': name, 'url': url.toString()};
  }

  final name = "hosted";
  final hasMultipleVersions = true;

  /// Gets the default URL for the package server for hosted dependencies.
  static String get defaultUrl {
    var url = io.Platform.environment["PUB_HOSTED_URL"];
    if (url != null) return url;

    return "https://pub.dartlang.org";
  }

  /// Downloads a list of all versions of a package that are available from the
  /// site.
  Future<List<PackageId>> doGetVersions(PackageRef ref) async {
    var url = _makeUrl(ref.description,
        (server, package) => "$server/api/packages/$package");

    log.io("Get versions from $url.");

    var body;
    try {
      body = await httpClient.read(url, headers: PUB_API_HEADERS);
    } catch (error, stackTrace) {
      var parsed = _parseDescription(ref.description);
      _throwFriendlyError(error, stackTrace, parsed.first, parsed.last);
    }

    var doc = JSON.decode(body);
    return doc['versions'].map((map) {
      var pubspec = new Pubspec.fromMap(
          map['pubspec'], systemCache.sources,
          expectedName: ref.name, location: url);
      var id = idFor(ref.name, pubspec.version);
      memoizePubspec(id, pubspec);

      return id;
    }).toList();
  }

  /// Downloads and parses the pubspec for a specific version of a package that
  /// is available from the site.
  Future<Pubspec> describeUncached(PackageId id) async {
    // Request it from the server.
    var url = _makeVersionUrl(id, (server, package, version) =>
        "$server/api/packages/$package/versions/$version");

    log.io("Describe package at $url.");
    var version;
    try {
      version = JSON.decode(
          await httpClient.read(url, headers: PUB_API_HEADERS));
    } catch (error, stackTrace) {
      var parsed = _parseDescription(id.description);
      _throwFriendlyError(error, stackTrace, id.name, parsed.last);
    }

    return new Pubspec.fromMap(
        version['pubspec'], systemCache.sources,
        expectedName: id.name, location: url);
  }

  /// Downloads the package identified by [id] to the system cache.
  Future<Package> downloadToSystemCache(PackageId id) async {
    if (!isInSystemCache(id)) {
      var packageDir = getDirectory(id);
      ensureDir(path.dirname(packageDir));
      var parsed = _parseDescription(id.description);
      await _download(parsed.last, parsed.first, id.version, packageDir);
    }

    return new Package.load(id.name, getDirectory(id), systemCache.sources);
  }

  /// The system cache directory for the hosted source contains subdirectories
  /// for each separate repository URL that's used on the system.
  ///
  /// Each of these subdirectories then contains a subdirectory for each
  /// package downloaded from that site.
  String getDirectory(PackageId id) {
    var parsed = _parseDescription(id.description);
    var dir = _urlToDirectory(parsed.last);
    return path.join(systemCacheRoot, dir, "${parsed.first}-${id.version}");
  }

  String packageName(description) => _parseDescription(description).first;

  bool descriptionsEqual(description1, description2) =>
      _parseDescription(description1) == _parseDescription(description2);

  /// Ensures that [description] is a valid hosted package description.
  ///
  /// There are two valid formats. A plain string refers to a package with the
  /// given name from the default host, while a map with keys "name" and "url"
  /// refers to a package with the given name from the host at the given URL.
  PackageRef parseRef(String name, description, {String containingPath}) {
    _parseDescription(description);
    return new PackageRef(name, this.name, description);
  }

  PackageId parseId(String name, Version version, description) {
    _parseDescription(description);
    return new PackageId(name, this.name, version, description);
  }

  /// Re-downloads all packages that have been previously downloaded into the
  /// system cache from any server.
  Future<Pair<List<PackageId>, List<PackageId>>> repairCachedPackages() async {
    if (!dirExists(systemCacheRoot)) return new Pair([], []);

    var successes = [];
    var failures = [];

    for (var serverDir in listDir(systemCacheRoot)) {
      var url = _directoryToUrl(path.basename(serverDir));
      var packages = _getCachedPackagesInDirectory(path.basename(serverDir));
      packages.sort(Package.orderByNameAndVersion);

      for (var package in packages) {
        var id = idFor(package.name, package.version);

        try {
          await _download(url, package.name, package.version, package.dir);
          successes.add(id);
        } catch (error, stackTrace) {
          failures.add(id);
          var message = "Failed to repair ${log.bold(package.name)} "
              "${package.version}";
          if (url != defaultUrl) message += " from $url";
          log.error("$message. Error:\n$error");
          log.fine(stackTrace);

          tryDeleteEntry(package.dir);
        }
      }
    }

    return new Pair(successes, failures);
  }

  /// Gets all of the packages that have been downloaded into the system cache
  /// from the default server.
  List<Package> getCachedPackages() {
    return _getCachedPackagesInDirectory(_urlToDirectory(defaultUrl));
  }

  /// Gets all of the packages that have been downloaded into the system cache
  /// into [dir].
  List<Package> _getCachedPackagesInDirectory(String dir) {
    var cacheDir = path.join(systemCacheRoot, dir);
    if (!dirExists(cacheDir)) return [];

    return listDir(cacheDir)
        .map((entry) => new Package.load(null, entry, systemCache.sources))
        .toList();
  }

  /// Downloads package [package] at [version] from [server], and unpacks it
  /// into [destPath].
  Future _download(String server, String package, Version version,
      String destPath) async {
    var url = Uri.parse("$server/packages/$package/versions/$version.tar.gz");
    log.io("Get package from $url.");
    log.message('Downloading ${log.bold(package)} ${version}...');

    // Download and extract the archive to a temp directory.
    var tempDir = systemCache.createTempDir();
    var response = await httpClient.send(new http.Request("GET", url));
    await extractTarGz(response.stream, tempDir);

    // Remove the existing directory if it exists. This will happen if
    // we're forcing a download to repair the cache.
    if (dirExists(destPath)) deleteEntry(destPath);

    // Now that the get has succeeded, move it to the real location in the
    // cache. This ensures that we don't leave half-busted ghost
    // directories in the user's pub cache if a get fails.
    renameDir(tempDir, destPath);
  }

  /// When an error occurs trying to read something about [package] from [url],
  /// this tries to translate into a more user friendly error message.
  ///
  /// Always throws an error, either the original one or a better one.
  void _throwFriendlyError(error, StackTrace stackTrace, String package,
      String url) {
    if (error is PubHttpException &&
        error.response.statusCode == 404) {
      throw new PackageNotFoundException(
          "Could not find package $package at $url.", error, stackTrace);
    }

    if (error is io.SocketException) {
      fail("Got socket error trying to find package $package at $url.",
           error, stackTrace);
    }

    // Otherwise re-throw the original exception.
    throw error;
  }
}

/// This is the modified hosted source used when pub get or upgrade are run
/// with "--offline".
///
/// This uses the system cache to get the list of available packages and does
/// no network access.
class OfflineHostedSource extends HostedSource {
  /// Gets the list of all versions of [ref] that are in the system cache.
  Future<List<PackageId>> doGetVersions(PackageRef ref) async {
    var parsed = _parseDescription(ref.description);
    var server = parsed.last;
    log.io("Finding versions of ${ref.name} in "
        "$systemCacheRoot/${_urlToDirectory(server)}");

    var dir = path.join(systemCacheRoot, _urlToDirectory(server));

    var versions;
    if (dirExists(dir)) {
      versions = await listDir(dir).map((entry) {
        var components = path.basename(entry).split("-");
        if (components.first != ref.name) return null;
        return HostedSource.idFor(ref.name, new Version.parse(components.last));
      }).where((id) => id != null).toList();
    } else {
      versions = [];
    }

    // If there are no versions in the cache, report a clearer error.
    if (versions.isEmpty) {
      throw new PackageNotFoundException(
          "Could not find package ${ref.name} in cache.");
    }

    return versions;
  }

  Future _download(String server, String package, Version version,
      String destPath) {
    // Since HostedSource is cached, this will only be called for uncached
    // packages.
    throw new UnsupportedError("Cannot download packages when offline.");
  }

  Future<Pubspec> describeUncached(PackageId id) {
    throw new PackageNotFoundException(
        "${id.name} ${id.version} is not available in your system cache.");
  }
}

/// Given a URL, returns a "normalized" string to be used as a directory name
/// for packages downloaded from the server at that URL.
///
/// This normalization strips off the scheme (which is presumed to be HTTP or
/// HTTPS) and *sort of* URL-encodes it. I say "sort of" because it does it
/// incorrectly: it uses the character's *decimal* ASCII value instead of hex.
///
/// This could cause an ambiguity since some characters get encoded as three
/// digits and others two. It's possible for one to be a prefix of the other.
/// In practice, the set of characters that are encoded don't happen to have
/// any collisions, so the encoding is reversible.
///
/// This behavior is a bug, but is being preserved for compatibility.
String _urlToDirectory(String url) {
  // Normalize all loopback URLs to "localhost".
  url = url.replaceAllMapped(new RegExp(r"^https?://(127\.0\.0\.1|\[::1\])?"),
      (match) => match[1] == null ? '' : 'localhost');
  return replace(url, new RegExp(r'[<>:"\\/|?*%]'),
      (match) => '%${match[0].codeUnitAt(0)}');
}

/// Given a directory name in the system cache, returns the URL of the server
/// whose packages it contains.
///
/// See [_urlToDirectory] for details on the mapping. Note that because the
/// directory name does not preserve the scheme, this has to guess at it. It
/// chooses "http" for loopback URLs (mainly to support the pub tests) and
/// "https" for all others.
String _directoryToUrl(String url) {
  // Decode the pseudo-URL-encoded characters.
  var chars = '<>:"\\/|?*%';
  for (var i = 0; i < chars.length; i++) {
    var c = chars.substring(i, i + 1);
    url = url.replaceAll("%${c.codeUnitAt(0)}", c);
  }

  // Figure out the scheme.
  var scheme = "https";

  // See if it's a loopback IP address.
  if (isLoopback(url.replaceAll(new RegExp(":.*"), ""))) scheme = "http";
  return "$scheme://$url";
}

/// Parses [description] into its server and package name components, then
/// converts that to a Uri given [pattern].
///
/// Ensures the package name is properly URL encoded.
Uri _makeUrl(description, String pattern(String server, String package)) {
  var parsed = _parseDescription(description);
  var server = parsed.last;
  var package = Uri.encodeComponent(parsed.first);
  return Uri.parse(pattern(server, package));
}

/// Parses [id] into its server, package name, and version components, then
/// converts that to a Uri given [pattern].
///
/// Ensures the package name is properly URL encoded.
Uri _makeVersionUrl(PackageId id,
    String pattern(String server, String package, String version)) {
  var parsed = _parseDescription(id.description);
  var server = parsed.last;
  var package = Uri.encodeComponent(parsed.first);
  var version = Uri.encodeComponent(id.version.toString());
  return Uri.parse(pattern(server, package, version));
}

/// Parses the description for a package.
///
/// If the package parses correctly, this returns a (name, url) pair. If not,
/// this throws a descriptive FormatException.
Pair<String, String> _parseDescription(description) {
  if (description is String) {
    return new Pair<String, String>(description, HostedSource.defaultUrl);
  }

  if (description is! Map) {
    throw new FormatException(
        "The description must be a package name or map.");
  }

  if (!description.containsKey("name")) {
    throw new FormatException(
    "The description map must contain a 'name' key.");
  }

  var name = description["name"];
  if (name is! String) {
    throw new FormatException("The 'name' key must have a string value.");
  }

  var url = description["url"];
  if (url == null) url = HostedSource.defaultUrl;

  return new Pair<String, String>(name, url);
}
