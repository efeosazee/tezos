(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Proto_alpha
open Alpha_context
open Tezos_micheline
open Script_typed_ir
open Script_tc_errors
open Script_ir_translator
open Script_interpreter
open Michelson_v1_printer

let print_ty (type t) ppf (annot, (ty : t ty)) =
  unparse_ty annot ty
  |> Micheline.strip_locations
  |> Michelson_v1_printer.print_expr_unwrapped ppf

let print_stack_ty (type t) ?(depth = max_int) ppf (s : t stack_ty) =
  let rec loop
    : type t. int -> Format.formatter -> t stack_ty -> unit
    = fun depth ppf -> function
      | Empty_t -> ()
      | _ when depth <= 0 ->
          Format.fprintf ppf "..."
      | Item_t (last, Empty_t, annot) ->
          Format.fprintf ppf "%a"
            print_ty (annot, last)
      | Item_t (last, rest, annot) ->
          Format.fprintf ppf "%a :@ %a"
            print_ty (annot, last) (loop (depth - 1)) rest in
  match s with
  | Empty_t ->
      Format.fprintf ppf "[]"
  | sty ->
      Format.fprintf ppf "@[<hov 2>[ %a ]@]" (loop depth) sty

let rec print_enumeration ppf = function
  | [ single ] ->
      Format.fprintf ppf "%a"
        Format.pp_print_text single
  | [ prev ; last ] ->
      Format.fprintf ppf "%a@ or@ %a"
        Format.pp_print_text prev Format.pp_print_text last
  | first :: rest ->
      Format.fprintf ppf "%a,@ %a"
        Format.pp_print_text first print_enumeration rest
  | [] -> assert false

let collect_error_locations errs =
  let rec collect acc = function
    | Alpha_environment.Ecoproto_error
        (Ill_formed_type (_, _, _)
        | Runtime_contract_error (_, _)
        | Michelson_v1_primitives.Invalid_primitive_name (_, _)
        | Ill_typed_data (_, _, _)
        | Ill_typed_contract (_, _)) :: _
    | [] -> acc
    | Alpha_environment.Ecoproto_error
        (Invalid_arity (loc, _, _, _)
        | Inconsistent_type_annotations (loc, _, _)
        | Unexpected_annotation loc
        | Type_too_large (loc, _, _)
        | Invalid_namespace (loc, _, _, _)
        | Invalid_primitive (loc, _, _)
        | Invalid_kind (loc, _, _)
        | Duplicate_field (loc, _)
        | Unexpected_big_map loc
        | Unexpected_operation loc
        | Fail_not_in_tail_position loc
        | Undefined_binop (loc, _, _, _)
        | Undefined_unop (loc, _, _)
        | Bad_return (loc, _, _)
        | Bad_stack (loc, _, _, _)
        | Unmatched_branches (loc, _, _)
        | Self_in_lambda loc
        | Invalid_constant (loc, _, _)
        | Invalid_contract (loc, _)
        | Comparable_type_expected (loc, _)
        | Overflow loc
        | Reject loc) :: rest ->
        collect (loc :: acc) rest
    | _ :: rest -> collect acc rest in
  collect [] errs

let report_errors ~details ~show_source ?parsed ppf errs =
  let rec print_trace locations errs =
    let print_loc ppf loc =
      match locations loc with
      | None ->
          Format.fprintf ppf "At (unshown) location %d, " loc
      | Some loc ->
          Format.fprintf ppf "%s,@ "
            (String.capitalize_ascii
               (Format.asprintf "%a" Micheline_parser.print_location loc))  in
    let parsed_locations parsed loc = try
        let oloc = List.assoc loc parsed.Michelson_v1_parser.unexpansion_table in
        let ploc, _ = List.assoc oloc parsed.expansion_table in
        Some ploc
      with Not_found -> None in
    let print_source ppf (parsed, _hilights (* TODO *)) =
      let lines =
        String.split_on_char '\n' parsed.Michelson_v1_parser.source in
      let cols =
        String.length (string_of_int (List.length lines)) in
      Format.fprintf ppf "@[<v 0>%a@]"
        (Format.pp_print_list
           (fun ppf (i, l) ->
              Format.fprintf ppf "%0*d: %s" cols i l))
        (List.mapi (fun i l -> (i + 1, l)) lines) in
    match errs with
    | [] -> ()
    | Alpha_environment.Ecoproto_error (Michelson_v1_primitives.Invalid_primitive_name (expr, loc)) :: rest ->
        let parsed =
          match parsed with
          | Some parsed ->
              if Micheline.strip_locations (Michelson_v1_macros.unexpand_rec (Micheline.root expr)) =
                 parsed.Michelson_v1_parser.unexpanded then
                parsed
              else
                Michelson_v1_printer.unparse_invalid expr
          | None -> Michelson_v1_printer.unparse_invalid expr in
        let hilights = loc :: collect_error_locations rest in
        if show_source then
          Format.fprintf ppf
            "@[<hov 0>@[<hov 2>Invalid primitive:@ %a@]@]"
            print_source (parsed, hilights)
        else
          Format.fprintf ppf "Invalid primitive." ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace (parsed_locations parsed) rest
    | Alpha_environment.Ecoproto_error (Ill_typed_data (name, expr, ty)) :: rest ->
        let parsed =
          match parsed with
          | Some parsed when expr = parsed.Michelson_v1_parser.expanded -> parsed
          | Some _ | None -> Michelson_v1_printer.unparse_expression expr in
        let hilights = collect_error_locations rest in
        Format.fprintf ppf
          "@[<hov 0>@[<hov 2>Ill typed %adata:@ %a@]@ \
           @[<hov 2>is not an expression of type@ %a@]@]"
          (fun ppf -> function
             | None -> ()
             | Some s -> Format.fprintf ppf "%s " s)
          name
          print_source (parsed, hilights)
          print_ty (None, ty) ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace (parsed_locations parsed) rest
    | Alpha_environment.Ecoproto_error (Ill_formed_type (_, expr, loc)) :: rest ->
        let parsed =
          match parsed with
          | Some parsed when expr = parsed.Michelson_v1_parser.expanded -> parsed
          | Some _ | None -> Michelson_v1_printer.unparse_expression expr in
        let hilights = loc :: collect_error_locations errs in
        if show_source then
          Format.fprintf ppf
            "@[<v 2>%aill formed type:@ %a@]"
            print_loc loc print_source (parsed, hilights)
        else
          Format.fprintf ppf
            "Ill formed type." ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace (parsed_locations parsed) rest
    | Alpha_environment.Ecoproto_error (Ill_typed_contract (expr, type_map)) :: rest ->
        let parsed =
          match parsed with
          | Some parsed when not details && expr = parsed.Michelson_v1_parser.expanded -> parsed
          | Some _ | None -> Michelson_v1_printer.unparse_toplevel ~type_map expr in
        let hilights = collect_error_locations rest in
        if show_source then
          Format.fprintf ppf
            "@[<v 0>Ill typed contract:@,  %a@]"
            print_source (parsed, hilights)
        else
          Format.fprintf ppf "Ill typed contract.";
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace (parsed_locations parsed) rest
    | Alpha_environment.Ecoproto_error (Missing_field prim) :: rest ->
        Format.fprintf ppf "@[<v 0>Missing contract field: %s@]"
          (Michelson_v1_primitives.string_of_prim prim) ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error (Duplicate_field (loc, prim)) :: rest ->
        Format.fprintf ppf "@[<v 0>%aduplicate contract field: %s@]"
          print_loc loc
          (Michelson_v1_primitives.string_of_prim prim) ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error (Unexpected_big_map loc) :: rest ->
        Format.fprintf ppf "%abig_map type only allowed on the left of the toplevel storage pair"
          print_loc loc ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error (Unexpected_operation loc) :: rest ->
        Format.fprintf ppf "%aoperation type forbidden in parameter, storage and constants"
          print_loc loc ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error (Runtime_contract_error (contract, expr)) :: rest ->
        let parsed =
          match parsed with
          | Some parsed when expr = parsed.Michelson_v1_parser.expanded -> parsed
          | Some _ | None -> Michelson_v1_printer.unparse_toplevel expr in
        let hilights = collect_error_locations rest in
        Format.fprintf ppf
          "@[<v 2>Runtime error in contract %a:@ %a@]"
          Contract.pp contract
          print_source (parsed, hilights) ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace (parsed_locations parsed) rest
    | Alpha_environment.Ecoproto_error (Apply.Internal_operation_replay op) :: rest ->
        Format.fprintf ppf
          "@[<v 2>Internal operation replay attempt:@,%a@]"
          Operation_result.pp_internal_operation op ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error Gas.Gas_limit_too_high :: rest ->
        Format.fprintf ppf
          "Gas limit for the block is out of the protocol hard bounds." ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error Gas.Block_quota_exceeded :: rest ->
        Format.fprintf ppf
          "Gas limit for the block exceeded during typechecking or execution." ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error Gas.Operation_quota_exceeded :: rest ->
        Format.fprintf ppf
          "@[<v 0>Gas limit exceeded during typechecking or execution.@,Try again with a higher gas limit.@]" ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error Contract.Storage_limit_too_high :: rest ->
        Format.fprintf ppf
          "Storage limit for the block is out of the protocol hard bounds." ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error Contract.Block_storage_quota_exceeded :: rest ->
        Format.fprintf ppf
          "Storage limit for the block exceeded during typechecking or execution." ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | Alpha_environment.Ecoproto_error Contract.Operation_storage_quota_exceeded :: rest ->
        Format.fprintf ppf
          "@[<v 0>Storage limit exceeded during typechecking or execution.@,Try again with a higher storage limit.@]" ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | [ Alpha_environment.Ecoproto_error (Script_interpreter.Bad_contract_parameter c) ] ->
        Format.fprintf ppf
          "@[<v 0>Account %a is not a smart contract, it does not take arguments.@,\
           The `-arg' flag should not be used when transferring to an account.@]"
          Contract.pp c
    | Alpha_environment.Ecoproto_error err :: rest ->
        begin match err with
          | Script_interpreter.Bad_contract_parameter c ->
              Format.fprintf ppf
                "Invalid argument passed to contract %a."
                Contract.pp c
          | Invalid_arity (loc, name, exp, got) ->
              Format.fprintf ppf
                "%aprimitive %s expects %d arguments but is given %d."
                print_loc loc (Michelson_v1_primitives.string_of_prim name) exp got
          | Invalid_namespace (loc, name, exp, got) ->
              let human_namespace = function
                | Instr_namespace -> ("an", "instruction")
                | Type_namespace -> ("a", "type name")
                | Constant_namespace -> ("a", "constant constructor")
                | Keyword_namespace -> ("a", "keyword") in
              Format.fprintf ppf
                "@[%aunexpected %s %s, only %s %s can be used here."
                print_loc loc
                (snd (human_namespace got))
                (Michelson_v1_primitives.string_of_prim name)
                (fst (human_namespace exp)) (snd (human_namespace exp))
          | Invalid_primitive (loc, exp, got) ->
              Format.fprintf ppf
                "@[%ainvalid primitive %s, only %a can be used here."
                print_loc loc
                (Michelson_v1_primitives.string_of_prim got)
                print_enumeration
                (List.map Michelson_v1_primitives.string_of_prim exp)
          | Invalid_kind (loc, exp, got) ->
              let human_kind = function
                | Seq_kind -> ("a", "sequence")
                | Prim_kind -> ("a", "primitive")
                | Int_kind -> ("an", "int")
                | String_kind -> ("a", "string") in
              Format.fprintf ppf
                "@[%aunexpected %s, only@ %a@ can be used here."
                print_loc loc
                (snd (human_kind got))
                print_enumeration
                (List.map (fun k -> let (a, n) = human_kind k in a ^ " " ^ n) exp)
          | Duplicate_map_keys (_, expr) ->
              Format.fprintf ppf
                "@[<v 2>Map literals cannot contain duplicate keys, \
                 however a duplicate key was found:@ \
                 @[%a@]"
                print_expr expr
          | Unordered_map_keys (_, expr) ->
              Format.fprintf ppf
                "@[<v 2>Keys in a map literal must be in strictly ascending order, \
                 but they were unordered in literal:@ \
                 @[%a@]"
                print_expr expr
          | Duplicate_set_values (_, expr) ->
              Format.fprintf ppf
                "@[<v 2>Set literals cannot contain duplicate values, \
                 however a duplicate value was found:@ \
                 @[%a@]"
                print_expr expr
          | Unordered_set_values (_, expr) ->
              Format.fprintf ppf
                "@[<v 2>Values in a set literal must be in strictly ascending order, \
                 but they were unordered in literal:@ \
                 @[%a@]"
                print_expr expr
          | Fail_not_in_tail_position loc ->
              Format.fprintf ppf
                "%aThe FAIL instruction must appear in a tail position."
                print_loc loc
          | Undefined_binop (loc, name, tya, tyb) ->
              Format.fprintf ppf
                "@[<hov 0>@[<hov 2>%aoperator %s is undefined between@ %a@]@ \
                 @[<hov 2>and@ %a.@]@]"
                print_loc loc
                (Michelson_v1_primitives.string_of_prim name)
                print_ty (None, tya)
                print_ty (None, tyb)
          | Undefined_unop (loc, name, ty) ->
              Format.fprintf ppf
                "@[<hov 0>@[<hov 2>%aoperator %s is undefined on@ %a@]@]"
                print_loc loc
                (Michelson_v1_primitives.string_of_prim name)
                print_ty (None, ty)
          | Bad_return (loc, got, exp) ->
              Format.fprintf ppf
                "@[<v 2>%awrong stack type at end of body:@,\
                 - @[<v 0>expected return stack type:@ %a,@]@,\
                 - @[<v 0>actual stack type:@ %a.@]@]"
                print_loc loc
                (fun ppf -> print_stack_ty ppf) (Item_t (exp, Empty_t, None))
                (fun ppf -> print_stack_ty ppf) got
          | Bad_stack (loc, name, depth, sty) ->
              Format.fprintf ppf
                "@[<hov 2>%awrong stack type for instruction %s:@ %a.@]"
                print_loc loc
                (Michelson_v1_primitives.string_of_prim name)
                (print_stack_ty ~depth) sty
          | Unmatched_branches (loc, sta, stb) ->
              Format.fprintf ppf
                "@[<v 2>%atwo branches don't end with the same stack type:@,\
                 - @[<hov>first stack type:@ %a,@]@,\
                 - @[<hov>other stack type:@ %a.@]@]"
                print_loc loc
                (fun ppf -> print_stack_ty ppf) sta
                (fun ppf -> print_stack_ty ppf) stb
          | Inconsistent_annotations (annot1, annot2) ->
              Format.fprintf ppf
                "@[<v 2>The two annotations do not match:@,\
                 - @[<hov>%s@]@,\
                 - @[<hov>%s@]"
                annot1 annot2
          | Inconsistent_type_annotations (loc, ty1, ty2) ->
              Format.fprintf ppf
                "@[<v 2>%athe two types contain incompatible annotations:@,\
                 - @[<hov>%a@]@,\
                 - @[<hov>%a@]"
                print_loc loc
                print_ty (None, ty1)
                print_ty (None, ty2)
          | Unexpected_annotation loc ->
              Format.fprintf ppf
                "@[<v 2>%aunexpected annotation."
                print_loc loc
          | Type_too_large (loc, size, maximum_size) ->
              Format.fprintf ppf
                "@[<v 2>%atype size (%d) exceeded maximum type size (%d)."
                print_loc loc
                size maximum_size
          | Self_in_lambda loc ->
              Format.fprintf ppf
                "%aThe SELF instruction cannot appear in a lambda."
                print_loc loc
          | Bad_stack_length ->
              Format.fprintf ppf
                "Bad stack length."
          | Bad_stack_item lvl ->
              Format.fprintf ppf
                "Bad stack item %d."
                lvl
          | Invalid_constant (loc, got, exp) ->
              Format.fprintf ppf
                "@[<hov 0>@[<hov 2>%avalue@ %a@]@ \
                 @[<hov 2>is invalid for type@ %a.@]@]"
                print_loc loc
                print_expr got
                print_ty (None, exp)
          | Invalid_contract (loc, contract) ->
              Format.fprintf ppf
                "%ainvalid contract %a."
                print_loc loc Contract.pp contract
          | Comparable_type_expected (loc, ty) ->
              Format.fprintf ppf "%acomparable type expected."
                print_loc loc ;
              Format.fprintf ppf "@[<hov 0>@[<hov 2>Type@ %a@]@ is not comparable.@]"
                print_ty (None, ty)
          | Inconsistent_types (tya, tyb) ->
              Format.fprintf ppf
                "@[<hov 0>@[<hov 2>Type@ %a@]@ \
                 @[<hov 2>is not compatible with type@ %a.@]@]"
                print_ty (None, tya)
                print_ty (None, tyb)
          | Reject loc ->
              Format.fprintf ppf "%ascript reached FAIL instruction"
                print_loc loc
          | Overflow loc ->
              Format.fprintf ppf "%aunexpected arithmetic overflow"
                print_loc loc
          | err -> Format.fprintf ppf "%a" Alpha_environment.Error_monad.pp err
        end ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest
    | err :: rest ->
        Format.fprintf ppf "%a" Error_monad.pp err ;
        if rest <> [] then Format.fprintf ppf "@," ;
        print_trace locations rest in
  Format.fprintf ppf "@[<v 0>" ;
  print_trace (fun _ -> None) errs ;
  Format.fprintf ppf "@]"
