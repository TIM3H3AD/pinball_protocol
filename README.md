# Pinball Protocol

## About

The `pinball_protocol` (`pb`) engine offers a suite of cryptocurrency tokenization and distribution tools using a hybrid `L1/L2` protocol.

The first `pb` TX was:

https://openchains.info/coin/triangles/tx/fc390f1fa6e897a255d9580992ef5a9ebf3811ca27eca5ba4b1eb3209ec92ede

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
