(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020-2023 Inria,
   contributor: Alain Delaët-Tixeuil <alain.delaet--tixeuil@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Catala_utils
open Shared_ast
module D = Dcalc.Ast
module A = Ast

(** We make use of the strong invriants on the structure of programs:
    Defaultable values can only appear in certin positions. This information is
    given by the type structure of expressions. In particular this mean we don't
    need to use the monadic bind while computing arithmetic opertions or
    function calls. The resulting function is not more difficult than what we
    had when translating without exceptions.

    The typing translation is to simply trnsform defult type into option types. *)

let translate_var : 'm D.expr Var.t -> 'm A.expr Var.t = Var.translate
let translate_var : 'm D.expr Var.t -> 'm A.expr Var.t = Var.translate

let rec translate_typ (tau : typ) : typ =
  Mark.copy tau
    begin
      match Mark.remove tau with
      | TDefault t -> TOption (translate_typ t)
      | TLit l -> TLit l
      | TTuple ts -> TTuple (List.map translate_typ ts)
      | TStruct s -> TStruct s
      | TEnum en -> TEnum en
      | TOption _ ->
        Message.raise_internal_error
          "The types option should not appear before the dcalc -> lcalc \
           translation step."
      | TClosureEnv ->
        Message.raise_internal_error
          "The types closure_env should not appear before the dcalc -> lcalc \
           translation step."
      | TAny -> TAny
      | TArray ts -> TArray (translate_typ ts)
      | TArrow (t1, t2) -> TArrow (List.map translate_typ t1, translate_typ t2)
    end

let rec translate_default
    (exceptions : 'm D.expr list)
    (just : 'm D.expr)
    (cons : 'm D.expr)
    (mark_default : 'm mark) : 'm A.expr boxed =
  let exceptions =
    List.map
      (fun except -> Expr.thunk_term (translate_expr except) (Mark.get except))
      exceptions
  in
  let pos = Expr.mark_pos mark_default in
  let exceptions =
    Expr.make_app
      (Expr.eop Op.HandleDefault
         [TAny, pos; TAny, pos; TAny, pos]
         (Expr.no_mark mark_default))
      [
        Expr.earray exceptions mark_default;
        Expr.thunk_term (translate_expr just) (Mark.get just);
        Expr.thunk_term (translate_expr cons) (Mark.get cons);
      ]
      pos
  in
  exceptions

and translate_expr (e : 'm D.expr) : 'm A.expr boxed =
  let m = Mark.get e in
  match Mark.remove e with
  | EEmptyError -> assert false
  | EErrorOnEmpty arg ->
    Expr.ecatch (translate_expr arg) EmptyError
      (Expr.eraise NoValueProvided m)
      m
  | EDefault { excepts; just; cons } ->
    translate_default excepts just cons (Mark.get e)
  | EPureDefault e -> translate_expr e
  | EOp { op; tys } -> Expr.eop (Operator.translate op) tys m
  | ( ELit _ | EApp _ | EArray _ | EVar _ | EExternal _ | EAbs _ | EIfThenElse _
    | ETuple _ | ETupleAccess _ | EInj _ | EAssert _ | EStruct _
    | EStructAccess _ | EMatch _ ) as e ->
    Expr.map ~f:translate_expr (Mark.add m e)
  | _ -> .

let translate_program (prg : 'm D.program) : 'm A.program =
  Bindlib.unbox (Program.map_exprs ~f:translate_expr ~varf:translate_var prg)
