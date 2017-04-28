open Import
open Jbuild_types

module Dir_with_jbuild = struct
  type t =
    { src_dir : Path.t
    ; ctx_dir : Path.t
    ; stanzas : Stanzas.t
    }
end

type t =
  { context                                 : Context.t
  ; libs                                    : Lib_db.t
  ; stanzas                                 : Dir_with_jbuild.t list
  ; packages                                : Package.t String_map.t
  ; aliases                                 : Alias.Store.t
  ; file_tree                               : File_tree.t
  ; artifacts                               : Artifacts.t
  ; mutable rules                           : Build_interpret.Rule.t list
  ; stanzas_to_consider_for_install         : (Path.t * Stanza.t) list
  ; mutable known_targets_by_src_dir_so_far : String_set.t Path.Map.t
  ; libs_vfile                              : (module Vfile_kind.S with type t = Lib.t list)
  ; cxx_flags                               : string list
  ; vars                                   : string String_map.t
  }

let context t = t.context
let aliases t = t.aliases
let stanzas t = t.stanzas
let packages t = t.packages
let artifacts t = t.artifacts
let file_tree t = t.file_tree
let rules t = t.rules
let stanzas_to_consider_for_install t = t.stanzas_to_consider_for_install
let cxx_flags t = t.cxx_flags

let expand_var_no_root t var = String_map.find var t.vars

let expand_vars t ~dir s =
  String_with_vars.expand s ~f:(function
  | "ROOT" -> Some (Path.reach ~from:dir t.context.build_dir)
  | var -> String_map.find var t.vars)

let create
      ~(context:Context.t)
      ~aliases
      ~dirs_with_dot_opam_files
      ~file_tree
      ~packages
      ~stanzas
      ~filter_out_optional_stanzas_with_missing_deps
  =
  let stanzas =
    List.map stanzas
      ~f:(fun (dir, stanzas) ->
        { Dir_with_jbuild.
          src_dir = dir
        ; ctx_dir = Path.append context.build_dir dir
          ; stanzas
        })
  in
  let internal_libraries =
    List.concat_map stanzas ~f:(fun { ctx_dir;  stanzas; _ } ->
      List.filter_map stanzas ~f:(fun stanza ->
        match (stanza : Stanza.t) with
        | Library lib -> Some (ctx_dir, lib)
        | _ -> None))
  in
  let dirs_with_dot_opam_files =
    Path.Set.elements dirs_with_dot_opam_files
    |> List.map ~f:(Path.append context.build_dir)
    |> Path.Set.of_list
  in
  let libs =
    Lib_db.create context.findlib internal_libraries
      ~dirs_with_dot_opam_files
  in
  let stanzas_to_consider_for_install =
    if filter_out_optional_stanzas_with_missing_deps then
      List.concat_map stanzas ~f:(fun { ctx_dir; stanzas; _ } ->
        List.filter_map stanzas ~f:(function
          | Library _ -> None
          | stanza    -> Some (ctx_dir, stanza)))
      @ List.map
          (Lib_db.internal_libs_without_non_installable_optional_ones libs)
          ~f:(fun (dir, lib) -> (dir, Stanza.Library lib))
    else
      List.concat_map stanzas ~f:(fun { ctx_dir; stanzas; _ } ->
        List.map stanzas ~f:(fun s -> (ctx_dir, s)))
  in
  let module Libs_vfile =
    Vfile_kind.Make_full
      (struct type t = Lib.t list end)
      (struct
        open Sexp.To_sexp
        let t _dir l = list string (List.map l ~f:Lib.best_name)
      end)
      (struct
        open Sexp.Of_sexp
        let t dir sexp =
          List.map (list string sexp) ~f:(Lib_db.find_exn libs ~from:dir)
      end)
  in
  let artifacts =
    Artifacts.create context (List.map stanzas ~f:(fun (d : Dir_with_jbuild.t) ->
      (d.ctx_dir, d.stanzas)))
  in
  let cxx_flags =
    String.extract_blank_separated_words context.ocamlc_cflags
    |> List.filter ~f:(fun s -> not (String.is_prefix s ~prefix:"-std="))
  in
  let vars =
    let ocamlopt =
      match context.ocamlopt with
      | None -> Path.relative context.ocaml_bin "ocamlopt"
      | Some p -> p
    in
    let make =
      match Bin.make with
      | None   -> "make"
      | Some p -> Path.to_string p
    in
    [ "-verbose"       , "" (*"-verbose";*)
    ; "CPP"            , sprintf "%s %s -E" context.c_compiler context.ocamlc_cflags
    ; "PA_CPP"         , sprintf "%s %s -undef -traditional -x c -E" context.c_compiler
                           context.ocamlc_cflags
    ; "CC"             , sprintf "%s %s" context.c_compiler context.ocamlc_cflags
    ; "CXX"            , String.concat ~sep:" " (context.c_compiler :: cxx_flags)
    ; "ocaml_bin"      , Path.to_string context.ocaml_bin
    ; "OCAML"          , Path.to_string context.ocaml
    ; "OCAMLC"         , Path.to_string context.ocamlc
    ; "OCAMLOPT"       , Path.to_string ocamlopt
    ; "ocaml_version"  , context.version
    ; "ocaml_where"    , Path.to_string context.stdlib_dir
    ; "ARCH_SIXTYFOUR" , string_of_bool context.arch_sixtyfour
    ; "MAKE"           , make
    ; "null"           , Path.to_string Config.dev_null
    ]
    |> String_map.of_alist
    |> function
    | Ok x -> x
    | Error _ -> assert false
  in
  { context
  ; libs
  ; stanzas
  ; packages
  ; aliases
  ; file_tree
  ; rules = []
  ; stanzas_to_consider_for_install
  ; known_targets_by_src_dir_so_far = Path.Map.empty
  ; libs_vfile = (module Libs_vfile)
  ; artifacts
  ; cxx_flags
  ; vars
  }

