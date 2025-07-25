#!/bin/bash
# Error test cases for L1 to L2 bridge and call
# This script tests various failure scenarios for bridge and call operations

# Don't exit on error - we're testing failures!
set +e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Helper functions
print_test() {
    echo -e "${PURPLE}[TEST]${NC} $1"
}

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

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
EXPECTED_FAILURES=0

# Function to record test result
record_test_result() {
    local test_name=$1
    local expected_to_fail=$2
    local actual_result=$3  # 0 = success, 1 = failure
    
    ((TOTAL_TESTS++))
    
    if [ "$expected_to_fail" = "true" ]; then
        if [ "$actual_result" = "1" ]; then
            print_success " Test '$test_name' failed as expected"
            ((PASSED_TESTS++))
            ((EXPECTED_FAILURES++))
        else
            print_error " Test '$test_name' succeeded but was expected to fail"
            ((FAILED_TESTS++))
        fi
    else
        if [ "$actual_result" = "0" ]; then
            print_success " Test '$test_name' passed"
            ((PASSED_TESTS++))
        else
            print_error " Test '$test_name' failed unexpectedly"
            ((FAILED_TESTS++))
        fi
    fi
}

echo ""
print_info "========== L1 TO L2 BRIDGE AND CALL ERROR TEST SUITE =========="
print_info "This suite tests error conditions for bridge and call operations"
echo ""

# Test 1: Bridge with invalid call data
print_test "Test 1: Bridge with malformed call data"
# Create invalid call data (not properly encoded)
INVALID_CALL_DATA="0x1234567890"  # Random hex, not a valid function call

# First approve
cast send $AGG_ERC20_L1 \
    "approve(address,uint256)" \
    $POLYGON_ZKEVM_BRIDGE_L1 10 \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 > /dev/null 2>&1

RESULT=$(cast send $POLYGON_ZKEVM_BRIDGE_L1 \
    "bridgeAsset(uint32,address,uint256,address,bool,bytes)" \
    $CHAIN_ID_AGGLAYER_1 \
    $ACCOUNT_ADDRESS_1 \
    10 \
    $AGG_ERC20_L1 \
    true \
    $INVALID_CALL_DATA \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 \
    --json 2>&1 || echo "FAILED")

# Bridge should succeed even with invalid call data (validation happens on claim)
if [[ "$RESULT" == *"FAILED"* ]] || [[ "$RESULT" == *"revert"* ]]; then
    record_test_result "Bridge with malformed call data" false 1
else
    record_test_result "Bridge with malformed call data" false 0
fi
echo ""

# Test 2: Bridge without approval (with call data)
print_test "Test 2: Bridge and call without token approval"
CALL_DATA=$(cast abi-encode "transfer(address,uint256)" $ACCOUNT_ADDRESS_2 5)
UNAPPROVED_AMOUNT=999999999

RESULT=$(cast send $POLYGON_ZKEVM_BRIDGE_L1 \
    "bridgeAsset(uint32,address,uint256,address,bool,bytes)" \
    $CHAIN_ID_AGGLAYER_1 \
    $ACCOUNT_ADDRESS_1 \
    $UNAPPROVED_AMOUNT \
    $AGG_ERC20_L1 \
    true \
    $CALL_DATA \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 \
    --json 2>&1 || echo "FAILED")

if [[ "$RESULT" == *"FAILED"* ]] || [[ "$RESULT" == *"revert"* ]] || [[ "$RESULT" == *"insufficient allowance"* ]]; then
    record_test_result "Bridge and call without approval" true 1
else
    record_test_result "Bridge and call without approval" true 0
fi
echo ""

# Test 3: Bridge with excessive call data
print_test "Test 3: Bridge with excessive call data size"
# Create very large call data (>65535 bytes)
LARGE_CALL_DATA=$(printf '0x%.0s00' {1..70000})

# Approve first
cast send $AGG_ERC20_L1 \
    "approve(address,uint256)" \
    $POLYGON_ZKEVM_BRIDGE_L1 1 \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 > /dev/null 2>&1

RESULT=$(cast send $POLYGON_ZKEVM_BRIDGE_L1 \
    "bridgeAsset(uint32,address,uint256,address,bool,bytes)" \
    $CHAIN_ID_AGGLAYER_1 \
    $ACCOUNT_ADDRESS_1 \
    1 \
    $AGG_ERC20_L1 \
    true \
    $LARGE_CALL_DATA \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 \
    --json 2>&1 || echo "FAILED")

if [[ "$RESULT" == *"FAILED"* ]] || [[ "$RESULT" == *"MetadataTooLarge"* ]] || [[ "$RESULT" == *"revert"* ]]; then
    record_test_result "Excessive call data" true 1
else
    record_test_result "Excessive call data" true 0
fi
echo ""

# Test 4: Call to dangerous function
print_test "Test 4: Bridge with call to self-destruct"
# Encode a call to selfdestruct (if contract had it)
# selfdestruct(address)
DANGEROUS_CALL=$(cast abi-encode "selfdestruct(address)" $ACCOUNT_ADDRESS_1)

# Approve first
cast send $AGG_ERC20_L1 \
    "approve(address,uint256)" \
    $POLYGON_ZKEVM_BRIDGE_L1 5 \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 > /dev/null 2>&1

RESULT=$(cast send $POLYGON_ZKEVM_BRIDGE_L1 \
    "bridgeAsset(uint32,address,uint256,address,bool,bytes)" \
    $CHAIN_ID_AGGLAYER_1 \
    $ACCOUNT_ADDRESS_1 \
    5 \
    $AGG_ERC20_L1 \
    true \
    $DANGEROUS_CALL \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 \
    --json 2>&1 || echo "FAILED")

