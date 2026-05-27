#!/usr/bin/env bash
# Best-effort state recovery: do not fail CI when individual imports/removals fail.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra"

cd "${INFRA_DIR}"

NAME_PREFIX="${NAME_PREFIX:-abricot-tp3}"
VPC_CIDR="${VPC_CIDR:-10.42.0.0/16}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

if [[ -z "${TF_VAR_postgres_password:-}" && ! -f terraform.tfvars && ! -f terraform.tfvars.json ]]; then
  echo "Skipping existing-resource import recovery because postgres_password is not configured for Terraform."
  exit 0
fi

is_real_id() {
  local value="${1:-}"
  [[ -n "${value}" && "${value}" != "None" && "${value}" != "null" ]]
}

aws_text() {
  aws "$@" --output text 2>/dev/null || true
}

belongs_to_current_account() {
  local value="${1:-}"
  local arn_account

  if [[ "${value}" =~ ^arn:aws[^:]*:[^:]+:[^:]*:([0-9]{12}): ]]; then
    arn_account="${BASH_REMATCH[1]}"
    [[ "${arn_account}" == "${account_id:-}" ]]
    return
  fi

  return 0
}

state_attr() {
  local address="$1"
  local attr="$2"

  terraform state show -no-color "${address}" 2>/dev/null \
    | awk -F'= ' -v attr="${attr}" '
        $1 ~ "^[[:space:]]*" attr "[[:space:]]*$" {
          gsub(/"/, "", $2)
          print $2
          exit
        }
      '
}

state_id() {
  state_attr "$1" "id"
}

remove_state_if_attr_mismatch() {
  local address="$1"
  local attr="$2"
  local expected="$3"
  local current

  if ! is_real_id "${expected}"; then
    return 0
  fi

  current="$(state_attr "${address}" "${attr}")"
  if is_real_id "${current}" && [[ "${current}" != "${expected}" ]]; then
    echo "Removing stale state for ${address}: ${attr} ${current} != ${expected}"
    terraform state rm "${address}" >/dev/null 2>&1 || true
  fi
}

import_if_missing() {
  local address="$1"
  local import_id="$2"
  local current_id

  if ! is_real_id "${import_id}"; then
    return 0
  fi

  if ! belongs_to_current_account "${import_id}"; then
    echo "Skipping ${address}: import id belongs to a different AWS account (${import_id})"
    return 0
  fi

  if terraform state show "${address}" >/dev/null 2>&1; then
    current_id="$(state_id "${address}")"
    if [[ "${current_id}" == "${import_id}" ]]; then
      return 0
    fi

    echo "Replacing stale state for ${address}: ${current_id} -> ${import_id}"
    terraform state rm "${address}" >/dev/null 2>&1 || true
  fi

  echo "Importing ${address} from ${import_id}"
  terraform import -input=false "${address}" "${import_id}" || true
}

import_if_absent() {
  local address="$1"
  local import_id="$2"

  if ! is_real_id "${import_id}"; then
    return 0
  fi

  if ! belongs_to_current_account "${import_id}"; then
    echo "Skipping ${address}: import id belongs to a different AWS account (${import_id})"
    return 0
  fi

  if terraform state show "${address}" >/dev/null 2>&1; then
    return 0
  fi

  echo "Importing ${address} from ${import_id}"
  terraform import -input=false "${address}" "${import_id}" || true
}

import_or_forget_vpc_scoped() {
  local address="$1"
  local import_id="$2"
  local expected_vpc_id="$3"

  if is_real_id "${import_id}"; then
    import_if_missing "${address}" "${import_id}"
    return 0
  fi

  remove_state_if_attr_mismatch "${address}" "vpc_id" "${expected_vpc_id}"
}

subnet_id_for_cidr() {
  local vpc_id="$1"
  local cidr="$2"

  aws_text ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=cidr-block,Values=${cidr}" \
    --query 'Subnets[0].SubnetId'
}

security_group_id_for_name() {
  local vpc_id="$1"
  local group_name="$2"

  aws_text ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${group_name}" \
    --query 'SecurityGroups[0].GroupId'
}

route_table_id_for_subnet() {
  local subnet_id="$1"

  if ! is_real_id "${subnet_id}"; then
    return 0
  fi

  aws_text ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=${subnet_id}" \
    --query 'RouteTables[0].RouteTableId'
}

nat_gateway_id_for_route_table() {
  local route_table_id="$1"

  if ! is_real_id "${route_table_id}"; then
    return 0
  fi

  aws_text ec2 describe-route-tables \
    --route-table-ids "${route_table_id}" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId | [0]"
}

nat_gateway_allocation_id() {
  local nat_gateway_id="$1"

  if ! is_real_id "${nat_gateway_id}"; then
    return 0
  fi

  aws_text ec2 describe-nat-gateways \
    --nat-gateway-ids "${nat_gateway_id}" \
    --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId'
}

route_destination_exists() {
  local route_table_id="$1"
  local destination="$2"

  if ! is_real_id "${route_table_id}"; then
    return 1
  fi

  local found
  found="$(aws_text ec2 describe-route-tables \
    --route-table-ids "${route_table_id}" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='${destination}'].DestinationCidrBlock | [0]")"

  is_real_id "${found}"
}

