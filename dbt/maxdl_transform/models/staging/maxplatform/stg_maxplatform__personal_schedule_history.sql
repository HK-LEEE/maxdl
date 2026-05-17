-- 자동 생성: maxplatform.personal_schedule_history Bronze → staging cleaned view
{{ config(materialized='view') }}
select
    {{ dbt_utils.star(from=source('maxplatform', 'personal_schedule_history'), except=['_airbyte_raw_id', '_airbyte_meta', '_airbyte_generation_id', '_airbyte_extracted_at']) }},
    _airbyte_extracted_at as _bronze_extracted_at_epoch,
    {{ maxdl_audit_columns() }}
from {{ source('maxplatform', 'personal_schedule_history') }}
