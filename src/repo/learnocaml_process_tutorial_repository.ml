(* This file is part of Learn-OCaml.
 *
 * Copyright (C) 2016 OCamlPro.
 *
 * Learn-OCaml is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Learn-OCaml is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *)


open Learnocaml_index

open Lwt.Infix

let parse_code_notation code =
  let len = String.length code in
  if String.contains code '\n' then
    let len = String.length code in
    let lines_margin lines =
      let rec line_margin start prev line =
        if start >= String.length line then start
        else if start >= prev then prev
        else match String.get line start with
          | ' ' | '\t' -> line_margin (start + 1) prev line
          | _ -> start in
      List.fold_left (line_margin 0) len lines in
    let trailing_whitespace margin line =
      let rec loop i =
        if i < margin then i
        else match String.get line i with
          | ' ' | '\t' -> loop (i - 1)
          | _ -> i in
      let last = max (margin - 1) (String.length line - 1) in
      last - loop last in
    let cut_margin margin lines =
      let rec cut acc = function
        | [] -> List.rev acc
        | line :: lines ->
            let len = String.length line
                      - margin
                      - trailing_whitespace margin line in
            cut (String.sub line margin len :: acc) lines
      in cut [] lines in
    let drop_padding_lines lines =
      let rec drop_start = function
        | [] -> []
        | line :: rest ->
            let len = String.length line in
            let rec empty i =
              if i >= len then true
              else match String.get line i with
                | ' ' | '\t' -> empty (i + 1)
                | _ -> false in
            if empty 0 then drop_start rest else line :: rest in
      lines |> drop_start |> List.rev |> drop_start |> List.rev in
    let lines = Stringext.split code ~on: '\n' in
    let lines = drop_padding_lines lines in
    let margin = lines_margin lines in
    let lines = cut_margin margin lines in
    let left_line lines =
      List.fold_left
        (fun acc line ->
           if String.length line = 0 then
             `None
           else
             match acc, String.get line 0 with
             | `Init, c -> `Some c
             | `Some c', c when c = c' -> `Some c
             | _ -> `None) `Init lines |> function
      | `Init | `None -> None
      | `Some char -> Some char in
    match left_line lines with
    | Some ('$' | '|' as c) ->
        let cut_first_char line =
          String.sub line 1 (String.length line - 1) in
        let lines = List.map cut_first_char lines in
        let lines = drop_padding_lines lines in
        let margin = lines_margin lines in
        let lines = cut_margin margin lines in
        let code = String.concat "\n" lines in
        begin match c with
        | '|' -> Code { code ; runnable = true }
        | '$' -> Math code
        | _ -> assert false end
    | None | Some _ ->
        let code = String.concat "\n" lines in
        Code { code ; runnable = false }
  else if len > 2
       && (String.get code 0 = String.get code (len - 1))
       && (String.get code 0 <> String.get code 1) then
    match String.get code 0 with
    | '|' ->
        let code = String.trim (String.sub code 1 (len - 2)) in
        Code { code ; runnable = true }
    | '$' ->
        let code = String.trim (String.sub code 1 (len - 2)) in
        Math code
    | _ -> Code { code ; runnable = false }
  else
    Code { code ; runnable = false }

