#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PSV1_SOURCE_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_DIR/install.sh"
trap - ERR

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
RM_MANAGER_DIR="$TEST_TMP"

fail(){ echo "[FAIL] $*" >&2; exit 1; }
pass(){ echo "[ OK ] $*"; }
assert_jq(){
  local json="$1" filter="$2" label="$3"
  jq -e "$filter" >/dev/null 2>&1 <<<"$json" || fail "$label"
  pass "$label"
}

test_relay_profiles(){
  local single pool cfg
  single='[{"uuid":"exit-1","name":"NL","ip":"203.0.113.10","suffix":"aaa111","bridgeTag":"BRIDGE_IN-aaa111","bridgeInboundUuid":"in-1","bridgeProfileUuid":"profile-1","bridgeUuid":"11111111-1111-4111-8111-111111111111","userName":"bridge_aaa111"}]'
  cfg=$(rm_cascade_relay_config_json turboflare relay-tag "$single" roundRobin)
  assert_jq "$cfg" '.inbounds[0].port==7443 and .inbounds[0].listen=="127.0.0.1"' "single: relay inbound is local :7443"
  assert_jq "$cfg" '[.outbounds[] | select(.protocol=="vless")] | length==1' "single: exactly one VLESS_EXIT"
  assert_jq "$cfg" 'any(.routing.rules[]; .network=="tcp,udp" and .outboundTag=="VLESS_EXIT")' "single: catch-all routes to VLESS_EXIT"
  assert_jq "$cfg" '(.routing.balancers // []) | length==0' "single: no balancer"

  pool=$(jq -nc --argjson one "$single" '$one + [{uuid:"exit-2",name:"DE",ip:"203.0.113.11",suffix:"bbb222",bridgeTag:"BRIDGE_IN-bbb222",bridgeInboundUuid:"in-2",bridgeProfileUuid:"profile-2",bridgeUuid:"22222222-2222-4222-8222-222222222222",userName:"bridge_bbb222"}]')
  cfg=$(rm_cascade_relay_config_json vk relay-tag "$pool" random)
  assert_jq "$cfg" '[.outbounds[] | select(.protocol=="vless")] | length==2' "pool: both VLESS_EXIT outbounds exist"
  assert_jq "$cfg" '.routing.balancers[0].tag=="EXIT_POOL" and .routing.balancers[0].strategy.type=="random"' "pool: requested balancer strategy"
  assert_jq "$cfg" 'any(.routing.rules[]; .network=="tcp,udp" and .balancerTag=="EXIT_POOL")' "pool: catch-all routes to EXIT_POOL"
}

TEST_SCENARIO=""
USER_FILE="$TEST_TMP/user.json"
SQUAD_FILE="$TEST_TMP/squad.json"
NODE_FILE="$TEST_TMP/node.json"

rm_internal_squads_json(){
  jq -nc '[{uuid:"squad-1",name:"PSV1-CASCADE",info:{inboundsCount:1}}]'
}

rm_nodes_json(){
  jq -c '[.]' < "$NODE_FILE"
}

rm_api(){
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  case "$TEST_SCENARIO:$method:$path" in
    user-create:GET:/api/users/by-username/bridge_create)
      if [[ -s "$USER_FILE" ]]; then jq -nc --argjson u "$(cat "$USER_FILE")" '{response:$u}'; else echo '{"response":null}'; fi
      ;;
    user-create:POST:/api/users)
      jq -nc --argjson b "$body" '{uuid:"user-1",username:$b.username,vlessUuid:$b.vlessUuid,activeInternalSquads:[{uuid:$b.activeInternalSquads[0],name:"PSV1-CASCADE"}]}' > "$USER_FILE"
      jq -nc --argjson b "$body" '{response:{id:101,shortUuid:"short",vlessUuid:$b.vlessUuid}}'
      ;;
    user-patch:GET:/api/users/by-username/bridge_existing)
      jq -nc --argjson u "$(cat "$USER_FILE")" '{response:$u}'
      ;;
    user-patch:PATCH:/api/users)
      jq --argjson b "$body" '.activeInternalSquads=($b.activeInternalSquads | map({uuid:.,name:"PSV1-CASCADE"}))' "$USER_FILE" > "$USER_FILE.next"
      mv "$USER_FILE.next" "$USER_FILE"
      jq -nc --arg v "$(jq -r '.vlessUuid' "$USER_FILE")" '{response:{id:102,vlessUuid:$v}}'
      ;;
    squad:GET:/api/internal-squads/squad-1)
      jq -nc --argjson s "$(cat "$SQUAD_FILE")" '{response:$s}'
      ;;
    squad:PATCH:/api/internal-squads)
      jq -nc --argjson b "$body" '{uuid:$b.uuid,name:$b.name,inbounds:($b.inbounds|map({uuid:.}))}' > "$SQUAD_FILE"
      echo '{"response":{"eventSent":true}}'
      ;;
    node:GET:/api/nodes/node-1)
      jq -nc --argjson n "$(cat "$NODE_FILE")" '{response:$n}'
      ;;
    node:PATCH:/api/nodes)
      jq --argjson b "$body" '.configProfile={activeConfigProfileUuid:$b.configProfile.activeConfigProfileUuid,activeInbounds:($b.configProfile.activeInbounds|map({uuid:.}))}' "$NODE_FILE" > "$NODE_FILE.next"
      mv "$NODE_FILE.next" "$NODE_FILE"
      echo '{"response":{"eventSent":true}}'
      ;;
    postcheck:GET:/api/nodes/relay-node)
      echo '{"response":{"uuid":"relay-node","name":"RU","address":"198.51.100.2","configProfile":{"activeConfigProfileUuid":"relay-profile","activeInbounds":[{"uuid":"relay-inbound"}]}}}'
      ;;
    postcheck:GET:/api/nodes/exit-node)
      echo '{"response":{"uuid":"exit-node","name":"NL","address":"203.0.113.10","configProfile":{"activeConfigProfileUuid":"exit-profile","activeInbounds":[{"uuid":"bridge-inbound"}]}}}'
      ;;
    postcheck:GET:/api/internal-squads/squad-1)
      echo '{"response":{"uuid":"squad-1","name":"PSV1-CASCADE","inbounds":[{"uuid":"relay-inbound"},{"uuid":"bridge-inbound"}]}}'
      ;;
    postcheck:GET:/api/config-profiles/relay-profile)
      echo '{"response":{"uuid":"relay-profile","name":"cascade","config":{"inbounds":[],"outbounds":[{"tag":"VLESS_EXIT","protocol":"vless","settings":{"vnext":[{"address":"203.0.113.10","port":8888,"users":[{"id":"55555555-5555-4555-8555-555555555555"}]}]}}],"routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"VLESS_EXIT"}]}}}}'
      ;;
    postcheck:GET:/api/users/by-username/bridge_postcheck)
      echo '{"response":{"uuid":"user-postcheck","username":"bridge_postcheck","vlessUuid":"55555555-5555-4555-8555-555555555555","activeInternalSquads":[{"uuid":"squad-1","name":"PSV1-CASCADE"}]}}'
      ;;
    *) echo '{}' ;;
  esac
}

