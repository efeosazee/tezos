(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

let build_rpc_directory validator mainchain_validator =

  let distributed_db = Validator.distributed_db validator in
  let state = Distributed_db.state distributed_db in

  let dir : unit RPC_directory.t ref = ref RPC_directory.empty in
  let gen_register0 s f =
    dir := RPC_directory.gen_register !dir s (fun () p q -> f p q) in
  let gen_register1 s f =
    dir := RPC_directory.gen_register !dir s (fun ((), a) p q -> f a p q) in

  gen_register0 Monitor_services.S.bootstrapped begin fun () () ->
    let block_stream, stopper =
      Chain_validator.new_head_watcher mainchain_validator in
    let first_run = ref true in
    let next () =
      if !first_run then begin
        first_run := false ;
        let chain_state = Chain_validator.chain_state mainchain_validator in
        Chain.head chain_state >>= fun head ->
        let head_hash = State.Block.hash head in
        let head_header = State.Block.header head in
        Lwt.return (Some (head_hash, head_header.shell.timestamp))
      end else begin
        Lwt.pick [
          ( Lwt_stream.get block_stream >|=
            Option.map ~f:(fun b ->
                (State.Block.hash b, (State.Block.header b).shell.timestamp)) ) ;
          (Chain_validator.bootstrapped mainchain_validator >|= fun () -> None) ;
        ]
      end in
    let shutdown () = Lwt_watcher.shutdown stopper in
    RPC_answer.return_stream { next ; shutdown }
  end ;

  gen_register0 Monitor_services.S.valid_blocks begin fun q () ->
    let block_stream, stopper = State.watcher state in
    let shutdown () = Lwt_watcher.shutdown stopper in
    let in_chains block =
      Lwt_list.map_p (Chain_directory.get_chain_id state) q#chains >>= function
      | [] -> Lwt.return_true
      | chains ->
          let chain_id = State.Block.chain_id block in
          Lwt.return (List.exists (Chain_id.equal chain_id) chains) in
    let in_protocols block =
      match q#protocols with
      | [] -> Lwt.return_true
      | protocols ->
          State.Block.predecessor block >>= function
          | None -> Lwt.return_false (* won't happen *)
          | Some pred ->
              State.Block.context pred >>= fun context ->
              Context.get_protocol context >>= fun protocol ->
              Lwt.return (List.exists (Protocol_hash.equal protocol) protocols) in
    let in_next_protocols block =
      match q#next_protocols with
      | [] -> Lwt.return_true
      | protocols ->
          State.Block.context block >>= fun context ->
          Context.get_protocol context >>= fun next_protocol ->
          Lwt.return (List.exists (Protocol_hash.equal next_protocol) protocols) in
    let stream =
      Lwt_stream.filter_map_s
        (fun block ->
           in_chains block >>= fun in_chains ->
           in_next_protocols block >>= fun in_next_protocols ->
           in_protocols block >>= fun in_protocols ->
           if in_chains && in_protocols && in_next_protocols then
             Lwt.return_some
               ((State.Block.chain_id block, State.Block.hash block),
                State.Block.header block)
           else
             Lwt.return_none)
        block_stream in
    let next () = Lwt_stream.get stream in
    RPC_answer.return_stream { next ; shutdown }
  end ;

  gen_register1 Monitor_services.S.heads begin fun chain q () ->
    (* TODO: when `chain = `Test`, should we reset then stream when
       the `testnet` change, or dias we currently do ?? *)
    Chain_directory.get_chain state chain >>= fun chain ->
    Validator.get_exn validator (State.Chain.id chain) >>= fun chain_validator ->
    let block_stream, stopper = Chain_validator.new_head_watcher chain_validator in
    Chain.head chain >>= fun head ->
    let shutdown () = Lwt_watcher.shutdown stopper in
    let in_next_protocols block =
      match q#next_protocols with
      | [] -> Lwt.return_true
      | protocols ->
          State.Block.context block >>= fun context ->
          Context.get_protocol context >>= fun next_protocol ->
          Lwt.return (List.exists (Protocol_hash.equal next_protocol) protocols) in
    let stream =
      Lwt_stream.filter_map_s
        (fun block ->
           in_next_protocols block >>= fun in_next_protocols ->
           if in_next_protocols then
             Lwt.return_some (State.Block.hash block, State.Block.header block)
           else
             Lwt.return_none)
        block_stream in
    let first_call = ref true in
    let next () =
      if !first_call then begin
        first_call := false ; Lwt.return_some (State.Block.hash head, State.Block.header head)
      end else
        Lwt_stream.get stream in
    RPC_answer.return_stream { next ; shutdown }
  end ;

  gen_register0 Monitor_services.S.protocols begin fun () () ->
    let stream, stopper = State.Protocol.watcher state in
    let shutdown () = Lwt_watcher.shutdown stopper in
    let next () = Lwt_stream.get stream in
    RPC_answer.return_stream { next ; shutdown }
  end ;

  !dir
