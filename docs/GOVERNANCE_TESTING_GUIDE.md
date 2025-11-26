# Aptos Governance and Framework Upgrade Testing Guide

This guide explains how to test Move VM version upgrades, gas schedule updates, and the complete governance proposal workflow on a local testnet.

## Table of Contents

1. [Overview](#overview)
2. [Local Testnet Setup](#local-testnet-setup)
3. [Governance Workflow](#governance-workflow)
4. [Framework Upgrade Testing](#framework-upgrade-testing)
5. [Gas Schedule Updates](#gas-schedule-updates)
6. [Complete Examples](#complete-examples)

---

## Overview

### Governance Architecture

Aptos uses an on-chain governance system where:
- **Validators** with staked tokens can create and vote on proposals
- **Proposals** contain executable scripts that modify on-chain configurations
- **Voting power** is derived from validator stake pool balances
- **Epochs** are time-based periods where configuration changes take effect

### Key Components

```
┌─────────────────────────────────────────────────────────┐
│                   Governance Flow                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. Create Proposal                                      │
│     ├─ Validator creates proposal with execution hash   │
│     ├─ Metadata (description, discussion URL)           │
│     └─ Minimum proposer stake required                  │
│                                                          │
│  2. Voting Period                                        │
│     ├─ Validators vote YES/NO                           │
│     ├─ Voting power based on stake                      │
│     └─ Duration: configured (default: ~7 days mainnet)  │
│                                                          │
│  3. Proposal Resolution                                  │
│     ├─ Check if quorum reached                          │
│     ├─ Check if YES > NO                                │
│     └─ Proposal state: SUCCEEDED or FAILED              │
│                                                          │
│  4. Execution                                            │
│     ├─ Execute proposal script                          │
│     ├─ Trigger reconfiguration                          │
│     └─ Changes take effect in next epoch                │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

---

## Local Testnet Setup

### Method 1: Using Smoke Tests (Recommended for Development)

The smoke test framework (`SwarmBuilder`) provides the easiest way to set up a multi-node local testnet with custom genesis configuration.

**Key files:**
- `testsuite/smoke-test/src/smoke_test_environment.rs` - SwarmBuilder
- `testsuite/smoke-test/src/upgrade.rs` - Example upgrade tests

**Example Setup:**

```rust
use aptos_forge::{Swarm, SwarmExt};
use crate::smoke_test_environment::SwarmBuilder;
use std::sync::Arc;

// Create a 5-node local testnet with custom governance config
let (mut env, _cli, _) = SwarmBuilder::new_local(5)
    .with_init_genesis_config(Arc::new(|genesis_config| {
        // Reduce voting duration for faster testing (default: 604800 seconds = 7 days)
        genesis_config.voting_duration_secs = 60; // 60 seconds for testing

        // Reduce epoch duration for faster reconfiguration
        genesis_config.epoch_duration_secs = 10; // 10 seconds

        // Set minimum voting threshold (in Octas, 1 APT = 100,000,000 Octas)
        genesis_config.min_voting_threshold = 10_000_000_000_000; // 100,000 APT

        // Set minimum proposer stake requirement
        genesis_config.required_proposer_stake = 100_000_000_000; // 1,000 APT

        // Enable new validators to join
        genesis_config.allow_new_validators = true;
    }))
    .with_init_genesis_stake(Arc::new(|_, genesis_stake_amount| {
        // Give each validator enough stake to meet proposal requirements
        *genesis_stake_amount = 200_000_000_000_000; // 2,000,000 APT
    }))
    .build_with_cli(0)
    .await;

// Get REST API endpoint
let url = env.aptos_public_info().url().to_string();

// Get root account private key
let private_key = env
    .aptos_public_info()
    .root_account()
    .private_key()
    .to_encoded_string()
    .unwrap();
```

### Method 2: Using Forge Framework

For more complex testing scenarios (e.g., version compatibility testing):

**Key files:**
- `testsuite/testcases/src/framework_upgrade.rs` - Framework upgrade test
- `testsuite/forge/src/interface/` - Forge interfaces

```rust
use aptos_forge::{NetworkTest, NetworkContextSynchronizer, Result};

pub struct FrameworkUpgrade;

#[async_trait]
impl NetworkTest for FrameworkUpgrade {
    async fn run<'a>(&self, ctx: NetworkContextSynchronizer<'a>) -> Result<()> {
        let mut ctx_locker = ctx.ctx.lock().await;
        let ctx = ctx_locker.deref_mut();

        // Access swarm
        let all_validators = ctx.swarm
            .read()
            .await
            .validators()
            .map(|v| v.peer_id())
            .collect::<Vec<_>>();

        // Your test logic here
        Ok(())
    }
}
```

### Method 3: Using aptos-node Directly

For manual testing:

```bash
# Build aptos-node
cargo build --release -p aptos-node

# Create a local testnet configuration
cd crates/aptos-genesis
cargo run --release -- generate-genesis \
    --local \
    --nodes 4 \
    --output-dir /tmp/aptos-local-testnet

# Start nodes
./target/release/aptos-node -f /tmp/aptos-local-testnet/0/node.yaml &
./target/release/aptos-node -f /tmp/aptos-local-testnet/1/node.yaml &
./target/release/aptos-node -f /tmp/aptos-local-testnet/2/node.yaml &
./target/release/aptos-node -f /tmp/aptos-local-testnet/3/node.yaml &
```

---

## Governance Workflow

### Step 1: Create a Governance Proposal

Governance proposals are created using the `aptos_governance` module.

**Move Code (aptos-framework):**

```move
// From aptos-move/framework/aptos-framework/sources/aptos_governance.move

/// Create a single-step proposal
public entry fun create_proposal(
    proposer: &signer,
    stake_pool: address,
    execution_hash: vector<u8>,
    metadata_location: vector<u8>,
    metadata_hash: vector<u8>,
)

/// Create a multi-step proposal
public entry fun create_proposal_v2(
    proposer: &signer,
    stake_pool: address,
    execution_hash: vector<u8>,
    metadata_location: vector<u8>,
    metadata_hash: vector<u8>,
    is_multi_step_proposal: bool,
)
```

**Using Aptos CLI:**

```bash
# Generate upgrade proposal script
aptos move governance generate-upgrade-proposal \
    --account 0x1 \
    --output proposal.move \
    --package-dir aptos-move/framework/aptos-framework

# Submit proposal
aptos governance propose \
    --pool-address <VALIDATOR_POOL_ADDRESS> \
    --script-path proposal.move \
    --metadata-url https://gist.github.com/yourname/proposal-metadata.json \
    --framework-local-dir aptos-move/framework/aptos-framework \
    --assume-yes
```

**Proposal Metadata Format:**

Create a JSON file at the metadata URL:

```json
{
    "title": "Framework Upgrade v1.8 -> v1.9",
    "description": "This proposal upgrades the Aptos framework to version 1.9, including new native functions and gas optimizations.",
    "source_code_url": "https://github.com/aptos-labs/aptos-core/pull/12345",
    "discussion_url": "https://github.com/aptos-labs/aptos-core/discussions/12346"
}
```

### Step 2: Vote on Proposal

**Using Move:**

```move
// From aptos-move/framework/aptos-framework/sources/aptos_governance.move

/// Vote with all voting power
public entry fun vote(
    voter: &signer,
    stake_pool: address,
    proposal_id: u64,
    should_pass: bool,
)

/// Vote with partial voting power (if feature enabled)
public entry fun partial_vote(
    voter: &signer,
    stake_pool: address,
    proposal_id: u64,
    voting_power: u64,
    should_pass: bool,
)
```

**Using Aptos CLI:**

```bash
# Vote YES on proposal
aptos governance vote \
    --pool-addresses <VALIDATOR_POOL_ADDRESS> \
    --proposal-id 1 \
    --yes \
    --assume-yes

# Vote NO on proposal
aptos governance vote \
    --pool-addresses <VALIDATOR_POOL_ADDRESS> \
    --proposal-id 1 \
    --no \
    --assume-yes

# View proposal status
aptos governance show-proposal \
    --proposal-id 1
```

### Step 3: Execute Proposal

Once voting period ends and proposal succeeds:

```bash
# Execute the proposal
aptos governance execute-proposal \
    --proposal-id 1 \
    --script-path proposal.move \
    --framework-local-dir aptos-move/framework/aptos-framework \
    --assume-yes
```

**Programmatically:**

```rust
use aptos_sdk::{
    transaction_builder::TransactionFactory,
    types::{transaction::Script, transaction::TransactionPayload},
};

// Read compiled script bytecode
let bytecode = std::fs::read("proposal.mv")?;

// Create execution transaction
let script = Script::new(bytecode, vec![], vec![
    TransactionArgument::U64(proposal_id),
]);

let payload = TransactionPayload::Script(script);
let transaction = transaction_factory
    .payload(payload)
    .sender(root_account)
    .sequence_number(seq_num)
    .build();
```

---

## Framework Upgrade Testing

### Generate Framework Upgrade Proposal

The `aptos-release-builder` crate provides tools for generating upgrade proposals.

**Using ReleaseConfig:**

```rust
use aptos_release_builder::{
    components::{
        framework::FrameworkReleaseConfig,
        ExecutionMode, Proposal, ProposalMetadata,
    },
    ReleaseConfig, ReleaseEntry,
};
use move_binary_format::file_format_common::VERSION_DEFAULT_LANG_V2;

let config = ReleaseConfig {
    name: "Framework Upgrade v1.9".to_string(),
    remote_endpoint: None,
    proposals: vec![
        Proposal {
            execution_mode: ExecutionMode::RootSigner,
            name: "framework".to_string(),
            metadata: ProposalMetadata {
                title: "Upgrade framework to v1.9".to_string(),
                description: "Adds new native functions".to_string(),
                source_code_url: "https://github.com/...".to_string(),
                discussion_url: "https://forum.aptoslabs.com/...".to_string(),
            },
            update_sequence: vec![
                ReleaseEntry::Framework(FrameworkReleaseConfig {
                    bytecode_version: VERSION_DEFAULT_LANG_V2,
                    git_hash: None,
                })
            ],
        },
    ],
};

// Generate proposal scripts
let output_dir = TempPath::new();
config.generate_release_proposal_scripts(output_dir.path()).await?;
```

### Complete Framework Upgrade Test

**File:** `testsuite/smoke-test/src/upgrade.rs`

```rust
#[tokio::test]
async fn test_upgrade_flow() {
    // 1. Setup local testnet
    let num_nodes = 5;
    let (mut env, _cli, _) = SwarmBuilder::new_local(num_nodes)
        .with_aptos_testnet()
        .build_with_cli(0)
        .await;

    let url = env.aptos_public_info().url().to_string();
    let private_key = env
        .aptos_public_info()
        .root_account()
        .private_key()
        .to_encoded_string()
        .unwrap();

    // 2. Generate upgrade proposal
    let upgrade_scripts_folder = TempPath::new();
    upgrade_scripts_folder.create_as_dir().unwrap();

    let config = aptos_release_builder::ReleaseConfig {
        name: "Framework Upgrade".to_string(),
        remote_endpoint: None,
        proposals: vec![
            Proposal {
                execution_mode: ExecutionMode::RootSigner,
                name: "framework".to_string(),
                metadata: ProposalMetadata::default(),
                update_sequence: vec![
                    ReleaseEntry::Framework(FrameworkReleaseConfig {
                        bytecode_version: VERSION_DEFAULT_LANG_V2,
                        git_hash: None,
                    })
                ],
            },
        ],
    };

    config
        .generate_release_proposal_scripts(upgrade_scripts_folder.path())
        .await
        .unwrap();

    // 3. Execute upgrade scripts
    let scripts = walkdir::WalkDir::new(upgrade_scripts_folder.path())
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension() == Some("move".as_ref()))
        .collect::<Vec<_>>();

    for script in scripts {
        // Execute each upgrade script
        execute_script(&env, script.path(), &url, &private_key).await?;

        // Increment sequence number
        env.aptos_public_info()
            .root_account()
            .increment_sequence_number();
    }

    // 4. Verify upgrade succeeded
    check_framework_version(&env).await?;
}
```

---

## Gas Schedule Updates

### Understanding Gas Versioning

**File:** `aptos-move/aptos-gas-schedule/src/ver.rs`

```rust
pub const RELEASE_V1_24: u64 = 37;
pub const RELEASE_V1_39: u64 = 43;
pub const LATEST_GAS_FEATURE_VERSION: u64 = RELEASE_V1_39;
```

### Generate Gas Schedule Update Proposal

```rust
use aptos_gas_schedule::{AptosGasParameters, InitialGasSchedule, ToOnChainGasSchedule};
use aptos_release_builder::components::gas::generate_gas_upgrade_proposal;
use aptos_types::on_chain_config::GasScheduleV2;

// Create custom gas parameters
let mut gas_parameters = AptosGasParameters::initial();

// Modify specific gas parameters
gas_parameters.vm.txn.max_transaction_size_in_bytes = GasQuantity::new(100_000_000);

// Create gas schedule
let gas_schedule = GasScheduleV2 {
    feature_version: aptos_gas_schedule::LATEST_GAS_FEATURE_VERSION,
    entries: gas_parameters.to_on_chain_gas_schedule(
        aptos_gas_schedule::LATEST_GAS_FEATURE_VERSION
    ),
};

// Generate proposal script
let (_, update_gas_script) = generate_gas_upgrade_proposal(
    None,              // old gas schedule (None = use current on-chain)
    &gas_schedule,     // new gas schedule
    true,              // is_testnet
    None,              // next_execution_hash (for multi-step)
    false,             // is_multi_step
)
.unwrap()
.pop()
.unwrap();

// Write script to file
std::fs::write("gas_update.move", update_gas_script)?;
```

### Execute Gas Update

```bash
aptos move run-script \
    --script-path gas_update.move \
    --framework-local-dir aptos-move/framework/aptos-framework \
    --sender-account 0xA550C18 \
    --url http://localhost:8080 \
    --private-key <ROOT_PRIVATE_KEY> \
    --assume-yes
```

---

## Complete Examples

### Example 1: Simple Smoke Test with Governance

```rust
use aptos_forge::Swarm;
use aptos_sdk::types::LocalAccount;
use std::sync::Arc;

#[tokio::test]
async fn test_governance_proposal_flow() {
    // 1. Setup testnet with 3 validators
    let (mut env, _, _) = SwarmBuilder::new_local(3)
        .with_init_genesis_config(Arc::new(|genesis_config| {
            genesis_config.voting_duration_secs = 60;
            genesis_config.epoch_duration_secs = 10;
            genesis_config.min_voting_threshold = 100_000_000_000;
            genesis_config.required_proposer_stake = 50_000_000_000;
        }))
        .with_init_genesis_stake(Arc::new(|_, stake| {
            *stake = 200_000_000_000_000;
        }))
        .build_with_cli(0)
        .await;

    let client = env.aptos_public_info().client();
    let mut root_account = env.aptos_public_info().root_account().clone();

    // 2. Create a simple proposal (e.g., update governance config)
    let proposal_script = create_governance_update_script();
    let script_hash = HashValue::sha3_256_of(&proposal_script);

    // Get first validator's stake pool
    let validator = env.validators().next().unwrap();
    let stake_pool = validator.peer_id();

    // Create proposal
    let create_proposal_txn = root_account
        .sign_with_transaction_builder(
            env.transaction_factory().payload(
                aptos_stdlib::aptos_governance_create_proposal(
                    stake_pool,
                    script_hash.to_vec(),
                    b"https://example.com/metadata.json".to_vec(),
                    metadata_hash.to_hex().as_bytes().to_vec(),
                )
            )
        );

    client.submit_and_wait(&create_proposal_txn).await?;

    // 3. Vote on proposal (need 2 out of 3 validators to vote YES)
    for validator in env.validators().take(2) {
        let voter = validator.account_private_key().unwrap().private_key();
        let stake_pool = validator.peer_id();

        let vote_txn = voter.sign_with_transaction_builder(
            env.transaction_factory().payload(
                aptos_stdlib::aptos_governance_vote(
                    stake_pool,
                    0, // proposal_id
                    true, // vote YES
                )
            )
        );

        client.submit_and_wait(&vote_txn).await?;
    }

    // 4. Wait for voting period to end
    tokio::time::sleep(Duration::from_secs(65)).await;

    // 5. Execute proposal
    let execute_txn = root_account
        .sign_with_transaction_builder(
            env.transaction_factory().payload(
                TransactionPayload::Script(Script::new(
                    proposal_script,
                    vec![],
                    vec![TransactionArgument::U64(0)], // proposal_id
                ))
            )
        );

    client.submit_and_wait(&execute_txn).await?;

    // 6. Trigger reconfiguration to apply changes
    let reconfig_txn = root_account
        .sign_with_transaction_builder(
            env.transaction_factory().entry_function(
                EntryFunction::new(
                    ModuleId::new(AccountAddress::ONE, Identifier::new("aptos_governance")?),
                    Identifier::new("reconfigure")?,
                    vec![],
                    vec![],
                )
            )
        );

    client.submit_and_wait(&reconfig_txn).await?;

    // Wait for new epoch
    tokio::time::sleep(Duration::from_secs(15)).await;

    // 7. Verify changes took effect
    verify_governance_config_updated(&client).await?;
}
```

### Example 2: Framework Upgrade with Governance (Full Flow)

**File reference:** `testsuite/testcases/src/framework_upgrade.rs`

This example shows the complete flow used in Forge tests:

```rust
#[async_trait]
impl NetworkTest for FrameworkUpgrade {
    async fn run<'a>(&self, ctx: NetworkContextSynchronizer<'a>) -> Result<()> {
        // Step 1: Setup
        let all_validators = ctx.swarm.read().await
            .validators()
            .map(|v| v.peer_id())
            .collect::<Vec<_>>();

        // Step 2: Get root account key
        let root_key_path = TempPath::new();
        std::fs::write(
            root_key_path.path(),
            bcs::to_bytes(&Ed25519PrivateKey::try_from(
                hex::decode(DEFAULT_ROOT_PRIV_KEY)?.as_ref(),
            )?)?,
        )?;

        // Step 3: Setup network config for proposal generation
        let network_info = aptos_release_builder::validate::NetworkConfig {
            endpoint: ctx.swarm.read().await
                .validators()
                .last()
                .unwrap()
                .rest_api_endpoint(),
            root_key_path: root_key_path.path().to_path_buf(),
            validator_account,
            validator_key,
            framework_git_rev: None,
        };

        // Mint tokens to validator for gas
        network_info.mint_to_validator(None).await?;

        // Step 4: Generate and execute upgrade proposal
        let release_config = aptos_release_builder::current_release_config();

        aptos_release_builder::validate::validate_config(
            release_config.clone(),
            network_info.clone(),
            None,
        ).await?;

        // Step 5: Generate traffic to test network stability
        let duration = Duration::from_secs(30);
        generate_traffic(ctx, &all_validators, duration).await?;

        // Step 6: Verify no forks occurred
        ctx.swarm.read().await.fork_check(epoch_duration).await?;

        Ok(())
    }
}
```

---

## Key Testing Considerations

### 1. Epoch Timing

Configuration changes only take effect at epoch boundaries:

```rust
// Trigger reconfiguration immediately (for testing)
aptos_stdlib::aptos_governance_force_end_epoch()

// Or trigger with DKG if randomness enabled
aptos_stdlib::aptos_governance_reconfigure()
```

### 2. Voting Power Calculation

```move
// From aptos_governance.move:731
public fun get_voting_power(pool_address: address): u64 {
    let (active, _, pending_active, pending_inactive) = stake::get_stake(pool_address);
    active + pending_active + pending_inactive
}
```

### 3. Proposal States

```move
const PROPOSAL_STATE_PENDING: u64 = 0;
const PROPOSAL_STATE_SUCCEEDED: u64 = 1;
const PROPOSAL_STATE_FAILED: u64 = 2;
```

### 4. Common Test Patterns

```rust
// Pattern 1: Wait for epoch change
async fn wait_for_epoch(swarm: &dyn Swarm, target_epoch: u64) -> Result<()> {
    loop {
        let current_epoch = swarm
            .validators()
            .next()
            .unwrap()
            .rest_client()
            .get_ledger_information()
            .await?
            .inner()
            .epoch;

        if current_epoch >= target_epoch {
            break;
        }

        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Ok(())
}

// Pattern 2: Check proposal status
async fn check_proposal_status(
    client: &RestClient,
    proposal_id: u64,
) -> Result<u64> {
    let response = client
        .view(
            &ViewRequest {
                function: "0x1::voting::get_proposal_state".parse()?,
                type_arguments: vec!["0x1::governance_proposal::GovernanceProposal".parse()?],
                arguments: vec![
                    serde_json::to_value("0x1")?,
                    serde_json::to_value(proposal_id.to_string())?,
                ],
            },
            None,
        )
        .await?
        .inner();

    Ok(response[0].as_str().unwrap().parse()?)
}
```

---

## Useful Commands

### Check Governance State

```bash
# List all proposals
aptos governance list-proposals

# Show specific proposal
aptos governance show-proposal --proposal-id 1

# Verify proposal script matches on-chain
aptos governance verify-proposal \
    --proposal-id 1 \
    --script-path proposal.move
```

### Check Validator State

```bash
# Get validator info
aptos node show-validator-info --account-address <POOL_ADDRESS>

# Get voting power
aptos account lookup-address <ACCOUNT_ADDRESS>
```

### Monitor Epochs

```bash
# Get current epoch
curl http://localhost:8080/v1/ | jq '.epoch'

# Watch epoch changes
watch -n 1 'curl -s http://localhost:8080/v1/ | jq .epoch'
```

---

## Troubleshooting

### Issue: Proposal voting fails with "insufficient stake lockup"

**Solution:** Ensure the validator's stake lockup period is longer than the proposal's voting duration:

```rust
genesis_config.voting_duration_secs = 60;
// Stake lockup must be > voting_duration_secs
stake::lock_up_stake(validator, 100); // Lock for 100 seconds
```

### Issue: Proposal execution fails with "proposal not resolved"

**Solution:** Wait for the voting period to end and ensure quorum is reached:

```bash
# Check proposal state
aptos governance show-proposal --proposal-id 1

# If still in voting period, wait or fast-forward time in tests:
timestamp::update_global_time_for_test(current_time + voting_duration + 1);
```

### Issue: Configuration changes don't take effect

**Solution:** Ensure reconfiguration is triggered and wait for epoch boundary:

```rust
// Trigger reconfiguration
aptos_stdlib::aptos_governance_reconfigure(&framework_signer);

// Wait for new epoch
tokio::time::sleep(Duration::from_secs(epoch_duration + 5)).await;
```

---

## Additional Resources

### Key Source Files

1. **Governance Implementation**
   - `aptos-move/framework/aptos-framework/sources/aptos_governance.move` - Main governance logic
   - `aptos-move/framework/aptos-framework/sources/voting.move` - Voting mechanism
   - `crates/aptos/src/governance/mod.rs` - CLI governance commands

2. **Release Builder**
   - `aptos-move/aptos-release-builder/src/lib.rs` - Proposal generation
   - `aptos-move/aptos-release-builder/src/components/` - Framework, gas, feature flags

3. **Testing Framework**
   - `testsuite/smoke-test/src/upgrade.rs` - Upgrade smoke tests
   - `testsuite/testcases/src/framework_upgrade.rs` - Framework upgrade Forge test
   - `testsuite/smoke-test/src/smoke_test_environment.rs` - SwarmBuilder

4. **Gas Scheduling**
   - `aptos-move/aptos-gas-schedule/src/ver.rs` - Gas versions
   - `aptos-move/aptos-gas-schedule/src/gas_schedule/` - Gas parameters

### Documentation

- [Aptos Governance Documentation](https://aptos.dev/concepts/governance)
- [Framework Release Process](https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/aptos-release-builder/README.md)
- [Testing Guide](https://github.com/aptos-labs/aptos-core/blob/main/testsuite/README.md)

---

## Summary

To test Move VM upgrades and governance on a local testnet:

1. **Setup:** Use `SwarmBuilder` to create a multi-node testnet with custom governance config
2. **Create Proposal:** Generate upgrade scripts using `aptos-release-builder`
3. **Vote:** Have validators vote on the proposal using their stake pools
4. **Execute:** After voting period, execute the proposal script
5. **Reconfigure:** Trigger epoch transition to apply changes
6. **Verify:** Check that the upgrade was successful and the network is healthy

The key is understanding that configuration changes are epoch-based, requiring reconfiguration to take effect. Testing should account for epoch timing and ensure sufficient voting power to reach quorum.