# Bridge should succeed (call execution validation happens on L2)
if [[ "$RESULT" == *"FAILED"* ]] || [[ "$RESULT" == *"revert"* ]]; then
    record_test_result "Bridge with dangerous call" false 1
else
    record_test_result "Bridge with dangerous call" false 0
fi
echo ""

# Test 5: Double claim with call data
print_test "Test 5: Attempting to claim the same bridge-and-call twice"
print_info "Creating a valid bridge and call..."

# Approve and bridge with call data
BRIDGE_AMOUNT=8
CALL_DATA=$(cast abi-encode "transfer(address,uint256)" $ACCOUNT_ADDRESS_2 2)

cast send $AGG_ERC20_L1 \
    "approve(address,uint256)" \
    $POLYGON_ZKEVM_BRIDGE_L1 $BRIDGE_AMOUNT \
    --private-key $PRIVATE_KEY_1 \
    --rpc-url $RPC_1 > /dev/null 2>&1

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

print_info "Bridge TX: $BRIDGE_TX"
print_info "Waiting for global exit root propagation (20s)..."
sleep 20

# Get bridge info
BRIDGE_INFO=$(aggsandbox show bridges --network-id 1 | extract_json)
MATCHING_BRIDGE=$(echo $BRIDGE_INFO | jq -r --arg tx "$BRIDGE_TX" '.bridges[] | select(.tx_hash == $tx)')

if [ -z "$MATCHING_BRIDGE" ] || [ "$MATCHING_BRIDGE" = "null" ]; then
    print_error "Could not find bridge transaction in API"
    record_test_result "Double bridge-and-call claim prevention" false 1
    echo ""
else
    DEPOSIT_COUNT=$(echo $MATCHING_BRIDGE | jq -r '.deposit_count')
    METADATA=$(echo $MATCHING_BRIDGE | jq -r '.metadata')
    
    # Get proof
    PROOF_DATA=$(aggsandbox show claim-proof --network-id 1 --leaf-index $DEPOSIT_COUNT --deposit-count $DEPOSIT_COUNT | extract_json)
    MAINNET_EXIT_ROOT=$(echo $PROOF_DATA | jq -r '.l1_info_tree_leaf.mainnet_exit_root')
    ROLLUP_EXIT_ROOT=$(echo $PROOF_DATA | jq -r '.l1_info_tree_leaf.rollup_exit_root')
    
    # First claim (should succeed)
    print_info "Attempting first claim..."
    CLAIM1=$(cast send $POLYGON_ZKEVM_BRIDGE_L2 \
        "claimAsset(uint256,bytes32,bytes32,uint32,address,uint32,address,uint256,bytes)" \
        $DEPOSIT_COUNT \
        $MAINNET_EXIT_ROOT \
        $ROLLUP_EXIT_ROOT \
        1 \
        $AGG_ERC20_L1 \
        $CHAIN_ID_AGGLAYER_1 \
        $ACCOUNT_ADDRESS_1 \
        $BRIDGE_AMOUNT \
        $METADATA \
        --private-key $PRIVATE_KEY_1 \
        --rpc-url $RPC_2 \
        --json 2>&1)
    
    if echo "$CLAIM1" | jq -e '.transactionHash' > /dev/null 2>&1; then
        print_info "First claim succeeded"
        sleep 3
        
        # Second claim (should fail)
        print_info "Attempting second claim of same deposit..."
        CLAIM2=$(cast send $POLYGON_ZKEVM_BRIDGE_L2 \
            "claimAsset(uint256,bytes32,bytes32,uint32,address,uint32,address,uint256,bytes)" \
            $DEPOSIT_COUNT \
            $MAINNET_EXIT_ROOT \
            $ROLLUP_EXIT_ROOT \
            1 \
            $AGG_ERC20_L1 \
            $CHAIN_ID_AGGLAYER_1 \
            $ACCOUNT_ADDRESS_1 \
            $BRIDGE_AMOUNT \
            $METADATA \
            --private-key $PRIVATE_KEY_1 \
            --rpc-url $RPC_2 \
            --json 2>&1 || echo "FAILED")
        
        if [[ "$CLAIM2" == *"FAILED"* ]] || [[ "$CLAIM2" == *"AlreadyClaimed"* ]] || [[ "$CLAIM2" == *"revert"* ]]; then
            record_test_result "Double bridge-and-call claim prevention" true 1
        else
            record_test_result "Double bridge-and-call claim prevention" true 0
        fi
    else
        print_info "First claim failed (might be GlobalExitRootInvalid)"
        record_test_result "Double bridge-and-call claim prevention" false 1
    fi
fi
echo ""

# Test Summary
echo ""
print_info "========== BRIDGE AND CALL ERROR TEST SUMMARY =========="
print_info "Total tests run: $TOTAL_TESTS"
print_success "Tests passed: $PASSED_TESTS"
if [ $FAILED_TESTS -gt 0 ]; then
    print_error "Tests failed: $FAILED_TESTS"
else
    print_info "Tests failed: $FAILED_TESTS"
fi
print_info "Expected failures caught: $EXPECTED_FAILURES"

echo ""
print_info "Error conditions tested:"
print_info "1.  Bridge with malformed call data"
print_info "2.  Bridge and call without approval"
print_info "3.  Excessive call data"
print_info "4.  Bridge with dangerous call"
print_info "5.  Double bridge-and-call claim prevention"

echo ""
echo ""
if [ $FAILED_TESTS -eq 0 ]; then
    print_success "All bridge and call error handling tests completed successfully! "
    exit 0
else
    print_error "Some tests did not behave as expected"
    exit 1
fi