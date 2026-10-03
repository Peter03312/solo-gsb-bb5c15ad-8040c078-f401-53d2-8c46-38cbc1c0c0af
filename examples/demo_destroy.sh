#!/usr/bin/env bash
# 历史版本原文销毁端到端示例：
#   发布版本 1（脱敏快照 + 令牌）并修订出版本 2 ->
#   标记受控并对版本 1 提交待审申请、再驳回一个申请（覆盖申请各状态）->
#   鉴权与明确拒绝（缺密钥 401/未知记录 404/未知版本 404/空白理由 422）->
#   首次销毁版本 1：原子清除版本原文与该版本全部申请冻结原文（状态/区间保留）->
#   重复销毁回放首次时间与理由（repeated=true，不再改写）->
#   销毁后：版本 1 直接发布/受控提交/待审批准均 409，待审仍可驳回 ->
#   其他版本（版本 2）修订与发布不受影响 ->
#   既有脱敏快照/令牌/额度/审计/公开读取保持原约定，公开响应不透露销毁状态
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

step "1. 创建记录、发布版本 1（令牌上限 3 次），再修订出版本 2"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
RID=$(echo "${CREATE}" | jq -r .record_id)
PUB1=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 3}')
SID1=$(echo "${PUB1}" | jq -r .snapshot_id)
TOK1=$(echo "${PUB1}" | jq -r .token)
curl -sS -X PUT "${BASE_URL}/records/${RID}" "${AUTH[@]}" -d '{
  "base_version": 1,
  "text": "患者李四，联系方式已变更。",
  "intervals": [{"start": 2, "end": 4}]
}' >/dev/null
echo "记录 ${RID}: 版本1快照 ${SID1}（3 次额度），当前版本 2"

step "2. 标记受控；对版本 1 提交一个待审申请、再提交并驳回一个申请"
curl -sS -X PUT "${BASE_URL}/records/${RID}/controlled" "${AUTH[@]}" | jq .
SUBMIT_PENDING=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}')
PENDING_REQ=$(echo "${SUBMIT_PENDING}" | jq -r .request_id)
SUBMIT_REJECT=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}')
REJECT_REQ=$(echo "${SUBMIT_REJECT}" | jq -r .request_id)
curl -sS -X POST "${BASE_URL}/publish-requests/${REJECT_REQ}/reject" \
  -u "bob:${BOB_PW}" -H 'Content-Type: application/json' -d '{"reason":"演示驳回留痕"}' \
  | jq '{request_id, status, reviewed_by}'
echo "待审申请: ${PENDING_REQ}；终态（驳回）申请: ${REJECT_REQ}"

step "3. 明确拒绝：缺密钥 401、未知记录 404、未知版本 404、空白理由 422"
printf '缺服务密钥: HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${RID}/versions/1/destroy" \
  -H 'Content-Type: application/json' -d '{"reason":"x"}')"
UNKNOWN="00000000-0000-0000-0000-000000000000"
printf '未知记录:   HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${UNKNOWN}/versions/1/destroy" "${AUTH[@]}" -d '{"reason":"x"}')"
printf '未知版本:   HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${RID}/versions/999/destroy" "${AUTH[@]}" -d '{"reason":"x"}')"
printf '空白理由:   HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${RID}/versions/1/destroy" "${AUTH[@]}" -d '{"reason":"   "}')"

step "4. 首次销毁版本 1：返回销毁时间与理由，repeated=false"
DESTROY=$(curl -sS -X POST "${BASE_URL}/records/${RID}/versions/1/destroy" "${AUTH[@]}" \
  -d '{"reason":"保留期满，依规销毁版本 1 原文"}')
echo "${DESTROY}" | jq .
DESTROYED_AT=$(echo "${DESTROY}" | jq -r .destroyed_at)

step "5. 重复销毁（不同理由/空理由）回放首次结果，repeated=true，不再改写"
curl -sS -X POST "${BASE_URL}/records/${RID}/versions/1/destroy" "${AUTH[@]}" \
  -d '{"reason":"试图覆盖的另一个理由"}' \
  | jq --arg first "${DESTROYED_AT}" -e \
    '{record_id, version: .version, destroyed_at, reason, repeated}
     | .repeated == true and .destroyed_at == $first
       and (.reason | contains("保留期满"))'
curl -sS -X POST "${BASE_URL}/records/${RID}/versions/1/destroy" "${AUTH[@]}" -d '{}' \
  | jq '{version: .version, destroyed_at, reason, repeated}'

step "6. 销毁后：版本 1 直接发布 / 受控提交 / 待审批准 均 409；申请状态仍保留"
printf '直接发布:     HTTP %s\n' "$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" -d '{"version":1}')"
printf '受控申请提交: HTTP %s\n' "$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version":1}')"
printf '待审申请批准: HTTP %s\n' "$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "${BASE_URL}/publish-requests/${PENDING_REQ}/approve" -u "bob:${BOB_PW}")"
echo "待审申请详情（仍为 pending，响应不含原文）:"
curl -sS "${BASE_URL}/publish-requests/${PENDING_REQ}" -u "alice:${ALICE_PW}" \
  | jq '{request_id, version: .version, status, reviewed_by, snapshot_id}'

step "7. 待审申请仍可驳回（不依赖原文）"
curl -sS -X POST "${BASE_URL}/publish-requests/${PENDING_REQ}/reject" \
  -u "bob:${BOB_PW}" -H 'Content-Type: application/json' \
  | jq '{request_id, version: .version, status, reviewed_by}'

step "8. 其他版本不受影响：版本 2 发布与继续修订（出版本 3）正常"
PUB2=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d '{"version": 2}')
SID2=$(echo "${PUB2}" | jq -r .snapshot_id)
TOK2=$(echo "${PUB2}" | jq -r .token)
curl -sS -X PUT "${BASE_URL}/records/${RID}" "${AUTH[@]}" -d '{
  "base_version": 2,
  "text": "销毁旧版本后的新版本三原文。",
  "intervals": [{"start": 0, "end": 3}]
}' | jq '{record_id, version: .version}'
echo "版本 2 公开读取（脱敏快照，不透露销毁状态）:"
curl -sS "${BASE_URL}/public/snapshots/${SID2}?token=${TOK2}" \
  | jq '{record_id, version: .version, status}'

step "9. 既有脱敏快照/令牌/额度/审计保持原约定（版本 1 快照继续可读、继续计数）"
echo "销毁后用版本 1 旧令牌公开读取（200，结构不变）:"
curl -sS "${BASE_URL}/public/snapshots/${SID1}?token=${TOK1}" | jq '{record_id, version: .version, status}'
echo "令牌计数仍按既有规则递增（销毁前未使用，当前 1）:"
curl -sS "${BASE_URL}/tokens/${TOK1}" "${AUTH[@]}" \
  | jq '{snapshot_id, version: .version, max_reads, reads_used, remaining_reads, active}'
echo "版本 1 快照成功读取审计事件数（销毁前后照常追加）:"
curl -sS "${BASE_URL}/snapshots/${SID1}/read-events?start=2000-01-01T00:00:00Z&end=2100-01-01T00:00:00Z" \
  "${AUTH[@]}" | jq '.events | length'

step "10. 销毁后不存在可用于重新签发的原文副本：版本 1 再次发布仍 409"
printf '版本 1 再次直接发布: HTTP %s（已发布的是脱敏快照，原文已不可得）\n' \
  "$(code -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" -d '{"version":1}')"

printf '\n\033[1m历史版本原文销毁演示完成。\033[0m\n'
