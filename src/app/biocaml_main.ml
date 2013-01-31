
open Core.Std
open Flow
open Biocaml_app_common

module Bam_conversion = struct

  let err_to_string sexp e = Error (`string (Sexp.to_string_hum (sexp e)))

  let bam_to_sam ?input_buffer_size =
    file_to_file ?input_buffer_size
      Biocaml_transform.(
        on_output
          (compose_results_merge_error
             (compose_results_merge_error
                (Biocaml_bam.Transform.string_to_raw
                   ?zlib_buffer_size:input_buffer_size ())
                (Biocaml_bam.Transform.raw_to_item ()))
             (compose_result_left
                (Biocaml_sam.Transform.item_to_raw ())
                (Biocaml_sam.Transform.raw_to_string ())))
          ~f:(function
          | Ok o -> Ok o
          | Error (`left (`left (`bam e))) ->
            err_to_string Biocaml_bam.Transform.sexp_of_raw_bam_error e
          | Error (`left (`left (`unzip e))) ->
            err_to_string Biocaml_zip.Transform.sexp_of_unzip_error e
          | Error (`left (`right e)) ->
            err_to_string Biocaml_bam.Transform.sexp_of_raw_to_item_error e
          | Error (`right  e) ->
            err_to_string Biocaml_sam.Error.sexp_of_item_to_raw e
          )
      )

  let bam_to_bam ~input_buffer_size ?output_buffer_size =
    file_to_file ~input_buffer_size ?output_buffer_size
      Biocaml_transform.(
        on_output
          (compose_results_merge_error
             (compose_results_merge_error
                (Biocaml_bam.Transform.string_to_raw
                   ~zlib_buffer_size:(10 * input_buffer_size) ())
                (Biocaml_bam.Transform.raw_to_item ()))
             (compose_result_left
                (Biocaml_bam.Transform.item_to_raw ())
                (Biocaml_bam.Transform.raw_to_string
                   ?zlib_buffer_size:output_buffer_size ())))
          ~f:(function
          | Ok o -> Ok o
          | Error (`left (`left (`bam e))) ->
            err_to_string Biocaml_bam.Transform.sexp_of_raw_bam_error e
          | Error (`left (`left (`unzip e))) ->
            err_to_string Biocaml_zip.Transform.sexp_of_unzip_error e
          | Error (`left (`right e)) ->
            err_to_string Biocaml_bam.Transform.sexp_of_raw_to_item_error e
          | Error (`right  e) ->
            err_to_string Biocaml_bam.Transform.sexp_of_item_to_raw_error e
          )
      )
  let cmd_bam_to_sam =
    Command_line.(
      basic ~summary:"convert from BAM to SAM"
        Spec.(
          file_to_file_flags ()
          +> anon ("BAM-FILE" %: string)
          +> anon ("SAM-FILE" %: string)
          ++ uses_lwt ())
        (fun ~input_buffer_size ~output_buffer_size bam sam ->
          bam_to_sam ~input_buffer_size bam ~output_buffer_size sam
          >>< common_error_to_string))

  let cmd_bam_to_bam =
    Command_line.(
      basic ~summary:"convert from BAM to BAM again (after parsing everything)"
        Spec.(
          file_to_file_flags ()
          +> anon ("BAM-FILE" %: string)
          +> anon ("BAM-FILE" %: string)
          ++ uses_lwt ()
        )
        (fun ~input_buffer_size ~output_buffer_size bam bam2 ->
          bam_to_bam ~input_buffer_size bam ~output_buffer_size bam2
          >>< common_error_to_string)
    )


  module With_set = struct
    module E = struct
      type t = O of int | C of int with sexp
      let compare t1 t2 =
        match t1, t2 with
        | O n, O m -> compare n m
        | C n, C m -> compare n m
        | O n, C m when n = m -> -1
        | C n, O m when n = m -> 1
        | O n, C m -> compare n m
        | C n, O m -> compare n m
    end
    module S = Set.Make (E)

    open E
    let create () = ref String.Map.empty
    let add_interval t n b e =
      match Map.find !t n with
      | Some set ->
        set := S.add !set (O b);
        set := S.add !set (C e)
      | None ->
        let set = ref S.empty in
        set := S.add !set (O b);
        set := S.add !set (C e);
        t := Map.add !t n set

    module Bed_set = Set.Make (struct
      type t = string * int * int * float with sexp
      let compare = Pervasives.compare
    end)

    let bed_set t =
      let beds = ref Bed_set.empty in
      Map.iter !t (fun ~key ~data ->
        let c_idx = ref (-1) in
        let c_val = ref 0 in
      (* printf "key: %s data length: %d\n" key (S.length !data); *)
        S.iter !data (function
        | O o ->
        (* printf "O %d -> c_idx: %d c_val: %d\n" o !c_idx !c_val; *)
          if o <> !c_idx then begin
            if !c_val > 0 then
              beds := Bed_set.add !beds (key, !c_idx, o, float !c_val);
            c_idx := o;
          end;
          incr c_val
        | C c ->
        (* printf "C %d -> c_idx: %d c_val: %d\n" c !c_idx !c_val; *)
          if c <> !c_idx then begin
            if !c_val > 0 then
              beds := Bed_set.add !beds (key, !c_idx, c, float !c_val);
            c_idx := c;
          end;
          decr c_val
        ));
      !beds


  end

  let build_wig ?(max_read_bytes=Int.max_value)
      ?(input_buffer_size=42_000) ?(output_buffer_size=42_000) bamfile wigfile =
    let tags =
      match Biocaml_tags.guess_from_filename bamfile with
      | Ok o -> o
      | Error e -> `bam
    in
    begin match tags with
    | `bam ->
      return (
        Biocaml_transform.compose_results
          ~on_error:(function `left l -> l | `right r -> `bam_to_item r)
          (Biocaml_bam.Transform.string_to_raw
             ~zlib_buffer_size:(10 * input_buffer_size) ())
          (Biocaml_bam.Transform.raw_to_item ()))
    | `sam ->
      return (
        Biocaml_transform.compose_results
          ~on_error:(function `left l -> `sam l | `right r -> `sam_to_item r)
          (Biocaml_sam.Transform.string_to_raw ())
          (Biocaml_sam.Transform.raw_to_item ()))
    | `gzip `sam ->
      return (
        Biocaml_transform.compose_results
          ~on_error:(function `left l -> `unzip l | `right r -> r)
          (Biocaml_zip.Transform.unzip
             ~zlib_buffer_size:(10 * input_buffer_size)
             ~format:`gzip ())
          (Biocaml_transform.compose_results
             ~on_error:(function `left l -> `sam l | `right r -> `sam_to_item r)
             (Biocaml_sam.Transform.string_to_raw ())
             (Biocaml_sam.Transform.raw_to_item ())))
    | _ ->
      failf "cannot handle file format"
    end
    >>= fun transfo ->
    let open With_set in
    let tree = create () in
    let transform =
      Biocaml_transform.on_output transfo ~f:(function
      | Ok (`alignment al) ->
        let open Biocaml_sam in
        Option.iter al.position (fun pos ->
          begin match al with
          | { reference_sequence = `reference_sequence rs;
              sequence = `reference; _ } ->
            add_interval tree rs.ref_name pos (pos + rs.ref_length)
          | { reference_sequence = `reference_sequence rs;
              sequence = `string s; _ } ->
            add_interval tree rs.ref_name pos (pos + String.length s)
          | _ -> ()
          end);
        Ok (`alignment al)
      | o -> o)
    in
    go_through_input ~transform ~max_read_bytes ~input_buffer_size bamfile
    >>= fun () ->
    let bed_set = bed_set tree in
    Lwt_io.(
      with_file ~mode:output
        ~buffer_size:output_buffer_size wigfile (fun o ->
          Bed_set.fold bed_set ~init:(return ()) ~f:(fun prev (chr, b, e, f) ->
            prev >>= fun () ->
            wrap_io (fprintf o "%s %d %d %g\n" chr b e) f)
        )
    )

  let cmd_extract_wig =
    Command_line.(
      basic ~summary:"Get the WIG out of a BAM or a SAM (potentially gzipped)"
        Spec.(
          file_to_file_flags ()
          +> flag "stop-after" (optional int)
            ~doc:"<n> Stop after reading <n> bytes"
          +> anon ("SAM-or-BAM-FILE" %: string)
          +> anon ("WIG-FILE" %: string)
          ++ uses_lwt ()
        )
        (fun ~input_buffer_size ~output_buffer_size max_read_bytes input_file wig ->
          build_wig ~input_buffer_size ~output_buffer_size ?max_read_bytes
            input_file wig
          >>< common_error_to_string)
    )

  let command =
    Command_line.(
      group ~summary:"Operations on BAM/SAM files (potentially gzipped)" [
        ("to-sam", cmd_bam_to_sam);
        ("to-bam", cmd_bam_to_bam);
        ("extract-wig", cmd_extract_wig);
      ])

end
module Bed_operations = struct


  let load ~on_output ~input_buffer_size ?(max_read_bytes=Int.max_value) filename =
    let tags =
      match Biocaml_tags.guess_from_filename filename with
      | Ok o -> o
      | Error e -> `bed
    in
    let parsing_transform =
      match tags with
      | `bed ->
        Biocaml_transform.on_output
          (Biocaml_bed.Transform.string_to_t ())
          ~f:(function Ok o -> Ok o | Error e -> Error (`bed e))
      | `gzip `bed ->
        Biocaml_transform.compose_results
          ~on_error:(function `left l -> `unzip l | `right r -> `bed r)
          (Biocaml_zip.Transform.unzip
             ~zlib_buffer_size:(10 * input_buffer_size) ~format:`gzip ())
          (Biocaml_bed.Transform.string_to_t ())
      | _ ->
        (failwith "cannot handle file-format")
    in
    let transform = Biocaml_transform.on_output parsing_transform ~f:on_output in
    go_through_input ~transform ~max_read_bytes ~input_buffer_size filename

  let load_itree () =
    let map = ref String.Map.empty in
    let add n low high content =
      match Map.find !map n with
      | Some tree_ref ->
        tree_ref := Biocaml_interval_tree.add !tree_ref
          ~low ~high ~data:(n, low, high, content);
      | None ->
        let tree_ref = ref Biocaml_interval_tree.empty in
        tree_ref := Biocaml_interval_tree.add !tree_ref
          ~low ~high ~data:(n, low, high, content);
        map := Map.add !map ~key:n ~data:tree_ref
    in
    let on_output = function
      | Ok (n, l, r, content) ->
        add n l r content;
        Ok ()
      | Error e -> Error e
    in
    (map, on_output)

  let load_rset () =
    let map = ref String.Map.empty in
    let add n low high content =
      match Map.find !map n with
      | Some rset_ref ->
        rset_ref := Biocaml_rSet.(union !rset_ref (of_range_list [low, high]))
      | None ->
        let rset = ref Biocaml_rSet.(of_range_list [low, high]) in
        map := Map.add !map ~key:n ~data:rset
    in
    let on_output = function
      | Ok (n, l, r, content) ->
        add n l r content;
        Ok ()
      | Error e -> Error e
    in
    (map, on_output)


  let intersects map name low high =
    match Map.find map name with
    | Some tree_ref ->
      if Biocaml_interval_tree.intersects !tree_ref ~low ~high
      then wrap_io Lwt_io.printf "Yes\n"
      else wrap_io Lwt_io.printf "No\n"
    | None ->
      wrap_io (Lwt_io.printf "Record for %S not found\n") name

  let rset_folding ~fold_operation ~fold_init
      ~input_buffer_size max_read_bytes input_files =
    let all_names = ref String.Set.empty in
    List.fold input_files ~init:(return []) ~f:(fun prev file ->
      prev >>= fun current_list ->
      let map_ref, on_output = load_rset () in
      load ~input_buffer_size ?max_read_bytes ~on_output file
      >>= fun () ->
      all_names := Set.union !all_names
        (String.Set.of_list (Map.keys !map_ref));
      return (!map_ref :: current_list))
    >>= fun files_maps ->
    Set.fold !all_names ~init:(return ()) ~f:(fun munit name ->
      munit >>= fun () ->
      List.filter_map files_maps (fun fm ->
        Map.find fm name |! Option.map ~f:(!))
      |! List.fold ~init:fold_init ~f:fold_operation
      |! Biocaml_rSet.to_range_list
      |! List.fold ~init:(return ()) ~f:(fun m (low, high) ->
        m >>= fun () ->
        wrap_io (Lwt_io.printf "%s\t%d\t%d\n" name low) high))

  let command =
    Command_line.(
      group ~summary:"Operations on BED files (potentially gzipped)" [
        ("intersects",
         basic
           ~summary:"Check if a bed file intersects and given interval"
           Spec.(
             verbosity_flags ()
             ++ input_buffer_size_flag ()
             +> flag "stop-after" (optional int)
               ~doc:"<n> Stop after reading <n> bytes"
             +> anon ("BED-ish-FILE" %: string)
             +> anon ("NAME" %: string)
             +> anon ("START" %: int)
             +> anon ("STOP" %: int)
             ++ uses_lwt ()
           )
           (fun ~input_buffer_size max_read_bytes input_file name start stop ->
             let map_ref, on_output = load_itree () in
             begin
               load ~input_buffer_size ?max_read_bytes ~on_output input_file
               >>= fun () ->
               intersects !map_ref  name start stop
             end
             >>< common_error_to_string));
        ("range-set",
         basic
           ~summary:"Output a non-overlapping set of intervals for a BED input file"
           Spec.(
             verbosity_flags ()
             ++ input_buffer_size_flag ()
             +> flag "stop-after" (optional int)
               ~doc:"<n> Stop after reading <n> bytes"
             +> anon ("BED-ish-FILE" %: string)
             ++ uses_lwt ()
           )
           (fun ~input_buffer_size max_read_bytes input_file ->
             let map_ref, on_output = load_rset () in
             begin
               load ~input_buffer_size ?max_read_bytes ~on_output input_file
               >>= fun () ->
               Map.fold !map_ref ~init:(return ()) ~f:(fun ~key ~data m ->
                 m >>= fun () ->
                 List.fold (Biocaml_rSet.to_range_list !data) ~init:(return ())
                   ~f:(fun m (low, high) ->
                     m >>= fun () ->
                     wrap_io (Lwt_io.printf "%s\t%d\t%d\n" key low) high))
             end
             >>< common_error_to_string));
        ("union",
         basic
           ~summary:"Compute the union of a bunch of BED files"
           Spec.(
             verbosity_flags ()
             ++ input_buffer_size_flag ()
             +> flag "stop-after" (optional int)
               ~doc:"<n> Stop after reading <n> bytes"
             +> anon (sequence ("BED-ish-FILES" %: string))
             ++ uses_lwt ()
           )
           (fun ~input_buffer_size max_read_bytes input_files ->
             rset_folding
               ~fold_operation:Biocaml_rSet.union
               ~fold_init:Biocaml_rSet.empty
               ~input_buffer_size max_read_bytes input_files
             >>< common_error_to_string)
        );
        ("intersection",
         basic
           ~summary:"Compute the intersection of a bunch of BED files"
           Spec.(
             verbosity_flags ()
             ++ input_buffer_size_flag ()
             +> flag "stop-after" (optional int)
               ~doc:"<n> Stop after reading <n> bytes"
             +> anon (sequence ("BED-ish-FILES" %: string))
             ++ uses_lwt ()
           )
           (fun ~input_buffer_size max_read_bytes input_files ->
             rset_folding
               ~fold_operation:Biocaml_rSet.inter
               ~fold_init:(Biocaml_rSet.of_range_list [Int.min_value, Int.max_value])
               ~input_buffer_size max_read_bytes input_files
             >>< common_error_to_string)
        );
      ])

end


module Demultiplexer = struct

  type barcode_specification = {
    barcode: string;
    position: int;
    on_read: int;
    mismatch: int option;
  }
  let barcode_specification ?mismatch ~position ~on_read barcode =
    Blang.base { mismatch; barcode; position; on_read }
  let barcode_specification_of_sexp =
    let open Sexp in
    function
    | Atom all_in_one as sexp ->
      begin match String.split ~on:':' all_in_one with
      | barcode :: on_read_str :: position_str :: rest ->
        let on_read = Int.of_string on_read_str in
        let position = Int.of_string position_str in
        let mismatch =
          match rest with [] -> None | h :: _ -> Some (Int.of_string h) in
        { mismatch; barcode; position; on_read}
        | _ -> of_sexp_error (sprintf "wrong barcode spec") sexp
      end
    | List (Atom barcode :: Atom "on" :: Atom "read" :: Atom on_read_str
            :: Atom "at" :: Atom "position" :: Atom position_str
            :: more_or_not) as sexp ->
      let on_read = Int.of_string on_read_str in
      let position = Int.of_string position_str in
      let mismatch =
        match more_or_not with
        | [ Atom "with"; Atom "mismatch"; Atom mm ] -> Some (Int.of_string mm)
        | [] -> None
        | _ -> of_sexp_error (sprintf "wrong barcode spec") sexp
      in
      { mismatch; barcode; position; on_read}
    | sexp -> of_sexp_error (sprintf "wrong barcode spec") sexp

  let sexp_of_barcode_specification { mismatch; barcode; position; on_read} =
    let open Sexp in
    let more =
      match mismatch with
      | None -> []
      | Some mm -> [ Atom "with"; Atom "mismatch"; Atom (Int.to_string mm) ] in
    List (Atom barcode
          :: Atom "on" :: Atom "read" :: Atom (Int.to_string on_read)
          :: Atom "at" :: Atom "position" :: Atom (Int.to_string position)
          :: more)


  type library = {
    name_prefix: string;
    barcoding: barcode_specification Blang.t;
    (* Disjunctive normal form: or_list (and_list barcode_specs))*)
  }

  let library_of_sexp =
    let open Sexp in
    function
    | List [Atom "library"; Atom name_prefix; sexp] ->
      { name_prefix;
        barcoding = Blang.t_of_sexp barcode_specification_of_sexp  sexp }
    | sexp ->
      of_sexp_error (sprintf "wrong library") sexp

  let sexp_of_library {name_prefix; barcoding} =
    let open Sexp in
    let rest = Blang.sexp_of_t sexp_of_barcode_specification barcoding in
    List [Atom "library"; Atom name_prefix; rest]

  type demux_specification = library list
  let demux_specification_of_sexp =
    let open Sexp in
    function
    | List (Atom "demux" :: rest) ->
      List.map rest library_of_sexp
    | List [] -> []
    | sexp -> of_sexp_error (sprintf "wrong sexp") sexp

  let sexp_of_demux_specification l =
    let open Sexp in
    List (Atom "demux" :: List.map l sexp_of_library)


  let join_pair t1 t2 =
    wrap_io (Lwt_list.map_p ident) [t1; t2]
    >>= begin function
    | [ r1; r2] -> return (r1, r2)
    | _ -> failf "join_pair did not return 2 elements"
    end


  let map_list_parallel_with_index l ~f =
    let c = ref (-1) in
    (* TODO: fix bug: there is no order warranty !! *)
    for_concurrent l ~f:(fun x -> incr c; f !c x)

  let check_barcode ~mismatch ~position ~barcode sequence =
    let allowed_mismatch = ref mismatch in
    let index = ref 0 in
    while !allowed_mismatch >= 0 && !index <= String.length barcode - 1 do
      if sequence.[position - 1 + !index] <> barcode.[!index]
      then decr allowed_mismatch;
      incr index
    done;
    (!allowed_mismatch >= 0, mismatch - !allowed_mismatch)

  let string_of_error e =
    let module M = struct
      type t = [ Biocaml_fastq.Error.t
               | `unzip of Biocaml_zip.Transform.unzip_error ]
      with sexp
    end in
    Sexp.to_string_hum (M.sexp_of_t e)

  type library_statistics = {
    mutable read_count: int;
    mutable no_mismatch_read_count: int;
  }
  let library_statistics () =
    { read_count = 0; no_mismatch_read_count = 0; }

  let perform ~mismatch ?gzip_output ?do_statistics
      ~input_buffer_size ~read_files
      ~output_buffer_size ~demux_specification =

    for_concurrent read_files (fun filename ->
      wrap_io () ~f:(fun () ->
        Lwt_io.(open_file ~mode:input ~buffer_size:input_buffer_size filename))
      >>= fun inp ->
      let transform =
        match Biocaml_tags.guess_from_filename filename with
        | Ok (`gzip `fastq) | _ when String.is_suffix filename ".gz" ->
          Biocaml_transform.compose_results
            ~on_error:(function `left l -> `unzip l | `right r -> r)
            (Biocaml_zip.Transform.unzip
               ~zlib_buffer_size:(3 * input_buffer_size) ~format:`gzip ())
            (Biocaml_fastq.Transform.string_to_item ~filename ())
        | _ ->
          (Biocaml_fastq.Transform.string_to_item ~filename ())
      in
      return (transform, inp))
    >>= fun (transform_inputs, errors) ->

    let close_all_inputs () =
      while_sequential transform_inputs (fun (_, i) ->
        wrap_io Lwt_io.close i)
      >>= fun _ ->
      return ()
    in
    begin match errors with
    | [] -> return ()
    | some ->
      close_all_inputs () >>= fun () ->
      error (`openning_files some)
    end
    >>= fun () ->

    for_concurrent demux_specification (fun {name_prefix; barcoding} ->
      map_list_parallel_with_index read_files (fun i _ ->
        let actual_filename, transform =
          match gzip_output with
          | None ->
            (sprintf "%s_R%d.fastq" name_prefix (i + 1),
             Biocaml_fastq.Transform.item_to_string ())
          | Some level ->
            (sprintf "%s_R%d.fastq.gz" name_prefix (i + 1),
             Biocaml_transform.compose
               (Biocaml_fastq.Transform.item_to_string ())
               (Biocaml_zip.Transform.zip ~format:`gzip ~level
                  ~zlib_buffer_size:output_buffer_size ()))
        in
        wrap_io () ~f:(fun () ->
          Lwt_io.(open_file ~mode:output ~buffer_size:output_buffer_size
                    actual_filename))
        >>= fun o ->
        return (transform, o))
      >>= begin function
      | (outs, []) ->
        return (name_prefix, outs, barcoding,
                Option.map do_statistics (fun _ -> library_statistics ()))
      | (outs, some_errors) ->
        close_all_inputs ()
        >>= fun () ->
        while_sequential outs (fun (_, o) -> wrap_io Lwt_io.close o)
        >>= fun _ ->
        error (`openning_files some_errors)
      end)
    >>= fun (output_specs, errors) ->
    let close_all () =
      close_all_inputs ()
      >>= fun () ->
      while_sequential output_specs (fun (_, outs, _, _) ->
        while_sequential outs (fun (_, o) -> wrap_io Lwt_io.close o))
    in
    let check_errors = function
      | [] -> return ()
      | some -> close_all () >>= fun _ -> error (`io_multi_error some)
    in
    check_errors errors
    >>= fun () ->

    let rec loop () =
      for_concurrent transform_inputs (fun (transform, in_channel) ->
        pull_next ~transform  ~in_channel)
      >>= fun (all_the_nexts, errors) ->
      check_errors errors
      >>= fun () ->
      if List.for_all all_the_nexts ((=) None)
      then return ()
      else begin
        map_list_parallel_with_index all_the_nexts (fun i -> function
        | Some (Ok item) -> return item
        | Some (Error e) ->
          failf "error while parsing read %d: %s" (i + 1) (string_of_error e)
        | None -> failf "read %d is not long enough" (i + 1))
        >>= fun (items, errors) ->
        check_errors errors
        >>= fun () ->
        for_concurrent output_specs (fun (_, outs, spec, stats_opt) ->
          let matches, max_mismatch =
            let default_mismatch = mismatch in
            let max_mismatch = ref 0 in
            let matches =
              Blang.eval spec (fun {on_read; barcode; position; mismatch} ->
                let mismatch =
                  Option.value ~default:default_mismatch mismatch in
                try
                  let item = List.nth_exn items (on_read - 1) in
                  let matches, mm =
                    check_barcode ~position ~barcode ~mismatch
                      item.Biocaml_fastq.sequence in
                  if matches then max_mismatch := max !max_mismatch mm;
                  matches
                with e -> false) in
            matches, !max_mismatch
          in
          if matches then begin
            Option.iter stats_opt (fun s ->
              s.read_count <- s.read_count + 1;
              if max_mismatch = 0 then
                s.no_mismatch_read_count <- s.no_mismatch_read_count + 1;
            );
            List.fold2_exn outs items ~init:(return ())
              ~f:(fun m (transform, out_channel) item ->
                m >>= fun () ->
                push_to_the_max ~transform ~out_channel item)
          end
          else
            return ())
        >>= fun (_, errors) ->
        check_errors errors
        >>= fun () ->
        loop ()
      end
    in
    loop () >>= fun () ->
    begin match do_statistics with
    | Some s ->
      let open Lwt_io in
      wrap_io (open_file ~mode:output ~buffer_size:output_buffer_size) s >>= fun o ->
      wrap_io (fprintf o) ";; library_name read_count 0_mismatch_read_count\n"
      >>= fun () ->
      return (Some o)
    | None -> return None
    end
    >>= fun stats_channel ->
    for_concurrent output_specs (fun (name, os, spec, stats) ->
      for_concurrent os ~f:(fun (transform, out_channel) ->
        Biocaml_transform.stop transform;
        flush_transform ~out_channel ~transform >>= fun () ->
        wrap_io Lwt_io.close out_channel)
      >>= fun (_, errors) ->
      (* TODO: check errors *)
      begin match stats, stats_channel with
      | Some { read_count; no_mismatch_read_count }, Some o ->
        wrap_io () ~f:(fun () ->
          Lwt_io.fprintf o "(%S %d %d)\n" name
            read_count no_mismatch_read_count)
      | _, _ -> return ()
      end
    )
    >>= fun _ ->
    for_concurrent transform_inputs (fun (_, i) -> wrap_io Lwt_io.close i)
    >>= fun (_, errors) ->
    (* TODO: check errors *)
    Option.value_map stats_channel ~default:(return ())
      ~f:(fun c -> wrap_io Lwt_io.close c)

  let parse_configuration s =
    let open Sexp in
    let sexp = ksprintf of_string "(\n%s\n)" s in
    let entries =
      match sexp with List entries -> entries | _ -> assert false in
    let mismatch =
      List.find_map entries (function
      | List [Atom "default-mismatch"; Atom vs] ->
        Some (Int.of_string vs)
      | _ -> None) in
    let undetermined =
      List.find_map entries (function
      | List [Atom "undetermined"; Atom vs] ->
        Some vs
      | _ -> None) in
    let gzip =
      List.find_map entries (function
      | List [Atom "gzip-output"; Atom vs] ->
        Some (Int.of_string vs)
      | _ -> None) in
    let demux =
      List.find_map entries (function
      | List (Atom "demux" :: _) as s ->
        Some (demux_specification_of_sexp s)
      | _ -> None) in
    let stats =
      List.find_map entries (function
      | List [Atom "statistics"; Atom vs] ->
        Some vs
      | _ -> None) in
    let inputs =
      List.find_map entries (function
      | List (Atom "input" :: files) ->
        Some (List.map files (function
        | Atom a -> a
        | s ->
          failwithf "wrong input files specification: %s" (to_string_hum s) ()))
      | _ -> None) in
    (mismatch, gzip, undetermined, stats, demux, inputs)

  let command =
    Command_line.(
      basic ~summary:"Fastq deumltiplexer"
        ~readme:begin fun () ->
          let open Blang in
          let ex v =
            (Sexp.to_string_hum (sexp_of_demux_specification v)) in
          String.concat ~sep:"\n\n" [
            "** Examples of S-Expressions:";
            sprintf "An empty one:\n%s" (ex []);
            sprintf "Two Illumina-style libraries (the index is read n°2):\n%s"
              (ex [
                { name_prefix = "LibONE";
                  barcoding =
                    barcode_specification ~position:1 "ACTGTT"
                      ~mismatch:1 ~on_read:2 };
                { name_prefix = "LibTWO";
                  barcoding =
                    barcode_specification ~position:1 "CTTATG"
                      ~mismatch:1 ~on_read:2 };
              ]);
            sprintf "A library with two barcodes to match:\n%s"
              (ex [
                { name_prefix = "LibAND";
                  barcoding =
                    and_ [
                      barcode_specification ~position:5 "ACTGTT"
                        ~mismatch:1 ~on_read:1;
                      barcode_specification ~position:1 "TTGT"
                        ~on_read:2;
                    ]}
              ]);
            sprintf "A merge of two barcodes into one “library”:\n%s"
              (ex [
                { name_prefix = "LibOR";
                  barcoding = or_ [
                    barcode_specification ~position:5 "ACTGTT"
                      ~mismatch:1 ~on_read:1;
                    barcode_specification ~position:1 "TTGT" ~on_read:2;
                  ] }]);
            begin
              let example =
                "(demux\n\
                \  (library \"Lib with ånnœ¥ing name\" ACCCT:1:2) \
                    ;; one barcode on R1, at pos 2\n\
                \  (library GetALL true) ;; get everything\n\
                \  (library Merge (and AGTT:2:42:1 ACCC:2:42:1 \n\
                \                   (not AGTGGTC:1:1:2)) \
                ;; a ∧ b ∧ ¬c  matching\n\
                ))" in
              let spec =
                Sexp.of_string example |! demux_specification_of_sexp in
              sprintf "This one:\n%s\nis equivalent to:\n%s" example (ex spec)
            end;
          ]
        end
        Spec.(
          file_to_file_flags ()
          +> flag "default-mismatch" (optional int)
            ~doc:"<int> default maximal mismatch allowed (default 0)"
          +> flag "gzip-output" ~aliases:["gz"] (optional int)
            ~doc:"<level> output GZip files (compression level: <level>)"
          +> flag "demux" (optional string)
            ~doc:"<string> give the specification as a list of S-Expressions"
          +> flag "specification" ~aliases:["spec"] (optional string)
            ~doc:"<file> give a path to a file containing the specification"
          +> flag "undetermined" (optional string)
            ~doc:"<name> put all the non-matched reads in a library"
          +> flag "statistics" ~aliases:["stats"] (optional string)
            ~doc:"<file> do some basic statistics and write them to <file>"
          +> anon (sequence ("READ-FILES" %: string))
          ++ uses_lwt ())
        begin fun ~input_buffer_size ~output_buffer_size
          mismatch_cl gzip_cl demux_cl spec undetermined_cl stats_cl
          read_files_cl ->
            begin 
              begin match spec with
              | Some s ->
                wrap_io () ~f:(fun () ->
                  Lwt_io.(with_file ~mode:input s (fun i -> read i)))
                >>| parse_configuration
              | None -> return (None, None, None, None, None, None)
              end
              >>= fun (mismatch, gzip, undetermined, stats, demux, inputs) ->
              begin match read_files_cl, inputs with
              | [], Some l -> return l
              | l, None -> return l
              | l, Some ll ->
                failf "conflict: input files defined in command line \
                     and configuration file"
              end
              >>= fun read_files ->
              let mismatch =
                match mismatch_cl with
                | Some s -> s
                | None -> match mismatch with Some s -> s | None -> 0 in
              let gzip_output = if gzip_cl <> None then gzip_cl else gzip in
              let undetermined =
                if undetermined_cl <> None then undetermined_cl else undetermined
              in
              let do_statistics = if stats_cl <> None then stats_cl else stats in
              let demux_spec_from_cl =
                Option.map demux_cl ~f:(fun s ->
                  Sexp.of_string (sprintf "(demux %s)" s)
                  |! demux_specification_of_sexp) in
              let demux =
                if demux_spec_from_cl <> None then demux_spec_from_cl
                else demux in
              let demux_specification =
                let default = Option.value ~default:[] demux in
                Option.value_map undetermined ~default
                  ~f:(fun name_prefix ->
                    let open Blang in
                    { name_prefix;
                      barcoding =
                        not_ (or_ (List.map default (fun l -> l.barcoding))) }
                    :: default)
              in
              perform ~mismatch ?gzip_output ?do_statistics
                ~input_buffer_size ~read_files ~output_buffer_size
                ~demux_specification
            end
            >>< begin function
            | Ok () -> return ()
            | Error e ->
              let s =
                Sexp.to_string_hum
                  (<:sexp_of<
                      [ `failure of string
                      | `io_exn of exn
                      | `io_multi_error of
                          [ `failure of string
                          | `io_exn of exn
                      | `openning_files of [ `io_exn of exn ] list ] list
                      | `openning_files of [ `io_exn of exn ] list ] >>
                      e)
              in
              error s
            end
        end)



end


let cmd_info =
  Command_line.(
    basic ~summary:"Get information about files"
      Spec.(
        empty +> anon (sequence ("FILES" %: string))
        ++ uses_lwt ()
      )
      (fun files ->
        let f s =
          wrap_io (Lwt_io.printf "File: %S\n") s
          >>= fun () ->
          begin match Biocaml_tags.guess_from_filename s with
          | Ok tags ->
            wrap_io (Lwt_io.printf "  Inferred Tags: %s\n")
              (Biocaml_tags.sexp_of_t tags |! Sexp.to_string_hum)
          | Error e ->
            wrap_io (Lwt_io.printf "  Cannot retrieve tags: %s\n")
              begin match e with
              | `extension_absent -> "no extension"
              | `extension_unknown s -> sprintf "unknown extension: %S" s
              end
          end
        in
        (* List.fold files ~init:(return ()) ~f:(fun m v -> m >>= fun () -> f v)) *)
        begin
          while_sequential ~f files
          >>= fun _ ->
          return ()
        end
        >>< common_error_to_string)
    )


let () =
  Command_line.(
    let whole_thing =
      group ~summary:"Biocaml's command-line application" [
        ("bed", Bed_operations.command);
        ("bam", Bam_conversion.command);
        ("entrez", Biocaml_app_entrez.command);
        ("demux", Demultiplexer.command);
        ("info", cmd_info);
      ] in
    run whole_thing;
    let m =
      List.fold !lwts_to_run ~init:(return ()) ~f:(fun m n ->
        m >>= fun () -> n)
    in

    begin match Lwt_main.run m with
    | Ok () -> ()
    | Error s ->
      eprintf "ERROR: %s\n%!" s
    end
  )

