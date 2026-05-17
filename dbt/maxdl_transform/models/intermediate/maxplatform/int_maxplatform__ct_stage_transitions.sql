-- 자동생성: maxplatform.ct_stage_transitions Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__ct_stage_transitions')) }}
from {{ ref('stg_maxplatform__ct_stage_transitions') }}
