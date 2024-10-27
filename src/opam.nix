args:
let
  inherit (builtins)
    readDir mapAttrs concatStringsSep isString isList attrValues filter head
    foldl' fromJSON listToAttrs readFile toFile isAttrs pathExists toJSON
    deepSeq length sort concatMap attrNames path elem elemAt match;
  bootstrapPackages = args.pkgs;
  inherit (bootstrapPackages) lib;
  inherit (lib)
    splitString tail nameValuePair zipAttrsWith collect concatLists
    filterAttrsRecursive fileContents pipe makeScope optionalAttrs hasSuffix
    converge mapAttrsRecursive composeManyExtensions removeSuffix optionalString
    last init recursiveUpdate foldl optional optionals importJSON mapAttrsToList
    remove findSingle filterAttrs hasInfix warn;

  inherit (import ./evaluator lib)
    compareVersions' getUrl fetchImpure;

  readDirRecursive = dir:
    mapAttrs (name: type:
      if type == "directory" then readDirRecursive "${dir}/${name}" else type)
    (readDir dir);

  # [Pkgset] -> Pkgset
  mergePackageSets = zipAttrsWith (_: foldl' (a: b: a // b) { });

  inherit (bootstrapPackages)
    runCommand linkFarm symlinkJoin opam2json opam;

  # Pkgdef -> Derivation
  builder = import ./builder.nix bootstrapPackages.lib;

  contentAddressedIFD = dir:
    deepSeq (readDir dir) (/. + builtins.unsafeDiscardStringContext dir);

  global-variables =
    import ./global-variables.nix bootstrapPackages.stdenv.hostPlatform;

  defaultEnv = {
    inherit (global-variables) arch os os-family os-distribution;
    sys-ocaml-version = bootstrapPackages.ocaml-ng.ocamlPackages_latest.ocaml.version;
  };
  defaultResolveArgs = {
    env = defaultEnv;
    criteria = "-count[version-lag,request],-count[version-lag,changed],-count[avoid-version,request]";
    depopts = true;
    best-effort = false;
    dev = false;
    with-test = false;
    with-doc = false;
  };

  mergeSortVersions = zipAttrsWith (_: sort (compareVersions' "lt"));

  readFileContents = { files ? bootstrapPackages.emptyDirectory, ... }@def:
    (builtins.removeAttrs def [ "files" ]) // {
      files-contents =
        mapAttrs (name: _: readFile (files + "/${name}")) (readDir files);
    };

  writeFileContents = { name ? "opam", files-contents ? { }, ... }@def:
    (builtins.removeAttrs def [ "files-contents" ])
    // optionalAttrs (files-contents != { }) {
      files = symlinkJoin {
        name = "${name}-files";
        paths =
          (attrValues (mapAttrs bootstrapPackages.writeTextDir files-contents));
      };
    };

  eraseStoreReferences = def:
    (builtins.removeAttrs def [ "repo" "opamFile" "src" ])
    // optionalAttrs (def ? src.url) {
      # Keep srcs which can be fetched
      src = {
        inherit (def.src) url rev subdir;
        hash = def.src.narHash;
      };
    };

  # Note: there can only be one version of the package present in packagedefs we're working on
  injectSources = sourceMap: def:
    if sourceMap ? ${def.name} then
      def // { src = sourceMap.${def.name}; }
    else if def ? src then
      def // 
      {
        src = (builtins.fetchGit ({ inherit (def.src) url rev; }))
          + def.src.subdir;
      }
    else
      def;
  namePathPair = name: path: { inherit name path; };
