open Bos_setup
open Dune_release

let get_pkg_dir pkg =
  Pkg.build_dir pkg >>= fun bdir ->
  Pkg.distrib_filename ~opam:true pkg >>= fun fname -> Ok Fpath.(bdir // fname)

let pp_opam_repo fmt opam_repo =
  let user, repo = opam_repo in
  Format.fprintf fmt "%s/%s" user repo

module D = struct
  let fetch_head = "${fetch_head}"
end

let update_opam_file ~dry_run ~url pkg =
  get_pkg_dir pkg >>= fun dir ->
  Pkg.opam pkg >>= fun opam_f ->
  OS.Dir.create dir >>= fun _ ->
  let dest_opam_file = Fpath.(dir / "opam") in
  let url = OpamUrl.parse url in
  Pkg.distrib_file ~dry_run pkg >>= fun distrib_file ->
  let file = Fpath.to_string distrib_file in
  let hash algo = OpamHash.compute ~kind:algo file in
  let checksum = List.map hash [ `SHA256; `SHA512 ] in
  let url = OpamFile.URL.create ~checksum url in
  OS.File.read opam_f >>= fun opam ->
  let opam_t = OpamFile.OPAM.read_from_string opam in
  ( match OpamVersion.to_string (OpamFile.OPAM.opam_version opam_t) with
  | "2.0" ->
      let file x = OpamFile.make (OpamFilename.of_string (Fpath.to_string x)) in
      let opam_t = OpamFile.OPAM.with_url url opam_t in
      if not dry_run then
        OpamFile.OPAM.write_with_preserved_format ~format_from:(file opam_f)
          (file dest_opam_file) opam_t;
      Ok ()
  | ("1.0" | "1.1" | "1.2") as v ->
      App_log.status (fun l ->
          l "Upgrading opam file %a from opam format %s to 2.0" Text.Pp.path
            opam_f v);
      let opam =
        OpamFile.OPAM.with_url url opam_t |> OpamFile.OPAM.write_to_string
      in
      Sos.write_file ~dry_run dest_opam_file opam
  | s -> Fmt.kstrf (fun x -> Error (`Msg x)) "invalid opam version: %s" s )
  >>| fun () ->
  App_log.success (fun m ->
      m "Wrote opam package description %a" Text.Pp.path dest_opam_file)

let undraft ?opam ~name ?distrib_uri ?distrib_file ?opam_repo ?user ?token
    ?local_repo ?remote_repo ?build_dir ?pkg_names ~dry_run ~yes:_ () =
  let pkg = Pkg.v ?name ?opam ?distrib_file ?build_dir ~dry_run:false () in
  Pkg.name pkg >>= fun pkg_name ->
  Pkg.build_dir pkg >>= fun build_dir ->
  Pkg.version pkg >>= fun version ->
  let pkg_names = match pkg_names with Some x -> x | None -> [] in
  let pkg_names = pkg_name :: pkg_names in
  let opam_repo =
    match opam_repo with None -> ("ocaml", "opam-repository") | Some r -> r
  in
  Config.v ~user ~local_repo ~remote_repo [ pkg ] >>= fun config ->
  ( match local_repo with
  | Some r -> Ok Fpath.(v r)
  | None -> (
      match config.local with
      | Some r -> Ok r
      | None -> R.error_msg "Unknown local repository." ) )
  >>= fun local_repo ->
  ( match remote_repo with
  | Some r -> Ok r
  | None -> (
      match config.remote with
      | Some r -> Ok r
      | None -> R.error_msg "Unknown remote repository." ) )
  >>= fun remote_repo ->
  ( match distrib_uri with
  | Some uri -> Ok uri
  | None -> Pkg.infer_distrib_uri pkg )
  >>= Pkg.distrib_user_and_repo
  >>= fun (distrib_user, repo) ->
  let user =
    match config.user with
    | Some user -> user (* from the .yaml configuration file *)
    | None -> (
        match Github.Parse.user_from_remote remote_repo with
        | Some user -> user (* trying to infer it from the remote repo URI *)
        | None -> distrib_user )
  in
  (match token with Some t -> Ok t | None -> Config.token ~dry_run ())
  >>= fun token ->
  App_log.status (fun l -> l "Undrafting release");
  Config.Draft_release.get ~dry_run ~build_dir ~name:pkg_name ~version
  >>= fun release_id ->
  Github.undraft_release ~token ~dry_run ~user ~repo ~release_id >>= fun url ->
  App_log.success (fun m ->
      m "The release has been undrafted and is available at %s\n" url);
  App_log.status (fun l -> l "Undrafting pull request");
  Config.Draft_pr.get ~dry_run ~build_dir ~name:pkg_name ~version
  >>= fun pr_id ->
  update_opam_file ~dry_run ~url pkg >>= fun () ->
  App_log.status (fun l ->
      l "Preparing pull request to %a" pp_opam_repo opam_repo);
  let branch = Fmt.strf "release-%s-%s" pkg_name version in
  Sos.with_dir ~dry_run local_repo
    (fun () ->
      let upstream =
        let user, repo = opam_repo in
        Printf.sprintf "https://github.com/%s/%s.git" user repo
      in
      let remote_branch = "master" in
      Vcs.get () >>= fun vcs ->
      App_log.status (fun l ->
          l "Fetching %a" Text.Pp.url (upstream ^ "#" ^ remote_branch));
      Vcs.run_git_quiet vcs ~dry_run ~force:true
        Cmd.(v "fetch" % upstream % remote_branch)
      >>= fun () ->
      Vcs.run_git_string vcs ~dry_run ~force:true
        ~default:(Sos.out D.fetch_head)
        Cmd.(v "rev-parse" % "FETCH_HEAD")
      >>= fun id ->
      Vcs.checkout vcs ~dry_run:false ~branch ~commit_ish:id >>= fun () ->
      let prepare_package name =
        let dir = name ^ "." ^ version in
        let dst = Fpath.(v "packages" / name / dir) in
        Vcs.run_git_quiet vcs ~dry_run ~force:true Cmd.(v "add" % p dst)
      in
      let rec prepare_packages = function
        | [] -> Ok ()
        | h :: t -> prepare_package h >>= fun () -> prepare_packages t
      in
      prepare_packages pkg_names >>= fun () ->
      let msg = "Undraft pull-request" in
      Vcs.run_git_quiet vcs ~dry_run Cmd.(v "commit" % "-m" % msg) >>= fun () ->
      App_log.status (fun l ->
          l "Pushing %a to %a" Text.Pp.commit branch Text.Pp.url remote_repo);
      Vcs.run_git_quiet vcs ~dry_run
        Cmd.(v "push" % "--force" % remote_repo % branch))
    ()
  |> R.join
  >>= fun () ->
  Github.undraft_pr ~token ~dry_run ~distrib_user ~opam_repo ~pr_id
  >>= fun url ->
  Config.Draft_release.unset ~dry_run ~build_dir ~name:pkg_name ~version
  >>= fun () ->
  Config.Draft_pr.unset ~dry_run ~build_dir ~name:pkg_name ~version
  >>= fun () ->
  App_log.success (fun m -> m "The pull-request has been undrafted at %s\n" url);
  Ok 0

let undraft_cli () (`Dist_name name) (`Dist_uri distrib_uri) (`Dist_opam opam)
    (`Dist_file distrib_file) (`Opam_repo opam_repo) (`User user) (`Token token)
    (`Local_repo local_repo) (`Remote_repo remote_repo) (`Build_dir build_dir)
    (`Package_names pkg_names) (`Dry_run dry_run) (`Yes yes) =
  undraft ?opam ~name ?distrib_uri ?distrib_file ?opam_repo ?user ?token
    ?local_repo ?remote_repo ?build_dir ~pkg_names ~dry_run ~yes ()
  |> Cli.handle_error

(* Command line interface *)

open Cmdliner

let doc = "Publish package distribution archives and derived artefacts"

let sdocs = Manpage.s_common_options

let exits = Cli.exits

let envs =
  [
    Term.env_info "DUNE_RELEASE_DELEGATE"
      ~doc:"The package delegate to use, see dune-release-delegate(7).";
  ]

let man_xrefs = [ `Main; `Cmd "publish"; `Cmd "opam" ]

let man =
  [
    `S Manpage.s_synopsis;
    `P "$(mname) $(tname) [$(i,OPTION)]... [$(i,ARTEFACT)]...";
    `S Manpage.s_description;
    `P
      "The $(tname) command undrafts the released asset, updates the \
       opam-repository pull request and undrafts it.";
    `P
      "Undrafting a released asset always relies on a release having been \
       published before with dune-release-publish(1).";
    `P
      "Undrafting a pull request always relies on a pull request having been \
       opened before with dune-release-opam(2).";
  ]

let cmd =
  ( Term.(
      pure undraft_cli $ Cli.setup $ Cli.dist_name $ Cli.dist_uri
      $ Cli.dist_opam $ Cli.dist_file $ Cli.opam_repo $ Cli.user $ Cli.token
      $ Cli.local_repo $ Cli.remote_repo $ Cli.build_dir $ Cli.pkg_names
      $ Cli.dry_run $ Cli.yes),
    Term.info "undraft" ~doc ~sdocs ~exits ~envs ~man ~man_xrefs )
