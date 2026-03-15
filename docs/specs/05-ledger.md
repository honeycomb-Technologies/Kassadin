# Spec 05: Multi-Era Ledger Validation

## Overview

The ledger validates every transaction and block across all eras (Byron → Conway). Each era adds rules; the Hard Fork Combinator dispatches to the correct era. This spec defines the exact validation rules, CDDL wire format per era, and Plutus integration.

---

## 1. Block Structure (Per Era)

### Hard Fork Combinator Wrapping
```
cardano_block = [era_id: uint, era_block]
  era_id: 0=Byron, 1=Shelley, 2=Allegra, 3=Mary, 4=Alonzo, 5=Babbage, 6=Conway
```

### Shelley+ Block Structure
```
block = [header, transaction_bodies, transaction_witness_sets, auxiliary_data_map, ?invalid_transactions]

header = [header_body, kes_signature]

header_body = [
    block_number: uint,           // 0
    slot: uint,                   // 1
    prev_hash: hash32 / nil,      // 2 (nil for genesis)
    issuer_vkey: vkey,            // 3
    vrf_vkey: vrf_vkey,           // 4
    vrf_result: [bytes, bytes],   // 5 (output, proof) -- Babbage+ single result
    block_body_size: uint,        // 6
    block_body_hash: hash32,      // 7
    operational_cert: [            // 8
        hot_vkey, seq_number, kes_period, cold_sig
    ],
    protocol_version: [uint, uint] // 9
]
```

### Transaction Body Fields (Conway, superset)
```
transaction_body = {
    0: set<transaction_input>,         // inputs
    1: [*transaction_output],          // outputs
    2: coin,                           // fee
    ?3: uint,                          // time-to-live (Shelley only)
    ?4: [*certificate],                // certificates
    ?5: withdrawals,                   // reward withdrawals
    ?7: auxiliary_data_hash,           // hash of auxiliary data
    ?8: uint,                          // validity interval start (Allegra+)
    ?9: mint,                          // minting (Mary+)
    ?11: script_data_hash,             // script integrity (Alonzo+)
    ?13: set<transaction_input>,       // collateral inputs (Alonzo+)
    ?14: required_signers,             // required signer hashes (Alonzo+)
    ?15: network_id,                   // network ID (Alonzo+)
    ?16: transaction_output,           // collateral return (Babbage+)
    ?17: coin,                         // total collateral (Babbage+)
    ?18: set<transaction_input>,       // reference inputs (Babbage+)
    ?19: voting_procedures,            // governance votes (Conway)
    ?20: proposal_procedures,          // governance proposals (Conway)
    ?21: coin,                         // current treasury value (Conway)
    ?22: positive_coin,                // donation (Conway)
}
```

### Transaction Output (Per Era)
```
Shelley:  [address, amount: coin]
Mary:     [address, amount: value]
Alonzo:   [address, amount: value, ?datum_hash: hash32]
Babbage+: {0: address, 1: value, ?2: datum_option, ?3: script_ref}
  datum_option = [0, hash32]         // datum hash
               / [1, #6.24(bytes .cbor plutus_data)]  // inline datum
  script_ref = #6.24(bytes .cbor script)
```

### Transaction Witness Set
```
transaction_witness_set = {
    ?0: [*vkeywitness],               // VKey witnesses
    ?1: [*native_script],             // Native scripts
    ?2: [*bootstrap_witness],         // Byron bootstrap witnesses
    ?3: [*plutus_v1_script],          // Plutus V1 scripts (Alonzo+)
    ?4: [*plutus_data],               // Datums (Alonzo+)
    ?5: redeemers,                    // Redeemers (Alonzo+)
    ?6: [*plutus_v2_script],          // Plutus V2 scripts (Babbage+)
    ?7: [*plutus_v3_script],          // Plutus V3 scripts (Conway+)
}

vkeywitness = [vkey, signature]
bootstrap_witness = [public_key, signature, chain_code, attributes]
```

---

## 2. UTXO Transition Rule (UTXOW)

### Fundamental Invariant: Preservation of Value
```
consumed(pp, utxo, txbody) == produced(pp, poolParams, txbody)

consumed = balance(txins ◁ utxo)    // sum of input values
         + withdrawals_balance        // sum of reward withdrawals
         + key_refunds                // deposits being returned

produced = balance(outputs)           // sum of output values
         + txfee                      // transaction fee
         + total_deposits             // new deposits (key reg, pool reg)
```

### Validation Predicates (all must hold)

**Structural checks (all eras):**
1. `|txins| ≥ 1` — at least one input
2. `txfee ≥ minFee(pp, txsize)` — fee covers minimum
3. `txins ⊆ dom(utxo)` — all inputs exist in UTxO
4. `preservation_of_value` — see above
5. `∀ output: coin(output) ≥ minCoinPerOutput(pp, output)` — min output value
6. `txsize ≤ maxTxSize(pp)` — transaction size limit
7. `∀ output: serializedSize(output) ≤ maxValSize(pp)` — (Alonzo+)