test_bridge_user_short_create_response(){
  local got desired='33333333-3333-4333-8333-333333333333'
  TEST_SCENARIO=user-create
  : > "$USER_FILE"
  got=$(rm_api_ensure_bridge_user token bridge_create "$desired" squad-1)
  [[ "$got" == "$desired" ]] || fail "create: shortened response must be verified by GET"
  pass "create: shortened response verified by factual squad membership"
}

test_bridge_user_short_patch_response(){
  local got desired='44444444-4444-4444-8444-444444444444'
  TEST_SCENARIO=user-patch
  jq -nc --arg v "$desired" '{uuid:"user-2",username:"bridge_existing",vlessUuid:$v,activeInternalSquads:[]}' > "$USER_FILE"
  got=$(rm_api_ensure_bridge_user token bridge_existing ignored squad-1)
  [[ "$got" == "$desired" ]] || fail "patch: shortened response must be verified by GET"
  assert_jq "$(cat "$USER_FILE")" 'any(.activeInternalSquads[]; .uuid=="squad-1")' "patch: user is factually in PSV1-CASCADE"
}

test_squad_summary_does_not_drop_inbounds(){
  local got
  TEST_SCENARIO=squad
  jq -nc '{uuid:"squad-1",name:"PSV1-CASCADE",inbounds:[{uuid:"old-inbound"}]}' > "$SQUAD_FILE"
  got=$(rm_api_ensure_named_squad token PSV1-CASCADE new-inbound relay-inbound)
  [[ "$got" == squad-1 ]] || fail "squad: upsert failed"
  assert_jq "$(cat "$SQUAD_FILE")" '[.inbounds[].uuid] | sort == ["new-inbound","old-inbound","relay-inbound"]' "squad: detail merge preserves old and adds required inbounds"
}

test_node_assignment_uses_read_after_write(){
  TEST_SCENARIO=node
  jq -nc '{uuid:"node-1",name:"Relay",address:"198.51.100.2",configProfile:{activeConfigProfileUuid:null,activeInbounds:[]}}' > "$NODE_FILE"
  rm_api_assign_node token node-1 profile-new inbound-new || fail "node: assignment was not confirmed"
  assert_jq "$(cat "$NODE_FILE")" '.configProfile.activeConfigProfileUuid=="profile-new" and any(.configProfile.activeInbounds[]; .uuid=="inbound-new")' "node: shortened PATCH response verified by GET"
}

test_incompatible_bridge_is_rejected(){
  local good bad
  good=$(rm_cascade_bridge_inbound_json BRIDGE_IN-good)
  bad=$(jq -c '.protocol="socks"' <<<"$good")
  rm_bridge_inbound_is_compatible "$good" || fail "bridge compatibility: valid inbound rejected"
  if rm_bridge_inbound_is_compatible "$bad"; then fail "bridge compatibility: invalid inbound accepted"; fi
  pass "bridge compatibility: conflicting :8888 inbound is rejected"
}

test_api_postconditions(){
  local exits
  TEST_SCENARIO=postcheck
  exits='[{"uuid":"exit-node","name":"NL","ip":"203.0.113.10","suffix":"post","bridgeTag":"BRIDGE_IN-post","bridgeInboundUuid":"bridge-inbound","bridgeProfileUuid":"exit-profile","bridgeUuid":"55555555-5555-4555-8555-555555555555","userName":"bridge_postcheck"}]'
  rm_verify_cascade_api_postconditions token relay-node relay-profile relay-inbound squad-1 "$exits" || fail "post-check: valid cascade state rejected"
  pass "post-check: all six API conditions accepted"
}

test_relay_profiles
test_bridge_user_short_create_response
test_bridge_user_short_patch_response
test_squad_summary_does_not_drop_inbounds
test_node_assignment_uses_read_after_write
test_incompatible_bridge_is_rejected
test_api_postconditions
echo "All cascade tests passed."
