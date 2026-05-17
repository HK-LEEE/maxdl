-- 자동생성: maxplatform.ct_config_stage_permissions Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__ct_config_stage_permissions')) }}
from {{ ref('stg_maxplatform__ct_config_stage_permissions') }}