let parse_html_tutorial tutorial_name filename =
  let fail fmt =
    Format.kasprintf
      (fun res -> Lwt.fail_with (Format.sprintf "in file %s, %s" filename res))
      fmt in
  Lwt_io.(with_file ~mode: Input) filename @@ fun chan ->
  Lwt_io.read chan >>= fun contents ->
  let tree =
    let open Markup in
    string contents |> parse_html |> signals |> tree
      ~text: (fun text -> `Text (String.concat "" text))
      ~element: (fun (_, name) _ children -> `Elt (name, children)) in
  let rec strip = function
    | `Elt ("pre", children) as elt -> elt
    | `Elt (name, children) ->
        let rec skip_white_space acc = function
          | [] -> List.rev acc
          | `Text "" :: rest -> skip_white_space acc rest
          | oth :: rest -> skip_white_space (oth :: acc) rest in
        `Elt (name, skip_white_space [] @@ List.map strip children)
    | `Text text -> `Text (String.trim text) in
  let rec parse_code acc = function
    | [] -> Lwt.return (String.concat "" (List.rev acc))
    | `Text text :: rest ->
        parse_code (text :: acc) rest
    | `Elt (tag, _) :: _ ->
        fail "unsupported markup <%s> in code" tag in
  let rec parse_text acc = function
    | [] -> Lwt.return (List.rev acc)
    | `Text t1 :: `Text t2 :: rest ->
        parse_text acc (`Text (t1 ^ t2) :: rest)
    | `Elt ("br", _) :: rest ->
        parse_text acc rest
    | `Text text :: rest ->
        parse_text (Text text :: acc) rest
    | `Elt (("code" | "quote"), children) :: rest ->
        parse_code [] children >>= fun code ->
        parse_text (parse_code_notation code :: acc) rest
    | `Elt (("strong" | "em" | "b"), children) :: rest ->
        parse_text [] children >>= fun contents ->
        parse_text (Emph contents :: acc) rest
    | `Elt (tag, _) :: _ ->
        fail "unsupported markup <%s> in text" tag in
  let rec parse_contents acc = function
    | `Elt ("p", children) :: rest ->
        parse_text [] children >>= fun contents ->
        parse_contents (Learnocaml_tutorial.Paragraph contents :: acc) rest
    | `Elt ("pre", children) :: rest ->
        parse_code [] children >>= fun code ->
        let contents = [ parse_code_notation code ] in
        parse_contents (Learnocaml_tutorial.Paragraph contents :: acc) rest
    | `Elt (tag, _) :: _ ->
        fail "the only markups supported at toplevel are \
              <h2>, <p>, <ul> and <pre>, <%s> is not allowed" tag
    | `Text _ :: _ ->
        fail "text is not allowed at the toplevel, \
              wrap it in a <p> markup"
    | [] -> Lwt.return (List.rev acc) in
  let rec parse_steps = function
    | acc, None, []  ->
        Lwt.return (List.rev acc)
    | acc, Some (step_title, sacc), [] ->
        parse_contents [] (List.rev sacc) >>= fun step_contents ->
        let acc = Learnocaml_tutorial.{ step_title ; step_contents } :: acc in
        Lwt.return (List.rev acc)
    | acc, None, `Elt ("h2", title) :: rest ->
        parse_text [] title >>= fun step_title ->
        parse_steps (acc, Some (step_title, []), rest)
    | acc, None, elt :: rest ->
        fail "step title (<h2> markup) expected \
              after the tutorial title (<h1> markup)"
    | acc, Some (step_title, sacc), (`Elt ("h2", _) :: _ as rest) ->
        parse_contents [] (List.rev sacc) >>= fun step_contents ->
        let acc = Learnocaml_tutorial.{ step_title ; step_contents } :: acc in
        parse_steps (acc, None, rest)
    | acc, Some (step_title, sacc), elt :: rest ->
        parse_steps (acc, Some (step_title, elt :: sacc), rest) in
  match tree with
  | None -> fail "unparsable HTML file"
  | Some tree -> match strip tree with
    | `Elt ("html", [ `Elt ("head", _) ; `Elt ("body", contents) ])
    | `Elt ("html", [ `Elt ("body", contents) ]) ->
        begin match contents with
          | `Elt ("h1", title) :: rest ->
              parse_text [] title >>= fun tutorial_title ->
              parse_steps ([], None, rest) >>= fun tutorial_steps ->
              Lwt.return
                (Learnocaml_index.{ tutorial_title ; tutorial_name },
                 Learnocaml_tutorial.{ tutorial_title ; tutorial_steps })
          | _ ->
              fail "tutorial title (<h1> markup) expected \
                    at the beginning of the <body>"
        end
    | _ -> fail "wrong HTML structure, \
                 expecting a standard <html> with a <body>"

let parse_md_tutorial tutorial_name filename =
  let fail fmt =
    Format.kasprintf
      (fun res -> Lwt.fail_with (Format.sprintf "in file %s, %s" filename res))
      fmt in
  Lwt_io.(with_file ~mode: Input) filename @@ fun chan ->
  Lwt_io.read chan >>= fun str ->
  let strip md =
    let rec strip acc = function
      | [] -> List.rev acc
      | Omd.NL :: rest -> strip acc rest
      | oth :: rest -> strip (oth :: acc) rest in
    strip [] md in
  let rec parse_text acc = function
    | [] -> Lwt.return (List.rev acc)
    | Omd.NL :: rest -> parse_text acc rest
    | Omd.Code (_, code) :: rest ->
        let elt = parse_code_notation code in
        parse_text (elt :: acc) rest
    | Omd.Text t1 :: Omd.Text t2 :: rest ->
        parse_text acc (Omd.Text (t1 ^ t2) :: rest)
    | Omd.Text text :: rest ->
        parse_text (Text text :: acc) rest
    | Omd.Emph t :: rest | Omd.Bold t :: rest ->
        parse_text [] t >>= fun text ->
        parse_text (Emph text :: acc) rest
    | elt :: _  ->
        fail "unexpected content in title (%s)"
          (Omd.to_markdown [ elt ]) in
  let rec parse_contents acc = function
    | Omd.Paragraph children :: rest ->
        parse_text [] children >>= fun contents ->
        parse_contents (Learnocaml_tutorial.Paragraph contents :: acc) rest
    | Omd.Code_block (_, code) :: rest ->
        let contents = [ parse_code_notation (code ^ "\n") ] in
        parse_contents (Learnocaml_tutorial.Paragraph contents :: acc) rest
    | elt :: _ ->
        fail "unexpected content at toplevel (%s)"
          (Omd.to_markdown [ elt ])
    | [] -> Lwt.return (List.rev acc) in
  let rec parse_steps = function
    | acc, None, []  ->
        Lwt.return (List.rev acc)
    | acc, Some (step_title, sacc), [] ->
        parse_contents [] (List.rev sacc) >>= fun step_contents ->
        let acc = Learnocaml_tutorial.{ step_title ; step_contents } :: acc in
        Lwt.return (List.rev acc)
    | acc, None, Omd.H2 title :: rest ->
        parse_text [] title >>= fun step_title ->
        parse_steps (acc, Some (step_title, []), rest)
    | acc, None, elt :: rest ->
        fail "step title (<h2> markup) expected \
              after the tutorial title (<h1> markup)"
    | acc, Some (step_title, sacc), (Omd.H2 _ :: _ as rest) ->
        parse_contents [] (List.rev sacc) >>= fun step_contents ->
        let acc = Learnocaml_tutorial.{ step_title ; step_contents } :: acc in
        parse_steps (acc, None, rest)
    | acc, Some (step_title, sacc), elt :: rest ->
        parse_steps (acc, Some (step_title, elt :: sacc), rest) in
  match Omd.of_string str |> strip with
  | Omd.H1 title :: rest ->
      parse_text [] title >>= fun tutorial_title ->
      parse_steps ([], None, rest) >>= fun tutorial_steps ->
      Lwt.return
        (Learnocaml_index.{ tutorial_title ; tutorial_name },
         Learnocaml_tutorial.{ tutorial_title ; tutorial_steps })
  | _ ->
      fail "expecting a level 1 title at file beginning"

let tutorials_dir = ref "./tutorials"

let tutorials_index = ref None

let args = Arg.align @@
  [ "-tutorials-dir", Arg.Set_string tutorials_dir,
    "PATH path to the tutorial repository (default: [./tutorials])" ;
    "-tutorials-index", Arg.String (fun fn -> tutorials_index := Some fn),
    "PATH path to the tutorials index (default: [<tutorials-dir>/index.json])" ]

let index_enc =
  let open Json_encoding in
  let series_enc =
    obj2
      (req "title" string)
      (req "tutorials" (list string)) in
  check_version_1 @@
  obj1 (req "series" (assoc series_enc))

let to_file encoding fn value =
  Lwt_io.(with_file ~mode: Output) fn @@ fun chan ->
  let json = Json_encoding.construct encoding value in
  let json = match json with
    | `A _ | `O _ as d -> d
    | v -> `A [ v ] in
  let str = Ezjsonm.to_string ~minify:false (json :> Ezjsonm.t) in
  Lwt_io.write chan str

let from_file encoding fn =
  Lwt_io.(with_file ~mode: Input) fn @@ fun chan ->
  Lwt_io.read chan >>= fun str ->
  let json = Ezjsonm.from_string str in
  Lwt.return (Json_encoding.destruct encoding json)

module StringMap = Map.Make (String)

let main dest_dir =
  let (/) dir f =
    String.concat Filename.dir_sep [ dir ; f ] in
  let tutorials_index =
    match !tutorials_index with
    | Some tutorials_index -> tutorials_index
    | None -> !tutorials_dir / "index.json" in
  Lwt.catch
    (fun () ->
       (if Sys.file_exists tutorials_index then
          from_file index_enc tutorials_index
        else
          match
            Array.to_list (Sys.readdir !tutorials_dir) |>
            List.filter (fun file ->
                not (Sys.is_directory file) &&
                (Filename.check_suffix file ".md" ||
                 Filename.check_suffix file ".html"))
          with
          | [] ->
              Format.eprintf "No index file, no .md or .html file.@." ;
              Format.eprintf "This does not look like a LearnOCaml tutorial repository.@." ;
              Lwt.fail_with  "cannot continue"
          | files ->
              Format.eprintf "Missing index file, using all .dm and .html files.@." ;
              Lwt.return [ "tutorials", ("All tutorials", files) ]) >>= fun series ->
       let retrieve_tutorial name =
         let base_name = !tutorials_dir / name in
         let md_file = base_name ^ ".md" in
         if Sys.file_exists md_file then
           parse_md_tutorial name md_file
         else
           let html_file = base_name ^ ".html" in
           if Sys.file_exists html_file then
             parse_html_tutorial name html_file
           else
             Lwt.fail_with (Format.asprintf "missing file %s.{html|md}" base_name ) in
       List.fold_left
         (fun acc (name, (series_title, tutorials)) ->
            Lwt_list.map_p
              (fun name ->
                 retrieve_tutorial name >>= fun (server_index_handle, tutorial) ->
                 let json_path = dest_dir / "tutorial_" ^ name ^ ".json" in
                 to_file Learnocaml_tutorial.tutorial_enc json_path tutorial >>= fun () ->
                 Lwt.return server_index_handle)
              tutorials >>= fun series_tutorials ->
            acc >>= fun acc ->
            Lwt.return (StringMap.add name { series_title ; series_tutorials } acc))
         (Lwt.return StringMap.empty)
         series >>= fun index ->
       to_file tutorial_index_enc (dest_dir / "tutorials.json") index >>= fun () ->
       Lwt.return true)
    (fun exn ->
       let print_unknown ppf = function
         | Failure msg -> Format.fprintf ppf "Fatal: %s" msg
         | exn -> Format.fprintf ppf "Fatal: %s"  (Printexc.to_string exn) in
       Json_encoding.print_error ~print_unknown Format.err_formatter exn ;
       Format.eprintf "@." ;
       Lwt.return false)