import_route_if_present() {
  local address="$1"
  local route_table_id="$2"
  local destination="$3"

  remove_state_if_attr_mismatch "${address}" "route_table_id" "${route_table_id}"

  if route_destination_exists "${route_table_id}" "${destination}"; then
    import_if_absent "${address}" "${route_table_id}_${destination}"
  else
    remove_state_if_attr_mismatch "${address}" "route_table_id" "${route_table_id}"
  fi
}

import_route_table_association() {
  local address="$1"
  local expected_subnet_id="$2"
  local expected_route_table_id="$3"

  if ! is_real_id "${expected_subnet_id}" || ! is_real_id "${expected_route_table_id}"; then
    remove_state_if_attr_mismatch "${address}" "subnet_id" "${expected_subnet_id}"
    return 0
  fi

  remove_state_if_attr_mismatch "${address}" "subnet_id" "${expected_subnet_id}"
  remove_state_if_attr_mismatch "${address}" "route_table_id" "${expected_route_table_id}"
  import_if_absent "${address}" "${expected_subnet_id}/${expected_route_table_id}"
}

lambda_function_name_for_key() {
  local key="$1"
  echo "${NAME_PREFIX}-${key//_/-}"
}

api_id_for_name() {
  aws_text apigatewayv2 get-apis \
    --query "Items[?Name=='${NAME_PREFIX}-http-api'].ApiId | [0]"
}

api_authorizer_id_for_name() {
  local api_id="$1"

  aws_text apigatewayv2 get-authorizers \
    --api-id "${api_id}" \
    --query "Items[?Name=='${NAME_PREFIX}-cognito-authorizer'].AuthorizerId | [0]"
}

api_integration_id_for_lambda() {
  local api_id="$1"
  local function_arn="$2"

  if ! is_real_id "${api_id}" || ! is_real_id "${function_arn}"; then
    return 0
  fi

  aws apigatewayv2 get-integrations --api-id "${api_id}" --output json 2>/dev/null \
    | jq -r --arg function_arn "${function_arn}" \
        '[.Items[]? | select((.IntegrationUri // "") | contains($function_arn)) | .IntegrationId][0] // empty' \
    || true
}

api_route_id_for_key() {
  local api_id="$1"
  local route_key="$2"

  if ! is_real_id "${api_id}"; then
    return 0
  fi

  aws apigatewayv2 get-routes --api-id "${api_id}" --output json 2>/dev/null \
    | jq -r --arg route_key "${route_key}" \
        '[.Items[]? | select(.RouteKey == $route_key) | .RouteId][0] // empty' \
    || true
}