in rec {

  splitNameVer = nameVer:
    let nv = nameVerToValuePair nameVer;
    in {
      inherit (nv) name;
      version = nv.value;
    };

  nameVerToValuePair = nameVer:
    let split = splitString "." nameVer;
    in nameValuePair (head split) (concatStringsSep "." (tail split));

  # Read 'url' and 'checksum' from a separate file called 'url' if one exists.
  # This supports the older opam repository format where this information was
  # split out into a separate file rather than being part of the main `opam`
  # file.
  legacyUrlFileContents = opamFile:
    let urlPath = "${dirOf opamFile}/url";
    in if pathExists urlPath then
      let
        json = runCommand "url.json" {
          preferLocalBuild = true;
          allowSubstitutes = false;
        } "${opam2json}/bin/opam2json ${urlPath} > $out"; in
        { url = { section = fromJSON (readFile json); }; }
       else {};

  # Path -> {...}
  importOpam = opamFile:
    let
      isStorePath = p: !isNull (match "[0-9a-z]{32}-.*" p);
      dir = baseNameOf (dirOf opamFile);
      basename = baseNameOf opamFile;
      name = if !isStorePath basename && hasSuffix ".opam" basename then
        basename
      else if !isStorePath basename && !isStorePath dir then
        "${dir}.opam"
      else
        "opam";
      json = runCommand "${name}.json" {
        preferLocalBuild = true;
        allowSubstitutes = false;
      } "${opam2json}/bin/opam2json ${opamFile} > $out";
      opamContents = fromJSON (readFile json);

    in if (opamContents ? url) then
      opamContents
       else
         let urlFileContents = legacyUrlFileContents opamFile; in
         opamContents // urlFileContents;

  fromOpam = opamText: importOpam (toFile "opam" opamText);

  # Path -> Derivation
  opam2nix = { src, opamFile ? src + "/${name}.opam", name ? null
    , version ? null, resolveEnv ? { } }:
    builder ({ inherit src name version; } // importOpam opamFile) resolveEnv;

  listRepo = repo:
    optionalAttrs (pathExists (repo + "/packages")) (mergeSortVersions
      (map (p: listToAttrs [ (nameVerToValuePair p) ]) (concatMap attrNames
        (attrValues (readDirRecursive (repo + "/packages"))))));

  opamListToQuery = list: listToAttrs (map nameVerToValuePair list);

  opamList = repo: resolveArgs: packages:
    let
      pkgRequest = name: version:
        if version == "*" then
          name
        else if isNull version then
          (warn ''
            [opam-nix] Using `null' as a version in a query is deprecated, because it is unintuitive to the user. Use `"*"' instead.''
            name)
        else
          "${name}.${version}";

      toString' = x: if isString x then x else toJSON x;

      args = recursiveUpdate defaultResolveArgs resolveArgs;

      environment = concatStringsSep "," (attrValues
        (mapAttrs (name: value: "${name}=${toString' value}") args.env));

      query = concatStringsSep "," (attrValues (mapAttrs pkgRequest packages));

      resolve-drv = with args;
        runCommand "resolve" {
          nativeBuildInputs = [ opam bootstrapPackages.ocaml ];
          OPAMCLI = "2.0";
        } ''
          export OPAMROOT=$NIX_BUILD_TOP/opam

          cd ${repo}
          opam admin list \
            --resolve=${query} \
            --short \
            --columns=package \
            ${optionalString depopts "--depopts"} \
            ${optionalString dev "--dev"} \
            ${optionalString with-test "--with-test"} \
            ${optionalString with-doc "--doc"} \
            ${optionalString best-effort "--best-effort"} \
            ${optionalString (!isNull env) "--environment '${environment}'"} \
            ${optionalString (!isNull criteria) "--criteria='${criteria}'"} \
            | tee $out
        '';
      solution = fileContents resolve-drv;

      lines = s: splitString "\n" s;

    in lines solution;

  makeOpamRepo' = recursive: dir:
    let
      contents = readDir dir;
      files = if recursive then
        readDirRecursive dir
      else
        (contents // optionalAttrs (contents.opam or null == "directory") {
          opam = readDir "${dir}/opam";
        });
      opamFiles = filterAttrsRecursive
        (name: value: isAttrs value || hasSuffix "opam" name) files;
      opamFilesOnly =
        converge (filterAttrsRecursive (_: v: v != { })) opamFiles;
      packages = concatLists (collect isList (mapAttrsRecursive
        (path': _: [rec {
          fileName = last path';
          dirName =
            splitNameVer (if init path' != [ ] then last (init path') else "");
          parsedOPAM = importOpam opamFile;
          name = parsedOPAM.name or (if hasSuffix ".opam" fileName then
            removeSuffix ".opam" fileName
          else
            dirName.name);

          version = parsedOPAM.version or (if dirName.version != "" then
            dirName.version
          else
            "dev");
          subdir = "/" + concatStringsSep "/" (let i = init path';
          in if length i > 0 && last i == "opam" then init i else i);
          source = dir + subdir;
          opamFile = "${dir + ("/" + (concatStringsSep "/" path'))}";
          opamFileContents = readFile opamFile;
        }]) opamFilesOnly));
      repo-description =
        namePathPair "repo" (toFile "repo" ''opam-version: "2.0"'');
      opamFileLinks = map ({ name, version, opamFile, ... }:
        namePathPair "packages/${name}/${name}.${version}/opam" opamFile)
        packages;
      pkgdefs = foldl (acc: x:
        recursiveUpdate acc { ${x.name} = { ${x.version} = x.parsedOPAM; }; })
        { } packages;
      sourceMap = foldl (acc: x:
        recursiveUpdate acc {
          ${x.name} = {
            ${x.version} = (optionalAttrs (builtins.isAttrs dir) dir) // {
              inherit (x) subdir;
              outPath = contentAddressedIFD x.source;
            };
          };
        }) { } packages;
      repo = linkFarm "opam-repo" ([ repo-description ] ++ opamFileLinks);
    in repo // { passthru = { inherit sourceMap pkgdefs; }; };

  makeOpamRepo = makeOpamRepo' false;
  makeOpamRepoRec = makeOpamRepo' true;

  filterOpamRepo = packages: repo:
    linkFarm "opam-repo" ([ (namePathPair "repo" "${repo}/repo") ] ++ attrValues
      (mapAttrs (name: version:
        let
          defaultPath = "${repo}/packages/${name}/${
              head (attrNames (readDir "${repo}/packages/${name}"))
            }";
        in if version == "*" || isNull version then
          namePathPair "packages/${name}/${name}.dev" defaultPath
        else
          namePathPair "packages/${name}/${name}.${version}"
          (let path = "${repo}/packages/${name}/${name}.${version}";
          in if builtins.pathExists path then path else defaultPath)) packages))
    // optionalAttrs (repo ? passthru) {
      passthru = let
        pickRelevantVersions = from:
          mapAttrs (name: version: {
            ${if version == "*" || isNull version then "dev" else version} =
              if version == "*" || isNull version then
                head (attrValues from.${name})
              else
                from.${name}.${version} or (head (attrValues from.${name}));
          }) packages;
      in repo.passthru // mapAttrs (_: pickRelevantVersions) {
        inherit (repo.passthru) sourceMap pkgdefs;
      };

    };

  queryToDefs = repos: packages:
    let
      findPackage = name: version:
        let
          pkgDir = repo: repo + "/packages/${name}/${name}.${version}";
          filesPath = contentAddressedIFD (pkgDir repo + "/files");
          repos' = filter (repo:
            repo ? passthru.pkgdefs.${name}.${version}
            || pathExists (pkgDir repo)) repos;
          repo = if length repos' > 0 then
            head repos'
          else
            throw "Could not find package ${name}.${version}";
          isLocal = repo ? passthru.sourceMap;
        in {
          opamFile = pkgDir repo + "/opam";
          inherit name version isLocal repo;
        } // optionalAttrs (pathExists (pkgDir repo + "/files")) {
          files = filesPath;
        } // optionalAttrs isLocal {
          src = repo.passthru.sourceMap.${name}.${version};
          pkgdef = repo.passthru.pkgdefs.${name}.${version};
        };

      packageFiles = mapAttrs findPackage packages;
    in mapAttrs (_:
      { opamFile, name, version, ... }@args:
      (builtins.removeAttrs args [ "pkgdef" ])
      // args.pkgdef or (importOpam opamFile)) packageFiles;

  callPackageWith = autoArgs: fn: args:
    let
      f = if lib.isAttrs fn then
        fn
      else if lib.isFunction fn then
        fn
      else
        import fn;
      auto =
        builtins.intersectAttrs (f.__functionArgs or (builtins.functionArgs f))
        autoArgs;
    in lib.makeOverridable f (auto // args);

  defsToScope = pkgs: resolveEnv: defs:
    makeScope callPackageWith (self:
      (mapAttrs (name: pkg: self.callPackage (builder pkg resolveEnv) { }) defs)
      // {
        nixpkgs = pkgs.extend (_: _: { inherit opam2json; });
      });

  defaultOverlay = import ./overlays/ocaml.nix;
  staticOverlay = import ./overlays/ocaml-static.nix;
  darwinOverlay = import ./overlays/ocaml-darwin.nix;
  opamRepository = args.opam-repository;
  opamOverlays = args.opam-overlays;
  mirageOpamOverlays = args.mirage-opam-overlays;

  __overlays = [
    (final: prev:
      defaultOverlay final prev
      // optionalAttrs prev.nixpkgs.stdenv.hostPlatform.isStatic
      (staticOverlay final prev)
      // optionalAttrs prev.nixpkgs.stdenv.hostPlatform.isDarwin
      (darwinOverlay final prev))
  ];

  applyOverlays = overlays: scope:
    scope.overrideScope' (composeManyExtensions overlays);

  applyChecksDocs = { with-test ? defaultResolveArgs.with-test
    , with-doc ? defaultResolveArgs.with-doc, ... }:
    query: scope:
    scope.overrideScope' (_: prev:
      mapAttrs (name: _:
        prev.${name}.overrideAttrs (_: {
          doCheck = with-test;
          doDoc = with-doc;
        })) query);

  joinRepos = repos:
    if length repos == 0 then
      runCommand "empty-repo" { } "mkdir -p $out/packages"
    else if length repos == 1 then
      head repos
    else
      symlinkJoin {
        name = "opam-repo";
        paths = repos;
      };

  materialize =
    { repos ? [ opamRepository ], resolveArgs ? { }, regenCommand ? null }:
    query:
    pipe query [
      (opamList (joinRepos repos) resolveArgs)
      (opamListToQuery)
      (queryToDefs repos)

      (mapAttrs (_: eraseStoreReferences))
      (mapAttrs (_: readFileContents))
      (d: d // { __opam_nix_regen = regenCommand; })
      (d: d // { __opam_nix_env = resolveArgs.env or { }; })
      (toJSON)
      (toFile "package-defs.json")
    ];

  materializeOpamProject = { repos ? [ opamRepository ], resolveArgs ? { }
    , regenCommand ? null, pinDepends ? true, recursive ? false }:
    name: project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps =
        getPinDepends repo.passthru.pkgdefs.${name}.${latestVersions.${name}} project;
    in materialize {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      resolveArgs = { dev = true; } // resolveArgs;
      inherit regenCommand;
    } ({ ${name} = latestVersions.${name}; } // query);

  materializeOpamProject' = { repos ? [ opamRepository ], resolveArgs ? { }
    , regenCommand ? null, pinDepends ? true, recursive ? false }:
    project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps = concatLists (attrValues (mapAttrs
        (name: version: getPinDepends repo.passthru.pkgdefs.${name}.${version} project)
        latestVersions));
    in materialize {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      resolveArgs = { dev = true; } // resolveArgs;
      inherit regenCommand;
    } (latestVersions // query);

  materializedDefsToScope =
    { pkgs ? bootstrapPackages, sourceMap ? { }, overlays ? __overlays }:
    file:
    let
      defs = pipe file [
        (readFile)
        (fromJSON)
        (d: removeAttrs d [ "__opam_nix_regen" ])
      ];
      env = defs.__opam_nix_env or (warn
        "[opam-nix] Your package-defs.json file is missing __opam_nix_env. Please, re-generate it."
        { });
    in pipe defs [
      (d: removeAttrs d [ "__opam_nix_env" ])
      (mapAttrs (_: writeFileContents))
      (mapAttrs (_: injectSources sourceMap))

      (defsToScope pkgs env)
      (applyOverlays overlays)
    ];

  queryToScope = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , overlays ? __overlays, resolveArgs ? { } }:
    query:
    pipe query [
      (opamList (joinRepos repos) resolveArgs)
      (opamListToQuery)
      (queryToDefs repos)
      (defsToScope pkgs resolveArgs.env or { })
      (applyOverlays overlays)
      (applyChecksDocs resolveArgs query)
    ];

  opamImport = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , resolveArgs ? { }, overlays ? __overlays }:
    export:
    let installedList = (importOpam export).installed;
    in pipe installedList [
      opamListToQuery
      (queryToDefs repos)
      (defsToScope pkgs resolveArgs.env or { })
      (applyOverlays overlays)
      (applyChecksDocs resolveArgs (opamListToQuery installedList))
    ];

  getPinDepends = pkgdef: project:
    if pkgdef ? pin-depends then
      map (dep:
        let
          inherit (splitNameVer (head dep)) name version;
        in
        let src =
          builtins.addErrorContext "while fetching the pin depend ${name} of ${builtins.toJSON pkgdef}" (fetchImpure (last dep) project);
        in
          (filterOpamRepo { ${name} = version; } (makeOpamRepo src))) pkgdef.pin-depends
    else
      [ ];

  buildOpamProject = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , overlays ? __overlays, resolveArgs ? { }, pinDepends ? true
    , recursive ? false }@args:
    name: project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps =
        getPinDepends repo.passthru.pkgdefs.${name}.${latestVersions.${name}} project;
    in queryToScope {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      overlays = overlays;
      resolveArgs = { dev = true; } // resolveArgs;
      inherit pkgs;
    } ({ ${name} = latestVersions.${name}; } // query);

  buildOpamProject' = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , overlays ? __overlays, resolveArgs ? { }, pinDepends ? true
    , recursive ? false }@args:
    project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps = concatLists (attrValues (mapAttrs
        (name: version: getPinDepends repo.passthru.pkgdefs.${name}.${version} project)
        latestVersions));
    in queryToScope {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      overlays = overlays;
      resolveArgs = { dev = true; } // resolveArgs;
      inherit pkgs;
    } (latestVersions // query);

  buildDuneProject =
    { pkgs ? bootstrapPackages, dune ? pkgs.pkgsBuildBuild.dune_3, ... }@args:
    name: project: query:
    let
      generatedOpamFile = pkgs.pkgsBuildBuild.stdenv.mkDerivation {
        name = "${name}.opam";
        src = project;
        nativeBuildInputs = [ dune pkgs.pkgsBuildBuild.ocaml ];
        phases = [ "unpackPhase" "buildPhase" "installPhase" ];
        buildPhase = "dune build ${name}.opam";
        installPhase = ''
          rm _build -rf
          cp -R . $out
        '';
      };
    in buildOpamProject args name generatedOpamFile query;

  # takes an atribute set of package definitions (as produced by `queryToDefs`),
  # deduplicates sources, and provides a list of sources to fetch
  defsToSrcs = filterPkgs: defs:
    let
      # use our own version of lib.strings.nameFromURL without `assert name != filename`
      nameFromURL = url: sep:
        let
          components = splitString "/" url;
          filename = last components;
          name = head (splitString sep filename);
        in name;
      defToSrc = { version, ... }@pkgdef:
        let
          inherit (getUrl bootstrapPackages pkgdef) src;
          name = let
            n = nameFromURL pkgdef.dev-repo ".";
            # rename dune so it doesn't clash with dune file in duniverse
          in if n == "dune" then "_dune" else n;
          # filter out pkgs without dev-repos
        in if pkgdef ? dev-repo then { inherit name version src; } else { };
      # remove filterPkgs
      filteredDefs = removeAttrs defs filterPkgs;
      srcs = mapAttrsToList (pkgName: def: defToSrc def) filteredDefs;
      # remove empty elements from pkgs without dev-repos
      cleanedSrcs = remove { } srcs;
    in cleanedSrcs;

  deduplicateSrcs = srcs:
    # This is O(n^2). We could try and improve this by sorting the list on name. But n is small.
    let
      op = srcs: newSrc:
        # Find if two packages come from the same dev-repo.
        # Note we are assuming no dev-repos will have different names here, but we also assume
        # this later when we will symlink in the duniverse directory based on this name.
        let
          duplicateSrc =
            findSingle (src: src.name == newSrc.name) null "multiple" srcs;
          # Multiple duplicates should never be found as we deduplicate on every new element.
        in assert duplicateSrc != "multiple";
        if duplicateSrc == null then
          srcs ++ [
            newSrc
          ]
          # > If packages from the same repo were resolved to different URLs, we need to pick
          # > a single one. Here we decided to go with the one associated with the package
          # > that has the higher version. We need a better long term solution as this won't
          # > play nicely with pins for instance.
          # > The best solution here would be to use source trimming, so we can pull each individual
          # > package to its own directory and strip out all the unrelated source code but we would
          # > need dune to provide that feature.
          # See [opam-monorepo](https://github.com/tarides/opam-monorepo/blob/9262e7f71d749520b7e046fbd90a4732a43866e9/lib/duniverse.ml#L143-L157)
        else if duplicateSrc.version >= newSrc.version then
          srcs
        else
          (remove duplicateSrc srcs) ++ [ newSrc ];
    in foldl' op [ ] srcs;

  mkMonorepo = srcs:
    let
      # derivation that fetches the source
      mkSrc = { name, version, src }:
        bootstrapPackages.pkgsBuildBuild.stdenv.mkDerivation ({
          inherit name version src;
          phases = [ "unpackPhase" "installPhase" ];
          installPhase = ''
            mkdir $out
            cp -R . $out
          '';
        });
    in listToAttrs (map (src: nameValuePair src.name (mkSrc src)) srcs);

  queryToMonorepo = { repos ? [ mirageOpamOverlays opamOverlays opamRepository ]
    , resolveArgs ? { }, filterPkgs ? [ ] }:
    query:
    pipe query [
      # pass monorepo = 1 to pick up dependencies marked with {?monorepo}
      # TODO use opam monorepo solver to filter non-dune dependant packages
      (opamList (joinRepos repos)
        (recursiveUpdate resolveArgs { env.monorepo = 1; }))
      opamListToQuery
      (queryToDefs repos)
      (defsToSrcs filterPkgs)
      deduplicateSrcs
      mkMonorepo
    ];

  buildOpamMonorepo =
    { repos ? [ mirageOpamOverlays opamOverlays opamRepository ]
    , resolveArgs ? { }, pinDepends ? true, recursive ? false
    , extraFilterPkgs ? [ ] }@args:
    project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps = concatLists (attrValues (mapAttrs
        (name: version: getPinDepends repo.passthru.pkgdefs.${name}.${version} project)
        latestVersions));
    in queryToMonorepo {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      filterPkgs = [ "ocaml-system" "opam-monorepo" ] ++
        # filter all queried packages, and packages with sources
        # in the project, from the monorepo
        (attrNames latestVersions) ++ extraFilterPkgs;
      resolveArgs = { dev = true; } // resolveArgs;
    } (latestVersions // query);
}
