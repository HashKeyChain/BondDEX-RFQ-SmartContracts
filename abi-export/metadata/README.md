# ABI Export Metadata

This directory stores versioned ABI release metadata for the BondDEX contracts-first
delivery pipeline.

Expected generated outputs:

- `metadata.json`: release version, commit, chain ids, proxy/implementation map
- `event-interface.md`: additive or breaking event-surface notes
- chain-specific address manifests under `../addresses/`
- contract ABI JSON files under `../abi/`

The canonical source of truth remains Foundry build output in `contracts/out/`.
