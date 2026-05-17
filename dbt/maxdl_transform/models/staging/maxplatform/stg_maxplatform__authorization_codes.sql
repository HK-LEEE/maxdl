-- 자동 생성: maxplatform.authorization_codes Bronze → staging cleaned view
{{ config(materialized='view') }}
select
    {{ dbt_utils.star(from=source('maxplatform', 'authorization_codes'), except=['_airbyte_raw_id', '_airbyte_meta', '_airbyte_generation_id', '_airbyte_extracted_at']) }},
    _airbyte_extracted_at as _bronze_extracted_at_epoch,
    {{ maxdl_audit_columns() }}
from {{ source('maxplatform', 'authorization_codes') }}
