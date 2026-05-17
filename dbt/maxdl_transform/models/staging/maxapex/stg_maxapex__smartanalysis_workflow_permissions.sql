-- 자동 생성: maxapex.smartanalysis_workflow_permissions Bronze → staging cleaned view
{{ config(materialized='view') }}
select
    {{ dbt_utils.star(from=source('maxapex', 'smartanalysis_workflow_permissions'), except=['_airbyte_raw_id', '_airbyte_meta', '_airbyte_generation_id', '_airbyte_extracted_at']) }},
    _airbyte_extracted_at as _bronze_extracted_at_epoch,
    {{ maxdl_audit_columns() }}
from {{ source('maxapex', 'smartanalysis_workflow_permissions') }}