**Validity intervals:**
8. `invalidBefore ≤ currentSlot` — (Allegra+, if present)
9. `currentSlot < invalidHereafter` — (Shelley TTL, or Allegra+ if present)

**Witness checks:**
10. All required VKey witnesses present (for inputs, certificates, withdrawals)
11. All VKey signatures valid
12. All native scripts evaluate to true (for script-locked inputs)

**Alonzo+ additional checks:**
13. Script data hash matches computed hash
14. All Plutus scripts have redeemers
15. All redeemers have corresponding scripts
16. Collateral inputs are VKey-controlled (not script-locked)
17. Total collateral ≥ `txfee × collateralPercent / 100`
18. |collateral_inputs| ≤ maxCollateralInputs

### Fee Calculation
```
minFee = pp.minFeeFixed + (txSerializedSize × pp.minFeePerByte)
       + (refScriptSize × pp.minFeeRefScriptCoinPerByte)  // Conway+
```

### Min UTxO Value
```
Shelley/Mary:  minUTxOValue (protocol parameter, typically 1 ADA)
Alonzo:        coinsPerUTxOWord × (utxoEntrySizeWithoutVal + ⌈serializedSize(val) / 8⌉)
Babbage+:      coinsPerUTxOByte × (160 + serializedSize(output))
```

### UTxO State Update
```
utxo' = (utxo \ txins) ∪ {(TxId(tx), ix) → out | (ix, out) ∈ outputs}
```

---

## 3. Certificate Processing (DELEGS Rule)

### Processing Order
Certificates are processed in order within a transaction.

### Shelley Certificates
| Tag | Certificate | Effect |
|-----|-------------|--------|
| 0 | StakeRegistration(cred) | Add cred to active set, charge deposit |
| 1 | StakeDeregistration(cred) | Remove from active set, refund deposit |
| 2 | StakeDelegation(cred, pool) | Update delegation map: cred → pool |
| 3 | PoolRegistration(params) | Register/update pool with params |
| 4 | PoolRetirement(pool, epoch) | Schedule retirement at epoch |
| 5 | GenesisKeyDelegation | Only during bootstrap |
| 6 | MIR(pot, rewards) | Move instantaneous rewards |

### Conway Certificates (Additional)
| Tag | Certificate | Effect |
|-----|-------------|--------|
| 7 | RegDeposit(cred, deposit) | Register stake with explicit deposit |
| 8 | UnregDeposit(cred, refund) | Deregister with explicit refund |
| 9 | VoteDelegation(cred, drep) | Delegate voting to DRep |
| 10 | StakeVoteDelegation(cred, pool, drep) | Delegate both |
| 11 | StakeRegDelegation(cred, pool, deposit) | Register + delegate |
| 12 | VoteRegDelegation(cred, drep, deposit) | Register + vote delegate |
| 13 | StakeVoteRegDelegation(cred, pool, drep, deposit) | All three |
| 14 | CommitteeAuth(cold, hot) | Authorize committee hot key |
| 15 | CommitteeResign(cold, anchor?) | Resign from committee |
| 16 | DRepRegistration(cred, deposit, anchor?) | Register as DRep |
| 17 | DRepDeregistration(cred, refund) | Deregister DRep |
| 18 | DRepUpdate(cred, anchor?) | Update DRep metadata |

---

## 4. Epoch Boundary Processing

At each epoch boundary:

### Reward Calculation
```
1. total_rewards = monetary_expansion(reserve) + tx_fees_collected
2. treasury_cut = total_rewards × tau
3. pool_rewards = total_rewards - treasury_cut

4. For each pool:
   a. apparent_performance = blocks_produced / expected_blocks
   b. if apparent_performance ≥ 1/a0_threshold:
      optimal_reward = pool_rewards × sigma_prime / (1 + a0)
   c. pool_reward = optimal_reward × apparent_performance
   d. leader_reward = pool_reward × (margin + (1-margin) × pledge_ratio)
   e. member_rewards = pool_reward - leader_reward
      distributed proportionally to delegators

5. rewards_map = {reward_account → reward_amount}
```

### Stake Snapshot Pipeline
```
Epoch N boundary:
  go_snapshot = set_snapshot        // used for leader election in epoch N
  set_snapshot = mark_snapshot      // will be used in epoch N+1
  mark_snapshot = current_delegation_state  // snapshot now
```

### Nonce Update
```
At epoch boundary:
  previous_epoch_nonce = epoch_nonce
  epoch_nonce = candidate_nonce ⊕ last_epoch_block_nonce ⊕ extra_entropy
  evolving_nonce = neutral_nonce
  candidate_nonce = evolving_nonce  // will evolve through next epoch
```

---

## 5. Plutus Script Execution

### Integration with plutuz

plutuz handles UPLC evaluation. We need to build the integration layer:

### Phase-1 Validation (Before Script Execution)
1. All script hashes resolve to known scripts (in witnesses or reference inputs)
2. All redeemers have matching scripts
3. Script versions compatible with current era
4. ExUnits within transaction and block limits
5. Collateral sufficient

