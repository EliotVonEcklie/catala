(** Error formatting and helper functions *)

(**{1 Terminal formatting}*)

(* Adds handling of color tags in the formatter *)
let[@ocaml.warning "-32"] color_formatter ppf = Ocolor_format.prettify_formatter ppf; ppf

(* Sets handling of tags in the formatter to ignore them (don't print any color codes) *)
let unstyle_formatter ppf =
  Format.pp_set_mark_tags ppf false; ppf
  (* Format.pp_set_formatter_stag_functions ppf {
   *   Format.mark_open_stag = (fun _ -> "");
   *   mark_close_stag = (fun _ -> "");
   *   print_open_stag = ignore;
   *   print_close_stag = ignore;
   * };
   * ppf *)

(* SIDE EFFECT AT MODULE LOAD: this turns on handling of tags in [Format.sprintf] etc. functions (ignoring them) *)
let () = ignore (unstyle_formatter Format.str_formatter)
(* Note: we could do the same for std_formatter, err_formatter... but we'd rather promote the use of the formatting functions of this module and the below std_ppf / err_ppf *)

let has_color unix_fd =
  match !Cli.style_flag with
  | Cli.Never -> false
  | Always -> true
  | Auto -> Unix.isatty unix_fd

(* Here we affect the Ocolor printers to stderr/stdout, which remain separate from the ones used by [Format.printf] / [Format.eprintf] (which remain unchanged) *)

let std_ppf = lazy (
  if has_color Unix.stdout
  then Ocolor_format.raw_std_formatter
  else unstyle_formatter (Ocolor_format.raw_std_formatter)
)

let err_ppf = lazy (
  if has_color Unix.stderr
  then Ocolor_format.raw_err_formatter
  else unstyle_formatter (Ocolor_format.raw_err_formatter)
)

let ignore_ppf = lazy (
  Format.make_formatter (fun _ _ _ -> ()) (fun () -> ())
)

let unformat (f: Format.formatter -> unit) : string =
  let buf = Buffer.create 1024 in
  let ppf = unstyle_formatter (Format.formatter_of_buffer buf) in
  Format.pp_set_margin ppf max_int; (* We won't print newlines anyways, but better not have them in the first place (this wouldn't remove cuts in a vbox for example) *)
  let out_funs = Format.pp_get_formatter_out_functions ppf () in
  Format.pp_set_formatter_out_functions ppf
    { out_funs
      with Format.out_newline = (fun () -> out_funs.out_string " " 0 1);
           Format.out_indent = (fun _ -> ()) };
  f ppf;
  Format.pp_print_flush ppf ();
  Buffer.contents buf

(**{2 Message types and output helpers *)

type content_type = Error | Warning | Debug | Log | Result

let get_ppf = function
  | Result -> Lazy.force std_ppf
  | Debug when not !Cli.debug_flag -> Lazy.force ignore_ppf
  | Warning when !Cli.disable_warnings_flag -> Lazy.force ignore_ppf
  | Error | Log | Debug | Warning -> Lazy.force err_ppf

(**{3 Markers}*)

let print_time_marker =
  let time : float ref = ref (Unix.gettimeofday ()) in
  fun ppf () ->
  let new_time = Unix.gettimeofday () in
  let old_time = !time in
  time := new_time;
  let delta = (new_time -. old_time) *. 1000. in
  if delta > 50. then
    Format.fprintf ppf "@{<bold;black>[TIME] %.0fms@}@\n" delta

let pp_marker target ppf () =
  let open Ocolor_types in
  let tags, str = match target with
  | Debug -> [ Bold; Fg (C4 magenta) ], "[DEBUG]"
  | Error -> [ Bold; Fg (C4 red) ], "[ERROR]"
  | Warning -> [ Bold; Fg (C4 yellow) ], "[WARNING]"
  | Result -> [ Bold; Fg (C4 green) ], "[RESULT]"
  | Log -> [ Bold; Fg (C4 black) ], "[LOG]"
  in
  if target = Debug then print_time_marker ppf ();
  Format.pp_open_stag ppf (Ocolor_format.Ocolor_styles_tag tags);
  Format.pp_print_string ppf str;
  Format.pp_close_stag ppf ()

(**{2 Printers}*)

(** Prints the argument after the correct marker and to the correct channel *)
let format target format =
  let ppf = get_ppf target in
  pp_marker target ppf ();
  Format.pp_print_space ppf ();
  Format.pp_open_hovbox ppf 0;
  Format.kfprintf (fun ppf -> Format.pp_close_box ppf (); Format.pp_print_newline ppf ()) ppf format

(** {1 Message content} *)

module Content = struct
  type message = Format.formatter -> unit

  type position = { pos_message : message option; pos : Pos.t }
  type t = { message : message; positions : position list }

  let of_message (message : message) : t = { message; positions = [] }
  let of_string (s : string) : t = { message = (fun ppf -> Format.pp_print_string ppf s); positions = [] }
end

open Content

let internal_error_prefix =
  "Internal Error, please report to \
   https://github.com/CatalaLang/catala/issues: "

let to_internal_error (content : Content.t) : Content.t =
  { content with message = (fun ppf -> Format.fprintf ppf "%s@\n%t" internal_error_prefix content.message)}

let emit_content (content : Content.t) (target : content_type) : unit =
  let { message; positions } = content in
  match !Cli.message_format_flag with
  | Cli.Human ->
    format target
      "@[<v>%t%a@]"
      message
      (fun ppf l -> Format.pp_print_list
         ~pp_sep:(fun _ () -> ())
         (fun ppf pos ->
            Format.pp_print_cut ppf ();
            Format.pp_print_cut ppf ();
            Option.iter (fun msg -> Format.fprintf ppf "%t@," msg) pos.pos_message;
            Pos.format_loc_text ppf pos.pos)
         ppf l)
      positions
  | Cli.GNU ->
    (* The top message doesn't come with a position, which is not something the
       GNU standard allows. So we look the position list and put the top message
       everywhere there is not a more precise message. If we can'r find a
       position without a more precise message, we just take the first position
       in the list to pair with the message. *)
    let marker = pp_marker target in
    let ppf = get_ppf target in
    let () =
      if
        positions != []
        && List.for_all
          (fun (pos' : Content.position) -> Option.is_some pos'.pos_message)
          positions
      then
        Format.fprintf ppf ("@{<blue>%s@}: %a %s@\n")
          (Pos.to_string_short (List.hd positions).pos)
          marker ()
          (unformat message)
    in
    Format.pp_print_list
      ~pp_sep:Format.pp_print_newline
      (fun ppf pos' ->
         Format.fprintf ppf ("@{<blue>%s@}: %a %s")
           (Pos.to_string_short pos'.pos)
           marker ()
           (match pos'.pos_message with
            | None -> unformat message
            | Some msg' -> unformat msg'))
      ppf
      positions

(** {1 Error exception} *)

exception CompilerError of Content.t

(** {1 Error printing} *)

let raise_spanned_error ?(span_msg : Content.message option) (span : Pos.t) format =
  Format.kdprintf
    (fun message ->
      raise
        (CompilerError
           {
             message;
             positions = [{ pos_message = span_msg; pos = span }];
           }))
    format

let raise_multispanned_error_full (spans : (Content.message option * Pos.t) list) format =
  Format.kdprintf
    (fun message ->
      raise
        (CompilerError
           {
             message;
             positions =
               List.map
                 (fun (pos_message, pos) -> { pos_message; pos })
                 spans;
           }))
    format

let raise_multispanned_error spans format =
  raise_multispanned_error_full
    (List.map (fun (msg, pos) -> Option.map (fun s ppf -> Format.pp_print_string ppf s) msg, pos) spans)
    format

let raise_error format =
  Format.kdprintf
    (fun message -> raise (CompilerError { message; positions = [] }))
    format

let raise_internal_error format =
  raise_error ("%s" ^^ format) internal_error_prefix

(** {1 Warning printing}*)

let assert_internal_error condition fmt =
  if condition then raise_internal_error ("assertion failed: " ^^ fmt)
  else Format.ifprintf (Format.formatter_of_out_channel stdout) fmt

let emit_multispanned_warning (pos : (Content.message option * Pos.t) list) format =
  Format.kdprintf
    (fun message ->
      emit_content
        {
          message;
          positions =
            List.map
              (fun (pos_message, pos) -> { pos_message; pos })
              pos;
        }
        Warning)
    format

let emit_spanned_warning ?(span_msg : Content.message option) (span : Pos.t) format =
  emit_multispanned_warning [span_msg, span] format

let emit_warning format = emit_multispanned_warning [] format

let emit_log format =
  Format.kdprintf
    (fun message -> emit_content { message; positions = [] } Log)
    format

let emit_debug format =
  Format.kdprintf
    (fun message -> emit_content { message; positions = [] } Debug)
    format

let emit_result format =
  Format.kdprintf
    (fun message -> emit_content { message; positions = [] } Result)
    format