let add_rule t ?sandbox build =
  let rule = Build_interpret.Rule.make ?sandbox build in
  t.rules <- rule :: t.rules;
  t.known_targets_by_src_dir_so_far <-
    List.fold_left rule.targets ~init:t.known_targets_by_src_dir_so_far
      ~f:(fun acc target ->
        match Path.extract_build_context (Build_interpret.Target.path target) with
        | None -> acc
        | Some (_, path) ->
          let dir = Path.parent path in
          let fn = Path.basename path in
          let files =
            match Path.Map.find dir acc with
            | None -> String_set.singleton fn
            | Some set -> String_set.add fn set
          in
          Path.Map.add acc ~key:dir ~data:files)

let sources_and_targets_known_so_far t ~src_path =
  let sources =
    match File_tree.find_dir t.file_tree src_path with
    | None -> String_set.empty
    | Some dir -> File_tree.Dir.files dir
  in
  match Path.Map.find src_path t.known_targets_by_src_dir_so_far with
  | None -> sources
  | Some set -> String_set.union sources set


module Libs = struct
  open Build.O
  open Lib_db

  let find t ~from name = find t.libs ~from name

  let vrequires t ~dir ~item =
    let fn = Path.relative dir (item ^ ".requires.sexp") in
    Build.Vspec.T (fn, t.libs_vfile)

  let load_requires t ~dir ~item =
    Build.vpath (vrequires t ~dir ~item)

  let vruntime_deps t ~dir ~item =
    let fn = Path.relative dir (item ^ ".runtime-deps.sexp") in
    Build.Vspec.T (fn, t.libs_vfile)

  let load_runtime_deps t ~dir ~item =
    Build.vpath (vruntime_deps t ~dir ~item)

  let with_fail ~fail build =
    match fail with
    | None -> build
    | Some f -> Build.fail f >>> build

  let closure t ~dir ~dep_kind lib_deps =
    let internals, externals, fail = Lib_db.interpret_lib_deps t.libs ~dir lib_deps in
    with_fail ~fail
      (Build.record_lib_deps ~dir ~kind:dep_kind lib_deps
       >>>
       Build.all
         (List.map internals ~f:(fun ((dir, lib) : Lib.Internal.t) ->
            load_requires t ~dir ~item:lib.name))
       >>^ (fun internal_deps ->
         let externals =
           Findlib.closure externals
             ~required_by:dir
             ~local_public_libs:(local_public_libs t.libs)
           |> List.map ~f:(fun pkg -> Lib.External pkg)
         in
         Lib.remove_dups_preserve_order
           (List.concat (externals :: internal_deps) @
            List.map internals ~f:(fun x -> Lib.Internal x))))

  let closed_ppx_runtime_deps_of t ~dir ~dep_kind lib_deps =
    let internals, externals, fail = Lib_db.interpret_lib_deps t.libs ~dir lib_deps in
    with_fail ~fail
      (Build.record_lib_deps ~dir ~kind:dep_kind lib_deps
       >>>
       Build.all
         (List.map internals ~f:(fun ((dir, lib) : Lib.Internal.t) ->
            load_runtime_deps t ~dir ~item:lib.name))
       >>^ (fun libs ->
         let externals =
           Findlib.closed_ppx_runtime_deps_of externals
             ~required_by:dir
             ~local_public_libs:(local_public_libs t.libs)
           |> List.map ~f:(fun pkg -> Lib.External pkg)
         in
         Lib.remove_dups_preserve_order (List.concat (externals :: libs))))

  let lib_is_available t ~from name = lib_is_available t.libs ~from name

  let add_select_rules t ~dir lib_deps =
    List.iter (Lib_db.resolve_selects t.libs ~from:dir lib_deps) ~f:(fun { dst_fn; src_fn } ->
      let src = Path.relative dir src_fn in
      let dst = Path.relative dir dst_fn in
      add_rule t
        (Build.path src
         >>>
         Build.action_context_independent ~targets:[dst]
           (Copy_and_add_line_directive (src, dst))))