terraform_api_routes() {
  awk '
    /^resource "aws_apigatewayv2_route"/ {
      name = $3
      gsub(/"/, "", name)
      in_block = 1
      has_count = 0
      route_key = ""
    }

    in_block && /^[[:space:]]*count[[:space:]]*=/ {
      has_count = 1
    }

    in_block && /^[[:space:]]*route_key[[:space:]]*=/ {
      route_key = $0
      sub(/^[^=]*=[[:space:]]*"/, "", route_key)
      sub(/"[[:space:]]*$/, "", route_key)
    }

    in_block && /^}/ {
      if (route_key != "") {
        address = "aws_apigatewayv2_route." name
        if (has_count) {
          address = address "[0]"
        }
        print address "\t" route_key
      }
      in_block = 0
    }
  ' main.tf
}

sns_topic_arn_for_name() {
  local topic_name="$1"

  aws sns list-topics --output json 2>/dev/null \
    | jq -r --arg suffix ":${topic_name}" '[.Topics[]?.TopicArn | select(endswith($suffix))][0] // empty' \
    || true
}

sqs_queue_url_for_name() {
  local queue_name="$1"

  aws_text sqs get-queue-url \
    --queue-name "${queue_name}" \
    --query QueueUrl
}

sqs_queue_arn_for_url() {
  local queue_url="$1"

  if ! is_real_id "${queue_url}"; then
    return 0
  fi

  aws_text sqs get-queue-attributes \
    --queue-url "${queue_url}" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn'
}

sns_subscription_arn_for_endpoint() {
  local topic_arn="$1"
  local protocol="$2"
  local endpoint="$3"

  if ! is_real_id "${topic_arn}" || ! is_real_id "${endpoint}"; then
    return 0
  fi

  aws sns list-subscriptions-by-topic --topic-arn "${topic_arn}" --output json 2>/dev/null \
    | jq -r --arg protocol "${protocol}" --arg endpoint "${endpoint}" \
        '[.Subscriptions[]? | select(.Protocol == $protocol and .Endpoint == $endpoint and .SubscriptionArn != "PendingConfirmation") | .SubscriptionArn][0] // empty' \
    || true
}

event_source_mapping_uuid() {
  local event_source_arn="$1"
  local function_name="$2"

  if ! is_real_id "${event_source_arn}" || ! is_real_id "${function_name}"; then
    return 0
  fi

  aws_text lambda list-event-source-mappings \
    --event-source-arn "${event_source_arn}" \
    --function-name "${function_name}" \
    --query 'EventSourceMappings[0].UUID'
}

lambda_permission_statement_id_for_api() {
  local function_name="$1"
  local source_arn="$2"

  if ! is_real_id "${function_name}" || ! is_real_id "${source_arn}"; then
    return 0
  fi

  aws lambda get-policy --function-name "${function_name}" --output json 2>/dev/null \
    | jq -r --arg source_arn "${source_arn}" '
        (.Policy | fromjson | .Statement[]?
          | select((.Principal | if type == "object" then .Service else . end) == "apigateway.amazonaws.com")
          | select(
              (.Condition.ArnLike."AWS:SourceArn" // "") == $source_arn
              or (.Condition.StringLike."AWS:SourceArn" // "") == $source_arn
            )
          | .Sid
        ) // empty
      ' \
    | head -n 1 \
    || true
}

echo "Importing existing Abricot resources into Terraform state when present"

account_id="$(aws_text sts get-caller-identity --query Account)"
if ! is_real_id "${account_id}"; then
  echo "Could not resolve current AWS account id; cannot rebuild Terraform state safely." >&2
  exit 1
fi

echo "Scrubbing state of resources from previous AWS accounts..."
for address in $(terraform state list 2>/dev/null || true); do
  id="$(terraform state show -no-color "${address}" 2>/dev/null | grep -E '^[[:space:]]*(id|arn)[[:space:]]*=' | head -n 1 | awk -F'"' '{print $2}')"
  if [[ "${id}" =~ arn:aws[^:]*:[^:]+:[^:]*:([0-9]{12}): ]]; then
    if [[ "${BASH_REMATCH[1]}" != "${account_id}" ]]; then
      echo "Removing stale cross-account state for ${address} (${BASH_REMATCH[1]})"
      terraform state rm "${address}" >/dev/null 2>&1 || true
    fi
  elif [[ "${id}" =~ abricot-tp3-([0-9]{12}) ]]; then
    if [[ "${BASH_REMATCH[1]}" != "${account_id}" ]]; then
      echo "Removing stale cross-account state for ${address} (${BASH_REMATCH[1]})"
      terraform state rm "${address}" >/dev/null 2>&1 || true
    fi
  fi
done

frontend_bucket="${NAME_PREFIX}-${account_id}-frontend"
lambda_artifacts_bucket="${NAME_PREFIX}-${account_id}-lambda-artifacts"
cognito_domain="${NAME_PREFIX}-${account_id}"
db_subnet_group="${NAME_PREFIX}-private-db"
db_instance="${NAME_PREFIX}-postgres"
db_proxy="${NAME_PREFIX}-users-proxy"
db_secret="${NAME_PREFIX}/postgres"

existing_vpc_id="$(aws_text rds describe-db-subnet-groups \
  --db-subnet-group-name "${db_subnet_group}" \
  --query 'DBSubnetGroups[0].VpcId')"

if ! is_real_id "${existing_vpc_id}"; then
  existing_vpc_id="$(aws_text ec2 describe-vpcs \
    --filters "Name=cidr-block,Values=${VPC_CIDR}" \
    --query 'Vpcs[0].VpcId')"
fi

if is_real_id "${existing_vpc_id}"; then
  public_subnet_0="$(subnet_id_for_cidr "${existing_vpc_id}" "10.42.0.0/24")"
  public_subnet_1="$(subnet_id_for_cidr "${existing_vpc_id}" "10.42.1.0/24")"
  private_app_subnet_0="$(subnet_id_for_cidr "${existing_vpc_id}" "10.42.10.0/24")"
  private_app_subnet_1="$(subnet_id_for_cidr "${existing_vpc_id}" "10.42.11.0/24")"
  private_db_subnet_0="$(subnet_id_for_cidr "${existing_vpc_id}" "10.42.20.0/24")"
  private_db_subnet_1="$(subnet_id_for_cidr "${existing_vpc_id}" "10.42.21.0/24")"

  import_if_missing 'aws_vpc.private[0]' "${existing_vpc_id}"
  internet_gateway_id="$(aws_text ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${existing_vpc_id}" \
    --query 'InternetGateways[0].InternetGatewayId')"
  import_or_forget_vpc_scoped 'aws_internet_gateway.private[0]' "${internet_gateway_id}" "${existing_vpc_id}"

  import_or_forget_vpc_scoped 'aws_subnet.public[0]' "${public_subnet_0}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_subnet.public[1]' "${public_subnet_1}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_subnet.private_app[0]' "${private_app_subnet_0}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_subnet.private_app[1]' "${private_app_subnet_1}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_subnet.private_db[0]' "${private_db_subnet_0}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_subnet.private_db[1]' "${private_db_subnet_1}" "${existing_vpc_id}"

  public_route_table_id="$(route_table_id_for_subnet "${public_subnet_0}")"
  private_app_route_table_0_id="$(route_table_id_for_subnet "${private_app_subnet_0}")"
  private_app_route_table_1_id="$(route_table_id_for_subnet "${private_app_subnet_1}")"
  private_db_route_table_id="$(route_table_id_for_subnet "${private_db_subnet_0}")"

  nat_gateway_id="$(nat_gateway_id_for_route_table "${private_app_route_table_0_id}")"
  if ! is_real_id "${nat_gateway_id}"; then
    nat_gateway_id="$(nat_gateway_id_for_route_table "${private_app_route_table_1_id}")"
  fi
  if ! is_real_id "${nat_gateway_id}"; then
    nat_gateway_id="$(aws_text ec2 describe-nat-gateways \
      --filter "Name=vpc-id,Values=${existing_vpc_id}" "Name=subnet-id,Values=${public_subnet_0}" "Name=state,Values=available,pending" \
      --query 'NatGateways[0].NatGatewayId')"
  fi
  nat_eip_allocation_id="$(nat_gateway_allocation_id "${nat_gateway_id}")"

  import_if_missing 'aws_eip.nat[0]' "${nat_eip_allocation_id}"
  if is_real_id "${nat_gateway_id}"; then
    import_if_missing 'aws_nat_gateway.this[0]' "${nat_gateway_id}"
  else
    remove_state_if_attr_mismatch 'aws_nat_gateway.this[0]' "subnet_id" "${public_subnet_0}"
  fi

  import_or_forget_vpc_scoped 'aws_route_table.public[0]' "${public_route_table_id}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_route_table.private_app[0]' "${private_app_route_table_0_id}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_route_table.private_app[1]' "${private_app_route_table_1_id}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_route_table.private_db[0]' "${private_db_route_table_id}" "${existing_vpc_id}"

  import_route_if_present 'aws_route.public_internet[0]' "${public_route_table_id}" "0.0.0.0/0"
  import_route_if_present 'aws_route.private_app_nat[0]' "${private_app_route_table_0_id}" "0.0.0.0/0"
  import_route_if_present 'aws_route.private_app_nat[1]' "${private_app_route_table_1_id}" "0.0.0.0/0"

  import_route_table_association 'aws_route_table_association.public[0]' "${public_subnet_0}" "${public_route_table_id}"
  import_route_table_association 'aws_route_table_association.public[1]' "${public_subnet_1}" "${public_route_table_id}"
  import_route_table_association 'aws_route_table_association.private_app[0]' "${private_app_subnet_0}" "${private_app_route_table_0_id}"
  import_route_table_association 'aws_route_table_association.private_app[1]' "${private_app_subnet_1}" "${private_app_route_table_1_id}"
  import_route_table_association 'aws_route_table_association.private_db[0]' "${private_db_subnet_0}" "${private_db_route_table_id}"
  import_route_table_association 'aws_route_table_association.private_db[1]' "${private_db_subnet_1}" "${private_db_route_table_id}"

  lambda_sg_id="$(security_group_id_for_name "${existing_vpc_id}" "${NAME_PREFIX}-lambda-sg")"
  rds_proxy_sg_id="$(security_group_id_for_name "${existing_vpc_id}" "${NAME_PREFIX}-rds-proxy-sg")"
  rds_sg_id="$(security_group_id_for_name "${existing_vpc_id}" "${NAME_PREFIX}-rds-sg")"

  import_or_forget_vpc_scoped 'aws_security_group.lambda[0]' "${lambda_sg_id}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_security_group.rds_proxy[0]' "${rds_proxy_sg_id}" "${existing_vpc_id}"
  import_or_forget_vpc_scoped 'aws_security_group.rds[0]' "${rds_sg_id}" "${existing_vpc_id}"

  if is_real_id "${lambda_sg_id}" && is_real_id "${rds_proxy_sg_id}" && is_real_id "${rds_sg_id}"; then
    import_if_absent 'aws_security_group_rule.lambda_to_rds_proxy[0]' "${lambda_sg_id}_egress_tcp_${POSTGRES_PORT}_${POSTGRES_PORT}_${rds_proxy_sg_id}"
    import_if_absent 'aws_security_group_rule.lambda_https_egress[0]' "${lambda_sg_id}_egress_tcp_443_443_0.0.0.0/0"
    import_if_absent 'aws_security_group_rule.rds_proxy_from_lambda[0]' "${rds_proxy_sg_id}_ingress_tcp_${POSTGRES_PORT}_${POSTGRES_PORT}_${lambda_sg_id}"
    import_if_absent 'aws_security_group_rule.rds_proxy_to_rds[0]' "${rds_proxy_sg_id}_egress_tcp_${POSTGRES_PORT}_${POSTGRES_PORT}_${rds_sg_id}"
    import_if_absent 'aws_security_group_rule.rds_from_proxy[0]' "${rds_sg_id}_ingress_tcp_${POSTGRES_PORT}_${POSTGRES_PORT}_${rds_proxy_sg_id}"
  fi
fi

if is_real_id "${account_id}" && aws s3api head-bucket --bucket "${frontend_bucket}" >/dev/null 2>&1; then
  import_if_missing 'aws_s3_bucket.frontend' "${frontend_bucket}"
  import_if_absent 'aws_s3_bucket_versioning.frontend' "${frontend_bucket}"
  import_if_absent 'aws_s3_bucket_ownership_controls.frontend' "${frontend_bucket}"
  import_if_absent 'aws_s3_bucket_public_access_block.frontend' "${frontend_bucket}"
  import_if_absent 'aws_s3_bucket_website_configuration.frontend' "${frontend_bucket}"
  import_if_absent 'aws_s3_bucket_policy.frontend_public_read' "${frontend_bucket}"
fi

if is_real_id "${account_id}" && aws s3api head-bucket --bucket "${lambda_artifacts_bucket}" >/dev/null 2>&1; then
  import_if_missing 'aws_s3_bucket.lambda_artifacts' "${lambda_artifacts_bucket}"
  import_if_absent 'aws_s3_bucket_versioning.lambda_artifacts' "${lambda_artifacts_bucket}"
  import_if_absent 'aws_s3_bucket_public_access_block.lambda_artifacts' "${lambda_artifacts_bucket}"
  import_if_absent 'aws_s3_bucket_server_side_encryption_configuration.lambda_artifacts' "${lambda_artifacts_bucket}"
fi

user_pool_id="$(aws_text cognito-idp list-user-pools \
  --max-results 60 \
  --query "UserPools[?Name=='${NAME_PREFIX}-user-pool'].Id | [0]")"
import_if_missing 'aws_cognito_user_pool.main' "${user_pool_id}"

if is_real_id "${user_pool_id}"; then
  import_if_missing 'aws_cognito_user_pool_domain.main' "${cognito_domain}"

  user_pool_client_id="$(aws_text cognito-idp list-user-pool-clients \
    --user-pool-id "${user_pool_id}" \
    --query "UserPoolClients[?ClientName=='${NAME_PREFIX}-spa-client'].ClientId | [0]")"
  if is_real_id "${user_pool_client_id}"; then
    import_if_absent 'aws_cognito_user_pool_client.spa' "${user_pool_id}/${user_pool_client_id}"
  fi
fi

lambda_keys=(
  health
  users_service
  catalog_service
  orders_service
  restaurants_service
  reservations_service
  promotions_service
  analytics_service
  email_worker
  analytics_worker
  db_migrate
)

for key in "${lambda_keys[@]}"; do
  function_name="$(lambda_function_name_for_key "${key}")"
  if aws lambda get-function --function-name "${function_name}" >/dev/null 2>&1; then
    import_if_missing "aws_lambda_function.this[\"${key}\"]" "${function_name}"
    if ! terraform state show "aws_lambda_function.this[\"${key}\"]" >/dev/null 2>&1; then
      function_arn="$(aws_text lambda get-function \
        --function-name "${function_name}" \
        --query 'Configuration.FunctionArn')"
      import_if_missing "aws_lambda_function.this[\"${key}\"]" "${function_arn}"
    fi
  fi
done

api_id="$(api_id_for_name)"
import_if_missing 'aws_apigatewayv2_api.http' "${api_id}"

if is_real_id "${api_id}"; then
  remove_state_if_attr_mismatch 'aws_apigatewayv2_stage.default' "api_id" "${api_id}"
  import_if_absent 'aws_apigatewayv2_stage.default' "${api_id}/\$default"

  api_authorizer_id="$(api_authorizer_id_for_name "${api_id}")"
  if is_real_id "${api_authorizer_id}"; then
    remove_state_if_attr_mismatch 'aws_apigatewayv2_authorizer.cognito' "api_id" "${api_id}"
    import_if_absent 'aws_apigatewayv2_authorizer.cognito' "${api_id}/${api_authorizer_id}"
  fi

  api_lambda_keys=(
    health
    users_service
    catalog_service
    orders_service
    restaurants_service
    reservations_service
    promotions_service
    analytics_service
  )

  for key in "${api_lambda_keys[@]}"; do
    function_name="$(lambda_function_name_for_key "${key}")"
    function_arn="$(aws_text lambda get-function \
      --function-name "${function_name}" \
      --query 'Configuration.FunctionArn')"
    integration_id="$(api_integration_id_for_lambda "${api_id}" "${function_arn}" || true)"
    remove_state_if_attr_mismatch "aws_apigatewayv2_integration.lambda[\"${key}\"]" "api_id" "${api_id}"
    if is_real_id "${integration_id}"; then
      import_if_absent "aws_apigatewayv2_integration.lambda[\"${key}\"]" "${api_id}/${integration_id}"
    fi

    expected_api_source_arn="arn:aws:execute-api:${AWS_REGION:-us-east-1}:${account_id}:${api_id}/*/*"
    remove_state_if_attr_mismatch "aws_lambda_permission.api_gateway[\"${key}\"]" "source_arn" "${expected_api_source_arn}"
    permission_sid="$(lambda_permission_statement_id_for_api "${function_name}" "${expected_api_source_arn}")"
    if is_real_id "${permission_sid}"; then
      import_if_absent "aws_lambda_permission.api_gateway[\"${key}\"]" "${function_name}/${permission_sid}"
    fi
  done

  while IFS=$'\t' read -r address route_key; do
    route_id="$(api_route_id_for_key "${api_id}" "${route_key}" || true)"
    remove_state_if_attr_mismatch "${address}" "api_id" "${api_id}"
    if is_real_id "${route_id}"; then
      import_if_absent "${address}" "${api_id}/${route_id}"
    fi
  done < <(terraform_api_routes || true)
fi

if aws rds describe-db-subnet-groups --db-subnet-group-name "${db_subnet_group}" >/dev/null 2>&1; then
  import_if_missing 'aws_db_subnet_group.private[0]' "${db_subnet_group}"
fi

if aws rds describe-db-instances --db-instance-identifier "${db_instance}" >/dev/null 2>&1; then
  import_if_missing 'aws_db_instance.postgres[0]' "${db_instance}"
fi

secret_arn="$(aws_text secretsmanager describe-secret \
  --secret-id "${db_secret}" \
  --query ARN)"
import_if_missing 'aws_secretsmanager_secret.db[0]' "${secret_arn}"

if aws rds describe-db-proxies --db-proxy-name "${db_proxy}" >/dev/null 2>&1; then
  import_if_absent 'aws_db_proxy.users[0]' "${db_proxy}"
  import_if_absent 'aws_db_proxy_default_target_group.users[0]' "${db_proxy}"
  import_if_absent 'aws_db_proxy_target.users[0]' "${db_proxy}/default/RDS_INSTANCE/${db_instance}"
fi

domain_events_topic_arn="$(sns_topic_arn_for_name "${NAME_PREFIX}-domain-events")"
email_topic_arn="$(sns_topic_arn_for_name "${NAME_PREFIX}-email-notifications")"

import_if_missing 'aws_sns_topic.domain_events' "${domain_events_topic_arn}"
import_if_missing 'aws_sns_topic.email_topic' "${email_topic_arn}"

email_events_dlq_url="$(sqs_queue_url_for_name "${NAME_PREFIX}-email-events-dlq")"
email_events_url="$(sqs_queue_url_for_name "${NAME_PREFIX}-email-events")"
analytics_events_dlq_url="$(sqs_queue_url_for_name "${NAME_PREFIX}-analytics-events-dlq")"
analytics_events_url="$(sqs_queue_url_for_name "${NAME_PREFIX}-analytics-events")"

import_if_missing 'aws_sqs_queue.email_events_dlq' "${email_events_dlq_url}"
import_if_missing 'aws_sqs_queue.email_events' "${email_events_url}"
import_if_missing 'aws_sqs_queue.analytics_events_dlq' "${analytics_events_dlq_url}"
import_if_missing 'aws_sqs_queue.analytics_events' "${analytics_events_url}"

if is_real_id "${email_events_url}"; then
  import_if_absent 'aws_sqs_queue_policy.email_events' "${email_events_url}"
fi

if is_real_id "${analytics_events_url}"; then
  import_if_absent 'aws_sqs_queue_policy.analytics_events' "${analytics_events_url}"
fi

email_events_arn="$(sqs_queue_arn_for_url "${email_events_url}")"
analytics_events_arn="$(sqs_queue_arn_for_url "${analytics_events_url}")"

email_events_subscription_arn="$(sns_subscription_arn_for_endpoint "${domain_events_topic_arn}" "sqs" "${email_events_arn}")"
analytics_events_subscription_arn="$(sns_subscription_arn_for_endpoint "${domain_events_topic_arn}" "sqs" "${analytics_events_arn}")"

import_if_absent 'aws_sns_topic_subscription.email_events_sqs' "${email_events_subscription_arn}"
import_if_absent 'aws_sns_topic_subscription.analytics_events_sqs' "${analytics_events_subscription_arn}"

if [[ -n "${TF_VAR_notification_email:-}" ]]; then
  email_notification_subscription_arn="$(sns_subscription_arn_for_endpoint "${email_topic_arn}" "email" "${TF_VAR_notification_email}")"
  import_if_absent 'aws_sns_topic_subscription.email_notification[0]' "${email_notification_subscription_arn}"
fi

email_worker_function="$(lambda_function_name_for_key "email_worker")"
analytics_worker_function="$(lambda_function_name_for_key "analytics_worker")"
email_worker_mapping_uuid="$(event_source_mapping_uuid "${email_events_arn}" "${email_worker_function}")"
analytics_worker_mapping_uuid="$(event_source_mapping_uuid "${analytics_events_arn}" "${analytics_worker_function}")"

import_if_absent 'aws_lambda_event_source_mapping.email_worker' "${email_worker_mapping_uuid}"
import_if_absent 'aws_lambda_event_source_mapping.analytics_worker' "${analytics_worker_mapping_uuid}"

echo "Existing-resource import recovery finished"
