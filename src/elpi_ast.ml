(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1 or later           *)
(* ------------------------------------------------------------------------- *)

open Elpi_util

module Loc = struct
  type t = {
    source_name : string;
    source_start: int;
    source_stop: int;
    line: int;
    line_starts_at: int;
  }
  [@@deriving eq]

  let to_string {
    source_name;
    source_start;
    source_stop;
    line;
    line_starts_at; }
  =
    let source =
     if source_name = "" then ""
     else source_name ^ ", " in
    let chars = Printf.sprintf "characters %d-%d" source_start source_stop in
    let pos =
      if line = -1 then chars
      else Printf.sprintf "%s, line %d, column %d"
             chars line (source_stop - line_starts_at) in
    source ^ pos

  let pp fmt l = Format.fprintf fmt "%s" (to_string l)
  let show l = to_string l

end

module Func = struct

  module Self = struct

  type t = string
  let compare = String.compare

  (* Hash consing *)
  let from_string =
   let h = Hashtbl.create 37 in
   let rec aux = function
    | "nil" -> aux "[]"
    | "cons" -> aux "::"
    | x ->
       try Hashtbl.find h x
       with Not_found -> Hashtbl.add h x x ; x
   in
     aux

  let pp fmt s = Format.fprintf fmt "%s" s
  let show x = x
  let equal x y = x == y || x = y (* Resilient to unmarshaling *)
  let truef = from_string "true"
  let andf = from_string ","
  let andf2 = from_string "&"
  let orf = from_string ";"
  let implf = from_string "=>"
  let rimplf = from_string ":-"
  let cutf = from_string "!"
  let pif = from_string "pi"
  let sigmaf = from_string "sigma"
  let eqf = from_string "="
  let isf = from_string "is"
  let consf = from_string "::"
  let nilf = from_string "[]"
  let arrowf = from_string "->"
  let sequentf = from_string "?-"
  let ctypef = from_string "ctype"
  
  let dummyname = from_string "%dummy"
  let spillf = from_string "%spill"

  end

  include Self
  module Map = Map.Make(Self)

end

type term =
   Const of Func.t
 | App of term * term list
 | Lam of Func.t * term
 | CData of Elpi_util.CData.t
 | Quoted of quote
and quote = { data : string; loc : Loc.t; kind : string option }
[@@deriving show, eq]

let mkC x = CData x
let mkLam x t = Lam (Func.from_string x,t)
let mkNil = Const Func.nilf
let mkQuoted loc s =
  let strip n m loc = { loc with Loc.source_start = loc.Loc.source_start + n;
                                 source_stop = loc.Loc.source_stop - m;
                                 line_starts_at = loc.Loc.line_starts_at - m; } in
  (* {{...}} stripped by the parser *)
  let loc = strip 2 2 loc in
  let rec find_data i =
    match s.[i] with
    | '{' -> find_data (i+1)
    | ':' ->
       let rec find_space i = match s.[i] with
         | ' ' -> i 
         | '\n' -> i 
         | _ -> find_space (i+1) in
       let space_after = find_space 0 - 1 in
       let kind = String.sub s (i+1) space_after in
       let data = String.sub s (i+space_after+2) (String.length s - i - i - space_after-2) in
       { loc = strip (i+space_after+2) i loc; data; kind = Some kind }
    | _ -> { loc = strip i i loc; data = String.sub s i (String.length s - i - i); kind = None }
  in
    Quoted (find_data 0)
let mkSeq l =
 let rec aux =
  function
    [] -> assert false
  | [e] -> e
  | hd::tl -> App(Const Func.consf,[hd;aux tl])
 in
  aux l
let mkIs x f = App(Const Func.isf,[x;f])

type attribute =
  Name of string | After of string | Before of string | If of string     
[@@deriving show]

type ('term,'attributes) clause = {
  loc : Loc.t;
  attributes : 'attributes;
  body : 'term;
}[@@deriving show]

type sequent = { eigen : term; context : term; conclusion : term }
and 'attribute chr_rule = {
  to_match : sequent list;
  to_remove : sequent list;
  guard : term option;
  new_goal : sequent option;
  cattributes : 'attribute;
  clocation : Loc.t;
}
[@@deriving show, create]

type ('name,'term) macro = { mlocation : Loc.t; maname : 'name; mbody : 'term }
[@@deriving show]

type tdecl = { tloc : Loc.t; textern : bool; tname : Func.t; tty : term }
[@@deriving show]

type 'name mode =
  { mname : 'name; margs : bool list }
[@@deriving show]

type decl =
 (* Blocks *)
 | Begin of Loc.t
 | Namespace of Loc.t * Func.t
 | Constraint of Loc.t * Func.t list
 | Shorten of Loc.t * Func.t
 | End of Loc.t

 | Accumulated of Loc.t * decl list

 (* data *)
 | Clause of (term, attribute list) clause
 | Local of Func.t
 | Mode of Func.t mode list
 | Chr of attribute list chr_rule
 | Macro of (Func.t, term) macro
 | Type of tdecl
[@@deriving show]


let mkLocal x = Local (Func.from_string x)

type program = decl list [@@deriving show]
type goal = Loc.t * term

exception NotInProlog of Loc.t * string

let mkApp loc = function
(* FG: for convenience, we accept an empty list of arguments *)
  | [(App _ | Const _ | Quoted _) as c] -> c
  | App(c,l1)::l2 -> App(c,l1@l2)
  | (Const _ | Quoted _) as c::l2 -> App(c,l2)
  | [] -> raise (NotInProlog(loc,"empty application"))
  | x::_ -> raise (NotInProlog(loc,"application head: " ^ show_term x))

let fresh_uv_names = ref (-1);;
let mkFreshUVar () = incr fresh_uv_names; Const (Func.from_string ("_" ^ string_of_int !fresh_uv_names))
let fresh_names = ref (-1);;
let mkFreshName () = incr fresh_names; Const (Func.from_string ("__" ^ string_of_int !fresh_names))
let mkCon c = Const (Func.from_string c)

open Elpi_util
module Fmt = Format

let { CData.cin = in_float; isc = is_float; cout = out_float } as cfloat =
  CData.(declare {
    data_name = "float";
    data_pp = (fun f x -> Fmt.fprintf f "%f" x);
    data_eq = (==);
    data_hash = Hashtbl.hash;
    data_hconsed = false;
  })
let { CData.cin = in_int; isc = is_int; cout = out_int } as cint =
  CData.(declare {
    data_name = "int";
    data_pp = (fun f x -> Fmt.fprintf f "%d" x);
    data_eq = (==);
    data_hash = Hashtbl.hash;
    data_hconsed = false;
  })
let { CData.cin = in_string; isc = is_string; cout = out_string } as cstring =
  CData.(declare {
    data_name = "string";
    data_pp = (fun f x -> Fmt.fprintf f "\"%s\"" x);
    data_eq = (=);
    data_hash = Hashtbl.hash;
    data_hconsed = true;
  })
let { CData.cin = in_loc; isc = is_loc; cout = out_loc } as cloc =
  CData.(declare {
    data_name = "loc";
    data_pp = (fun f (x,name) ->
      let bname = Filename.basename x.Loc.source_name in
      let line_no = x.Loc.line in
      match name with
      | None -> Fmt.fprintf f "%s:%4d:" bname line_no 
      | Some name -> Fmt.fprintf f "%s:%4d:%s:" bname line_no name);
    data_eq = (=);
    data_hash = Hashtbl.hash;
    data_hconsed = false;
  })
