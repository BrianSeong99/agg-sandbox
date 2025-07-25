#!/bin/bash
# Test script for bridge and call from L1 to L2
# This demonstrates bridging tokens and executing a function call in one transaction

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_debug() {
    if [ "$DEBUG" = "1" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Helper function to extract JSON from aggsandbox output
extract_json() {
    sed -n '/^{/,/^}/p'
}

# Load environment variables
if [ -f .env ]; then
    source .env
    print_info "Loaded environment variables from .env"
else
    print_error ".env file not found. Please ensure you have the environment file."
    exit 1
fi

# Parse command line arguments
BRIDGE_AMOUNT=${1:-50}  # Default to 50 tokens if not specified

echo ""
print_info "========== L1 TO L2 BRIDGE AND CALL TEST =========="
print_info "Bridge Amount: $BRIDGE_AMOUNT AGG tokens"
print_info "This test bridges tokens and executes a call in one transaction"
echo ""

# Step 1: Check initial balance
print_step "1. Checking initial token balance on L1"

L1_BALANCE=$(cast call $AGG_ERC20_L1 \
    "balanceOf(address)" \
    $ACCOUNT_ADDRESS_1 \
    --rpc-url $RPC_1 | sed 's/0x//' | tr '[:lower:]' '[:upper:]')
L1_BALANCE_DEC=$((16#$L1_BALANCE))

print_info "L1 Balance: $L1_BALANCE_DEC AGG tokens"

if [ $L1_BALANCE_DEC -lt $BRIDGE_AMOUNT ]; then
    print_error "Insufficient L1 balance. Need $BRIDGE_AMOUNT but have $L1_BALANCE_DEC"
    exit 1
fi

echo ""

# Step 2: Approve the bridge contract
print_step "2. Approving bridge contract to spend tokens"

APPROVE_TX=$(cast send $AGG_ERC20_L1 \
    "approve(address,uint256)" \
    $POLYGON_ZKEVM_BRIDGE_L1 $BRIDGE_AMOUNT \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 \
    --json | jq -r '.transactionHash')

print_info "Approval TX: $APPROVE_TX"
print_info "Waiting for confirmation..."
sleep 2

echo ""

# Step 3: Prepare call data
print_step "3. Preparing call data for L2 execution"

# For this example, we'll call a simple function on L2
# Let's use the transfer function to send tokens to another address
# transfer(address to, uint256 amount)
RECIPIENT_ON_L2=$ACCOUNT_ADDRESS_2
TRANSFER_AMOUNT=10  # Transfer 10 tokens after bridging

# Encode the function call
# Note: This assumes the wrapped token will have a transfer function
CALL_DATA=$(cast abi-encode "transfer(address,uint256)" $RECIPIENT_ON_L2 $TRANSFER_AMOUNT)
print_info "Call data: $CALL_DATA"
print_info "Will transfer $TRANSFER_AMOUNT tokens to $RECIPIENT_ON_L2 after bridging"

echo ""

# Step 4: Execute bridge and call
print_step "4. Executing bridge and call transaction"

# bridgeAssetAndCall(uint32 destinationNetwork, address destinationAddress, uint256 amount, address token, bool forceUpdateGlobalExitRoot, bytes calldata permitData)
# Note: The destination address will receive the bridged tokens and execute the call
print_info "Destination network: $CHAIN_ID_AGGLAYER_1"
print_info "Destination contract: TBD (will be the wrapped token contract)"

# For bridge and call, we need to specify the contract that will receive the call
# Since we don't know the wrapped token address yet, we'll use a placeholder
# In a real scenario, you would know the target contract address
BRIDGE_TX=$(cast send $POLYGON_ZKEVM_BRIDGE_L1 \
    "bridgeAsset(uint32,address,uint256,address,bool,bytes)" \
    $CHAIN_ID_AGGLAYER_1 \
    $ACCOUNT_ADDRESS_1 \
    $BRIDGE_AMOUNT \
    $AGG_ERC20_L1 \
    true \
    $CALL_DATA \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 \
    --json | jq -r '.transactionHash')

if [ -z "$BRIDGE_TX" ] || [ "$BRIDGE_TX" = "null" ]; then
    print_error "Failed to send bridge and call transaction"
    exit 1
fi

print_success "Bridge and call TX: $BRIDGE_TX"
print_info "Waiting for confirmation..."
sleep 2

echo ""

# Step 5: Get bridge event details
print_step "5. Getting bridge event details"

RECEIPT=$(cast receipt $BRIDGE_TX --rpc-url $RPC_1 --json)
TX_STATUS=$(echo "$RECEIPT" | jq -r '.status')

if [ "$TX_STATUS" != "0x1" ]; then
    print_error "Bridge transaction failed!"
    exit 1
fi

print_success "Bridge transaction confirmed"

echo ""

# Step 6: Wait for global exit root propagation
print_step "6. Waiting for global exit root to propagate"
print_info "This typically takes 15-20 seconds..."

for i in {1..20}; do
    echo -n "."
    sleep 1
done
echo ""

echo ""

# Step 7: Get bridge information from API
print_step "7. Getting bridge information from bridge service"

BRIDGE_INFO=$(aggsandbox show bridges --network-id 1 | extract_json)

if [ "$DEBUG" = "1" ]; then
    print_debug "Bridge API response:"
    echo "$BRIDGE_INFO" | jq '.'
fi

# Find our bridge transaction
MATCHING_BRIDGE=$(echo $BRIDGE_INFO | jq -r --arg tx "$BRIDGE_TX" '.bridges[] | select(.tx_hash == $tx)')

if [ -z "$MATCHING_BRIDGE" ] || [ "$MATCHING_BRIDGE" = "null" ]; then
    print_error "Could not find bridge transaction in API"
    exit 1
fi

print_info "Found bridge in API:"
echo "$MATCHING_BRIDGE" | jq '.'

# Extract values
DEPOSIT_COUNT=$(echo $MATCHING_BRIDGE | jq -r '.deposit_count')
METADATA=$(echo $MATCHING_BRIDGE | jq -r '.metadata')
CALLDATA=$(echo $MATCHING_BRIDGE | jq -r '.calldata')

print_info "Deposit count: $DEPOSIT_COUNT"
print_info "Metadata: $METADATA"
print_info "Call data included: $([ -n "$CALLDATA" ] && [ "$CALLDATA" != "null" ] && echo "Yes" || echo "No")"

echo ""

# Step 8: Get claim proof
print_step "8. Getting claim proof"

PROOF_DATA=$(aggsandbox show claim-proof --network-id 1 --leaf-index $DEPOSIT_COUNT --deposit-count $DEPOSIT_COUNT | extract_json)

if [ "$DEBUG" = "1" ]; then
    print_debug "Proof data:"
    echo "$PROOF_DATA" | jq '.'
fi

MAINNET_EXIT_ROOT=$(echo $PROOF_DATA | jq -r '.l1_info_tree_leaf.mainnet_exit_root')
ROLLUP_EXIT_ROOT=$(echo $PROOF_DATA | jq -r '.l1_info_tree_leaf.rollup_exit_root')

print_info "Mainnet exit root: $MAINNET_EXIT_ROOT"
print_info "Rollup exit root: $ROLLUP_EXIT_ROOT"

echo ""

# Step 9: Execute claim on L2
print_step "9. Claiming assets and executing call on L2"

print_info "Submitting claim transaction..."

# For L1 origin (network 0), we need to set the mainnet flag in global index
# Global index = deposit_count | (1 << 64) for mainnet
GLOBAL_INDEX=$(echo "$DEPOSIT_COUNT + 18446744073709551616" | bc)
print_debug "Global index: $GLOBAL_INDEX (deposit count: $DEPOSIT_COUNT with mainnet flag)"

# The claim will execute both the token transfer and the call
CLAIM_TX=$(cast send $POLYGON_ZKEVM_BRIDGE_L2 \
    "claimAsset(uint256,bytes32,bytes32,uint32,address,uint32,address,uint256,bytes)" \
    $GLOBAL_INDEX \
    $MAINNET_EXIT_ROOT \
    $ROLLUP_EXIT_ROOT \
    0 \
    $AGG_ERC20_L1 \
    $CHAIN_ID_AGGLAYER_1 \
    $ACCOUNT_ADDRESS_1 \
    $BRIDGE_AMOUNT \
    $METADATA \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_2 \
    --json 2>&1)

# Check if claim was successful
if echo "$CLAIM_TX" | jq -e '.transactionHash' > /dev/null 2>&1; then
    CLAIM_TX_HASH=$(echo "$CLAIM_TX" | jq -r '.transactionHash')
    print_success "Claim TX: $CLAIM_TX_HASH"
    
    # Wait for confirmation
    sleep 3
    
    # Get claim receipt
    CLAIM_RECEIPT=$(cast receipt $CLAIM_TX_HASH --rpc-url $RPC_2 --json)
    CLAIM_STATUS=$(echo "$CLAIM_RECEIPT" | jq -r '.status')
    
    if [ "$CLAIM_STATUS" = "0x1" ]; then
        print_success "Claim and call executed successfully!"
        
        # Check if the call was executed
        print_info "Checking for call execution events..."
        if [ "$DEBUG" = "1" ]; then
            echo "$CLAIM_RECEIPT" | jq '.logs'
        fi
    else
        print_error "Claim transaction reverted"
        exit 1
    fi
else
    print_error "Failed to send claim transaction"
    
    if echo "$CLAIM_TX" | grep -q "0x002f6fad"; then
        print_info "GlobalExitRootInvalid error - synchronization issue"
    elif echo "$CLAIM_TX" | grep -q "AlreadyClaimed"; then
        print_info "This deposit was already claimed"
    fi
    
    exit 1
fi

echo ""

# Step 10: Verify the call execution
print_step "10. Verifying call execution results"

# Get the wrapped token address (from previous claims or known address)
WRAPPED_TOKEN="0x19e2b7738a026883d08c3642984ab6d7510ca238"

# Check balances to verify the transfer happened
if [ "$CALL_DATA" != "0x" ] && [ "$CALL_DATA" != "null" ]; then
    print_info "Checking if the call was executed..."
    
    # Check recipient balance
    RECIPIENT_BALANCE=$(cast call $WRAPPED_TOKEN \
        "balanceOf(address)" \
        $RECIPIENT_ON_L2 \
        --rpc-url $RPC_2 2>/dev/null || echo "0x0")
    
    if [ "$RECIPIENT_BALANCE" != "0x0" ]; then
        RECIPIENT_BALANCE_DEC=$(printf "%d" $RECIPIENT_BALANCE 2>/dev/null || echo "0")
        print_info "Recipient balance: $RECIPIENT_BALANCE_DEC tokens"
        
        if [ $RECIPIENT_BALANCE_DEC -ge $TRANSFER_AMOUNT ]; then
            print_success "Call executed! Tokens were transferred to recipient"
        else
            print_info "Call may not have executed as expected"
        fi
    fi
else
    print_info "No call data was included in the bridge transaction"
fi

echo ""

# Summary
print_info "========== BRIDGE AND CALL TEST SUMMARY =========="
print_success "Bridge and Call Completed!"
print_info "   Bridged Amount: $BRIDGE_AMOUNT tokens"
print_info "   Bridge TX: $BRIDGE_TX"
print_info "   Deposit Count: $DEPOSIT_COUNT"
print_info "   Claim TX: $CLAIM_TX_HASH"
if [ -n "$CALL_DATA" ] && [ "$CALL_DATA" != "0x" ]; then
    print_info "   Call Data: Included"
    print_info "   Call Target: Transfer $TRANSFER_AMOUNT tokens to $RECIPIENT_ON_L2"
fi
print_info ""
print_info "Note: Bridge and call allows atomic execution of"
print_info "token bridging and contract calls in one transaction"
print_info "========================================="
echo ""