end

module Deps = struct
  open Build.O
  open Dep_conf

  let dep t ~dir = function
    | File  s -> Build.path (Path.relative dir (expand_vars t ~dir s))
    | Alias s -> Build.path (Alias.file (Alias.make ~dir (expand_vars t ~dir s)))
    | Glob_files s -> begin
        let path = Path.relative dir (expand_vars t ~dir s) in
        let dir = Path.parent path in
        let s = Path.basename path in
        match Glob_lexer.parse_string s with
        | Ok re ->
          Build.paths_glob ~dir (Re.compile re)
        | Error (_pos, msg) ->
          die "invalid glob in %s/jbuild: %s" (Path.to_string dir) msg
      end
    | Files_recursively_in s ->
      let path = Path.relative dir (expand_vars t ~dir s) in
      Build.files_recursively_in ~dir:path ~file_tree:t.file_tree

  let interpret t ~dir l =
    let rec loop acc = function
      | [] -> acc
      | d :: l ->
        loop (acc >>> dep t ~dir d) l
    in
    loop (Build.return ()) l

  let only_plain_file t ~dir = function
    | File s -> Some (Path.relative dir (expand_vars t ~dir s))
    | Alias _ -> None
    | Glob_files _ -> None
    | Files_recursively_in _ -> None

  let only_plain_files t ~dir l = List.map l ~f:(only_plain_file t ~dir)
end

