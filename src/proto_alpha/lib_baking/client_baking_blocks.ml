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

type block_info = {
  hash: Block_hash.t ;
  chain_id: Chain_id.t ;
  predecessor: Block_hash.t ;
  fitness: MBytes.t list ;
  timestamp: Time.t ;
  protocol: Protocol_hash.t ;
  next_protocol: Protocol_hash.t ;
  level: Level.t ;
}

let raw_info cctxt ?(chain = `Main) hash header =
  let block = `Hash (hash, 0) in
  Shell_services.Chain.chain_id cctxt ~chain () >>=? fun chain_id ->
  Shell_services.Blocks.protocols
    cctxt ~chain ~block () >>=? fun { current_protocol = protocol ;
                                      next_protocol } ->
  Alpha_block_services.metadata cctxt
    ~chain ~block () >>=? fun { protocol_data = { level } } ->
  let { Tezos_base.Block_header.predecessor ; fitness ; timestamp ; _ } =
    header.Tezos_base.Block_header.shell in
  return { hash ; chain_id ; predecessor ; fitness ;
           timestamp ; protocol ; next_protocol ; level }

let info cctxt ?(chain = `Main) block =
  Shell_services.Blocks.hash cctxt ~chain ~block () >>=? fun hash ->
  Shell_services.Blocks.Header.shell_header
    cctxt ~chain ~block () >>=? fun shell  ->
  Shell_services.Blocks.Header.raw_protocol_data
    cctxt ~chain ~block () >>=? fun protocol_data ->
  raw_info cctxt ~chain hash { shell ; protocol_data }

let monitor_valid_blocks cctxt ?chains ?protocols ?next_protocols () =
  Shell_services.Monitor.valid_blocks cctxt
    ?chains ?protocols ?next_protocols () >>=? fun (block_stream, _stop) ->
  return (Lwt_stream.map_s
            (fun ((chain, block), header) ->
               raw_info cctxt ~chain:(`Hash chain) block header)
            block_stream)

let monitor_heads cctxt ?next_protocols chain =
  Monitor_services.heads
    cctxt ?next_protocols chain >>=? fun (block_stream, _stop) ->
  return (Lwt_stream.map_s
            (fun (block, header) -> raw_info cctxt ~chain block header)
            block_stream)

let blocks_from_current_cycle cctxt ?(chain = `Main) block ?(offset = 0l) () =
  Shell_services.Blocks.hash cctxt ~chain ~block () >>=? fun hash ->
  Alpha_block_services.metadata
    cctxt ~chain ~block () >>=? fun { protocol_data = { level } } ->
  Alpha_services.Helpers.levels_in_current_cycle
    cctxt ~offset (chain, block) >>=? fun (first, last) ->
  let length = Int32.to_int (Raw_level.diff level.level first) in
  Shell_services.Blocks.list cctxt ~heads:[hash] ~length () >>=? fun blocks ->
  let blocks =
    List.remove
      (length - (Int32.to_int (Raw_level.diff last first)))
      (List.hd blocks) in
  if Raw_level.(level.level = last) then
    return (hash :: blocks)
  else
    return blocks
