# Pinball Protocol

`pinball_protocol.rb` is a standalone Ruby reference file that distills the core idea behind the Pinball tokenization engine.

It is not the full production system. This repo is meant to show the protocol shape clearly:

- issuer vault creation
- holder quiver creation
- primary claims
- peer-to-peer listing and fills
- protocol fees, royalties, and reserve math
- redeem flow
- explicit ledger events

The full production platform includes Rails models, wallet RPC, on-chain broadcast logic, media, UI, and other state handling that are intentionally left out here.

This repo is a compact public example of the design.