module Action = struct
  open Build.O
  module U = Action.Mini_shexp.Unexpanded

  type resolved_forms =
    { (* Mapping from ${...} forms to their resolutions *)
      artifacts : Action.var_expansion String_map.t
    ; (* Failed resolutions *)
      failures  : fail list
    ; (* All "name" for ${lib:name:...}/${lib-available:name} forms *)
      lib_deps  : Build.lib_deps
    }

  let add_artifact ?lib_dep acc ~var result =
    let lib_deps =
      match lib_dep with
      | None -> acc.lib_deps
      | Some (lib, kind) -> String_map.add acc.lib_deps ~key:lib ~data:kind
    in
    match result with
    | Ok path ->
      { acc with
        artifacts = String_map.add acc.artifacts ~key:var ~data:path
      ; lib_deps
      }
    | Error fail ->
      { acc with
        failures = fail :: acc.failures
      ; lib_deps
      }

  let map_result = function
    | Ok x -> Ok (Action.Path x)
    | Error _ as e -> e

  let extract_artifacts sctx ~dir ~dep_kind t =
    let init =
      { artifacts = String_map.empty
      ; failures  = []
      ; lib_deps  = String_map.empty
      }
    in
    U.fold_vars t ~init ~f:(fun acc var ->
      let module A = Artifacts in
      match String.lsplit2 var ~on:':' with
      | Some ("exe"     , s) -> add_artifact acc ~var (Ok (Path (Path.relative dir s)))
      | Some ("path"    , s) -> add_artifact acc ~var (Ok (Path (Path.relative dir s)))
      | Some ("bin"     , s) ->
        add_artifact acc ~var (A.binary (artifacts sctx) s |> map_result)
      | Some ("lib"     , s)
      | Some ("libexec" , s) ->
        let lib_dep, res = A.file_of_lib (artifacts sctx) ~from:dir s in
        add_artifact acc ~var ~lib_dep:(lib_dep, dep_kind) (map_result res)
      | Some ("lib-available", lib) ->
        add_artifact acc ~var ~lib_dep:(lib, Optional)
          (Ok (Str (string_of_bool (Libs.lib_is_available sctx ~from:dir lib))))
      (* CR-someday jdimino: allow this only for (jbuild_version jane_street) *)
      | Some ("findlib" , s) ->
        let lib_dep, res =
          A.file_of_lib (artifacts sctx) ~from:dir s ~use_provides:true
        in
        add_artifact acc ~var ~lib_dep:(lib_dep, Required) (map_result res)
      | _ -> acc)

  let expand_var =
    let dep_exn name = function
      | Some dep -> dep
      | None -> die "cannot use ${%s} with files_recursively_in" name
    in
    fun sctx ~artifacts ~targets ~deps var_name ->
      match String_map.find var_name artifacts with
      | Some exp -> exp
      | None ->
        match var_name with
        | "@" -> Action.Paths targets
        | "<" -> (match deps with
          | []        -> Str ""
          | dep1 :: _ -> Path (dep_exn var_name dep1))
        | "^" ->
          Paths (List.map deps ~f:(dep_exn var_name))
        | "ROOT" -> Path sctx.context.build_dir
        | var ->
          match expand_var_no_root sctx var with
          | Some s -> Str s
          | None -> Not_found

  let run sctx t ~dir ~dep_kind ~targets ~deps =
    let forms = extract_artifacts sctx ~dir ~dep_kind t in
    let build =
      match
        U.expand sctx.context dir t
          ~f:(expand_var sctx ~artifacts:forms.artifacts ~targets ~deps)
      with
      | t ->
        Build.path_set
          (String_map.fold forms.artifacts ~init:Path.Set.empty
             ~f:(fun ~key:_ ~data:exp acc ->
               match exp with
               | Action.Path p -> Path.Set.add p acc
               | Paths ps -> Path.Set.union acc (Path.Set.of_list ps)
               | Not_found | Str _ -> acc))
        >>>
        Build.action t ~context:sctx.context ~dir ~targets
      | exception e ->
        Build.fail ~targets { fail = fun () -> raise e }
    in
    let build =
      Build.record_lib_deps_simple ~dir forms.lib_deps
      >>>
      build
    in
    match forms.failures with
    | [] -> build
    | fail :: _ -> Build.fail fail >>> build
end