### Phase-2 Validation (Script Execution)
```
For each redeemer in transaction:
  1. Identify script (from witnesses or reference input)
  2. Construct ScriptContext:
     - TxInfo: inputs, reference_inputs, outputs, fee, mint, certs,
               withdrawals, validity_range, signatories, redeemers,
               datums, tx_id, votes, proposals, treasury, donation
     - ScriptPurpose: Spending(txin) / Minting(policy) / Certifying(cert) / Rewarding(acct) / Voting(voter) / Proposing(idx)
     - Datum (for spending scripts)
  3. Encode ScriptContext as PlutusData
  4. Call plutuz:
     script_args = [datum, redeemer, script_context]  // V1/V2
     script_args = [script_context]                    // V3 (merged)
     result = plutuz.evalVersion(allocator, applied_script, semantics_variant)
  5. If result is error → Phase-2 failure (consume collateral)
  6. Track consumed ExUnits
```

### Script Data Hash Computation
```
script_data_hash = Blake2b-256(
    redeemers_cbor ||
    datums_cbor ||
    language_views_cbor
)

Where:
  redeemers_cbor = canonical CBOR encoding of redeemers
  datums_cbor = canonical CBOR encoding of datums (empty bytes if none)
  language_views_cbor = canonical CBOR map {language_tag => cost_model_encoding}

Language view encoding per version:
  PlutusV1: indefinite-length list of cost coefficients as bytes
  PlutusV2: definite-length list of cost coefficients
  PlutusV3: definite-length list of cost coefficients
```

### Cost Model Loading
```zig
pub fn loadCostModel(protocol_params: ProtocolParams, lang: Language) ?CostModel {
    // Protocol parameters contain: {0: [*int64], 1: [*int64], 2: [*int64]}
    // 0 = PlutusV1, 1 = PlutusV2, 2 = PlutusV3
    const coefficients = protocol_params.cost_models.get(lang) orelse return null;
    return CostModel.fromCoefficients(coefficients);
}
```

---

## 6. Governance (Conway)

### Governance Actions
```zig
pub const GovAction = union(enum) {
    parameter_change: struct {
        prev_action: ?GovActionId,
        updates: ProtocolParamUpdate,
        guardrails: ?ScriptHash,
    },
    hard_fork: struct {
        prev_action: ?GovActionId,
        new_version: ProtVer,
    },
    treasury_withdrawal: struct {
        withdrawals: HashMap(RewardAccount, Coin),
        guardrails: ?ScriptHash,
    },
    no_confidence: struct { prev_action: ?GovActionId },
    update_committee: struct {
        members_to_remove: HashSet(Credential),
        members_to_add: HashMap(Credential, EpochNo),
        quorum: UnitInterval,
    },
    new_constitution: struct {
        prev_action: ?GovActionId,
        constitution: Constitution,
    },
    info_action: void,
};
```

### Voting
```
voter types: CommitteeVoter, DRepVoter, StakePoolVoter
Each governance action requires approval from multiple bodies
Thresholds defined in protocol parameters (pool_voting_thresholds, drep_voting_thresholds)
```

### Enactment
Actions are enacted in order at epoch boundaries when they receive sufficient votes and survive the governance action lifetime.

---

## 7. Hard Fork Combinator

### Era Detection
The current era is determined by protocol parameters:
- Major protocol version indicates era
- Hard fork transitions happen at epoch boundaries
- Transition encoded in ledger state

### Multi-Era Dispatch
```zig
pub fn validateBlock(block_bytes: []const u8, ledger: *LedgerState) !void {
    const era = decodeEraTag(block_bytes);
    switch (era) {
        0 => validateByronBlock(block_bytes, ledger),
        1 => validateShelleyBlock(block_bytes, ledger),
        2 => validateAllegraBlock(block_bytes, ledger),
        3 => validateMaryBlock(block_bytes, ledger),
        4 => validateAlonzoBlock(block_bytes, ledger),
        5 => validateBabbageBlock(block_bytes, ledger),
        6 => validateConwayBlock(block_bytes, ledger),
        else => return error.UnknownEra,
    }
}
```

### Cross-Era Ledger State Migration
At hard fork boundaries, the ledger state must be translated:
- UTxO set format may change (e.g., TxOut gains datum field in Alonzo)
- Protocol parameters gain new fields
- Certificate types expand
- The HFC handles this via era-specific translation functions

---

## Test Requirements

1. **Per-era block parsing:** Decode 100 real blocks from each era (Byron through Conway)
2. **CBOR round-trip:** Encode → decode every block without byte changes
3. **UTxO rule:** Apply 1000 transactions, verify UTxO state hash matches Haskell
4. **Preservation of value:** Verify for every transaction in test set
5. **Certificate processing:** Apply all certificate types, verify delegation state
6. **Reward calculation:** Compute rewards at 10 epoch boundaries, compare with Haskell
7. **Plutus execution:** Run 100 Alonzo+ transactions with scripts, verify results match
8. **Script data hash:** Compute for 50 Alonzo+ transactions, compare with Haskell
9. **Hard fork transitions:** Replay mainnet across Shelley→Allegra, Allegra→Mary, etc.
10. **Conway governance:** Process governance proposals and votes from preprod
