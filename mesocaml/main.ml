open Learnocaml_data
open Learnocaml_report

open Lwt.Infix

open Utils

module IntMap = Map.Make(struct type t = int let compare = compare end)

(* Return all the token in sync *)
let get_all_token sync =
  let rec aux acc f =
    let dir = Sys.readdir f in
    let dir_full = Array.map (fun s -> f ^ "/" ^ s) dir in
    (* If there is a sub-directory which does not start by "." *)
    if Array.exists (fun s -> Sys.is_directory s && not (String.contains s '.')) dir_full
    then
      Array.fold_left
        (fun acc x ->
          if Sys.is_directory x
          then aux acc x
          else acc
        ) acc dir_full
    else
      let sync_len = String.length sync + 1 in
      let string_token =
        String.concat "-" @@
          String.split_on_char '/' @@
            String.sub f sync_len (String.length f - sync_len) in
      if Token.check string_token
      then Token.parse string_token :: acc
      else acc
  in
  aux [] sync

let impl_of_string s = Parse.implementation (Lexing.from_string s)

let get_with_pred p =
  let rec aux =
  function
  | [] -> None
  | x::xs ->
     match p x with
     | None -> aux xs
     | res -> res
  in aux

type func_res = Asttypes.rec_flag * Parsetree.value_binding list

let find_func f : Parsetree.structure_item list -> func_res option =
  let open Parsetree in
  let pred c =
    match c.pstr_desc with
    | Pstr_value (r,(x::_ as body)) ->
       begin
         match x.pvb_pat.ppat_desc with
         | Ppat_var v ->
            if Asttypes.(v.txt) = f
            then Some (r,body)
            else None
         | _ -> None
       end
    | _ -> None
  in
  get_with_pred pred

(* Renvoie la liste des différents Answer.t associés à exo_name et fun_name *)
let get_exo_states exo_name fun_name lst : (Token.t * Answer.t * func_res) list =
  Lwt_main.run @@
    Lwt_list.filter_map_s
      (fun t ->
        Learnocaml_store.Save.get t >|=
        bindOption
          (fun x ->
            bindOption
              (fun x ->
                fmapOption
                  (fun r -> t,x,r)
                  (find_func fun_name (impl_of_string Answer.(x.solution)))
                )
              (SMap.find_opt exo_name Save.(x.all_exercise_states))
          )
      )
      lst

(* Renvoie un couple où:
   - Le premier membre contient les réponses sans notes
   - Le second contient les report des réponses notées
*)
let partition_WasGraded =
  let aux (nonlst,acc) ((a,x,b) as e) =
    match Answer.(x.report) with
    | None -> e::nonlst,acc
    | Some g -> nonlst,(a,g,b)::acc
  in
  List.fold_left aux ([], [])

let partition_FunExist fun_name =
  let pred (_,x,_) =
    let rec inner_pred =
      function
      | Message (x,_) ->
         begin
           match x with
           | Text found::Code fn::Text t::_ ->
              found = "Found" && fn = fun_name && t = "with compatible type."
           | _ -> false
         end
      | Section (_,x) -> List.exists inner_pred x
    in List.exists inner_pred x
  in List.partition pred

let partition_by_grade funname =
  let rec get_relative_section = function
    | [] -> []
    | (Message _)::xs -> get_relative_section xs
    | (Section (t,res))::xs ->
       match t with
       | Text func::Code  fn::_ ->
          if func = "Function:" && fn = funname
          then res
          else get_relative_section xs
       | _ -> get_relative_section xs
  in
  let rec get_grade xs =
    let aux acc =
      function
      | Section (_,s) -> get_grade s
      | Message (_,s) ->
         match s with
         | Success i -> acc + i
         | _ -> acc
    in
    List.fold_left aux 0 xs
  in
  let aux acc ((_,x,_) as e) =
    let sec = get_relative_section x in
    let g = get_grade sec in
    let lst =
      match IntMap.find_opt g acc with
      | None -> [e]
      | Some xs -> e::xs
    in IntMap.add g lst acc
  in
  List.fold_left aux IntMap.empty

let hm_part m =
  let hashtbl = Hashtbl.create 100 in
  List.iter
    (fun (t,_,x) ->
      let hash,lst = Ast_utils.hash_of_bindings 50 x in
      Hashtbl.add hashtbl t (hash::lst)
    ) m;
  Clustering.cluster hashtbl

exception Found of func_res
let assoc_3 t lst =
  try
    List.iter (fun (t',_,x) -> if t = t' then raise (Found x) else ()) lst;
    failwith "assoc_3"
  with
  | Found x -> x

let print_hm assoc xs =
  let string_of_bindings (r,xs)=
    let pstr_desc = Parsetree.Pstr_value (r,xs) in
    let pstr_loc = Location.none in
    let str =
      Pprintast.string_of_structure [Parsetree.{pstr_desc;pstr_loc}] in
    "----\n" ^ str ^ "\n----\n"
  in
  ignore @@
    List.fold_right
      (fun lst acc ->
        Printf.printf "+ Class n° %d: \n" acc;
        print_endline @@
          Clustering.string_of_tree
            (fun xs ->
              Clustering.string_of_token_list xs ^ "\n"
              ^ string_of_bindings (assoc_3 (List.hd xs) assoc)
            )
            lst;
        acc+1
      ) xs 1

let refine_with_hm =
  IntMap.map (fun x -> x, hm_part x)

let print_part m =
  Printf.printf "In the remaining, %d classes were found:\n" (IntMap.cardinal m);
  IntMap.iter
    (fun k (assoc, hmpart) ->
      Printf.printf " %d pts: %d answers\n" k (List.length assoc);
      Printf.printf "  HM CLASSES: %d\n\n" (List.length hmpart);
      print_hm assoc hmpart
    )
    m

let main sync exo_name fun_name =
  Learnocaml_store.sync_dir := Filename.concat (Sys.getcwd ()) sync;
  let lst = get_all_token sync in
  let saves = get_exo_states exo_name fun_name lst in
  Printf.printf "%d matching repositories found.\n" (List.length saves);
  let nonlst,lst = partition_WasGraded saves in
  let funexist,nonfunexist = partition_FunExist fun_name lst in
  let map = partition_by_grade fun_name funexist in
  let map = refine_with_hm map in
  Printf.printf "%d codes were not graded.\n" (List.length nonlst);
  Printf.printf "When graded, %d codes didn't implemented %s with the right type.\n" (List.length nonfunexist) fun_name;
  print_part map;
  ()

let () =
  if Array.length Sys.argv - 1 < 3
  then
    begin
      print_endline "You must provide 3 arguments: sync repo, exo name and fun name";
      exit 1
    end
  else
    main Sys.argv.(1) Sys.argv.(2) Sys.argv.(3)
